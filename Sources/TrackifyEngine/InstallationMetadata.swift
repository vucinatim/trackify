import Foundation

public enum InstallationOrigin: String, Codable, CaseIterable, Sendable {
    case direct
    case homebrew
    case managed
    case development
}

public enum UpdateInstallAction: String, Codable, Sendable {
    case sparkle
    case homebrew
    case managed
    case disabled
}

public struct InstallationMetadata: Codable, Equatable, Sendable {
    public let origin: InstallationOrigin
    public let version: String
    public let build: String
    public let bundleIdentifier: String?
    public let sparkleConfigured: Bool

    public init(
        origin: InstallationOrigin,
        version: String,
        build: String,
        bundleIdentifier: String?,
        sparkleConfigured: Bool
    ) {
        self.origin = origin
        self.version = version
        self.build = build
        self.bundleIdentifier = bundleIdentifier
        self.sparkleConfigured = sparkleConfigured
    }

    public var updateAction: UpdateInstallAction {
        switch origin {
        case .direct: sparkleConfigured ? .sparkle : .disabled
        case .homebrew: .homebrew
        case .managed: .managed
        case .development: .disabled
        }
    }

    public static func parse(info: [String: Any]) -> Self {
        let rawOrigin = info["TrackifyInstallationOrigin"] as? String
        let origin = rawOrigin.flatMap(InstallationOrigin.init(rawValue:)) ?? .development
        let version = info["CFBundleShortVersionString"] as? String ?? "0.1.0-dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let bundleIdentifier = info["CFBundleIdentifier"] as? String
        let publicKey = info["SUPublicEDKey"] as? String
        let sparkleConfigured =
            bundleIdentifier == "com.zoulabs.trackify"
            && publicKey?.isEmpty == false
            && publicKey != "UNCONFIGURED"
        return Self(
            origin: origin,
            version: version,
            build: build,
            bundleIdentifier: bundleIdentifier,
            sparkleConfigured: sparkleConfigured
        )
    }

    public static func load(enclosing executableURL: URL) -> Self {
        let executable = executableURL.resolvingSymlinksInPath().standardizedFileURL
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let infoURL = contents.appending(path: "Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return Self(
                origin: .development,
                version: "0.1.0-dev",
                build: "0",
                bundleIdentifier: nil,
                sparkleConfigured: false
            )
        }
        return parse(info: info)
    }
}
