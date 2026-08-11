import ArgumentParser
import Darwin
import Foundation
import TrackifyDomain
import TrackifyEngine
import TrackifyStore

extension SummaryProviderID: ExpressibleByArgument {}
extension HookPhase: ExpressibleByArgument {}
extension RecipeCadence: ExpressibleByArgument {}
extension ReportScheduleCadence: ExpressibleByArgument {}
extension RecipeOutputFormat: ExpressibleByArgument {}
extension PrivacyProfile: ExpressibleByArgument {}
extension ProviderSelectionMode: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.replacingOccurrences(of: "-", with: "_"))
    }
}

@main
public struct TrackifyCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "trackify",
        abstract: "A local development-work ledger for macOS.",
        version: TrackifyBuildVersion.current,
        subcommands: [
            Status.self,
            Today.self,
            Day.self,
            Timeline.self,
            Search.self,
            Context.self,
            SummariesCommand.self,
            ReportsCommand.self,
            SourcesCommand.self,
            Providers.self,
            UsageCommand.self,
            RecipesCommand.self,
            ReportersCommand.self,
            ArtifactsCommand.self,
            Integrations.self,
            Bootstrap.self,
            RepositoriesCommand.self,
            SessionsCommand.self,
            Show.self,
            Roots.self,
            Backfill.self,
            DoctorCommand.self,
            DataCommand.self,
            UpdateCommand.self,
            CollectionControl.self,
            Collect.self,
            Simulate.self,
        ],
        defaultSubcommand: Status.self
    )

    public init() {
        CLIInterruptHandler.installIfExecutable()
    }
}

private final class CLIInterruptHandler: @unchecked Sendable {
    private static let installed = CLIInterruptHandler()

    private var sources: [DispatchSourceSignal] = []
    private let stateLock = NSLock()
    private var isStopping = false

    static func installIfExecutable() {
        guard ProcessInfo.processInfo.processName == "trackify" else { return }
        _ = installed
    }

    private init() {
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)
        let queue = DispatchQueue(label: "com.zoulabs.trackify.cli-signals")
        sources = [SIGINT, SIGTERM].map { signal in
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler { [weak self] in self?.stop(for: signal) }
            source.resume()
            return source
        }
    }

    private func stop(for signal: Int32) {
        let shouldStop = stateLock.withLock {
            guard !isStopping else { return false }
            isStopping = true
            return true
        }
        guard shouldStop else { return }
        ProcessRunner.terminateAllRunningCommands()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
            ProcessRunner.terminateAllRunningCommands(signal: SIGKILL)
            Darwin._exit(128 + signal)
        }
    }
}

public struct SummariesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "summaries",
        abstract: "Inspect and refresh Trackify's canonical work summaries.",
        subcommands: [List.self, Show.self, Refresh.self, Status.self],
        defaultSubcommand: Status.self)
    public init() {}

    public struct List: ParsableCommand {
        @Option(name: .long, help: "Maximum number of summaries.") var limit = 50
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let summaries = try storeOptions.makeStore().summaries(limit: limit)
            if outputOptions.json {
                try JSONOutput.write(SummariesPayload(summaries: summaries))
            } else if summaries.isEmpty {
                print("No summaries yet.")
            } else {
                for summary in summaries {
                    print(
                        "\(summary.id.rawValue) · \(summary.kind.rawValue) · \(summary.state.rawValue) · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                    print("  \(summary.content.compactNarrative)")
                }
            }
        }
    }

    public struct Show: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard let summary = try storeOptions.makeStore().summary(id: SummaryID(identifier)) else {
                throw ValidationError("Summary '\(identifier)' was not found.")
            }
            if outputOptions.json {
                try JSONOutput.write(SummaryPayload(summary: summary))
            } else {
                print(summary.content.narrative)
                for section in summary.content.projectSections {
                    print("\n\(section.project)\n  \(section.narrative)")
                }
                print(
                    "\n\(summary.coverage.coveredEventCount)/\(summary.coverage.eligibleEventCount) events covered · \(summary.generationSource.rawValue)"
                )
            }
        }
    }

    public struct Refresh: AsyncParsableCommand {
        @Option(name: .long, help: "Calendar days to refresh, including today (1...366).")
        var days = 2
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() async throws {
            let store = try storeOptions.makeStore()
            let settings = try storeOptions.makeSettingsStore().load()
            let result = await SummaryCoordinator().refresh(
                store: store, settings: settings, now: Date(),
                lookbackDays: days)
            if outputOptions.json {
                try JSONOutput.write(SummaryRefreshPayload(result: result))
            } else {
                print("Generated \(result.generated.count) summary revisions; \(result.unchanged) unchanged.")
                for issue in result.issues { print("Warning: \(issue)") }
            }
        }
    }

    public struct Status: ParsableCommand {
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let store = try storeOptions.makeStore()
            let current = try store.latestSummary(kind: .current)
            let day = try store.latestSummary(kind: .day)
            let runs = try store.summaryRuns(limit: 20)
            if outputOptions.json {
                try JSONOutput.write(
                    SummaryStatusPayload(
                        current: current, day: day, recentRuns: runs))
            } else {
                print("Current: \(current?.content.compactNarrative ?? "not generated")")
                print("Today: \(day?.content.compactNarrative ?? "not generated")")
                print("Recent summary runs: \(runs.count)")
            }
        }
    }
}

public struct ReportsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reports",
        abstract: "Preview, generate, and inspect configurable reports.",
        subcommands: [Generate.self, Preview.self, List.self, Show.self, Copy.self])
    public init() {}

    public struct Generate: AsyncParsableCommand {
        @Option(name: .long, help: "Saved report template ID.") var template = "daily-work-summary"
        @Option(name: .long, help: "today, yesterday, last-hour, or YYYY-MM-DD.") var period = "today"
        @Option(name: .long, help: "One-off instructions stored with this run.") var instructions: String?
        @Option(name: .long, help: "automatic, codex, claude, or local-only.") var provider: ProviderSelectionMode?
        @Option(name: .long, help: "Limit evidence to a repository ID; repeatable.") var repository: [String] = []
        @Flag(name: .long, help: "Only enqueue; do not wait for the report.") var enqueueOnly = false
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() async throws {
            let now = Date()
            let store = try storeOptions.makeStore()
            let settings = try storeOptions.makeSettingsStore().load()
            guard let (_, version) = try store.recipe(id: RecipeID(template)) else {
                throw ValidationError("Template '\(template)' was not found.")
            }
            let configuration = try effectiveConfiguration(
                version: version, instructions: instructions, provider: provider,
                repositories: repository)
            let queue = ReportQueue()
            let run = try queue.enqueueOnDemand(
                store: store, settings: settings, recipeID: RecipeID(template),
                period: try IntelligenceCLI.period(period, now: now), now: now,
                configuration: configuration)
            if enqueueOnly {
                if outputOptions.json { try JSONOutput.write(ReportRunPayload(run: run)) } else { print("Enqueued \(run.id.rawValue).") }
                return
            }
            _ = await queue.drain(store: store, settings: settings, maximumRuns: 20)
            guard let completed = try store.reportRun(id: run.id),
                let artifactID = completed.artifactID,
                let artifact = try store.artifact(id: artifactID)
            else { throw ValidationError("The report is still queued. Run `trackify reports list` shortly.") }
            if outputOptions.json { try JSONOutput.write(ArtifactPayload(artifact: artifact)) } else { print(artifact.content) }
        }
    }

    public struct Preview: ParsableCommand {
        @Option(name: .long, help: "Saved report template ID.") var template = "daily-work-summary"
        @Option(name: .long, help: "today, yesterday, last-hour, or YYYY-MM-DD.") var period = "today"
        @Option(name: .long, help: "One-off instructions to validate and estimate.") var instructions: String?
        @Option(name: .long) var provider: ProviderSelectionMode?
        @Option(name: .long, help: "Limit evidence to a repository ID; repeatable.") var repository: [String] = []
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let now = Date()
            let store = try storeOptions.makeStore()
            let settings = try storeOptions.makeSettingsStore().load()
            guard let (_, version) = try store.recipe(id: RecipeID(template)) else {
                throw ValidationError("Template '\(template)' was not found.")
            }
            let result = try ReportQueue().preview(
                store: store, settings: settings, recipeID: RecipeID(template),
                period: try IntelligenceCLI.period(period, now: now), cutoff: now,
                configuration: try effectiveConfiguration(
                    version: version, instructions: instructions, provider: provider,
                    repositories: repository))
            if outputOptions.json {
                try JSONOutput.write(ReportGenerationPreviewPayload(preview: result))
            } else {
                print(
                    "\(result.state.rawValue): \(result.evidenceCount) evidence items · \(result.serializedBytes) bytes · ~\(result.estimatedInputTokens) input tokens · \(result.providerMode.rawValue)"
                )
            }
        }
    }

    public struct List: ParsableCommand {
        @Option(name: .long) var since = "7d"
        @Option(name: .long) var limit = 50
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard (1...1_000).contains(limit) else { throw ValidationError("--limit must be 1...1000.") }
            let values = try storeOptions.makeStore().artifacts(
                since: Date().addingTimeInterval(-(try DateParsing.duration(since))), limit: limit
            )
            .filter { $0.type == .report }
            if outputOptions.json {
                try JSONOutput.write(ArtifactsPayload(artifacts: values.map(ArtifactListItem.init), nextCursor: nil))
            } else {
                for value in values {
                    print("\(value.id.rawValue)  \(value.recipeID.rawValue)  r\(value.revision)  \(value.createdAt.formatted(.iso8601))")
                }
            }
        }
    }

    public struct Show: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard let artifact = try storeOptions.makeStore().artifact(id: ArtifactID(identifier)), artifact.type == .report else {
                throw ValidationError("Report '\(identifier)' was not found.")
            }
            if outputOptions.json { try JSONOutput.write(ArtifactPayload(artifact: artifact)) } else { print(artifact.content) }
        }
    }

    public struct Copy: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws {
            guard let artifact = try storeOptions.makeStore().artifact(id: ArtifactID(identifier)), artifact.type == .report else {
                throw ValidationError("Report '\(identifier)' was not found.")
            }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/pbcopy")
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            pipe.fileHandleForWriting.write(Data(artifact.content.utf8))
            try pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ValidationError("pbcopy failed.") }
            print("Copied \(identifier).")
        }
    }

    private static func effectiveConfiguration(
        version: ReportRecipeVersion,
        instructions: String?,
        provider: ProviderSelectionMode?,
        repositories: [String]
    ) throws -> ReportRunConfiguration {
        ReportRunConfiguration(
            purpose: version.purpose, audience: version.audience,
            repositoryIDs: repositories.isEmpty ? version.repositoryIDs : repositories.map { RepositoryID($0) },
            groupNames: repositories.isEmpty ? version.groupNames : [],
            customFocus: try instructions.map(ReportRecipeValidator.customFocus) ?? version.customFocus,
            tone: version.tone, outputFormat: version.outputFormat,
            maximumCharacters: version.maximumCharacters, privacyProfile: version.privacyProfile,
            providerModeOverride: provider ?? version.providerModeOverride)
    }
}

public struct CollectionControl: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "collection",
        abstract: "Inspect, pause, or resume passive collection.",
        subcommands: [Status.self, Pause.self, Resume.self],
        defaultSubcommand: Status.self
    )
    public init() {}

    public struct Status: ParsableCommand {
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let paused = try storeOptions.makeSettingsStore().load().collectionPaused
            let store = try storeOptions.makeStore()
            let live = try store.liveCollectorStatus()
            let recordedReconciliation = try store.heartbeatObservedAt(service: "reconciliation")
            let collectorObservedAt = try store.collectorStatus().observedAt
            let lastFullReconciliation = recordedReconciliation ?? collectorObservedAt
            if outputOptions.json {
                try JSONOutput.write(
                    CollectionStatePayload(
                        paused: paused, live: live,
                        lastFullReconciliation: lastFullReconciliation))
            } else {
                print(paused ? "Collection is paused." : "Collection is running.")
                if let live {
                    print("Live collector: \(live.mode.rawValue)")
                    print("Pending: \(live.pendingTriggerCount) triggers, \(live.pendingPathCount) paths")
                    if let lastMutationAt = live.lastMutationAt {
                        print("Last mutation: \(DateParsing.iso8601(lastMutationAt))")
                    }
                    if let latency = live.lastLatencySeconds {
                        print("Last convergence: \(String(format: "%.3f", latency)) seconds")
                    }
                    if let latency = live.p95LatencySeconds {
                        print("P95 convergence: \(String(format: "%.3f", latency)) seconds")
                    }
                    if let error = live.lastError { print("Last error: \(error)") }
                } else {
                    print("Live collector: not started")
                }
                if let lastFullReconciliation {
                    print("Last full reconciliation: \(DateParsing.iso8601(lastFullReconciliation))")
                }
            }
        }
    }

    public struct Pause: ParsableCommand {
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws { try set(true, options: storeOptions) }
    }

    public struct Resume: ParsableCommand {
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws { try set(false, options: storeOptions) }
    }

    private static func set(_ paused: Bool, options: StoreOptions) throws {
        let paths = try options.makePaths()
        let store = SettingsStore(fileURL: paths.settingsURL)
        var settings = try store.load()
        settings.collectionPaused = paused
        try store.save(settings)
        TrackifyChangeSignal.post(for: paths.ledgerURL, kind: .settings)
        print(paused ? "Paused passive collection." : "Resumed passive collection.")
    }
}

public struct Bootstrap: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Inspect or apply a bounded first-run setup.",
        subcommands: [Inspect.self, Apply.self],
        defaultSubcommand: Inspect.self
    )

    public init() {}

    public struct Inspect: ParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Inspect sources and recommend primary repository groups.")
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let paths = try storeOptions.makePaths()
            let inspection = try BootstrapInspector().inspect(paths: paths, store: storeOptions.makeStore())
            if outputOptions.json {
                try JSONOutput.write(BootstrapInspectionPayload(inspection: inspection))
            } else {
                print("Data root: \(inspection.dataRoot)")
                for root in inspection.recommendedRoots {
                    print("Recommend \(root.suggestedName): \(root.path) (\(root.repositoryCount) repositories)")
                }
                if inspection.recommendedRoots.isEmpty { print("No new primary roots recommended.") }
                print("History: \(inspection.backfillPlan.historyFiles) files, \(inspection.backfillPlan.historyBytes) bytes")
                print(
                    "Initial summaries: at most \(inspection.backfillPlan.maximumProviderCalls) provider calls; inactive periods use none")
            }
        }
    }

    public struct Apply: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Apply recommended roots, provider selection, and bounded backfill.")

        @Option(name: .long, help: "Summary/report provider: auto, codex, claude, or local.")
        var provider = "auto"
        @Option(name: .long, help: "Evidence backfill policy. V1 supports all or none.")
        var backfillEvidence = "all"
        @Option(name: .long, help: "Historical summary window such as 7d, or none.")
        var backfillSummaries = "none"
        @Flag(name: .long, help: "Use the selected LLM for automatic summaries.")
        var enableAISummaries = false
        @Flag(name: .long, help: "Confirm the inspected historical summary plan.")
        var confirmSummaryBackfill = false
        @Flag(name: .long, help: "Launch Trackify after setup.")
        var launch = false
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public mutating func run() async throws {
            guard ["all", "none"].contains(backfillEvidence) else {
                throw ValidationError("--backfill-evidence must be all or none.")
            }
            let paths = try storeOptions.makePaths()
            let store = try storeOptions.makeStore()
            let inspection = try BootstrapInspector().inspect(paths: paths, store: store)
            let manager = DiscoveryRootManager()
            var addedRoots: [DiscoveryRoot] = []
            for recommendation in inspection.recommendedRoots {
                addedRoots.append(
                    try manager.add(
                        path: URL(filePath: recommendation.path),
                        name: recommendation.suggestedName,
                        store: store
                    ))
            }

            let settingsStore = try storeOptions.makeSettingsStore()
            var settings = try settingsStore.load()
            settings.providerSelection = try selectedMode(provider)
            settings.automaticSummariesUseLLM = enableAISummaries
            let temporarilyPauseCollection = launch && !settings.collectionPaused
            if temporarilyPauseCollection { settings.collectionPaused = true }
            try settingsStore.save(settings)
            if launch { try launchApplication() }

            var collection: LocalCollectionResult?
            let generatedSummaries: Int
            do {
                if backfillEvidence == "all" {
                    let roots = try store.discoveryRoots(enabledOnly: true).map {
                        GitCollectionRoot(
                            path: URL(filePath: $0.canonicalPath),
                            discoveryRootID: $0.id,
                            excludedPaths: Set($0.excludedPaths)
                        )
                    }
                    collection = try await LocalCollectionCoordinator().collect(
                        store: store,
                        gitRoots: roots,
                        hookInboxURL: paths.hookInboxURL
                    )
                }
                generatedSummaries = try await generateRecentSummaries(
                    backfillSummaries,
                    store: store,
                    settings: settings,
                    confirmed: confirmSummaryBackfill
                )
                if temporarilyPauseCollection {
                    settings.collectionPaused = false
                    try settingsStore.save(settings)
                }
            } catch {
                if temporarilyPauseCollection {
                    settings.collectionPaused = false
                    try? settingsStore.save(settings)
                }
                throw error
            }

            let payload = BootstrapApplyPayload(
                addedRoots: addedRoots,
                selectedProvider: settings.providerSelection.explicitProvider,
                providerSelection: settings.providerSelection,
                automaticSummariesUseLLM: settings.automaticSummariesUseLLM,
                collection: collection,
                generatedSummaries: generatedSummaries,
                launched: launch
            )
            if outputOptions.json {
                try JSONOutput.write(payload)
            } else {
                print(
                    "Configured \(try store.discoveryRoots().count) roots and \(settings.providerSelection.rawValue) generation mode."
                )
                print("Generated \(generatedSummaries) recent summary revisions.")
            }
        }

        private func selectedMode(_ value: String) throws -> ProviderSelectionMode {
            switch value.lowercased() {
            case "auto", "automatic": .automatic
            case "codex": .codex
            case "claude": .claude
            case "local", "local-only", "local_only": .localOnly
            default: throw ValidationError("--provider must be auto, codex, claude, or local.")
            }
        }

        private func generateRecentSummaries(
            _ value: String,
            store: LedgerStore,
            settings: TrackifySettings,
            confirmed: Bool
        ) async throws -> Int {
            guard value != "none" else { return 0 }
            guard confirmed else {
                throw ValidationError(
                    "Historical summaries require --confirm-summary-backfill after inspecting `trackify bootstrap inspect`.")
            }
            let duration = try DateParsing.duration(value)
            guard duration <= 14 * 86_400 else {
                throw ValidationError("Initial summary backfill is capped at 14 days to bound provider usage.")
            }
            let now = Date()
            let days = max(1, Int(ceil(duration / 86_400)))
            let result = await SummaryCoordinator().refresh(
                store: store, settings: settings, now: now, lookbackDays: days)
            guard result.issues.isEmpty else {
                throw ValidationError(result.issues.joined(separator: " "))
            }
            return result.generated.count
        }

        private func launchApplication() throws {
            let app = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Trackify.app")
            let arguments = FileManager.default.fileExists(atPath: app.path) ? [app.path] : ["-a", "Trackify"]
            let output = try ProcessRunner().run(
                executable: URL(filePath: "/usr/bin/open"),
                arguments: arguments,
                workingDirectory: nil,
                environment: nil,
                outputLimit: 64 * 1_024
            )
            guard output.status == 0 else {
                throw ProcessRunnerError.failed(executable: "/usr/bin/open", status: output.status, output: output.utf8)
            }
        }
    }
}

public struct Integrations: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Inspect or receive optional provider lifecycle hooks.",
        subcommands: [Status.self, Emit.self],
        defaultSubcommand: Status.self
    )

    public init() {}

    public struct Status: ParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Show the local hook inbox status.")
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let url = try storeOptions.makePaths().hookInboxURL
            let exists = FileManager.default.fileExists(atPath: url.path)
            let payload = IntegrationStatusPayload(inboxPath: url.path, inboxExists: exists)
            if outputOptions.json {
                try JSONOutput.write(payload)
            } else {
                print("Hook inbox: \(url.path)")
                print("State: \(exists ? "receiving events" : "not yet used")")
                print("Durable Codex and Claude cache collection remains enabled independently.")
            }
        }
    }

    public struct Emit: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Append one bounded lifecycle event. Intended for provider hooks."
        )

        @Argument(help: "Provider: codex or claude.")
        var provider: String
        @Option(name: .long, help: "Provider session identifier.")
        var session: String
        @Option(name: .long, help: "Provider turn identifier.")
        var turn: String
        @Option(name: .long, help: "Lifecycle phase.")
        var phase: HookPhase
        @Option(name: .long, help: "ISO-8601 occurrence time; defaults to now.")
        var at: String?
        @Option(name: .long, help: "Optional working directory.")
        var cwd: String?
        @OptionGroup var storeOptions: StoreOptions

        public init() {}

        public func run() throws {
            guard let source = SourceKind(rawValue: provider), source == .codex || source == .claude else {
                throw ValidationError("Provider must be codex or claude.")
            }
            let occurredAt: Date
            if let at {
                guard let parsed = try? Date(at, strategy: .iso8601) else {
                    throw ValidationError("--at must be an ISO-8601 instant.")
                }
                occurredAt = parsed
            } else {
                occurredAt = Date()
            }
            try HookInboxWriter().append(
                HookEnvelope(
                    source: source,
                    sessionID: session,
                    turnID: turn,
                    phase: phase,
                    occurredAt: occurredAt,
                    workingDirectory: cwd
                ),
                to: try storeOptions.makePaths().hookInboxURL
            )
        }
    }
}

public struct ReportCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Generate an honest report from ledger evidence."
    )

    @Flag(name: .long, help: "Generate the report for today. This is the V1 default.")
    var today = false

    @Flag(name: .long, help: "Inspect the bounded local evidence compilation without saving a report or calling a provider.")
    var preview = false

    @Option(name: .long, help: "Preview the local clock hour containing this ISO-8601 instant.")
    var previewHour: String?

    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions

    public init() {}

    public mutating func run() async throws {
        let now = Date()
        let store = try storeOptions.makeStore()
        let range: DateInterval
        if let previewHour {
            guard preview else { throw ValidationError("--preview-hour requires --preview.") }
            guard let instant = try? Date(previewHour, strategy: .iso8601),
                let hour = Calendar.current.dateInterval(of: .hour, for: instant)
            else {
                throw ValidationError("--preview-hour must be an ISO-8601 instant.")
            }
            range = hour
        } else {
            range = DateParsing.localDay(containing: now)
        }
        if preview {
            let packet = try ReportGenerator().evidencePacket(
                store: store,
                range: range,
                cutoff: previewHour == nil ? now : range.end
            )
            let payload = ReportPacketPreviewPayload(packet: packet)
            if outputOptions.json {
                try JSONOutput.write(payload)
            } else {
                print("Evidence compiler: \(packet.selection.compilerVersion)")
                print("Period state: \(packet.state.rawValue)")
                print(
                    "Selected: \(packet.selection.selectedEventCount)/\(packet.selection.totalEventCount) events across \(packet.selection.representedContextCount)/\(packet.selection.activeContextCount) contexts"
                )
                print(
                    "Prior summaries: \(packet.selection.selectedPriorSummaryCount); quiet omitted: \(packet.selection.omittedQuietSummaryCount)"
                )
                print("Provider packet: \(packet.serializedByteCount) bytes; approximately \(packet.estimatedInputTokens) input tokens")
            }
            return
        }
        let settings = try storeOptions.makeSettingsStore().load()
        let queue = ReportQueue()
        let run = try queue.enqueueOnDemand(
            store: store, settings: settings, recipeID: RecipeID("daily-work-summary"),
            period: range, now: now)
        _ = await queue.drain(store: store, settings: settings, maximumRuns: 20)
        guard let completedRun = try store.reportRun(id: run.id),
            let artifactID = completedRun.artifactID,
            let artifact = try store.artifact(id: artifactID)
        else { throw ValidationError("The report is still queued. Run `trackify artifacts list` shortly.") }
        if outputOptions.json {
            try JSONOutput.write(ArtifactPayload(artifact: artifact))
        } else {
            print("[\(artifact.state.rawValue)] \(artifact.content)")
        }
    }
}

public struct Providers: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Inspect and select summary and report providers.",
        subcommands: [List.self, Status.self, Use.self, Test.self],
        defaultSubcommand: Status.self
    )

    public init() {}

    public struct List: ParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "List supported generation providers.")
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws { try ProviderOutput.run(storeOptions: storeOptions, json: outputOptions.json) }
    }

    public struct Status: ParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Show provider health and current selection.")
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws { try ProviderOutput.run(storeOptions: storeOptions, json: outputOptions.json) }
    }

    public struct Use: ParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Select the CLI used for summaries and reports.")

        @Argument(help: "Mode: automatic, codex, claude, or local.")
        var provider: String

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            let settingsStore = try storeOptions.makeSettingsStore()
            var settings = try settingsStore.load()
            let mode: ProviderSelectionMode
            switch provider.lowercased() {
            case "automatic": mode = .automatic
            case "codex": mode = .codex
            case "claude": mode = .claude
            case "local", "local-only", "local_only": mode = .localOnly
            default: throw ValidationError("Mode must be automatic, codex, claude, or local.")
            }
            settings.providerSelection = mode
            try settingsStore.save(settings)
            if outputOptions.json {
                try JSONOutput.write(ProviderSelectionPayload(selected: mode))
            } else {
                print("Selected \(mode.rawValue) for summaries and reports.")
            }
        }
    }

    public struct Test: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Send a tiny synthetic payload and record a provider test run.")
        @Argument var provider: SummaryProviderID
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() async throws {
            let store = try storeOptions.makeStore()
            let settings = try storeOptions.makeSettingsStore().load()
            let run = try await ReportQueue().testProvider(
                provider, store: store, settings: settings, now: Date())
            if outputOptions.json {
                try JSONOutput.write(ReportRunPayload(run: run))
            } else {
                print("\(provider.rawValue): \(run.state.rawValue)")
                print("Synthetic payload only; \(run.usage.knownTokenTotal.map(String.init) ?? "usage unavailable") tokens reported.")
            }
        }
    }
}

public struct SourcesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sources", abstract: "Inspect local history-source capabilities.",
        subcommands: [Status.self], defaultSubcommand: Status.self)
    public init() {}

    public struct Status: ParsableCommand {
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let store = try storeOptions.makeStore()
            let sources = CapabilityDiscovery().sources(store: store)
            if outputOptions.json {
                try JSONOutput.write(SourcesPayload(sources: sources))
            } else {
                for source in sources {
                    print(
                        "\(source.surface): \(source.state.rawValue) · \(source.importedRecordCount) \(source.family) records in ledger"
                    )
                    print("  \(source.location)")
                    if let importedAt = source.lastSuccessfulImportAt {
                        print("  Last import: \(ISO8601DateFormatter().string(from: importedAt))")
                    }
                    if let detail = source.detail { print("  \(detail)") }
                }
            }
        }
    }
}

public struct UsageCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "usage", abstract: "Inspect Trackify-initiated model usage.",
        subcommands: [Budget.self, Configure.self, Today.self, Month.self, Runs.self, Cancel.self])
    public init() {}

    public struct Budget: ParsableCommand {
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let store = try storeOptions.makeStore()
            let settings = try storeOptions.makeSettingsStore().load()
            let capabilities = CapabilityDiscovery().generators(store: store)
            let provider = CapabilityDiscovery().effectiveProvider(
                mode: settings.providerSelection, capabilities: capabilities)
            let status = try GenerationBudgetController().status(
                store: store, budgets: settings.generationBudgets,
                provider: provider, now: Date())
            if outputOptions.json {
                try JSONOutput.write(UsageBudgetPayload(status: status))
                return
            }
            if let allowance = status.allowance {
                print(
                    "Codex weekly allowance: \(allowance.remainingPercent)% left"
                        + (allowance.resetsAt.map {
                            " · resets \(DateParsing.iso8601($0))"
                        } ?? ""))
                print(
                    "Trackify-attributed allowance: \(status.allowanceAttributedPercent)%"
                        + (status.allowancePercentLimit.map { " / \($0)%" } ?? ""))
            } else {
                print("Provider allowance: unavailable; using Trackify-owned credit safeguards")
            }
            print(
                "Estimated weekly credits: \(status.estimatedCreditsUsed)"
                    + (status.weeklyCreditLimit.map { " / \($0)" } ?? ""))
            print("Calls today: \(status.callsToday) / \(status.callsPerDayLimit)")
            print(status.isPaused ? "Automatic generation paused: \(status.pauseReason ?? "budget")" : "Automatic generation: available")
        }
    }

    public struct Configure: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Configure automatic summary and report budget safeguards.")

        @Flag(name: .long, help: "Restore the recommended budget policy.") var defaults = false
        @Option(name: .long, help: "Maximum Trackify-attributed share of the provider's weekly allowance.")
        var weeklyPercent: Int?
        @Option(name: .long, help: "Weekly equivalent-credit safeguard.") var weeklyCredits: Int?
        @Option(name: .long, help: "Provider allowance kept in reserve for the user's own work.")
        var minimumProviderRemaining: Int?
        @Option(name: .long, help: "Maximum automatic provider calls per day.") var callsPerDay: Int?
        @Option(name: .long, help: "Maximum estimated input tokens for one call.") var tokensPerCall: Int?
        @Option(name: .long, help: "Maximum provider input bytes for one call.") var inputBytesPerCall: Int?
        @Option(name: .long, help: "Daily token ceiling across Trackify calls.") var dailyTokens: Int?
        @Option(name: .long, help: "Monthly token ceiling across Trackify calls.") var monthlyTokens: Int?
        @Option(name: .long, help: "Output tokens reserved during preflight estimation.") var outputReserveTokens: Int?
        @Option(name: .long, help: "Provider process deadline in seconds.") var deadlineSeconds: Int?
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            guard defaults || hasOverride else {
                throw ValidationError("Pass at least one budget option or --defaults.")
            }

            let settingsStore = try storeOptions.makeSettingsStore()
            var settings = try settingsStore.load()
            var budgets = defaults ? GenerationBudgets() : settings.generationBudgets
            if let weeklyPercent { budgets.weeklyAllowancePercentLimit = weeklyPercent }
            if let weeklyCredits { budgets.weeklyCreditLimit = Decimal(weeklyCredits) }
            if let minimumProviderRemaining {
                budgets.minimumProviderAllowanceRemainingPercent = minimumProviderRemaining
            }
            if let callsPerDay { budgets.maximumCallsPerDay = callsPerDay }
            if let tokensPerCall { budgets.maximumEstimatedInputTokensPerCall = tokensPerCall }
            if let inputBytesPerCall { budgets.maximumInputBytesPerCall = inputBytesPerCall }
            if let dailyTokens { budgets.dailyTokenLimit = dailyTokens }
            if let monthlyTokens { budgets.monthlyTokenLimit = monthlyTokens }
            if let outputReserveTokens { budgets.estimatedOutputTokensPerCall = outputReserveTokens }
            if let deadlineSeconds { budgets.processDeadlineSeconds = deadlineSeconds }
            settings.generationBudgets = budgets.normalized()
            try settingsStore.save(settings)

            if outputOptions.json {
                try JSONOutput.write(
                    UsageBudgetConfigurationPayload(budgets: settings.generationBudgets))
            } else {
                print("Saved automatic generation budget policy.")
                print(
                    "Weekly allowance target: "
                        + (settings.generationBudgets.weeklyAllowancePercentLimit.map { "\($0)%" }
                            ?? "disabled"))
                print(
                    "Weekly credit safeguard: "
                        + (settings.generationBudgets.weeklyCreditLimit.map {
                            String(describing: $0)
                        } ?? "disabled"))
                print("Calls per day: \(settings.generationBudgets.maximumCallsPerDay)")
                print(
                    "Estimated input tokens per call: "
                        + "\(settings.generationBudgets.maximumEstimatedInputTokensPerCall)")
            }
        }

        private var hasOverride: Bool {
            weeklyPercent != nil || weeklyCredits != nil || minimumProviderRemaining != nil
                || callsPerDay != nil || tokensPerCall != nil || inputBytesPerCall != nil
                || dailyTokens != nil || monthlyTokens != nil || outputReserveTokens != nil
                || deadlineSeconds != nil
        }
    }

    public struct Today: ParsableCommand {
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let interval = Calendar.current.dateInterval(of: .day, for: Date())!
            try UsageOutput.write(store: storeOptions.makeStore(), interval: interval, json: outputOptions.json)
        }
    }

    public struct Month: ParsableCommand {
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let interval = Calendar.current.dateInterval(of: .month, for: Date())!
            try UsageOutput.write(store: storeOptions.makeStore(), interval: interval, json: outputOptions.json)
        }
    }

    public struct Runs: ParsableCommand {
        @Option(name: .long, help: "Lookback duration such as 7d or 24h.") var since = "7d"
        @Option(name: .long, help: "Maximum rows (1...1000).") var limit = 200
        @Option(name: .long, help: "Opaque cursor returned by the previous page.") var cursor: String?
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard (1...1_000).contains(limit) else { throw ValidationError("--limit must be 1...1000.") }
            let start = Date().addingTimeInterval(-(try DateParsing.duration(since)))
            let page = try cursor.map(PageCursor.decode)
            let runs = try storeOptions.makeStore().reportRuns(
                since: start, before: page?.date,
                beforeID: page.map { ReportRunID($0.id) }, limit: limit)
            let nextCursor =
                runs.count == limit
                ? runs.last.map { PageCursor.encode(date: $0.queuedAt, id: $0.id.rawValue) }
                : nil
            if outputOptions.json {
                try JSONOutput.write(ReportRunsPayload(runs: runs, nextCursor: nextCursor))
            } else {
                for run in runs {
                    print(
                        "\(run.id.rawValue)  \(run.state.rawValue)  \(run.effectiveProvider?.rawValue ?? "local")  \(run.usage.knownTokenTotal ?? 0) tokens"
                    )
                }
                if let nextCursor { print("Next cursor: \(nextCursor)") }
            }
        }
    }

    public struct Cancel: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let cancelled = try storeOptions.makeStore().cancelReportRun(
                id: ReportRunID(identifier), at: Date())
            guard cancelled else { throw ValidationError("Run is not pending or running.") }
            if outputOptions.json {
                try JSONOutput.write(CancelRunPayload(runID: ReportRunID(identifier), cancelled: true))
            } else {
                print("Cancelled \(identifier).")
            }
        }
    }
}

public struct RecipesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "recipes", abstract: "Manage versioned report templates.",
        subcommands: [
            List.self, Show.self, Create.self, Update.self, Duplicate.self,
            Enable.self, Disable.self, Preview.self, Backfill.self,
        ])
    public init() {}

    public struct List: ParsableCommand {
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let recipes = try storeOptions.makeStore().recipes()
            if outputOptions.json {
                try JSONOutput.write(RecipesPayload(recipes: recipes))
            } else {
                for recipe in recipes {
                    print("\(recipe.id.rawValue)  \(recipe.name)  \(recipe.currentVersionID.rawValue)")
                }
            }
        }
    }

    public struct Show: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard let value = try storeOptions.makeStore().recipe(id: RecipeID(identifier)) else {
                throw ValidationError("Recipe '\(identifier)' was not found.")
            }
            if outputOptions.json {
                try JSONOutput.write(RecipePayload(recipe: value.0, version: value.1))
            } else {
                print("\(value.0.name) · version \(value.1.version)")
                print("\(value.1.purpose)\nPrivacy: \(value.1.privacyProfile.rawValue) · \(value.1.cadence.rawValue)")
            }
        }
    }

    public struct Create: ParsableCommand {
        @Option(name: .long, help: "Path to a versioned JSON recipe definition.") var from: String
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let definition = try JSONDecoder().decode(RecipeDefinition.self, from: Data(contentsOf: URL(filePath: from)))
            let store = try storeOptions.makeStore()
            let version = try store.createRecipeVersion(
                recipeID: RecipeID(definition.id), name: definition.name,
                purpose: definition.purpose, audience: definition.audience,
                cadence: definition.cadence,
                repositoryIDs: definition.repositoryIDs.map { RepositoryID($0) },
                groupNames: definition.groupNames, customFocus: definition.customFocus,
                tone: definition.tone, outputFormat: definition.outputFormat,
                maximumCharacters: definition.maximumCharacters,
                privacyProfile: definition.privacyProfile,
                providerModeOverride: definition.providerModeOverride, now: Date())
            let recipe = try store.recipe(id: RecipeID(definition.id))!.0
            if outputOptions.json {
                try JSONOutput.write(RecipePayload(recipe: recipe, version: version))
            } else {
                print("Saved \(recipe.id.rawValue) version \(version.version).")
            }
        }
    }

    public struct Update: ParsableCommand {
        @Argument var identifier: String
        @Option(name: .long, help: "Path to a JSON recipe definition containing the new version.") var from: String
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let store = try storeOptions.makeStore()
            guard let (recipe, _) = try store.recipe(id: RecipeID(identifier)) else {
                throw ValidationError("Recipe '\(identifier)' was not found.")
            }
            guard !recipe.isBuiltIn else {
                throw ValidationError("Built-in templates are immutable. Duplicate it first.")
            }
            let definition = try JSONDecoder().decode(
                RecipeDefinition.self, from: Data(contentsOf: URL(filePath: from)))
            let version = try save(definition, as: RecipeID(identifier), store: store)
            let updated = try store.recipe(id: RecipeID(identifier))!.0
            if outputOptions.json {
                try JSONOutput.write(RecipePayload(recipe: updated, version: version))
            } else {
                print("Saved \(identifier) version \(version.version).")
            }
        }
    }

    public struct Duplicate: ParsableCommand {
        @Argument var identifier: String
        @Option(name: .long, help: "ID for the new custom template.") var id: String
        @Option(name: .long, help: "Optional display name.") var name: String?
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let store = try storeOptions.makeStore()
            guard let (source, version) = try store.recipe(id: RecipeID(identifier)) else {
                throw ValidationError("Recipe '\(identifier)' was not found.")
            }
            let created = try store.createRecipeVersion(
                recipeID: RecipeID(id), name: name ?? "\(source.name) Copy",
                purpose: version.purpose, audience: version.audience, cadence: .onDemand,
                repositoryIDs: version.repositoryIDs, groupNames: version.groupNames,
                customFocus: version.customFocus, tone: version.tone,
                outputFormat: version.outputFormat, maximumCharacters: version.maximumCharacters,
                privacyProfile: version.privacyProfile,
                providerModeOverride: version.providerModeOverride, now: Date())
            let recipe = try store.recipe(id: RecipeID(id))!.0
            if outputOptions.json {
                try JSONOutput.write(RecipePayload(recipe: recipe, version: created))
            } else {
                print("Created \(id) from \(identifier).")
            }
        }
    }

    public struct Enable: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws {
            try storeOptions.makeStore().setRecipeEnabled(true, id: RecipeID(identifier))
            print("Enabled \(identifier).")
        }
    }

    public struct Disable: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws {
            try storeOptions.makeStore().setRecipeEnabled(false, id: RecipeID(identifier))
            print("Disabled \(identifier).")
        }
    }

    public struct Preview: ParsableCommand {
        @Argument var identifier: String
        @Option(name: .long, help: "today, yesterday, last-hour, or YYYY-MM-DD.") var period = "today"
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            let now = Date()
            let interval = try IntelligenceCLI.period(period, now: now)
            let store = try storeOptions.makeStore()
            guard let (_, recipe) = try store.recipe(id: RecipeID(identifier)) else {
                throw ValidationError("Recipe '\(identifier)' was not found.")
            }
            let repositoryIDs = try ReportScopeResolver().repositoryIDs(store: store, recipe: recipe)
            let packet = try ReportRecipePolicy().apply(
                ReportGenerator().evidencePacket(
                    store: store, range: interval, cutoff: min(now, interval.end),
                    repositoryIDs: repositoryIDs),
                recipe: recipe, scopedRepositoryIDs: repositoryIDs)
            let payload = ReportPacketPreviewPayload(packet: packet)
            if outputOptions.json {
                try JSONOutput.write(payload)
            } else {
                print("\(recipe.id.rawValue) v\(recipe.version): \(packet.state.rawValue)")
                print(
                    "\(packet.selection.selectedEventCount) selected · \(packet.serializedByteCount) bytes · ~\(packet.estimatedInputTokens) tokens"
                )
            }
        }
    }

    public struct Backfill: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Preview or explicitly enqueue bounded historical model reports.")
        @Argument var identifier: String
        @Option(name: .long, help: "Lookback duration, limited to 14 days.") var since = "7d"
        @Flag(name: .long, help: "Confirm the displayed bounded model-use plan.") var confirm = false
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() async throws {
            let now = Date()
            let duration = try DateParsing.duration(since)
            let days = Int(ceil(duration / 86_400))
            guard (1...14).contains(days) else { throw ValidationError("--since must cover 1...14 days.") }
            let today = DateParsing.localDay(containing: now)
            let periods = (1...days).reversed().map { offset -> DateInterval in
                let end = Calendar.current.date(byAdding: .day, value: -offset + 1, to: today.start)!
                let start = Calendar.current.date(byAdding: .day, value: -1, to: end)!
                return DateInterval(start: start, end: end)
            }
            let store = try storeOptions.makeStore()
            let settings = try storeOptions.makeSettingsStore().load()
            let queue = ReportQueue()
            let plan = try queue.backfillPlan(
                store: store, recipeID: RecipeID(identifier), periods: periods, cutoff: now,
                providerMode: settings.providerSelection)
            guard confirm else {
                if outputOptions.json {
                    try JSONOutput.write(ModelBackfillPlanPayload(plan: plan, confirmed: false))
                } else {
                    print(
                        "Preview only: \(plan.activePeriods) active periods, up to \(plan.maximumCalls) calls, ~\(plan.estimatedInputTokens) input tokens."
                    )
                    print("Run again with --confirm to enqueue model backfill.")
                }
                return
            }
            let runs = try queue.enqueueBackfill(
                store: store, settings: settings, recipeID: RecipeID(identifier),
                periods: periods, now: now, confirmed: true)
            let result = await queue.drain(store: store, settings: settings, maximumRuns: min(20, periods.count))
            if outputOptions.json {
                try JSONOutput.write(
                    ModelBackfillResultPayload(plan: plan, runs: runs.map(\.id), artifacts: result.completed))
            } else {
                print("Enqueued \(runs.count) periods; stored \(result.completed.count) artifacts.")
            }
        }
    }

    private static func save(
        _ definition: RecipeDefinition, as id: RecipeID, store: LedgerStore
    ) throws -> ReportRecipeVersion {
        try store.createRecipeVersion(
            recipeID: id, name: definition.name, purpose: definition.purpose,
            audience: definition.audience, cadence: definition.cadence,
            repositoryIDs: definition.repositoryIDs.map { RepositoryID($0) },
            groupNames: definition.groupNames, customFocus: definition.customFocus,
            tone: definition.tone, outputFormat: definition.outputFormat,
            maximumCharacters: definition.maximumCharacters,
            privacyProfile: definition.privacyProfile,
            providerModeOverride: definition.providerModeOverride, now: Date())
    }
}

public struct ReportersCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reporters",
        abstract: "Manage scheduled report generation independently from templates.",
        subcommands: [List.self, Show.self, Create.self, Update.self, Enable.self, Disable.self, Delete.self]
    )

    public init() {}

    public struct List: ParsableCommand {
        @Flag(name: .long, help: "Only include enabled reporters.") var enabledOnly = false
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            let reporters = try storeOptions.makeStore().reportSchedules(enabledOnly: enabledOnly)
            if outputOptions.json {
                try JSONOutput.write(ReportersPayload(reporters: reporters))
            } else if reporters.isEmpty {
                print("No scheduled reporters configured.")
            } else {
                for reporter in reporters {
                    let state = reporter.isEnabled ? "enabled" : "disabled"
                    let scope =
                        reporter.repositoryIDs.isEmpty
                        ? "all projects"
                        : reporter.repositoryIDs.map(\.rawValue).joined(separator: ",")
                    print(
                        "\(reporter.id.rawValue)  \(reporter.name)  \(reporter.cadence.rawValue)  \(state)  \(scope)"
                    )
                }
            }
        }
    }

    public struct Show: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            guard let reporter = try storeOptions.makeStore().reportSchedule(id: ReportScheduleID(identifier)) else {
                throw ValidationError("Reporter '\(identifier)' was not found.")
            }
            if outputOptions.json {
                try JSONOutput.write(ReporterPayload(reporter: reporter))
            } else {
                print(reporter.name)
                print("Template: \(reporter.recipeID.rawValue)")
                print("Cadence: \(reporter.cadence.rawValue)")
                print("State: \(reporter.isEnabled ? "enabled" : "disabled")")
                print(
                    "Projects: \(reporter.repositoryIDs.isEmpty ? "all" : reporter.repositoryIDs.map(\.rawValue).joined(separator: ", "))"
                )
                print("Provider: \(reporter.providerModeOverride?.rawValue ?? "app default")")
            }
        }
    }

    public struct Create: ParsableCommand {
        @Option(name: .long, help: "Stable reporter ID. Generated from the name when omitted.") var id: String?
        @Option(name: .long, help: "Display name.") var name: String
        @Option(name: .long, help: "Report template ID.") var template: String
        @Option(name: .long, help: "hourly or daily.") var cadence: ReportScheduleCadence
        @Option(name: .long, help: "Limit to a repository ID; repeatable.") var repository: [String] = []
        @Option(name: .long, help: "automatic, codex, claude, or local-only.") var provider: ProviderSelectionMode?
        @Flag(name: .long, help: "Create the reporter disabled.") var disabled = false
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            let store = try storeOptions.makeStore()
            guard try store.recipe(id: RecipeID(template)) != nil else {
                throw ValidationError("Template '\(template)' was not found.")
            }
            let identifier = ReportScheduleID(id ?? Self.generatedIdentifier(name: name))
            guard try store.reportSchedule(id: identifier) == nil else {
                throw ValidationError("Reporter '\(identifier.rawValue)' already exists.")
            }
            let reporter = try store.saveReportSchedule(
                id: identifier,
                draft: ReportScheduleDraft(
                    name: name, recipeID: RecipeID(template), cadence: cadence,
                    repositoryIDs: repository.map { RepositoryID($0) },
                    providerModeOverride: provider, isEnabled: !disabled),
                now: Date())
            if outputOptions.json {
                try JSONOutput.write(ReporterPayload(reporter: reporter))
            } else {
                print("Created \(reporter.id.rawValue).")
            }
        }

        private static func generatedIdentifier(name: String) -> String {
            let slug = name.lowercased().unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
            }
            let normalized = String(slug).split(separator: "-").joined(separator: "-")
            let base = normalized.isEmpty ? "reporter" : normalized
            return "\(base)-\(UUID().uuidString.lowercased().prefix(6))"
        }
    }

    public struct Update: ParsableCommand {
        @Argument var identifier: String
        @Option(name: .long) var name: String?
        @Option(name: .long, help: "Report template ID.") var template: String?
        @Option(name: .long) var cadence: ReportScheduleCadence?
        @Option(name: .long, help: "Replace scope with these repository IDs; repeatable.") var repository: [String] = []
        @Flag(name: .long, help: "Replace repository scope with all projects.") var allProjects = false
        @Option(name: .long) var provider: ProviderSelectionMode?
        @Flag(name: .long, help: "Use the app default provider selection.") var appDefaultProvider = false
        @Option(name: .long, help: "Set true or false.") var enabled: Bool?
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            guard !(allProjects && !repository.isEmpty) else {
                throw ValidationError("Use either --all-projects or --repository, not both.")
            }
            guard !(appDefaultProvider && provider != nil) else {
                throw ValidationError("Use either --app-default-provider or --provider, not both.")
            }
            let store = try storeOptions.makeStore()
            let id = ReportScheduleID(identifier)
            guard let current = try store.reportSchedule(id: id) else {
                throw ValidationError("Reporter '\(identifier)' was not found.")
            }
            let recipeID = RecipeID(template ?? current.recipeID.rawValue)
            guard try store.recipe(id: recipeID) != nil else {
                throw ValidationError("Template '\(recipeID.rawValue)' was not found.")
            }
            let repositories: [RepositoryID]
            if allProjects {
                repositories = []
            } else if !repository.isEmpty {
                repositories = repository.map { RepositoryID($0) }
            } else {
                repositories = current.repositoryIDs
            }
            let updated = try store.saveReportSchedule(
                id: id,
                draft: ReportScheduleDraft(
                    name: name ?? current.name, recipeID: recipeID,
                    cadence: cadence ?? current.cadence, repositoryIDs: repositories,
                    groupNames: current.groupNames,
                    providerModeOverride: appDefaultProvider ? nil : (provider ?? current.providerModeOverride),
                    isEnabled: enabled ?? current.isEnabled),
                now: Date())
            if outputOptions.json {
                try JSONOutput.write(ReporterPayload(reporter: updated))
            } else {
                print("Updated \(identifier).")
            }
        }
    }

    public struct Enable: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws {
            try storeOptions.makeStore().setReportScheduleEnabled(true, id: ReportScheduleID(identifier), now: Date())
            print("Enabled \(identifier).")
        }
    }

    public struct Disable: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws {
            try storeOptions.makeStore().setReportScheduleEnabled(false, id: ReportScheduleID(identifier), now: Date())
            print("Disabled \(identifier).")
        }
    }

    public struct Delete: ParsableCommand {
        @Argument var identifier: String
        @Flag(name: .long, help: "Confirm deletion of this reporter. Existing reports remain.") var confirm = false
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard confirm else { throw ValidationError("Pass --confirm to delete this reporter.") }
            try storeOptions.makeStore().deleteReportSchedule(id: ReportScheduleID(identifier))
            if outputOptions.json {
                try JSONOutput.write(DeleteReporterPayload(identifier: identifier))
            } else {
                print("Deleted \(identifier). Existing report history was preserved.")
            }
        }
    }
}

public struct ArtifactsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "artifacts", abstract: "Inspect and export immutable report artifacts.",
        subcommands: [List.self, Show.self, Export.self, Copy.self])
    public init() {}

    public struct List: ParsableCommand {
        @Option(name: .long) var since = "7d"
        @Option(name: .long) var limit = 200
        @Option(name: .long, help: "Opaque cursor returned by the previous page.") var cursor: String?
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard (1...1_000).contains(limit) else { throw ValidationError("--limit must be 1...1000.") }
            let page = try cursor.map(PageCursor.decode)
            let values = try storeOptions.makeStore().artifacts(
                since: Date().addingTimeInterval(-(try DateParsing.duration(since))),
                before: page?.date, beforeID: page.map { ArtifactID($0.id) }, limit: limit)
            let nextCursor =
                values.count == limit
                ? values.last.map { PageCursor.encode(date: $0.createdAt, id: $0.id.rawValue) }
                : nil
            if outputOptions.json {
                try JSONOutput.write(
                    ArtifactsPayload(
                        artifacts: values.map(ArtifactListItem.init), nextCursor: nextCursor)
                )
            } else {
                for artifact in values {
                    print(
                        "\(artifact.id.rawValue)  \(artifact.recipeID.rawValue)  \(artifact.state.rawValue)  r\(artifact.revision)"
                    )
                }
                if let nextCursor { print("Next cursor: \(nextCursor)") }
            }
        }
    }

    public struct Show: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard let artifact = try storeOptions.makeStore().artifact(id: ArtifactID(identifier)) else {
                throw ValidationError("Artifact '\(identifier)' was not found.")
            }
            if outputOptions.json {
                try JSONOutput.write(ArtifactPayload(artifact: artifact))
            } else {
                print(artifact.content)
                print(
                    "\nRecipe: \(artifact.recipeVersionID.rawValue) · \(artifact.privacyProfile.rawValue) · revision \(artifact.revision)")
                print("Evidence: \(artifact.evidenceIDs.count) · Run: \(artifact.reportRunID?.rawValue ?? "legacy")")
            }
        }
    }

    public struct Export: ParsableCommand {
        @Argument var identifier: String
        @Option(name: .long, help: "markdown or json.") var format = "markdown"
        @Option(name: .long, help: "Optional file path. Without it, writes to stdout.") var output: String?
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws {
            let store = try storeOptions.makeStore()
            guard let artifact = try store.artifact(id: ArtifactID(identifier)) else {
                throw ValidationError("Artifact '\(identifier)' was not found.")
            }
            let renderFormat: RecipeOutputFormat
            let kind: DestinationKind
            switch format.lowercased() {
            case "markdown", "md":
                renderFormat = .markdown
                kind = .markdownFile
            case "json":
                renderFormat = .structuredJSON
                kind = .jsonFile
            default: throw ValidationError("--format must be markdown or json.")
            }
            guard let output else {
                FileHandle.standardOutput.write(try ArtifactRenderer().render(artifact, as: renderFormat))
                return
            }
            let destination = Destination(
                id: DestinationID("file:\(kind.rawValue):\(URL(filePath: output).standardizedFileURL.path)"),
                kind: kind, name: "CLI export", privacyProfile: artifact.privacyProfile,
                permission: .local, configuration: ["path": output])
            try store.saveDestination(destination, now: Date())
            let attempt = try ArtifactDeliveryService().deliver(
                artifact: artifact, destination: destination, store: store)
            print(attempt.externalIdentifier ?? output)
        }
    }

    public struct Copy: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws {
            let store = try storeOptions.makeStore()
            guard let artifact = try store.artifact(id: ArtifactID(identifier)) else {
                throw ValidationError("Artifact '\(identifier)' was not found.")
            }
            let destination = Destination(
                id: DestinationID("local-clipboard"), kind: .clipboard, name: "Clipboard",
                privacyProfile: .private, permission: .local)
            try store.saveDestination(destination, now: Date())
            _ = try ArtifactDeliveryService().deliver(artifact: artifact, destination: destination, store: store)
            print("Copied artifact to the clipboard.")
        }
    }
}

public struct Context: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Build a bounded recent-work ledger for an agent or developer."
    )

    @Option(name: .long, help: "Repository name, ID, path, or 'current'.")
    var repo = "current"

    @Flag(name: .long, help: "Build one context covering every active repository.")
    var all = false

    @Flag(name: .long, help: "Use the current local calendar day instead of a rolling duration.")
    var today = false

    @Option(name: .long, help: "Lookback duration such as 24h, 14d, or 2w.")
    var since = "14d"

    @Option(name: .long, help: "Maximum rendered output size.")
    var maxCharacters = 12_000

    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions

    public init() {}

    public func run() throws {
        guard (1_000...100_000).contains(maxCharacters) else {
            throw ValidationError("--max-characters must be between 1000 and 100000.")
        }
        if all, repo != "current" {
            throw ValidationError("--repo cannot be combined with --all.")
        }
        let now = Date()
        let start: Date
        if today {
            start = Calendar.current.startOfDay(for: now)
        } else {
            start = now.addingTimeInterval(-(try DateParsing.duration(since)))
        }
        let store = try storeOptions.makeStore()
        let rendered: String
        let mode: String
        if all {
            rendered = try ContextQueries().portfolioContext(
                store: store,
                since: start,
                cutoff: now,
                maximumCharacters: maxCharacters
            ).rendered
            mode = today ? "today-all" : "recent-all"
        } else {
            rendered = try ContextQueries().context(
                store: store,
                repository: repo,
                currentDirectory: URL(filePath: FileManager.default.currentDirectoryPath),
                since: start,
                cutoff: now,
                maximumCharacters: maxCharacters
            ).rendered
            mode = today ? "today-repository" : "recent-repository"
        }
        if outputOptions.json {
            try JSONOutput.writeContext(rendered: rendered, mode: mode, maximumBytes: maxCharacters)
        } else {
            print(rendered)
        }
    }
}

public struct Search: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Search repositories, commits, summaries, and agent messages."
    )

    @Argument(help: "Full-text query.")
    var query: String

    @Option(name: .long, help: "Maximum number of results (1...500).")
    var limit = 50

    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions

    public init() {}

    public func run() throws {
        guard (1...500).contains(limit) else { throw ValidationError("--limit must be between 1 and 500.") }
        let results = try storeOptions.makeStore().search(query, limit: limit)
        if outputOptions.json {
            try JSONOutput.write(SearchPayload(query: query, results: results))
            return
        }
        if results.isEmpty {
            print("No matching ledger records.")
            return
        }
        for result in results {
            let time = result.occurredAt.map { DateParsing.iso8601($0) + "  " } ?? ""
            print("\(time)\(result.kind.rawValue)  \(result.excerpt)")
        }
    }
}

public struct Roots: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Manage repository discovery roots.",
        subcommands: [List.self, Add.self, Scan.self, Enable.self, Disable.self, Exclude.self],
        defaultSubcommand: List.self
    )

    public init() {}

    public struct List: ParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "List configured discovery roots.")

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            let roots = try storeOptions.makeStore().discoveryRoots()
            if outputOptions.json {
                try JSONOutput.write(RootsPayload(roots: roots))
                return
            }
            if roots.isEmpty {
                print("No discovery roots configured.")
                return
            }
            for root in roots {
                let state = root.isEnabled ? "enabled" : "disabled"
                print("\(root.displayName)  \(root.canonicalPath)  [\(state)]")
            }
        }
    }

    public struct Add: ParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Add a repository discovery root.")

        @Argument(help: "Directory to scan recursively.")
        var path: String

        @Option(name: .long, help: "Display name used as the primary group label.")
        var name: String?

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            let root = try DiscoveryRootManager().add(
                path: URL(filePath: path),
                name: name,
                store: storeOptions.makeStore()
            )
            if outputOptions.json {
                try JSONOutput.write(RootPayload(root: root))
            } else {
                print("Added \(root.displayName): \(root.canonicalPath)")
            }
        }
    }

    public struct Scan: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Scan configured roots for Git repositories.")

        @Argument(help: "Optional configured root path to scan.")
        var rootPath: String?

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let store = try storeOptions.makeStore()
            var roots = try store.discoveryRoots(enabledOnly: true)
            if let rootPath {
                let canonical = URL(filePath: rootPath).standardizedFileURL.resolvingSymlinksInPath().path
                roots = roots.filter { URL(filePath: $0.canonicalPath).standardizedFileURL.path == canonical }
                guard !roots.isEmpty else { throw ValidationError("The requested path is not an enabled discovery root.") }
            }
            let result = try await LocalCollectionCoordinator().collect(
                store: store,
                gitRoots: roots.map {
                    GitCollectionRoot(
                        path: URL(filePath: $0.canonicalPath),
                        discoveryRootID: $0.id,
                        excludedPaths: Set($0.excludedPaths)
                    )
                },
                includeCodex: false,
                includeClaude: false
            )
            for root in roots {
                try store.markDiscoveryRootScanned(id: root.id, at: Date())
            }
            if outputOptions.json {
                try JSONOutput.write(RootScanPayload(summaries: result.summaries, counts: result.counts))
                return
            }
            if roots.isEmpty {
                print("No enabled discovery roots configured.")
            } else {
                print("Scanned \(roots.count) roots; ledger now contains \(try store.counts().repositories) repositories.")
            }
        }
    }

    public struct Enable: ParsableCommand {
        @Argument(help: "Root ID, label, or path.") var root: String
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws { try Roots.setEnabled(true, identifier: root, store: storeOptions.makeStore()) }
    }

    public struct Disable: ParsableCommand {
        @Argument(help: "Root ID, label, or path.") var root: String
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws { try Roots.setEnabled(false, identifier: root, store: storeOptions.makeStore()) }
    }

    public struct Exclude: ParsableCommand {
        @Argument(help: "Root ID, label, or path.") var root: String
        @Argument(help: "Relative path beneath the root to exclude.") var relativePath: String
        @OptionGroup var storeOptions: StoreOptions
        public init() {}
        public func run() throws {
            guard !relativePath.hasPrefix("/"),
                !relativePath.split(separator: "/").contains("..")
            else {
                throw ValidationError("The exclusion must be a safe path relative to the root.")
            }
            let store = try storeOptions.makeStore()
            var value = try Roots.resolve(root, store: store)
            if !value.excludedPaths.contains(relativePath) {
                value.excludedPaths.append(relativePath)
                value.excludedPaths.sort()
                try store.upsert(discoveryRoot: value)
            }
            print("Excluded \(relativePath) beneath \(value.displayName). Existing history was preserved.")
        }
    }

    private static func resolve(_ identifier: String, store: LedgerStore) throws -> DiscoveryRoot {
        let canonical = URL(filePath: identifier).standardizedFileURL.path
        let matches = try store.discoveryRoots().filter {
            $0.id.rawValue == identifier
                || $0.displayName.caseInsensitiveCompare(identifier) == .orderedSame
                || $0.canonicalPath == canonical
        }
        guard matches.count == 1, let match = matches.first else {
            throw ValidationError(
                matches.isEmpty
                    ? "Discovery root '\(identifier)' was not found." : "Discovery root '\(identifier)' is ambiguous; use its stable ID.")
        }
        return match
    }

    private static func setEnabled(_ enabled: Bool, identifier: String, store: LedgerStore) throws {
        var root = try resolve(identifier, store: store)
        root.isEnabled = enabled
        try store.upsert(discoveryRoot: root)
        print("\(enabled ? "Enabled" : "Disabled") \(root.displayName). Existing history was preserved.")
    }
}

public struct Today: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Show activity for the current local calendar day."
    )

    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions

    public init() {}

    public func run() throws {
        let now = Date()
        try ActivityOutput.run(
            store: storeOptions.makeStore(),
            range: DateParsing.localDay(containing: now),
            cutoff: now,
            json: outputOptions.json
        )
    }
}

public struct Day: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Show activity for a local calendar day."
    )

    @Argument(help: "Date in YYYY-MM-DD format.")
    var date: String

    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions

    public init() {}

    public func run() throws {
        let range = try DateParsing.localDay(date)
        try ActivityOutput.run(
            store: storeOptions.makeStore(),
            range: range,
            cutoff: min(Date(), range.end),
            json: outputOptions.json
        )
    }
}

public struct Timeline: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Show normalized ledger events over a recent duration."
    )

    @Option(name: .long, help: "Lookback duration such as 12h, 7d, or 2w.")
    var since = "24h"

    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions

    public init() {}

    public func run() throws {
        let now = Date()
        let duration = try DateParsing.duration(since)
        let store = try storeOptions.makeStore()
        let events = try CanonicalWorkEvidenceService().events(
            store: store,
            events: store.events(
                from: now.addingTimeInterval(-duration),
                through: now))
        if outputOptions.json {
            try JSONOutput.write(TimelinePayload(events: events))
            return
        }
        if events.isEmpty {
            print("No activity detected in the selected period.")
            return
        }
        for event in events {
            let state = event.state.map { " [\($0.rawValue)]" } ?? ""
            print("\(DateParsing.iso8601(event.occurredAt))  \(event.kind.rawValue)\(state)")
        }
    }
}

public struct RepositoriesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "repos",
        abstract: "List discovered repositories."
    )

    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions

    public init() {}

    public func run() throws {
        let repositories = try storeOptions.makeStore().repositoryCatalog()
        if outputOptions.json {
            try JSONOutput.write(RepositoriesPayload(repositories: repositories))
            return
        }
        if repositories.isEmpty {
            print("No repositories discovered.")
            return
        }
        for item in repositories {
            let group = item.discoveryRootName.map { "\($0)/" } ?? ""
            print(
                "\(group)\(item.relativePath ?? item.repository.displayName)  \(item.workingCopy.branch ?? "detached")  \(item.workingCopy.canonicalPath)"
            )
        }
    }
}

public struct SessionsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List recent Codex and Claude sessions."
    )

    @Option(name: .long, help: "Maximum number of sessions (1...1000).")
    var limit = 100
    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions
    public init() {}

    public func run() throws {
        guard (1...1_000).contains(limit) else { throw ValidationError("--limit must be between 1 and 1000.") }
        let sessions = try storeOptions.makeStore().sessions(limit: limit)
        if outputOptions.json {
            try JSONOutput.write(SessionsPayload(sessions: sessions))
        } else if sessions.isEmpty {
            print("No agent sessions collected.")
        } else {
            for session in sessions {
                print(
                    "\(session.id.rawValue)  \(session.source.rawValue)  [\(session.state.rawValue)]  \(session.workingDirectory ?? "unassigned")"
                )
            }
        }
    }
}

public struct Show: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Show one ledger record by its stable identifier.",
        subcommands: [Session.self, Commit.self, Summary.self, LegacyReport.self]
    )
    public init() {}

    public struct Session: ParsableCommand {
        @Argument var identifier: String
        @Option(name: .long, help: "Maximum recent messages, returned in chronological order.")
        var messageLimit = 50
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard (1...1_000).contains(messageLimit) else { throw ValidationError("--message-limit must be between 1 and 1000.") }
            let store = try storeOptions.makeStore()
            guard let session = try store.session(identifier: identifier) else {
                throw ValidationError("Session '\(identifier)' was not found.")
            }
            let messages = try store.messages(sessionID: session.id, limit: messageLimit)
            if outputOptions.json {
                try JSONOutput.write(SessionPayload(session: session, messages: messages))
            } else {
                print("Session: \(session.id.rawValue)")
                print("Provider: \(session.source.rawValue)")
                print("State: \(session.state.rawValue)")
                print("Directory: \(session.workingDirectory ?? "unassigned")")
                for message in messages {
                    print("\n[\(message.role.rawValue)] \(message.normalizedText)")
                }
            }
        }
    }

    public struct Commit: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard let commit = try storeOptions.makeStore().commit(identifier: identifier) else {
                throw ValidationError("Commit '\(identifier)' was not found.")
            }
            if outputOptions.json {
                try JSONOutput.write(CommitPayload(commit: commit))
            } else {
                print("\(commit.hash)  \(commit.message)")
                print("Repository: \(commit.repositoryID.rawValue)")
                print("Authored: \(DateParsing.iso8601(commit.authorTime))")
                print("Reachable: \(commit.isReachable)")
                print("Lines/files: +\(commit.additions ?? 0)/-\(commit.deletions ?? 0), \(commit.filesChanged ?? 0) files")
            }
        }
    }

    public struct Summary: ParsableCommand {
        @Argument var identifier: String
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard let summary = try storeOptions.makeStore().summary(id: SummaryID(identifier)) else {
                throw ValidationError("Summary '\(identifier)' was not found.")
            }
            if outputOptions.json {
                try JSONOutput.write(SummaryPayload(summary: summary))
            } else {
                print("[\(summary.kind.rawValue) · \(summary.state.rawValue)] \(summary.content.narrative)")
                for section in summary.content.projectSections {
                    print("\n\(section.project)\n  \(section.narrative)")
                }
            }
        }
    }

    public struct LegacyReport: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "legacy-report",
            abstract: "Inspect a report migrated from Trackify V1.")
        @Argument var identifier: String
        @Option(name: .long, help: "Include at most this many evidence identifiers in JSON (0...500).")
        var evidenceLimit = 0
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions
        public init() {}
        public func run() throws {
            guard (0...500).contains(evidenceLimit) else {
                throw ValidationError("--evidence-limit must be between 0 and 500.")
            }
            guard let report = try storeOptions.makeStore().report(identifier: identifier) else {
                throw ValidationError("Report '\(identifier)' was not found.")
            }
            if outputOptions.json {
                try JSONOutput.write(ReportPayload(report: report, evidenceLimit: evidenceLimit))
            } else {
                print("[\(report.state.rawValue)] \(report.summary)")
                print("Period: \(DateParsing.iso8601(report.periodStart)) → \(DateParsing.iso8601(report.periodEnd))")
                print("Evidence: \(report.evidenceIDs.count) records; revision \(report.revision)")
            }
        }
    }
}

struct StoreOptions: ParsableArguments {
    @Option(name: .long, help: "Use a custom Trackify data root.")
    var dataRoot: String?

    func makePaths() throws -> TrackifyPaths {
        if let dataRoot {
            return TrackifyPaths(dataRoot: URL(filePath: dataRoot))
        }
        return try .default()
    }

    func makeStore() throws -> LedgerStore {
        try LedgerStore(databaseURL: makePaths().ledgerURL)
    }

    func makeSettingsStore() throws -> SettingsStore {
        SettingsStore(fileURL: try makePaths().settingsURL)
    }
}

struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit versioned JSON output.")
    var json = false
}

public struct Status: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Show ledger and collection status."
    )

    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions

    public init() {}

    public func run() throws {
        let store = try storeOptions.makeStore()
        let report = try Doctor().inspect(store: store)

        if outputOptions.json {
            try JSONOutput.write(StatusPayload(report: report))
            return
        }

        print("Trackify: \(report.state.rawValue)")
        print("Ledger: \(report.databasePath)")
        print("Repositories: \(report.counts.repositories)")
        print("Commits: \(report.counts.commits)")
        print("Sessions: \(report.counts.sessions)")
        print("Messages: \(report.counts.messages)")
        print("Events: \(report.counts.events)")
        print("Database: \(report.health.databaseBytes) bytes")
    }
}

public struct DoctorCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Inspect the local ledger and report actionable problems."
    )

    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions

    @Option(name: .long, help: "Write an allowlisted, content-free diagnostic JSON file.")
    var export: String?

    public init() {}

    public func run() throws {
        let store = try storeOptions.makeStore()
        let report = try Doctor().inspect(store: store)
        if let export {
            let destination = URL(filePath: export)
            try DiagnosticExporter().write(
                DiagnosticExporter().make(store: store),
                to: destination
            )
        }
        if outputOptions.json {
            try JSONOutput.write(DoctorPayload(report: report, diagnosticExport: export))
            return
        }

        print("State: \(report.state.rawValue)")
        print("Database: \(report.databasePath)")
        print("Migrations: \(report.migrations.joined(separator: ", "))")
        print("Integrity: \(report.health.integrity)")
        print("Evidence: \(report.evidence.state.rawValue) (projection v\(report.evidence.projectionVersion))")
        print(
            "Evidence records: \(report.evidence.unresolvedRecordCount) unresolved, \(report.evidence.diagnosticRecordCount) diagnostic, \(report.evidence.aliasRecordCount) aliases, \(report.evidence.replayRecordCount) replays"
        )
        if let coverage = report.coverage {
            print(
                "Coverage: \(DateParsing.iso8601(coverage.start))..<\(DateParsing.iso8601(coverage.cutoff)) (\(coverage.calendarDays) local calendar days)"
            )
            for source in coverage.sourceReads {
                let bytes = source.bytesRead.map(String.init) ?? "unavailable"
                print(
                    "Read \(source.sourceKey): \(source.unitsOpened)/\(source.candidatesConsidered) \(source.unit.rawValue) units, \(bytes) bytes, \(source.recordsObserved) observed, \(source.recordsAccepted) accepted"
                )
            }
        }
        print("Database size: \(report.health.databaseBytes) bytes")
        print("Migration backups: \(report.health.migrationBackupCount) (\(report.health.migrationBackupBytes) bytes)")
        if let observed = report.health.collectorObservedAt {
            print("Collector: \(report.health.collectorState ?? "unknown") at \(DateParsing.iso8601(observed))")
        }
        if report.problems.isEmpty {
            print("No problems detected.")
        } else {
            for problem in report.problems {
                print("- \(problem)")
            }
        }
        for warning in report.warnings {
            print("Warning: \(warning)")
        }
        if let export {
            print("Safe diagnostic written to \(URL(filePath: export).standardizedFileURL.path).")
            print("It contains only versions, counts, health states, and sizes; review it before sharing.")
        }
    }
}

public struct DataCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "data",
        abstract: "Inspect, export, or remove local Trackify data.",
        subcommands: [Path.self, Export.self, DeleteReports.self, Rebuild.self, ActivateRebuild.self],
        defaultSubcommand: Path.self
    )

    public init() {}

    public struct Path: ParsableCommand {
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            let root = try storeOptions.makePaths().dataRoot.path
            if outputOptions.json {
                try JSONOutput.write(DataPathPayload(dataRoot: root))
            } else {
                print(root)
            }
        }
    }

    public struct Export: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Export a consistent private SQLite snapshot of the complete ledger."
        )

        @Argument(help: "Destination SQLite file. It must not already exist.")
        var destination: String
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            let url = URL(filePath: destination).standardizedFileURL
            try storeOptions.makeStore().exportSnapshot(to: url)
            if outputOptions.json {
                try JSONOutput.write(DataExportPayload(destination: url.path))
            } else {
                print("Exported the complete private ledger to \(url.path).")
                print("This file may contain repository and conversation information; protect it accordingly.")
            }
        }
    }

    public struct DeleteReports: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete-reports",
            abstract: "Delete all generated reports while preserving source evidence and statistics."
        )

        @Flag(name: .long, help: "Confirm deletion of every generated report and report search entry.")
        var confirm = false
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            guard confirm else {
                throw ValidationError("Pass --confirm to delete all generated reports.")
            }
            let deleted = try storeOptions.makeStore().deleteAllReports()
            if outputOptions.json {
                try JSONOutput.write(DeleteReportsPayload(deletedReports: deleted))
            } else {
                print("Deleted \(deleted) generated report\(deleted == 1 ? "" : "s").")
            }
        }
    }

    public struct Rebuild: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "rebuild",
            abstract: "Reconstruct a shadow ledger from Git and local provider histories, verify it, and optionally activate it."
        )

        @Flag(name: .long, help: "Read reconstructable evidence only from configured Git roots and local provider caches.")
        var fromSources = false
        @Flag(name: .long, help: "Require storage, semantic, idempotence, and local-summary validation.")
        var verify = false
        @Flag(name: .long, help: "Atomically activate the validated shadow ledger and retain the previous ledger as a private backup.")
        var replace = false
        @Option(name: .long, help: "Local calendar days to reconstruct, including today (1...366).")
        var days = 7
        @Option(name: .long, help: "Use an exact ISO-8601 cutoff for deterministic validation.")
        var cutoff: String?
        @Option(name: .long, help: "Require an exact canonical fingerprint before activation.")
        var expectedFingerprint: String?
        @Option(name: .long, help: "Require an exact normalized-evidence fingerprint before activation.")
        var expectedEvidenceFingerprint: String?
        @Option(name: .long, help: "Override the home directory used to locate provider caches (primarily for isolated validation).")
        var homeDirectory: String?
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() async throws {
            guard fromSources else {
                throw ValidationError("Pass --from-sources; existing ledger rows are never treated as rebuild source truth.")
            }
            guard verify else {
                throw ValidationError("Pass --verify; an unverified evidence ledger cannot be activated.")
            }
            let cutoffDate: Date?
            if let cutoff {
                guard let parsed = ISO8601DateFormatter().date(from: cutoff) else {
                    throw ValidationError("--cutoff must be an ISO-8601 timestamp.")
                }
                cutoffDate = parsed
            } else {
                cutoffDate = nil
            }
            let paths = try storeOptions.makePaths()
            let rebuilder =
                cutoffDate.map { EvidenceLedgerRebuilder(clock: FixedWallClock($0)) }
                ?? EvidenceLedgerRebuilder()
            let result = try await rebuilder.rebuild(
                paths: paths,
                homeDirectory: homeDirectory.map { URL(filePath: $0).standardizedFileURL }
                    ?? FileManager.default.homeDirectoryForCurrentUser,
                replace: replace,
                expectedFingerprint: expectedFingerprint,
                expectedEvidenceFingerprint: expectedEvidenceFingerprint,
                calendarDays: days)
            if outputOptions.json {
                try JSONOutput.write(result)
                return
            }
            print("Shadow ledger: \(result.shadowLedgerPath)")
            print(
                "Coverage: \(result.coverage.start.formatted(.iso8601))..<\(result.coverage.cutoff.formatted(.iso8601)) (\(result.coverage.calendarDays) local calendar days)"
            )
            print("Storage: \(result.storageIntegrity)")
            print("Evidence: \(result.quality.state.rawValue)")
            print("Canonical work: \(result.canonical.workTurns) turns, \(result.canonical.workMessages) messages")
            print(
                "Diagnostics: \(result.canonical.diagnosticRecords), control: \(result.canonical.controlRecords), unresolved: \(result.canonical.unresolvedRecords)"
            )
            print("Fingerprint: \(result.canonical.canonicalFingerprint)")
            print("Evidence fingerprint: \(result.canonical.evidenceFingerprint)")
            print("Second pass changed history: \(result.incrementalPassChangedCanonicalHistory ? "yes" : "no")")
            print("Local summaries generated: \(result.summariesGenerated)")
            if result.activated {
                print("Activated validated ledger.")
                if let previous = result.replacedLedgerPath { print("Previous ledger: \(previous)") }
            } else {
                print("Dry rebuild complete; the active ledger was not changed.")
            }
        }
    }

    public struct ActivateRebuild: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "activate-rebuild",
            abstract: "Revalidate and activate an existing Trackify-owned shadow ledger."
        )

        @Option(name: .long, help: "Path to the shadow trackify.sqlite inside this data root.")
        var shadowLedger: String
        @Option(name: .long, help: "Required canonical fingerprint from the verified rebuild.")
        var expectedFingerprint: String
        @Option(name: .long, help: "Required normalized-evidence fingerprint from the verified rebuild.")
        var expectedEvidenceFingerprint: String
        @Flag(name: .long, help: "Confirm atomic replacement of the active derived ledger.")
        var confirm = false
        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            guard confirm else {
                throw ValidationError("Pass --confirm to activate the validated shadow ledger.")
            }
            let paths = try storeOptions.makePaths()
            let result = try EvidenceLedgerRebuilder().activateValidatedShadow(
                shadowLedgerURL: URL(filePath: shadowLedger),
                activePaths: paths,
                expectedFingerprint: expectedFingerprint,
                expectedEvidenceFingerprint: expectedEvidenceFingerprint)
            if outputOptions.json {
                try JSONOutput.write(result)
                return
            }
            print("Activated: \(result.activatedLedgerPath)")
            print("Storage: \(result.storageIntegrity)")
            print("Evidence: \(result.quality.state.rawValue)")
            print("Fingerprint: \(result.canonical.canonicalFingerprint)")
            print("Evidence fingerprint: \(result.canonical.evidenceFingerprint)")
            if let previous = result.replacedLedgerPath {
                print("Previous ledger: \(previous)")
            }
        }
    }
}

public struct UpdateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Inspect or request an update through the installation owner.",
        subcommands: [Status.self, Check.self, Install.self],
        defaultSubcommand: Status.self
    )

    public init() {}

    public struct Status: ParsableCommand {
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            try writeUpdateStatus(metadata: currentInstallation(), state: "idle", outputOptions: outputOptions)
        }
    }

    public struct Check: ParsableCommand {
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            let metadata = currentInstallation()
            if metadata.updateAction == .sparkle {
                try openUpdate(path: "check")
                try writeUpdateStatus(metadata: metadata, state: "requested", outputOptions: outputOptions)
            } else {
                try writeUpdateStatus(metadata: metadata, state: "externally_managed", outputOptions: outputOptions)
            }
        }
    }

    public struct Install: ParsableCommand {
        @Flag(name: .long, help: "Allow the owning updater to relaunch Trackify after installation.")
        var relaunch = false
        @OptionGroup var outputOptions: OutputOptions

        public init() {}

        public func run() throws {
            guard relaunch else { throw ValidationError("Pass --relaunch to request update installation.") }
            let metadata = currentInstallation()
            guard metadata.updateAction == .sparkle else {
                throw ValidationError(updateInstruction(for: metadata.updateAction))
            }
            try openUpdate(path: "install")
            try writeUpdateStatus(metadata: metadata, state: "requested", outputOptions: outputOptions)
        }
    }
}

public struct Collect: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Collect Git and local Codex and Claude evidence."
    )

    @Option(name: .customLong("git-root"), help: "Repository discovery root. Repeat for multiple roots.")
    var gitRoots: [String] = []

    @Flag(name: .long, help: "Skip the default Codex history locations.")
    var noCodex = false

    @Flag(name: .long, help: "Skip the default Claude history location.")
    var noClaude = false

    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions

    public init() {}

    public mutating func run() async throws {
        let store = try storeOptions.makeStore()
        let configured = try store.discoveryRoots(enabledOnly: true).map {
            GitCollectionRoot(
                path: URL(filePath: $0.canonicalPath),
                discoveryRootID: $0.id,
                excludedPaths: Set($0.excludedPaths)
            )
        }
        let transient = gitRoots.map { GitCollectionRoot(path: URL(filePath: $0)) }
        let result = try await LocalCollectionCoordinator().collect(
            store: store,
            gitRoots: configured + transient,
            includeCodex: !noCodex,
            includeClaude: !noClaude,
            hookInboxURL: try storeOptions.makePaths().hookInboxURL
        )
        let payload = CollectionPayload(result: result)
        if outputOptions.json {
            try JSONOutput.write(payload)
            return
        }

        if result.summaries.isEmpty {
            print("No configured or available sources were found.")
        } else {
            for summary in result.summaries {
                print("\(summary.sourceKey): \(summary.insertedEvents) new events, \(summary.receivedMessages) messages observed")
            }
        }
        for issue in result.issues {
            FileHandle.standardError.write(Data("\(issue.sourceKey): \(issue.message)\n".utf8))
        }
        print("Ledger: \(payload.counts.repositories) repositories, \(payload.counts.sessions) sessions, \(payload.counts.events) events")
    }
}

public struct Backfill: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Import available historical evidence for a date range."
    )

    @Option(name: .long, help: "Inclusive start date in YYYY-MM-DD format.")
    var from: String

    @Option(name: .long, help: "Inclusive end date in YYYY-MM-DD format.")
    var to: String

    @Flag(name: .long, help: "Skip Codex history.")
    var noCodex = false

    @Flag(name: .long, help: "Skip Claude history.")
    var noClaude = false

    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var outputOptions: OutputOptions

    public init() {}

    public mutating func run() async throws {
        let start = try DateParsing.localDay(from).start
        let end = try DateParsing.localDay(to).end
        guard end > start else { throw ValidationError("--to must not precede --from.") }
        let store = try storeOptions.makeStore()
        let roots = try store.discoveryRoots(enabledOnly: true).map {
            GitCollectionRoot(
                path: URL(filePath: $0.canonicalPath),
                discoveryRootID: $0.id,
                excludedPaths: Set($0.excludedPaths)
            )
        }
        let result = try await LocalCollectionCoordinator().collect(
            store: store,
            gitRoots: roots,
            includeCodex: !noCodex,
            includeClaude: !noClaude,
            range: DateInterval(start: start, end: end),
            hookInboxURL: try storeOptions.makePaths().hookInboxURL
        )
        let payload = CollectionPayload(result: result)
        if outputOptions.json {
            try JSONOutput.write(payload)
        } else {
            print("Backfilled \(from) through \(to): \(result.counts.events) total ledger events.")
            if !result.issues.isEmpty {
                print("Completed with \(result.issues.count) source issue(s); run trackify doctor for details.")
            }
        }
    }
}

public struct Simulate: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Run a deterministic scenario against an isolated ledger."
    )

    @Option(name: .long, help: "Scenario name.")
    var scenario = "foundation"

    @Option(name: .long, help: "Simulation speed. V1 currently supports instant.")
    var speed = "instant"

    @Option(name: .long, help: "Number of virtual days.")
    var days = 2

    @Option(name: .long, help: "ISO-8601 start instant.")
    var start = "2026-08-03T00:00:00Z"

    @Option(name: .long, help: "Preserve the simulated ledger in a new data root for UI or CLI inspection.")
    var outputDataRoot: String?

    @OptionGroup var outputOptions: OutputOptions

    public init() {}

    public mutating func run() async throws {
        guard ["foundation", "showcase"].contains(scenario) else {
            throw ValidationError("Unknown scenario '\(scenario)'.")
        }
        guard speed == "instant" else {
            throw ValidationError("Only --speed instant is supported.")
        }
        guard days > 0 else {
            throw ValidationError("--days must be greater than zero.")
        }
        guard let startDate = ISO8601DateFormatter().date(from: start) else {
            throw ValidationError("--start must be an ISO-8601 instant.")
        }

        let directory =
            outputDataRoot.map { URL(filePath: $0).standardizedFileURL }
            ?? FileManager.default.temporaryDirectory
            .appending(path: "trackify-simulation-\(UUID().uuidString)", directoryHint: .isDirectory)
        let isEphemeral = outputDataRoot == nil
        guard !FileManager.default.fileExists(atPath: directory.appending(path: "trackify.sqlite").path) else {
            throw ValidationError("--output-data-root must not contain an existing Trackify ledger.")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            if isEphemeral { try? FileManager.default.removeItem(at: directory) }
        }

        let store = try LedgerStore(databaseURL: TrackifyPaths(dataRoot: directory).ledgerURL)
        let result: SimulationResult
        if scenario == "showcase" {
            result = try await ShowcaseSimulation().run(store: store, start: startDate, days: days)
        } else {
            result = try await FoundationSimulation().run(store: store, start: startDate, days: days)
        }
        var simulationCalendar = Calendar(identifier: .gregorian)
        simulationCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let summaryNow = min(
            result.days.compactMap(\.lastEvidenceAt).max()?.addingTimeInterval(1_800)
                ?? result.endedAt,
            result.endedAt)
        let summaryRefresh = await SummaryCoordinator().refresh(
            store: store, settings: TrackifySettings(providerSelection: .localOnly),
            now: summaryNow, calendar: simulationCalendar,
            lookbackDays: min(days + 1, 366))

        if outputOptions.json {
            try JSONOutput.write(
                SimulationPayload(
                    result: result, summaryRefresh: summaryRefresh,
                    dataRoot: directory.path, ephemeral: isEphemeral))
            return
        }

        print("Scenario: \(scenario)")
        print(
            "Virtual range: \(ISO8601DateFormatter().string(from: result.startedAt)) → \(ISO8601DateFormatter().string(from: result.endedAt))"
        )
        print("Generated events: \(result.generatedEvents)")
        print("Generated summary revisions: \(summaryRefresh.generated.count)")
        print("Isolated ledger events: \(result.counts.events)")
        print(isEphemeral ? "Ledger: temporary (removed after validation)" : "Ledger: \(directory.path)")
    }
}

private struct StatusPayload: Encodable {
    let schemaVersion = 2
    let state: DiagnosticState
    let databasePath: String
    let counts: LedgerCounts
    let liveCollector: LiveCollectorRuntimeStatus?
    let lastFullReconciliation: Date?

    init(report: DiagnosticReport) {
        state = report.state
        databasePath = report.databasePath
        counts = report.counts
        liveCollector = report.liveCollector
        lastFullReconciliation = report.lastFullReconciliation
    }
}

private struct DoctorPayload: Encodable {
    let schemaVersion = 1
    let report: DiagnosticReport
    let diagnosticExport: String?
}

private struct DataPathPayload: Encodable {
    let schemaVersion = 1
    let dataRoot: String
}

private struct DataExportPayload: Encodable {
    let schemaVersion = 1
    let destination: String
}

private struct DeleteReportsPayload: Encodable {
    let schemaVersion = 1
    let deletedReports: Int
}

private struct UpdateStatusPayload: Encodable {
    let schemaVersion = 1
    let origin: InstallationOrigin
    let channel = "stable"
    let currentVersion: String
    let build: String
    let state: String
    let installAction: UpdateInstallAction
    let instruction: String
    let requiresRelaunch: Bool
}

private struct SimulationPayload: Encodable {
    let schemaVersion = 2
    let result: SimulationResult
    let summaryRefresh: SummaryRefreshResult
    let dataRoot: String
    let ephemeral: Bool
}

private struct CollectionPayload: Encodable {
    let schemaVersion = 1
    let summaries: [CollectionSummary]
    let issues: [CollectionIssue]
    let counts: LedgerCounts

    init(result: LocalCollectionResult) {
        summaries = result.summaries
        issues = result.issues
        counts = result.counts
    }
}

private struct CollectionStatePayload: Encodable {
    let schemaVersion = 2
    let paused: Bool
    let live: LiveCollectorRuntimeStatus?
    let lastFullReconciliation: Date?
}

private struct ActivityPayload: Encodable {
    let schemaVersion = 2
    let dashboard: ActivityDashboard
}

private struct SummariesPayload: Encodable {
    let schemaVersion = 1
    let summaries: [WorkSummary]
}

private struct SummaryPayload: Encodable {
    let schemaVersion = 1
    let summary: WorkSummary
}

private struct SummaryRefreshPayload: Encodable {
    let schemaVersion = 1
    let result: SummaryRefreshResult
}

private struct SummaryStatusPayload: Encodable {
    let schemaVersion = 1
    let current: WorkSummary?
    let day: WorkSummary?
    let recentRuns: [SummaryRun]
}

private struct TimelinePayload: Encodable {
    let schemaVersion = 1
    let events: [LedgerEvent]
}

private struct RepositoriesPayload: Encodable {
    let schemaVersion = 1
    let repositories: [RepositoryCatalogItem]
}

private struct SessionsPayload: Encodable {
    let schemaVersion = 1
    let sessions: [ConversationSession]
}

private struct SessionPayload: Encodable {
    let schemaVersion = 1
    let session: ConversationSession
    let messages: [ConversationMessage]
}

private struct CommitPayload: Encodable {
    let schemaVersion = 1
    let commit: GitCommit
}

private struct SearchPayload: Encodable {
    let schemaVersion = 1
    let query: String
    let results: [SearchResult]
}

struct ContextPayload: Codable {
    let schemaVersion: Int
    let mode: String
    let rendered: String
    let truncated: Bool

    init(mode: String, rendered: String, truncated: Bool) {
        schemaVersion = 2
        self.mode = mode
        self.rendered = rendered
        self.truncated = truncated
    }
}

struct ReportPayload: Encodable {
    struct ReportRecord: Encodable {
        let id: ReportID
        let periodStart: Date
        let periodEnd: Date
        let state: ReportPeriodState
        let summary: String
        let evidenceCount: Int
        let evidenceIDs: [EvidenceID]
        let omittedEvidenceCount: Int
        let provider: String?
        let model: String?
        let generatorVersion: String
        let revision: Int
    }

    let schemaVersion = 2
    let report: ReportRecord

    init(report: WorkReport, evidenceLimit: Int) {
        let included = Array(report.evidenceIDs.prefix(evidenceLimit))
        self.report = ReportRecord(
            id: report.id,
            periodStart: report.periodStart,
            periodEnd: report.periodEnd,
            state: report.state,
            summary: SensitiveText.redact(report.summary),
            evidenceCount: report.evidenceIDs.count,
            evidenceIDs: included,
            omittedEvidenceCount: report.evidenceIDs.count - included.count,
            provider: report.provider,
            model: report.model,
            generatorVersion: report.generatorVersion,
            revision: report.revision
        )
    }
}

private struct ReportPacketPreviewPayload: Encodable {
    let schemaVersion = 1
    let periodStart: Date
    let periodEnd: Date
    let state: ReportPeriodState
    let activity: ReportActivitySnapshot
    let selection: ReportPacketSelection
    let serializedBytes: Int
    let estimatedInputTokens: Int
    let selectedAliases: [String]
    let selectedKinds: [String: Int]
    let priorSummaryAliases: [String]

    init(packet: ReportEvidencePacket) {
        periodStart = packet.periodStart
        periodEnd = packet.periodEnd
        state = packet.state
        activity = packet.activity
        selection = packet.selection
        serializedBytes = packet.serializedByteCount
        estimatedInputTokens = packet.estimatedInputTokens
        selectedAliases = packet.events.map(\.eventID.rawValue)
        selectedKinds = Dictionary(grouping: packet.events, by: { $0.kind.rawValue }).mapValues(\.count)
        priorSummaryAliases = packet.priorSummaries.map(\.alias)
    }
}

private struct ReportGenerationPreviewPayload: Encodable {
    let schemaVersion = 1
    let preview: ReportGenerationPreview
}

private struct ProvidersPayload: Encodable {
    let schemaVersion = 2
    let selectionMode: ProviderSelectionMode
    let effectiveProvider: SummaryProviderID?
    let providers: [GenerationCapability]
}

private struct ProviderSelectionPayload: Encodable {
    let schemaVersion = 2
    let selected: ProviderSelectionMode
}

private struct SourcesPayload: Encodable {
    let schemaVersion = 1
    let sources: [SourceCapability]
}

private struct UsagePayload: Encodable {
    let schemaVersion = 1
    let periodStart: Date
    let periodEnd: Date
    let usage: UsageSummary
}

private struct UsageBudgetPayload: Encodable {
    let schemaVersion = 1
    let status: GenerationBudgetStatus
}

private struct UsageBudgetConfigurationPayload: Encodable {
    let schemaVersion = 1
    let budgets: GenerationBudgets
}

private struct ReportRunsPayload: Encodable {
    let schemaVersion = 2
    let runs: [ReportRun]
    let nextCursor: String?
}

private struct ReportRunPayload: Encodable {
    let schemaVersion = 1
    let run: ReportRun
}

private struct RecipesPayload: Encodable {
    let schemaVersion = 1
    let recipes: [ReportRecipe]
}

private struct RecipePayload: Encodable {
    let schemaVersion = 1
    let recipe: ReportRecipe
    let version: ReportRecipeVersion
}

private struct ReportersPayload: Encodable {
    let schemaVersion = 1
    let reporters: [ReportSchedule]
}

private struct ReporterPayload: Encodable {
    let schemaVersion = 1
    let reporter: ReportSchedule
}

private struct DeleteReporterPayload: Encodable {
    let schemaVersion = 1
    let identifier: String
    let deleted = true
}

private struct ArtifactsPayload: Encodable {
    let schemaVersion = 3
    let artifacts: [ArtifactListItem]
    let nextCursor: String?
}

private struct ArtifactListItem: Encodable {
    let id: ArtifactID
    let type: ArtifactType
    let recipeID: RecipeID
    let recipeVersionID: RecipeVersionID
    let reportRunID: ReportRunID?
    let periodStart: Date
    let periodEnd: Date
    let state: ReportPeriodState
    let revision: Int
    let format: RecipeOutputFormat
    let privacyProfile: PrivacyProfile
    let createdAt: Date
    let contentPreview: String
    let evidenceCount: Int
    let repositoryCount: Int
    let groupCount: Int

    init(_ artifact: Artifact) {
        id = artifact.id
        type = artifact.type
        recipeID = artifact.recipeID
        recipeVersionID = artifact.recipeVersionID
        reportRunID = artifact.reportRunID
        periodStart = artifact.periodStart
        periodEnd = artifact.periodEnd
        state = artifact.state
        revision = artifact.revision
        format = artifact.format
        privacyProfile = artifact.privacyProfile
        createdAt = artifact.createdAt
        contentPreview = String(artifact.content.prefix(400))
        evidenceCount = artifact.evidenceIDs.count
        repositoryCount = artifact.repositoryIDs.count
        groupCount = artifact.groupNames.count
    }
}

private struct ArtifactPayload: Encodable {
    let schemaVersion = 1
    let artifact: Artifact
}

private struct ModelBackfillPlanPayload: Encodable {
    let schemaVersion = 1
    let plan: ModelBackfillPlan
    let confirmed: Bool
}

private struct ModelBackfillResultPayload: Encodable {
    let schemaVersion = 1
    let plan: ModelBackfillPlan
    let runs: [ReportRunID]
    let artifacts: [ArtifactID]
}

private struct CancelRunPayload: Encodable {
    let schemaVersion = 1
    let runID: ReportRunID
    let cancelled: Bool
}

private struct RecipeDefinition: Decodable {
    let id: String
    let name: String
    let purpose: String
    let audience: String
    let cadence: RecipeCadence
    let repositoryIDs: [String]
    let groupNames: [String]
    let customFocus: String?
    let tone: String
    let outputFormat: RecipeOutputFormat
    let maximumCharacters: Int
    let privacyProfile: PrivacyProfile
    let providerModeOverride: ProviderSelectionMode?

    private enum CodingKeys: String, CodingKey {
        case id, name, purpose, audience, cadence, repositoryIDs, groupNames
        case customFocus, tone, outputFormat, maximumCharacters, privacyProfile
        case providerModeOverride
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        purpose = try values.decode(String.self, forKey: .purpose)
        audience = try values.decodeIfPresent(String.self, forKey: .audience) ?? "self"
        cadence = try values.decodeIfPresent(RecipeCadence.self, forKey: .cadence) ?? .onDemand
        repositoryIDs = try values.decodeIfPresent([String].self, forKey: .repositoryIDs) ?? []
        groupNames = try values.decodeIfPresent([String].self, forKey: .groupNames) ?? []
        customFocus = try values.decodeIfPresent(String.self, forKey: .customFocus)
        tone = try values.decodeIfPresent(String.self, forKey: .tone) ?? "concise and factual"
        outputFormat = try values.decodeIfPresent(RecipeOutputFormat.self, forKey: .outputFormat) ?? .plainText
        maximumCharacters = try values.decodeIfPresent(Int.self, forKey: .maximumCharacters) ?? 2_000
        privacyProfile = try values.decodeIfPresent(PrivacyProfile.self, forKey: .privacyProfile) ?? .private
        providerModeOverride = try values.decodeIfPresent(ProviderSelectionMode.self, forKey: .providerModeOverride)
    }
}

private struct IntegrationStatusPayload: Encodable {
    let schemaVersion = 1
    let inboxPath: String
    let inboxExists: Bool
    let cacheReconciliation = true
}

private struct BootstrapInspectionPayload: Encodable {
    let schemaVersion = 1
    let inspection: BootstrapInspection
}

private struct BootstrapApplyPayload: Encodable {
    let schemaVersion = 2
    let addedRoots: [DiscoveryRoot]
    let selectedProvider: SummaryProviderID?
    let providerSelection: ProviderSelectionMode
    let automaticSummariesUseLLM: Bool
    let collection: LocalCollectionResult?
    let generatedSummaries: Int
    let launched: Bool
}

private struct RootsPayload: Encodable {
    let schemaVersion = 1
    let roots: [DiscoveryRoot]
}

private struct RootPayload: Encodable {
    let schemaVersion = 1
    let root: DiscoveryRoot
}

private struct RootScanPayload: Encodable {
    let schemaVersion = 1
    let summaries: [CollectionSummary]
    let counts: LedgerCounts
}

private enum ProviderOutput {
    static func run(storeOptions: StoreOptions, json: Bool) throws {
        let settings = try storeOptions.makeSettingsStore().load()
        let providers = CapabilityDiscovery().generators(store: try storeOptions.makeStore())
        let effective = CapabilityDiscovery().effectiveProvider(
            mode: settings.providerSelection, capabilities: providers)
        if json {
            try JSONOutput.write(
                ProvidersPayload(
                    selectionMode: settings.providerSelection,
                    effectiveProvider: effective,
                    providers: providers))
            return
        }
        print("Mode: \(settings.providerSelection.rawValue) · effective: \(effective?.rawValue ?? "local_only")")
        for provider in providers {
            let selected = effective == provider.id ? " (effective)" : ""
            print("\(provider.id.rawValue): \(provider.authentication.rawValue)\(selected)")
            if let version = provider.cliVersion { print("  \(version)") }
        }
    }
}

private enum UsageOutput {
    static func write(store: LedgerStore, interval: DateInterval, json: Bool) throws {
        let usage = try store.usage(from: interval.start, through: interval.end)
        if json {
            try JSONOutput.write(
                UsagePayload(periodStart: interval.start, periodEnd: interval.end, usage: usage))
        } else {
            let tokens = usage.inputTokens + usage.cachedInputTokens + usage.outputTokens + usage.reasoningTokens
            print("Runs: \(usage.runs) · succeeded \(usage.succeeded) · failed \(usage.failed)")
            print(
                "Tokens: \(tokens) (input \(usage.inputTokens), cached \(usage.cachedInputTokens), output \(usage.outputTokens), reasoning \(usage.reasoningTokens))"
            )
            if usage.knownCost > 0 {
                print("Provider-reported known cost: \(usage.currency ?? "") \(usage.knownCost)")
            } else {
                print(usage.hasUnknownCost ? "Incremental cost: unknown" : "Cost: no provider value reported")
            }
        }
    }
}

private enum IntelligenceCLI {
    static func period(_ value: String, now: Date, calendar: Calendar = .current) throws -> DateInterval {
        switch value.lowercased() {
        case "today": return DateParsing.localDay(containing: now)
        case "yesterday":
            let today = DateParsing.localDay(containing: now)
            let start = calendar.date(byAdding: .day, value: -1, to: today.start)!
            return DateInterval(start: start, end: today.start)
        case "last-hour":
            let hour = calendar.dateInterval(of: .hour, for: now)!
            let start = calendar.date(byAdding: .hour, value: -1, to: hour.start)!
            return DateInterval(start: start, end: hour.start)
        default:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: value) else {
                throw ValidationError("--period must be today, yesterday, last-hour, or YYYY-MM-DD.")
            }
            return DateParsing.localDay(containing: date)
        }
    }
}

private enum ActivityOutput {
    static func run(store: LedgerStore, range: DateInterval, cutoff: Date, json: Bool) throws {
        let dashboard = try ActivityQueries().dashboard(store: store, range: range, cutoff: cutoff)
        let snapshot = dashboard.activity
        if json {
            try JSONOutput.write(ActivityPayload(dashboard: dashboard))
            return
        }
        print("Period: \(DateParsing.iso8601(snapshot.rangeStart)) → \(DateParsing.iso8601(snapshot.rangeEnd))")
        print("Active evidence hours: \(snapshot.activeHours)")
        print("LLM turns: \(snapshot.llmTurns)")
        print("Conversation messages: \(snapshot.conversationMessages)")
        print("Commits: \(snapshot.commits)")
        print("Lines: +\(snapshot.additions) / -\(snapshot.deletions)")
        print("Files changed in commits: \(snapshot.filesChanged)")
        print("Repositories: \(snapshot.repositoryIDs.count)")
        if dashboard.comparison.activeDays > 0 {
            print("Compared with: \(dashboard.comparison.activeDays)-day active moving average")
            print("Active-hour pace: \(formatChange(dashboard.comparison.activeHours.percentChange))")
            print("LLM-turn pace: \(formatChange(dashboard.comparison.llmTurns.percentChange))")
            print("Commit pace: \(formatChange(dashboard.comparison.commits.percentChange))")
        }
        if let first = snapshot.firstEvidenceAt, let last = snapshot.lastEvidenceAt {
            print("Observed window: \(DateParsing.iso8601(first)) → \(DateParsing.iso8601(last))")
        } else {
            print("State: no evidence detected")
        }
        print("Evidence records: \(snapshot.evidenceCount)")
    }

    private static func formatChange(_ percent: Double?) -> String {
        guard let percent else { return "no baseline" }
        return String(format: "%+.0f%%", percent)
    }
}

private struct PageCursor: Codable {
    let date: Date
    let id: String

    static func encode(date: Date, id: String) -> String {
        let cursor = PageCursor(date: date, id: id)
        return (try? JSONEncoder().encode(cursor).base64EncodedString()) ?? ""
    }

    static func decode(_ value: String) throws -> PageCursor {
        guard let data = Data(base64Encoded: value),
            let cursor = try? JSONDecoder().decode(PageCursor.self, from: data),
            !cursor.id.isEmpty
        else { throw ValidationError("--cursor is invalid.") }
        return cursor
    }
}

private enum DateParsing {
    static func localDay(_ value: String) throws -> DateInterval {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
            pieces[0].count == 4,
            pieces[1].count == 2,
            pieces[2].count == 2,
            let year = Int(pieces[0]),
            let month = Int(pieces[1]),
            let day = Int(pieces[2]),
            let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day)),
            Calendar.current.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day)
        else {
            throw ValidationError("Expected a date in YYYY-MM-DD format, got '\(value)'.")
        }
        return localDay(containing: date)
    }

    static func iso8601(_ date: Date) -> String {
        date.ISO8601Format()
    }

    static func localDay(containing date: Date) -> DateInterval {
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    static func duration(_ value: String) throws -> TimeInterval {
        guard value.count >= 2,
            let unit = value.last,
            let amount = Double(value.dropLast()),
            amount > 0
        else {
            throw ValidationError("Expected a positive duration such as 12h, 7d, or 2w.")
        }
        let multiplier: TimeInterval
        switch unit {
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        case "d": multiplier = 86_400
        case "w": multiplier = 604_800
        default: throw ValidationError("Unsupported duration unit '\(unit)'. Use m, h, d, or w.")
        }
        return amount * multiplier
    }
}

enum JSONOutput {
    static func write<Value: Encodable>(_ value: Value) throws {
        let data = try encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func writeContext(rendered: String, mode: String, maximumBytes: Int) throws {
        let data = try contextData(rendered: rendered, mode: mode, maximumBytes: maximumBytes)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func contextData(rendered: String, mode: String, maximumBytes: Int) throws -> Data {
        let complete = ContextPayload(mode: mode, rendered: rendered, truncated: false)
        if try encode(complete).count + 1 <= maximumBytes {
            return try encode(complete)
        }

        let marker = "\n… output budget reached"
        var lowerBound = 0
        var upperBound = rendered.count
        var best = ""
        while lowerBound <= upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            let candidate = String(rendered.prefix(midpoint)) + marker
            let payload = ContextPayload(mode: mode, rendered: candidate, truncated: true)
            if try encode(payload).count + 1 <= maximumBytes {
                best = candidate
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint - 1
            }
        }
        return try encode(ContextPayload(mode: mode, rendered: best, truncated: true))
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private func currentInstallation() -> InstallationMetadata {
    InstallationMetadata.load(enclosing: currentExecutableURL())
}

private func currentExecutableURL() -> URL {
    let argument = CommandLine.arguments[0]
    if argument.contains("/") {
        return URL(filePath: argument).absoluteURL
    }
    for directory in ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":") {
        let candidate = URL(filePath: String(directory)).appending(path: argument)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return Bundle.main.executableURL ?? URL(filePath: argument).absoluteURL
}

private func openUpdate(path: String) throws {
    let output = try ProcessRunner().run(
        executable: URL(filePath: "/usr/bin/open"),
        arguments: ["trackify://update/\(path)"],
        workingDirectory: nil,
        environment: nil,
        outputLimit: 64 * 1_024
    )
    guard output.status == 0 else {
        throw ProcessRunnerError.failed(executable: "/usr/bin/open", status: output.status, output: output.utf8)
    }
}

private func updateInstruction(for action: UpdateInstallAction) -> String {
    switch action {
    case .sparkle: "Open Trackify to install the signed update."
    case .homebrew: "Run brew upgrade --cask trackify; Homebrew owns this installation."
    case .managed: "Your organization owns updates for this installation."
    case .disabled: "Updates are disabled for this development or unconfigured build."
    }
}

private func writeUpdateStatus(
    metadata: InstallationMetadata,
    state: String,
    outputOptions: OutputOptions
) throws {
    let payload = UpdateStatusPayload(
        origin: metadata.origin,
        currentVersion: metadata.version,
        build: metadata.build,
        state: state,
        installAction: metadata.updateAction,
        instruction: updateInstruction(for: metadata.updateAction),
        requiresRelaunch: metadata.updateAction == .sparkle
    )
    if outputOptions.json {
        try JSONOutput.write(payload)
    } else {
        print("Trackify \(metadata.version) (\(metadata.build))")
        print("Installation: \(metadata.origin.rawValue)")
        print("Update owner: \(metadata.updateAction.rawValue)")
        print(payload.instruction)
    }
}

private enum TrackifyBuildVersion {
    static var current: String {
        currentInstallation().version
    }
}
