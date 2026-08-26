import Foundation

/// Shared constants for watch↔phone connectivity. Both targets compile this
/// file, so neither side has to reference a type defined only in the other.
enum HangConnectivity {
    /// Application-context key under which a JSON-encoded `HangSession` is
    /// exchanged over WatchConnectivity.
    static let sessionKey = "hangSession"
}
