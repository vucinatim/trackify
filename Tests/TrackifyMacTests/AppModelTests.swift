import Foundation
import Testing
import TrackifyDomain
import TrackifyEngine

@testable import TrackifyMac

@MainActor
@Suite("macOS app model")
struct AppModelTests {
    @Test("Production time advances between refreshes")
    func productionTimeAdvances() {
        let initial = Date(timeIntervalSince1970: 1_786_000_000)
        let clock = MutableWallClock(initial)
        let model = AppModel(environment: [:], clock: clock)

        #expect(model.referenceNow == initial)
        clock.advance(by: 90)
        #expect(model.referenceNow == initial.addingTimeInterval(90))
    }

    @Test("UI validation keeps its deterministic fixed time")
    func validationTimeIsFixed() {
        let fixed = "2026-08-06T12:00:00Z"
        let model = AppModel(environment: [
            "TRACKIFY_UI_VALIDATION": "1",
            "TRACKIFY_UI_NOW": fixed,
        ])

        #expect(model.isUIValidation)
        #expect(model.referenceNow == ISO8601DateFormatter().date(from: fixed))
        #expect(model.referenceNow == model.referenceNow)
    }

    @Test("Menu pause state follows the current budget snapshot")
    func menuPauseStateIsLive() {
        let available = GenerationBudgetStatus(
            allowance: nil, allowanceAttributedPercent: 0, allowancePercentLimit: 3,
            estimatedCreditsUsed: 10, weeklyCreditLimit: 500,
            callsToday: 3, callsPerDayLimit: 30,
            isPaused: false, pauseReason: nil)
        let paused = GenerationBudgetStatus(
            allowance: nil, allowanceAttributedPercent: 3, allowancePercentLimit: 3,
            estimatedCreditsUsed: 10, weeklyCreditLimit: 500,
            callsToday: 3, callsPerDayLimit: 30,
            isPaused: true, pauseReason: "weekly Trackify allowance target")

        #expect(!AppModel.liveBudgetIsPaused(available))
        #expect(AppModel.liveBudgetIsPaused(paused))
    }

    @Test("Evidence-hour selection charts evidence density instead of binary occupancy")
    func evidenceTrendUsesEvidenceItems() {
        let start = Date(timeIntervalSince1970: 1_786_000_000)
        let snapshot = ActivitySnapshot(
            rangeStart: start,
            rangeEnd: start.addingTimeInterval(3_600),
            activeHours: 1,
            llmTurns: 7,
            conversationMessages: 12,
            commits: 2,
            additions: 80,
            deletions: 10,
            filesChanged: 5,
            repositoryIDs: [],
            evidenceCount: 19,
            firstEvidenceAt: start,
            lastEvidenceAt: start.addingTimeInterval(3_000)
        )

        #expect(DashboardMetric.evidenceHours.title == "Evidence hours")
        #expect(DashboardMetric.evidenceHours.hourlySubtitle == "Evidence events by hour")
        #expect(DashboardMetric.evidenceHours.trendValue(snapshot) == 19)
        #expect(DashboardMetric.llmTurns.trendValue(snapshot) == 7)
    }

    @Test("Summary provenance distinguishes direct AI, local rollups, and migrated history")
    func summaryProvenanceIsExplicit() {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let codex = summary(
            id: "codex", now: now, source: .codex, provider: .codex, model: "gpt-test")
        let rollup = summary(
            id: "rollup", now: now, source: .local, children: [codex.id])
        let migrated = summary(id: "migrated", now: now, source: .migrated)
        let summaries = [codex.id: codex, rollup.id: rollup, migrated.id: migrated]

        #expect(
            SummaryProvenancePresentation.resolve(codex, summariesByID: summaries)
                == SummaryProvenancePresentation(
                    kind: .codex, label: "Codex", detail: "gpt-test"))
        #expect(
            SummaryProvenancePresentation.resolve(rollup, summariesByID: summaries).label
                == "Programmatic rollup · Codex")
        #expect(
            SummaryProvenancePresentation.resolve(migrated, summariesByID: summaries).kind
                == .migrated)
        #expect(
            SummaryCoveragePresentation.label(
                SummaryCoverage(
                    eligibleEventCount: 5, coveredEventCount: 3,
                    truncatedAssistantCount: 1))
                == "3/5 covered events · 1 shortened agent response")
    }

    @Test("Usage history combines automatic summaries and user reports")
    func generationHistoryIsComplete() {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let summaryRun = SummaryRun(
            id: SummaryRunID("summary-run"), kind: .segment,
            periodStart: now.addingTimeInterval(-1_800), periodEnd: now,
            selectionMode: .codex, effectiveProvider: .codex,
            effectiveModel: "gpt-test", sourceFingerprint: "source",
            estimatedInputTokens: 1_200, queuedAt: now, state: .succeeded)
        let reportRun = ReportRun(
            id: ReportRunID("report-run"), recipeID: RecipeID("clockify"),
            recipeVersionID: RecipeVersionID("clockify-v1"),
            periodStart: now.addingTimeInterval(-3_600), periodEnd: now,
            intent: .onDemand, selectionMode: .localOnly,
            compilerVersion: "compiler", promptVersion: "prompt",
            outputSchemaVersion: "schema", queuedAt: now.addingTimeInterval(-60),
            state: .succeeded)

        let items = GenerationRunPresentation.merge(
            summaries: [summaryRun], reports: [reportRun],
            templateNames: [RecipeID("clockify"): "Clockify entry"])

        #expect(items.count == 2)
        #expect(items.map(\.kind) == [.summary, .report])
        #expect(items.first?.provider == "Codex · gpt-test")
        #expect(items.last?.title == "Clockify entry")
        #expect(items.last?.usage == "No AI usage")
    }

    private func summary(
        id: String,
        now: Date,
        source: SummaryGenerationSource,
        provider: SummaryProviderID? = nil,
        model: String? = nil,
        children: [SummaryID] = []
    ) -> WorkSummary {
        WorkSummary(
            id: SummaryID(id), kind: children.isEmpty ? .segment : .current,
            periodStart: now.addingTimeInterval(-1_800), periodEnd: now,
            generatedAt: now, state: .completed,
            content: SummaryContent(narrative: "Summary"),
            childSummaryIDs: children, generationSource: source,
            provider: provider, model: model,
            generatorVersion: "test", promptVersion: "test", schemaVersion: "test",
            sourceFingerprint: "source-\(id)",
            coverage: SummaryCoverage(eligibleEventCount: 1, coveredEventCount: 1),
            revision: 1)
    }
}
