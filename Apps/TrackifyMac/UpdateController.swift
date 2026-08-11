import Combine
import Sparkle
import TrackifyEngine
import TrackifyStore

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    let installation: InstallationMetadata
    private let controller: SPUStandardUpdaterController

    init() {
        installation = InstallationMetadata.parse(info: Bundle.main.infoDictionary ?? [:])
        let ownsUpdates = installation.updateAction == .sparkle
        controller = SPUStandardUpdaterController(
            startingUpdater: ownsUpdates,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        if ownsUpdates {
            if let paths = try? TrackifyPaths.default(),
                let settings = try? SettingsStore(fileURL: paths.settingsURL).load()
            {
                controller.updater.automaticallyChecksForUpdates = settings.automaticUpdateChecks
            }
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
        }
    }

    func checkForUpdates() {
        guard installation.updateAction == .sparkle else { return }
        controller.updater.checkForUpdates()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard installation.updateAction == .sparkle else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func handle(url: URL) {
        guard url.scheme == "trackify", url.host == "update" else { return }
        guard ["check", "install"].contains(url.pathComponents.last ?? "") else { return }
        checkForUpdates()
    }
}
