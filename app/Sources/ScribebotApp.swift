// Menu-bar-only app (LSUIElement). The status item is a SwiftUI scene; the
// three real windows are AppKit-owned so that an agent-less app can still open
// one at launch and so each keeps its own size and position.
import SwiftUI

extension Notification.Name {
    /// AppDelegate lives outside the scene graph, so the one view that is always
    /// instantiated (the status item label) opens the main window on its behalf.
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
        case .onboarding: return NSSize(width: 620, height: 640)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    let perms = Permissions()
    let library: Library
    let recorder: Recorder
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
                ? NSColor(hex: "0F1413") : NSColor(hex: "F6F7F6")
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
            OnboardingView(perms: s.perms) {
                UserDefaults.standard.set(true, forKey: "didOnboard")
                Windows.shared.close(.onboarding)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
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
            if wanted.contains("main") {
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
            } else {
                // A Window scene would otherwise restore itself on every launch,
                // which is wrong for a menu-bar app: the window is opened on demand.
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

        // The real window. Dock-less like the rest of the app, but a proper
        // resizable document window with its own frame autosave.
        Window("Scribebot", id: "main") {
            MainWindowView(library: state.library, recorder: state.recorder, perms: state.perms)
        }
        .defaultSize(width: 1180, height: 720)
        .windowToolbarStyle(.unifiedCompact)
    }
}

/// The Window scene's NSWindow, once SwiftUI has made it.
@MainActor func mainWindow() -> NSWindow? {
    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
}
