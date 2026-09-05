import Foundation

/// Input activity is a hint, not a meeting API. Keep a session alive through
/// short mute/device transitions so dismissing a prompt actually dismisses it.
struct CallSessions {
    private var lastSeen: [String: Date] = [:]
    mutating func update(active: Set<String>, now: Date, suppressed: Bool) -> String? {
        lastSeen = lastSeen.filter { now.timeIntervalSince($0.value) < 30 }
        let fresh = active.subtracting(lastSeen.keys).sorted()
        for id in active { lastSeen[id] = now }
        return suppressed ? nil : fresh.first
    }
}

