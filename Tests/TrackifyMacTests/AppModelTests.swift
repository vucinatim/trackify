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
        #expect(DashboardMetric.evidenceHours.hourlySubtitle == "Evidence items by hour")
        #expect(DashboardMetric.evidenceHours.trendValue(snapshot) == 19)
        #expect(DashboardMetric.llmTurns.trendValue(snapshot) == 7)
    }
}
