// A regular Dock app with an additional menu-bar recording shortcut.
import SwiftUI

extension Notification.Name {
    /// AppDelegate lives outside the scene graph, so the one view that is always
    /// instantiated (the status item label) opens the main window on its behalf.
    static let openSettings = Notification.Name("scribebot.openSettings")
    static let openMainWindow = Notification.Name("scribebot.openMainWindow")
}

enum WindowID: String {
    case transcript, library, onboarding
    var title: String {
        switch self {
        case .transcript: return "Live Transcript"
        case .library: return "Recordings"
        case .onboarding: return "Scribebot Setup"
        }
    }
    var size: NSSize {
        switch self {
        case .transcript: return NSSize(width: 620, height: 520)
        case .library: return NSSize(width: 820, height: 520)
        case .onboarding: return NSSize(width: 680, height: 700)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    let perms = Permissions()
    let library: Library
    let recorder: Recorder
    /// Models land beside the recordings, never inside the bundle: adding a
    /// file under Contents/Resources breaks the signature macOS just checked.
    /// The checkout's own models/ is searched too, so a development build does
    /// not offer to re-download what it already has.
    let models = ModelDownloads(
        directory: ModelCatalog.directory(under: Paths.support),
        alsoSearch: [Paths.root.appendingPathComponent("models")])
    lazy var callMonitor = CallMonitor(recorder: recorder, perms: perms)
    private init() {
        let l = Library()
        library = l
        recorder = Recorder(library: l)
    }
}

@MainActor
final class Windows {
    static let shared = Windows()
    private var open: [WindowID: NSWindow] = [:]

    func show(_ id: WindowID) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = open[id] { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: id.size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = id.title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: "1D1D1C") : NSColor(hex: "FFFFFF")
        }
        w.contentView = NSHostingView(rootView: content(id))
        w.center()
        open[id] = w
        w.makeKeyAndOrderFront(nil)
    }

    func close(_ id: WindowID) { open[id]?.close() }

    @ViewBuilder private func content(_ id: WindowID) -> some View {
        let s = AppState.shared
        switch id {
        case .transcript: TranscriptView(recorder: s.recorder)
        case .library: MeetingsView(library: s.library)
        case .onboarding:
            OnboardingView(perms: s.perms, models: s.models) {
                Windows.shared.close(.onboarding)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
        return true
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            AppState.shared.callMonitor.start()
            SettingsView.applyAppearance(UserDefaults.standard.string(forKey: "appearance") ?? "system")
            let env = ProcessInfo.processInfo.environment
            // ponytail: screenshot hook. The -AppleInterfaceStyle argument domain
            // is no longer honoured, and flipping the system theme to check ours
            // is a rude thing to do to whoever is using the Mac.
            if env["SCRIBEBOT_DARK"] == "1" { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if env["SCRIBEBOT_DEMO"] == "1" {
                AppState.shared.recorder.seedDemo()
                AppState.shared.library.seedDemo(MeetingIndex.shared)
            }
            let wanted = (env["SCRIBEBOT_OPEN"] ?? "").split(separator: ",").map(String.init)
            if wanted.isEmpty || wanted.contains("main") {
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
            } else {
                // Explicit preview hooks may request only a secondary window.
                mainWindow()?.close()
            }
            if wanted.isEmpty {
                if !UserDefaults.standard.bool(forKey: "didOnboard") {
                    Windows.shared.show(.onboarding)
                }
            } else {
                // ponytail: test hook so the UI can be screenshotted headlessly.
                for name in wanted {
                    if let id = WindowID(rawValue: name) { Windows.shared.show(id) }
                }
            }
        }
    }
}

@main
struct ScribebotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {

        MenuBarExtra {
            MenuBarView(recorder: state.recorder, perms: state.perms) {
                Windows.shared.show($0)
            }
        } label: {
            MenuBarLabel(recorder: state.recorder)
        }
        .menuBarExtraStyle(.window)

        // The main document window retains its size and position between launches.
        Window("Scribebot", id: "main") {
            MainWindowView(library: state.library, recorder: state.recorder, perms: state.perms)
        }
        .defaultSize(width: 1180, height: 720)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openMainWindow, object: nil)
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// The Window scene's NSWindow, once SwiftUI has made it.
@MainActor func mainWindow() -> NSWindow? {
    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
}
