import XCTest
@testable import FirstWatchApp

/// Tests for the persistence + aggregation layer shared by the watch (summary
/// "best today") and the phone (history charts / gamification growth). These run
/// against a throwaway `UserDefaults` suite so they never touch real app data.
final class HangSessionStoreTests: XCTestCase {

    /// A fresh isolated UserDefaults per test. `.removePersistentDomain` ensures
    /// no leakage between tests even if a previous run wrote to this suite.
    private func makeStore() -> HangSessionStore {
        let suiteName = "HangSessionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return HangSessionStore(defaults: defaults, key: "test.sessions")
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ hr: Int = 9) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = hr
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - Store

    func test_emptyStore_returnsEmptyArray() {
        let store = makeStore()
        XCTAssertEqual(store.allSessions, [])
    }

    func test_append_persistsAndRetrieves() {
        let store = makeStore()
        let s = HangSession(date: date(2026, 6, 16), reps: 3, totalSeconds: 30)

        store.append(s)

        XCTAssertEqual(store.allSessions.count, 1)
        XCTAssertEqual(store.allSessions.first, s)
    }

    func test_append_preservesOrder_oldestFirst() {
        let store = makeStore()
        let old = HangSession(date: date(2026, 6, 1), reps: 1, totalSeconds: 10)
        let new = HangSession(date: date(2026, 6, 16), reps: 2, totalSeconds: 20)

        store.append(old)
        store.append(new)

        XCTAssertEqual(store.allSessions, [old, new])
    }

    func test_clear_removesAll() {
        let store = makeStore()
        store.append(HangSession(reps: 1, totalSeconds: 10))

        store.clear()

        XCTAssertEqual(store.allSessions, [])
    }

    func test_replaceAll_overwritesHistory() {
        let store = makeStore()
        store.append(HangSession(reps: 1, totalSeconds: 10))
        let replacement = [HangSession(reps: 5, totalSeconds: 50)]

        store.replaceAll(replacement)

        XCTAssertEqual(store.allSessions, replacement)
    }

    func test_corruptedData_returnsEmptyRatherThanCrashing() {
        // Simulate garbage in UserDefaults: the store must degrade gracefully.
        let suiteName = "HangSessionStoreTests.corrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(Data("not json".utf8), forKey: "test.sessions")
        let store = HangSessionStore(defaults: defaults, key: "test.sessions")

        XCTAssertEqual(store.allSessions, [], "Corrupted JSON should yield [] not a crash")
    }

    // MARK: - Codable round-trip

    func test_codable_roundTrip() throws {
        let original = HangSession(reps: 4, totalSeconds: 40)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HangSession.self, from: data)

        XCTAssertEqual(decoded.reps, 4)
        XCTAssertEqual(decoded.totalSeconds, 40)
    }

    // MARK: - Day grouping (used by phone history + "best today")

    func test_dayKey_groupsSameDayTogether() {
        let morning = HangSession(date: date(2026, 6, 16, 8), reps: 1, totalSeconds: 10)
        let evening = HangSession(date: date(2026, 6, 16, 20), reps: 2, totalSeconds: 20)

        XCTAssertEqual(morning.dayKey(), evening.dayKey(),
                       "Two sessions on the same calendar day share a DayKey")
    }

    func test_groupedByDay_ordersAscendingAndSeparatesDays() {
        let sessions = [
            HangSession(date: date(2026, 6, 16, 20), reps: 2, totalSeconds: 20),
            HangSession(date: date(2026, 6, 1, 9), reps: 1, totalSeconds: 10),
            HangSession(date: date(2026, 6, 16, 8), reps: 1, totalSeconds: 10),
        ]

        let groups = HangSession.groupedByDay(sessions)

        XCTAssertEqual(groups.count, 2, "Two distinct days")
        XCTAssertEqual(groups[0].day.day, 1, "First group is the earliest day")
        XCTAssertEqual(groups[1].day.day, 16)
        XCTAssertEqual(groups[1].sessions.count, 2, "Both June-16 sessions land in one group")
    }

    func test_totalSeconds_sumsAcrossSessions() {
        let sessions = [
            HangSession(reps: 1, totalSeconds: 10),
            HangSession(reps: 3, totalSeconds: 30),
        ]
        XCTAssertEqual(HangSession.totalSeconds(of: sessions), 40)
    }

    func test_dayKey_stringFormat() {
        let s = HangSession(date: date(2026, 6, 16), reps: 1, totalSeconds: 10)
        XCTAssertEqual(s.dayKey().description, "2026-06-16")
    }
}
