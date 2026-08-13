import SwiftUI
import TrackifyDomain

struct SummaryProvenancePresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case codex
        case claude
        case local
        case localRollup
        case migrated
    }

    let kind: Kind
    let label: String
    let detail: String?

    static func resolve(
        _ summary: WorkSummary,
        summariesByID: [SummaryID: WorkSummary]
    ) -> Self {
        switch summary.generationSource {
        case .codex:
            return Self(kind: .codex, label: "Codex", detail: summary.model)
        case .claude:
            return Self(kind: .claude, label: "Claude", detail: summary.model)
        case .migrated:
            return Self(kind: .migrated, label: "Migrated", detail: "Imported from an older Trackify summary")
        case .local:
            let providers = descendantProviders(
                summary.childSummaryIDs,
                summariesByID: summariesByID,
                visited: [])
            guard !providers.isEmpty else {
                let label: String
                let detail: String
                switch summary.kind {
                case .current:
                    label = "Programmatic"
                    detail = "The open hour is updated locally every 15 minutes"
                case .day:
                    label = "Programmatic rollup"
                    detail = "Composed locally from the day's built-in summaries"
                case .segment:
                    label = "Local fallback"
                    detail = "The hourly AI summary could not run"
                }
                return Self(kind: .local, label: label, detail: detail)
            }
            let providerLabel: String
            if providers == [.codex] {
                providerLabel = "Codex"
            } else if providers == [.claude] {
                providerLabel = "Claude"
            } else {
                providerLabel = "Codex + Claude"
            }
            return Self(
                kind: .localRollup,
                label: "Programmatic rollup · \(providerLabel)",
                detail: "Composed locally from underlying \(providerLabel) hourly summaries")
        }
    }

    private static func descendantProviders(
        _ ids: [SummaryID],
        summariesByID: [SummaryID: WorkSummary],
        visited: Set<SummaryID>
    ) -> Set<SummaryProviderID> {
        var visited = visited
        var result: Set<SummaryProviderID> = []
        for id in ids where visited.insert(id).inserted {
            guard let child = summariesByID[id] else { continue }
            if let provider = child.provider {
                result.insert(provider)
            }
            result.formUnion(
                descendantProviders(
                    child.childSummaryIDs,
                    summariesByID: summariesByID,
                    visited: visited))
        }
        return result
    }
}

enum SummaryCoveragePresentation {
    static func label(_ coverage: SummaryCoverage) -> String {
        guard coverage.isKnown else { return "Coverage unknown" }
        let events =
            coverage.isComplete
            ? "\(coverage.coveredEventCount) covered events"
            : "\(coverage.coveredEventCount)/\(coverage.eligibleEventCount) covered events"
        guard coverage.truncatedAssistantCount > 0 else { return events }
        let responses = coverage.truncatedAssistantCount == 1 ? "response" : "responses"
        return "\(events) · \(coverage.truncatedAssistantCount) shortened agent \(responses)"
    }
}

struct SummaryProvenanceBadge: View {
    let provenance: SummaryProvenancePresentation

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(provenance.label)
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .help(provenance.detail ?? provenance.label)
        .accessibilityLabel(provenance.detail.map { "\(provenance.label), \($0)" } ?? provenance.label)
    }

    private var icon: String {
        switch provenance.kind {
        case .codex, .claude: "sparkles"
        case .local: "function"
        case .localRollup: "arrow.triangle.merge"
        case .migrated: "clock.arrow.circlepath"
        }
    }

    private var color: Color {
        switch provenance.kind {
        case .codex: .purple
        case .claude: .orange
        case .local: .secondary
        case .localRollup: .indigo
        case .migrated: .secondary
        }
    }
}

struct TrackifySearchField: View {
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
        .frame(height: 30)
        .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(color)
    }
}
