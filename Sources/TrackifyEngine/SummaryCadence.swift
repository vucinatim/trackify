import Foundation
import TrackifyDomain

/// The single scheduling contract for Trackify's built-in work summaries.
///
/// The open hour is refreshed programmatically on quarter-hour boundaries.
/// Completed active hours receive one provider-backed summary after a short
/// ingestion grace period. Configurable reports consume these summaries but
/// keep their own schedules and provider choices.
public enum SummaryCadence {
    public static let programmaticIntervalMinutes = 15
    public static let providerIntervalMinutes = 60
    public static let completionGraceMinutes = 15

    public static func programmaticBoundary(
        at date: Date,
        calendar: Calendar = .current
    ) -> Date {
        let components = calendar.dateComponents(
            [.era, .year, .month, .day, .hour, .minute], from: date)
        var boundary = DateComponents()
        boundary.era = components.era
        boundary.year = components.year
        boundary.month = components.month
        boundary.day = components.day
        boundary.hour = components.hour
        boundary.minute =
            ((components.minute ?? 0) / programmaticIntervalMinutes)
            * programmaticIntervalMinutes
        boundary.second = 0
        return calendar.date(from: boundary) ?? date
    }

    public static func completedHourCutoff(
        at date: Date,
        calendar: Calendar = .current
    ) -> Date {
        let graceAdjusted =
            calendar.date(
                byAdding: .minute, value: -completionGraceMinutes, to: date) ?? date
        return calendar.dateInterval(of: .hour, for: graceAdjusted)?.start ?? graceAdjusted
    }

    public static func currentWorkRange(
        at date: Date,
        calendar: Calendar = .current
    ) -> DateInterval? {
        let start = completedHourCutoff(at: date, calendar: calendar)
        let end = programmaticBoundary(at: date, calendar: calendar)
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The only clock hour eligible for automatic provider generation.
    /// Older gaps reconcile locally instead of causing a surprise token spike
    /// after restart, sleep, migration, or collection catch-up.
    public static func providerWorkRange(
        at date: Date,
        calendar: Calendar = .current
    ) -> DateInterval {
        let end = completedHourCutoff(at: date, calendar: calendar)
        let start =
            calendar.date(
                byAdding: .minute, value: -providerIntervalMinutes, to: end)
            ?? end.addingTimeInterval(-TimeInterval(providerIntervalMinutes * 60))
        return DateInterval(start: start, end: end)
    }

    public static func completedHours(
        in day: DateInterval,
        through cutoff: Date,
        calendar: Calendar = .current
    ) -> [DateInterval] {
        var result: [DateInterval] = []
        var start = day.start
        let end = min(max(cutoff, day.start), day.end)
        while start < end {
            let next = min(
                calendar.date(
                    byAdding: .minute, value: providerIntervalMinutes, to: start)
                    ?? start.addingTimeInterval(
                        TimeInterval(providerIntervalMinutes * 60)),
                end)
            guard next > start else { break }
            result.append(DateInterval(start: start, end: next))
            start = next
        }
        return result
    }

    public static func isCanonical(_ summary: WorkSummary) -> Bool {
        summary.generatorVersion == SummaryCoordinator.generatorVersion
    }
}
