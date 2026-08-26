import SwiftUI

/// Headline stats: streak, this-week total (+ vs last week), all-time, bests.
///
/// Fixes applied:
/// - streak pluralisation bug ("1 day" vs "N days") + flame hides at 0.
/// - Sessions decoded ONCE per body render (cached in a let), not per-property.
/// - "This week vs last week" delta so the user sees progress/regression.
/// - Best day/session now show their date.
/// - Empty state guides new users instead of showing a wall of zeros.
struct StatsView: View {

    @EnvironmentObject private var store: HangSessionStore

    var body: some View {
        NavigationView {
            ScrollView {
                // Decode sessions once for the whole render. `allSessions`
                // decodes from disk each call; computing it in a `let` here
                // avoids N redundant JSON decodes when multiple tiles read it.
                let sessions = store.allSessions

                if sessions.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 16) {
                        streakCard(sessions: sessions)
                        weekSection(sessions: sessions)
                        allTimeSection(sessions: sessions)
                    }
                    .padding()
                }
            }
            .navigationTitle("Stats")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            Image(systemName: "leaf")
                .font(.system(size: 56))
                .foregroundColor(.successGreen)
            Text("No stats yet")
                .font(.title3.bold())
            Text("Complete a hang on your watch, or load demo data in the Garden tab, to see your stats grow here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Streak

    private func streakCard(sessions: [HangSession]) -> some View {
        let streak = HangStats.currentStreakDays(sessions)
        let isZero = streak == 0
        return HStack(spacing: 16) {
            Image(systemName: isZero ? "moon.zzz" : "flame.fill")
                .font(.system(size: 40))
                .foregroundColor(isZero ? .secondary : .energyOrange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(streak)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(streak == 1 ? "day streak" : "days streak")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    // MARK: - Week (with vs-last-week delta)

    private func weekSection(sessions: [HangSession]) -> some View {
        let thisWeek = HangStats.sessionsThisWeek(sessions)
        let lastWeekSeconds = secondsInPreviousWeek(sessions)
        let weekSeconds = HangStats.totalSeconds(thisWeek)
        let weekReps = HangStats.totalReps(thisWeek)
        let delta = weekSeconds - lastWeekSeconds

        return VStack(alignment: .leading, spacing: 12) {
            Text("This week")
                .font(.headline)

            HStack(spacing: 12) {
                statTile(title: "Total",
                         value: formatSeconds(weekSeconds),
                         subtitle: "\(weekReps) sets",
                         icon: "calendar",
                         color: .neonBlue)
                statTile(title: "vs last week",
                         value: formatDelta(delta),
                         subtitle: formatSeconds(lastWeekSeconds) + " last",
                         icon: delta >= 0 ? "arrow.up.right" : "arrow.down.right",
                         color: delta >= 0 ? .successGreen : .energyOrange)
            }
        }
    }

    /// Total seconds in the calendar week immediately before the current one.
    private func secondsInPreviousWeek(_ sessions: [HangSession]) -> Int {
        let cal = Calendar(identifier: .gregorian)
        var c = cal
        c.firstWeekday = 2
        guard let thisWeek = c.dateInterval(of: .weekOfYear, for: Date()),
              let prevStart = c.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start),
              let prevWeek = c.dateInterval(of: .weekOfYear, for: prevStart) else { return 0 }
        return sessions.filter { prevWeek.contains($0.date) }.reduce(0) { $0 + $1.totalSeconds }
    }

    private func formatDelta(_ delta: Int) -> String {
        if delta == 0 { return "same" }
        return (delta > 0 ? "+" : "") + formatSeconds(abs(delta))
    }

    // MARK: - All time

    private func allTimeSection(sessions: [HangSession]) -> some View {
        let bestDay = bestDayInfo(sessions)
        let bestSession = bestSessionInfo(sessions)

        return VStack(alignment: .leading, spacing: 12) {
            Text("All time")
                .font(.headline)

            HStack(spacing: 12) {
                statTile(title: "Total",
                         value: formatSeconds(HangStats.totalSeconds(sessions)),
                         subtitle: "\(HangStats.totalReps(sessions)) sets",
                         icon: "hourglass",
                         color: .successGreen)
                statTile(title: "Best day",
                         value: formatSeconds(bestDay.seconds),
                         subtitle: bestDay.dateLabel,
                         icon: "sun.max",
                         color: .energyOrange)
            }
            HStack(spacing: 12) {
                statTile(title: "Best session",
                         value: formatSeconds(bestSession.seconds),
                         subtitle: bestSession.dateLabel,
                         icon: "star",
                         color: .neonBlue)
                statTile(title: "Sessions",
                         value: "\(sessions.count)",
                         subtitle: nil,
                         icon: "list.bullet",
                         color: .purple)
            }
        }
    }

    /// (seconds, human date label) for the best calendar day.
    private func bestDayInfo(_ sessions: [HangSession]) -> (seconds: Int, dateLabel: String) {
        let groups = Dictionary(grouping: sessions, by: { $0.dayKey() })
        guard let best = groups.max(by: { a, b in
            a.value.reduce(0) { $0 + $1.totalSeconds } < b.value.reduce(0) { $0 + $1.totalSeconds }
        }) else { return (0, "") }
        let total = best.value.reduce(0) { $0 + $1.totalSeconds }
        let f = DateFormatter(); f.dateStyle = .medium
        // Reconstruct a date from the DayKey for the label.
        var c = DateComponents(); c.year = best.key.year; c.month = best.key.month; c.day = best.key.day
        let date = Calendar(identifier: .gregorian).date(from: c).map { f.string(from: $0) } ?? ""
        return (total, date)
    }

    /// (seconds, human date label) for the single best session.
    private func bestSessionInfo(_ sessions: [HangSession]) -> (seconds: Int, dateLabel: String) {
        guard let best = sessions.max(by: { $0.totalSeconds < $1.totalSeconds }) else {
            return (0, "")
        }
        let f = DateFormatter(); f.dateStyle = .medium
        return (best.totalSeconds, f.string(from: best.date))
    }

    // MARK: - Tile

    private func statTile(title: String, value: String, subtitle: String?,
                          icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: icon)
                    .foregroundColor(color)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func formatSeconds(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
