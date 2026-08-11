import Foundation
import Testing
import TrackifyDomain

@testable import TrackifyEngine

@Suite("Live collection")
struct LiveCollectionTests {
    @Test("macOS filesystem monitor delivers a recursive file change")
    func fileSystemMonitorIntegration() async throws {
        guard ProcessInfo.processInfo.environment["TRACKIFY_FSEVENTS_INTEGRATION"] == "1" else {
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-fsevents-\(UUID().uuidString)", directoryHint: .isDirectory)
        let nested = directory.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = nested.appending(path: "event.jsonl").standardizedFileURL.path
        let gate = OneShotGate()

        try await confirmation("FSEvents delivered the nested file", expectedCount: 1) { confirm in
            let monitor = FSEventsChangeMonitor(roots: [directory], latency: 0.05) { changes in
                if changes.contains(where: { $0.path == target }), gate.claim() {
                    confirm()
                }
            }
            try monitor.start()
            defer { monitor.stop() }
            try Data("{}\n".utf8).write(to: URL(filePath: target))
            try await Task.sleep(for: .seconds(2))
        }
    }

    @Test("Planner targets one known repository and filters dependency churn")
    func targetsKnownRepository() throws {
        let now = Date(timeIntervalSince1970: 1_785_888_000)
        let root = GitCollectionRoot(path: URL(filePath: "/projects"))
        let copy = WorkingCopy(
            id: WorkingCopyID("copy-a"), repositoryID: RepositoryID("repo-a"),
            canonicalPath: "/projects/a", firstObservedAt: now, lastObservedAt: now)
        let catalog = makeCatalog(gitRoots: [root], workingCopies: [copy])
        let planner = LiveCollectionPlanner()
        let trigger = try #require(
            planner.classify(
                [
                    FileSystemChange(
                        path: "/projects/a/Sources/App.swift", rawFlags: 0,
                        eventID: 1, observedAt: now),
                    FileSystemChange(
                        path: "/projects/a/node_modules/cache.bin", rawFlags: 0,
                        eventID: 2, observedAt: now),
                ],
                catalog: catalog))
        let plan = planner.plan(
            LiveCollectionBatch(
                families: trigger.families, paths: trigger.paths, reasons: [trigger.reason],
                firstObservedAt: now, lastObservedAt: now,
                requiresReconciliation: false, triggerCount: 1),
            catalog: catalog)

        #expect(trigger.families == [.git])
        #expect(trigger.paths == ["/projects/a/Sources/App.swift"])
        #expect(plan.gitRoots.count == 1)
        #expect(plan.gitRoots[0].includedRepositories == [URL(filePath: "/projects/a")])
    }

    @Test("Unknown repository paths request bounded discovery")
    func requestsDiscoveryForUnknownRepository() throws {
        let now = Date(timeIntervalSince1970: 1_785_888_000)
        let root = GitCollectionRoot(path: URL(filePath: "/projects"))
        let catalog = makeCatalog(gitRoots: [root], workingCopies: [])
        let planner = LiveCollectionPlanner()
        let trigger = try #require(
            planner.classify(
                [
                    FileSystemChange(
                        path: "/projects/new-repo/.git/HEAD", rawFlags: 0,
                        eventID: 1, observedAt: now)
                ],
                catalog: catalog))
        let plan = planner.plan(
            LiveCollectionBatch(
                families: trigger.families, paths: trigger.paths, reasons: [trigger.reason],
                firstObservedAt: now, lastObservedAt: now,
                requiresReconciliation: false, triggerCount: 1),
            catalog: catalog)

        #expect(trigger.families == [.git, .discovery])
        #expect(plan.gitRoots.count == 1)
        #expect(plan.gitRoots[0].includedRepositories == nil)
    }

    @Test("Provider append plans one exact conversation file")
    func targetsProviderFile() throws {
        let now = Date(timeIntervalSince1970: 1_785_888_000)
        let catalog = makeCatalog()
        let file = "/home/demo/.codex/sessions/2026/session.jsonl"
        let planner = LiveCollectionPlanner()
        let trigger = try #require(
            planner.classify(
                [FileSystemChange(path: file, rawFlags: 0, eventID: 1, observedAt: now)],
                catalog: catalog))
        let plan = planner.plan(
            LiveCollectionBatch(
                families: trigger.families, paths: trigger.paths, reasons: [trigger.reason],
                firstObservedAt: now, lastObservedAt: now,
                requiresReconciliation: false, triggerCount: 1),
            catalog: catalog)

        #expect(plan.includeCodex)
        #expect(plan.codexFiles == [URL(filePath: file)])
        #expect(!plan.includeClaude)
        #expect(plan.gitRoots.isEmpty)
    }

    @Test("Recovery remains scoped to the affected source family")
    func scopesRecoveryToAffectedFamily() throws {
        let now = Date(timeIntervalSince1970: 1_785_888_000)
        let root = GitCollectionRoot(path: URL(filePath: "/projects"))
        let copy = WorkingCopy(
            id: WorkingCopyID("copy-a"), repositoryID: RepositoryID("repo-a"),
            canonicalPath: "/projects/a", firstObservedAt: now, lastObservedAt: now)
        let catalog = makeCatalog(gitRoots: [root], workingCopies: [copy])
        let plan = LiveCollectionPlanner().plan(
            LiveCollectionBatch(
                families: [.codex], paths: [], reasons: [.reconciliation],
                firstObservedAt: now, lastObservedAt: now,
                requiresReconciliation: true, triggerCount: 1),
            catalog: catalog)

        #expect(plan.includeCodex)
        #expect(plan.codexFiles == nil)
        #expect(!plan.includeClaude)
        #expect(!plan.includeHook)
        #expect(plan.gitRoots.isEmpty)
    }

    @Test("SQLite churn never feeds the filesystem collector")
    func ignoresLedgerFiles() {
        let now = Date(timeIntervalSince1970: 1_785_888_000)
        let catalog = makeCatalog()
        let planner = LiveCollectionPlanner()
        let changes = [
            FileSystemChange(
                path: catalog.ledgerURL.path, rawFlags: 0,
                eventID: 1, observedAt: now),
            FileSystemChange(
                path: catalog.ledgerURL.path + "-wal", rawFlags: 0,
                eventID: 2, observedAt: now),
        ]

        #expect(planner.classify(changes, catalog: catalog) == nil)
    }

    @Test("Targeted Git collection opens only the affected repository")
    func targetedGitCollection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-live-git-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "first", directoryHint: .isDirectory)
        let second = directory.appending(path: "second", directoryHint: .isDirectory)
        try makeLiveGitRepository(at: first)
        try makeLiveGitRepository(at: second)

        let batch = try await GitSourceAdapter(
            root: directory, includedRepositories: [first]
        ).collect(
            request: CollectionRequest(cutoff: Date(timeIntervalSince1970: 1_785_888_000)),
            cursor: nil)

        #expect(batch.readMetrics.candidatesConsidered == 1)
        #expect(batch.readMetrics.openedUnitFingerprints.count == 1)
        #expect(batch.repositories.map(\.repository.displayName) == ["first"])
    }

    @Test("A filesystem storm coalesces into one bounded collection")
    func coalescesEventStorm() async throws {
        let now = Date(timeIntervalSince1970: 1_785_888_000)
        let recorder = LiveBatchRecorder()
        let coordinator = LiveCollectionCoordinator(
            policy: LiveCollectionPolicy(
                providerDebounce: 600, gitDebounce: 600, discoveryDebounce: 600,
                maximumDelay: 600, retryDelay: 1, maximumPathsPerBatch: 100),
            clock: FixedWallClock(now),
            collector: { batch in
                await recorder.record(batch)
                return LedgerMutation(
                    committedAt: now, firstTriggerAt: batch.firstObservedAt,
                    insertedEvents: 1, insertedObservations: 1,
                    changedFamilies: batch.families)
            })

        for index in 0..<1_000 {
            await coordinator.submit(
                LiveCollectionTrigger(
                    families: [.codex], paths: ["/history/session-\(index).jsonl"],
                    observedAt: now, reason: .filesystem))
        }
        await coordinator.flush()

        let batches = await recorder.values
        #expect(batches.count == 1)
        #expect(batches.first?.triggerCount == 1_000)
        #expect(batches.first?.paths.count == 100)
        #expect(batches.first?.requiresReconciliation == true)
        #expect(await coordinator.status().mode == .upToDate)
        await coordinator.stop()
    }

    @Test("Triggers arriving during collection form one following batch")
    func preservesTriggersDuringCollection() async throws {
        let now = Date(timeIntervalSince1970: 1_785_888_000)
        let recorder = LiveBatchRecorder()
        let gate = LiveCollectionGate()
        let coordinator = LiveCollectionCoordinator(
            policy: LiveCollectionPolicy(
                providerDebounce: 600, gitDebounce: 600, discoveryDebounce: 600,
                maximumDelay: 600),
            clock: FixedWallClock(now),
            collector: { batch in
                let ordinal = await recorder.record(batch)
                if ordinal == 1 { await gate.wait() }
                return LedgerMutation(
                    committedAt: now, firstTriggerAt: batch.firstObservedAt,
                    insertedEvents: 1, insertedObservations: 1,
                    changedFamilies: batch.families)
            })

        await coordinator.submit(
            LiveCollectionTrigger(
                families: [.codex], paths: ["/history/first.jsonl"],
                observedAt: now, reason: .filesystem))
        let firstFlush = Task { await coordinator.flush() }
        await gate.waitUntilCollectorEntered()
        await coordinator.submit(
            LiveCollectionTrigger(
                families: [.git], paths: ["/projects/second/file.swift"],
                observedAt: now, reason: .filesystem))
        let queuedFlush = Task { await coordinator.flush() }
        await Task.yield()
        await gate.release()
        await firstFlush.value
        await queuedFlush.value

        let batches = await recorder.values
        #expect(batches.count == 2)
        #expect(batches[0].families == [.codex])
        #expect(batches[1].families == [.git])
        await coordinator.stop()
    }

    @Test("Targeted conversation reads retain unrelated durable cursors")
    func targetedConversationRead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-live-source-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "first.jsonl")
        let second = directory.appending(path: "second.jsonl")
        try Data("{}\n".utf8).write(to: first)
        try Data("{}\n".utf8).write(to: second)
        let request = CollectionRequest(cutoff: Date(timeIntervalSince1970: 1_785_888_000))

        let firstBatch = try await ConversationDirectorySource(
            provider: .codex, root: directory, includedFiles: [first]
        ).collect(request: request, cursor: nil)
        let firstCursor = try JSONDecoder().decode(
            ConversationDirectoryCursor.self, from: try #require(firstBatch.nextCursor))
        #expect(firstBatch.readMetrics.candidatesConsidered == 1)
        #expect(Set(firstCursor.files.keys) == ["first.jsonl"])

        let secondBatch = try await ConversationDirectorySource(
            provider: .codex, root: directory, includedFiles: [second]
        ).collect(request: request, cursor: firstBatch.nextCursor)
        let secondCursor = try JSONDecoder().decode(
            ConversationDirectoryCursor.self, from: try #require(secondBatch.nextCursor))
        #expect(secondBatch.readMetrics.candidatesConsidered == 1)
        #expect(Set(secondCursor.files.keys) == ["first.jsonl", "second.jsonl"])
    }
}

private func makeCatalog(
    gitRoots: [GitCollectionRoot] = [],
    workingCopies: [WorkingCopy] = []
) -> LiveWatchCatalog {
    LiveWatchCatalog(
        gitRoots: gitRoots, workingCopies: workingCopies,
        codexRoots: [URL(filePath: "/home/demo/.codex/sessions")],
        claudeRoot: URL(filePath: "/home/demo/.claude/projects"),
        claudeDesktopRoot: URL(filePath: "/home/demo/Library/Application Support/Claude/local-agent-mode-sessions"),
        hookInboxURL: URL(filePath: "/home/demo/Library/Application Support/Trackify/Inbox/events.jsonl"),
        ledgerURL: URL(filePath: "/home/demo/Library/Application Support/Trackify/trackify.sqlite"),
        settingsURL: URL(filePath: "/home/demo/Library/Application Support/Trackify/settings.json"))
}

private func makeLiveGitRepository(at url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let runner = ProcessRunner()
    let executable = URL(filePath: "/usr/bin/git")
    let environment = [
        "HOME": FileManager.default.temporaryDirectory.path,
        "PATH": "/usr/bin:/bin",
        "GIT_AUTHOR_NAME": "Trackify Test",
        "GIT_AUTHOR_EMAIL": "trackify@example.invalid",
        "GIT_COMMITTER_NAME": "Trackify Test",
        "GIT_COMMITTER_EMAIL": "trackify@example.invalid",
    ]
    func run(_ arguments: [String]) throws {
        let output = try runner.run(
            executable: executable, arguments: arguments,
            workingDirectory: url, environment: environment,
            outputLimit: 1_024 * 1_024)
        guard output.status == 0 else {
            throw ProcessRunnerError.failed(
                executable: executable.path, status: output.status, output: output.utf8)
        }
    }
    try run(["init", "--initial-branch=main"])
    try Data("initial\n".utf8).write(to: url.appending(path: "README.md"))
    try run(["add", "README.md"])
    try run(["commit", "-m", "Initial commit"])
}

private actor LiveBatchRecorder {
    private(set) var values: [LiveCollectionBatch] = []

    @discardableResult
    func record(_ batch: LiveCollectionBatch) -> Int {
        values.append(batch)
        return values.count
    }
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

private actor LiveCollectionGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilCollectorEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}
