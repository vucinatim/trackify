import Foundation
import Testing
import TrackifyDomain
import TrackifyStore

@testable import TrackifyEngine

@Suite("Canonical evidence integrity")
struct EvidenceIntegrityTests {
    @Test("Rebuild coverage includes today and the preceding local calendar days")
    func boundedRebuildCoverage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Ljubljana"))
        let cutoff = try #require(
            ISO8601DateFormatter().date(from: "2026-08-07T13:45:00Z"))
        let coverage = try EvidenceRebuildCoverage.recentCalendarDays(
            7, cutoff: cutoff, calendar: calendar)
        let expectedStart = try #require(
            ISO8601DateFormatter().date(from: "2026-07-31T22:00:00Z"))

        #expect(coverage.calendarDays == 7)
        #expect(coverage.cutoff == cutoff)
        #expect(coverage.start == expectedStart)
        #expect(coverage.interval.end == cutoff)
        #expect(coverage.interval.contains(cutoff.addingTimeInterval(-1)))
        #expect(throws: EvidenceRebuildError.self) {
            try EvidenceRebuildCoverage.recentCalendarDays(
                0, cutoff: cutoff, calendar: calendar)
        }
    }

    @Test("Validated evidence coverage and source read audit persist together")
    func persistedCoverageAudit() async throws {
        try await withIntegrityStore { store in
            let start = Date(timeIntervalSince1970: 1_786_089_600)
            let coverage = EvidenceLedgerCoverage(
                calendarDays: 7,
                start: start,
                cutoff: start.addingTimeInterval(7 * 86_400),
                recordedAt: start.addingTimeInterval(7 * 86_400),
                canonicalFingerprint: "fixture",
                sourceReads: [
                    EvidenceSourceReadAudit(
                        sourceKey: "codex", unit: .file,
                        candidatesConsidered: 2, unitsOpened: 1,
                        bytesRead: 120, recordsObserved: 4, recordsAccepted: 3)
                ])
            try store.replaceEvidenceCoverage(coverage)
            #expect(try store.evidenceCoverage() == coverage)
        }
    }

    @Test("Codex dual record families resolve to one logical message")
    func codexDualFamilyIdentity() async throws {
        try await withIntegrityStore { store in
            let lines = [
                #"{"timestamp":"2026-08-07T08:00:00.000Z","type":"session_meta","payload":{"id":"dual","cwd":"/workspace/project"}}"#,
                #"{"timestamp":"2026-08-07T08:00:01.000Z","type":"turn_context","payload":{"turn_id":"turn-1","cwd":"/workspace/project"}}"#,
                #"{"timestamp":"2026-08-07T08:00:02.000Z","type":"event_msg","payload":{"type":"user_message","turn_id":"turn-1","client_id":"event-wrapper","message":"Implement the canonical projection"}}"#,
                #"{"timestamp":"2026-08-07T08:00:02.000Z","type":"response_item","payload":{"type":"message","id":"response-wrapper","turn_id":"turn-1","role":"user","content":[{"type":"input_text","text":"Implement the canonical projection"}]}}"#,
            ].map { Data($0.utf8) }
            let parsed = try CodexConversationParser().parse(
                lines: lines, fallbackSessionID: "fallback",
                observedAt: Date(timeIntervalSince1970: 1_786_089_700))
            #expect(parsed.messages.count == 2)
            #expect(Set(parsed.messages.map(\.id)).count == 1)
            #expect(Set(parsed.normalizedRecords.map(\.id)).count == parsed.normalizedRecords.count)

            _ = try await CollectionEngine(store: store).ingest(
                CollectionBatch(
                    sourceKey: "dual", sessions: [parsed.session],
                    messages: parsed.messages,
                    conversationRecords: parsed.normalizedRecords,
                    records: parsed.records))
            let audit = try store.canonicalAudit()
            #expect(audit.workTurns == 1)
            #expect(audit.workMessages == 1)
            #expect(audit.aliases == 1)
        }
    }

    @Test("Known Codex completion and goal events remain control evidence")
    func codexKnownTransportFamilies() throws {
        let lines = [
            #"{"timestamp":"2026-08-07T08:00:00.000Z","type":"session_meta","payload":{"id":"transport","cwd":"/workspace/project"}}"#,
            #"{"timestamp":"2026-08-07T08:00:01.000Z","type":"turn_context","payload":{"turn_id":"turn-1","cwd":"/workspace/project"}}"#,
            #"{"timestamp":"2026-08-07T08:00:02.000Z","type":"event_msg","payload":{"type":"mcp_tool_call_end","turn_id":"turn-1","call_id":"call-1"}}"#,
            #"{"timestamp":"2026-08-07T08:00:03.000Z","type":"event_msg","payload":{"type":"thread_goal_updated","turn_id":"turn-1"}}"#,
            #"{"timestamp":"2026-08-07T08:00:04.000Z","type":"event_msg","payload":{"type":"thread_rolled_back","turn_id":"turn-1"}}"#,
        ].map { Data($0.utf8) }
        let parsed = try CodexConversationParser().parse(
            lines: lines, fallbackSessionID: "fallback", observedAt: Date())
        let types = Set(parsed.normalizedRecords.map(\.provenance.sourceRecordType))
        #expect(types.contains("event_msg.mcp_tool_call_end"))
        #expect(types.contains("event_msg.thread_goal_updated"))
        #expect(types.contains("event_msg.thread_rolled_back"))
        #expect(parsed.unknownRecordCount == 0)
        #expect(parsed.normalizedRecords.allSatisfy { $0.provenance.disposition != .unresolved })
    }

    @Test("Codex multi-agent coordination remains non-metric control evidence")
    func codexMultiAgentControlEvidence() throws {
        let lines = [
            #"{"timestamp":"2026-08-13T19:00:00.000Z","type":"session_meta","payload":{"id":"multi-agent","cwd":"/workspace/project"}}"#,
            #"{"timestamp":"2026-08-13T19:00:01.000Z","type":"turn_context","payload":{"turn_id":"turn-1","cwd":"/workspace/project"}}"#,
            #"{"timestamp":"2026-08-13T19:00:02.000Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"event-1","agent_thread_id":"agent-1","agent_path":"worker","kind":"started","occurred_at_ms":1786647602000}}"#,
            #"{"timestamp":"2026-08-13T19:00:03.000Z","type":"inter_agent_communication_metadata","payload":{"trigger_turn":true}}"#,
        ].map { Data($0.utf8) }
        let parsed = try CodexConversationParser().parse(
            lines: lines, fallbackSessionID: "fallback", observedAt: Date())
        let records = parsed.normalizedRecords.filter {
            $0.provenance.sourceRecordType == "event_msg.sub_agent_activity"
                || $0.provenance.sourceRecordType == "inter_agent_communication_metadata"
        }

        #expect(records.count == 2)
        #expect(parsed.unknownRecordCount == 0)
        #expect(records.allSatisfy { $0.provenance.disposition == .control })
        #expect(records.allSatisfy { $0.provenance.semanticKind == .control })
        #expect(records.allSatisfy { $0.role == nil && $0.normalizedText == nil })
    }

    @Test("Equal text in distinct authoritative turns remains distinct")
    func repeatedPromptIdentity() throws {
        let lines = [
            #"{"timestamp":"2026-08-07T08:00:00.000Z","type":"session_meta","payload":{"id":"repeated","cwd":"/workspace/project"}}"#,
            #"{"timestamp":"2026-08-07T08:00:01.000Z","type":"event_msg","payload":{"type":"user_message","turn_id":"turn-1","message":"Run the tests"}}"#,
            #"{"timestamp":"2026-08-07T08:10:01.000Z","type":"event_msg","payload":{"type":"user_message","turn_id":"turn-2","message":"Run the tests"}}"#,
        ].map { Data($0.utf8) }
        let parsed = try CodexConversationParser().parse(
            lines: lines, fallbackSessionID: "fallback", observedAt: Date())
        #expect(parsed.messages.count == 2)
        #expect(Set(parsed.messages.map(\.id)).count == 2)
        #expect(Set(parsed.messages.compactMap(\.provenance.logicalTurnID)).count == 2)
    }

    @Test("Claude sidechain tasks remain distinct from parent intent")
    func claudeSidechainTurnLineage() throws {
        let lines = [
            #"{"type":"user","sessionId":"parallel","uuid":"human","promptId":"shared","timestamp":"2026-08-07T08:00:00.000Z","cwd":"/workspace/project","message":{"role":"user","content":"Parent intent"}}"#,
            #"{"type":"user","sessionId":"parallel","uuid":"agent-task","promptId":"shared","isSidechain":true,"timestamp":"2026-08-07T08:00:01.000Z","cwd":"/workspace/project","message":{"role":"user","content":"Delegated task"}}"#,
            #"{"type":"assistant","sessionId":"parallel","uuid":"agent-answer","parentUuid":"agent-task","isSidechain":true,"timestamp":"2026-08-07T08:00:02.000Z","cwd":"/workspace/project","message":{"id":"agent-response","role":"assistant","content":"Delegated progress","stop_reason":"end_turn"}}"#,
            #"{"type":"pr-link","sessionId":"parallel","uuid":"link","parentUuid":"human","timestamp":"2026-08-07T08:00:03.000Z","cwd":"/workspace/project"}"#,
            #"{"type":"user","sessionId":"parallel","uuid":"auth","promptId":"auth-turn","timestamp":"2026-08-07T08:00:04.000Z","cwd":"/workspace/project","message":{"role":"user","content":"auth"}}"#,
        ].map { Data($0.utf8) }
        let parsed = try ClaudeConversationParser().parse(
            lines: lines, fallbackSessionID: "fallback", observedAt: Date())
        let intents = parsed.messages.filter { $0.provenance.semanticKind == .intent }
        let auth = try #require(
            parsed.messages.first {
                $0.provenance.classificationReason == "claude-auth-command"
            })
        let link = try #require(
            parsed.normalizedRecords.first {
                $0.provenance.sourceRecordType == "pr-link"
            })

        #expect(intents.count == 2)
        #expect(Set(intents.compactMap(\.provenance.logicalTurnID)).count == 2)
        #expect(Set(intents.map(\.provenance.origin)) == [.human, .agent])
        #expect(auth.provenance.disposition == .diagnostic)
        #expect(auth.provenance.semanticKind == .control)
        #expect(link.provenance.disposition == .control)
    }

    @Test("Claude compacted transcript context never becomes human work")
    func claudeCompactedContext() throws {
        let lines = [
            #"{"type":"user","sessionId":"compacted","uuid":"summary","parentUuid":"previous","promptId":"summary-turn","timestamp":"2026-08-07T08:00:00.000Z","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"Synthesized prior conversation context"}}"#
        ].map { Data($0.utf8) }
        let parsed = try ClaudeConversationParser().parse(
            lines: lines, fallbackSessionID: "fallback", observedAt: Date())
        let message = try #require(parsed.messages.first)

        #expect(message.provenance.origin == .system)
        #expect(message.provenance.disposition == .control)
        #expect(message.provenance.semanticKind == .control)
        #expect(message.provenance.isMeta)
        #expect(message.provenance.classificationReason == "claude-provider-generated-context")
        #expect(parsed.records.allSatisfy { $0.event.kind != .agentRunStarted })
    }

    @Test("Claude classification and lineage do not depend on parser batch boundaries")
    func claudeBatchBoundaryIndependence() throws {
        let lines = [
            #"{"type":"user","sessionId":"batch","uuid":"human","promptId":"main","timestamp":"2026-08-07T08:00:00.000Z","message":{"role":"user","content":"Parent intent"}}"#,
            #"{"type":"assistant","sessionId":"batch","uuid":"main-answer","parentUuid":"human","timestamp":"2026-08-07T08:00:01.000Z","message":{"id":"main-response","role":"assistant","content":"Progress","stop_reason":"end_turn"}}"#,
            #"{"type":"user","sessionId":"batch","uuid":"agent-task","promptId":"main","isSidechain":true,"timestamp":"2026-08-07T08:00:02.000Z","message":{"role":"user","content":"Delegated task"}}"#,
            #"{"type":"assistant","sessionId":"batch","uuid":"agent-answer","parentUuid":"agent-task","isSidechain":true,"timestamp":"2026-08-07T08:00:03.000Z","message":{"id":"agent-response","role":"assistant","content":"Delegated progress","stop_reason":"end_turn"}}"#,
            #"{"type":"user","sessionId":"batch","uuid":"auth","promptId":"auth-turn","timestamp":"2026-08-07T08:00:04.000Z","message":{"role":"user","content":"auth"}}"#,
            #"{"type":"assistant","sessionId":"batch","uuid":"failure","parentUuid":"auth","timestamp":"2026-08-07T08:00:05.000Z","message":{"id":"failure-response","role":"assistant","content":"Invalid API key","stop_reason":"end_turn"}}"#,
            #"{"type":"pr-link","sessionId":"batch","uuid":"link","parentUuid":"human","timestamp":"2026-08-07T08:00:06.000Z"}"#,
        ].map { Data($0.utf8) }
        let parser = ClaudeConversationParser()
        let whole = try parser.parse(
            lines: lines, fallbackSessionID: "fallback", observedAt: Date())
        var state = ConversationParserState()
        var chunkedMessages: [ConversationMessage] = []
        var chunkedRecords: [NormalizedConversationRecord] = []
        for line in lines {
            let parsed = try parser.parse(
                lines: [line], fallbackSessionID: "fallback",
                observedAt: Date(), previousState: state)
            state = parsed.parserState
            chunkedMessages.append(contentsOf: parsed.messages)
            chunkedRecords.append(contentsOf: parsed.normalizedRecords)
        }

        let wholeMessages = Dictionary(
            uniqueKeysWithValues: whole.messages.map {
                ($0.id, $0.provenance)
            })
        let boundaryMessages = Dictionary(
            uniqueKeysWithValues: chunkedMessages.map {
                ($0.id, $0.provenance)
            })
        let wholeRecords = Dictionary(
            uniqueKeysWithValues: whole.normalizedRecords.map {
                ($0.id, $0.provenance)
            })
        let boundaryRecords = Dictionary(
            uniqueKeysWithValues: chunkedRecords.map {
                ($0.id, $0.provenance)
            })
        #expect(wholeMessages == boundaryMessages)
        #expect(wholeRecords == boundaryRecords)
    }

    @Test("Logical turn origin is deterministic regardless of message order")
    func deterministicTurnOrigin() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-turn-order-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try LedgerStore(databaseURL: directory.appending(path: "first.sqlite"))
        let second = try LedgerStore(databaseURL: directory.appending(path: "second.sqlite"))
        let lines = [
            #"{"timestamp":"2026-08-07T08:00:00.000Z","type":"session_meta","payload":{"id":"turn-order","cwd":"/workspace/project"}}"#,
            #"{"timestamp":"2026-08-07T08:00:01.000Z","type":"turn_context","payload":{"turn_id":"turn-1","cwd":"/workspace/project"}}"#,
            #"{"timestamp":"2026-08-07T08:00:02.000Z","type":"event_msg","payload":{"type":"user_message","turn_id":"turn-1","message":"Intent"}}"#,
            #"{"timestamp":"2026-08-07T08:00:03.000Z","type":"response_item","payload":{"type":"message","id":"answer","turn_id":"turn-1","role":"assistant","content":[{"type":"output_text","text":"Progress"}]}}"#,
        ].map { Data($0.utf8) }
        let parsed = try CodexConversationParser().parse(
            lines: lines, fallbackSessionID: "fallback", observedAt: Date())
        _ = try await CollectionEngine(store: first).ingest(
            CollectionBatch(
                sourceKey: "first", sessions: [parsed.session],
                messages: parsed.messages, records: []))
        _ = try await CollectionEngine(store: second).ingest(
            CollectionBatch(
                sourceKey: "second", sessions: [parsed.session],
                messages: parsed.messages.reversed(), records: []))
        #expect(try first.canonicalAudit() == second.canonicalAudit())
    }

    @Test("Hook and provider failure traffic cannot become work activity")
    func diagnosticLoopExclusion() async throws {
        try await withIntegrityStore { store in
            let lines = [
                #"{"type":"user","sessionId":"loop","uuid":"u1","promptId":"p1","timestamp":"2026-08-07T09:00:00.000Z","cwd":"/workspace/project","message":{"role":"user","content":"Stop hook feedback: keep waiting"}}"#,
                #"{"type":"assistant","sessionId":"loop","uuid":"a1","parentUuid":"u1","timestamp":"2026-08-07T09:00:01.000Z","cwd":"/workspace/project","message":{"id":"r1","role":"assistant","content":[{"type":"text","text":"Out of extra usage"}],"stop_reason":"end_turn"}}"#,
            ].map { Data($0.utf8) }
            let parsed = try ClaudeConversationParser().parse(
                lines: lines, fallbackSessionID: "fallback", observedAt: Date())
            #expect(parsed.messages.allSatisfy { $0.provenance.disposition == .diagnostic })
            _ = try await CollectionEngine(store: store).ingest(
                CollectionBatch(
                    sourceKey: "loop", sessions: [parsed.session], messages: parsed.messages,
                    conversationRecords: parsed.normalizedRecords, records: parsed.records))
            let range = DateInterval(
                start: Date(timeIntervalSince1970: 1_786_089_600), duration: 3_600)
            let activity = try ActivityQueries().snapshot(
                store: store, range: range, cutoff: range.end)
            #expect(activity.llmTurns == 0)
            #expect(activity.activeHours == 0)
            #expect(activity.conversationMessages == 0)
            #expect(try store.canonicalAudit().diagnosticRecords == 2)
        }
    }

    @Test("Unknown source semantics quarantine and degrade evidence quality")
    func unknownSemanticsAreVisible() async throws {
        try await withIntegrityStore { store in
            let parsed = try ClaudeConversationParser().parse(
                lines: [
                    Data(#"{"type":"future-transport-v99","sessionId":"future","uuid":"x1","timestamp":"2026-08-07T10:00:00.000Z"}"#.utf8)
                ],
                fallbackSessionID: "future", observedAt: Date())
            _ = try await CollectionEngine(store: store).ingest(
                CollectionBatch(
                    sourceKey: "future", sessions: [parsed.session],
                    conversationRecords: parsed.normalizedRecords, records: parsed.records))
            let quality = try store.refreshEvidenceQualityAudit(at: Date())
            #expect(quality.state == .degraded)
            #expect(quality.unresolvedRecordCount == 1)
            #expect(quality.issues.contains { $0.code == "unresolved-record" })
        }
    }

    @Test("Semantic doctor catches work intent without a logical turn")
    func missingLogicalTurnInvariant() async throws {
        try await withIntegrityStore { store in
            let date = Date(timeIntervalSince1970: 1_786_089_600)
            let session = ConversationSession(
                id: SessionID("broken-session"), source: .claude,
                sourceSessionID: "broken", lastObservedAt: date, state: .inProgress)
            try store.upsert(session: session)
            let message = ConversationMessage(
                id: MessageID("broken-message"), sessionID: session.id,
                sourceMessageID: "broken-message", role: .user,
                occurredAt: date, normalizedText: "A real request",
                fingerprint: "broken-fingerprint",
                provenance: ConversationProvenance(
                    sourceRecordID: "broken-message", sourceRecordType: "user",
                    origin: .human, semanticKind: .intent, disposition: .work,
                    classificationReason: "fixture-missing-turn",
                    logicalMessageID: LogicalMessageID("broken-message")))
            try store.upsert(message: message)
            let quality = try store.refreshEvidenceQualityAudit(at: date)
            #expect(quality.state == .degraded)
            #expect(quality.issues.contains { $0.code == "work-message-without-logical-turn" })
        }
    }

    @Test("Non-metric evidence notices remain warnings without degrading doctor health")
    func nonMetricEvidenceWarning() async throws {
        try await withIntegrityStore { store in
            let lines = [
                #"{"timestamp":"2026-08-07T08:00:00.000Z","type":"session_meta","payload":{"id":"warning","cwd":"/workspace/unregistered"}}"#,
                #"{"timestamp":"2026-08-07T08:00:01.000Z","type":"event_msg","payload":{"type":"user_message","turn_id":"turn-1","message":"Implement the bounded ledger"}}"#,
            ].map { Data($0.utf8) }
            let parsed = try CodexConversationParser().parse(
                lines: lines, fallbackSessionID: "fallback", observedAt: Date())
            _ = try await CollectionEngine(store: store).ingest(
                CollectionBatch(
                    sourceKey: "warning", sessions: [parsed.session],
                    messages: parsed.messages,
                    conversationRecords: parsed.normalizedRecords,
                    records: parsed.records))

            let report = try Doctor().inspect(store: store)
            #expect(report.state == .healthy)
            #expect(report.problems.isEmpty)
            #expect(report.warnings.contains { $0.contains("work-repository-unresolved") })
        }
    }

    @Test("Provider processes receive a registered private operation envelope")
    func registeredProviderEnvelope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-provider-envelope-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerStore(databaseURL: directory.appending(path: "trackify.sqlite"))
        let provider = ContextInspectingProvider()
        let date = Date(timeIntervalSince1970: 1_786_089_600)
        let activity = ActivitySnapshot(
            rangeStart: date, rangeEnd: date.addingTimeInterval(1),
            activeHours: 0, llmTurns: 0, conversationMessages: 0,
            commits: 0, additions: 0, deletions: 0, filesChanged: 0,
            repositoryIDs: [], evidenceCount: 0,
            firstEvidenceAt: nil, lastEvidenceAt: nil)
        let packet = ReportEvidencePacket(
            schemaVersion: 4, periodStart: date,
            periodEnd: date.addingTimeInterval(1), state: .noActivity,
            activity: activity, events: [])
        _ = try await RegisteredProviderInvocation.generate(
            provider: provider, providerID: .codex, packet: packet,
            recipe: nil, purpose: "integrity-test", store: store,
            allowanceReader: NoProviderAllowanceReader(),
            now: { date })
        #expect(try store.internalProviderOperationStates() == ["succeeded": 1])
        #expect(await provider.sawMarker)
        #expect(await provider.sawEnvironment)
    }
}

private actor ContextInspectingProvider: SummaryProvider {
    nonisolated let id = "fixture"
    nonisolated let model = "fixture"
    private(set) var sawMarker = false
    private(set) var sawEnvironment = false

    func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        ProviderSummary(summary: "fixture", topics: [], evidenceAliases: [])
    }

    func generate(
        _ packet: ReportEvidencePacket,
        recipe: ReportRecipeVersion?,
        context: ProviderInvocationContext
    ) async throws -> ProviderGenerationResult {
        sawMarker = FileManager.default.fileExists(
            atPath: context.workingDirectory
                .appending(path: ".trackify-internal-operation").path)
        sawEnvironment = context.environment["TRACKIFY_INTERNAL_OPERATION_ID"] == context.operationID
        return ProviderGenerationResult(
            summary: ProviderSummary(summary: "fixture", topics: [], evidenceAliases: []),
            invocationVersion: "fixture")
    }
}

private func withIntegrityStore(
    _ body: (LedgerStore) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "trackify-integrity-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LedgerStore(databaseURL: directory.appending(path: "trackify.sqlite"))
    try await body(store)
}
