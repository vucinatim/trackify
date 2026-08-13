import SwiftUI
import TrackifyDomain
import TrackifyEngine

struct MainWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateController
    @ObservedObject var router: AppRouter

    enum Section: String, CaseIterable, Identifiable {
        case overview
        case activity
        case projects
        case reports
        case settings

        var id: Self { self }
        var title: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .activity: "list.bullet.rectangle"
            case .projects: "shippingbox"
            case .reports: "doc.text"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $router.selection) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationTitle("Trackify")
            .navigationSplitViewColumnWidth(min: 178, ideal: 194, max: 220)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarRuntimeStatus(model: model)
            }
        } detail: {
            VStack(spacing: 0) {
                if let message = model.degradedMessage {
                    AppStatusBanner(
                        message: message,
                        canDismiss: model.errorMessage != nil,
                        review: { router.selection = .settings },
                        dismiss: model.dismissError)
                }
                Group {
                    switch router.selection {
                    case .overview: OverviewView(model: model)
                    case .activity: ActivityView(model: model)
                    case .projects: ProjectsView(model: model)
                    case .reports: ReportsView(model: model)
                    case .settings: SettingsView(model: model, updates: updates)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .task { await model.refresh() }
    }
}

enum DashboardRange: String, CaseIterable, Identifiable {
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

enum DashboardMetric: String, CaseIterable, Identifiable {
    case evidenceHours = "evidence-hours"
    case llmTurns = "llm-turns"
    case commits
    case committedLines = "committed-lines"

    var id: Self { self }
    var title: String {
        switch self {
        case .evidenceHours: "Evidence hours"
        case .llmTurns: "LLM turns"
        case .commits: "Commits"
        case .committedLines: "Committed lines"
        }
    }
    var trendTitle: String {
        switch self {
        case .evidenceHours: "Evidence events"
        default: title
        }
    }
    var hourlySubtitle: String { "\(trendTitle) by hour" }
    var icon: String {
        switch self {
        case .evidenceHours: "clock.fill"
        case .llmTurns: "sparkles"
        case .commits: "point.topleft.down.to.point.bottomright.curvepath"
        case .committedLines: "plus.forwardslash.minus"
        }
    }
    var tint: Color {
        switch self {
        case .evidenceHours: .indigo
        case .llmTurns: .purple
        case .commits: .blue
        case .committedLines: .green
        }
    }
    func trendValue(_ snapshot: ActivitySnapshot) -> Int {
        switch self {
        case .evidenceHours: snapshot.evidenceCount
        case .llmTurns: snapshot.llmTurns
        case .commits: snapshot.commits
        case .committedLines: snapshot.additions
        }
    }
}

private struct OverviewView: View {
    @ObservedObject var model: AppModel
    @State private var range: DashboardRange = .week
    @State private var selectedDate: Date?
    @State private var showingDatePicker = false
    @State private var trendHours: [HourActivity] = []
    @State private var isLoadingTrend = false
    @State private var selectedMetric: DashboardMetric
    private let requestedRange: DashboardRange?
    private let requestedDate: Date?

    init(model: AppModel) {
        self.model = model
        let requested = ProcessInfo.processInfo.environment["TRACKIFY_UI_RANGE"].flatMap { value in
            DashboardRange.allCases.first { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame }
        }
        let date = ProcessInfo.processInfo.environment["TRACKIFY_UI_DATE"]
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        let metric =
            ProcessInfo.processInfo.environment["TRACKIFY_UI_METRIC"]
            .flatMap(DashboardMetric.init(rawValue:)) ?? .evidenceHours
        requestedRange = requested
        requestedDate = date
        _range = State(initialValue: requested ?? .week)
        _selectedDate = State(initialValue: date.map { Calendar.current.startOfDay(for: $0) })
        _selectedMetric = State(initialValue: metric)
    }

    private var effectiveDate: Date {
        selectedDate ?? Calendar.current.startOfDay(for: model.referenceNow)
    }

    private var selectedDays: [CalendarActivity] {
        let inclusiveEnd = Calendar.current.date(byAdding: .day, value: 1, to: effectiveDate)!
        return Array(model.historyDays.filter { $0.date < inclusiveEnd }.suffix(range.dayCount))
    }

    private var totals: ActivityTotals { ActivityTotals(selectedDays.map(\.activity)) }
    private var trendInterval: DateInterval {
        let start = selectedDays.first?.date ?? effectiveDate
        let finalDay = selectedDays.last?.date ?? effectiveDate
        let end = Calendar.current.date(byAdding: .day, value: 1, to: finalDay) ?? finalDay
        return DateInterval(start: start, end: end)
    }

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
                            Button("Today") {
                                selectedDate = Calendar.current.startOfDay(for: model.referenceNow)
                            }
                            .frame(width: 58)
                            .disabled(isToday)
                            Button {
                                moveSelection(by: -1)
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            Button {
                                showingDatePicker.toggle()
                            } label: {
                                Label(dateButtonTitle, systemImage: "calendar")
                                    .frame(width: 122)
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
                        tint: .indigo,
                        isSelected: selectedMetric == .evidenceHours
                    ) { selectedMetric = .evidenceHours }
                    MetricCard(
                        title: "LLM turns",
                        value: totals.llmTurns.formatted(),
                        detail: rangeDetail(\.llmTurns),
                        icon: "sparkles",
                        tint: .purple,
                        isSelected: selectedMetric == .llmTurns
                    ) { selectedMetric = .llmTurns }
                    MetricCard(
                        title: "Commits",
                        value: totals.commits.formatted(),
                        detail: rangeDetail(\.commits),
                        icon: "point.topleft.down.to.point.bottomright.curvepath",
                        tint: .blue,
                        isSelected: selectedMetric == .commits
                    ) { selectedMetric = .commits }
                    MetricCard(
                        title: "Committed lines",
                        value: "+\(totals.additions.formatted())",
                        detail: "−\(totals.deletions.formatted()) · \(totals.filesChanged) files",
                        icon: "plus.forwardslash.minus",
                        tint: .green,
                        isSelected: selectedMetric == .committedLines
                    ) { selectedMetric = .committedLines }
                }

                HStack(alignment: .top, spacing: 14) {
                    Panel(title: "Activity trend", subtitle: selectedMetric.hourlySubtitle) {
                        if selectedDays.isEmpty {
                            EmptyInline(text: "No activity history in this range")
                        } else if trendHours.isEmpty && isLoadingTrend {
                            EmptyInline(text: "Loading hourly activity…")
                        } else {
                            OverviewTrendChart(
                                range: range,
                                metric: selectedMetric,
                                interval: trendInterval,
                                referenceNow: model.referenceNow,
                                hours: trendHours
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
                    Panel(title: range == .day ? "Summary" : "Daily summaries", subtitle: "What was actually being worked on") {
                        if summariesInRange.isEmpty {
                            EmptyInline(text: "No summary is available for this range yet")
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(summariesInRange.prefix(7)), id: \.id) { summary in
                                    SummaryOverviewCard(
                                        summary: summary,
                                        provenance: model.summaryProvenance(for: summary),
                                        copy: model.copy)
                                    if summary.id != summariesInRange.prefix(7).last?.id { Divider() }
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
        .task(id: trendQueryID) {
            guard !selectedDays.isEmpty else {
                trendHours = []
                isLoadingTrend = false
                return
            }
            isLoadingTrend = true
            if range == .day && isToday { trendHours = model.hours } else { trendHours = [] }
            let interval = trendInterval
            let loaded = await model.hourActivity(from: interval.start, through: interval.end)
            guard !Task.isCancelled else { return }
            trendHours = loaded
            isLoadingTrend = false
        }
    }

    private var isToday: Bool { Calendar.current.isDate(effectiveDate, inSameDayAs: model.referenceNow) }
    private var dateEyebrow: String {
        isToday ? "Today · \(effectiveDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))" : "Historical view"
    }
    private var dateButtonTitle: String {
        effectiveDate.formatted(.dateTime.month(.abbreviated).day().year())
    }
    private var trendQueryID: String {
        "\(range.rawValue)|\(trendInterval.start.timeIntervalSince1970)|\(trendInterval.end.timeIntervalSince1970)|\(selectedDays.count)"
    }
    private var availableDateRange: ClosedRange<Date> {
        (model.historyDays.first?.date ?? effectiveDate)...Calendar.current.startOfDay(for: model.referenceNow)
    }
    private var summariesInRange: [WorkSummary] {
        if range == .day, isToday, let current = model.latestCurrentSummary {
            return [current]
        }
        guard let first = selectedDays.first?.date, let last = selectedDays.last?.date,
            let end = Calendar.current.date(byAdding: .day, value: 1, to: last)
        else { return [] }
        let candidates = model.summaries.filter {
            $0.kind == .day && $0.periodStart >= first && $0.periodStart < end
        }
        let grouped = Dictionary(grouping: candidates) {
            Calendar.current.startOfDay(for: $0.periodStart)
        }
        return grouped.values.compactMap { values in
            values.max { lhs, rhs in
                lhs.generatedAt == rhs.generatedAt
                    ? lhs.revision < rhs.revision
                    : lhs.generatedAt < rhs.generatedAt
            }
        }.sorted { $0.periodStart > $1.periodStart }
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
        case summaries = "Summaries"
        case commits = "Commits"
        case conversations = "Conversations"
        case changes = "Changes"
        var id: Self { self }
    }

    private var entries: [TimelineEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let repositoryNames = repositoryNamesByID
        let summaries = summariesByID
        return model.timeline.filter { entry in
            let matchesKind: Bool
            switch filter {
            case .all: matchesKind = true
            case .summaries: matchesKind = entry.kind == .summary
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
                || (entry.source?.rawValue.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || (entry.state.map(humanState)?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || (summaries[entry.id].map {
                    model.summaryProvenance(for: $0).label.localizedCaseInsensitiveContains(trimmedQuery)
                } ?? false)
        }
    }

    var body: some View {
        let visibleEntries = entries
        let dayGroups = groupedDays(visibleEntries)
        let repositoryNames = repositoryNamesByID
        let summaries = summariesByID

        VStack(spacing: 0) {
            PageHeader(
                eyebrow: "Summaries and concrete evidence",
                title: "Activity",
                subtitle: "Search and filter the chronological work ledger"
            ) {
                TrackifySearchField("Search activity", text: $query)
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
                                        if entry.kind == .summary, let summary = summaries[entry.id] {
                                            SummaryActivityCard(
                                                summary: summary,
                                                provenance: model.summaryProvenance(for: summary),
                                                copy: model.copy)
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
    private var summariesByID: [String: WorkSummary] {
        var result: [String: WorkSummary] = [:]
        for summary in model.summaries { result[summary.id.rawValue] = summary }
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
        return filter == .summaries ? "No summaries yet" : "No activity yet"
    }
    private var emptyIcon: String { filter == .summaries ? "text.document" : "list.bullet.rectangle" }
    private var emptyDescription: String {
        if filter == .summaries {
            return "Automatic summaries appear here as the evidence-backed timeline develops."
        }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter != .all {
            return "Try a different filter or search term."
        }
        return "Collected commits, conversations, summaries, and working-copy changes will appear here automatically."
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
                    if let sourceLabel {
                        Text(sourceLabel).font(.caption).foregroundStyle(.secondary)
                    }
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

    private var sourceLabel: String? {
        guard entry.kind == .conversation else { return nil }
        return switch entry.source {
        case .some(.codex): "Codex"
        case .some(.claude): "Claude"
        default: nil
        }
    }

    private var icon: String {
        switch entry.kind {
        case .summary: "text.document.fill"
        case .commit: "point.topleft.down.to.point.bottomright.curvepath"
        case .conversation: entry.messageRole == .user ? "person.fill" : "sparkles"
        case .change: "pencil.and.list.clipboard"
        case .test: "checkmark.seal.fill"
        }
    }
    private var tint: Color {
        switch entry.kind {
        case .summary: .indigo
        case .commit: .blue
        case .conversation: entry.messageRole == .user ? .blue : .purple
        case .change: .orange
        case .test: entry.state == "failed" ? .red : .green
        }
    }
}

private struct SummaryActivityCard: View {
    let summary: WorkSummary
    let provenance: SummaryProvenancePresentation
    let copy: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").foregroundStyle(.indigo)
                Text("Summary").font(.caption.weight(.semibold)).foregroundStyle(.indigo)
                SummaryProvenanceBadge(provenance: provenance)
                StateBadge(state: summary.state.rawValue)
                Spacer()
                Text(summaryPeriodLabel)
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Text(summary.content.narrative).font(.body.weight(.medium)).lineLimit(expanded ? nil : 4)
            if expanded, !summary.content.projectSections.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.content.projectSections, id: \.project) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.project).font(.caption.weight(.semibold)).foregroundStyle(.indigo)
                            Text(section.narrative).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Label(SummaryCoveragePresentation.label(summary.coverage), systemImage: "list.bullet.rectangle")
                if expanded, let detail = provenance.detail {
                    Text("·")
                    Text(detail)
                }
                Spacer()
                Button(expanded ? "Less" : "Details") { expanded.toggle() }.buttonStyle(.link)
                Button {
                    copy(summary.content.narrative)
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

    private var summaryPeriodLabel: String {
        let start = summary.periodStart.formatted(.dateTime.hour().minute())
        let end = summary.periodEnd.formatted(.dateTime.hour().minute())
        return "\(start)–\(end)"
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
                        TrackifySearchField("Filter repositories", text: $searchText)
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
    @State private var activity: ActivitySnapshot?
    @State private var isLoadingActivity = false
    private var entries: [TimelineEntry] { model.timeline.filter { $0.repositoryID == item.repository.id } }

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
                VStack(alignment: .leading, spacing: 8) {
                    Text("LAST \(AppModel.presentationHistoryDays) DAYS")
                        .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        CompactMetric(
                            value: metricValue(\.activeHours), label: "Evidence hours", tint: .indigo)
                        CompactMetric(value: metricValue(\.llmTurns), label: "LLM turns", tint: .purple)
                        CompactMetric(value: metricValue(\.commits), label: "Commits", tint: .blue)
                    }
                }
                Panel(title: "Repository", subtitle: nil) {
                    VStack(spacing: 12) {
                        LabeledContent("Branch", value: item.workingCopy.branch ?? "Unknown")
                        if let head = item.workingCopy.headCommit {
                            Divider()
                            LabeledContent("HEAD", value: String(head.prefix(12)))
                        }
                        Divider()
                        LabeledContent("Path") {
                            Text(item.workingCopy.canonicalPath).textSelection(.enabled)
                        }
                        if let remote = item.repository.remoteIdentity {
                            Divider()
                            LabeledContent("Remote") {
                                Text(remote).textSelection(.enabled).lineLimit(2)
                            }
                        }
                        Divider()
                        LabeledContent(
                            "Last observed",
                            value: item.repository.lastObservedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }
                Panel(title: "Recent evidence", subtitle: "Latest loaded entries associated with this repository") {
                    if entries.isEmpty {
                        EmptyInline(text: "No recent entries are available in the loaded timeline")
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
        .task(id: item.repository.id) {
            isLoadingActivity = true
            activity = await model.projectActivity(repositoryID: item.repository.id)
            isLoadingActivity = false
        }
    }

    private func metricValue(_ keyPath: KeyPath<ActivitySnapshot, Int>) -> String {
        if let activity { return activity[keyPath: keyPath].formatted() }
        return isLoadingActivity ? "…" : "0"
    }

    private func projectIcon(_ entry: TimelineEntry) -> String {
        switch entry.kind {
        case .summary: "text.document"
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
        case .summary: .indigo
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

private struct SidebarRuntimeStatus: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatusPill(text: status.title, color: status.color)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var status: (title: String, color: Color) {
        if model.collectionPaused { return ("Collection paused", .secondary) }
        if model.degradedMessage != nil { return ("Needs attention", .orange) }
        if model.liveCollectorStatus.mode == .stopped { return ("Starting collector", .secondary) }
        if model.isRecordingPending { return ("Recording evidence", .blue) }
        if model.isAnyCollectionActive { return ("Syncing evidence", .blue) }
        if model.isSummarizing { return ("Writing summary", .purple) }
        return ("Up to date", .green)
    }

    private var detail: String {
        if model.liveCollectorStatus.pendingPathCount > 0 {
            let count = model.liveCollectorStatus.pendingPathCount
            return "\(count) repository scope\(count == 1 ? "" : "s") pending"
        }
        if let date = model.latestSuccessfulCollectionAt {
            return "Updated \(date.formatted(.relative(presentation: .named)))"
        }
        return "Waiting for the first collection"
    }
}

private struct AppStatusBanner: View {
    let message: String
    let canDismiss: Bool
    let review: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button("Review") { review() }
                .buttonStyle(.link)
            if canDismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
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
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .font(.caption.weight(.semibold)).foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? tint : .secondary)
                }
                Text(value).font(.title2.bold().monospacedDigit())
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? tint.opacity(0.075) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? tint.opacity(0.85) : Color.secondary.opacity(0.13), lineWidth: isSelected ? 2 : 1)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

private struct SummaryOverviewCard: View {
    let summary: WorkSummary
    let provenance: SummaryProvenancePresentation
    let copy: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                HStack {
                    Text(summary.periodStart, format: .dateTime.month(.abbreviated).day())
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    StateBadge(state: summary.state.rawValue)
                }
                Spacer()
                SummaryProvenanceBadge(provenance: provenance)
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless).help(expanded ? "Collapse summary" : "Expand summary")
                Button {
                    copy(summary.content.narrative)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless).help("Copy summary")
            }
            Text(summary.content.narrative)
                .font(.callout)
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
            if expanded, !summary.content.projectSections.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(summary.content.projectSections, id: \.project) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.project)
                                .font(.caption.weight(.bold)).foregroundStyle(.tint)
                            Text(section.narrative).font(.callout).foregroundStyle(.secondary)
                            if !section.openWork.isEmpty {
                                Label(section.openWork.joined(separator: " · "), systemImage: "circle.lefthalf.filled")
                                    .font(.caption).foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            Label(SummaryCoveragePresentation.label(summary.coverage), systemImage: "list.bullet.rectangle")
                .font(.caption).foregroundStyle(.secondary)
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
        case sources, summaries, usage, general
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
                .tabItem { Label("AI Providers", systemImage: "sparkles") }
                .tag(SettingsTab.summaries)
            usageView
                .tabItem { Label("Usage", systemImage: "chart.bar") }
                .tag(SettingsTab.usage)
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
            SwiftUI.Section("Evidence quality") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.evidenceQuality.state == .healthy ? "Canonical evidence is healthy" : "Evidence needs attention")
                        Text(
                            "Projection v\(model.evidenceQuality.projectionVersion) · \(model.evidenceQuality.unresolvedRecordCount) unresolved · \(model.evidenceQuality.aliasRecordCount) aliases · \(model.evidenceQuality.replayRecordCount) replays"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(
                        text: model.evidenceQuality.state == .healthy ? "Healthy" : "Degraded",
                        color: model.evidenceQuality.state == .healthy ? .green : .orange)
                }
                ForEach(model.evidenceQuality.issues, id: \.id) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.code.replacingOccurrences(of: "-", with: " ").capitalized)
                        Text("\(issue.detail) · \(issue.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Diagnostics contain structural counts and compatibility labels only—never raw private message text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Conversation history") {
                ForEach(model.sourceCapabilities) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(source.surface)
                            Spacer()
                            StatusPill(
                                text: humanState(source.state.rawValue),
                                color: sourceColor(source.state))
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(root.displayName)
                            Spacer()
                            StatusPill(
                                text: root.isEnabled ? "Enabled" : "Disabled",
                                color: root.isEnabled ? .green : .secondary)
                        }
                        Text(root.canonicalPath)
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text(
                                root.lastScannedAt.map {
                                    "Scanned \($0.formatted(date: .abbreviated, time: .shortened))"
                                } ?? "Not scanned yet")
                            if !root.excludedPaths.isEmpty {
                                Text("· \(root.excludedPaths.count) exclusions")
                            }
                        }
                        .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }.formStyle(.grouped)
    }

    private func sourceColor(_ state: CapabilityState) -> Color {
        switch state {
        case .available: .green
        case .degraded, .permissionDenied: .orange
        case .unsupported, .notFound: .secondary
        }
    }

    private func authenticationColor(_ state: AuthenticationState) -> Color {
        switch state {
        case .ready: .green
        case .unknown: .orange
        case .unavailable, .notInstalled: .secondary
        }
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
                LabeledContent(
                    "Effective provider",
                    value: model.effectiveProvider?.rawValue.capitalized ?? "Local fallback")
                Toggle(
                    "Use AI for automatic summaries",
                    isOn: Binding(
                        get: { model.automaticSummariesUseLLM },
                        set: { value in Task { await model.setAutomaticSummariesUseLLM(value) } }))
                ForEach(model.generationCapabilities) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.id.rawValue.capitalized)
                            Text(provider.cliVersion ?? provider.executablePath ?? "Not installed")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let detail = provider.detail {
                                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        Spacer()
                        StatusPill(
                            text: humanState(provider.authentication.rawValue),
                            color: authenticationColor(provider.authentication))
                        Button("Test") { Task { await model.testProvider(provider.id) } }
                            .disabled(provider.executablePath == nil || model.isSummarizing)
                        if provider.id == .claude, provider.authentication == .unavailable {
                            Button("Copy login command") { model.copy("claude auth login") }
                        }
                    }
                }
                Text("Tests send a tiny synthetic payload only. Trackify never reads or changes provider credentials or configuration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Weekly AI budget") {
                if let allowance = model.generationBudgetStatus.allowance {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Codex weekly allowance")
                            Spacer()
                            Text("\(allowance.remainingPercent)% left")
                        }
                        ProgressView(value: Double(allowance.remainingPercent), total: 100)
                        if let reset = allowance.resetsAt {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    LabeledContent("Provider allowance", value: "Not exposed")
                }
                LabeledContent("Trackify weekly target") {
                    TextField("Percent", value: weeklyAllowanceBinding, format: .number)
                        .multilineTextAlignment(.trailing).frame(width: 72)
                    Text("%").foregroundStyle(.secondary)
                }
                LabeledContent("Credit safeguard") {
                    TextField("Credits", value: weeklyCreditsBinding, format: .number)
                        .multilineTextAlignment(.trailing).frame(width: 92)
                    Text("credits").foregroundStyle(.secondary)
                }
                Text(
                    "Trackify measures its own calls and, when Codex exposes it, the actual weekly subscription percentage before and after each generation. Your unrelated Codex work is not charged to Trackify."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Safety limits") {
                LabeledContent("Calls per day") {
                    TextField("Calls", value: $budgets.maximumCallsPerDay, format: .number)
                        .multilineTextAlignment(.trailing).frame(width: 92)
                }
                LabeledContent("Input tokens per call") {
                    TextField(
                        "Tokens", value: $budgets.maximumEstimatedInputTokensPerCall,
                        format: .number
                    )
                    .multilineTextAlignment(.trailing).frame(width: 110)
                }
                LabeledContent("Daily token ceiling") {
                    TextField("Tokens", value: $budgets.dailyTokenLimit, format: .number)
                        .multilineTextAlignment(.trailing).frame(width: 110)
                }
                LabeledContent("Provider deadline") {
                    TextField("Seconds", value: $budgets.processDeadlineSeconds, format: .number)
                        .multilineTextAlignment(.trailing).frame(width: 92)
                    Text("seconds").foregroundStyle(.secondary)
                }
                Button("Save budgets") { Task { await model.saveGenerationBudgets(budgets) } }
                Text(
                    "These are emergency burst safeguards. The weekly percentage and credit budget are the primary controls."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var usageView: some View {
        Form {
            SwiftUI.Section("Weekly budget") {
                if let allowance = model.generationBudgetStatus.allowance {
                    LabeledContent("Codex allowance", value: "\(allowance.remainingPercent)% left")
                    if let reset = allowance.resetsAt {
                        LabeledContent(
                            "Resets",
                            value: reset.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                LabeledContent(
                    "Trackify-attributed allowance",
                    value:
                        "\(model.generationBudgetStatus.allowanceAttributedPercent)% / \(model.generationBudgetStatus.allowancePercentLimit ?? 0)%"
                )
                LabeledContent(
                    "Estimated credits",
                    value:
                        "\(model.generationBudgetStatus.estimatedCreditsUsed.formatted()) / \((model.generationBudgetStatus.weeklyCreditLimit ?? 0).formatted())"
                )
                LabeledContent(
                    "Calls today",
                    value: "\(model.generationBudgetStatus.callsToday) / \(model.generationBudgetStatus.callsPerDayLimit)")
                if model.generationBudgetStatus.isPaused {
                    Label(
                        "Automatic generation paused: \(model.generationBudgetStatus.pauseReason ?? "budget")",
                        systemImage: "pause.circle.fill"
                    )
                    .foregroundStyle(.orange)
                } else {
                    Label("Automatic generation available", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            SwiftUI.Section("Trackify-initiated model usage") {
                UsageRow(title: "Today", usage: model.usageToday)
                UsageRow(title: "This month", usage: model.usageMonth)
                Text(
                    "Costs are shown only when the provider reports an attributable estimate. Subscription or managed billing remains unknown."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Recent runs") {
                if recentGenerationRuns.isEmpty {
                    Text("No summary or report runs yet.").foregroundStyle(.secondary)
                }
                ForEach(recentGenerationRuns.prefix(16)) { run in
                    GenerationRunRow(run: run)
                }
            }
        }.formStyle(.grouped)
    }

    private var recentGenerationRuns: [GenerationRunPresentation] {
        let templateNames = Dictionary(
            uniqueKeysWithValues: model.reportTemplates.map { ($0.id, $0.recipe.name) })
        return GenerationRunPresentation.merge(
            summaries: model.summaryRuns,
            reports: model.reportRuns,
            templateNames: templateNames)
    }

    private var weeklyAllowanceBinding: Binding<Int> {
        Binding(
            get: { budgets.weeklyAllowancePercentLimit ?? 3 },
            set: { budgets.weeklyAllowancePercentLimit = min(max($0, 1), 20) })
    }

    private var weeklyCreditsBinding: Binding<Int> {
        Binding(
            get: {
                NSDecimalNumber(decimal: budgets.weeklyCreditLimit ?? 500).intValue
            },
            set: { budgets.weeklyCreditLimit = Decimal(min(max($0, 50), 10_000)) })
    }

    private var generalView: some View {
        Form {
            SwiftUI.Section("Collection") {
                LabeledContent("Status", value: collectionStatus)
                LabeledContent(
                    "Last successful update",
                    value: model.latestSuccessfulCollectionAt?.formatted(date: .abbreviated, time: .shortened)
                        ?? "Not yet")
                if model.liveCollectorStatus.pendingPathCount > 0 || model.liveCollectorStatus.pendingTriggerCount > 0 {
                    LabeledContent(
                        "Pending work",
                        value:
                            "\(model.liveCollectorStatus.pendingPathCount) repository scopes · \(model.liveCollectorStatus.pendingTriggerCount) filesystem signals"
                    )
                }
                if let median = model.liveCollectorStatus.medianLatencySeconds {
                    LabeledContent(
                        "Typical live latency",
                        value: "\(median.formatted(.number.precision(.fractionLength(1)))) seconds")
                }
                Toggle("Launch Trackify at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in model.setLaunchAtLogin(value) }
                Toggle(
                    "Pause passive collection",
                    isOn: Binding(
                        get: { model.collectionPaused },
                        set: { value in Task { await model.setCollectionPaused(value) } }))
                LabeledContent("Reconciliation", value: "Every 30 minutes")
                LabeledContent("Evidence", value: "Local only")
                Button {
                    Task { await model.collectNow() }
                } label: {
                    if model.isAnyCollectionActive {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Syncing…")
                        }
                    } else {
                        Text("Sync now")
                    }
                }
                .disabled(model.isAnyCollectionActive)
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
        if model.liveCollectorStatus.mode == .stopped { return "Starting" }
        if model.isRecordingPending { return "Recording" }
        if model.isAnyCollectionActive { return "Syncing" }
        return "Up to date"
    }
}

struct GenerationRunPresentation: Identifiable, Equatable {
    enum Kind: Equatable { case summary, report }

    let id: String
    let kind: Kind
    let title: String
    let provider: String
    let state: ReportRunState
    let usage: String
    let queuedAt: Date
    let failureDetail: String?

    static func merge(
        summaries: [SummaryRun],
        reports: [ReportRun],
        templateNames: [RecipeID: String]
    ) -> [Self] {
        let summaryItems = summaries.map { run in
            Self(
                id: "summary:\(run.id.rawValue)",
                kind: .summary,
                title: summaryTitle(run.kind),
                provider: providerTitle(
                    effective: run.effectiveProvider,
                    requested: run.requestedProvider,
                    selection: run.selectionMode,
                    model: run.effectiveModel ?? run.requestedModel),
                state: run.state,
                usage: usageTitle(
                    usage: run.usage,
                    estimatedInputTokens: run.estimatedInputTokens,
                    effectiveProvider: run.effectiveProvider),
                queuedAt: run.queuedAt,
                failureDetail: run.failureDetail)
        }
        let reportItems = reports.map { run in
            Self(
                id: "report:\(run.id.rawValue)",
                kind: .report,
                title: templateNames[run.recipeID] ?? run.recipeID.rawValue.replacingOccurrences(of: "-", with: " ").capitalized,
                provider: providerTitle(
                    effective: run.effectiveProvider,
                    requested: run.requestedProvider,
                    selection: run.selectionMode,
                    model: run.effectiveModel ?? run.requestedModel),
                state: run.state,
                usage: usageTitle(
                    usage: run.usage,
                    estimatedInputTokens: run.estimatedInputTokens ?? 0,
                    effectiveProvider: run.effectiveProvider),
                queuedAt: run.queuedAt,
                failureDetail: run.failureDetail)
        }
        return (summaryItems + reportItems).sorted { $0.queuedAt > $1.queuedAt }
    }

    private static func summaryTitle(_ kind: WorkSummaryKind) -> String {
        switch kind {
        case .segment: "Automatic half-hour summary"
        case .current: "Current-work rollup"
        case .day: "Daily summary"
        }
    }

    private static func providerTitle(
        effective: SummaryProviderID?,
        requested: SummaryProviderID?,
        selection: ProviderSelectionMode,
        model: String?
    ) -> String {
        if let provider = effective {
            let base = provider.rawValue.capitalized
            return model.map { "\(base) · \($0)" } ?? base
        }
        if selection == .localOnly { return "Local" }
        if let requested { return "\(requested.rawValue.capitalized) requested" }
        return humanState(selection.rawValue)
    }

    private static func usageTitle(
        usage: ProviderUsage,
        estimatedInputTokens: Int,
        effectiveProvider: SummaryProviderID?
    ) -> String {
        if let measured = usage.knownTokenTotal, measured > 0 {
            return "\(measured.formatted()) tokens"
        }
        if effectiveProvider != nil, estimatedInputTokens > 0 {
            return "~\(estimatedInputTokens.formatted()) input tokens"
        }
        return effectiveProvider == nil ? "No AI usage" : "Usage unavailable"
    }
}

private struct GenerationRunRow: View {
    let run: GenerationRunPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: run.kind == .summary ? "sparkles" : "doc.text")
                .foregroundStyle(run.kind == .summary ? Color.purple : Color.blue)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.title).font(.callout.weight(.medium))
                Text("\(run.provider) · \(run.usage)")
                    .font(.caption).foregroundStyle(.secondary)
                if run.state == .failed, let detail = run.failureDetail {
                    Text(detail).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(humanState(run.state.rawValue))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(run.state == .failed ? .red : .secondary)
                Text(run.queuedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
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
                Text("\(usage.runs) \(usage.runs == 1 ? "run" : "runs")")
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
