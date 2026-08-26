import SwiftUI

/// Day / Week / Year history browser. Within "Day", sessions expand by the hour
/// they happened so the user can see "9am: 30s, 6pm: 20s".
struct HistoryView: View {

    @EnvironmentObject private var store: HangSessionStore

    enum Scope: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        case year = "Year"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .day
    @State private var anchorDate: Date = Date()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                BarChartView(bars: chartBars, accent: chartAccent)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                List {
                    scopeSection
                }
                .listStyle(.plain)
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: stepBackward) {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Previous \(scope.rawValue)")
                }
                ToolbarItem(placement: .principal) {
                    Text(anchorTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: stepForward) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(atOrAfterToday)
                    .accessibilityLabel("Next \(scope.rawValue)")
                }
            }
        }
    }

    // MARK: - Sections per scope

    @ViewBuilder
    private var scopeSection: some View {
        switch scope {
        case .day:   daySection
        case .week:  weekSection
        case .year:  yearSection
        }
    }

    // MARK: - Chart data per scope

    /// Bars for the chart, matching the selected scope's granularity.
    /// Bar ids are stable strings (not UUID) so re-renders preserve identity
    /// and the chart animates instead of flashing on every refresh.
    private var chartBars: [BarChartView.Bar] {
        let sessions = sessionsForCurrentScope()
        switch scope {
        case .day:
            // One bar per active hour, labelled "9a", "6p" etc.
            let hourly = Dictionary(grouping: sessions, by: { hourOfDay($0.date) })
            return hourly.sorted { $0.key < $1.key }.map { (hour, items) in
                let total = items.reduce(0) { $0 + $1.totalSeconds }
                return BarChartView.Bar(id: "h\(hour)",
                                         value: Double(total),
                                         label: hourLabel(hour),
                                         valueLabel: "\(total)s")
            }
        case .week:
            // One bar per day Mon–Sun of the anchor week.
            var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 2
            guard let weekRange = cal.dateInterval(of: .weekOfYear, for: anchorDate) else { return [] }
            let weekdaySymbols = ["M", "T", "W", "T", "F", "S", "S"]
            var bars: [BarChartView.Bar] = []
            for i in 0..<7 {
                guard let day = cal.date(byAdding: .day, value: i, to: weekRange.start) else { continue }
                let dayInterval = cal.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86400)
                let total = sessions.filter { dayInterval.contains($0.date) }
                                    .reduce(0) { $0 + $1.totalSeconds }
                bars.append(BarChartView.Bar(id: "d\(i)",
                                             value: Double(total),
                                             label: weekdaySymbols[i],
                                             valueLabel: total > 0 ? "\(total)s" : nil))
            }
            return bars
        case .year:
            // One bar per month Jan–Dec. id is the month number for stability.
            var bars: [BarChartView.Bar] = []
            let year = Calendar.current.component(.year, from: anchorDate)
            let symbols = Calendar.current.shortMonthSymbols
            for m in 1...12 {
                let total = sessions.filter {
                    Calendar.current.component(.year, from: $0.date) == year &&
                    Calendar.current.component(.month, from: $0.date) == m
                }.reduce(0) { $0 + $1.totalSeconds }
                bars.append(BarChartView.Bar(id: "m\(m)",
                                             value: Double(total),
                                             label: String(symbols[m - 1].prefix(1)),
                                             valueLabel: total > 0 ? formatSeconds(total) : nil))
            }
            return bars
        }
    }

    private var chartAccent: Color {
        switch scope {
        case .day:  return .neonBlue
        case .week: return .successGreen
        case .year: return .energyOrange
        }
    }

    private var daySection: some View {
        // Group the day's sessions by hour (ascending). Each row shows the hour,
        // the sessions in it, and the running total.
        let sessions = sessionsForCurrentScope()
        let hourly = Dictionary(grouping: sessions, by: { hourOfDay($0.date) })
            .sorted { $0.key < $1.key }

        return Group {
            if sessions.isEmpty {
                emptyRow
            } else {
                ForEach(hourly, id: \.key) { hour, items in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(hourLabel(hour))
                                .font(.subheadline.bold())
                            Spacer()
                            Text(formatSeconds(items.reduce(0) { $0 + $1.totalSeconds }))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        ForEach(items) { session in
                            HStack {
                                Text(timeOfDay(session.date))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(session.reps) sets · \(session.totalSeconds)s")
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var weekSection: some View {
        let days = dailyBreakdown(for: sessionsForCurrentScope())
        return Group {
            if days.isEmpty { emptyRow }
            else {
                ForEach(days, id: \.day) { entry in
                    HStack {
                        Text(entry.day.description.dropFirst(5)) // "06-16"
                            .font(.subheadline)
                        Spacer()
                        Text("\(entry.totalSeconds)s · \(entry.reps) sets")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var yearSection: some View {
        // Aggregate by month.
        let sessions = sessionsForCurrentScope()
        let monthly = Dictionary(grouping: sessions, by: { monthLabel($0.date) })
            .sorted { $0.key < $1.key }
        return Group {
            if sessions.isEmpty { emptyRow }
            else {
                ForEach(monthly, id: \.key) { month, items in
                    HStack {
                        Text(month)
                            .font(.subheadline.bold())
                        Spacer()
                        Text(formatSeconds(items.reduce(0) { $0 + $1.totalSeconds }))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var emptyRow: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "leaf")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("No hangs yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 24)
            Spacer()
        }
    }

    // MARK: - Filtering + formatting helpers

    private func sessionsForCurrentScope() -> [HangSession] {
        let calendar = Calendar(identifier: .gregorian)
        switch scope {
        case .day:
            guard let day = calendar.dateInterval(of: .day, for: anchorDate) else { return [] }
            return store.allSessions.filter { day.contains($0.date) }
        case .week:
            var cal = calendar; cal.firstWeekday = 2
            guard let week = cal.dateInterval(of: .weekOfYear, for: anchorDate) else { return [] }
            return store.allSessions.filter { week.contains($0.date) }
        case .year:
            return HangStats.sessionsThisYear(store.allSessions, now: anchorDate)
        }
    }

    private struct DailyEntry { let day: HangSession.DayKey; let totalSeconds: Int; let reps: Int }

    private func dailyBreakdown(for sessions: [HangSession]) -> [DailyEntry] {
        let groups = Dictionary(grouping: sessions, by: { $0.dayKey() })
        return groups
            .map { (day, items) in
                DailyEntry(day: day,
                           totalSeconds: items.reduce(0) { $0 + $1.totalSeconds },
                           reps: items.reduce(0) { $0 + $1.reps })
            }
            .sorted { $0.day < $1.day }
    }

    private var anchorTitle: String {
        let f = DateFormatter()
        switch scope {
        case .day:
            f.dateStyle = .medium
        case .week:
            f.dateStyle = .medium
        case .year:
            f.dateFormat = "yyyy"
        }
        return f.string(from: anchorDate)
    }

    private func stepBackward() {
        shift(by: -1)
    }

    private func stepForward() {
        shift(by: 1)
    }

    private var atOrAfterToday: Bool {
        anchorDate >= Calendar.current.startOfDay(for: Date())
    }

    private func shift(by delta: Int) {
        let calendar = Calendar.current
        let component: Calendar.Component = scope == .day ? .day : (scope == .week ? .weekOfYear : .year)
        if let next = calendar.date(byAdding: component, value: delta, to: anchorDate) {
            anchorDate = next
        }
    }

    private func hourOfDay(_ date: Date) -> Int {
        Calendar.current.component(.hour, from: date)
    }

    private func hourLabel(_ hour: Int) -> String {
        let h = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        let ampm = hour < 12 ? "AM" : "PM"
        return "\(h) \(ampm)"
    }

    private func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }

    private func monthLabel(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f.string(from: date)
    }

    private func formatSeconds(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
