import XCTest
@testable import FirstWatchApp

/// Tests for the energy-collector's 72h wither rule + collection state.
/// Mirrors the 蚂蚁森林 mechanic: collectible immediately, gone after 72h.
final class EnergyCollectorTests: XCTestCase {

    private func makeStore() -> EnergyCollector {
        let suiteName = "EnergyCollectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return EnergyCollector(defaults: defaults)
    }

    private func date(_ daysAgo: Double, _ hoursAgo: Double = 0) -> Date {
        Date().addingTimeInterval(-(daysAgo * 86400 + hoursAgo * 3600))
    }

    // MARK: - 72h wither rule

    func test_isAlive_within72h_isTrue() {
        let s = HangSession(date: date(0, 1), reps: 1, totalSeconds: 30)
        XCTAssertTrue(EnergyCollector.isAlive(s))
    }

    func test_isAlive_justUnder72h_isTrue() {
        // 1 minute before the 72h boundary — comfortably alive.
        let s = HangSession(date: Date().addingTimeInterval(-(EnergyCollector.expirySeconds - 60)),
                            reps: 1, totalSeconds: 30)
        XCTAssertTrue(EnergyCollector.isAlive(s), "Just under 72h should still be alive")
    }

    func test_isAlive_beyond72h_isFalse() {
        let s = HangSession(date: date(4), reps: 1, totalSeconds: 30)  // 4 days ago
        XCTAssertFalse(EnergyCollector.isAlive(s), "Beyond 72h the orb should have withered")
    }

    func test_uncollected_filtersOutExpired() {
        let collector = makeStore()
        let fresh = HangSession(date: date(0, 2), reps: 1, totalSeconds: 30)
        let stale = HangSession(date: date(4), reps: 1, totalSeconds: 30)
        let result = collector.uncollected(from: [fresh, stale])
        XCTAssertEqual(result, [fresh], "Only the alive orb should appear")
    }

    // MARK: - Collection state

    func test_collect_onceReturnsTrue_thenFalse() {
        let collector = makeStore()
        let s = HangSession(date: date(0, 1), reps: 1, totalSeconds: 30)

        XCTAssertTrue(collector.collect(s), "First collect should return true")
        XCTAssertFalse(collector.collect(s), "Second collect should return false (already collected)")
    }

    func test_uncollected_excludesCollected() {
        let collector = makeStore()
        let a = HangSession(date: date(0, 1), reps: 1, totalSeconds: 10)
        let b = HangSession(date: date(0, 2), reps: 1, totalSeconds: 20)
        _ = collector.collect(a)

        let remaining = collector.uncollected(from: [a, b])
        XCTAssertEqual(remaining, [b], "Collected orb must not appear in uncollected")
    }

    func test_reset_clearsAllCollected() {
        let collector = makeStore()
        let s = HangSession(date: date(0, 1), reps: 1, totalSeconds: 10)
        _ = collector.collect(s)
        XCTAssertTrue(collector.isCollected(s))

        collector.reset()
        XCTAssertFalse(collector.isCollected(s))
    }

    // MARK: - Persistence

    func test_collectedIDs_persistAcrossInstances() {
        let suiteName = "EnergyCollectorTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let s = HangSession(date: date(0, 1), reps: 1, totalSeconds: 10)
        EnergyCollector(defaults: defaults).collect(s)

        // A NEW instance reading the same defaults should remember the collect.
        let reloaded = EnergyCollector(defaults: defaults)
        XCTAssertTrue(reloaded.isCollected(s), "Collection must persist to UserDefaults")
    }
}
