import Charts
import SwiftUI
import TrackifyDomain

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateController
    @ObservedObject var router: AppRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.referenceNow, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(headline)
                        .font(.headline)
                }
                Spacer()
                CollectionStatusBadge(title: collectionStatus.title, color: collectionStatus.color)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("LATEST EVIDENCE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if model.collectionPaused {
                    Label("Passive collection is paused", systemImage: "pause.circle")
                        .font(.callout)
                } else if let latestEvidenceAt = model.latestEvidenceAt {
                    Label("Recorded \(latestEvidenceAt, style: .relative)", systemImage: "clock")
                        .font(.callout)
                    if !model.activeRepositoryNames.isEmpty {
                        Text(model.activeRepositoryNames.prefix(4).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Label("No evidence recorded today", systemImage: "circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if let activity = model.dashboard?.activity {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 10) {
                    Metric(value: "\(activity.activeHours)", label: "Active hours")
                    Metric(value: "\(activity.llmTurns)", label: "LLM turns")
                    Metric(value: "\(activity.commits)", label: "Commits")
                    Metric(value: "\(activity.filesChanged)", label: "Files")
                    Metric(value: "+\(activity.additions)/-\(activity.deletions)", label: "Lines")
                    Metric(value: "\(activity.repositoryIDs.count)", label: "Repositories")
                }
                if let percent = model.dashboard?.comparison.activeHours.percentChange,
                    model.dashboard?.comparison.activeDays ?? 0 > 0
                {
                    Label(
                        "\(percent, format: .number.precision(.fractionLength(0)).sign(strategy: .always()))% vs active-day average",
                        systemImage: percent >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        let chartNow = model.isUIValidation ? model.referenceNow : timeline.date
                        Chart {
                            ForEach(model.hours) { hour in
                                BarMark(
                                    x: .value("Hour", hour.start, unit: .hour),
                                    y: .value("Evidence", hour.evidenceCount)
                                )
                                .foregroundStyle(Color.accentColor.gradient)
                            }
                            if hourlyChartDomain.contains(chartNow) {
                                RuleMark(x: .value("Current time", chartNow))
                                    .foregroundStyle(Color.pink.opacity(0.9))
                                    .lineStyle(StrokeStyle(lineWidth: 1))
                                    .accessibilityLabel("Current time")
                            }
                        }
                        .chartXScale(domain: hourlyChartDomain)
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                    }
                    .frame(height: 46)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
                    }

                    HStack {
                        ForEach(["00", "06", "12", "18", "24"], id: \.self) { label in
                            Text(label)
                            if label != "24" { Spacer() }
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Hourly evidence")
            } else {
                Text("Loading ledger…").foregroundStyle(.secondary)
            }

            if let summary = model.latestCurrentSummary {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("CURRENT WORK")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        ReportStateLabel(state: summary.state)
                    }
                    Text(summary.content.compactNarrative)
                        .font(.callout)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        if !summary.content.projects.isEmpty {
                            Text(summary.content.projects.prefix(4).joined(separator: ", "))
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(summary.provider?.rawValue.capitalized ?? "Local")
                        Text("·")
                        Text(summary.generatedAt, style: .relative)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("No work summary is available yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = model.degradedMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Divider()

            HStack {
                Button("Open Trackify") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button {
                    Task { await model.setCollectionPaused(!model.collectionPaused) }
                } label: {
                    Image(systemName: model.collectionPaused ? "play.fill" : "pause.fill")
                }
                .help(model.collectionPaused ? "Resume collection" : "Pause collection")
                Menu {
                    Button {
                        Task { await model.collectNow() }
                    } label: {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.isCollecting)

                    Divider()
                    Button {
                        router.selection = .settings
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    Button {
                        updates.checkForUpdates()
                    } label: {
                        Label("Check for Updates…", systemImage: "arrow.down.circle")
                    }
                    .disabled(!updates.canCheckForUpdates)

                    Divider()
                    Button("Quit Trackify", systemImage: "power") {
                        NSApp.terminate(nil)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("More")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 390)
        .task { await model.start() }
    }

    private var headline: String {
        if model.collectionPaused { return "Collection paused" }
        if model.degradedMessage != nil { return "Trackify needs attention" }
        if model.llmBudgetPaused { return "Evidence current · LLM budget paused" }
        if model.isSummarizing { return "Evidence current · summarizing" }
        return model.hasEvidenceToday ? "Evidence recorded today" : "Tracking quietly"
    }

    private var collectionStatus: (title: String, color: Color) {
        if model.collectionPaused { return ("Paused", .secondary) }
        if model.degradedMessage != nil { return ("Needs attention", .orange) }
        if model.isCollecting { return ("Syncing", .blue) }
        if model.llmBudgetPaused { return ("LLM paused", .orange) }
        if model.isSummarizing { return ("Summarizing", .purple) }
        return ("Up to date", .green)
    }

    private var hourlyChartDomain: ClosedRange<Date> {
        let calendar = Calendar.current
        let start = model.hours.first?.start ?? calendar.startOfDay(for: model.referenceNow)
        let lastHour = model.hours.last?.start ?? start
        let end = calendar.date(byAdding: .hour, value: 1, to: lastHour) ?? lastHour.addingTimeInterval(3_600)
        return start...end
    }
}

private struct CollectionStatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityLabel("Collection status: \(title)")
    }
}

private struct ReportStateLabel: View {
    let state: ReportPeriodState

    var body: some View {
        Text(state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .completed: .green
        case .inProgress: .blue
        case .investigating, .waiting: .orange
        case .observed, .noActivity: .secondary
        }
    }
}

private struct Metric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
