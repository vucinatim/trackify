import AppKit
import Foundation
import TrackifyDomain
import TrackifyStore

public enum ArtifactDeliveryError: Error, Equatable, LocalizedError {
    case privacyMismatch
    case permissionDenied
    case destinationDisabled
    case unsupportedDestination
    case fileExists(String)

    public var errorDescription: String? {
        switch self {
        case .privacyMismatch: "The artifact privacy profile is not eligible for this destination."
        case .permissionDenied: "The destination has not been approved."
        case .destinationDisabled: "The destination is disabled."
        case .unsupportedDestination: "This destination adapter is not available."
        case .fileExists(let path): "Refusing to overwrite a different file at \(path)."
        }
    }
}

public struct ArtifactExportEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let artifact: Artifact

    public init(artifact: Artifact) {
        schemaVersion = 1
        self.artifact = artifact
    }
}

public struct ArtifactRenderer: Sendable {
    public init() {}

    public func render(_ artifact: Artifact, as format: RecipeOutputFormat) throws -> Data {
        switch format {
        case .plainText:
            Data(SensitiveText.redact(artifact.content).utf8)
        case .markdown:
            Data(markdown(artifact).utf8)
        case .structuredJSON:
            try json(artifact)
        }
    }

    public func markdown(_ artifact: Artifact) -> String {
        let title = artifact.recipeID.rawValue.replacingOccurrences(of: "-", with: " ").capitalized
        return """
            # \(title)

            - Period: \(artifact.periodStart.formatted(.iso8601)) – \(artifact.periodEnd.formatted(.iso8601))
            - State: \(artifact.state.rawValue)
            - Privacy: \(artifact.privacyProfile.rawValue)
            - Revision: \(artifact.revision)

            \(SensitiveText.redact(artifact.content))
            """
    }

    public func json(_ artifact: Artifact) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(ArtifactExportEnvelope(artifact: artifact))
        data.append(0x0A)
        return data
    }
}

public struct ArtifactDeliveryService: Sendable {
    private let renderer: ArtifactRenderer

    public init(renderer: ArtifactRenderer = ArtifactRenderer()) {
        self.renderer = renderer
    }

    @discardableResult
    public func deliver(
        artifact: Artifact,
        destination: Destination,
        store: LedgerStore,
        now: Date = Date()
    ) throws -> DeliveryAttempt {
        guard destination.isEnabled else { throw ArtifactDeliveryError.destinationDisabled }
        guard destination.permission == .local || destination.permission == .approved else {
            throw ArtifactDeliveryError.permissionDenied
        }
        guard privacyRank(destination.privacyProfile) >= privacyRank(artifact.privacyProfile) else {
            throw ArtifactDeliveryError.privacyMismatch
        }
        let key = StableHash.sha256(
            "delivery:\(artifact.id.rawValue):\(destination.id.rawValue):\(destination.kind.rawValue)")
        let pending = DeliveryAttempt(
            id: DeliveryAttemptID(StableHash.sha256("delivery-attempt:\(key)")),
            artifactID: artifact.id, destinationID: destination.id,
            idempotencyKey: key, state: .pending, attemptedAt: now)
        let existing = try store.recordDelivery(pending)
        if existing.state == .delivered { return existing }
        do {
            let identifier = try perform(artifact: artifact, destination: destination)
            let completed = DeliveryAttempt(
                id: existing.id, artifactID: artifact.id, destinationID: destination.id,
                idempotencyKey: key, state: .delivered, attemptedAt: existing.attemptedAt,
                finishedAt: now, retryCount: existing.retryCount,
                externalIdentifier: identifier)
            try store.updateDelivery(completed)
            return completed
        } catch {
            let failed = DeliveryAttempt(
                id: existing.id, artifactID: artifact.id, destinationID: destination.id,
                idempotencyKey: key, state: .failed, attemptedAt: existing.attemptedAt,
                finishedAt: now, retryCount: existing.retryCount + 1,
                failureDetail: error.localizedDescription)
            try store.updateDelivery(failed)
            throw error
        }
    }

    private func perform(artifact: Artifact, destination: Destination) throws -> String? {
        switch destination.kind {
        case .clipboard:
            let string = String(decoding: try renderer.render(artifact, as: .plainText), as: UTF8.self)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(string, forType: .string) else {
                throw ArtifactDeliveryError.permissionDenied
            }
            return "macos-pasteboard"
        case .markdownFile, .jsonFile:
            guard let path = destination.configuration["path"] else {
                throw ArtifactDeliveryError.unsupportedDestination
            }
            let format: RecipeOutputFormat = destination.kind == .markdownFile ? .markdown : .structuredJSON
            let data = try renderer.render(artifact, as: format)
            let url = URL(filePath: path).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                if try Data(contentsOf: url) == data { return url.path }
                throw ArtifactDeliveryError.fileExists(url.path)
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic, .withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url.path
        case .mock:
            return destination.configuration["externalIdentifier"] ?? "mock-delivered"
        }
    }

    private func privacyRank(_ profile: PrivacyProfile) -> Int {
        switch profile {
        case .public: 0
        case .client: 1
        case .team: 2
        case .private: 3
        }
    }
}
