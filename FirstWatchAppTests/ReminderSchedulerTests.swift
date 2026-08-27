import XCTest
@testable import FirstWatchApp

/// Tests for the reminder scheduler's pure logic (time math + "has hung today").
/// The actual UNUserNotificationCenter calls are not exercised here (they need
/// a real device/simulator entitlement); the testable parts are the date math
/// and the "did the user hang today" predicate.
final class ReminderSchedulerTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ hr: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = hr; c.minute = mi
        return calendar.date(from: c)!
    }

    // MARK: - nextFireDate

    func test_nextFireDate_beforeTargetTime_isToday() {
        // Now = 10:00, target 20:00 → fires today at 20:00.
        let now = date(2026, 6, 16, 10, 0)
        let fire = ReminderScheduler.nextFireDate(after: now, hour: 20, minute: 0,
                                                   calendar: calendar)
        XCTAssertEqual(fire, date(2026, 6, 16, 20, 0))
    }

    func test_nextFireDate_afterTargetTime_isTomorrow() {
        // Now = 21:00, target 20:00 → already passed, fires tomorrow.
        let now = date(2026, 6, 16, 21, 0)
        let fire = ReminderScheduler.nextFireDate(after: now, hour: 20, minute: 0,
                                                   calendar: calendar)
        XCTAssertEqual(fire, date(2026, 6, 17, 20, 0))
    }

    func test_nextFireDate_exactlyAtTarget_advancesToTomorrow() {
        // At exactly 20:00, .nextTime pushes to the next occurrence (tomorrow).
        let now = date(2026, 6, 16, 20, 0)
        let fire = ReminderScheduler.nextFireDate(after: now, hour: 20, minute: 0,
                                                   calendar: calendar)
        XCTAssertEqual(fire, date(2026, 6, 17, 20, 0))
    }

    func test_nextFireDate_invalidHour_returnsNil() {
        XCTAssertNil(ReminderScheduler.nextFireDate(hour: 24))
        XCTAssertNil(ReminderScheduler.nextFireDate(hour: -1))
    }

    func test_nextFireDate_invalidMinute_returnsNil() {
        XCTAssertNil(ReminderScheduler.nextFireDate(hour: 20, minute: 60))
    }

    // MARK: - hasHungToday

    func test_hasHungToday_trueWhenSessionToday() {
        let now = date(2026, 6, 16, 12, 0)
        let session = HangSession(date: date(2026, 6, 16, 8, 0), reps: 1, totalSeconds: 10)
        XCTAssertTrue(ReminderScheduler.hasHungToday([session], now: now))
    }

    func test_hasHungToday_falseWhenSessionYesterday() {
        let now = date(2026, 6, 16, 12, 0)
        let session = HangSession(date: date(2026, 6, 15, 23, 0), reps: 1, totalSeconds: 10)
        XCTAssertFalse(ReminderScheduler.hasHungToday([session], now: now))
    }

    func test_hasHungToday_falseWhenNoSessions() {
        let now = date(2026, 6, 16, 12, 0)
        XCTAssertFalse(ReminderScheduler.hasHungToday([], now: now))
    }
}
