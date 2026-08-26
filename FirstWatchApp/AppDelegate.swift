import UIKit

/// Minimal UIApplicationDelegate for the SwiftUI app lifecycle.
///
/// The app is driven by `HangTrackerApp` (a SwiftUI `@main App`). This delegate
/// is wired in via `UIApplicationDelegateAdaptor` so we still get lifecycle hooks
/// (e.g. for the local-notification request) without reviving the old storyboard
/// plumbing.
class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }
}
