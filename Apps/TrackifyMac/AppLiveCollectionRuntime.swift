import AppKit
import Foundation
import TrackifyDomain
import TrackifyEngine
import TrackifyStore

private actor LiveWatchCatalogRegistry {
    private var catalog: LiveWatchCatalog
    private let planner = LiveCollectionPlanner()

    init(catalog: LiveWatchCatalog) { self.catalog = catalog }

    func current() -> LiveWatchCatalog { catalog }

    func update(_ catalog: LiveWatchCatalog) { self.catalog = catalog }

    func classify(_ changes: [FileSystemChange]) -> LiveCollectionTrigger? {
        planner.classify(changes, catalog: catalog)
    }

    func containsSettingsChange(_ changes: [FileSystemChange]) -> Bool {
        changes.contains { URL(filePath: $0.path).standardizedFileURL == catalog.settingsURL }
    }
}

@MainActor
final class AppLiveCollectionRuntime {
    private weak var model: AppModel?
    private var monitor: FSEventsChangeMonitor
    private let coordinator: LiveCollectionCoordinator
    private let catalogRegistry: LiveWatchCatalogRegistry
    private let clock: any WallClock
    private var distributedObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var startupReconciliationTask: Task<Void, Never>?
    private var paused: Bool
    private var stopped = false

    private init(
        model: AppModel,
        monitor: FSEventsChangeMonitor,
        coordinator: LiveCollectionCoordinator,
        catalogRegistry: LiveWatchCatalogRegistry,
        clock: any WallClock,
        paused: Bool
    ) {
        self.model = model
        self.monitor = monitor
        self.coordinator = coordinator
        self.catalogRegistry = catalogRegistry
        self.clock = clock
        self.paused = paused
    }

    static func start(
        model: AppModel,
        clock: any WallClock,
        paused: Bool
    ) async throws -> AppLiveCollectionRuntime {
        let catalog = try await Task.detached(priority: .utility) {
            try loadCatalog()
        }.value
        let registry = LiveWatchCatalogRegistry(catalog: catalog)
        let coordinator = LiveCollectionCoordinator(
            clock: clock,
            collector: { batch in
                let current = await registry.current()
                return try await collect(batch: batch, catalog: current, clock: clock)
            },
            mutationHandler: { [weak model] mutation in
                if mutation.changedFamilies.contains(.discovery),
                    let updated = try? loadCatalog()
                {
                    await registry.update(updated)
                }
                await model?.refreshEvidence()
            },
            statusHandler: { [weak model] status in
                try? persist(status: status, at: clock.now())
                await model?.applyLiveCollectorStatus(status)
            })
        let monitor = makeMonitor(
            roots: catalog.monitoredRoots, registry: registry,
            coordinator: coordinator, model: model)
        let runtime = AppLiveCollectionRuntime(
            model: model, monitor: monitor, coordinator: coordinator,
            catalogRegistry: registry, clock: clock, paused: paused)
        runtime.installObservers(ledgerURL: catalog.ledgerURL, clock: clock)
        if paused {
            await coordinator.pause()
        } else {
            try monitor.start()
        }
        try? persist(
            status: LiveCollectorRuntimeStatus(mode: paused ? .stopped : .upToDate),
            at: clock.now())
        model.applyLiveCollectorStatus(
            LiveCollectorRuntimeStatus(mode: paused ? .stopped : .upToDate))
        if !paused {
            runtime.startupReconciliationTask = Task { [weak runtime] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let runtime else { return }
                await runtime.submitBoundedRecovery()
            }
        }
        return runtime
    }

    func setPaused(_ paused: Bool) {
        guard !stopped, self.paused != paused else { return }
        self.paused = paused
        if paused {
            startupReconciliationTask?.cancel()
            startupReconciliationTask = nil
            monitor.stop()
            Task { await coordinator.pause() }
            model?.applyLiveCollectorStatus(LiveCollectorRuntimeStatus(mode: .stopped))
        } else {
            do {
                try monitor.start()
                startupReconciliationTask = Task { [weak self] in
                    guard let self else { return }
                    await coordinator.resume()
                    await submitBoundedRecovery()
                }
            } catch {
                model?.errorMessage = "Live collection could not resume: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        startupReconciliationTask?.cancel()
        startupReconciliationTask = nil
        monitor.stop()
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        Task { await coordinator.stop() }
    }

    private func installObservers(ledgerURL: URL, clock: any WallClock) {
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: TrackifyChangeSignal.notificationName,
            object: TrackifyChangeSignal.identifier(for: ledgerURL),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let processID = notification.userInfo?["processID"] as? Int,
                processID == Int(ProcessInfo.processInfo.processIdentifier)
            {
                return
            }
            let kind =
                (notification.userInfo?["kind"] as? String)
                .flatMap(TrackifyChangeKind.init(rawValue:)) ?? .ledger
            Task { @MainActor in
                if kind == .settings {
                    await self.model?.reloadCollectionSettings()
                    return
                }
                guard !self.paused, !self.stopped else { return }
                await self.reloadCatalogIfNeeded()
                await self.coordinator.submit(
                    LiveCollectionTrigger(
                        families: [.ledger], observedAt: clock.now(),
                        reason: .ledgerMutation))
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.monitor.stop() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused, !self.stopped else { return }
                do {
                    try self.monitor.start()
                    await self.submitBoundedRecovery()
                } catch {
                    self.model?.errorMessage = "Live collection could not recover after wake: \(error.localizedDescription)"
                }
            }
        }
    }

    private func submitBoundedRecovery() async {
        let sourceFamilies: [Set<LiveSourceFamily>] = [
            [.codex], [.claude, .claudeDesktop], [.hook],
        ]
        for families in sourceFamilies {
            guard !Task.isCancelled, !paused, !stopped else { return }
            await coordinator.submit(
                LiveCollectionTrigger(
                    families: families,
                    observedAt: clock.now(), reason: .reconciliation,
                    requiresReconciliation: true))
            await coordinator.flush()
            try? await Task.sleep(for: .milliseconds(1_250))
        }

        let catalog = await catalogRegistry.current()
        let priority = Set(catalog.priorityRepositoryIDs)
        let repositories = catalog.workingCopies
            .filter { priority.contains($0.repositoryID) }
            .map(\.canonicalPath).sorted()
        let batchSize = 4
        for start in stride(from: 0, to: repositories.count, by: batchSize) {
            guard !Task.isCancelled, !paused, !stopped else { return }
            let end = min(start + batchSize, repositories.count)
            let paths = Set(repositories[start..<end].map { $0 + "/.git/HEAD" })
            await coordinator.submit(
                LiveCollectionTrigger(
                    families: [.git], paths: paths,
                    observedAt: clock.now(), reason: .manual))
            await coordinator.flush()
            try? await Task.sleep(for: .milliseconds(1_250))
        }
    }

    private func reloadCatalogIfNeeded() async {
        guard
            let updated = try? await Task.detached(
                priority: .utility,
                operation: {
                    try Self.loadCatalog()
                }
            ).value
        else { return }
        await catalogRegistry.update(updated)
        let oldRoots = Set(monitor.monitoredRoots.map { $0.standardizedFileURL.path })
        let newRoots = Set(updated.monitoredRoots.map { $0.standardizedFileURL.path })
        guard oldRoots != newRoots else { return }
        monitor.stop()
        monitor = Self.makeMonitor(
            roots: updated.monitoredRoots,
            registry: catalogRegistry,
            coordinator: coordinator,
            model: model)
        guard !paused, !stopped else { return }
        do { try monitor.start() } catch {
            model?.errorMessage = "Live collection roots could not be updated: \(error.localizedDescription)"
        }
    }

    private nonisolated static func makeMonitor(
        roots: [URL],
        registry: LiveWatchCatalogRegistry,
        coordinator: LiveCollectionCoordinator,
        model: AppModel?
    ) -> FSEventsChangeMonitor {
        FSEventsChangeMonitor(roots: roots) { changes in
            Task {
                if await registry.containsSettingsChange(changes) {
                    await model?.reloadCollectionSettings()
                }
                guard let trigger = await registry.classify(changes) else { return }
                await coordinator.submit(trigger)
            }
        }
    }

    private nonisolated static func loadCatalog() throws -> LiveWatchCatalog {
        let paths = try TrackifyPaths.default()
        let store = try LedgerStore(databaseURL: paths.ledgerURL)
        let roots = try store.discoveryRoots(enabledOnly: true).map {
            GitCollectionRoot(
                path: URL(filePath: $0.canonicalPath), discoveryRootID: $0.id,
                excludedPaths: Set($0.excludedPaths))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let recentEvents = try store.recentEvents(
            from: .distantPast, through: .distantFuture,
            kinds: [
                .gitCommitObserved, .gitWorkingTreeChanged,
                .agentMessageObserved, .testFinished,
            ],
            limit: 500)
        var seenRepositoryIDs = Set<RepositoryID>()
        let priorityRepositoryIDs = recentEvents.compactMap { event -> RepositoryID? in
            guard let repositoryID = event.repositoryID,
                seenRepositoryIDs.insert(repositoryID).inserted
            else { return nil }
            return repositoryID
        }.prefix(16)
        return LiveWatchCatalog(
            gitRoots: roots,
            workingCopies: try store.workingCopies(),
            codexRoots: [
                home.appending(path: ".codex/sessions"),
                home.appending(path: ".codex/archived_sessions"),
            ],
            claudeRoot: home.appending(path: ".claude/projects"),
            claudeDesktopRoot: home.appending(
                path: "Library/Application Support/Claude/local-agent-mode-sessions"),
            hookInboxURL: paths.hookInboxURL,
            ledgerURL: paths.ledgerURL,
            settingsURL: paths.settingsURL,
            priorityRepositoryIDs: Array(priorityRepositoryIDs))
    }

    private nonisolated static func collect(
        batch: LiveCollectionBatch,
        catalog: LiveWatchCatalog,
        clock: any WallClock
    ) async throws -> LedgerMutation? {
        let paths = try TrackifyPaths.default()
        let settings = try SettingsStore(fileURL: paths.settingsURL).load()
        guard !settings.collectionPaused else { return nil }
        let plan = LiveCollectionPlanner().plan(batch, catalog: catalog)
        if plan.presentationOnly {
            return LedgerMutation(
                committedAt: clock.now(), firstTriggerAt: batch.firstObservedAt,
                insertedEvents: 0, insertedObservations: 0,
                changedFamilies: batch.families)
        }

        let store = try LedgerStore(databaseURL: paths.ledgerURL)
        let result = try await LocalCollectionCoordinator(clock: clock).collect(
            store: store,
            gitRoots: plan.gitRoots,
            includeCodex: plan.includeCodex,
            includeClaude: plan.includeClaude,
            hookInboxURL: plan.includeHook ? paths.hookInboxURL : nil,
            codexFiles: plan.codexFiles,
            claudeFiles: plan.claudeFiles,
            claudeDesktopFiles: plan.claudeDesktopFiles,
            maintenanceScope: .touchedSources)
        let insertedEvents = result.summaries.reduce(0) { $0 + $1.insertedEvents }
        let insertedObservations = result.summaries.reduce(0) { $0 + $1.insertedObservations }
        guard insertedEvents > 0 || insertedObservations > 0 else { return nil }
        let repositoryPaths = Set(
            plan.gitRoots.flatMap { root -> [String] in
                if let included = root.includedRepositories { return included.map(\.path) }
                return catalog.workingCopies.filter {
                    $0.canonicalPath == root.path.path
                        || $0.canonicalPath.hasPrefix(root.path.path + "/")
                }.map(\.canonicalPath)
            })
        let repositoryIDs = Set(
            catalog.workingCopies.filter { repositoryPaths.contains($0.canonicalPath) }
                .map(\.repositoryID))
        return LedgerMutation(
            committedAt: clock.now(), firstTriggerAt: batch.firstObservedAt,
            insertedEvents: insertedEvents,
            insertedObservations: insertedObservations,
            affectedRepositoryIDs: repositoryIDs,
            changedFamilies: batch.families)
    }

    private nonisolated static func persist(
        status: LiveCollectorRuntimeStatus,
        at date: Date
    ) throws {
        let paths = try TrackifyPaths.default()
        try LedgerStore(databaseURL: paths.ledgerURL).recordLiveCollectorStatus(status, at: date)
    }
}
