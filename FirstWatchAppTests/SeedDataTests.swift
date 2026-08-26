import XCTest
@testable import FirstWatchApp

/// Verifies the demo datasets are internally coherent across all three spans,
/// so loading any span lights up History/Stats/Garden consistently.
final class SeedDataTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private var now: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 16; c.hour = 12
        return calendar.date(from: c)!
    }

    // MARK: - Common invariants (all spans)

    func test_allSpans_areNonEmpty() {
        for span in SeedData.Span.allCases {
            let s = SeedData.sessions(span: span, now: now)
            XCTAssertFalse(s.isEmpty, "\(span.rawValue) should produce data")
        }
    }

    func test_allSpans_includeToday() {
        let todayKey = HangSession(date: now, reps: 0, totalSeconds: 0).dayKey(calendar: calendar)
        for span in SeedData.Span.allCases {
            let s = SeedData.sessions(span: span, now: now)
            XCTAssertTrue(s.contains { $0.dayKey(calendar: calendar) == todayKey },
                          "\(span.rawValue) should include today for a live streak")
        }
    }

    func test_allSpans_sortedAscending() {
        for span in SeedData.Span.allCases {
            let s = SeedData.sessions(span: span, now: now)
            for i in 1..<s.count {
                XCTAssertLessThan(s[i - 1].date, s[i].date,
                                  "\(span.rawValue): sessions must be sorted ascending")
            }
        }
    }

    func test_allSpans_produceLiveStreak() {
        for span in SeedData.Span.allCases {
            let s = SeedData.sessions(span: span, now: now)
            let streak = HangStats.currentStreakDays(s, now: now, calendar: calendar)
            XCTAssertGreaterThanOrEqual(streak, 5,
                                        "\(span.rawValue): recent 5 days must form a streak")
        }
    }

    func test_allSpans_reachAtLeastSprout() {
        for span in SeedData.Span.allCases {
            let total = HangStats.totalSeconds(SeedData.sessions(span: span, now: now))
            let stage = HangGrowth.stage(forTotalSeconds: total)
            XCTAssertGreaterThanOrEqual(stage, .sprout,
                                        "\(span.rawValue): cumulative (\(total)s) should reach Sprout+")
        }
    }

    // MARK: - Span-specific coverage

    func test_threeWeeks_spansAboutThreeWeeks() {
        let s = SeedData.sessions(span: .threeWeeks, now: now)
        let days = calendar.dateComponents([.day], from: s.first!.date, to: s.last!.date).day ?? 0
        XCTAssertGreaterThanOrEqual(days, 18)
        XCTAssertLessThanOrEqual(days, 21)
    }

    func test_oneYear_spansMostOfYear() {
        let s = SeedData.sessions(span: .oneYear, now: now)
        let days = calendar.dateComponents([.day], from: s.first!.date, to: s.last!.date).day ?? 0
        XCTAssertGreaterThan(days, 330, "1-year span should cover most of a year")
    }

    func test_twoYears_spansAboutTwoYears() {
        let s = SeedData.sessions(span: .twoYears, now: now)
        let days = calendar.dateComponents([.day], from: s.first!.date, to: s.last!.date).day ?? 0
        XCTAssertGreaterThan(days, 660, "2-year span should cover ~2 years")
    }

    // MARK: - Determinism

    func test_sameSpan_isDeterministic() {
        // Same span + same now must yield identical data (so the demo is stable).
        let a = SeedData.sessions(span: .oneYear, now: now)
        let b = SeedData.sessions(span: .oneYear, now: now)
        XCTAssertEqual(a.map(\.date), b.map(\.date))
        XCTAssertEqual(a.map(\.totalSeconds), b.map(\.totalSeconds))
    }

    // MARK: - Variety (exercises History's hourly + multi-session rows)

    func test_someDaysHaveMultipleSessions() {
        for span in SeedData.Span.allCases {
            let groups = Dictionary(grouping: SeedData.sessions(span: span, now: now),
                                    by: { $0.dayKey(calendar: calendar) })
            let multi = groups.values.filter { $0.count > 1 }
            XCTAssertFalse(multi.isEmpty, "\(span.rawValue): some days should have 2 sessions")
        }
    }
}
