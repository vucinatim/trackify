import Charts
import SwiftUI
import TrackifyDomain
import TrackifyEngine

struct OverviewTrendChart: View {
    let range: DashboardRange
    let metric: DashboardMetric
    let interval: DateInterval
    let hours: [HourActivity]
    private let validationTooltipEdge: Bool

    @State private var hoveredPoint: OverviewTrendPoint?
    @State private var hoverLocationX: CGFloat?

    init(
        range: DashboardRange,
        metric: DashboardMetric,
        interval: DateInterval,
        hours: [HourActivity]
    ) {
        self.range = range
        self.metric = metric
        self.interval = interval
        self.hours = hours
        validationTooltipEdge = ProcessInfo.processInfo.environment["TRACKIFY_UI_CHART_TOOLTIP"] == "edge"
    }

    private var points: [OverviewTrendPoint] {
        hours.map { hour in
            let end = min(
                Calendar.current.date(byAdding: .hour, value: 1, to: hour.start) ?? interval.end,
                interval.end)
            return OverviewTrendPoint(
                start: hour.start,
                end: end,
                value: metric.trendValue(hour.activity),
                activity: hour.activity)
        }
    }

    var body: some View {
        if points.isEmpty {
            Label("No hourly activity in this range", systemImage: "circle.dotted")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        } else {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    chart

                    if let hoveredPoint, let hoverLocationX {
                        OverviewTrendTooltip(point: hoveredPoint, metric: metric)
                            .frame(width: min(310, geometry.size.width - 16), alignment: .leading)
                            .position(
                                x: tooltipCenter(for: hoverLocationX, width: geometry.size.width),
                                y: 40
                            )
                            .allowsHitTesting(false)
                            .zIndex(10)
                    }
                }
            }
            .onDisappear {
                hoveredPoint = nil
                hoverLocationX = nil
            }
            .onAppear {
                guard validationTooltipEdge,
                    let point = points.last(where: { $0.value > 0 }) ?? points.last
                else { return }
                hoveredPoint = point
                hoverLocationX = 10_000
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                RectangleMark(
                    xStart: .value("Start", point.start),
                    xEnd: .value("End", point.end),
                    yStart: .value("Baseline", 0),
                    yEnd: .value(metric.trendTitle, point.value)
                )
                .foregroundStyle(metric.tint.gradient)
                .opacity(0.92)
                .cornerRadius(range == .day ? 2 : 1)
            }

            if let hoveredPoint {
                RuleMark(x: .value("Selected hour", hoveredPoint.center))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: interval.start...interval.end)
        .chartYScale(domain: 0...max(1, points.map(\.value).max() ?? 1))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: minorAxisDates) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.11))
                AxisTick().foregroundStyle(Color.secondary.opacity(0.18))
            }
            AxisMarks(values: majorAxisDates) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.32))
                AxisTick().foregroundStyle(Color.secondary.opacity(0.45))
                AxisValueLabel {
                    if let date = value.as(Date.self) { majorAxisLabel(date) }
                }
            }
        }
        .chartPlotStyle { plot in plot.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        updateHover(phase, proxy: proxy, geometry: geometry)
                    }
            }
        }
    }

    private var majorAxisDates: [Date] {
        switch range {
        case .day:
            dates(every: 6, component: .hour, includeEnd: true)
        case .week:
            dates(every: 1, component: .day, includeEnd: false)
        case .month:
            dates(every: 5, component: .day, includeEnd: true)
        }
    }

    private var minorAxisDates: [Date] {
        let candidates: [Date]
        switch range {
        case .day: candidates = dates(every: 1, component: .hour, includeEnd: false)
        case .week: candidates = dates(every: 6, component: .hour, includeEnd: false)
        case .month: candidates = dates(every: 1, component: .day, includeEnd: false)
        }
        let majors = Set(majorAxisDates)
        return candidates.filter { !majors.contains($0) }
    }

    private func dates(
        every value: Int,
        component: Calendar.Component,
        includeEnd: Bool
    ) -> [Date] {
        var result: [Date] = []
        var cursor = interval.start
        while cursor < interval.end {
            result.append(cursor)
            guard let next = Calendar.current.date(byAdding: component, value: value, to: cursor), next > cursor else {
                break
            }
            cursor = next
        }
        if includeEnd, result.last != interval.end { result.append(interval.end) }
        return result
    }

    @ViewBuilder
    private func majorAxisLabel(_ date: Date) -> some View {
        switch range {
        case .day:
            if date == interval.end {
                Text("24").fixedSize()
            } else {
                Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)))).fixedSize()
            }
        case .week:
            Text(date.formatted(.dateTime.weekday(.narrow).day())).fixedSize()
        case .month:
            Text(date.formatted(.dateTime.month(.abbreviated).day())).fixedSize()
        }
    }

    private func tooltipCenter(for location: CGFloat, width: CGFloat) -> CGFloat {
        let tooltipWidth = min(310, width - 16)
        return min(max(location, tooltipWidth / 2 + 8), width - tooltipWidth / 2 - 8)
    }

    private func updateHover(
        _ phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        switch phase {
        case .active(let location):
            guard let plotFrame = proxy.plotFrame else { return }
            let frame = geometry[plotFrame]
            let x = location.x - frame.minX
            guard x >= 0, x <= frame.width, let date: Date = proxy.value(atX: x) else {
                hoveredPoint = nil
                hoverLocationX = nil
                return
            }
            let nearest = points.min {
                abs($0.center.timeIntervalSince(date)) < abs($1.center.timeIntervalSince(date))
            }
            if hoveredPoint?.id != nearest?.id { hoveredPoint = nearest }
            hoverLocationX = location.x
        case .ended:
            hoveredPoint = nil
            hoverLocationX = nil
        }
    }
}

private struct OverviewTrendPoint: Identifiable {
    let start: Date
    let end: Date
    let value: Int
    let activity: ActivitySnapshot

    var id: Date { start }
    var center: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
}

private struct OverviewTrendTooltip: View {
    let point: OverviewTrendPoint
    let metric: DashboardMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            Text("\(point.value.formatted()) \(metric.trendTitle.lowercased())")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(metric.tint)
            Text(primaryDetail).font(.caption2).foregroundStyle(.secondary)
            Text(secondaryDetail).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)) }
        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
    }

    private var title: String {
        "\(point.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))–\(point.end.formatted(date: .omitted, time: .shortened))"
    }

    private var primaryDetail: String {
        let evidence = point.activity.activeHours > 0 ? "Evidence present" : "No evidence"
        return "\(evidence) · \(point.activity.llmTurns) turns · \(point.activity.commits) commits"
    }

    private var secondaryDetail: String {
        "+\(point.activity.additions.formatted()) / −\(point.activity.deletions.formatted()) · \(point.activity.filesChanged) files · \(point.activity.repositoryIDs.count) repositories"
    }
}
