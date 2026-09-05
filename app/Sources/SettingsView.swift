import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", calendar = "Calendar", account = "Account"
    case billing = "Billing", ai = "AI", integrations = "Integrations"
    case storage = "Storage and data", backup = "Backup & Sync"
    case permissions = "Permissions", help = "Help"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .calendar: return "calendar"
        case .account: return "person.crop.circle"
        case .billing: return "creditcard"
        case .ai: return "cpu"
        case .integrations: return "puzzlepiece.extension"
        case .storage: return "internaldrive"
        case .backup: return "externaldrive.badge.icloud"
        case .permissions: return "lock.shield"
        case .help: return "questionmark.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var perms: Permissions
    var onBack: () -> Void
    @State var page: SettingsPage = .general
    @AppStorage("callPrompts") private var callPrompts = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("useCalendarTitles") private var useCalendarTitles = true

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: onBack) {
                    Label("Back to library", systemImage: "chevron.left")
                        .font(T.body(13, .medium)).padding(12)
                }.buttonStyle(.plain).foregroundStyle(P.ink2)

                Text("Settings").font(T.disp(22)).padding(.horizontal, 12).padding(.vertical, 18)
                ForEach(SettingsPage.allCases) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(T.body(15, page == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 12)
                            .background(page == item ? P.accentSoft : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(page == item ? P.ink : P.ink2)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            }.frame(width: 224).frame(maxHeight: .infinity).background(P.sidebar)
            Divider().overlay(P.rule)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label(page.rawValue, systemImage: page.icon).font(T.disp(26))
                    content
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(30)
            }
            .background(P.ground)
        }
        .foregroundStyle(P.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { perms.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            perms.refresh()
        }
        .onChange(of: appearance) { _, value in Self.applyAppearance(value) }
    }

    static func applyAppearance(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .general:
            section("Call recording prompts", "Show a prompt when a supported meeting app or browser uses the microphone. Microphone checks may also trigger it; calls without microphone activity may not. Recording starts only when you choose Transcribe.") {
                Toggle("Show call recording prompts", isOn: $callPrompts)
                Button("Preview call prompt") { AppState.shared.callMonitor.preview() }
                    .buttonStyle(FlatButton(filled: false))
            }
            section("Appearance", "Choose how Scribebot looks on this Mac.") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }.pickerStyle(.segmented)
            }
            section("Desktop app", "Scribebot opens in the Dock. The menu-bar shortcut keeps recording controls within reach.") {
                Text("Open Settings anytime with ⌘,").font(T.body(13)).foregroundStyle(P.ink2)
            }
        case .calendar:
            section("Meeting names", "Use your Mac’s calendar to name new recordings after the meeting. Calendar access is optional.") {
                Toggle("Use calendar meeting titles", isOn: $useCalendarTitles)
                permissionControl(.calendar)
            }
            note("People", "The People list currently uses an imported calendar index. Granting access enables meeting titles; it does not automatically rebuild that index.")
        case .account:
            note("No account required", "Scribebot works locally without signing in. Your recordings belong to this Mac and are not associated with an online account.")
        case .billing:
            note("Free and open source", "This version of Scribebot has no subscription, trial, payment details, or usage charges. There is no billing account to manage.")
        case .ai:
            note("Transcription", "Hebrew transcription runs locally using ivrit-ai large-v3-turbo. The glossary restores English technical terms inside Hebrew speech.")
            section("Summaries", "Summaries use a separate local Ollama installation with the gemma4:latest model. Scribebot does not upload the transcript to a cloud service.") {
                Link("Open Ollama", destination: URL(string: "https://ollama.com")!)
                    .buttonStyle(FlatButton(filled: false))
            }
        case .integrations:
            section("Calendar", "Connect through macOS to use meeting titles.") { permissionControl(.calendar) }
            note("Meeting apps", "System audio capture works independently of the meeting app. No meeting bot or account connection is required.")
            note("Other services", "Direct integrations with cloud storage, messaging, and task services are not available in this version.")
        case .storage:
            section("Recording library", "Audio, transcripts, and saved summaries are stored locally.") {
                Text(Paths.recordings.path).font(T.body(12)).foregroundStyle(P.ink2).textSelection(.enabled)
                folderButton("Open recordings folder")
            }
            note("Delete a call", "Select a recording and choose Delete. You can move audio, transcript, or both to Trash. Deleting a transcript also removes its saved summary.")
        case .backup:
            section("Back up your recordings", "Quit Scribebot or finish recording before copying the recordings folder to your backup drive. Include the entire folder to preserve audio, transcripts, and call details together.") {
                folderButton("Open folder to back up")
            }
            note("Sync", "Automatic backup and cloud sync are not available. Files stay on this Mac unless you copy them yourself.")
        case .permissions:
            Text("Allow access here when macOS has not asked yet. If access was denied, macOS requires you to change it in System Settings.")
                .font(T.body(14)).foregroundStyle(P.ink2).fixedSize(horizontal: false, vertical: true)
            ForEach(Scope.allCases) { scope in
                section(scope.title, permissionDescription(scope)) { permissionControl(scope) }
            }
            Button("Refresh status") { perms.refresh() }.buttonStyle(FlatButton(filled: false))
        case .help:
            note("Scribebot \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")", "Local meeting transcription for Mac.")
            section("Support", "Read the guide or report a problem on GitHub. Include what happened and your macOS version; avoid attaching private meeting audio.") {
                Link("User guide", destination: URL(string: "https://github.com/goblin195/ScribeBot#readme")!)
                Link("Report an issue", destination: URL(string: "https://github.com/goblin195/ScribeBot/issues")!)
                Link("Releases", destination: URL(string: "https://github.com/goblin195/ScribeBot/releases")!)
            }
        }
    }

    private func permissionDescription(_ scope: Scope) -> String {
        switch scope {
        case .systemAudio: return "Capture the other side of a call from system audio. Required to start recording."
        case .microphone: return "Capture your voice on its own audio track."
        case .calendar: return "Name new recordings using calendar meetings. Optional."
        case .contacts: return "Optional contacts access. Granting this permission does not automatically import names into the glossary."
        }
    }

    private func permissionControl(_ scope: Scope) -> some View {
        let consent = perms.consent(scope)
        return HStack {
            Pill(text: consent.label, kind: consent.pill)
            Spacer()
            Button(consent == .undetermined ? "Allow access" : "Open System Settings") {
                if consent == .undetermined { perms.request(scope) }
                else { perms.openSettings(scope) }
            }.buttonStyle(FlatButton(filled: consent == .undetermined))
        }
    }

    private func folderButton(_ title: String) -> some View {
        Button(title) { NSWorkspace.shared.open(Paths.recordings) }
            .buttonStyle(FlatButton(filled: false))
    }

    private func note(_ title: String, _ description: String) -> some View {
        section(title, description) { EmptyView() }
    }

    private func section<Content: View>(_ title: String, _ description: String,
                                      @ViewBuilder controls: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(T.body(16, .semibold))
            Text(description).font(T.body(13)).foregroundStyle(P.ink2)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            controls()
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(P.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
