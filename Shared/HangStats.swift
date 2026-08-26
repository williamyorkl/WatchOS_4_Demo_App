import Foundation

/// Aggregate statistics over a list of hang sessions. Pure functions, fully
/// unit-testable, shared between the phone's Stats view, History view and the
/// gamification growth calc. Keeping the math here (not in views) means the
/// "best day", "streak", "weekly total" numbers can never silently drift.
enum HangStats {

    /// Total seconds across all sessions.
    static func totalSeconds(_ sessions: [HangSession]) -> Int {
        sessions.reduce(0) { $0 + $1.totalSeconds }
    }

    /// Total completed sets across all sessions.
    static func totalReps(_ sessions: [HangSession]) -> Int {
        sessions.reduce(0) { $0 + $1.reps }
    }

    /// Best single-day total (seconds). Returns 0 if no sessions.
    static func bestDaySeconds(_ sessions: [HangSession]) -> Int {
        let byDay = Dictionary(grouping: sessions, by: { $0.dayKey() })
        return byDay.values.map { $0.reduce(0) { $0 + $1.totalSeconds } }.max() ?? 0
    }

    /// Best single-session total (seconds). Returns 0 if no sessions.
    static func bestSessionSeconds(_ sessions: [HangSession]) -> Int {
        sessions.map(\.totalSeconds).max() ?? 0
    }

    /// Current consecutive-day streak ending today (or yesterday, so a streak
    /// isn't broken merely because the day is still young). A "day with
    /// activity" is any calendar day with ≥1 session.
    static func currentStreakDays(_ sessions: [HangSession],
                                  now: Date = Date(),
                                  calendar: Calendar = Calendar(identifier: .gregorian)) -> Int {
        let activeDays = Set(sessions.map { $0.dayKey(calendar: calendar) })
        guard !activeDays.isEmpty else { return 0 }

        var streak = 0
        var cursor = calendar.startOfDay(for: now)
        // Allow the streak to count if the user has hung today OR yesterday
        // (so checking the app at 9am before today's hang doesn't show 0).
        let todayKey = dayKey(for: cursor, calendar: calendar)
        let startedYesterday = !activeDays.contains(todayKey)
        if startedYesterday {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }

        while activeDays.contains(dayKey(for: cursor, calendar: calendar)) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return streak
    }

    /// Sessions that fall within the same calendar week (Mon–Sun) as `now`.
    static func sessionsThisWeek(_ sessions: [HangSession],
                                 now: Date = Date(),
                                 calendar: Calendar = Calendar(identifier: .gregorian)) -> [HangSession] {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        guard let weekRange = cal.dateInterval(of: .weekOfYear, for: now) else { return [] }
        return sessions.filter { weekRange.contains($0.date) }
    }

    /// Sessions that fall within the same calendar year as `now`.
    static func sessionsThisYear(_ sessions: [HangSession],
                                 now: Date = Date(),
                                 calendar: Calendar = Calendar(identifier: .gregorian)) -> [HangSession] {
        guard let yearRange = calYearInterval(now, calendar: calendar) else { return [] }
        return sessions.filter { yearRange.contains($0.date) }
    }

    /// Sessions on a specific calendar day.
    static func sessions(on day: HangSession.DayKey,
                         in sessions: [HangSession]) -> [HangSession] {
        sessions.filter { $0.dayKey() == day }
    }

    // MARK: - Helpers

    private static func dayKey(for date: Date, calendar: Calendar) -> HangSession.DayKey {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return HangSession.DayKey(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    private static func calYearInterval(_ date: Date, calendar: Calendar) -> DateInterval? {
        let c = calendar.dateComponents([.year], from: date)
        guard let year = c.year,
              let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else {
            return nil
        }
        let end = calendar.date(byAdding: .year, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }
}
