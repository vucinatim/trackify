import Foundation
import TrackifyDomain
import TrackifyStore

public struct EvidenceRebuildCoverage: Codable, Equatable, Sendable {
    public let calendarDays: Int
    public let start: Date
    public let cutoff: Date

    public init(calendarDays: Int, start: Date, cutoff: Date) {
        self.calendarDays = calendarDays
        self.start = start
        self.cutoff = cutoff
    }

    public var interval: DateInterval {
        DateInterval(start: start, end: cutoff)
    }

    public static func recentCalendarDays(
        _ calendarDays: Int,
        cutoff: Date,
        calendar: Calendar = .current
    ) throws -> EvidenceRebuildCoverage {
        guard (1...366).contains(calendarDays) else {
            throw EvidenceRebuildError.invalidCalendarDays(calendarDays)
        }
        guard
            let today = calendar.dateInterval(of: .day, for: cutoff),
            let start = calendar.date(
                byAdding: .day,
                value: -(calendarDays - 1),
                to: today.start)
        else {
            throw EvidenceRebuildError.coverageCalculationFailed
        }
        return EvidenceRebuildCoverage(
            calendarDays: calendarDays,
            start: start,
            cutoff: cutoff)
    }
}

public struct EvidenceRebuildAudit: Codable, Equatable, Sendable {
    public let shadowLedgerPath: String
    public let coverage: EvidenceRebuildCoverage
    public let collection: LocalCollectionResult
    public let verificationCollection: LocalCollectionResult
    public let canonical: CanonicalLedgerAudit
    public let quality: EvidenceQualitySnapshot
    public let storageIntegrity: String
    public let incrementalPassChangedCanonicalHistory: Bool
    public let summariesGenerated: Int
    public let activated: Bool
    public let replacedLedgerPath: String?

    public var isValid: Bool {
        collection.issues.isEmpty
            && verificationCollection.issues.isEmpty
            && storageIntegrity == "ok"
            && quality.state == .healthy
            && !incrementalPassChangedCanonicalHistory
    }
}

public struct EvidenceActivationAudit: Codable, Equatable, Sendable {
    public let activatedLedgerPath: String
    public let replacedLedgerPath: String?
    public let coverage: EvidenceLedgerCoverage
    public let canonical: CanonicalLedgerAudit
    public let storageIntegrity: String
    public let quality: EvidenceQualitySnapshot
}

public enum EvidenceRebuildError: Error, LocalizedError {
    case invalidCalendarDays(Int)
    case coverageCalculationFailed
    case validationFailed([String])
    case replacementFailed(String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidCalendarDays(let days):
            "Evidence rebuild days must be between 1 and 366; received \(days)."
        case .coverageCalculationFailed:
            "The local calendar coverage interval could not be calculated."
        case .validationFailed(let reasons):
            "Shadow evidence rebuild failed validation: \(reasons.joined(separator: "; "))"
        case .replacementFailed(let detail):
            "Validated ledger could not be activated: \(detail)"
        case .insufficientDiskSpace(let required, let available):
            "Evidence rebuild requires at least \(required) free bytes; only \(available) bytes are available."
        }
    }
}

private struct RebuildConfiguration {
    let settings: TrackifySettings
    let roots: [DiscoveryRoot]
    let templates: [ReportTemplate]
    let schedules: [ReportSchedule]
    let destinations: [Destination]
}

public struct EvidenceLedgerRebuilder: Sendable {
    private let clock: any WallClock

    public init(clock: any WallClock = SystemWallClock()) {
        self.clock = clock
    }

    public func rebuild(
        paths: TrackifyPaths,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeCodex: Bool = true,
        includeClaude: Bool = true,
        replace: Bool = false,
        expectedFingerprint: String? = nil,
        expectedEvidenceFingerprint: String? = nil,
        calendarDays: Int = 7,
        calendar: Calendar = .current
    ) async throws -> EvidenceRebuildAudit {
        let now = clock.now()
        let coverage = try EvidenceRebuildCoverage.recentCalendarDays(
            calendarDays, cutoff: now, calendar: calendar)
        try requireDiskHeadroom(paths: paths)
        let configuration = try readConfiguration(paths: paths)
        let shadowRoot = paths.dataRoot.appending(
            path: "Rebuilds/\(ISO8601DateFormatter().string(from: now))-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory)
        let shadowPaths = TrackifyPaths(dataRoot: shadowRoot)
        let shadowStore = try LedgerStore(
            databaseURL: shadowPaths.ledgerURL, durability: .disposableShadow)
        try restore(configuration: configuration, store: shadowStore, now: now)
        try SettingsStore(fileURL: shadowPaths.settingsURL).save(configuration.settings)

        let gitRoots = configuration.roots.filter(\.isEnabled).map {
            GitCollectionRoot(
                path: URL(filePath: $0.canonicalPath),
                discoveryRootID: $0.id,
                excludedPaths: Set($0.excludedPaths))
        }
        let coordinator = LocalCollectionCoordinator(clock: clock)
        let collection = try await coordinator.collect(
            store: shadowStore, gitRoots: gitRoots,
            includeCodex: includeCodex, includeClaude: includeClaude,
            range: coverage.interval,
            hookInboxURL: FileManager.default.fileExists(atPath: paths.hookInboxURL.path)
                ? paths.hookInboxURL : nil,
            homeDirectory: homeDirectory)
        let firstAudit = try shadowStore.canonicalAudit()

        // The exact same full-source use case must become a no-op once cursors
        // are current. This catches replay and unstable identity immediately.
        let verificationCollection = try await coordinator.collect(
            store: shadowStore, gitRoots: gitRoots,
            includeCodex: includeCodex, includeClaude: includeClaude,
            range: coverage.interval,
            hookInboxURL: FileManager.default.fileExists(atPath: paths.hookInboxURL.path)
                ? paths.hookInboxURL : nil,
            homeDirectory: homeDirectory)
        let secondAudit = try shadowStore.canonicalAudit()
        let changed = firstAudit != secondAudit
        let cursorSeedReads = try seedForwardConversationCursors(
            store: shadowStore,
            homeDirectory: homeDirectory,
            range: coverage.interval,
            includeCodex: includeCodex,
            includeClaude: includeClaude,
            now: now)
        let persistedCoverage = EvidenceLedgerCoverage(
            calendarDays: coverage.calendarDays,
            start: coverage.start,
            cutoff: coverage.cutoff,
            recordedAt: now,
            canonicalFingerprint: secondAudit.canonicalFingerprint,
            sourceReads: (collection.sourceReads + cursorSeedReads)
                .sorted { $0.sourceKey < $1.sourceKey })
        try shadowStore.replaceEvidenceCoverage(persistedCoverage)
        let coverageViolations = try shadowStore.evidenceCoverageViolationCount(
            in: coverage.interval)
        try shadowStore.rebuildCanonicalMessageSearchIndex()
        let quality = try shadowStore.refreshEvidenceQualityAudit(at: now)
        let storage = try shadowStore.health()

        var summarySettings = configuration.settings
        summarySettings.providerSelection = .localOnly
        summarySettings.automaticSummariesUseLLM = false
        let summaries: SummaryRefreshResult
        summaries = await SummaryCoordinator().refresh(
            store: shadowStore, settings: summarySettings, now: now,
            calendar: calendar, lookbackDays: calendarDays)

        var reasons = collection.issues.map { "\($0.sourceKey): \($0.message)" }
        reasons.append(
            contentsOf: verificationCollection.issues.map {
                "Verification \($0.sourceKey): \($0.message)"
            })
        if storage.integrity != "ok" { reasons.append("SQLite integrity is \(storage.integrity)") }
        if quality.state != .healthy {
            reasons.append(contentsOf: quality.issues.filter(\.affectsWorkMetrics).map(\.detail))
        }
        if changed { reasons.append("A second import changed canonical history") }
        if let expectedFingerprint,
            secondAudit.canonicalFingerprint != expectedFingerprint
        {
            reasons.append(
                "Canonical fingerprint \(secondAudit.canonicalFingerprint) does not match expected \(expectedFingerprint)"
            )
        }
        if let expectedEvidenceFingerprint,
            secondAudit.evidenceFingerprint != expectedEvidenceFingerprint
        {
            reasons.append(
                "Evidence fingerprint \(secondAudit.evidenceFingerprint) does not match expected \(expectedEvidenceFingerprint)"
            )
        }
        if coverageViolations > 0 {
            reasons.append(
                "\(coverageViolations) canonical conversation or commit records fall outside the requested coverage interval"
            )
        }
        if !summaries.issues.isEmpty {
            reasons.append(contentsOf: summaries.issues.map { "Summary: \($0)" })
        }
        guard reasons.isEmpty else { throw EvidenceRebuildError.validationFailed(reasons) }

        var replacedPath: String?
        if replace {
            try shadowStore.checkpoint()
            replacedPath = try activate(
                shadowStore: shadowStore, activePaths: paths, now: now)
        }
        return EvidenceRebuildAudit(
            shadowLedgerPath: shadowPaths.ledgerURL.path,
            coverage: coverage,
            collection: collection, verificationCollection: verificationCollection,
            canonical: secondAudit,
            quality: quality, storageIntegrity: storage.integrity,
            incrementalPassChangedCanonicalHistory: changed,
            summariesGenerated: summaries.generated.count,
            activated: replace, replacedLedgerPath: replacedPath)
    }

    public func activateValidatedShadow(
        shadowLedgerURL: URL,
        activePaths: TrackifyPaths,
        expectedFingerprint: String,
        expectedEvidenceFingerprint: String
    ) throws -> EvidenceActivationAudit {
        let shadowURL = shadowLedgerURL.standardizedFileURL
        let rebuildRoot =
            activePaths.dataRoot.appending(
                path: "Rebuilds", directoryHint: .isDirectory
            ).standardizedFileURL.path + "/"
        guard shadowURL.path.hasPrefix(rebuildRoot),
            shadowURL.lastPathComponent == "trackify.sqlite"
        else {
            throw EvidenceRebuildError.validationFailed(
                ["Only a Trackify-owned shadow ledger inside the active data root can be activated."])
        }
        let shadowStore = try LedgerStore(databaseURL: shadowURL)
        let storage = try shadowStore.health()
        let quality = try shadowStore.refreshEvidenceQualityAudit(at: clock.now())
        let canonical = try shadowStore.canonicalAudit()
        guard let coverage = try shadowStore.evidenceCoverage() else {
            throw EvidenceRebuildError.validationFailed(
                ["The shadow ledger has no verified coverage record."])
        }
        var reasons: [String] = []
        if storage.integrity != "ok" { reasons.append("SQLite integrity is \(storage.integrity)") }
        if quality.state != .healthy {
            reasons.append(contentsOf: quality.issues.filter(\.affectsWorkMetrics).map(\.detail))
        }
        if canonical.canonicalFingerprint != expectedFingerprint {
            reasons.append(
                "Canonical fingerprint \(canonical.canonicalFingerprint) does not match expected \(expectedFingerprint)"
            )
        }
        if canonical.evidenceFingerprint != expectedEvidenceFingerprint {
            reasons.append(
                "Evidence fingerprint \(canonical.evidenceFingerprint) does not match expected \(expectedEvidenceFingerprint)"
            )
        }
        guard reasons.isEmpty else { throw EvidenceRebuildError.validationFailed(reasons) }
        try shadowStore.checkpoint()
        let replaced = try activate(
            shadowStore: shadowStore, activePaths: activePaths, now: clock.now())
        return EvidenceActivationAudit(
            activatedLedgerPath: activePaths.ledgerURL.path,
            replacedLedgerPath: replaced,
            coverage: coverage,
            canonical: canonical,
            storageIntegrity: storage.integrity,
            quality: quality)
    }

    private func requireDiskHeadroom(paths: TrackifyPaths) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(
            forPath: paths.dataRoot.path)
        let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let activeSize =
            ((try? FileManager.default.attributesOfItem(
                atPath: paths.ledgerURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        // A rebuild needs a working shadow, its WAL, a verified export, and
        // room to retain the active ledger until activation succeeds.
        let required = max(Int64(4 * 1_024 * 1_024 * 1_024), activeSize * 4)
        guard available >= required else {
            throw EvidenceRebuildError.insufficientDiskSpace(
                requiredBytes: required, availableBytes: available)
        }
    }

    private func seedForwardConversationCursors(
        store: LedgerStore,
        homeDirectory: URL,
        range: DateInterval,
        includeCodex: Bool,
        includeClaude: Bool,
        now: Date
    ) throws -> [EvidenceSourceReadAudit] {
        var sources: [(ConversationProvider, URL)] = []
        if includeCodex {
            sources.append(contentsOf: [
                (.codex, homeDirectory.appending(path: ".codex/sessions")),
                (.codex, homeDirectory.appending(path: ".codex/archived_sessions")),
            ])
        }
        if includeClaude {
            sources.append(contentsOf: [
                (.claude, homeDirectory.appending(path: ".claude/projects")),
                (
                    .claudeDesktop,
                    homeDirectory.appending(
                        path: "Library/Application Support/Claude/local-agent-mode-sessions")
                ),
            ])
        }
        var audits: [EvidenceSourceReadAudit] = []
        for (provider, root) in sources where FileManager.default.fileExists(atPath: root.path) {
            let scoped = ConversationDirectorySource(
                provider: provider,
                root: root,
                cursorScope: LocalCollectionCoordinator.backfillCursorScope(range))
            let boundedCursor = try store.cursor(for: scoped.sourceKey)
            let seed = try scoped.makeForwardCursorSeed(from: boundedCursor)
            try store.setCursor(seed.cursor, for: seed.sourceKey, at: now)
            audits.append(seed.audit)
        }
        return audits
    }

    private func readConfiguration(paths: TrackifyPaths) throws -> RebuildConfiguration {
        let settings = try SettingsStore(fileURL: paths.settingsURL).load()
        guard FileManager.default.fileExists(atPath: paths.ledgerURL.path) else {
            return RebuildConfiguration(
                settings: settings, roots: [], templates: [], schedules: [], destinations: [])
        }
        let store = try LedgerStore(databaseURL: paths.ledgerURL)
        return RebuildConfiguration(
            settings: settings,
            roots: try store.discoveryRoots(),
            templates: try store.reportTemplates(),
            schedules: try store.reportSchedules(),
            destinations: try store.destinations())
    }

    private func restore(
        configuration: RebuildConfiguration,
        store: LedgerStore,
        now: Date
    ) throws {
        for root in configuration.roots { try store.upsert(discoveryRoot: root) }
        for template in configuration.templates {
            if template.recipe.isBuiltIn {
                try store.setRecipeEnabled(template.recipe.isEnabled, id: template.recipe.id)
                continue
            }
            let value = template.version
            _ = try store.createRecipeVersion(
                recipeID: template.recipe.id, name: template.recipe.name,
                purpose: value.purpose, audience: value.audience,
                cadence: value.cadence, repositoryIDs: value.repositoryIDs,
                groupNames: value.groupNames, customFocus: value.customFocus,
                tone: value.tone, outputFormat: value.outputFormat,
                maximumCharacters: value.maximumCharacters,
                privacyProfile: value.privacyProfile,
                providerModeOverride: value.providerModeOverride, now: now)
            try store.setRecipeEnabled(template.recipe.isEnabled, id: template.recipe.id)
        }
        for schedule in configuration.schedules {
            _ = try store.saveReportSchedule(
                id: schedule.id, draft: ReportScheduleDraft(schedule: schedule), now: now)
        }
        for destination in configuration.destinations {
            let safe = Destination(
                id: destination.id, kind: destination.kind, name: destination.name,
                privacyProfile: destination.privacyProfile,
                permission: destination.permission,
                configuration: destination.configuration.filter { key, _ in
                    let value = key.lowercased()
                    return !["secret", "token", "password", "credential", "api_key", "apikey"]
                        .contains(where: value.contains)
                },
                isEnabled: destination.isEnabled)
            try store.saveDestination(safe, now: now)
        }
    }

    private func activate(
        shadowStore: LedgerStore,
        activePaths: TrackifyPaths,
        now: Date
    ) throws -> String? {
        let fileManager = FileManager.default
        let activation = activePaths.dataRoot.appending(path: ".validated-rebuild.sqlite")
        if fileManager.fileExists(atPath: activation.path) { try fileManager.removeItem(at: activation) }
        try shadowStore.exportSnapshot(to: activation)
        let backup = activePaths.dataRoot.appending(
            path: "Backups/pre-goal4-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.lowercased()).sqlite")
        try fileManager.createDirectory(
            at: backup.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        do {
            if fileManager.fileExists(atPath: activePaths.ledgerURL.path) {
                let active = try LedgerStore(databaseURL: activePaths.ledgerURL)
                try active.checkpoint()
                try fileManager.moveItem(at: activePaths.ledgerURL, to: backup)
            }
            try fileManager.moveItem(at: activation, to: activePaths.ledgerURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: activePaths.ledgerURL.path)
            return fileManager.fileExists(atPath: backup.path) ? backup.path : nil
        } catch {
            if !fileManager.fileExists(atPath: activePaths.ledgerURL.path),
                fileManager.fileExists(atPath: backup.path)
            {
                try? fileManager.moveItem(at: backup, to: activePaths.ledgerURL)
            }
            throw EvidenceRebuildError.replacementFailed(error.localizedDescription)
        }
    }
}
