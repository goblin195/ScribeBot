// First run: pick a decoder, fetch it, choose who writes summaries, and grant
// the four consent systems. The permissions screen used to be the whole of it,
// because the installer carried the model. It no longer does — 1.4 GB of a
// 1.5 GB DMG was one file — so setup has to put one on the machine.
//
// Every step is resumable, and none of it is stored as "step 3 is done": the
// position is remembered, but what each step reports is read back from the
// world. A finished download is a file on disk; a granted permission is what
// TCC says right now. Quitting halfway and reopening therefore never repeats a
// download or re-asks for something already allowed.
import SwiftUI

enum SetupStep: Int, CaseIterable, Identifiable {
    case welcome, models, summaries, permissions, done
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .welcome: return "Welcome"
        case .models: return "Model"
        case .summaries: return "Summary"
        case .permissions: return "Access"
        case .done: return "Done"
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var perms: Permissions
    @ObservedObject var models: ModelDownloads
    @StateObject private var ai = AISettings.shared
    var onDone: () -> Void

    /// Only the position is persisted. Everything a step reports is re-read.
    @AppStorage("setupStep") private var stepRaw = SetupStep.welcome.rawValue
    private var step: SetupStep { SetupStep(rawValue: stepRaw) ?? .welcome }

    private var anyModelInstalled: Bool {
        ModelCatalog.all.contains { models.state[$0.id] == .installed }
    }
    private var downloading: Bool {
        ModelCatalog.all.contains { models.state[$0.id]?.isBusy == true }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(P.rule)
            ScrollView { content.padding(.horizontal, 30).padding(.vertical, 24) }
            footer
        }
        .background(P.ground)
        .frame(minWidth: 560, minHeight: 560)
        .onAppear {
            models.refresh()
            if ai.providers.isEmpty { ai.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            perms.refresh()
            models.refresh()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(P.accent).frame(width: 6, height: 6)
                Eyebrow(text: "setup · on-device only", color: P.accent)
            }
            HStack(spacing: 0) {
                ForEach(SetupStep.allCases) { s in
                    HStack(spacing: 7) {
                        Text(String(format: "%02d", s.rawValue + 1))
                            .font(T.mono(10))
                            .foregroundStyle(s.rawValue <= step.rawValue ? P.accent : P.ink3)
                            .fixedSize()   // "01" wrapped to two lines otherwise
                        Text(s.label)
                            .font(T.body(11.5, s == step ? .semibold : .regular))
                            .foregroundStyle(s == step ? P.ink : P.ink3)
                            .fixedSize()   // the rail wrapped a label onto two lines
                    }
                    if s != SetupStep.allCases.last {
                        Rectangle().fill(P.rule).frame(height: 1)
                            .frame(maxWidth: .infinity).padding(.horizontal, 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 18)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(P.rule)
            HStack(spacing: 14) {
                if step != .welcome {
                    Button("Back") { stepRaw = max(0, stepRaw - 1) }
                        .buttonStyle(FlatButton(tint: P.ink3, filled: false))
                }
                Text(footnote).font(T.body(12)).foregroundStyle(P.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if step == .done {
                    Button("Start using Scribebot", action: finish)
                        .buttonStyle(FlatButton())
                } else {
                    Button(step == .models && downloading ? "Continue in background" : "Continue") {
                        stepRaw = min(SetupStep.allCases.count - 1, stepRaw + 1)
                    }
                    .buttonStyle(FlatButton())
                }
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
            .background(P.surface2)
        }
    }

    private var footnote: String {
        switch step {
        case .welcome: return ""
        case .models:
            if downloading { return "The download keeps running while you finish setup." }
            return anyModelInstalled ? "" : "Nothing can be transcribed until one of these is on disk."
        case .summaries: return ""
        case .permissions:
            return perms.readyToRecord ? "" : "System audio is the one Scribebot cannot work without."
        case .done: return ""
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "didOnboard")
        onDone()
    }

    // MARK: - Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .models: modelStep
        case .summaries: summaryStep
        case .permissions: permissionStep
        case .done: doneStep
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(T.disp(26)).tracking(-0.6).foregroundStyle(P.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lead(_ text: String) -> some View {
        Text(text)
            .font(T.body(12.5)).foregroundStyle(P.ink2).lineSpacing(2.5)
            .frame(maxWidth: 470, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Everything runs\non this Mac.")
            lead("Scribebot records both sides of a call, transcribes them here, and writes "
                 + "the files next to your recordings. Nothing is uploaded, and there is no "
                 + "account.")
            VStack(alignment: .leading, spacing: 12) {
                bullet("A speech model", "About 1.5 GB, downloaded next. It is not in the "
                       + "installer, which is why the download you just ran was small.")
                bullet("A summary engine", "Optional, and whatever you already have installed. "
                       + "Setup does not download a second multi-gigabyte model.")
                bullet("Four macOS permissions", "Explained one line each, with what breaks "
                       + "without them.")
            }
            .padding(.top, 4)
        }
    }

    private func bullet(_ head: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(P.ink3).frame(width: 4, height: 4).padding(.top, 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(head).font(T.body(13, .semibold)).foregroundStyle(P.ink)
                Text(body).font(T.body(12)).foregroundStyle(P.ink2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 470, alignment: .leading)
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Choose a decoder.")
            lead("Take both if you meet in Hebrew and in other languages — Scribebot detects "
                 + "the language and picks. Either one alone is enough to start.")
            ForEach(ModelCatalog.all) { spec in
                ModelRow(spec: spec,
                         state: models.state[spec.id] ?? .absent,
                         target: models.targetURL(spec),
                         start: { models.start(spec) },
                         cancel: { models.cancel(spec) })
            }
            Text("Models are stored in \(models.directory.path) — not inside the app, because "
                 + "writing into a signed bundle breaks its signature. Replacing Scribebot "
                 + "does not make you download them again.")
                .font(T.mono(10)).foregroundStyle(P.ink3).lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Who writes\nthe summaries?")
            lead("This list is what is actually installed on this Mac right now — Scribebot "
                 + "does not download a summary model. Transcription is unaffected either way; "
                 + "summaries are optional and can be changed later in Settings.")
            AIProviderPicker(ai: ai)
        }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Four permissions,\nand what each one buys you.")
            lead("System audio recording and Microphone are two different grants from macOS. "
                 + "Allowing one does nothing for the other: without system audio you record "
                 + "only yourself, without the microphone only everybody else.")
            VStack(spacing: 0) {
                Divider().overlay(P.rule)
                ForEach(Array(Scope.allCases.enumerated()), id: \.element.id) { i, scope in
                    PermissionRow(index: i + 1, scope: scope,
                                  consent: perms.consent(scope),
                                  grant: { perms.request(scope) },
                                  settings: { perms.openSettings(scope) })
                    Divider().overlay(P.rule)
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(anyModelInstalled && perms.readyToRecord
                  ? "Ready to record."
                  : "Set up, with gaps.")
            VStack(alignment: .leading, spacing: 10) {
                readiness(anyModelInstalled || downloading,
                          anyModelInstalled ? "A speech model is installed."
                          : downloading ? "A model is still downloading; recording works once it lands."
                          : "No speech model. Recording will fail until one is downloaded.")
                readiness(perms.readyToRecord,
                          perms.readyToRecord ? "System audio can be captured."
                          : "System audio recording is not allowed yet.")
                readiness(perms.consent(.microphone) == .granted,
                          perms.consent(.microphone) == .granted
                          ? "Your microphone is captured on its own track."
                          : "Without the microphone your own half is missing.")
            }
            lead("All of this is in Settings if you want to change it. Recordings live in "
                 + "~/Library/Application Support/Scribebot/recordings.")
        }
    }

    private func readiness(_ ok: Bool, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(ok ? P.ok : P.warn).font(.system(size: 13))
            Text(text).font(T.body(12.5)).foregroundStyle(P.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 470, alignment: .leading)
    }
}

/// One downloadable decoder: what it is for, how far it has got, and — when the
/// download will not work — exactly what file to put where instead.
private struct ModelRow: View {
    let spec: ModelSpec
    let state: ModelState
    let target: URL
    let start: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Text(spec.label).font(T.body(14, .semibold)).foregroundStyle(P.ink)
                        Text(spec.sizeText).font(T.mono(10)).foregroundStyle(P.ink3)
                    }
                    Text(spec.blurb).font(T.body(12)).foregroundStyle(P.ink2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                action
            }
            progress
            if case let .failed(why) = state { trouble(why) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .installed:
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("INSTALLED").font(T.mono(10, .medium)).tracking(0.8)
            }
            .foregroundStyle(P.ok)
        case .downloading:
            Button("Cancel", action: cancel).buttonStyle(FlatButton(tint: P.ink3, filled: false))
        case .verifying:
            Text("VERIFYING").font(T.mono(10, .medium)).tracking(0.8).foregroundStyle(P.ink3)
        case .partial:
            Button("Resume", action: start).buttonStyle(FlatButton())
        case .failed:
            Button("Try again", action: start).buttonStyle(FlatButton(tint: P.warn, filled: false))
        case .absent:
            Button("Download", action: start).buttonStyle(FlatButton())
        }
    }

    @ViewBuilder private var progress: some View {
        switch state {
        case let .downloading(received, total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                Text("\(bytes(received)) of \(bytes(total)) · \(percent(received, total))")
                    .font(T.mono(10)).foregroundStyle(P.ink3)
            }
        case let .partial(received):
            Text("\(bytes(received)) already downloaded — Resume continues from there.")
                .font(T.mono(10)).foregroundStyle(P.ink3)
        case .verifying:
            Text("Checking the size and SHA-256 before installing it.")
                .font(T.mono(10)).foregroundStyle(P.ink3)
        default:
            EmptyView()
        }
    }

    /// A failed download is where the honest fallback lives: the app cannot
    /// promise a third-party URL will still answer, so it says which file goes
    /// where and lets the user fetch it any way they like.
    private func trouble(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(why, systemImage: "exclamationmark.triangle")
                .font(T.body(12)).foregroundStyle(P.bad)
                .fixedSize(horizontal: false, vertical: true)
            Text("Or download it yourself and put it at this exact path:")
                .font(T.body(11.5)).foregroundStyle(P.ink2)
            Text(spec.url.absoluteString).font(T.mono(10)).foregroundStyle(P.ink3)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(target.path).font(T.mono(10)).foregroundStyle(P.ink3)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.badSoft, in: RoundedRectangle(cornerRadius: 9))
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    private func percent(_ n: Int64, _ total: Int64) -> String {
        total > 0 ? "\(Int((Double(n) / Double(total)) * 100))%" : "—"
    }
}

private struct PermissionRow: View {
    let index: Int
    let scope: Scope
    let consent: Consent
    let grant: () -> Void
    let settings: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(String(format: "%02d", index))
                .font(T.mono(11)).foregroundStyle(consent == .granted ? P.accent : P.ink3)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Text(scope.title)
                        .font(T.body(14, .semibold)).foregroundStyle(P.ink)
                    // when granted the right-hand column already says so
                    if consent != .granted { Pill(text: consent.label, kind: consent.pill) }
                    if !scope.essential {
                        Text("optional").font(T.mono(9)).tracking(1)
                            .foregroundStyle(P.ink3)
                    }
                }
                Text(scope.why)
                    .font(T.body(12.5)).foregroundStyle(P.ink2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(scope.detail)
                    .font(T.mono(10)).foregroundStyle(P.ink3)
                    .padding(.top, 1)
            }
            Spacer(minLength: 12)
            action.padding(.top, 1)
        }
        .padding(.horizontal, 4).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? P.surface : P.ground)
        .onHover { hover = $0 }
    }

    @ViewBuilder private var action: some View {
        switch consent {
        case .granted:
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("GRANTED").font(T.mono(10, .medium)).tracking(0.8)
            }
            .foregroundStyle(P.ok)
            .frame(width: 96, alignment: .trailing)
        case .denied:
            Button("Open Settings", action: settings)
                .buttonStyle(FlatButton(tint: P.warn, filled: false))
                .frame(width: 116, alignment: .trailing)
        case .unavailable:
            Text("SPI MISSING").font(T.mono(10)).foregroundStyle(P.bad)
                .frame(width: 96, alignment: .trailing)
        case .undetermined:
            Button("Grant", action: grant)
                .buttonStyle(FlatButton())
                .frame(width: 96, alignment: .trailing)
        }
    }
}
