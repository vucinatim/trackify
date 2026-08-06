import Foundation
import Testing
import TrackifyDomain
import TrackifyStore

@testable import TrackifyEngine

@Suite("Smart evidence compiler")
struct EvidenceCompilerTests {
    @Test("Selection is deterministic, bounded, aliased, and representative across parallel projects")
    func deterministicParallelSelection() async throws {
        try await withCompilerStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let range = DateInterval(start: start, duration: 3_600)
            let repoA = try addRepository("compiler-repo-a", name: "Trackify", store: store, at: start)
            let repoB = try addRepository("compiler-repo-b", name: "ClientApp", store: store, at: start)
            let sessionA = SessionID("compiler-session-a-stable")
            let sessionB = SessionID("compiler-session-b-stable")
            try store.upsert(
                session: ConversationSession(
                    id: sessionA,
                    source: .codex,
                    sourceSessionID: sessionA.rawValue,
                    startedAt: start,
                    lastObservedAt: range.end,
                    state: .inProgress
                ))
            try store.upsert(
                session: ConversationSession(
                    id: sessionB,
                    source: .claude,
                    sourceSessionID: sessionB.rawValue,
                    startedAt: start,
                    lastObservedAt: range.end,
                    state: .inProgress
                ))

            try addMessage(
                "intent-stable-id",
                text: "Make the smart evidence compiler preserve user intent across parallel projects",
                role: .user,
                repositoryID: repoA.id,
                sessionID: sessionA,
                at: start.addingTimeInterval(30),
                store: store
            )
            for index in 0..<80 {
                try addMessage(
                    "assistant-chatter-\(index)",
                    text: "Progress update \(index): continuing repetitive implementation details that should not crowd out intent.",
                    role: .assistant,
                    repositoryID: repoA.id,
                    sessionID: sessionA,
                    at: start.addingTimeInterval(Double(60 + index)),
                    store: store
                )
            }
            try addEvent(
                "client-failure-stable-id",
                kind: .testFinished,
                repositoryID: repoB.id,
                sessionID: sessionB,
                state: .failed,
                payload: ["suite": "Client export tests", "result": "failed"],
                at: start.addingTimeInterval(300),
                store: store
            )
            try addEvent(
                "trackify-dirty-stable-id",
                kind: .gitWorkingTreeChanged,
                repositoryID: repoA.id,
                state: .inProgress,
                payload: ["clean": "false", "changedFiles": "7", "additions": "90", "deletions": "14"],
                at: start.addingTimeInterval(500),
                store: store
            )
            try addEvent(
                "client-dirty-stable-id",
                kind: .gitWorkingTreeChanged,
                repositoryID: repoB.id,
                state: .inProgress,
                payload: ["clean": "false", "changedFiles": "2"],
                at: start.addingTimeInterval(510),
                store: store
            )

            let compiler = EvidenceCompiler(
                configuration: .init(maxHourlyEvents: 8, maxSerializedBytes: 20 * 1_024)
            )
            let generator = ReportGenerator(compiler: compiler)
            let first = try generator.evidencePacket(store: store, range: range, cutoff: range.end)
            let second = try generator.evidencePacket(store: store, range: range, cutoff: range.end)

            #expect(first == second)
            #expect(first.schemaVersion == 4)
            #expect(first.selection.compilerVersion == EvidenceCompiler.version)
            #expect(first.events.count <= 8)
            #expect(first.selection.omittedEventCount > 70)
            #expect(first.selection.activeContextCount == 2)
            #expect(first.selection.representedContextCount == 2)
            #expect(first.selection.omittedContextCount == 0)
            #expect(first.serializedByteCount <= 20 * 1_024)
            #expect(first.estimatedInputTokens <= 5_120)
            #expect(first.events.contains { $0.messageRole == .user })
            #expect(first.events.count { $0.messageRole == .assistant } <= 3)
            #expect(first.events.contains { $0.kind == .testFinished && $0.state == .failed })
            #expect(Set(first.events.compactMap(\.repositoryName)) == ["Trackify", "ClientApp"])
            #expect(first.events.map(\.eventID.rawValue) == (1...first.events.count).map { "e\($0)" })
            #expect(first.events.allSatisfy { $0.repositoryID?.rawValue.hasPrefix("r") ?? true })
            #expect(first.events.allSatisfy { $0.sessionID?.rawValue.hasPrefix("s") ?? true })

            let encoded = try encodedString(first)
            for stableValue in [
                repoA.id.rawValue, repoB.id.rawValue, sessionA.rawValue, sessionB.rawValue,
                "intent-stable-id", "client-failure-stable-id", "trackify-dirty-stable-id",
            ] {
                #expect(!encoded.contains(stableValue))
            }
            #expect(encoded.contains("user_intent"))
            #expect(encoded.contains("final_state"))
            #expect(encoded.contains("project_coverage"))
        }
    }

    @Test("Compiler keeps concrete commits and removes unrelated payload fields and secrets")
    func concreteEvidenceAndPrivacy() async throws {
        try await withCompilerStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let range = DateInterval(start: start, duration: 3_600)
            let repository = try addRepository("compiler-commit-repo", name: "LedgerKit", store: store, at: start)
            let secret = "sk-example1234567890"
            try store.upsert(
                commit: GitCommit(
                    id: "compiler-commit-id",
                    repositoryID: repository.id,
                    hash: "abcdef123456",
                    authorTime: start.addingTimeInterval(120),
                    message: "Implement compiler without leaking \(secret)",
                    additions: 42,
                    deletions: 5,
                    filesChanged: 3,
                    firstObservedAt: start,
                    lastObservedAt: start,
                    isReachable: true
                ))
            try addEvent(
                "compiler-commit-event-stable",
                kind: .gitCommitObserved,
                repositoryID: repository.id,
                state: .completed,
                payload: [
                    "hash": "abcdef123456",
                    "message": "Implement compiler without leaking \(secret)",
                    "additions": "42",
                    "deletions": "5",
                    "filesChanged": "3",
                    "command": "curl -H Authorization:\(secret)",
                ],
                at: start.addingTimeInterval(120),
                store: store
            )

            let packet = try ReportGenerator().evidencePacket(store: store, range: range, cutoff: range.end)
            let commit = try #require(packet.events.first { $0.kind == .gitCommitObserved })
            let encoded = try encodedString(packet)

            #expect(commit.selectionReasons.contains(.concreteOutcome))
            #expect(commit.payload["message"]?.contains("[REDACTED_OPENAI_KEY]") == true)
            #expect(commit.payload["command"] == nil)
            #expect(commit.payload["hash"] == nil)
            #expect(!encoded.contains(secret))
            #expect(!encoded.contains("compiler-commit-event-stable"))
            #expect(packet.allEvidenceIDs == [EvidenceID("compiler-commit-event-stable-evidence")])
        }
    }

    @Test("Daily packets use active hourly reports across the full day and preserve quiet-hour metadata")
    func hierarchicalDailyPacket() async throws {
        try await withCompilerStore { store in
            let day = Date(timeIntervalSince1970: 1_754_284_800)
            let range = DateInterval(start: day, duration: 86_400)
            let repository = try addRepository("daily-repo", name: "DayLedger", store: store, at: day)
            try addEvent(
                "morning-work",
                kind: .gitWorkingTreeChanged,
                repositoryID: repository.id,
                state: .inProgress,
                payload: ["clean": "false", "changedFiles": "2"],
                at: day.addingTimeInterval(9 * 3_600),
                store: store
            )
            try addEvent(
                "evening-work",
                kind: .gitWorkingTreeChanged,
                repositoryID: repository.id,
                state: .inProgress,
                payload: ["clean": "false", "changedFiles": "4"],
                at: day.addingTimeInterval(20 * 3_600),
                store: store
            )
            try saveHourlyReport(
                id: "morning-report",
                start: day.addingTimeInterval(9 * 3_600),
                state: .completed,
                summary: "Completed the morning evidence compiler foundation.",
                evidenceIDs: [EvidenceID("morning-work-evidence")],
                store: store
            )
            try saveHourlyReport(
                id: "quiet-report",
                start: day.addingTimeInterval(13 * 3_600),
                state: .noActivity,
                summary: "No development activity was detected during this period.",
                evidenceIDs: [],
                store: store
            )
            try saveHourlyReport(
                id: "evening-report",
                start: day.addingTimeInterval(20 * 3_600),
                state: .inProgress,
                summary: "Continued validation in the evening; work remained unfinished.",
                evidenceIDs: [EvidenceID("evening-work-evidence")],
                store: store
            )

            let packet = try ReportGenerator().evidencePacket(store: store, range: range, cutoff: range.end)
            #expect(packet.priorReports.map(\.alias) == ["h1", "h2"])
            #expect(packet.priorReports.map(\.summary).contains { $0.contains("morning") })
            #expect(packet.priorReports.map(\.summary).contains { $0.contains("evening") })
            #expect(packet.selection.totalPriorReportCount == 3)
            #expect(packet.selection.selectedPriorReportCount == 2)
            #expect(packet.selection.omittedQuietReportCount == 1)
            #expect(
                packet.evidenceIDs(for: ["h1", "h2"]) == [
                    EvidenceID("morning-work-evidence"), EvidenceID("evening-work-evidence"),
                ])
            #expect(packet.serializedByteCount <= 20 * 1_024)

            let encoded = try encodedString(packet)
            #expect(encoded.contains("priorReports"))
            #expect(encoded.contains("omittedQuietReportCount"))
            #expect(!encoded.contains("morning-work-evidence"))
            #expect(!encoded.contains("evening-work-evidence"))

            let report = try await ReportGenerator().generate(
                store: store,
                range: range,
                cutoff: range.end,
                provider: PriorReportSummaryProvider()
            )
            #expect(
                report.evidenceIDs == [
                    EvidenceID("morning-work-evidence"), EvidenceID("evening-work-evidence"),
                ])
        }
    }

    @Test("Serialized byte budget trims lower-priority evidence")
    func hardByteBudget() async throws {
        try await withCompilerStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let range = DateInterval(start: start, duration: 3_600)
            let repository = try addRepository("budget-repo", name: "BudgetKit", store: store, at: start)
            let session = SessionID("budget-session")
            try store.upsert(
                session: ConversationSession(
                    id: session,
                    source: .codex,
                    sourceSessionID: session.rawValue,
                    startedAt: start,
                    lastObservedAt: range.end,
                    state: .inProgress
                ))
            for index in 0..<20 {
                try addMessage(
                    "budget-message-\(index)",
                    text: "Detailed progress \(index) " + String(repeating: "bounded evidence ", count: 80),
                    role: index == 0 ? .user : .assistant,
                    repositoryID: repository.id,
                    sessionID: session,
                    at: start.addingTimeInterval(Double(index + 1)),
                    store: store
                )
            }

            let packet = try ReportGenerator(
                compiler: EvidenceCompiler(
                    configuration: .init(maxHourlyEvents: 20, maxSerializedBytes: 2_500)
                )
            ).evidencePacket(store: store, range: range, cutoff: range.end)

            #expect(packet.serializedByteCount <= 2_500)
            #expect(packet.events.count < 20)
            #expect(packet.events.contains { $0.messageRole == .user })
            #expect(packet.selection.omittedEventCount > 0)
        }
    }

    @Test("Provider aliases resolve back to stable evidence provenance")
    func providerAliasResolution() async throws {
        try await withCompilerStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let range = DateInterval(start: start, duration: 3_600)
            let repository = try addRepository("alias-repo", name: "AliasKit", store: store, at: start)
            try addEvent(
                "alias-tree",
                kind: .gitWorkingTreeChanged,
                repositoryID: repository.id,
                state: .inProgress,
                payload: ["clean": "false", "changedFiles": "1"],
                at: start.addingTimeInterval(60),
                store: store
            )

            let report = try await ReportGenerator().generate(
                store: store,
                range: range,
                cutoff: range.end,
                provider: AliasSummaryProvider()
            )

            #expect(report.provider == "alias-test")
            #expect(report.evidenceIDs == [EvidenceID("alias-tree-evidence")])
        }
    }
}

private struct AliasSummaryProvider: SummaryProvider {
    let id = "alias-test"
    let model = "fixture"

    func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        ProviderSummary(
            summary: "Work remained in progress with local provenance.",
            topics: ["compiler"],
            evidenceAliases: [packet.events[0].eventID.rawValue]
        )
    }
}

private struct PriorReportSummaryProvider: SummaryProvider {
    let id = "prior-report-test"
    let model = "fixture"

    func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        ProviderSummary(
            summary: "Morning work completed and evening validation remained in progress.",
            topics: ["daily hierarchy"],
            evidenceAliases: packet.priorReports.map(\.alias)
        )
    }
}

private func addRepository(
    _ id: String,
    name: String,
    store: LedgerStore,
    at date: Date
) throws -> Repository {
    let repository = Repository(
        id: RepositoryID(id),
        displayName: name,
        firstObservedAt: date,
        lastObservedAt: date
    )
    try store.upsert(
        repository: repository,
        workingCopy: WorkingCopy(
            id: WorkingCopyID("\(id)-copy"),
            repositoryID: repository.id,
            canonicalPath: "/tmp/\(id)",
            firstObservedAt: date,
            lastObservedAt: date
        ))
    return repository
}

private func addMessage(
    _ id: String,
    text: String,
    role: MessageRole,
    repositoryID: RepositoryID,
    sessionID: SessionID,
    at date: Date,
    store: LedgerStore
) throws {
    let message = ConversationMessage(
        id: MessageID("\(id)-message"),
        sessionID: sessionID,
        sourceMessageID: id,
        role: role,
        occurredAt: date,
        normalizedText: text,
        fingerprint: "\(id)-fingerprint"
    )
    try store.upsert(message: message)
    try addEvent(
        id,
        kind: .agentMessageObserved,
        repositoryID: repositoryID,
        sessionID: sessionID,
        payload: ["messageID": message.id.rawValue, "role": role.rawValue],
        at: date,
        store: store
    )
}

private func addEvent(
    _ id: String,
    kind: EventKind,
    repositoryID: RepositoryID? = nil,
    sessionID: SessionID? = nil,
    state: ObservedState? = nil,
    payload: [String: String] = [:],
    at date: Date,
    store: LedgerStore
) throws {
    let evidenceID = EvidenceID("\(id)-evidence")
    _ = try store.ingest(
        evidence: SourceEvidence(
            id: evidenceID,
            source: .simulation,
            ingestionPath: .fixture,
            sourceRecordID: id,
            fingerprint: "\(id)-fingerprint",
            occurredAt: date,
            observedAt: date,
            adapterVersion: 1
        ),
        event: LedgerEvent(
            id: EventID(id),
            evidenceID: evidenceID,
            occurredAt: date,
            observedAt: date,
            source: .simulation,
            kind: kind,
            repositoryID: repositoryID,
            sessionID: sessionID,
            state: state,
            payload: payload
        )
    )
}

private func saveHourlyReport(
    id: String,
    start: Date,
    state: ReportPeriodState,
    summary: String,
    evidenceIDs: [EvidenceID],
    store: LedgerStore
) throws {
    try store.save(
        report: WorkReport(
            id: ReportID(id),
            periodStart: start,
            periodEnd: start.addingTimeInterval(3_600),
            state: state,
            summary: summary,
            evidenceIDs: evidenceIDs,
            provider: nil,
            model: nil,
            generatorVersion: "fixture",
            revision: 1
        ))
}

private func encodedString(_ packet: ReportEvidencePacket) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(packet), as: UTF8.self)
}

private func withCompilerStore(
    _ body: (LedgerStore) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "trackify-compiler-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(LedgerStore(databaseURL: directory.appending(path: "ledger.sqlite")))
}
