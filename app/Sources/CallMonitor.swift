import SwiftUI
import CoreAudio

@MainActor
final class CallMonitor {
    private let recorder: Recorder
    private let perms: Permissions
    private var timer: Timer?
    private var panel: NSPanel?
    private var expiry: Date?
    private var sessions = CallSessions()
    private var previous: Set<String> = []
    private var displayedID: String?

    init(recorder: Recorder, perms: Permissions) {
        self.recorder = recorder
        self.perms = perms
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let enabled = UserDefaults.standard.object(forKey: "callPrompts") as? Bool ?? true
        guard enabled else { dismiss(); previous = []; sessions = CallSessions(); return }
        let apps = activeApps()
        let active = Set(apps.keys)
        let stable = active.intersection(previous)
        previous = active
        let busy = recorder.isRecording || recorder.isFinalizing
        let candidate = sessions.update(active: stable, now: Date(), suppressed: busy)
        if busy || (expiry.map { Date() >= $0 } ?? false)
            || (displayedID.map { !active.contains($0) } ?? false) { dismiss() }
        if let id = candidate, panel == nil, let app = apps[id] {
            show(name: app.localizedName ?? id, icon: app.icon, id: id, preview: false)
        }
    }

    func preview() {
        show(name: "Preview · meeting app", icon: nil, id: nil, preview: true)
    }

    private func show(name: String, icon: NSImage?, id: String?, preview: Bool) {
        dismiss()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 84),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: CallPrompt(name: name, icon: icon, preview: preview,
            action: { [weak self] in self?.transcribe(preview: preview) },
            dismiss: { [weak self] in self?.dismiss() }))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 380, y: frame.maxY - 104))
        }
        self.panel = panel
        displayedID = id
        expiry = Date().addingTimeInterval(30)
        panel.orderFrontRegardless()
    }

    private func transcribe(preview: Bool) {
        dismiss()
        guard !preview, !recorder.isRecording, !recorder.isFinalizing else { return }
        perms.refresh()
        guard perms.readyToRecord else {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
            NotificationCenter.default.post(name: .openSettings, object: nil, userInfo: ["page": "Permissions"])
            return
        }
        recorder.start()
        if recorder.lastError != nil {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        expiry = nil
        displayedID = nil
    }

    private func activeApps() -> [String: NSRunningApplication] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [:] }
        guard size > 0 else { return [:] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [:] }
        var result: [String: NSRunningApplication] = [:]
        for object in objects {
            guard scalar(object, kAudioProcessPropertyIsRunningInput) != 0,
                  let app = NSRunningApplication(processIdentifier: pid_t(bitPattern: scalar(object, kAudioProcessPropertyPID))),
                  let bundle = app.bundleIdentifier else { continue }
            // Helper processes are attributed to their running parent application.
            let families = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
                "com.cisco.webex", "net.whatsapp.WhatsApp", "com.apple.FaceTime",
                "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
                "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser.Browser",
                "com.tinyspeck.slackmacgap", "com.hnc.Discord"]
            guard let family = families.first(where: { bundle == $0 || bundle.hasPrefix($0 + ".") || ($0 == "com.cisco.webex" && bundle.hasPrefix($0)) }) else { continue }
            result[family] = NSRunningApplication.runningApplications(withBundleIdentifier: family).first ?? app
        }
        return result
    }

    private func scalar(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
}

private struct CallPrompt: View {
    let name: String
    let icon: NSImage?
    let preview: Bool
    let action: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "waveform.circle.fill").resizable() }
            }.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcribe this call?").font(.system(size: 14, weight: .semibold))
                Text(name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(preview ? "Got it" : "Transcribe", action: action)
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white).padding(.horizontal, 13).padding(.vertical, 10)
                .background(Color(white: 0.15), in: Capsule())
        }
        .padding(16).frame(width: 360, height: 84)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(10)
                .accessibilityLabel("Dismiss call prompt")
        }
    }
}
