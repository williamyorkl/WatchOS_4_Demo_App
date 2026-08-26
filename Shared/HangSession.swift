import Foundation

/// A single completed hang session, persisted locally and (later) synced to the
/// phone. Pure `Codable` value type on `Foundation` only, so it compiles into
/// the watch extension, the iOS app, and the test target — and serialises with
/// plain `JSONEncoder`/`JSONDecoder` (no SwiftData/CoreData dependency, per the
/// "keep the deployment target where it is" decision).
struct HangSession: Codable, Equatable, Identifiable {
    /// Stable unique id (UUID string). `Identifiable` so it works directly in
    /// SwiftUI `List`/`ForEach` on the phone.
    let id: UUID
    /// When the session was completed (used for day/week/year grouping).
    let date: Date
    /// Number of completed 10-second sets.
    let reps: Int
    /// Total hang time in seconds across the whole session.
    let totalSeconds: Int

    init(id: UUID = UUID(), date: Date = Date(), reps: Int, totalSeconds: Int) {
        self.id = id
        self.date = date
        self.reps = reps
        self.totalSeconds = totalSeconds
    }
}

/// Day-keyed grouping helpers. Pure functions, fully unit-testable, shared by
/// the watch (summary "best today") and the phone (history charts).
extension HangSession {

    /// A calendar-day identity (year, month, day) for grouping, independent of
    /// the exact time-of-day a session happened.
    struct DayKey: Hashable, Comparable, CustomStringConvertible {
        let year: Int
        let month: Int
        let day: Int

        var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

        static func < (lhs: DayKey, rhs: DayKey) -> Bool {
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            if lhs.month != rhs.month { return lhs.month < rhs.month }
            return lhs.day < rhs.day
        }
    }

    /// The day key for this session in the given calendar (default Gregorian).
    func dayKey(calendar: Calendar = Calendar(identifier: .gregorian)) -> DayKey {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return DayKey(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    /// Total seconds for a group of sessions (e.g. all sessions on one day).
    static func totalSeconds(of sessions: [HangSession]) -> Int {
        sessions.reduce(0) { $0 + $1.totalSeconds }
    }

    /// Group sessions by calendar day, ascending by day.
    static func groupedByDay(_ sessions: [HangSession],
                             calendar: Calendar = Calendar(identifier: .gregorian))
        -> [(day: DayKey, sessions: [HangSession])] {
        let groups = Dictionary(grouping: sessions, by: { $0.dayKey(calendar: calendar) })
        return groups.sorted { $0.key < $1.key }
            .map { (day: $0.key, sessions: $0.value) }
    }
}
