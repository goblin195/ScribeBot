// The panel behind the status item. Idle and recording are two different
// layouts, not one layout with a colour swap.
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        label
            // The status item is the only view alive before a window exists, so
            // it is what AppDelegate asks to open the main window at launch.
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    @ViewBuilder private var label: some View {
        if recorder.isRecording {
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill")
                Text(clock(recorder.elapsed)).font(T.mono(11, .medium))
            }
        } else {
            Image(systemName: "waveform")
        }
    }
}

func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
}

struct MenuBarView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var perms: Permissions
    var open: (WindowID) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Eyebrow(text: "scribebot", color: P.accent)
                Spacer()
                Pill(text: recorder.isRecording ? "recording" : "idle",
                     kind: recorder.isRecording ? .run : .idle)
            }
            .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 11)

            Divider().overlay(P.rule)

            if recorder.isRecording { recordingBody } else { idleBody }

            Divider().overlay(P.rule)

            VStack(spacing: 0) {
                Row(icon: "rectangle.split.3x1", title: "Open Scribebot") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Divider().overlay(P.rule).padding(.vertical, 4)
                Row(icon: "text.alignright", title: "Live transcript",
                    note: recorder.committed.isEmpty ? nil : "\(recorder.committed.count) lines") {
                    open(.transcript)
                }
                Row(icon: "list.bullet.rectangle", title: "Recordings",
                    note: recorder.library.items.isEmpty ? nil : "\(recorder.library.items.count)") {
                    open(.library)
                }
                Row(icon: "lock.shield", title: "Permissions",
                    note: perms.readyToRecord ? nil : "action needed",
                    noteColor: perms.readyToRecord ? P.ink3 : P.warn) {
                    open(.onboarding)
                }
                Divider().overlay(P.rule).padding(.vertical, 4)
                Row(icon: "power", title: "Quit Scribebot") { NSApp.terminate(nil) }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 310)
        .background(P.ground)
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ready for your next conversation.")
                .font(T.body(13)).foregroundStyle(P.ink2)
            if let e = recorder.lastError {
                Text(e).font(T.mono(10)).foregroundStyle(P.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: { recorder.start() }) {
                HStack(spacing: 7) {
                    Image(systemName: "record.circle").font(.system(size: 11, weight: .semibold))
                    Text("New recording")
                }
            }
            .buttonStyle(FlatButton())
            .disabled(!perms.readyToRecord)
            .opacity(perms.readyToRecord ? 1 : 0.45)
            if !perms.readyToRecord {
                Text("System audio recording is not granted yet.")
                    .font(T.mono(10)).foregroundStyle(P.warn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 15)
    }

    private var recordingBody: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                RecDot()
                Text(clock(recorder.elapsed))
                    .font(T.mono(26, .medium)).foregroundStyle(P.ink)
                    .monospacedDigit()
                Spacer()
                Text("Recording").font(T.mono(9.5)).foregroundStyle(P.ink3)
            }
            LevelMeter(level: recorder.level)
            if !recorder.provisional.isEmpty || !recorder.committed.isEmpty {
                BidiText(text: recorder.provisional.isEmpty
                         ? (recorder.committed.last ?? "") : recorder.provisional,
                         font: T.body(12),
                         color: recorder.provisional.isEmpty ? P.ink2 : P.ink3)
                    .lineLimit(2)
            }
            Button(action: { recorder.stop() }) {
                HStack(spacing: 7) {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold))
                    Text("Stop & save")
                }
            }
            .buttonStyle(FlatButton(tint: P.bad))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 15)
    }
}

/// Pulsing capture indicator — the one place motion is warranted.
struct RecDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(P.bad).frame(width: 9, height: 9)
            .opacity(on ? 1 : 0.32)
            .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// 28 hard segments rather than a smooth bar: it reads as an instrument, and
/// the last four sit in the clip colour so hot input is visible at a glance.
struct LevelMeter: View {
    let level: Float
    private let count = 28
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                let lit = Float(i) / Float(count) < level
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(lit ? (i > count - 5 ? P.bad : P.accent) : P.sunk)
                    .frame(height: i > count - 5 ? 14 : 10)
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: level)
    }
}

private struct Row: View {
    let icon: String
    let title: String
    var note: String? = nil
    var noteColor: Color = P.ink3
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 11))
                    .foregroundStyle(hover ? P.accent : P.ink2).frame(width: 15)
                Text(title).font(T.body(12.5)).foregroundStyle(P.ink)
                Spacer()
                if let note { Text(note).font(T.mono(10)).foregroundStyle(noteColor) }
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? P.surface2 : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
