import Foundation
import os

/// Chooses which helper (one per Chrome profile) receives toggles and drives the indicator:
/// the profile that joined a call most recently, otherwise the one with the most recent activity.
/// Activity is a change of a state already known, or a confirmed toggle; a first report cannot be
/// told apart from a reply to `get_state`, so it does not count. Ties go to the newest helper.
struct CallRouter {
    struct Profile: Equatable {
        var muted: Bool?
        var cameraOff: Bool?
        var inCall = false

        var hasKnownState: Bool { muted != nil || cameraOff != nil }
    }

    private struct Entry {
        var profile = Profile()
        let connectedAt: Int
        var lastActivity = 0
        var joinedCallAt = 0
    }

    private var entries: [ClientID: Entry] = [:]
    private var toggleRecipients: [ToggleTarget: ClientID] = [:]
    private let logger = Logger(subsystem: "com.macmute.app", category: "routing")
    private var clock = 0

    var selected: ClientID? {
        let inCall = entries.filter { $0.value.profile.inCall }
        if let latestJoin = inCall.max(by: { $0.value.joinedCallAt < $1.value.joinedCallAt }) {
            return latestJoin.key
        }
        // Without activity, a helper that reported any state has a Meet tab; a newer one without state may not.
        return entries.max { lhs, rhs in
            (lhs.value.lastActivity, lhs.value.profile.hasKnownState ? 1 : 0, lhs.value.connectedAt)
                < (rhs.value.lastActivity, rhs.value.profile.hasKnownState ? 1 : 0, rhs.value.connectedAt)
        }?.key
    }

    func profile(_ id: ClientID) -> Profile? {
        entries[id]?.profile
    }

    mutating func connect(_ id: ClientID) {
        entries[id] = Entry(connectedAt: tick())
    }

    /// Returns the targets whose latest toggle was sent to this helper, whether or not it is still pending.
    @discardableResult
    mutating func disconnect(_ id: ClientID) -> [ToggleTarget] {
        entries[id] = nil
        let orphaned = toggleRecipients.filter { $0.value == id }.map(\.key)
        orphaned.forEach { toggleRecipients[$0] = nil }
        return orphaned.sorted { $0.rawValue < $1.rawValue }
    }

    mutating func recordState(_ target: ToggleTarget, _ state: Bool, from id: ClientID) {
        guard var entry = knownEntry(id, for: "\(target.rawValue) state") else { return }
        let previous = entry.profile[target]
        entry.profile[target] = state
        if let previous, previous != state {
            entry.lastActivity = tick()
        }
        entries[id] = entry
    }

    mutating func recordConfirmedToggle(_ target: ToggleTarget, _ state: Bool, from id: ClientID) {
        guard var entry = knownEntry(id, for: "confirmed \(target.rawValue) toggle") else { return }
        entry.profile[target] = state
        entry.lastActivity = tick()
        entries[id] = entry
    }

    mutating func setInCall(_ inCall: Bool, for id: ClientID) {
        guard var entry = knownEntry(id, for: "call status"), entry.profile.inCall != inCall else { return }
        entry.profile.inCall = inCall
        if inCall { entry.joinedCallAt = tick() }
        entries[id] = entry
    }

    mutating func toggleSent(_ target: ToggleTarget, to id: ClientID) {
        toggleRecipients[target] = id
    }

    func toggleRecipient(for target: ToggleTarget) -> ClientID? {
        toggleRecipients[target]
    }

    private func knownEntry(_ id: ClientID, for update: String) -> Entry? {
        guard let entry = entries[id] else {
            logger.notice("Ignoring \(update, privacy: .public) from unknown helper \(id, privacy: .public)")
            return nil
        }
        return entry
    }

    private mutating func tick() -> Int {
        clock += 1
        return clock
    }
}

extension CallRouter.Profile {
    /// `true` when the mic is muted or the camera is off, as in `ToggleConfirmation`.
    subscript(target: ToggleTarget) -> Bool? {
        get { target == .mic ? muted : cameraOff }
        set {
            if target == .mic { muted = newValue } else { cameraOff = newValue }
        }
    }
}
