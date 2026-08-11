import Foundation
import TrackifyDomain
import TrackifyStore

public enum ProviderHealthState: String, Codable, Sendable {
    case notInstalled = "not_installed"
    case authenticationUnknown = "authentication_unknown"
    case ready
    case unavailable
}

public struct ProviderHealth: Codable, Equatable, Sendable {
    public let providerID: String
    public let state: ProviderHealthState
    public let executablePath: String?
    public let detail: String?
}

public enum SummaryProviderError: Error, Equatable, LocalizedError {
    case executableNotFound(String)
    case packetTooLarge(Int)
    case processFailed(provider: String, status: Int32)
    case authenticationFailed(String)
    case rateLimited(String)
    case modelUnavailable(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let provider):
            return "\(provider) CLI is not installed."
        case .packetTooLarge(let limit):
            return "The redacted report evidence exceeded the \(limit)-byte provider limit."
        case .processFailed(let provider, let status):
            return "\(provider) exited with status \(status)."
        case .authenticationFailed(let provider):
            return "\(provider) rejected the saved authentication context."
        case .rateLimited(let provider):
            return "\(provider) reported a rate or usage limit."
        case .modelUnavailable(let provider):
            return "\(provider) reported that the requested model is unavailable."
        case .invalidResponse(let provider):
            return "\(provider) returned an invalid structured report."
        }
    }
}

public struct CodexSummaryProvider: SummaryProvider, Sendable {
    public static let invocationVersion = "codex-cli-v2"
    public let id = "codex-cli"
    public let model: String
    private let executable: URL?
    private let runner: any InputCommandRunning

    public init(
        model: String = "gpt-5.6-sol",
        executable: URL? = ExecutableLocator.find(
            "codex",
            additionalPaths: ["/Applications/ChatGPT.app/Contents/Resources/codex"]
        ),
        runner: any InputCommandRunning = ProcessRunner(timeout: 180)
    ) {
        self.model = model
        self.executable = executable
        self.runner = runner
    }

    public func health() -> ProviderHealth {
        ProviderHealthInspector().codex(executable: executable)
    }

    public func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        try await generate(packet, recipe: nil).summary
    }

    public func generate(
        _ packet: ReportEvidencePacket,
        recipe: ReportRecipeVersion?
    ) async throws -> ProviderGenerationResult {
        let context = try ProviderInvocationContext.create(purpose: "direct-report")
        defer { context.cleanup() }
        return try await generate(packet, recipe: recipe, context: context)
    }

    public func generate(
        _ packet: ReportEvidencePacket,
        recipe: ReportRecipeVersion?,
        context: ProviderInvocationContext
    ) async throws -> ProviderGenerationResult {
        guard let executable else { throw SummaryProviderError.executableNotFound("Codex") }
        let input = try ProviderPrompt.make(packet, recipe: recipe)
        let directory = context.workingDirectory
        let schemaURL = directory.appending(path: "report.schema.json")
        let outputURL = directory.appending(path: "report.json")
        try ProviderPrompt.schema.write(to: schemaURL, options: .atomic)
        let arguments = [
            "exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules",
            "--sandbox", "read-only", "--skip-git-repo-check",
            "--model", model,
            "-c", "model_reasoning_effort=\"medium\"",
            "--output-schema", schemaURL.path,
            "--output-last-message", outputURL.path,
            "-",
        ]
        let output = try await runner.runAsync(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: internalEnvironment(context: context),
            input: input,
            outputLimit: 2 * 1_024 * 1_024
        )
        guard output.status == 0 else {
            throw ProviderProcessFailure.classify(
                provider: "Codex", status: output.status, output: output.data)
        }
        let response = try Data(contentsOf: outputURL)
        return ProviderGenerationResult(
            summary: try ProviderPrompt.result(from: response, provider: "Codex", packet: packet),
            usage: ProviderUsageParser.codex(output.data),
            effectiveModel: ProviderUsageParser.effectiveModel(output.data) ?? model,
            invocationVersion: Self.invocationVersion)
    }
}

public struct ClaudeSummaryProvider: SummaryProvider, Sendable {
    public static let invocationVersion = "claude-cli-v2"
    public let id = "claude-cli"
    public let model: String
    private let executable: URL?
    private let runner: any InputCommandRunning

    public init(
        model: String = "opus",
        executable: URL? = ClaudeExecutableLocator.find(),
        runner: any InputCommandRunning = ProcessRunner(timeout: 180)
    ) {
        self.model = model
        self.executable = executable
        self.runner = runner
    }

    public func health() -> ProviderHealth {
        ProviderHealthInspector().claude(executable: executable)
    }

    public func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        try await generate(packet, recipe: nil).summary
    }

    public func generate(
        _ packet: ReportEvidencePacket,
        recipe: ReportRecipeVersion?
    ) async throws -> ProviderGenerationResult {
        let context = try ProviderInvocationContext.create(purpose: "direct-report")
        defer { context.cleanup() }
        return try await generate(packet, recipe: recipe, context: context)
    }

    public func generate(
        _ packet: ReportEvidencePacket,
        recipe: ReportRecipeVersion?,
        context: ProviderInvocationContext
    ) async throws -> ProviderGenerationResult {
        guard let executable else { throw SummaryProviderError.executableNotFound("Claude") }
        let input = try ProviderPrompt.make(packet, recipe: recipe)
        let schema = String(decoding: ProviderPrompt.schema, as: UTF8.self)
        let directory = context.workingDirectory
        let arguments = [
            "--print", "--no-session-persistence", "--model", model,
            "--tools", "", "--strict-mcp-config",
            "--setting-sources", "", "--disable-slash-commands", "--no-chrome",
            "--system-prompt",
            "Render only the requested evidence-backed report JSON. Never use tools or infer unsupported facts.",
            "--output-format", "json", "--json-schema", schema,
        ]
        let output = try await runner.runAsync(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: internalEnvironment(context: context),
            input: input,
            outputLimit: 2 * 1_024 * 1_024
        )
        guard output.status == 0 else {
            throw ProviderProcessFailure.classify(
                provider: "Claude", status: output.status, output: output.data)
        }
        return ProviderGenerationResult(
            summary: try ProviderPrompt.result(from: output.data, provider: "Claude", packet: packet),
            usage: ProviderUsageParser.claude(output.data),
            effectiveModel: ProviderUsageParser.effectiveModel(output.data) ?? model,
            invocationVersion: Self.invocationVersion)
    }
}

private enum ProviderProcessFailure {
    static func classify(provider: String, status: Int32, output: Data) -> SummaryProviderError {
        let detail = String(decoding: output.prefix(64 * 1_024), as: UTF8.self).lowercased()
        if containsAny(
            detail,
            [
                "authentication", "authenticate", "unauthorized", "not authenticated",
                "oauth session expired", "log in", "login required", "api key",
            ]
        ) {
            return .authenticationFailed(provider)
        }
        if containsAny(
            detail,
            ["rate limit", "rate_limit", "usage limit", "quota exceeded", "too many requests", "overloaded"]
        ) {
            return .rateLimited(provider)
        }
        if detail.contains("model"),
            containsAny(detail, ["not found", "unavailable", "not available", "does not exist", "unsupported"])
        {
            return .modelUnavailable(provider)
        }
        return .processFailed(provider: provider, status: status)
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains(where: value.contains)
    }
}

public struct ProviderHealthInspector: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessRunner(timeout: 5)) {
        self.runner = runner
    }

    public func codex(executable: URL?) -> ProviderHealth {
        guard let executable else {
            return ProviderHealth(
                providerID: "codex-cli",
                state: .notInstalled,
                executablePath: nil,
                detail: "Install Codex CLI to enable generated summaries."
            )
        }
        _ = runner
        return ProviderHealth(
            providerID: "codex-cli", state: .authenticationUnknown,
            executablePath: executable.path,
            detail:
                "Codex is installed. Authentication will be verified by the first enabled Trackify generation or a provider test."
        )
    }

    public func claude(executable: URL?) -> ProviderHealth {
        guard let executable else {
            return ProviderHealth(
                providerID: "claude-cli",
                state: .notInstalled,
                executablePath: nil,
                detail: "Install Claude Code to enable generated summaries."
            )
        }
        // Claude has shipped versions where an unsupported `auth status`
        // command is interpreted as an ordinary prompt and persisted as a
        // conversation. Passive capability discovery must never launch a
        // provider. Readiness is promoted only by an explicit durable
        // invocation outcome in CapabilityDiscovery.generators(store:).
        return ProviderHealth(
            providerID: "claude-cli", state: .authenticationUnknown,
            executablePath: executable.path,
            detail:
                "Claude Code is installed. Authentication will be verified by the first enabled Trackify generation or a provider test."
        )
    }
}

public struct CapabilityDiscovery: @unchecked Sendable {
    private let fileManager: FileManager
    private let runner: any CommandRunning

    public init(
        fileManager: FileManager = .default,
        runner: any CommandRunning = ProcessRunner(timeout: 5)
    ) {
        self.fileManager = fileManager
        self.runner = runner
    }

    public func sources(
        store: LedgerStore,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) -> [SourceCapability] {
        let definitions: [(String, String, String, URL, Int)] = [
            (
                "codex-cli-history", "codex", "Codex CLI/Desktop history", homeDirectory.appending(path: ".codex/sessions"),
                CodexConversationParser.adapterVersion
            ),
            (
                "codex-archive-history", "codex", "Codex archived history", homeDirectory.appending(path: ".codex/archived_sessions"),
                CodexConversationParser.adapterVersion
            ),
            (
                "claude-terminal-history", "claude", "Claude Code terminal history", homeDirectory.appending(path: ".claude/projects"),
                ClaudeConversationParser.adapterVersion
            ),
            (
                "claude-desktop-code-history", "claude", "Claude Desktop Code history",
                homeDirectory.appending(path: "Library/Application Support/Claude/local-agent-mode-sessions"),
                ClaudeConversationParser.adapterVersion
            ),
        ]
        return definitions.map { id, family, surface, location, adapterVersion in
            let state: CapabilityState
            var detail: String?
            if !fileManager.fileExists(atPath: location.path) {
                state = .notFound
            } else if !fileManager.isReadableFile(atPath: location.path) {
                state = .permissionDenied
                detail = "Trackify cannot read this history location."
            } else {
                state = .available
            }
            let statistics = (try? store.sourceStatistics(source: family))
            return SourceCapability(
                id: id, family: family, surface: surface, location: location.path,
                adapterVersion: adapterVersion, state: state, lastProbeAt: now,
                lastSuccessfulImportAt: statistics?.lastObservedAt,
                importedRecordCount: statistics?.records ?? 0, detail: detail)
        }
    }

    public func generators(store: LedgerStore? = nil, now: Date = Date()) -> [GenerationCapability] {
        let codexURL = ExecutableLocator.find(
            "codex", additionalPaths: ["/Applications/ChatGPT.app/Contents/Resources/codex"])
        let claudeURL = ClaudeExecutableLocator.find(
            fileManager: fileManager,
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            runner: runner)
        let discovered = [
            generation(
                id: .codex, executable: codexURL, model: "gpt-5.6-sol",
                invocation: CodexSummaryProvider.invocationVersion, supportsUsage: true,
                health: ProviderHealthInspector(runner: runner).codex(executable: codexURL), now: now),
            generation(
                id: .claude, executable: claudeURL, model: "opus",
                invocation: ClaudeSummaryProvider.invocationVersion, supportsUsage: true,
                health: ProviderHealthInspector(runner: runner).claude(executable: claudeURL), now: now),
        ]
        guard let store else { return discovered }
        return discovered.map { capability in
            guard capability.authentication != .notInstalled,
                let verification = try? store.latestProviderAuthentication(capability.id)
            else { return capability }
            return GenerationCapability(
                id: capability.id, executablePath: capability.executablePath,
                cliVersion: capability.cliVersion, authentication: verification.state,
                structuredOutput: capability.structuredOutput,
                usageReporting: capability.usageReporting,
                hardMonetaryCap: capability.hardMonetaryCap,
                requestedModel: capability.requestedModel,
                effectiveModelKnown: capability.effectiveModelKnown,
                invocationContractVersion: capability.invocationContractVersion,
                lastProbeAt: capability.lastProbeAt,
                detail: verification.state == .ready
                    ? "Readiness was verified by a successful Trackify provider invocation."
                    : [
                        capability.detail,
                        "The latest explicit Trackify invocation also reported an authentication failure.",
                    ].compactMap { $0 }.joined(separator: " "))
        }
    }

    public func effectiveProvider(
        mode: ProviderSelectionMode,
        capabilities: [GenerationCapability]? = nil
    ) -> SummaryProviderID? {
        let values = capabilities ?? generators()
        switch mode {
        case .localOnly: return nil
        case .codex: return .codex
        case .claude: return .claude
        case .automatic:
            // Prefer proven readiness, then let the first enabled generation
            // verify an installed provider whose authentication is still unknown.
            for state in [AuthenticationState.ready, .unknown] {
                if let provider = [SummaryProviderID.codex, .claude].first(where: { id in
                    values.first(where: { $0.id == id })?.authentication == state
                }) {
                    return provider
                }
            }
            return nil
        }
    }

    /// Returns a provider that may be invoked without a separate setup probe.
    /// Unknown authentication is intentionally eligible: the generation itself
    /// is the durable readiness check. Known failures and missing executables are
    /// not retried on every scheduled refresh.
    public func automaticInvocationProvider(
        mode: ProviderSelectionMode,
        capabilities: [GenerationCapability]
    ) -> SummaryProviderID? {
        guard let provider = effectiveProvider(mode: mode, capabilities: capabilities),
            let authentication = capabilities.first(where: { $0.id == provider })?.authentication,
            authentication == .ready || authentication == .unknown
        else { return nil }
        return provider
    }

    private func generation(
        id: SummaryProviderID,
        executable: URL?,
        model: String,
        invocation: String,
        supportsUsage: Bool,
        health: ProviderHealth,
        now: Date
    ) -> GenerationCapability {
        return GenerationCapability(
            id: id, executablePath: executable?.path, cliVersion: nil,
            authentication: authentication(health.state), structuredOutput: executable != nil,
            usageReporting: executable != nil && supportsUsage, hardMonetaryCap: false,
            requestedModel: model, effectiveModelKnown: false,
            invocationContractVersion: invocation, lastProbeAt: now, detail: health.detail)
    }

    private func authentication(_ state: ProviderHealthState) -> AuthenticationState {
        switch state {
        case .ready: .ready
        case .authenticationUnknown: .unknown
        case .unavailable: .unavailable
        case .notInstalled: .notInstalled
        }
    }
}

public enum ExecutableLocator {
    public static func find(
        _ name: String,
        additionalPaths: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let searchPaths =
            additionalPaths
            + (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(filePath: String($0)).appending(path: name).path }
        return searchPaths.lazy
            .map { URL(filePath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

public enum ClaudeExecutableLocator {
    public static func candidates(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(filePath: String($0)).appending(path: "claude") }
        let localCandidate = homeDirectory.appending(path: ".local/bin/claude")
        let versionsRoot = homeDirectory.appending(path: "Library/Application Support/Claude/claude-code")
        let desktopCandidates =
            ((try? fileManager.contentsOfDirectory(
                at: versionsRoot, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? [])
            .sorted {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
            }
            .map { $0.appending(path: "claude.app/Contents/MacOS/claude") }
        var seen: Set<String> = []
        return ([localCandidate] + pathCandidates + desktopCandidates).filter {
            fileManager.isExecutableFile(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    public static func find(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: any CommandRunning = ProcessRunner(timeout: 5)
    ) -> URL? {
        // Keep the runner parameter for source compatibility with callers that
        // injected one before discovery became pure. It is deliberately never
        // invoked.
        _ = runner
        return candidates(
            fileManager: fileManager, homeDirectory: homeDirectory, environment: environment
        ).first
    }
}

public enum SummaryProviderFactory {
    public static func make(_ id: SummaryProviderID) -> any SummaryProvider {
        switch id {
        case .codex: CodexSummaryProvider()
        case .claude: ClaudeSummaryProvider()
        }
    }

    public static func make(_ id: SummaryProviderID, timeout: TimeInterval) -> any SummaryProvider {
        switch id {
        case .codex: CodexSummaryProvider(runner: ProcessRunner(timeout: timeout))
        case .claude: ClaudeSummaryProvider(runner: ProcessRunner(timeout: timeout))
        }
    }

    public static func health() -> [ProviderHealth] {
        [CodexSummaryProvider().health(), ClaudeSummaryProvider().health()]
    }

    public static func selection(
        mode: ProviderSelectionMode,
        capabilities: [GenerationCapability]? = nil
    ) -> (SummaryProviderID, any SummaryProvider)? {
        guard let id = CapabilityDiscovery().effectiveProvider(mode: mode, capabilities: capabilities)
        else { return nil }
        return (id, make(id))
    }
}

private enum ProviderPrompt {
    static let maximumBytes = 256 * 1_024

    static let schema = Data(
        #"{"type":"object","additionalProperties":false,"properties":{"summary":{"type":"string","minLength":1,"maxLength":5000},"compactSummary":{"type":"string","minLength":1,"maxLength":500},"topics":{"type":"array","maxItems":12,"items":{"type":"string","maxLength":160}},"evidenceAliases":{"type":"array","items":{"type":"string"}},"projects":{"type":"array","maxItems":16,"items":{"type":"string","maxLength":160}},"projectSummaries":{"type":"array","maxItems":16,"items":{"type":"object","additionalProperties":false,"properties":{"project":{"type":"string","maxLength":160},"narrative":{"type":"string","maxLength":1600},"intents":{"type":"array","maxItems":12,"items":{"type":"string","maxLength":500}},"outcomes":{"type":"array","maxItems":12,"items":{"type":"string","maxLength":500}},"openWork":{"type":"array","maxItems":12,"items":{"type":"string","maxLength":500}},"blockers":{"type":"array","maxItems":8,"items":{"type":"string","maxLength":500}}},"required":["project","narrative","intents","outcomes","openWork","blockers"]}},"intents":{"type":"array","maxItems":16,"items":{"type":"string","maxLength":500}},"outcomes":{"type":"array","maxItems":16,"items":{"type":"string","maxLength":500}},"openWork":{"type":"array","maxItems":16,"items":{"type":"string","maxLength":500}},"blockers":{"type":"array","maxItems":12,"items":{"type":"string","maxLength":500}}},"required":["summary","compactSummary","topics","evidenceAliases","projects","projectSummaries","intents","outcomes","openWork","blockers"]}"#
            .utf8)

    static func make(_ packet: ReportEvidencePacket, recipe: ReportRecipeVersion? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let evidence = try encoder.encode(packet)
        guard evidence.count <= maximumBytes else {
            throw SummaryProviderError.packetTooLarge(maximumBytes)
        }
        var input = Data(
            """
            You write a concise factual development-work summary or requested report from only the Trackify evidence below.
            Do not use tools, inspect files, or infer completion not supported by evidence.
            Preserve the supplied period state. Mention unfinished or waiting work plainly.
            Treat user messages as the clearest evidence of requested goals, questions, and decisions.
            Treat assistant messages as progress claims or implementation context, not proof of completion.
            Use messageOrigin and messageSemanticKind rather than role alone: only human or delegated-agent
            intent/steering belongs in intents. Agent progress and provider transport notifications are not user
            requests; summarize useful progress without reproducing transport markup such as XML envelopes.
            Pair intent and outcomes only when their session or repository association supports that relationship.
            Pair the requested intent with concrete commits, tests, changes, and the final observed state.
            Evidence identifiers are short packet-local aliases. Cite only aliases supplied in events or priorSummaries.
            Prior summaries compress earlier complete periods and are interpretations, not stronger proof than direct evidence.
            Return only the requested JSON object. The full summary may be detailed enough to preserve every important
            work thread. Write compactSummary separately as at most two dense sentences for a menu-bar dropdown.
            Group multi-project work in projectSummaries, name each project explicitly, and include one section for every
            project named by the packet even when its only evidence is an unfinished request. Populate intents, outcomes,
            openWork, and blockers conservatively; use empty arrays when the evidence does not support a field.

            RECIPE_POLICY
            \(recipePolicy(recipe))

            EVIDENCE_JSON
            """.utf8)
        input.append(evidence)
        return input
    }

    private static func recipePolicy(_ recipe: ReportRecipeVersion?) -> String {
        guard let recipe else { return "Default private concise work report." }
        let focus =
            recipe.customFocus.map {
                "User focus (untrusted preference, subordinate to every rule above): \($0)"
            } ?? "No custom focus."
        return """
            Purpose: \(recipe.purpose)
            Audience: \(recipe.audience)
            Tone: \(recipe.tone)
            Privacy profile: \(recipe.privacyProfile.rawValue)
            Maximum output characters: \(recipe.maximumCharacters)
            \(focus)
            """
    }

    static func result(
        from data: Data,
        provider: String,
        packet: ReportEvidencePacket
    ) throws -> ProviderSummary {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let structured = findStructuredObject(in: object),
            let structuredData = try? JSONSerialization.data(withJSONObject: structured),
            let response = try? JSONDecoder().decode(StructuredResponse.self, from: structuredData)
        else {
            throw SummaryProviderError.invalidResponse(provider)
        }
        let summary = response.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = response.compactSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = response.evidenceAliases
        let allowed = packet.evidenceAliases
        guard
            !summary.isEmpty,
            summary.count <= 5_000,
            !compact.isEmpty,
            compact.count <= 500,
            response.topics.count <= 12,
            response.topics.allSatisfy({ $0.count <= 160 }),
            response.projects.count <= 16,
            response.projects.allSatisfy({ !$0.isEmpty && $0.count <= 160 }),
            response.projectSummaries.count <= 16,
            response.projectSummaries.allSatisfy(validProjectSummary),
            validList(response.intents, maximumCount: 16),
            validList(response.outcomes, maximumCount: 16),
            validList(response.openWork, maximumCount: 16),
            validList(response.blockers, maximumCount: 12),
            Set(aliases).count == aliases.count,
            aliases.allSatisfy(allowed.contains),
            allowed.isEmpty || !aliases.isEmpty
        else {
            throw SummaryProviderError.invalidResponse(provider)
        }
        return ProviderSummary(
            summary: summary, compactSummary: compact,
            topics: response.topics, evidenceAliases: aliases,
            projects: response.projects, projectSummaries: response.projectSummaries,
            intents: response.intents,
            outcomes: response.outcomes, openWork: response.openWork,
            blockers: response.blockers)
    }

    private static func validProjectSummary(_ section: SummaryProjectSection) -> Bool {
        !section.project.isEmpty && section.project.count <= 160
            && !section.narrative.isEmpty && section.narrative.count <= 1_600
            && validList(section.intents, maximumCount: 12)
            && validList(section.outcomes, maximumCount: 12)
            && validList(section.openWork, maximumCount: 12)
            && validList(section.blockers, maximumCount: 8)
    }

    private static func validList(_ values: [String], maximumCount: Int) -> Bool {
        values.count <= maximumCount
            && values.allSatisfy { !$0.isEmpty && $0.count <= 500 }
    }

    private static func findStructuredObject(in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if dictionary["summary"] is String { return dictionary }
            if let structured = dictionary["structured_output"],
                let response = findStructuredObject(in: structured)
            {
                return response
            }
            if let result = dictionary["result"] as? String,
                let data = result.data(using: .utf8),
                let nested = try? JSONSerialization.jsonObject(with: data)
            {
                return findStructuredObject(in: nested)
            }
        }
        return nil
    }

    private struct StructuredResponse: Decodable {
        let summary: String
        let compactSummary: String
        let topics: [String]
        let evidenceAliases: [String]
        let projects: [String]
        let projectSummaries: [SummaryProjectSection]
        let intents: [String]
        let outcomes: [String]
        let openWork: [String]
        let blockers: [String]

        private enum CodingKeys: String, CodingKey {
            case summary, compactSummary, topics, evidenceAliases, projects, projectSummaries
            case intents, outcomes, openWork, blockers
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            summary = try values.decode(String.self, forKey: .summary)
            compactSummary = try values.decodeIfPresent(String.self, forKey: .compactSummary) ?? summary
            topics = try values.decodeIfPresent([String].self, forKey: .topics) ?? []
            evidenceAliases = try values.decodeIfPresent([String].self, forKey: .evidenceAliases) ?? []
            projects = try values.decodeIfPresent([String].self, forKey: .projects) ?? []
            projectSummaries =
                try values.decodeIfPresent(
                    [SummaryProjectSection].self, forKey: .projectSummaries) ?? []
            intents = try values.decodeIfPresent([String].self, forKey: .intents) ?? []
            outcomes = try values.decodeIfPresent([String].self, forKey: .outcomes) ?? []
            openWork = try values.decodeIfPresent([String].self, forKey: .openWork) ?? []
            blockers = try values.decodeIfPresent([String].self, forKey: .blockers) ?? []
        }
    }
}

enum ProviderUsageParser {
    static func codex(_ data: Data) -> ProviderUsage {
        let objects = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Data($0.utf8) }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) }
        let metrics = objects.reduce(into: TokenMetrics()) { collect($1, into: &$0) }
        return metrics.usage(costKind: .unknown, billingContext: "Codex CLI billing context not reported")
    }

    static func claude(_ data: Data) -> ProviderUsage {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return ProviderUsage() }
        var metrics = TokenMetrics()
        collect(object, into: &metrics)
        let cost = findNumber(keys: ["total_cost_usd", "cost_usd"], in: object).map { Decimal($0) }
        return ProviderUsage(
            inputTokens: metrics.input, cachedInputTokens: metrics.cached,
            outputTokens: metrics.output, reasoningTokens: metrics.reasoning,
            cost: cost, currency: cost == nil ? nil : "USD",
            costKind: cost == nil ? .unknown : .providerEstimate,
            billingContext: cost == nil ? "Claude CLI did not report an attributable cost" : "Claude CLI estimate")
    }

    static func effectiveModel(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findString(keys: ["model", "model_name", "effective_model"], in: object)
    }

    private struct TokenMetrics {
        var input: Int?
        var cached: Int?
        var output: Int?
        var reasoning: Int?

        func usage(costKind: CostKind, billingContext: String?) -> ProviderUsage {
            ProviderUsage(
                inputTokens: input, cachedInputTokens: cached, outputTokens: output,
                reasoningTokens: reasoning, costKind: costKind, billingContext: billingContext)
        }
    }

    private static func collect(_ value: Any, into metrics: inout TokenMetrics) {
        if let object = value as? [String: Any] {
            for (key, value) in object {
                let number = (value as? NSNumber)?.intValue
                switch key.lowercased() {
                case "input_tokens", "inputtokens": metrics.input = maximum(metrics.input, number)
                case "cache_read_input_tokens", "cached_input_tokens", "cache_read_tokens":
                    metrics.cached = maximum(metrics.cached, number)
                case "output_tokens", "outputtokens": metrics.output = maximum(metrics.output, number)
                case "reasoning_tokens", "reasoningtokens": metrics.reasoning = maximum(metrics.reasoning, number)
                default: break
                }
                collect(value, into: &metrics)
            }
        } else if let values = value as? [Any] {
            for value in values {
                collect(value, into: &metrics)
            }
        }
    }

    private static func maximum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
        case (.some, .none): lhs
        case (.none, .some): rhs
        case (.none, .none): nil
        }
    }

    private static func findNumber(keys: Set<String>, in value: Any) -> Double? {
        if let object = value as? [String: Any] {
            for (key, value) in object where keys.contains(key.lowercased()) {
                if let number = value as? NSNumber { return number.doubleValue }
            }
            for value in object.values {
                if let found = findNumber(keys: keys, in: value) { return found }
            }
        } else if let values = value as? [Any] {
            for value in values {
                if let found = findNumber(keys: keys, in: value) { return found }
            }
        }
        return nil
    }

    private static func findString(keys: Set<String>, in value: Any) -> String? {
        if let object = value as? [String: Any] {
            for (key, value) in object where keys.contains(key.lowercased()) {
                if let string = value as? String { return string }
            }
            for value in object.values {
                if let found = findString(keys: keys, in: value) { return found }
            }
        } else if let values = value as? [Any] {
            for value in values {
                if let found = findString(keys: keys, in: value) { return found }
            }
        }
        return nil
    }
}

private func internalEnvironment(context: ProviderInvocationContext) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["TRACKIFY_INTERNAL_RUN"] = "1"
    for (key, value) in context.environment { environment[key] = value }
    return environment
}
