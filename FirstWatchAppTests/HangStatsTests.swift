import XCTest
@testable import FirstWatchApp

/// Tests for the shared aggregation math used by the phone's History/Stats and
/// (later) the gamification growth calc. Pure functions over `[HangSession]`,
/// so every number on the phone screen is pinned here.
final class HangStatsTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ hr: Int = 9, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = hr; c.minute = min
        return calendar.date(from: c)!
    }

    private func session(_ y: Int, _ m: Int, _ d: Int, _ hr: Int = 9, reps: Int = 1, seconds: Int = 10) -> HangSession {
        HangSession(date: date(y, m, d, hr), reps: reps, totalSeconds: seconds)
    }

    // MARK: - Totals

    func test_totalSeconds_sumsAllSessions() {
        let sessions = [session(2026, 6, 1, seconds: 10), session(2026, 6, 2, seconds: 30)]
        XCTAssertEqual(HangStats.totalSeconds(sessions), 40)
    }

    func test_totalReps_sumsAllSessions() {
        let sessions = [session(2026, 6, 1, reps: 2), session(2026, 6, 2, reps: 3)]
        XCTAssertEqual(HangStats.totalReps(sessions), 5)
    }

    func test_empty_totalsAreZero() {
        XCTAssertEqual(HangStats.totalSeconds([]), 0)
        XCTAssertEqual(HangStats.totalReps([]), 0)
        XCTAssertEqual(HangStats.bestDaySeconds([]), 0)
        XCTAssertEqual(HangStats.bestSessionSeconds([]), 0)
    }

    // MARK: - Bests

    func test_bestDaySeconds_picksHighestDayTotal() {
        // June 1: 10+20=30. June 2: 50. June 3: 5. → best = 50.
        let sessions = [
            session(2026, 6, 1, seconds: 10),
            session(2026, 6, 1, seconds: 20),
            session(2026, 6, 2, seconds: 50),
            session(2026, 6, 3, seconds: 5),
        ]
        XCTAssertEqual(HangStats.bestDaySeconds(sessions), 50)
    }

    func test_bestSessionSeconds_picksHighestSingleSession() {
        let sessions = [session(2026, 6, 1, seconds: 10),
                        session(2026, 6, 2, seconds: 45),
                        session(2026, 6, 3, seconds: 30)]
        XCTAssertEqual(HangStats.bestSessionSeconds(sessions), 45)
    }

    // MARK: - Streak

    func test_streak_consecutiveDaysEndingToday() {
        let now = date(2026, 6, 3, 12)
        let sessions = [
            session(2026, 6, 1),
            session(2026, 6, 2),
            session(2026, 6, 3),
        ]
        XCTAssertEqual(HangStats.currentStreakDays(sessions, now: now), 3)
    }

    func test_streak_countsYesterdayIfTodayEmpty() {
        // User hung yesterday + day before, not yet today. Streak should still
        // read 2 (don't punish checking the app early in the day).
        let now = date(2026, 6, 3, 8)
        let sessions = [session(2026, 6, 1), session(2026, 6, 2)]
        XCTAssertEqual(HangStats.currentStreakDays(sessions, now: now), 2)
    }

    func test_streak_breaksOnGap() {
        let now = date(2026, 6, 5, 12)
        let sessions = [session(2026, 6, 1), session(2026, 6, 4), session(2026, 6, 5)]
        // 4,5 consecutive = 2 (the 1st is separated by a gap).
        XCTAssertEqual(HangStats.currentStreakDays(sessions, now: now), 2)
    }

    func test_streak_zeroWhenNothingTodayOrYesterday() {
        let now = date(2026, 6, 5, 12)
        let sessions = [session(2026, 6, 1), session(2026, 6, 2)]
        // Last activity June 2; today is June 5 → no active streak.
        XCTAssertEqual(HangStats.currentStreakDays(sessions, now: now), 0)
    }

    // MARK: - Week / Year scoping

    func test_sessionsThisWeek_filtersToCurrentWeek() {
        // 2026-06-15 is a Monday. Week (Mon–Sun) = June 15–21.
        let now = date(2026, 6, 17, 12)
        let sessions = [
            session(2026, 6, 14),  // Sun before — excluded
            session(2026, 6, 15),  // Mon — in
            session(2026, 6, 17),  // Wed — in
            session(2026, 6, 22),  // next Mon — excluded
        ]
        let week = HangStats.sessionsThisWeek(sessions, now: now)
        XCTAssertEqual(week.count, 2)
    }

    func test_sessionsThisYear_filtersToCurrentYear() {
        let now = date(2026, 6, 17, 12)
        let sessions = [
            session(2025, 12, 31),
            session(2026, 1, 1),
            session(2026, 6, 17),
            session(2027, 1, 1),
        ]
        let year = HangStats.sessionsThisYear(sessions, now: now)
        XCTAssertEqual(year.count, 2)
    }

    // MARK: - Per-day lookup

    func test_sessionsOnDay_filtersCorrectDay() {
        let sessions = [
            session(2026, 6, 1, seconds: 10),
            session(2026, 6, 1, seconds: 20),
            session(2026, 6, 2, seconds: 5),
        ]
        let key = sessions[0].dayKey()
        let onDay = HangStats.sessions(on: key, in: sessions)
        XCTAssertEqual(onDay.count, 2)
        XCTAssertEqual(HangStats.totalSeconds(onDay), 30)
    }
}
