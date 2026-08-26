import XCTest
@testable import FirstWatchApp

/// Phone-side sync + storage coverage.
///
/// Fix #7: the watch now pushes each completed session as a `transferUserInfo`
/// item — a FIFO queue in which EVERY item is delivered — instead of the old
/// application-context snapshot (latest-wins: completing sessions S1 then S2
/// while the phone was unreachable silently dropped S1). These tests drive the
/// phone's receive path with exactly the payloads a queue replay produces.
final class SyncAndRecoveryTests: XCTestCase {

    private func makeStore() -> HangSessionStore {
        let suite = "SyncTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return HangSessionStore(defaults: defaults)
    }

    private func payload(for session: HangSession) -> [String: Any] {
        let data = try! JSONEncoder().encode(session)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// The regression for the silent drop: three sessions queued while the
    /// phone was unreachable must ALL arrive. (Under the old latest-wins
    /// context push, only the last one ever reached the phone.)
    func test_userInfoQueue_deliversAllQueuedSessions_inOrder() {
        let store = makeStore()
        let sync = WatchSyncManager()

        let queued = (0..<3).map { HangSession(reps: $0 + 1, totalSeconds: 10 * ($0 + 1)) }
        for session in queued {
            sync.ingest(payload: payload(for: session), into: store)
        }

        XCTAssertEqual(store.allSessions.count, 3, "Every queued session must be delivered")
        XCTAssertEqual(store.allSessions.map(\.totalSeconds), [10, 20, 30],
                       "Queue order must be preserved")
        XCTAssertEqual(store.allSessions.map(\.reps), [1, 2, 3])
    }

    func test_userInfoQueue_dedupesRedelivery() {
        let store = makeStore()
        let sync = WatchSyncManager()
        let session = HangSession(reps: 2, totalSeconds: 20)
        let sessionPayload = payload(for: session)

        sync.ingest(payload: sessionPayload, into: store)
        sync.ingest(payload: sessionPayload, into: store)   // WC redelivers on reconnect

        XCTAssertEqual(store.allSessions.count, 1)
        XCTAssertEqual(store.allSessions.first?.id, session.id)
    }

    func test_ingest_malformedPayload_isIgnored() {
        let store = makeStore()
        let sync = WatchSyncManager()

        sync.ingest(payload: ["junk": 1], into: store)
        sync.ingest(payload: ["unrelated": "value"], into: store)

        XCTAssertEqual(store.allSessions.count, 0)
    }

    // MARK: - Pose profile persistence (fix #2 storage)

    func test_poseProfileStore_roundTripsLearnedPose() {
        let suite = "PoseStore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HangPoseProfileStore(defaults: defaults)

        XCTAssertNil(store.load(), "Fresh storage has no profile — engine falls back to the default reference")

        let learned = HangPoseProfile(hangGravity: GravityVector(0.92, 0.08, -0.10).normalized())
        store.save(learned)
        let loaded = store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.hangGravity.x, learned.hangGravity.x, accuracy: 1e-9)
        XCTAssertEqual(loaded!.hangGravity.y, learned.hangGravity.y, accuracy: 1e-9)
        XCTAssertEqual(loaded!.hangGravity.z, learned.hangGravity.z, accuracy: 1e-9)

        store.clear()
        XCTAssertNil(store.load())
    }

    func test_defaultProfile_matchesLegacyReference() {
        // The out-of-the-box profile must preserve the legacy x-negative
        // behaviour, so the fix never regresses the configuration the original
        // hard-coded predicate supported.
        XCTAssertEqual(HangPoseProfile.default.hangGravity,
                       MotionStateMachine.defaultHangReference)
        var sm = MotionStateMachine(hangReference: HangPoseProfile.default.hangGravity)
        let pose = MotionStateMachine.hangingPose
        let start = Date()
        for i in 0..<90 {
            _ = sm.process(x: pose.x, y: pose.y, z: pose.z,
                           at: start.addingTimeInterval(Double(i) / 60.0))
        }
        XCTAssertEqual(sm.state, .active)
    }
}
