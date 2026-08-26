import SwiftUI
import WatchConnectivity

/// SwiftUI app lifecycle entry point for the Hang Tracker phone app.
///
/// Replaces the 2018 UIKit storyboard shell (`Main.storyboard` +
/// `ViewController`). The shared `HangSessionStore` is published into the
/// environment so HistoryView / StatsView / GardenView all read the same data
/// and refresh automatically when a session arrives from the watch.
@main
struct HangTrackerApp: App {

    // Keeps the old UIApplicationDelegate hooks available (notifications, etc.)
    // without reverting to the storyboard lifecycle.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var store = HangSessionStore()
    @StateObject private var sync = WatchSyncManager()
    @StateObject private var reminders = ReminderScheduler()
    @StateObject private var energy = EnergyCollector()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environmentObject(sync)
                .environmentObject(reminders)
                .environmentObject(energy)
                .onAppear {
                    sync.start(store: store)
                    scheduleReminderIfAuthorized()
                }
        }
    }

    /// Request notification permission on first launch; once granted, schedule
    /// the daily 8pm "haven't hung today" reminder. If the user denies, we
    /// simply skip scheduling (no nagging).
    private func scheduleReminderIfAuthorized() {
        reminders.requestAuthorization { granted in
            if granted {
                reminders.scheduleDaily(atHour: 20, minute: 0)
            }
        }
    }
}
