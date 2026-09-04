// Four separate consent systems, four different APIs, one screen.
//
// System audio recording is the awkward one: it is kTCCServiceAudioCapture, it
// is NOT the microphone, and AVFoundation has no public API for it. The TCC SPI
// below is lifted verbatim from capture/tap.swift, where it was worked out the
// hard way — it must run in *this* process, because TCC answers about the
// caller, and the helper we spawn inherits our grant as its responsible parent.
import SwiftUI
import AVFoundation
import EventKit
import Contacts

enum Consent: Equatable {
    case granted, denied, undetermined, unavailable

    var pill: Pill.Kind {
        switch self {
        case .granted: return .ok
        case .denied: return .bad
        case .undetermined: return .idle
        case .unavailable: return .warn
        }
    }
    var label: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "not asked"
        case .unavailable: return "unavailable"
        }
    }
}

// MARK: - TCC private API (system audio recording)

private let tccHandle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
private let kAudioCaptureService = "kTCCServiceAudioCapture" as CFString

/// 0 = authorized, 1 = denied, 2 = undetermined, -1 = SPI missing.
func audioCapturePreflight() -> Int {
    guard let h = tccHandle, let sym = dlsym(h, "TCCAccessPreflight") else { return -1 }
    return unsafeBitCast(sym, to: PreflightFn.self)(kAudioCaptureService, nil)
}

func requestAudioCapture(_ done: @escaping (Bool) -> Void) {
    guard let h = tccHandle, let sym = dlsym(h, "TCCAccessRequest") else { done(false); return }
    unsafeBitCast(sym, to: RequestFn.self)(kAudioCaptureService, nil) { ok in
        DispatchQueue.main.async { done(ok) }
    }
}

// MARK: - Model

enum Scope: String, CaseIterable, Identifiable {
    case systemAudio, microphone, calendar, contacts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemAudio: return "System audio recording"
        case .microphone:  return "Microphone"
        case .calendar:    return "Calendar"
        case .contacts:    return "Contacts"
        }
    }
    /// One honest line. Not marketing — what breaks without it.
    var why: String {
        switch self {
        case .systemAudio:
            return "Records what the other people on the call say. Without it Scribebot only hears you."
        case .microphone:
            return "Records your own side of the conversation. Without it your half is missing."
        case .calendar:
            return "Names the recording after the meeting it happened in, instead of a timestamp."
        case .contacts:
            return "Feeds the glossary the proper nouns transcribers mangle — colleagues, vendors, projects."
        }
    }
    var detail: String {
        switch self {
        case .systemAudio: return "kTCCServiceAudioCapture · CoreAudio process tap"
        case .microphone:  return "AVCaptureDevice · .audio"
        case .calendar:    return "EventKit · full access to events"
        case .contacts:    return "Contacts · read-only"
        }
    }
    /// Required to record at all, versus makes the output better.
    var essential: Bool { self == .systemAudio || self == .microphone }

    var settingsPane: String {
        switch self {
        case .systemAudio: return "Privacy_AudioCapture"
        case .microphone:  return "Privacy_Microphone"
        case .calendar:    return "Privacy_Calendars"
        case .contacts:    return "Privacy_Contacts"
        }
    }
}

@MainActor
final class Permissions: ObservableObject {
    @Published private(set) var state: [Scope: Consent] = [:]
    private let eventStore = EKEventStore()

    init() { refresh() }

    func consent(_ s: Scope) -> Consent { state[s] ?? .undetermined }

    /// True once we can actually capture both sides of a call.
    var readyToRecord: Bool { consent(.systemAudio) == .granted }

    var allEssentialResolved: Bool {
        Scope.allCases.filter(\.essential).allSatisfy { consent($0) != .undetermined }
    }

    func refresh() {
        state[.systemAudio] = {
            switch audioCapturePreflight() {
            case 0: return .granted
            case 1: return .denied
            case 2: return .undetermined
            default: return .unavailable
            }
        }()
        state[.microphone] = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .undetermined
            }
        }()
        state[.calendar] = {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .denied, .restricted, .writeOnly: return .denied
            default: return .undetermined
            }
        }()
        state[.contacts] = {
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .undetermined
            }
        }()
    }

    func request(_ scope: Scope) {
        // Once TCC has a decision on record the prompt never shows again; the
        // only honest thing left to do is send the user to the right pane.
        if consent(scope) == .denied { openSettings(scope); return }

        switch scope {
        case .systemAudio:
            requestAudioCapture { [weak self] _ in self?.refresh() }
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        case .calendar:
            eventStore.requestFullAccessToEvents { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        case .contacts:
            CNContactStore().requestAccess(for: .contacts) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func openSettings(_ scope: Scope) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(scope.settingsPane)")!
        NSWorkspace.shared.open(url)
    }
}
