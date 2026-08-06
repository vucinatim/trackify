import Foundation
import TrackifyDomain
import TrackifyStore

public struct ScheduledReportResult: Codable, Equatable, Sendable {
    public let generated: [WorkReport]
    public let issues: [String]

    public init(generated: [WorkReport], issues: [String]) {
        self.generated = generated
        self.issues = issues
    }
}

/// Creates each completed hourly and daily report once. The app owns scheduling;
/// this type only contains deterministic, independently testable policy.
struct ReportScheduler: Sendable {
    func generateDueReports(
        store: LedgerStore,
        now: Date,
        calendar: Calendar = .current,
        provider: (any SummaryProvider)? = nil,
        catchupDuration: TimeInterval = 7 * 86_400
    ) async -> ScheduledReportResult {
        precondition(catchupDuration > 0)
        guard let currentHour = calendar.dateInterval(of: .hour, for: now),
            let previousHourStart = calendar.date(byAdding: .hour, value: -1, to: currentHour.start),
            let currentDay = calendar.dateInterval(of: .day, for: now),
            let previousDayStart = calendar.date(byAdding: .day, value: -1, to: currentDay.start)
        else {
            return ScheduledReportResult(generated: [], issues: ["Could not calculate local report periods."])
        }

        let previousHour = DateInterval(start: previousHourStart, end: currentHour.start)
        let previousDay = DateInterval(start: previousDayStart, end: currentDay.start)
        func key(_ period: DateInterval) -> String {
            "\(period.start.timeIntervalSinceReferenceDate):\(period.duration)"
        }
        var periodsByKey = [key(previousHour): previousHour, key(previousDay): previousDay]
        do {
            let events = try store.events(
                from: now.addingTimeInterval(-catchupDuration),
                through: currentHour.start
            )
            for event in events where event.occurredAt < currentHour.start {
                if let hour = calendar.dateInterval(of: .hour, for: event.occurredAt), hour.end <= currentHour.start {
                    periodsByKey[key(hour)] = hour
                }
                if let day = calendar.dateInterval(of: .day, for: event.occurredAt), day.end <= currentDay.start {
                    periodsByKey[key(day)] = day
                }
            }
        } catch {
            return ScheduledReportResult(generated: [], issues: ["Could not inspect catch-up periods: \(error)"])
        }
        let periods = periodsByKey.values.sorted {
            $0.start == $1.start ? $0.duration < $1.duration : $0.start < $1.start
        }
        var generated: [WorkReport] = []
        var issues: [String] = []
        for period in periods {
            do {
                guard try !store.hasReport(exactly: period) else { continue }
                let generator = ReportGenerator()
                do {
                    generated.append(
                        try await generator.generate(
                            store: store,
                            range: period,
                            cutoff: period.end,
                            provider: period == previousHour || period == previousDay ? provider : nil
                        ))
                } catch  where provider != nil {
                    issues.append("Provider summary failed for \(period.start): \(error)")
                    generated.append(
                        try await generator.generate(
                            store: store,
                            range: period,
                            cutoff: period.end
                        ))
                }
            } catch {
                issues.append("Report generation failed for \(period.start): \(error)")
            }
        }
        return ScheduledReportResult(generated: generated, issues: issues)
    }
}
