import Foundation

/// Persists `[HangSession]` to `UserDefaults` as JSON.
///
/// Chosen over SwiftData/CoreData deliberately: the project's deployment
/// targets are iOS 13 / watchOS 9, below the SwiftData floor, and a JSON blob in
/// UserDefaults is the simplest store that satisfies "record every session" +
/// "day/week/year aggregation" without new dependencies (razor's principle).
///
/// The store itself is trivially testable: inject a `UserDefaults` suite (or
/// use `.standard` in production) and call `append` / `allSessions`.
///
/// Thread-safety: `UserDefaults` is documented thread-safe; mutations here are
/// confined to the main queue by the callers (ViewModel / phone UI).
final class HangSessionStore: ObservableObject {

    private let defaults: UserDefaults
    private let key: String

    /// - Parameter defaults: inject a suite for tests (e.g. a fresh
    ///   `UserDefaults(suiteName:)`); defaults to `.standard` for production.
    init(defaults: UserDefaults = .standard, key: String = "hangSessions") {
        self.defaults = defaults
        self.key = key
    }

    /// All stored sessions, oldest-first. Reading decodes from disk each call
    /// (cheap for our volumes); mutations publish via `objectWillChange`.
    var allSessions: [HangSession] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([HangSession].self, from: data)) ?? []
    }

    /// Append a completed session and persist immediately.
    func append(_ session: HangSession) {
        var sessions = allSessions
        sessions.append(session)
        save(sessions)
    }

    /// Replace the entire history (used by phone-side edits / sync merges).
    func replaceAll(_ sessions: [HangSession]) {
        save(sessions)
    }

    /// Wipe all stored sessions (used by "clear history" on the phone).
    func clear() {
        defaults.removeObject(forKey: key)
        objectWillChange.send()
    }

    private func save(_ sessions: [HangSession]) {
        let data = (try? JSONEncoder().encode(sessions)) ?? Data()
        defaults.set(data, forKey: key)
        objectWillChange.send()
    }
}
