import SwiftUI

/// Shared colour palette for the hang tracker. Compiled into both the watch
/// extension and the iOS app so the phone UI can reuse the exact same greens /
/// oranges / blues as the watch ring without duplicating the RGB values.
///
/// (Previously these lived inline in the watch-only `PullUpTrackerView.swift`,
/// which made them invisible to the iOS target.)
extension Color {
    static let oledBlack = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let successGreen = Color(red: 0.133, green: 0.773, blue: 0.369)
    static let energyOrange = Color(red: 0.976, green: 0.451, blue: 0.086)
    static let neonBlue = Color(red: 0.0, green: 0.8, blue: 1.0)
    static let dangerRed = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let cardBackground = Color(red: 0.102, green: 0.102, blue: 0.102)
    static let cardBackgroundAlt = Color(red: 0.110, green: 0.110, blue: 0.118)
    static let subtleBorder = Color.white.opacity(0.05)
}
