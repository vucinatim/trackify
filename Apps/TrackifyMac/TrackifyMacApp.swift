import AppKit
import SwiftUI

@main
struct TrackifyMacApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateController()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model, updates: updates, router: router)
        } label: {
            MenuBarLabel(
                model: model,
                systemImage: menuBarSystemImage,
                accessibilityLabel: menuBarAccessibilityLabel
            )
        }
        .menuBarExtraStyle(.window)

        mainWindow

            .commands { TrackifyCommands(router: router) }
    }

    private var mainWindow: some Scene {
        Window("Trackify", id: "main") {
            Group {
                MainWindow(model: model, updates: updates, router: router)
            }
            .preferredColorScheme(validationColorScheme)
            .frame(minWidth: 1_040, minHeight: 700)
            .background(ValidationWindowSizing())
            .onOpenURL { url in
                if url.scheme == "trackify", url.host == "uninstall", url.path == "/prepare" {
                    model.prepareForUninstall()
                } else {
                    updates.handle(url: url)
                }
            }
        }
        .defaultSize(width: validationDimension("TRACKIFY_UI_WIDTH") ?? 1_180, height: validationDimension("TRACKIFY_UI_HEIGHT") ?? 800)
    }

    private var validationColorScheme: ColorScheme? {
        guard model.isUIValidation else { return nil }
        switch ProcessInfo.processInfo.environment["TRACKIFY_UI_SCHEME"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func validationDimension(_ key: String) -> CGFloat? {
        guard model.isUIValidation,
            let value = ProcessInfo.processInfo.environment[key].flatMap(Double.init),
            value > 0
        else { return nil }
        return CGFloat(value)
    }

    private var menuBarSystemImage: String {
        if model.collectionPaused { return "pause.fill" }
        if model.degradedMessage != nil { return "exclamationmark.triangle.fill" }
        return model.hasEvidenceToday ? "chart.bar.fill" : "chart.bar"
    }

    private var menuBarAccessibilityLabel: String {
        let state: String
        if model.collectionPaused {
            state = "collection paused"
        } else if model.degradedMessage != nil {
            state = "collection degraded"
        } else if model.hasEvidenceToday {
            state = "evidence recorded today"
        } else {
            state = "no current activity"
        }
        return ["Trackify", model.menuBarEvidenceHours, model.menuBarPace, state]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct TrackifyCommands: Commands {
    @ObservedObject var router: AppRouter
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                router.selection = .settings
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async {
                    NSApp.windows.first(where: { $0.title == "Trackify" })?.makeKeyAndOrderFront(nil)
                }
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var selection: MainWindow.Section

    init() {
        selection =
            ProcessInfo.processInfo.environment["TRACKIFY_UI_SCREEN"]
            .flatMap(MainWindow.Section.init(rawValue:)) ?? .overview
    }
}

private struct ValidationWindowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSView) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TRACKIFY_UI_VALIDATION"] == "1",
            let width = environment["TRACKIFY_UI_WIDTH"].flatMap(Double.init),
            let height = environment["TRACKIFY_UI_HEIGHT"].flatMap(Double.init)
        else { return }
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setContentSize(NSSize(width: width, height: height))
            window.collectionBehavior.insert(.moveToActiveSpace)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let systemImage: String
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            if let evidenceHours = model.menuBarEvidenceHours {
                Text(evidenceHours)
                if let pace = model.menuBarPace, !model.collectionPaused { Text(pace) }
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .task {
            await model.start()
            guard model.isUIValidation else { return }
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
