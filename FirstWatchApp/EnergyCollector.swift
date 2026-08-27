import Foundation
import Combine

/// Tracks which hang sessions the user has "collected" as energy orbs in the
/// Garden (蚂蚁森林-style tap-to-collect), and enforces the 72-hour expiry.
///
/// Borrowed from Ant Forest: energy is collectible immediately (instant
/// gratification from a just-finished hang), but if left uncollected for more
/// than `expirySeconds` (72h) it "withers" and disappears — creating gentle
/// urgency to check back, without the harsher "tree dies" punishment.
///
/// Injectable `UserDefaults` + `now` for testing.
final class EnergyCollector: ObservableObject {

    /// How long an uncollected orb stays alive before withering. 72h, matching
    /// Ant Forest.
    static let expirySeconds: TimeInterval = 72 * 60 * 60

    @Published private(set) var collectedSessionIDs: Set<UUID>

    private let defaults: UserDefaults
    private let key = "collectedEnergyIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.array(forKey: key) as? [String] ?? []
        self.collectedSessionIDs = Set(stored.compactMap { UUID(uuidString: $0) })
    }

    /// Whether a given session's orb has already been collected.
    func isCollected(_ session: HangSession) -> Bool {
        collectedSessionIDs.contains(session.id)
    }

    /// Whether a session's orb is still alive (within the 72h window). Pure
    /// function of the session date and `now`, so it's trivially testable.
    static func isAlive(_ session: HangSession, now: Date = Date()) -> Bool {
        now.timeIntervalSince(session.date) <= expirySeconds
    }

    /// Sessions whose orbs are still floating (uncollected AND alive). These are
    /// the orbs visible in the Garden. `now` is injectable for testing.
    func uncollected(from sessions: [HangSession], now: Date = Date()) -> [HangSession] {
        sessions.filter {
            !collectedSessionIDs.contains($0.id) && Self.isAlive($0, now: now)
        }
    }

    /// Mark a session's orb as collected. Returns true if it was a new
    /// collection (caller plays the sound / animation), false if already taken.
    @discardableResult
    func collect(_ session: HangSession) -> Bool {
        guard !collectedSessionIDs.contains(session.id) else { return false }
        collectedSessionIDs.insert(session.id)
        persist()
        return true
    }

    /// Collect everything passed in at once (for a "collect all" affordance).
    func collectAll(_ sessions: [HangSession]) {
        for s in sessions { collectedSessionIDs.insert(s.id) }
        persist()
    }

    /// Reset collection state (used by the demo "clear" button).
    func reset() {
        collectedSessionIDs.removeAll()
        persist()
    }

    private func persist() {
        let strings = collectedSessionIDs.map { $0.uuidString }
        defaults.set(strings, forKey: key)
    }
}
