import Foundation

/// Generates coherent demo datasets so History/Stats/Garden all show non-empty,
/// interlinked content out of the box.
///
/// IMPORTANT: this is DEBUG-only demo scaffolding. Data is written through the
/// real `HangSessionStore.replaceAll`, so it flows through the exact same path
/// as genuine watch-synced sessions — every view reads from the same store and
/// updates together. Use the in-app reset button, or `store.clear()`, to return
/// to a clean slate.
///
/// Three spans are offered so you can see History's day/week/year scopes, the
/// bar chart, and long-term Garden growth all light up.
enum SeedData {

    enum Span: String, CaseIterable, Identifiable {
        case threeWeeks = "3 weeks"
        case oneYear    = "1 year"
        case twoYears   = "2 years"
        var id: String { rawValue }

        var dayCount: Int {
            switch self {
            case .threeWeeks: return 21
            case .oneYear:    return 365
            case .twoYears:   return 730
            }
        }
    }

    /// Deterministic pseudo-random generator so the same span always yields the
    /// same dataset (stable across launches, reproducible in tests). Uses a
    /// simple linear-congruential generator — good enough for demo data.
    private struct LCG {
        private var state: UInt64
        init(seed: UInt64 = 0x1234_5678_DEAD_BEEF) { state = seed }
        mutating func next() -> Double {
            // Numerical Recipes constants.
            state = 6364136223846793005 &* state &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Generate a progressive history covering `span`.
    ///
    /// Design goals:
    /// - Sessions ramp up over time (10s early → 60s recently) so Garden growth
    ///   is visible and the recent bar-chart bars are taller.
    /// - Most days have 1 session, ~25% have 2 (so History's hourly breakdown
    ///   shows multiple rows some days).
    /// - Recent ~5 days are always present (live streak); earlier history has
    ///   occasional gaps (broken-then-restarted streaks).
    /// - Always includes today.
    static func sessions(span: Span, now: Date = Date(),
                         calendar: Calendar = Calendar(identifier: .gregorian)) -> [HangSession] {
        var rng = LCG()
        var out: [HangSession] = []
        let totalDays = span.dayCount

        for daysAgo in stride(from: totalDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo,
                                           to: calendar.startOfDay(for: now)) else { continue }

            // The most recent 5 days are always active (live streak). Older days
            // skip ~20% of the time to create gaps.
            let isActiveDay = daysAgo < 5 || rng.next() > 0.2
            guard isActiveDay else { continue }

            // 1 or 2 sessions this day.
            let sessionCount = rng.next() < 0.25 ? 2 : 1

            // Progress factor 0 (oldest) → 1 (today): ramps duration & reps.
            let progress = 1.0 - (Double(daysAgo) / Double(max(totalDays, 1)))
            for s in 0..<sessionCount {
                let hour = s == 0 ? Int(rng.next() * 3) + 7       // morning ~7-9
                                  : Int(rng.next() * 3) + 18      // evening ~18-20
                let minute = Int(rng.next() * 59)
                var comps = calendar.dateComponents([.year, .month, .day], from: day)
                comps.hour = hour
                comps.minute = minute
                guard let date = calendar.date(from: comps) else { continue }

                let seconds = Int(10 + progress * 50)               // 10s → 60s
                let reps = max(1, seconds / 10)
                out.append(HangSession(date: date, reps: reps, totalSeconds: seconds))
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    /// Write a demo dataset into the given store (replaces existing data).
    static func load(span: Span, into store: HangSessionStore, now: Date = Date()) {
        store.replaceAll(sessions(span: span, now: now))
    }

    /// Convenience: load the default 3-week sample.
    static func load(into store: HangSessionStore, now: Date = Date()) {
        load(span: .threeWeeks, into: store, now: now)
    }

    // Back-compat: the original 3-week generator used by older tests/callers.
    static func sessions(now: Date = Date(),
                         calendar: Calendar = Calendar(identifier: .gregorian)) -> [HangSession] {
        sessions(span: .threeWeeks, now: now, calendar: calendar)
    }
}
