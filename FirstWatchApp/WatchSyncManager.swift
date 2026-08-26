import Foundation
import WatchConnectivity
import Combine

/// Receives hang sessions pushed from the watch over WatchConnectivity and folds
/// them into the shared `HangSessionStore`.
///
/// Design: the watch sends each completed session as a **userInfo transfer**
/// (FIFO queue, guaranteed delivery of every item). This replaced the old
/// application-context push, which is latest-wins: when the phone was
/// unreachable, completing sessions S1 then S2 silently dropped S1. The
/// application-context path is still handled for backward compatibility with
/// older watch builds. If the same session id arrives twice (WC can redeliver),
/// it is deduped.
///
/// Kept as an `ObservableObject` so SwiftUI views can show a "synced just now"
/// affordance. WC activation is idempotent and safe to call onAppear.
final class WatchSyncManager: NSObject, ObservableObject {

    /// Timestamp of the most recent session received from the watch (for UI).
    @Published var lastReceivedAt: Date?

    /// JSON-encoded `HangSession` arrives under this key in the user-info
    /// transfer / application context. Shared string with the watch sender
    /// (defined in `HangConnectivity` so the watch can reference it too).
    static var sessionKey: String { HangConnectivity.sessionKey }

    func start(store: HangSessionStore) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.store = store
        // Drain any context that arrived before activation.
        processApplicationContext(session.receivedApplicationContext, store: store)
    }

    private var store: HangSessionStore?

    private func processApplicationContext(_ context: [String: Any], store: HangSessionStore) {
        guard let payload = context[Self.sessionKey] as? [String: Any] else { return }
        ingest(payload: payload, into: store)
    }

    /// Decode, dedupe (by session id) and store one received session payload.
    /// Split out from the WCSession delegate methods (which can't be
    /// constructed in unit tests) so the receive path itself is testable.
    func ingest(payload: [String: Any], into store: HangSessionStore) {
        // Re-encode the dictionary to JSON Data and decode as HangSession, so we
        // reuse the Codable model rather than hand-parsing fields.
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let session = try? JSONDecoder().decode(HangSession.self, from: data) else {
            return
        }
        // Dedupe: if a session with this id is already stored, skip.
        if store.allSessions.contains(where: { $0.id == session.id }) { return }
        store.append(session)
        DispatchQueue.main.async { self.lastReceivedAt = Date() }
    }
}

extension WatchSyncManager: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // No-op: activation is fire-and-forget for context delivery.
    }

    /// Queued delivery from the watch — every completed session arrives here
    /// exactly once, in order, even if the phone was unreachable at the time.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let store = store else { return }
        guard let payload = userInfo[Self.sessionKey] as? [String: Any] else { return }
        ingest(payload: payload, into: store)
    }

    /// Backward compatibility with the old watch build's context push.
    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let store = store else { return }
        processApplicationContext(applicationContext, store: store)
    }

    // iOS-only: required to satisfy the protocol on the phone.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate to reconnect to the (possibly new) watch after a switch.
        WCSession.default.activate()
    }
}
