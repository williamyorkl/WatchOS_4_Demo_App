import SwiftUI

/// Root tab bar: History, Stats, Garden.
struct RootTabView: View {

    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }
                .tag(0)

            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(1)

            GardenView()
                .tabItem { Label("Garden", systemImage: "leaf.fill") }
                .tag(2)
        }
        .accentColor(.successGreen)
        .onAppear { handleDebugLaunchArgs() }
    }

    /// DEBUG-only: when launched with `-loadDemo <span>` (e.g. via
    /// `simctl launch ... -loadDemo "1 year"`), auto-load that demo span and
    /// jump to the Garden tab so the scene can be screenshotted/inspected
    /// without manual tapping. No-op in release.
    #if DEBUG
    private func handleDebugLaunchArgs() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-loadDemo"), i + 1 < args.count else { return }
        let spanArg = args[i + 1]
        let span = SeedData.Span.allCases.first { $0.rawValue == spanArg } ?? .oneYear
        // Load via a transient store injected through the environment isn't
        // possible here (env objects are set in HangTrackerApp), so we write
        // directly to the standard store the app uses.
        SeedData.load(span: span, into: HangSessionStore())
        if args.contains("-goGarden") { selectedTab = 2 }
    }
    #endif
}
