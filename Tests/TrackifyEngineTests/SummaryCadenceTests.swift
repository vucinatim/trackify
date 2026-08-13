import Foundation
import Testing

@testable import TrackifyEngine

@Suite("Summary cadence")
struct SummaryCadenceTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test("Programmatic snapshots advance only on quarter-hour boundaries")
    func programmaticBoundary() throws {
        let date = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 8, day: 14, hour: 10, minute: 29, second: 59)))
        let boundary = SummaryCadence.programmaticBoundary(at: date, calendar: calendar)
        #expect(calendar.component(.minute, from: boundary) == 15)
        #expect(calendar.component(.second, from: boundary) == 0)
    }

    @Test("Completed hours wait fifteen minutes for durable evidence")
    func completedHourGrace() throws {
        let beforeGrace = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 8, day: 14, hour: 10, minute: 14)))
        let afterGrace = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 8, day: 14, hour: 10, minute: 15)))
        #expect(
            calendar.component(
                .hour,
                from: SummaryCadence.completedHourCutoff(
                    at: beforeGrace, calendar: calendar)) == 9)
        #expect(
            calendar.component(
                .hour,
                from: SummaryCadence.completedHourCutoff(
                    at: afterGrace, calendar: calendar)) == 10)
    }

    @Test("Current work covers only the not-yet-finalized portion")
    func currentWorkRange() throws {
        let date = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 8, day: 14, hour: 10, minute: 44)))
        let range = try #require(
            SummaryCadence.currentWorkRange(at: date, calendar: calendar))
        #expect(calendar.component(.hour, from: range.start) == 10)
        #expect(calendar.component(.minute, from: range.start) == 0)
        #expect(calendar.component(.minute, from: range.end) == 30)
    }

    @Test("Only the immediately preceding hour is provider eligible")
    func providerWorkRange() throws {
        let date = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 8, day: 14, hour: 10, minute: 44)))
        let range = SummaryCadence.providerWorkRange(at: date, calendar: calendar)
        #expect(calendar.component(.hour, from: range.start) == 9)
        #expect(calendar.component(.hour, from: range.end) == 10)
        #expect(range.duration == 3_600)
    }
}
