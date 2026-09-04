// First run. Four consent systems, explained one line each, with live status.
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var perms: Permissions
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(P.ink)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(Scope.allCases.enumerated()), id: \.element.id) { i, scope in
                        PermissionRow(index: i + 1, scope: scope,
                                      consent: perms.consent(scope),
                                      grant: { perms.request(scope) },
                                      settings: { perms.openSettings(scope) })
                        Divider().overlay(P.rule)
                    }
                }
            }
            footer
        }
        .background(P.ground)
        .frame(minWidth: 560, minHeight: 540)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in perms.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(P.accent).frame(width: 6, height: 6)
                Eyebrow(text: "first run · on-device only", color: P.accent)
            }
            Text("Four permissions,\nand what each one buys you.")
                .font(T.disp(27)).tracking(-0.6)
                .foregroundStyle(P.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Scribebot transcribes meetings entirely on this Mac. Nothing is uploaded, "
                 + "so every one of these is about what the machine can hear or read locally.")
                .font(T.body(12.5)).foregroundStyle(P.ink2)
                .lineSpacing(2.5)
                .frame(maxWidth: 460, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 24)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(P.rule)
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: perms.readyToRecord ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(perms.readyToRecord ? P.ok : P.warn)
                    .font(.system(size: 13))
                Text(perms.readyToRecord
                     ? "Ready. System audio can be captured."
                     : "System audio recording is the one Scribebot cannot work without.")
                    .font(T.body(12)).foregroundStyle(P.ink2)
                Spacer(minLength: 8)
                Button(perms.readyToRecord ? "Start using Scribebot" : "Continue anyway",
                       action: onDone)
                    .buttonStyle(FlatButton(tint: perms.readyToRecord ? P.accent : P.ink3,
                                            filled: perms.readyToRecord))
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
            .background(P.surface2)
        }
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
        .padding(.horizontal, 30).padding(.vertical, 18)
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
