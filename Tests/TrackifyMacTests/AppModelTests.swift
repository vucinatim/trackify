import Foundation
import Testing
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
}
