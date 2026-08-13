import Foundation
import TrackifyDomain
import TrackifyStore

public struct SummaryRefreshResult: Codable, Equatable, Sendable {
    public let generated: [SummaryID]
    public let unchanged: Int
    public let issues: [String]

    public init(generated: [SummaryID], unchanged: Int, issues: [String]) {
        self.generated = generated
        self.unchanged = unchanged
        self.issues = issues
    }
}

public struct SummaryCoordinator: Sendable {
    public static let generatorVersion = "work-summary-v6"
    public static let promptVersion = "work-summary-prompt-v6"
    public static let schemaVersion = "work-summary-v1"

    private let compiler: SummaryCoverageCompiler
    private let providerFactory: @Sendable (SummaryProviderID, TimeInterval) -> any SummaryProvider
    private let budgetController: GenerationBudgetController
    private let allowanceReader: any ProviderAllowanceReading
    private let availableProvider:
        @Sendable (
            LedgerStore, Date, ProviderSelectionMode
        ) -> SummaryProviderID?

    public init(
        compiler: SummaryCoverageCompiler = SummaryCoverageCompiler(),
        providerFactory: @escaping @Sendable (SummaryProviderID, TimeInterval) -> any SummaryProvider = {
            SummaryProviderFactory.make($0, timeout: $1)
        },
        allowanceReader: any ProviderAllowanceReading = AutomaticProviderAllowanceReader(),
        budgetController: GenerationBudgetController? = nil,
        availableProvider:
            @escaping @Sendable (
                LedgerStore, Date, ProviderSelectionMode
            ) -> SummaryProviderID? = { store, now, mode in
                let discovery = CapabilityDiscovery()
                let capabilities = discovery.generators(store: store, now: now)
                return discovery.automaticInvocationProvider(
                    mode: mode, capabilities: capabilities)
            }
    ) {
        self.compiler = compiler
        self.providerFactory = providerFactory
        self.allowanceReader = allowanceReader
        self.budgetController =
            budgetController
            ?? GenerationBudgetController(allowanceReader: allowanceReader)
        self.availableProvider = availableProvider
    }

    public static func recoverInterruptedRuns(
        store: LedgerStore,
        now: Date
    ) throws -> [SummaryRun] {
        let ownerID = "summaries:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString)"
        guard
            try ProviderGenerationLease.acquire(
                store: store, ownerID: ownerID, now: now, duration: 60)
        else {
            return []
        }
        defer { try? store.releaseLease(name: ProviderGenerationLease.name, ownerID: ownerID) }
        return try store.recoverInterruptedSummaryRuns(at: now)
    }

    public func refresh(
        store: LedgerStore,
        settings: TrackifySettings,
        now: Date,
        calendar: Calendar = .current,
        lookbackDays: Int = 2
    ) async -> SummaryRefreshResult {
        guard (1...366).contains(lookbackDays) else {
            return SummaryRefreshResult(
                generated: [], unchanged: 0,
                issues: ["Summary lookback must be between 1 and 366 days."])
        }
        guard let today = calendar.dateInterval(of: .day, for: now) else {
            return SummaryRefreshResult(
                generated: [], unchanged: 0,
                issues: ["Could not calculate the local summary day."])
        }
        let ownerID = "summaries:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString)"
        let leaseDuration = max(
            300,
            TimeInterval(settings.generationBudgets.processDeadlineSeconds)
                * TimeInterval(min(settings.generationBudgets.maximumCallsPerDay, 20)))
        do {
            guard
                try ProviderGenerationLease.acquire(
                    store: store, ownerID: ownerID,
                    now: now, duration: leaseDuration)
            else {
                return SummaryRefreshResult(generated: [], unchanged: 0, issues: [])
            }
        } catch {
            return SummaryRefreshResult(
                generated: [], unchanged: 0,
                issues: ["Could not acquire summary generation lease: \(error.localizedDescription)"])
        }
        defer { try? store.releaseLease(name: ProviderGenerationLease.name, ownerID: ownerID) }

        do {
            _ = try store.recoverInterruptedSummaryRuns(at: now)
        } catch {
            return SummaryRefreshResult(
                generated: [], unchanged: 0,
                issues: ["Could not recover interrupted summary runs: \(error.localizedDescription)"])
        }

        let days = (0..<lookbackDays).compactMap { offset -> DateInterval? in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today.start)
            else { return nil }
            return calendar.dateInterval(of: .day, for: start)
        }
        let preferredMode: ProviderSelectionMode =
            settings.automaticSummariesUseLLM ? settings.providerSelection : .localOnly
        let readyProvider =
            preferredMode == .localOnly ? nil : availableProvider(store, now, preferredMode)
        let recoveryBudgetStatus: GenerationBudgetStatus?
        if let readyProvider {
            let provider = providerFactory(
                readyProvider,
                TimeInterval(settings.generationBudgets.processDeadlineSeconds))
            recoveryBudgetStatus = try? budgetController.status(
                store: store, budgets: settings.generationBudgets,
                provider: readyProvider, model: provider.model,
                now: now, calendar: calendar)
        } else {
            recoveryBudgetStatus = nil
        }

        var generated: [SummaryID] = []
        var unchanged = 0
        var issues: [String] = []
        let providerWorkRange = SummaryCadence.providerWorkRange(
            at: now, calendar: calendar)
        for day in days {
            guard !Task.isCancelled else { break }
            let isToday = calendar.isDate(day.start, inSameDayAs: today.start)
            let programmaticCutoff =
                isToday
                ? min(SummaryCadence.programmaticBoundary(at: now, calendar: calendar), day.end)
                : day.end
            let providerCutoff =
                isToday
                ? min(SummaryCadence.completedHourCutoff(at: now, calendar: calendar), day.end)
                : day.end
            guard programmaticCutoff > day.start else { continue }
            let hourlyPeriods: [DateInterval]
            do {
                hourlyPeriods = try activeHourlyIntervals(
                    store: store, in: day, cutoff: providerCutoff, calendar: calendar)
            } catch {
                issues.append("Could not discover active summary periods: \(error.localizedDescription)")
                continue
            }
            var leaves: [WorkSummary] = []
            for period in hourlyPeriods {
                guard !Task.isCancelled else { break }
                do {
                    let isProviderHour =
                        isToday
                        && period.start == providerWorkRange.start
                        && period.end == providerWorkRange.end
                    let periodMode: ProviderSelectionMode =
                        isProviderHour ? preferredMode : .localOnly
                    let periodProvider = isProviderHour ? readyProvider : nil
                    let periodRecoveryStatus =
                        isProviderHour ? recoveryBudgetStatus : nil
                    let compilation = try compiler.compile(
                        store: store, range: period, cutoff: period.end,
                        calendar: calendar)
                    guard compilation.coverage.eligibleEventCount > 0 else { continue }
                    if let existing = try reusableSummary(
                        store: store, settings: settings, kind: .segment,
                        compilation: compilation,
                        preferredMode: periodMode, readyProvider: periodProvider,
                        recoveryBudgetStatus: periodRecoveryStatus, now: now,
                        calendar: calendar)
                    {
                        leaves.append(existing)
                        unchanged += 1
                    } else {
                        let summary = try await generate(
                            store: store, settings: settings, kind: .segment,
                            compilation: compilation, children: [],
                            preferredMode: periodMode, readyProvider: periodProvider,
                            now: now, calendar: calendar)
                        leaves.append(summary)
                        generated.append(summary.id)
                    }
                } catch {
                    issues.append("Hourly summary failed for \(period.start): \(error.localizedDescription)")
                }
            }

            guard !Task.isCancelled else { break }
            leaves.sort { $0.periodStart < $1.periodStart }
            var current: WorkSummary?
            if isToday,
                let currentRange = SummaryCadence.currentWorkRange(at: now, calendar: calendar),
                currentRange.start >= day.start,
                currentRange.end <= programmaticCutoff
            {
                do {
                    let compilation = try compiler.compile(
                        store: store, range: currentRange, cutoff: currentRange.end,
                        calendar: calendar)
                    if compilation.coverage.eligibleEventCount > 0 {
                        if let existing = try reusableSummary(
                            store: store, settings: settings, kind: .current,
                            compilation: compilation, preferredMode: .localOnly,
                            readyProvider: nil, recoveryBudgetStatus: nil,
                            now: now, calendar: calendar)
                        {
                            current = existing
                            unchanged += 1
                        } else {
                            let summary = try await generate(
                                store: store, settings: settings, kind: .current,
                                compilation: compilation, children: [],
                                preferredMode: .localOnly, readyProvider: nil,
                                now: now, calendar: calendar)
                            current = summary
                            generated.append(summary.id)
                        }
                    }
                } catch {
                    issues.append("Current-work summary failed: \(error.localizedDescription)")
                }
            }

            let dayChildren = leaves + [current].compactMap { $0 }
            guard !dayChildren.isEmpty else { continue }
            do {
                let parent = try await generateParentIfChanged(
                    store: store, settings: settings, kind: .day,
                    range: DateInterval(start: day.start, end: programmaticCutoff),
                    children: dayChildren,
                    preferredMode: .localOnly, readyProvider: nil,
                    recoveryBudgetStatus: nil,
                    now: now, calendar: calendar)
                if let parent { generated.append(parent.id) } else { unchanged += 1 }
            } catch {
                issues.append("Daily rollup failed for \(day.start): \(error.localizedDescription)")
            }
        }
        return SummaryRefreshResult(generated: generated, unchanged: unchanged, issues: issues)
    }

    private func generateParentIfChanged(
        store: LedgerStore,
        settings: TrackifySettings,
        kind: WorkSummaryKind,
        range: DateInterval,
        children: [WorkSummary],
        preferredMode: ProviderSelectionMode,
        readyProvider: SummaryProviderID?,
        recoveryBudgetStatus: GenerationBudgetStatus?,
        now: Date,
        calendar: Calendar
    ) async throws -> WorkSummary? {
        let fingerprint = StableHash.sha256(
            "\(Self.generatorVersion)|\(kind.rawValue)|"
                + children.map { "\($0.id.rawValue):\($0.sourceFingerprint)" }.joined(separator: "|"))
        let compilation = parentCompilation(
            range: range, children: children, sourceFingerprint: fingerprint,
            calendar: calendar)
        if try reusableSummary(
            store: store, settings: settings, kind: kind, compilation: compilation,
            preferredMode: preferredMode, readyProvider: readyProvider,
            recoveryBudgetStatus: recoveryBudgetStatus, now: now,
            calendar: calendar) != nil
        {
            return nil
        }
        return try await generate(
            store: store, settings: settings, kind: kind,
            compilation: compilation, children: children,
            preferredMode: preferredMode, readyProvider: readyProvider,
            now: now, calendar: calendar)
    }

    private func generate(
        store: LedgerStore,
        settings: TrackifySettings,
        kind: WorkSummaryKind,
        compilation: SummaryCompilation,
        children: [WorkSummary],
        preferredMode: ProviderSelectionMode,
        readyProvider: SummaryProviderID?,
        now: Date,
        calendar: Calendar
    ) async throws -> WorkSummary {
        guard compilation.coverage.isComplete else {
            throw SummaryCoverageCompilerError.incomplete(
                expected: compilation.coverage.eligibleEventCount,
                covered: compilation.coverage.coveredEventCount)
        }
        let estimatedTokens =
            compilation.estimatedInputTokens
            + (readyProvider == nil ? 0 : compilation.chunks.count * GenerationBudgets.conservativeProviderOverheadTokens)
        let runID = SummaryRunID.random()
        let requestedProvider = preferredMode.explicitProvider ?? readyProvider
        var run = SummaryRun(
            id: runID, kind: kind, periodStart: compilation.range.start,
            periodEnd: compilation.range.end, selectionMode: preferredMode,
            requestedProvider: requestedProvider,
            sourceFingerprint: compilation.sourceFingerprint,
            inputBytes: compilation.serializedByteCount,
            estimatedInputTokens: estimatedTokens, queuedAt: now, state: .pending)
        try store.save(summaryRun: run)

        var content: SummaryContent
        var provider: SummaryProviderID?
        var model: String?
        var usage = ProviderUsage()
        var failureClass: GenerationFailureClass?
        var failureDetail: String?
        var invokedProvider: SummaryProviderID?
        var invokedModel: String?
        let startedAt = now
        let generator = readyProvider.map {
            providerFactory($0, TimeInterval(settings.generationBudgets.processDeadlineSeconds))
        }
        let budgetDecision = try readyProvider.flatMap { provider -> GenerationBudgetDecision? in
            guard let generator else { return nil }
            return try budgetController.decision(
                request: budgetRequest(
                    kind: kind, compilation: compilation,
                    provider: provider, model: generator.model),
                budgets: settings.generationBudgets, store: store, now: now,
                calendar: calendar)
        }

        if let readyProvider, let generator, budgetDecision?.allowed == true {
            invokedProvider = readyProvider
            invokedModel = generator.model
            run = replacing(
                run, requestedProvider: readyProvider, requestedModel: generator.model,
                effectiveProvider: readyProvider, effectiveModel: generator.model,
                usage: usage, startedAt: startedAt, finishedAt: nil, state: .running,
                failureClass: nil, failureDetail: nil, summaryID: nil)
            try store.save(summaryRun: run)
            do {
                var results: [ProviderGenerationResult] = []
                for packet in compilation.chunks {
                    results.append(
                        try await RegisteredProviderInvocation.generate(
                            provider: generator, providerID: readyProvider,
                            packet: packet, recipe: nil,
                            purpose: "summary:\(runID.rawValue)", store: store,
                            allowanceReader: allowanceReader,
                            now: { now }))
                }
                content = merge(results.map(\.summary))
                usage = merge(results.map(\.usage))
                provider = readyProvider
                model = results.compactMap(\.effectiveModel).last ?? generator.model
            } catch {
                content = localContent(compilation: compilation, children: children)
                failureClass = classify(error).0
                failureDetail = classify(error).1
                provider = nil
                model = nil
            }
        } else {
            content = localContent(compilation: compilation, children: children)
            provider = nil
            model = nil
            if readyProvider != nil {
                failureClass = .budget
                failureDetail = "LLM summary budget paused: \(budgetDecision?.reason ?? "budget unavailable")"
            } else if preferredMode != .localOnly {
                failureClass = .unavailable
                failureDetail = "No selected summary provider was available for automatic generation"
            }
        }
        content = ensuringProjectCoverage(
            content, compilation: compilation, children: children)

        let previous = try store.summaries(
            overlapping: compilation.range, kinds: [kind], limit: 500
        )
        .filter {
            $0.periodStart == compilation.range.start
                && $0.periodEnd == compilation.range.end
        }
        .max { $0.revision < $1.revision }
        let revision = (previous?.revision ?? 0) + 1
        let summaryID = SummaryID(
            StableHash.sha256(
                "summary:\(kind.rawValue):\(compilation.range.start.timeIntervalSince1970):"
                    + "\(compilation.range.end.timeIntervalSince1970):\(compilation.sourceFingerprint):\(revision)"))
        let summary = WorkSummary(
            id: summaryID, kind: kind, periodStart: compilation.range.start,
            periodEnd: compilation.range.end, generatedAt: now, state: compilation.state,
            content: sanitized(content), statistics: compilation.statistics,
            evidenceIDs: compilation.evidenceIDs,
            childSummaryIDs: children.map(\.id),
            generationSource: SummaryGenerationSource(provider: provider),
            provider: provider, model: model,
            generatorVersion: Self.generatorVersion,
            promptVersion: Self.promptVersion, schemaVersion: Self.schemaVersion,
            sourceFingerprint: compilation.sourceFingerprint,
            coverage: compilation.coverage, revision: revision,
            revisesSummaryID: previous?.id)
        try store.save(summary: summary)
        let finalState: ReportRunState = failureClass == nil ? .succeeded : .fallback
        run = replacing(
            run, requestedProvider: requestedProvider, requestedModel: run.requestedModel,
            effectiveProvider: invokedProvider ?? provider, effectiveModel: invokedModel ?? model,
            usage: usage, startedAt: startedAt, finishedAt: now, state: finalState,
            failureClass: failureClass, failureDetail: failureDetail,
            summaryID: summary.id)
        try store.save(summaryRun: run)
        return summary
    }

    private func parentCompilation(
        range: DateInterval,
        children: [WorkSummary],
        sourceFingerprint: String,
        calendar: Calendar
    ) -> SummaryCompilation {
        let evidenceIDs = Array(Set(children.flatMap(\.evidenceIDs))).sorted { $0.rawValue < $1.rawValue }
        let statistics = SummaryStatistics(
            activeHours: Set(
                children.flatMap { child in
                    stride(
                        from: child.periodStart.timeIntervalSince1970,
                        to: child.periodEnd.timeIntervalSince1970,
                        by: 3_600
                    ).map { Int($0 / 3_600) }
                }
            ).count,
            llmTurns: children.reduce(0) { $0 + $1.statistics.llmTurns },
            conversationMessages: children.reduce(0) { $0 + $1.statistics.conversationMessages },
            commits: children.reduce(0) { $0 + $1.statistics.commits },
            additions: children.reduce(0) { $0 + $1.statistics.additions },
            deletions: children.reduce(0) { $0 + $1.statistics.deletions },
            filesChanged: children.reduce(0) { $0 + $1.statistics.filesChanged },
            repositoryIDs: Array(Set(children.flatMap { $0.statistics.repositoryIDs }))
                .sorted { $0.rawValue < $1.rawValue },
            evidenceCount: evidenceIDs.count)
        let state = aggregateState(children.map(\.state))
        let activity = ActivitySnapshot(
            rangeStart: range.start, rangeEnd: range.end,
            activeHours: statistics.activeHours, llmTurns: statistics.llmTurns,
            conversationMessages: statistics.conversationMessages, commits: statistics.commits,
            additions: statistics.additions, deletions: statistics.deletions,
            filesChanged: statistics.filesChanged,
            repositoryIDs: statistics.repositoryIDs, evidenceCount: evidenceIDs.count,
            firstEvidenceAt: children.first?.periodStart,
            lastEvidenceAt: children.last?.periodEnd)
        let digests = children.enumerated().map { offset, child in
            return ReportPeriodDigest(
                alias: "s\(offset + 1)", summaryID: child.id,
                periodStart: child.periodStart,
                periodEnd: child.periodEnd, state: child.state,
                summary: parentDigestText(child),
                provider: child.provider?.rawValue, evidenceIDs: [],
                projects: child.content.projects)
        }
        let chunks = parentPackets(
            range: range, state: state, activity: activity, digests: digests)
        let coverage = SummaryCoverage(
            eligibleEventCount: children.reduce(0) { $0 + $1.coverage.eligibleEventCount },
            coveredEventCount: children.reduce(0) { $0 + $1.coverage.coveredEventCount },
            truncatedAssistantCount: children.reduce(0) { $0 + $1.coverage.truncatedAssistantCount },
            chunkCount: max(chunks.count, 1),
            isKnown: children.allSatisfy { $0.coverage.isKnown })
        _ = calendar
        return SummaryCompilation(
            range: range, state: state, statistics: statistics, chunks: chunks,
            evidenceIDs: evidenceIDs, sourceFingerprint: sourceFingerprint,
            coverage: coverage)
    }

    private func parentPackets(
        range: DateInterval,
        state: ReportPeriodState,
        activity: ActivitySnapshot,
        digests: [ReportPeriodDigest]
    ) -> [ReportEvidencePacket] {
        var groups: [[ReportPeriodDigest]] = []
        var current: [ReportPeriodDigest] = []
        for digest in digests {
            let candidate = parentPacket(
                range: range, state: state, activity: activity,
                digests: current + [digest], total: digests.count)
            if candidate.serializedByteCount <= 20 * 1_024 || current.isEmpty {
                current.append(digest)
            } else {
                groups.append(current)
                current = [digest]
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.map {
            parentPacket(
                range: range, state: state, activity: activity,
                digests: $0, total: digests.count)
        }
    }

    private func parentPacket(
        range: DateInterval,
        state: ReportPeriodState,
        activity: ActivitySnapshot,
        digests: [ReportPeriodDigest],
        total: Int
    ) -> ReportEvidencePacket {
        ReportEvidencePacket(
            schemaVersion: 2, periodStart: range.start, periodEnd: range.end,
            state: state, activity: activity, events: [], priorSummaries: digests,
            selection: ReportPacketSelection(
                compilerVersion: SummaryCoverageCompiler.version,
                totalEventCount: total, selectedEventCount: digests.count,
                omittedEventCount: 0, omittedByKind: [:],
                activeContextCount: digests.count, representedContextCount: digests.count,
                omittedContextCount: 0, totalPriorSummaryCount: total,
                selectedPriorSummaryCount: digests.count,
                serializedByteLimit: 20 * 1_024))
    }

    private func localContent(
        compilation: SummaryCompilation,
        children: [WorkSummary]
    ) -> SummaryContent {
        if !children.isEmpty {
            let sections = mergeProjectSections(
                children.flatMap { $0.content.projectSections }
            ).map(normalizedProjectSection)
            let projects = unique(
                sections.map(\.project) + children.flatMap { $0.content.projects })
            let status = localStatusSentence(for: compilation.state)
            let narrative =
                projects.isEmpty
                ? status
                : "\(status) Work covered \(projects.joined(separator: ", "))."
            let compactDetails = sections.prefix(3).compactMap { section -> String? in
                let detail =
                    section.openWork.last
                    ?? section.outcomes.last
                    ?? section.intents.last
                    ?? (section.narrative.isEmpty ? nil : section.narrative)
                return detail.map { "\(section.project): \(withoutTerminalPunctuation($0))" }
            }
            let compactLead = compactDetails.joined(separator: "; ")
            let compactNarrative = concise(
                compactLead.isEmpty ? status : "\(compactLead). \(status)",
                limit: 480)
            return SummaryContent(
                narrative: narrative,
                compactNarrative: compactNarrative,
                projects: projects,
                projectSections: sections,
                intents: Array(unique(children.flatMap { $0.content.intents }).suffix(24)),
                outcomes: Array(unique(children.flatMap { $0.content.outcomes }).suffix(32)),
                openWork: Array(unique(children.flatMap { $0.content.openWork }).suffix(24)),
                blockers: Array(unique(children.flatMap { $0.content.blockers }).suffix(12)),
                topics: unique(children.flatMap { $0.content.topics }))
        }
        let events = compilation.chunks.flatMap(\.events)
        let projects = unique(events.compactMap(\.repositoryName))
        let intents = unique(
            events.compactMap {
                isIntent($0) ? $0.messageExcerpt.map { concise($0, limit: 320) } : nil
            })
        let outcomes = unique(
            events.compactMap { event in
                event.kind == .gitCommitObserved
                    ? event.payload["message"].map { concise($0, limit: 240) } : nil
            })
        let dirtyProjects = projects.filter { project in
            events.last(where: {
                $0.repositoryName == project && $0.kind == .gitWorkingTreeChanged
            }).map { $0.payload["clean"] != "true" } ?? false
        }
        let openWork =
            compilation.state == .inProgress
            ? unique(
                Array(intents.suffix(1))
                    + dirtyProjects.map { "Uncommitted changes remained in progress in \($0)." })
            : []
        let blockers =
            compilation.state == .investigating
            ? ["A failed build or test remained under investigation."] : []
        let narrative: String
        if let intent = intents.last, let outcome = outcomes.last {
            narrative = "Requested “\(intent)”. Latest concrete outcome: \(outcome)."
        } else if let outcome = outcomes.last {
            narrative = "Worked on \(outcome)."
        } else if let intent = intents.last {
            narrative = "Worked on “\(intent)”. No later completion evidence was recorded."
        } else {
            narrative = ReportGenerator().deterministicSummary(compilation.chunks.first!)
        }
        let sections = projects.map { project in
            let projectEvents = events.filter { $0.repositoryName == project }
            let projectIntents = unique(
                projectEvents.compactMap {
                    isIntent($0) ? $0.messageExcerpt.map { concise($0, limit: 320) } : nil
                })
            let projectOutcomes = unique(
                projectEvents.compactMap { event in
                    event.kind == .gitCommitObserved
                        ? event.payload["message"].map { concise($0, limit: 240) } : nil
                })
            let hasDirtyTree =
                projectEvents.last(where: {
                    $0.kind == .gitWorkingTreeChanged
                }).map { $0.payload["clean"] != "true" } ?? false
            let projectNarrative =
                (projectOutcomes.last ?? projectIntents.last)
                ?? (hasDirtyTree
                    ? "Uncommitted changes remained in progress."
                    : "Development activity was recorded.")
            let projectOpenWork =
                compilation.state == .inProgress
                ? unique(
                    Array(projectIntents.suffix(1))
                        + (hasDirtyTree ? ["Uncommitted changes remained in progress."] : []))
                : []
            return SummaryProjectSection(
                project: project, narrative: projectNarrative,
                intents: projectIntents, outcomes: projectOutcomes,
                openWork: projectOpenWork,
                blockers: blockers)
        }
        return SummaryContent(
            narrative: narrative, compactNarrative: concise(narrative, limit: 480),
            projects: projects, projectSections: sections, intents: intents,
            outcomes: outcomes, openWork: openWork, blockers: blockers,
            topics: projects)
    }

    private func merge(_ summaries: [ProviderSummary]) -> SummaryContent {
        let compact = unique(summaries.map(\.compactSummary))
        return SummaryContent(
            narrative: summaries.map(\.summary).joined(separator: " "),
            compactNarrative: concise(
                compact.suffix(2).joined(separator: " "), limit: 480),
            projects: unique(summaries.flatMap(\.projects)),
            projectSections: mergeProjectSections(summaries.flatMap(\.projectSummaries)),
            intents: unique(summaries.flatMap(\.intents)),
            outcomes: unique(summaries.flatMap(\.outcomes)),
            openWork: unique(summaries.flatMap(\.openWork)),
            blockers: unique(summaries.flatMap(\.blockers)),
            topics: unique(summaries.flatMap(\.topics)))
    }

    private func merge(_ values: [ProviderUsage]) -> ProviderUsage {
        func total(_ keyPath: KeyPath<ProviderUsage, Int?>) -> Int? {
            let values = values.compactMap { $0[keyPath: keyPath] }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        let knownCosts = values.compactMap(\.cost)
        let cost = knownCosts.count == values.count ? knownCosts.reduce(0, +) : nil
        return ProviderUsage(
            inputTokens: total(\.inputTokens), cachedInputTokens: total(\.cachedInputTokens),
            outputTokens: total(\.outputTokens), reasoningTokens: total(\.reasoningTokens),
            cost: cost, currency: values.compactMap(\.currency).first,
            costKind: cost == nil ? .unknown : values.first?.costKind ?? .unknown,
            billingContext: unique(values.compactMap(\.billingContext)).joined(separator: "; "))
    }

    private func aggregateState(_ states: [ReportPeriodState]) -> ReportPeriodState {
        if states.contains(.investigating) { return .investigating }
        if states.contains(.inProgress) { return .inProgress }
        if states.contains(.waiting) { return .waiting }
        if states.contains(.completed) { return .completed }
        if states.contains(.observed) { return .observed }
        return .noActivity
    }

    /// Provider structure is validated, but a model can still omit a project.
    /// Preserve its useful prose while filling any missing project section from
    /// deterministic evidence so multi-project work never collapses together.
    private func ensuringProjectCoverage(
        _ content: SummaryContent,
        compilation: SummaryCompilation,
        children: [WorkSummary]
    ) -> SummaryContent {
        let expectedProjects = unique(
            compilation.chunks.flatMap { packet in
                packet.events.compactMap(\.repositoryName)
                    + packet.priorSummaries.flatMap(\.projects)
            } + children.flatMap { $0.content.projects })
        guard !expectedProjects.isEmpty else { return content }
        let deterministic = localContent(compilation: compilation, children: children)
        let supplied = Dictionary(
            content.projectSections.map { ($0.project.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })
        let fallback = Dictionary(
            deterministic.projectSections.map { ($0.project.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })
        let orderedProjects = unique(
            content.projectSections.map(\.project) + content.projects + expectedProjects)
        let sections = orderedProjects.map { project in
            supplied[project.lowercased()]
                ?? fallback[project.lowercased()]
                ?? SummaryProjectSection(
                    project: project,
                    narrative: "Development activity was recorded in this period.")
        }
        return SummaryContent(
            narrative: content.narrative,
            compactNarrative: content.compactNarrative,
            projects: orderedProjects,
            projectSections: sections,
            intents: content.intents, outcomes: content.outcomes,
            openWork: content.openWork, blockers: content.blockers,
            topics: content.topics)
    }

    private func reusableSummary(
        store: LedgerStore,
        settings: TrackifySettings,
        kind: WorkSummaryKind,
        compilation: SummaryCompilation,
        preferredMode: ProviderSelectionMode,
        readyProvider: SummaryProviderID?,
        recoveryBudgetStatus: GenerationBudgetStatus?,
        now: Date,
        calendar: Calendar
    ) throws -> WorkSummary? {
        let samePeriod = try store.summaries(
            overlapping: compilation.range, kinds: [kind], includeSuperseded: true,
            limit: 500
        ).filter {
            $0.periodStart == compilation.range.start
                && $0.periodEnd == compilation.range.end
                && $0.generatorVersion == Self.generatorVersion
                && $0.promptVersion == Self.promptVersion
                && $0.schemaVersion == Self.schemaVersion
        }

        // A completed hour gets at most one successful provider-backed summary.
        // Late evidence remains available to reports directly, but cannot silently
        // downgrade or repeatedly re-spend the finalized hourly summary.
        if kind == .segment,
            let finalized = samePeriod.filter({ $0.provider != nil })
                .max(by: { $0.revision < $1.revision })
        {
            return finalized
        }

        guard
            let existing = samePeriod.filter({
                $0.sourceFingerprint == compilation.sourceFingerprint
            }).max(by: { $0.revision < $1.revision })
        else { return nil }

        guard preferredMode != .localOnly, let readyProvider else { return existing }
        if existing.provider == readyProvider { return existing }
        if preferredMode == .automatic, existing.provider != nil { return existing }

        guard
            let run = try store.summaryRuns(limit: 1_000).first(where: {
                $0.summaryID == existing.id
            })
        else { return nil }
        if run.failureClass == .budget {
            guard let recoveryBudgetStatus else { return existing }
            let provider = providerFactory(
                readyProvider,
                TimeInterval(settings.generationBudgets.processDeadlineSeconds))
            let recovery = try budgetController.decision(
                request: budgetRequest(
                    kind: kind, compilation: compilation,
                    provider: readyProvider, model: provider.model),
                budgets: settings.generationBudgets, store: store, now: now,
                calendar: calendar, status: recoveryBudgetStatus)
            return recovery.allowed ? nil : existing
        }
        if run.effectiveProvider == readyProvider,
            now.timeIntervalSince(run.finishedAt ?? run.queuedAt) < 30 * 60
        {
            return existing
        }
        return nil
    }

    private func budgetRequest(
        kind: WorkSummaryKind,
        compilation: SummaryCompilation,
        provider: SummaryProviderID,
        model: String?
    ) -> GenerationBudgetRequest {
        let overhead = GenerationBudgets.conservativeProviderOverheadTokens
        let maximumPacketTokens =
            compilation.chunks.map { $0.estimatedInputTokens + overhead }.max() ?? overhead
        return GenerationBudgetRequest(
            provider: provider, model: model,
            calls: compilation.chunks.count,
            maximumInputBytes: compilation.chunks.map(\.serializedByteCount).max() ?? 0,
            maximumEstimatedInputTokens: maximumPacketTokens,
            totalEstimatedInputTokens: compilation.estimatedInputTokens
                + compilation.chunks.count * overhead)
    }

    private func isIntent(_ event: ReportEventDigest) -> Bool {
        guard event.messageExcerpt != nil else { return false }
        guard let semantic = event.messageSemanticKind else {
            return event.messageRole == .user
        }
        guard semantic == .intent || semantic == .steering else { return false }
        guard let origin = event.messageOrigin else { return event.messageRole == .user }
        return origin == .human || origin == .agent
    }

    private func activeHourlyIntervals(
        store: LedgerStore,
        in day: DateInterval,
        cutoff: Date,
        calendar: Calendar
    ) throws -> [DateInterval] {
        let events = try store.events(
            from: day.start, through: cutoff, kinds: CoreEvidence.kinds)
        guard !events.isEmpty else { return [] }
        return SummaryCadence.completedHours(
            in: day, through: cutoff, calendar: calendar
        ).filter { interval in
            events.contains { event in
                event.occurredAt >= interval.start && event.occurredAt < interval.end
                    && CoreEvidence.includes(event)
            }
        }
    }

    private func sanitized(_ content: SummaryContent) -> SummaryContent {
        SummaryContent(
            narrative: SecretRedactor.redact(content.narrative),
            compactNarrative: SecretRedactor.redact(content.compactNarrative),
            projects: content.projects.map { SecretRedactor.redact($0) },
            projectSections: content.projectSections.map {
                SummaryProjectSection(
                    project: SecretRedactor.redact($0.project),
                    narrative: SecretRedactor.redact($0.narrative),
                    intents: $0.intents.map { SecretRedactor.redact($0) },
                    outcomes: $0.outcomes.map { SecretRedactor.redact($0) },
                    openWork: $0.openWork.map { SecretRedactor.redact($0) },
                    blockers: $0.blockers.map { SecretRedactor.redact($0) })
            },
            intents: content.intents.map { SecretRedactor.redact($0) },
            outcomes: content.outcomes.map { SecretRedactor.redact($0) },
            openWork: content.openWork.map { SecretRedactor.redact($0) },
            blockers: content.blockers.map { SecretRedactor.redact($0) },
            topics: content.topics.map { SecretRedactor.redact($0) })
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func mergeProjectSections(
        _ sections: [SummaryProjectSection]
    ) -> [SummaryProjectSection] {
        let grouped = Dictionary(grouping: sections, by: \.project)
        return grouped.keys.sorted().map { project in
            let values = grouped[project] ?? []
            return SummaryProjectSection(
                project: project,
                narrative: values.map(\.narrative).filter { !$0.isEmpty }.joined(separator: " "),
                intents: unique(values.flatMap(\.intents)),
                outcomes: unique(values.flatMap(\.outcomes)),
                openWork: unique(values.flatMap(\.openWork)),
                blockers: unique(values.flatMap(\.blockers)))
        }
    }

    private func normalizedProjectSection(
        _ section: SummaryProjectSection
    ) -> SummaryProjectSection {
        var details: [String] = []
        if !section.intents.isEmpty {
            details.append("Focus: \(section.intents.suffix(3).joined(separator: "; "))")
        }
        if !section.outcomes.isEmpty {
            details.append("Outcomes: \(section.outcomes.suffix(4).joined(separator: "; "))")
        }
        if !section.openWork.isEmpty {
            details.append("Open work: \(section.openWork.suffix(3).joined(separator: "; "))")
        }
        if !section.blockers.isEmpty {
            details.append("Blockers: \(section.blockers.suffix(3).joined(separator: "; "))")
        }
        let narrative =
            details.isEmpty
            ? section.narrative
            : details.map { withoutTerminalPunctuation($0) + "." }.joined(separator: " ")
        return SummaryProjectSection(
            project: section.project,
            narrative: concise(narrative, limit: 1_600),
            intents: Array(section.intents.suffix(8)),
            outcomes: Array(section.outcomes.suffix(12)),
            openWork: Array(section.openWork.suffix(8)),
            blockers: Array(section.blockers.suffix(8)))
    }

    /// Parent generations receive one bounded signal for every project in
    /// every child. This preserves the whole time line without duplicating the
    /// leaf's full provenance arrays or allowing a three-project menu preview
    /// to hide a fourth project from a daily summary.
    private func parentDigestText(_ child: WorkSummary) -> String {
        let grouped = child.content.projectSections.map { section in
            "\(section.project): \(concise(section.narrative, limit: 360))"
        }
        if !grouped.isEmpty { return grouped.joined(separator: " | ") }
        let fallback =
            child.content.compactNarrative.isEmpty
            ? child.content.narrative : child.content.compactNarrative
        return concise(fallback, limit: 480)
    }

    private func localStatusSentence(for state: ReportPeriodState) -> String {
        switch state {
        case .completed:
            return "The recorded work reached a completed state during this period."
        case .inProgress:
            return "Work remained in progress at the end of this period."
        case .investigating:
            return "Work remained under investigation at the end of this period."
        case .waiting:
            return "Work was waiting on an external dependency at the end of this period."
        case .observed:
            return "Development activity was recorded without evidence that the work was complete."
        case .noActivity:
            return "No development activity was recorded in this period."
        }
    }

    private func withoutTerminalPunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ".!?;: "))
    }

    private func concise(_ value: String, limit: Int) -> String {
        let normalized = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return normalized.count <= limit ? normalized : String(normalized.prefix(limit - 1)) + "…"
    }

    private func classify(_ error: Error) -> (GenerationFailureClass, String) {
        if let provider = error as? SummaryProviderError {
            switch provider {
            case .executableNotFound: return (.unavailable, provider.localizedDescription)
            case .authenticationFailed: return (.authentication, provider.localizedDescription)
            case .rateLimited: return (.rateLimited, provider.localizedDescription)
            case .modelUnavailable: return (.unavailable, provider.localizedDescription)
            case .invalidResponse, .packetTooLarge: return (.invalidResponse, provider.localizedDescription)
            case .processFailed: return (.process, provider.localizedDescription)
            }
        }
        if error is CancellationError { return (.cancelled, "Cancelled") }
        return (.unknown, String(describing: error))
    }

    private func replacing(
        _ run: SummaryRun,
        requestedProvider: SummaryProviderID?, requestedModel: String?,
        effectiveProvider: SummaryProviderID?, effectiveModel: String?,
        usage: ProviderUsage, startedAt: Date?, finishedAt: Date?,
        state: ReportRunState, failureClass: GenerationFailureClass?,
        failureDetail: String?, summaryID: SummaryID?
    ) -> SummaryRun {
        SummaryRun(
            id: run.id, kind: run.kind, periodStart: run.periodStart,
            periodEnd: run.periodEnd, selectionMode: run.selectionMode,
            requestedProvider: requestedProvider, requestedModel: requestedModel,
            effectiveProvider: effectiveProvider, effectiveModel: effectiveModel,
            sourceFingerprint: run.sourceFingerprint, inputBytes: run.inputBytes,
            estimatedInputTokens: run.estimatedInputTokens, usage: usage,
            queuedAt: run.queuedAt, startedAt: startedAt, finishedAt: finishedAt,
            state: state, failureClass: failureClass, failureDetail: failureDetail,
            summaryID: summaryID)
    }
}
