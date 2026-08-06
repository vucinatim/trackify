import Charts
import SwiftUI
import TrackifyDomain
import TrackifyEngine

struct MainWindow: View {
    @ObservedObject var model: AppModel
    @State private var selection: Section

    enum Section: String, CaseIterable, Identifiable {
        case overview
        case activity
        case projects

        var id: Self { self }
        var title: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .activity: "list.bullet.rectangle"
            case .projects: "shippingbox"
            }
        }
    }

    init(model: AppModel) {
        self.model = model
        let requested = ProcessInfo.processInfo.environment["TRACKIFY_UI_SCREEN"]
            .flatMap(Section.init(rawValue:))
        _selection = State(initialValue: requested ?? .overview)
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationTitle("Trackify")
            .navigationSplitViewColumnWidth(min: 178, ideal: 194, max: 220)
        } detail: {
            Group {
                switch selection {
                case .overview: OverviewView(model: model)
                case .activity: ActivityView(model: model)
                case .projects: ProjectsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task { await model.start() }
    }
}

private enum DashboardRange: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "7 days"
    case month = "30 days"

    var id: Self { self }
    var dayCount: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        }
    }
}

private struct OverviewView: View {
    @ObservedObject var model: AppModel
    @State private var range: DashboardRange = .week
    @State private var selectedDate: Date?
    @State private var showingDatePicker = false
    @State private var historicalHours: [HourActivity] = []
    private let requestedRange: DashboardRange?
    private let requestedDate: Date?

    init(model: AppModel) {
        self.model = model
        let requested = ProcessInfo.processInfo.environment["TRACKIFY_UI_RANGE"].flatMap { value in
            DashboardRange.allCases.first { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame }
        }
        let date = ProcessInfo.processInfo.environment["TRACKIFY_UI_DATE"]
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        requestedRange = requested
        requestedDate = date
        _range = State(initialValue: requested ?? .week)
        _selectedDate = State(initialValue: date.map { Calendar.current.startOfDay(for: $0) })
    }

    private var effectiveDate: Date {
        selectedDate ?? Calendar.current.startOfDay(for: model.referenceNow)
    }

    private var selectedDays: [CalendarActivity] {
        let inclusiveEnd = Calendar.current.date(byAdding: .day, value: 1, to: effectiveDate)!
        return Array(model.historyDays.filter { $0.date < inclusiveEnd }.suffix(range.dayCount))
    }

    private var totals: ActivityTotals { ActivityTotals(selectedDays.map(\.activity)) }
    private var selectedHours: [HourActivity] { isToday ? model.hours : historicalHours }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    eyebrow: dateEyebrow,
                    title: "Overview",
                    subtitle: "A local, evidence-backed view of your coding work."
                ) {
                    VStack(alignment: .trailing, spacing: 9) {
                        HStack(spacing: 6) {
                            Button {
                                moveSelection(by: -1)
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            Button {
                                showingDatePicker.toggle()
                            } label: {
                                Label(dateButtonTitle, systemImage: "calendar")
                            }
                            .popover(isPresented: $showingDatePicker) {
                                DatePicker(
                                    "History date",
                                    selection: Binding(
                                        get: { effectiveDate },
                                        set: { selectedDate = Calendar.current.startOfDay(for: $0) }
                                    ),
                                    in: availableDateRange,
                                    displayedComponents: .date
                                )
                                .labelsHidden()
                                .datePickerStyle(.graphical)
                                .frame(width: 190)
                                .padding(12)
                            }
                            Button {
                                moveSelection(by: 1)
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(isToday)
                            if !isToday {
                                Button("Today") { selectedDate = Calendar.current.startOfDay(for: model.referenceNow) }
                            }
                        }
                        Picker("Range", selection: $range) {
                            ForEach(DashboardRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 236)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    MetricCard(
                        title: "Evidence hours",
                        value: "\(totals.activeHours)h",
                        detail: rangeDetail(\.activeHours),
                        icon: "clock.fill",
                        tint: .indigo
                    )
                    MetricCard(
                        title: "LLM turns",
                        value: totals.llmTurns.formatted(),
                        detail: rangeDetail(\.llmTurns),
                        icon: "sparkles",
                        tint: .purple
                    )
                    MetricCard(
                        title: "Commits",
                        value: totals.commits.formatted(),
                        detail: rangeDetail(\.commits),
                        icon: "point.topleft.down.to.point.bottomright.curvepath",
                        tint: .blue
                    )
                    MetricCard(
                        title: "Committed lines",
                        value: "+\(totals.additions.formatted())",
                        detail: "−\(totals.deletions.formatted()) · \(totals.filesChanged) files",
                        icon: "plus.forwardslash.minus",
                        tint: .green
                    )
                }

                HStack(alignment: .top, spacing: 14) {
                    Panel(title: "Activity trend", subtitle: trendSubtitle) {
                        if selectedDays.isEmpty {
                            EmptyInline(text: "No activity history in this range")
                        } else {
                            ActivityTrendChart(
                                range: range,
                                days: selectedDays,
                                hours: selectedHours
                            )
                            .frame(height: 190)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Panel(title: "History", subtitle: "Pick a day to inspect or compare") {
                        ActivityHeatmap(
                            days: model.historyDays,
                            selectedDate: effectiveDate,
                            today: model.referenceNow
                        ) { date in
                            selectedDate = date
                            range = .day
                        }
                        .frame(height: 190)
                    }
                    .frame(width: 310)
                }

                HStack(alignment: .top, spacing: 14) {
                    Panel(title: "Reports in range", subtitle: "What was actually being worked on") {
                        if reportsInRange.isEmpty {
                            EmptyInline(text: "No report has been generated for this range")
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(reportsInRange.prefix(4)), id: \.id) { report in
                                    ReportSummaryRow(report: report, copy: model.copy)
                                    if report.id != reportsInRange.prefix(4).last?.id { Divider() }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Panel(title: "Project focus", subtitle: "Repositories present in this range") {
                        if projectFocus.isEmpty {
                            EmptyInline(text: "No project activity in this range")
                        } else {
                            VStack(spacing: 12) {
                                ForEach(projectFocus, id: \.name) { item in
                                    HStack(spacing: 10) {
                                        Image(systemName: "shippingbox.fill")
                                            .foregroundStyle(.tint)
                                            .frame(width: 26, height: 26)
                                            .background(.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.name).font(.callout.weight(.medium))
                                            Text("\(item.activeDays) active days")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(item.activeDays.formatted()).font(.headline.monospacedDigit())
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 310)
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if model.claimInitialOverviewPresentation() {
                if requestedDate == nil {
                    selectedDate = Calendar.current.startOfDay(for: model.referenceNow)
                }
                if requestedRange == nil { range = .week }
            }
        }
        .task(id: effectiveDate) {
            guard !isToday else {
                historicalHours = []
                return
            }
            historicalHours = []
            let loaded = await model.hourActivity(for: effectiveDate)
            guard !Task.isCancelled else { return }
            historicalHours = loaded
        }
    }

    private var isToday: Bool { Calendar.current.isDate(effectiveDate, inSameDayAs: model.referenceNow) }
    private var dateEyebrow: String {
        isToday ? "Today · \(effectiveDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))" : "Historical view"
    }
    private var dateButtonTitle: String {
        isToday ? "Today" : effectiveDate.formatted(.dateTime.month(.abbreviated).day().year())
    }
    private var trendSubtitle: String {
        range == .day ? "Evidence records by hour" : "Evidence hours by day"
    }
    private var availableDateRange: ClosedRange<Date> {
        (model.historyDays.first?.date ?? effectiveDate)...Calendar.current.startOfDay(for: model.referenceNow)
    }
    private var reportsInRange: [WorkReport] {
        guard let first = selectedDays.first?.date, let last = selectedDays.last?.date,
            let end = Calendar.current.date(byAdding: .day, value: 1, to: last)
        else { return [] }
        return model.reports.filter { $0.periodStart >= first && $0.periodStart < end }
    }
    private var projectFocus: [(name: String, activeDays: Int)] {
        var counts: [RepositoryID: Int] = [:]
        for day in selectedDays {
            for id in day.activity.repositoryIDs { counts[id, default: 0] += 1 }
        }
        return Array(
            counts.map { (model.repositoryName($0.key) ?? "Unknown", $0.value) }
                .sorted { $0.1 > $1.1 }
                .prefix(4)
        )
    }

    private func moveSelection(by days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: effectiveDate) else { return }
        let bounded = min(max(date, availableDateRange.lowerBound), availableDateRange.upperBound)
        selectedDate = Calendar.current.startOfDay(for: bounded)
    }

    private func rangeDetail(_ keyPath: KeyPath<ActivitySnapshot, Int>) -> String {
        let active = selectedDays.filter { $0.activity.evidenceCount > 0 }
        guard !active.isEmpty else { return "No evidence in range" }
        let average = Double(active.reduce(0) { $0 + $1.activity[keyPath: keyPath] }) / Double(active.count)
        return "\(average.formatted(.number.precision(.fractionLength(1)))) per active day"
    }
}

private struct ActivityTotals {
    let activeHours: Int
    let llmTurns: Int
    let commits: Int
    let additions: Int
    let deletions: Int
    let filesChanged: Int

    init(_ snapshots: [ActivitySnapshot]) {
        activeHours = snapshots.reduce(0) { $0 + $1.activeHours }
        llmTurns = snapshots.reduce(0) { $0 + $1.llmTurns }
        commits = snapshots.reduce(0) { $0 + $1.commits }
        additions = snapshots.reduce(0) { $0 + $1.additions }
        deletions = snapshots.reduce(0) { $0 + $1.deletions }
        filesChanged = snapshots.reduce(0) { $0 + $1.filesChanged }
    }
}

private struct ActivityTrendPoint: Identifiable {
    let date: Date
    let value: Int
    let activity: ActivitySnapshot
    var id: Date { date }
}

private struct ActivityTrendChart: View {
    let range: DashboardRange
    let days: [CalendarActivity]
    let hours: [HourActivity]
    @State private var hoveredPoint: ActivityTrendPoint?

    private var points: [ActivityTrendPoint] {
        if range == .day {
            return hours.map {
                ActivityTrendPoint(date: $0.start, value: $0.activity.evidenceCount, activity: $0.activity)
            }
        }
        return days.map {
            ActivityTrendPoint(date: $0.date, value: $0.activeHours, activity: $0.activity)
        }
    }

    var body: some View {
        if points.isEmpty {
            EmptyInline(text: range == .day ? "Loading hourly activity…" : "No activity history in this range")
        } else {
            Chart {
                if range == .day {
                    ForEach(points) { point in
                        BarMark(
                            x: .value("Hour", point.date, unit: .hour),
                            y: .value("Evidence records", point.value)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(2)
                    }
                } else {
                    ForEach(points) { point in
                        AreaMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Evidence hours", point.value)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                        LineMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Evidence hours", point.value)
                        )
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        PointMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Evidence hours", point.value)
                        )
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(20)
                    }
                }

                if let hoveredPoint {
                    RuleMark(
                        x: .value(
                            "Selected time",
                            hoveredPoint.date,
                            unit: range == .day ? .hour : .day
                        )
                    )
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 8) {
                        ActivityTrendTooltip(point: hoveredPoint, hourly: range == .day)
                    }
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: 0...max(4, points.map(\.value).max() ?? 4))
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
            .chartXAxis {
                if range == .day {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                            }
                        }
                    }
                } else {
                    AxisMarks(values: axisDates) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                if range == .month {
                                    Text(date, format: .dateTime.month(.abbreviated).day())
                                } else {
                                    Text(date, format: .dateTime.weekday(.narrow).day())
                                }
                            }
                        }
                    }
                }
            }
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
            .onDisappear { hoveredPoint = nil }
        }
    }

    private var xDomain: ClosedRange<Date> {
        guard let first = points.first?.date, let last = points.last?.date else {
            return Date.distantPast...Date.distantFuture
        }
        if range == .day {
            let end = Calendar.current.date(byAdding: .hour, value: 1, to: last) ?? last
            return first...end
        }
        let start = Calendar.current.date(byAdding: .hour, value: -12, to: first) ?? first
        let end = Calendar.current.date(byAdding: .hour, value: 12, to: last) ?? last
        return start...end
    }

    private var axisDates: [Date] {
        guard range == .month else { return points.map(\.date) }
        var values = points.enumerated().compactMap { index, point in index.isMultiple(of: 5) ? point.date : nil }
        if let last = points.last?.date, values.last != last { values.append(last) }
        return values
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
                return
            }
            let nearest = points.min {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }
            if hoveredPoint?.id != nearest?.id { hoveredPoint = nearest }
        case .ended:
            hoveredPoint = nil
        }
    }
}

private struct ActivityTrendTooltip: View {
    let point: ActivityTrendPoint
    let hourly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            Text(primaryDetail).font(.caption2).foregroundStyle(.secondary)
            Text(secondaryDetail).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)) }
        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
        .fixedSize()
    }

    private var title: String {
        if hourly {
            let end = Calendar.current.date(byAdding: .hour, value: 1, to: point.date) ?? point.date
            return "\(point.date.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
        }
        return point.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var primaryDetail: String {
        if hourly {
            return "\(point.activity.evidenceCount) evidence · \(point.activity.llmTurns) turns · \(point.activity.commits) commits"
        }
        return "\(point.activity.activeHours) evidence hours · \(point.activity.llmTurns) turns · \(point.activity.commits) commits"
    }

    private var secondaryDetail: String {
        "+\(point.activity.additions.formatted()) / −\(point.activity.deletions.formatted()) · \(point.activity.repositoryIDs.count) repositories"
    }
}

private struct ActivityHeatmap: View {
    let days: [CalendarActivity]
    let selectedDate: Date
    let today: Date
    let select: (Date) -> Void
    @State private var hoveredDate: Date?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                ForEach(Calendar.current.veryShortWeekdaySymbols, id: \.self) { weekday in
                    Text(weekday).font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(days.suffix(42))) { day in
                    Button {
                        select(day.date)
                    } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(intensity(day)))
                            .overlay(alignment: .topLeading) {
                                Text(day.date.formatted(.dateTime.day()))
                                    .font(.system(size: 8, weight: .medium, design: .rounded))
                                    .foregroundStyle(day.activity.evidenceCount > 0 ? .primary : .tertiary)
                                    .padding(4)
                            }
                            .overlay(alignment: .topTrailing) {
                                if Calendar.current.isDate(day.date, inSameDayAs: today) {
                                    Circle().fill(Color.pink).frame(width: 5, height: 5).padding(4)
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(
                                        Calendar.current.isDate(day.date, inSameDayAs: selectedDate)
                                            ? Color(red: 0.72, green: 0.88, blue: 1) : .clear,
                                        lineWidth: 2
                                    )
                            }
                            .frame(height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(heatmapHelp(day))
                    .onHover { hovering in
                        if hovering {
                            hoveredDate = day.date
                        } else if hoveredDate == day.date {
                            hoveredDate = nil
                        }
                    }
                }
            }
            HStack(spacing: 5) {
                if let hoveredDay {
                    Text(hoverSummary(hoveredDay))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                } else {
                    Label {
                        Text("Today").foregroundStyle(.tertiary)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(.pink)
                    }
                    .labelStyle(.titleAndIcon)
                    Spacer()
                    Text("Quiet")
                    ForEach([0.06, 0.2, 0.38, 0.62], id: \.self) { value in
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(value)).frame(width: 14, height: 8)
                    }
                    Text("Busy")
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            .frame(height: 16)
        }
    }

    private func intensity(_ day: CalendarActivity) -> Double {
        guard day.activity.evidenceCount > 0 else { return 0.055 }
        return min(0.18 + Double(day.activity.evidenceCount) / 18, 0.72)
    }

    private func heatmapHelp(_ day: CalendarActivity) -> String {
        let prefix = Calendar.current.isDate(day.date, inSameDayAs: today) ? "Today · " : ""
        return "\(prefix)\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.activeHours) evidence hours"
    }

    private var hoveredDay: CalendarActivity? {
        hoveredDate.flatMap { date in days.first { Calendar.current.isDate($0.date, inSameDayAs: date) } }
    }

    private func hoverSummary(_ day: CalendarActivity) -> String {
        let prefix = Calendar.current.isDate(day.date, inSameDayAs: today) ? "Today · " : ""
        return
            "\(prefix)\(day.date.formatted(.dateTime.month(.abbreviated).day())) · \(day.activeHours)h · \(day.activity.llmTurns) turns · \(day.commits) commits"
    }
}

private struct ActivityView: View {
    @ObservedObject var model: AppModel
    @State private var filter: ActivityFilter = .all
    @State private var query = ""

    private enum ActivityFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case reports = "Reports"
        case commits = "Commits"
        case conversations = "Conversations"
        case changes = "Changes"
        var id: Self { self }
    }

    private var entries: [TimelineEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let repositoryNames = repositoryNamesByID
        return model.timeline.filter { entry in
            let matchesKind: Bool
            switch filter {
            case .all: matchesKind = true
            case .reports: matchesKind = entry.kind == .report
            case .commits: matchesKind = entry.kind == .commit
            case .conversations: matchesKind = entry.kind == .conversation
            case .changes: matchesKind = entry.kind == .change || entry.kind == .test
            }
            guard matchesKind else { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return entry.title.localizedCaseInsensitiveContains(trimmedQuery)
                || (entry.detail?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || (entry.repositoryID.flatMap { repositoryNames[$0] }?.localizedCaseInsensitiveContains(trimmedQuery)
                    ?? false)
                || messageRoleSearchText(entry.messageRole).localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        let visibleEntries = entries
        let dayGroups = groupedDays(visibleEntries)
        let repositoryNames = repositoryNamesByID
        let reports = reportsByID

        VStack(spacing: 0) {
            PageHeader(
                eyebrow: "Reports and concrete evidence",
                title: "Activity",
                subtitle: "Search and filter the chronological work ledger"
            ) {
                SearchField("Search activity", text: $query)
                    .frame(width: 260)
            }
            .padding(24)
            Divider()
            HStack {
                Picker("Filter", selection: $filter) {
                    ForEach(ActivityFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 560)
                Spacer()
                Text("\(visibleEntries.count) entries")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            Divider()

            if visibleEntries.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyIcon)
                } description: {
                    Text(emptyDescription)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(dayGroups, id: \.date) { group in
                            SwiftUI.Section {
                                ForEach(group.entries) { entry in
                                    Group {
                                        if entry.kind == .report, let report = reports[entry.id] {
                                            ReportActivityCard(report: report, copy: model.copy)
                                        } else {
                                            TimelineRow(
                                                entry: entry,
                                                repositoryName: entry.repositoryID.flatMap { repositoryNames[$0] }
                                            )
                                        }
                                    }
                                    .padding(.top, entry.id == group.entries.first?.id ? 12 : 0)
                                }
                            } header: {
                                StickyDayHeader(date: group.date)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func groupedDays(_ entries: [TimelineEntry]) -> [(date: Date, entries: [TimelineEntry])] {
        Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.occurredAt) }
            .map { ($0.key, $0.value) }
            .sorted { $0.date > $1.date }
    }
    private var repositoryNamesByID: [RepositoryID: String] {
        var result: [RepositoryID: String] = [:]
        for item in model.repositories { result[item.repository.id] = item.repository.displayName }
        return result
    }
    private var reportsByID: [String: WorkReport] {
        var result: [String: WorkReport] = [:]
        for report in model.reports { result[report.id.rawValue] = report }
        return result
    }
    private func messageRoleSearchText(_ role: MessageRole?) -> String {
        switch role {
        case .user: "you user prompt request"
        case .assistant: "agent assistant update response"
        case .system, nil: ""
        }
    }
    private var emptyTitle: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No matching activity" }
        return filter == .reports ? "No reports yet" : "No activity yet"
    }
    private var emptyIcon: String { filter == .reports ? "doc.text" : "list.bullet.rectangle" }
    private var emptyDescription: String {
        if filter == .reports {
            return "Reports appear here after an evidence-backed period is generated. Other activity remains available independently."
        }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter != .all {
            return "Try a different filter or search term."
        }
        return "Collected commits, conversations, reports, and working-copy changes will appear here automatically."
    }
}

private struct StickyDayHeader: View {
    let date: Date

    var body: some View {
        Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Divider().padding(.leading, 30)
            }
    }
}

private struct TimelineRow: View {
    let entry: TimelineEntry
    let repositoryName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold)).foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: Circle())
                Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1, height: 54)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(tint)
                    if let repositoryName { Text(repositoryName).font(.caption).foregroundStyle(.secondary) }
                    if let state = entry.state, state != "completed" { StateBadge(state: state) }
                    Spacer()
                    Text(entry.occurredAt, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(displayTitle)
                    .font(entry.messageRole == .user ? .callout.weight(.medium) : .callout)
                    .lineLimit(3)
                if let detail = entry.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 30)
    }

    private var displayTitle: String {
        guard entry.title.count > 600 else { return entry.title }
        return String(entry.title.prefix(599)) + "…"
    }

    private var label: String {
        switch entry.messageRole {
        case .user: "You"
        case .assistant: "Agent"
        case .system, nil: entry.kind.rawValue.capitalized
        }
    }

    private var icon: String {
        switch entry.kind {
        case .report: "doc.text.fill"
        case .commit: "point.topleft.down.to.point.bottomright.curvepath"
        case .conversation: entry.messageRole == .user ? "person.fill" : "sparkles"
        case .change: "pencil.and.list.clipboard"
        case .test: "checkmark.seal.fill"
        }
    }
    private var tint: Color {
        switch entry.kind {
        case .report: .indigo
        case .commit: .blue
        case .conversation: entry.messageRole == .user ? .blue : .purple
        case .change: .orange
        case .test: entry.state == "failed" ? .red : .green
        }
    }
}

private struct ReportActivityCard: View {
    let report: WorkReport
    let copy: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").foregroundStyle(.indigo)
                Text("Report").font(.caption.weight(.semibold)).foregroundStyle(.indigo)
                StateBadge(state: report.state.rawValue)
                Spacer()
                Text(report.periodStart, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Text(report.summary).font(.body.weight(.medium)).lineLimit(expanded ? nil : 4)
            HStack {
                Label("\(report.evidenceIDs.count) evidence records", systemImage: "list.bullet.rectangle")
                if expanded {
                    Text("·")
                    Text(report.provider ?? "Local fallback")
                    if let model = report.model { Text("· \(model)") }
                }
                Spacer()
                Button(expanded ? "Less" : "Details") { expanded.toggle() }.buttonStyle(.link)
                Button {
                    copy(report.summary)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless).help("Copy summary")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.indigo.opacity(0.18)) }
        .padding(.horizontal, 30).padding(.bottom, 14)
    }
}

private struct ProjectsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedID: WorkingCopyID?
    @State private var searchText = ""

    private var filtered: [RepositoryCatalogItem] {
        model.repositories.filter {
            searchText.isEmpty || $0.repository.displayName.localizedCaseInsensitiveContains(searchText)
                || ($0.relativePath ?? $0.workingCopy.canonicalPath).localizedCaseInsensitiveContains(searchText)
        }
    }
    private var selected: RepositoryCatalogItem? {
        filtered.first { $0.workingCopy.id == selectedID } ?? filtered.first
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                eyebrow: "\(model.repositories.count) discovered repositories",
                title: "Projects",
                subtitle: "Automatically grouped by their discovery roots"
            )
            .padding(24)
            Divider()
            if model.repositories.isEmpty {
                ContentUnavailableView(
                    "No repositories yet",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Configure a discovery root, then collect.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        SearchField("Filter repositories", text: $searchText)
                            .padding(12)
                        Divider()
                        List(selection: $selectedID) {
                            ForEach(groupedRepositories, id: \.name) { group in
                                SwiftUI.Section(group.name) {
                                    ForEach(group.items, id: \.workingCopy.id) { item in
                                        ProjectListRow(item: item).tag(item.workingCopy.id)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                    .frame(minWidth: 270, idealWidth: 320, maxWidth: 370)
                    .background(Color(nsColor: .windowBackgroundColor))
                    if let selected {
                        ProjectDetail(item: selected, model: model)
                    } else {
                        ContentUnavailableView("Select a project", systemImage: "shippingbox")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { selectedID = selectedID ?? filtered.first?.workingCopy.id }
    }

    private var groupedRepositories: [(name: String, items: [RepositoryCatalogItem])] {
        Dictionary(grouping: filtered) { $0.discoveryRootName ?? "Other" }
            .map { ($0.key, $0.value) }
            .sorted { $0.name < $1.name }
    }
}

private struct ProjectListRow: View {
    let item: RepositoryCatalogItem
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.repository.displayName).font(.callout.weight(.medium))
                Text(item.relativePath ?? item.workingCopy.canonicalPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProjectDetail: View {
    let item: RepositoryCatalogItem
    @ObservedObject var model: AppModel
    private var entries: [TimelineEntry] { model.timeline.filter { $0.repositoryID == item.repository.id } }
    private var commits: Int { entries.count { $0.kind == .commit } }
    private var prompts: Int { entries.count { $0.messageRole == .user } }
    private var agentUpdates: Int { entries.count { $0.messageRole == .assistant } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "shippingbox.fill")
                        .font(.title2).foregroundStyle(.tint)
                        .frame(width: 46, height: 46)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.repository.displayName).font(.title.bold())
                        Text(item.discoveryRootName ?? "Other").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    CompactMetric(value: commits.formatted(), label: "Recent commits", tint: .blue)
                    CompactMetric(value: prompts.formatted(), label: "User prompts", tint: .blue)
                    CompactMetric(value: agentUpdates.formatted(), label: "Agent updates", tint: .purple)
                }
                Panel(title: "Repository", subtitle: nil) {
                    VStack(spacing: 12) {
                        LabeledContent("Branch", value: item.workingCopy.branch ?? "Unknown")
                        Divider()
                        LabeledContent("Path", value: item.workingCopy.canonicalPath)
                        Divider()
                        LabeledContent(
                            "Last observed",
                            value: item.repository.lastObservedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }
                Panel(title: "Recent evidence", subtitle: "Latest entries associated with this repository") {
                    if entries.isEmpty {
                        EmptyInline(text: "No activity in the current history window")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(entries.prefix(6))) { entry in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: projectIcon(entry))
                                        .foregroundStyle(projectTint(entry)).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.title).font(.callout).lineLimit(2)
                                        Text(
                                            entry.occurredAt,
                                            format: .dateTime.month(.abbreviated).day().hour().minute()
                                        )
                                        .font(.caption).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 9)
                                if entry.id != entries.prefix(6).last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(28).frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func projectIcon(_ entry: TimelineEntry) -> String {
        switch entry.kind {
        case .report: "doc.text"
        case .commit: "point.topleft.down.to.point.bottomright.curvepath"
        case .conversation: entry.messageRole == .user ? "person.fill" : "sparkles"
        case .change: "pencil.and.list.clipboard"
        case .test: "checkmark.seal"
        }
    }

    private func projectTint(_ entry: TimelineEntry) -> Color {
        switch entry.kind {
        case .conversation: entry.messageRole == .user ? .blue : .purple
        case .commit: .blue
        case .change: .orange
        case .test: entry.state == "failed" ? .red : .green
        case .report: .indigo
        }
    }
}

private struct PageHeader<Actions: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let actions: Actions

    init(eyebrow: String, title: String, subtitle: String, @ViewBuilder actions: () -> Actions) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.tint)
                Text(title).font(.largeTitle.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(eyebrow: String, title: String, subtitle: String) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

private struct SearchField: View {
    let prompt: String
    @Binding var text: String

    init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        _text = text
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }
}

private struct Panel<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.13), lineWidth: 1) }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold)).foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(value).font(.title2.bold().monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.13), lineWidth: 1) }
    }
}

private struct CompactMetric: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct StateBadge: View {
    let state: String
    var body: some View {
        Text(humanState(state))
            .font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
    private var color: Color {
        switch state {
        case "completed": .green
        case "in_progress": .blue
        case "investigating", "waiting": .orange
        case "failed": .red
        default: .secondary
        }
    }
}

private struct ReportSummaryRow: View {
    let report: WorkReport
    let copy: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(report.periodStart, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    StateBadge(state: report.state.rawValue)
                }
                Text(report.summary).font(.callout).lineLimit(2)
            }
            Spacer()
            Button {
                copy(report.summary)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless).help("Copy summary")
        }
        .padding(.vertical, 10)
    }
}

private struct EmptyInline: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "circle.dotted")
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
    }
}

private func humanState(_ state: String) -> String {
    state.replacingOccurrences(of: "_", with: " ").capitalized
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateController
    @State private var launchAtLogin = false
    @State private var budgets = GenerationBudgets()
    @State private var selectedTab: SettingsTab

    private enum SettingsTab: String {
        case sources, summaries, usage, recipes, general
    }

    init(model: AppModel, updates: UpdateController) {
        self.model = model
        self.updates = updates
        let requested = ProcessInfo.processInfo.environment["TRACKIFY_UI_SETTINGS_TAB"]
            .flatMap(SettingsTab.init(rawValue:))
        _selectedTab = State(initialValue: requested ?? .sources)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            sourcesView
                .tabItem { Label("Sources", systemImage: "externaldrive") }
                .tag(SettingsTab.sources)
            summariesView
                .tabItem { Label("Summaries", systemImage: "sparkles") }
                .tag(SettingsTab.summaries)
            usageView
                .tabItem { Label("Usage", systemImage: "chart.bar") }
                .tag(SettingsTab.usage)
            recipesView
                .tabItem { Label("Recipes", systemImage: "doc.text") }
                .tag(SettingsTab.recipes)
            generalView
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .padding(12)
        .onAppear {
            launchAtLogin = model.launchAtLoginEnabled
            budgets = model.generationBudgets
        }
    }

    private var sourcesView: some View {
        Form {
            SwiftUI.Section("Conversation history") {
                ForEach(model.sourceCapabilities) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(source.surface)
                            Spacer()
                            CapabilityPill(text: humanState(source.state.rawValue), ready: source.state == .available)
                        }
                        Text(source.location).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("\(source.importedRecordCount) \(source.family.capitalized) records in ledger")
                            .font(.caption).foregroundStyle(.secondary)
                        if let importedAt = source.lastSuccessfulImportAt {
                            Text("Last import: \(importedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No successful import recorded")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let detail = source.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                Button("Rescan capabilities") { Task { await model.rescanCapabilities() } }
            }
            SwiftUI.Section("Repository roots") {
                ForEach(model.roots, id: \.id) { root in
                    LabeledContent(root.displayName, value: root.canonicalPath)
                }
            }
        }.formStyle(.grouped)
    }

    private var summariesView: some View {
        Form {
            SwiftUI.Section("Provider") {
                Picker(
                    "Mode",
                    selection: Binding(
                        get: { model.providerSelection },
                        set: { value in Task { await model.setProviderSelection(value) } })
                ) {
                    Text("Automatic").tag(ProviderSelectionMode.automatic)
                    Text("Codex").tag(ProviderSelectionMode.codex)
                    Text("Claude").tag(ProviderSelectionMode.claude)
                    Text("Local only").tag(ProviderSelectionMode.localOnly)
                }
                LabeledContent("Effective provider", value: model.effectiveProvider?.rawValue.capitalized ?? "Local only")
                Toggle(
                    "Use models for scheduled reports",
                    isOn: Binding(
                        get: { model.scheduledModelReportsEnabled },
                        set: { value in Task { await model.setScheduledModelReportsEnabled(value) } }))
                ForEach(model.generationCapabilities) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.id.rawValue.capitalized)
                            Text(provider.cliVersion ?? provider.executablePath ?? "Not installed")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        CapabilityPill(
                            text: humanState(provider.authentication.rawValue),
                            ready: provider.authentication == .ready)
                        Button("Test") { Task { await model.testProvider(provider.id) } }
                            .disabled(provider.executablePath == nil || model.isSummarizing)
                    }
                }
                Text("Tests send a tiny synthetic payload only. Trackify never reads or changes provider credentials or configuration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Budgets") {
                Stepper("Calls per day: \(budgets.maximumCallsPerDay)", value: $budgets.maximumCallsPerDay, in: 0...48)
                Stepper(
                    "Daily tokens: \(budgets.dailyTokenLimit.formatted())", value: $budgets.dailyTokenLimit, in: 0...1_000_000, step: 5_000)
                Stepper(
                    "Per-call tokens: \(budgets.maximumEstimatedInputTokensPerCall.formatted())",
                    value: $budgets.maximumEstimatedInputTokensPerCall, in: 500...100_000, step: 500)
                Stepper("Deadline: \(budgets.processDeadlineSeconds)s", value: $budgets.processDeadlineSeconds, in: 15...600, step: 15)
                Button("Save budgets") { Task { await model.saveGenerationBudgets(budgets) } }
                Text(
                    "Token limits include a conservative allowance for the provider CLI's own system context; Usage replaces estimates with emitted values after each run."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var usageView: some View {
        Form {
            SwiftUI.Section("Trackify-initiated model usage") {
                UsageRow(title: "Today", usage: model.usageToday)
                UsageRow(title: "This month", usage: model.usageMonth)
                Text(
                    "Costs are shown only when the provider reports an attributable estimate. Subscription or managed billing remains unknown."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Recent runs") {
                if model.reportRuns.isEmpty {
                    Text("No model or deterministic report runs yet.").foregroundStyle(.secondary)
                }
                ForEach(model.reportRuns.prefix(12)) { run in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(run.recipeID.rawValue.replacingOccurrences(of: "-", with: " ").capitalized)
                            Text(run.effectiveProvider?.rawValue ?? "Local renderer")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(humanState(run.state.rawValue)).foregroundStyle(run.state == .failed ? .red : .secondary)
                        Text((run.usage.knownTokenTotal ?? 0).formatted() + " tokens")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private var recipesView: some View {
        Form {
            SwiftUI.Section("Versioned recipes") {
                ForEach(model.recipes) { recipe in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recipe.name)
                            Text(recipe.currentVersionID.rawValue)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if recipe.isBuiltIn { Text("Built-in").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text(
                    "Custom focus can change audience and wording, but cannot weaken evidence, redaction, tools, schema, or provenance rules."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Recent artifacts") {
                if model.artifacts.isEmpty { Text("No artifacts yet.").foregroundStyle(.secondary) }
                ForEach(model.artifacts.prefix(10)) { artifact in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(artifact.recipeID.rawValue.replacingOccurrences(of: "-", with: " ").capitalized)
                            Spacer()
                            Text(artifact.privacyProfile.rawValue.capitalized)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(artifact.content).font(.caption).lineLimit(2).textSelection(.enabled)
                        Text("Revision \(artifact.revision) · \(artifact.evidenceIDs.count) evidence links")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 2)
                }
            }
        }.formStyle(.grouped)
    }

    private var generalView: some View {
        Form {
            SwiftUI.Section("Collection") {
                LabeledContent("Status", value: collectionStatus)
                Toggle("Launch Trackify at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in model.setLaunchAtLogin(value) }
                Toggle(
                    "Pause passive collection",
                    isOn: Binding(
                        get: { model.collectionPaused },
                        set: { value in Task { await model.setCollectionPaused(value) } }))
                LabeledContent("Reconciliation", value: "Every 30 minutes")
                LabeledContent("Evidence", value: "Local only")
                Button("Sync now") { Task { await model.collectNow() } }.disabled(model.isCollecting)
            }
            SwiftUI.Section("Updates") {
                Toggle(
                    "Check for updates automatically",
                    isOn: Binding(
                        get: { model.automaticUpdateChecks },
                        set: { value in
                            model.setAutomaticUpdateChecks(value)
                            updates.setAutomaticChecks(value)
                        })
                )
                .disabled(updates.installation.updateAction != .sparkle)
                Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
                LabeledContent("Installation", value: updates.installation.origin.rawValue.capitalized)
                Text(updateDescription).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var updateDescription: String {
        switch updates.installation.updateAction {
        case .sparkle: "Signed direct installations update through the GitHub-hosted Sparkle feed."
        case .homebrew: "This installation is updated with brew upgrade --cask trackify."
        case .managed: "Updates are owned by your organization."
        case .disabled: "Update checks are disabled for this development or unconfigured build."
        }
    }

    private var collectionStatus: String {
        if model.collectionPaused { return "Paused" }
        if model.degradedMessage != nil { return "Needs attention" }
        if model.isCollecting { return "Syncing" }
        return "Up to date"
    }
}

private struct CapabilityPill: View {
    let text: String
    let ready: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ready ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption)
    }
}

private struct UsageRow: View {
    let title: String
    let usage: UsageSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text("\(usage.runs) runs")
            }
            let tokens = usage.inputTokens + usage.cachedInputTokens + usage.outputTokens + usage.reasoningTokens
            Text("\(tokens.formatted()) tokens · \(usage.durationSeconds.formatted(.number.precision(.fractionLength(1))))s")
                .font(.caption).foregroundStyle(.secondary)
            if usage.knownCost > 0 {
                Text("Provider-reported known cost: \(usage.currency ?? "") \(NSDecimalNumber(decimal: usage.knownCost).stringValue)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(usage.hasUnknownCost ? "Incremental cost unknown" : "No provider cost reported")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
