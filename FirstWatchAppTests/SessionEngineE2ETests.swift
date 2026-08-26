import XCTest
@testable import FirstWatchApp

/// END-TO-END tests: the `MotionSimulator` (physical behaviour) drives the
/// `SessionEngine` — the exact orchestration the watch app runs — through the
/// same two input streams production uses (60 Hz motion samples + 1 Hz timer
/// ticks). Every scenario below maps to one of the ten core-UX fixes and fails
/// on the pre-fix code.
final class SessionEngineE2ETests: XCTestCase {

    // MARK: - Harness
    //
    // Mirrors the ViewModel's wiring: ticks fire every 1 s from session start;
    // motion samples flow between ticks.

    final class EngineHarness {
        var engine: SessionEngine
        private let epoch = Date(timeIntervalSinceReferenceDate: 700_000)
        private var nextTick: TimeInterval = 1.0

        private(set) var haptics: [SessionEngine.HapticKind] = []
        private(set) var completedSessions: [HangSession] = []
        private(set) var learnedPoses: [GravityVector] = []
        private(set) var lastDraft: HangSessionDraft?
        private(set) var draftUpdatedCount = 0
        private(set) var draftClearedCount = 0
        private(set) var stateChangedTimes: [TimeInterval] = []
        private(set) var phaseLog: [(t: TimeInterval, phase: TrackerLogic.HoldPhase)] = []

        init(poseProfile: HangPoseProfile = .default) {
            engine = SessionEngine(poseProfile: poseProfile)
        }

        func date(_ t: TimeInterval) -> Date { epoch.addingTimeInterval(t) }

        func begin(at t: TimeInterval = 0) {
            apply(engine.begin(now: date(t)), at: t)
            nextTick = t + 1.0
        }

        func cancel(at t: TimeInterval) {
            apply(engine.cancel(now: date(t)), at: t)
        }

        func end(at t: TimeInterval) {
            apply(engine.end(now: date(t)), at: t)
        }

        func feed(_ samples: [MotionSimulator.Sample]) {
            for s in samples {
                while nextTick <= s.t {
                    apply(engine.secondTick(now: date(nextTick)), at: nextTick)
                    nextTick += 1.0
                }
                apply(engine.motionSample(x: s.x, y: s.y, z: s.z, at: date(s.t)), at: s.t)
            }
        }

        func tick(to endTime: TimeInterval) {
            while nextTick <= endTime {
                apply(engine.secondTick(now: date(nextTick)), at: nextTick)
                nextTick += 1.0
            }
        }

        func stateChangedCount(after t: TimeInterval) -> Int {
            stateChangedTimes.filter { $0 > t }.count
        }

        private func apply(_ signals: [SessionEngine.Signal], at t: TimeInterval) {
            for signal in signals {
                switch signal {
                case .haptic(let kind): haptics.append(kind)
                case .repCompleted: break
                case .stateChanged: stateChangedTimes.append(t)
                case .draftUpdated(let draft):
                    lastDraft = draft
                    draftUpdatedCount += 1
                case .draftCleared: draftClearedCount += 1
                case .sessionCompleted(let session): completedSessions.append(session)
                case .poseLearned(let gravity): learnedPoses.append(gravity)
                }
            }
            let phase = engine.snapshot().holdPhase
            if phaseLog.last?.phase != phase {
                phaseLog.append((t, phase))
            }
        }
    }

    private func firstHoldingTime(_ harness: EngineHarness) -> TimeInterval? {
        harness.phaseLog.first { $0.phase == .holding }?.t
    }

    // MARK: - Fix #1: grab during the countdown must count, not deadlock

    /// The countdown exists so the user can grab the bar during it — and that
    /// exact usage deadlocked the old pipeline (state machine already `.active`
    /// when `finishCountdown()` reset `holdPhase` to `.waiting`; no further
    /// event could ever arrive). Reconciliation must make early grabs count.
    func test_E2E_fix1_grabDuringCountdown_countsInsteadOfDeadlocking() {
        let harness = EngineHarness()
        var sim = MotionSimulator()               // authorDefault config
        sim.stand(duration: 0.3)                  // tap Start, arm down
        sim.reach(duration: 0.6)                  // grab the bar DURING 3-2-1 (0.3–0.9 s)
        sim.hang(duration: 25.1, swayDegrees: 8)  // hang on through 26 s
        harness.begin(at: 0)
        harness.feed(sim.samples())

        let snap = harness.engine.snapshot()
        XCTAssertEqual(snap.sessionPhase, .active)
        XCTAssertEqual(snap.holdPhase, .holding,
                       "Early grab must reach holding — the old code stayed in waiting forever")
        XCTAssertGreaterThanOrEqual(snap.reps, 2)
        XCTAssertGreaterThanOrEqual(snap.totalHoldTime, 20)

        harness.end(at: 26.0)
        guard harness.completedSessions.count == 1 else {
            return XCTFail("Expected exactly one completed session, got \(harness.completedSessions.count)")
        }
        XCTAssertEqual(harness.completedSessions[0].reps, snap.reps)
        XCTAssertEqual(harness.completedSessions[0].totalSeconds, snap.totalHoldTime)
    }

    // MARK: - Fix #2: any wearing style works — bootstrap, learn, persist

    /// A mirrored-wrist user's hang reads a gravity the default (legacy)
    /// reference can never match. Session 1 must self-heal via the bootstrap
    /// adoption; session 2 must detect instantly from the persisted profile.
    func test_E2E_fix2_mirroredWrist_bootstrapThenInstantDetectionNextSession() {
        let suiteName = "E2EFix2Pose-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // ── Session 1: default profile, mirrored-wrist physics ──
        let h1 = EngineHarness()
        var sim1 = MotionSimulator(config: .mirroredWrist)
        sim1.stand(duration: 3.0)
        sim1.reach(duration: 0.6)
        sim1.hang(duration: 20.4, swayDegrees: 5)
        h1.begin(at: 0)
        h1.feed(sim1.samples())

        XCTAssertFalse(h1.learnedPoses.isEmpty,
                       "The bootstrap must adopt the user's real hang pose")
        XCTAssertGreaterThanOrEqual(h1.engine.snapshot().totalHoldTime, 6,
                                    "After adoption the hang must actually count")
        h1.end(at: 24.0)
        XCTAssertEqual(h1.completedSessions.count, 1)

        // The ViewModel persists the learned pose; mirror that here.
        let poseStore = HangPoseProfileStore(defaults: defaults)
        poseStore.save(HangPoseProfile(hangGravity: h1.learnedPoses.last!))

        // ── Session 2: learned profile → instant detection, no bootstrap ──
        guard let profile = poseStore.load() else {
            return XCTFail("Learned pose must round-trip through storage")
        }
        let h2 = EngineHarness(poseProfile: profile)
        var sim2 = MotionSimulator(config: .mirroredWrist)
        sim2.stand(duration: 3.2)
        sim2.reach(duration: 0.6)
        sim2.hang(duration: 6.2, swayDegrees: 5)
        h2.begin(at: 0)
        h2.feed(sim2.samples())

        XCTAssertTrue(h2.learnedPoses.isEmpty,
                      "Configured users never hit the bootstrap path")
        guard let holdingAt = firstHoldingTime(h2) else {
            return XCTFail("Learned profile must detect the mirrored-wrist hang")
        }
        XCTAssertLessThanOrEqual(holdingAt - 3.8, 2.6,
                                 "Second session detection must be as fast as the default config's")
        XCTAssertGreaterThanOrEqual(h2.engine.snapshot().totalHoldTime, 1)
    }

    /// A third wearing style (crown on the other side) must ALSO bootstrap —
    /// the fix is not accidentally tuned to one alternate config.
    func test_E2E_fix2_crownSwapped_bootstrapsToo() {
        let harness = EngineHarness()
        var sim = MotionSimulator(config: .crownSwapped)
        sim.stand(duration: 3.0)
        sim.reach(duration: 0.6)
        sim.hang(duration: 18.4, swayDegrees: 5)
        harness.begin(at: 0)
        harness.feed(sim.samples())

        XCTAssertFalse(harness.learnedPoses.isEmpty)
        XCTAssertGreaterThanOrEqual(harness.engine.snapshot().totalHoldTime, 4)
    }

    // MARK: - Fix #3: grab → counting latency ~2 s (was ~5–6 s)

    func test_E2E_fix3_grabToCounting_latencyUnder2Point6Seconds() {
        let harness = EngineHarness()
        var sim = MotionSimulator()
        sim.stand(duration: 3.2)              // countdown ends at 3.0
        sim.reach(duration: 0.6)              // hands on the bar at 3.8
        sim.hang(duration: 6.2, swayDegrees: 8)
        harness.begin(at: 0)
        harness.feed(sim.samples())

        guard let holdingAt = firstHoldingTime(harness) else {
            return XCTFail("Must reach holding")
        }
        // on-bar at 3.8 → holding no later than ~2.6 s later (state machine
        // 0.8 + 0.2 s, one settle tick, window-flush and tick jitter margin).
        XCTAssertLessThanOrEqual(holdingAt - 3.8, 2.6,
                                 "Detection overhead per grab must be ~2 s, not the old ~5 s")
        XCTAssertGreaterThanOrEqual(harness.engine.snapshot().totalHoldTime, 2)
    }

    // MARK: - Fix #4: quick regrip continues the set; long rest starts fresh

    func test_E2E_fix4_quickRegrip_completesTheSet() {
        let harness = EngineHarness()
        var sim = MotionSimulator()
        sim.stand(duration: 3.2)
        sim.reach(duration: 0.6)          // on bar 3.8
        sim.hang(duration: 8.2)           // ~8 s of hang
        sim.drop(duration: 0.5)           // off the bar
        sim.stand(duration: 1.3)          // brief rest (regrip)
        sim.reach(duration: 0.6)
        sim.hang(duration: 6.0)           // back on the bar
        harness.begin(at: 0)
        harness.feed(sim.samples())

        XCTAssertEqual(harness.engine.snapshot().reps, 1,
                       "8 s + quick regrip + 2 s must complete the set — the old code threw the set away on every drop")
        XCTAssertGreaterThanOrEqual(harness.engine.snapshot().totalHoldTime, 10)
    }

    func test_E2E_fix4_longRest_startsFreshSetButKeepsTotalTime() {
        let harness = EngineHarness()
        var sim = MotionSimulator()
        sim.stand(duration: 3.2)
        sim.reach(duration: 0.6)
        sim.hang(duration: 8.2)
        sim.drop(duration: 0.5)
        sim.stand(duration: 7.5)          // real rest, beyond the 4 s grace
        sim.reach(duration: 0.6)
        sim.hang(duration: 4.2)
        harness.begin(at: 0)
        harness.feed(sim.samples())

        XCTAssertEqual(harness.engine.snapshot().reps, 0,
                       "A long rest starts a fresh set — the earlier 8 s don't carry into a rep")
        XCTAssertGreaterThanOrEqual(harness.engine.snapshot().totalHoldTime, 8,
                                    "Hang TIME always accumulates regardless of set resets")
    }

    // MARK: - Fix #5: sway and shake spikes must not kill the set

    func test_E2E_fix5_swayAndShakeSpikes_doNotPauseCounting() {
        let harness = EngineHarness()
        var sim = MotionSimulator()
        sim.stand(duration: 3.2)
        sim.reach(duration: 0.6)
        sim.hang(duration: 6.0, swayDegrees: 28)   // hard body sway
        sim.shake(duration: 0.12, spikeG: 0.7)     // grip-adjustment spike
        sim.hang(duration: 6.0, swayDegrees: 28)
        sim.shake(duration: 0.12, spikeG: 0.7)
        sim.hang(duration: 8.0, swayDegrees: 28)
        harness.begin(at: 0)
        harness.feed(sim.samples())

        XCTAssertEqual(harness.haptics.filter { $0 == .stop }.count, 0,
                       "No enteredPaused may fire for sub-debounce sway/spikes")
        XCTAssertGreaterThanOrEqual(harness.engine.snapshot().reps, 1)
        XCTAssertEqual(harness.engine.snapshot().holdPhase, .holding)
    }

    // MARK: - Fix #8: crash recovery — an in-flight session can't vanish

    func test_E2E_fix8_crashRecovery_draftBecomesSession() {
        let draftSuite = "E2EFix8Draft-\(UUID().uuidString)"
        let storeSuite = "E2EFix8Store-\(UUID().uuidString)"
        let draftDefaults = UserDefaults(suiteName: draftSuite)!
        let storeDefaults = UserDefaults(suiteName: storeSuite)!
        defer {
            draftDefaults.removePersistentDomain(forName: draftSuite)
            storeDefaults.removePersistentDomain(forName: storeSuite)
        }

        // Hang ~10 s, then "crash": the app dies before the user ends the session.
        let harness = EngineHarness()
        var sim = MotionSimulator()
        sim.stand(duration: 3.2)
        sim.reach(duration: 0.6)
        sim.hang(duration: 10.2)
        harness.begin(at: 0)
        harness.feed(sim.samples())

        guard let draft = harness.lastDraft else {
            return XCTFail("A draft must be emitted continuously during the session")
        }
        XCTAssertGreaterThanOrEqual(draft.totalSeconds, 6)
        XCTAssertGreaterThanOrEqual(harness.draftUpdatedCount, 3,
                                    "The draft must track progress (not just be written once)")

        // Next launch: restore.
        draft.save(to: draftDefaults)
        let store = HangSessionStore(defaults: storeDefaults)
        let restored = HangSessionDraft.restore(into: store, defaults: draftDefaults)
        XCTAssertNotNil(restored, "A crashed session with real hang time must be restored")
        XCTAssertEqual(restored?.id, draft.id)
        XCTAssertEqual(restored?.totalSeconds, draft.totalSeconds)
        XCTAssertEqual(store.allSessions.count, 1)

        // Idempotent: the same draft can never double-write.
        draft.save(to: draftDefaults)
        XCTAssertNil(HangSessionDraft.restore(into: store, defaults: draftDefaults))
        XCTAssertEqual(store.allSessions.count, 1)

        // A nothing-happened draft is consumed but restores nothing.
        HangSessionDraft(id: UUID(), startedAt: Date(), reps: 0, totalSeconds: 0)
            .save(to: draftDefaults)
        XCTAssertNil(HangSessionDraft.restore(into: store, defaults: draftDefaults))
    }

    // MARK: - Fix #9: the countdown can be cancelled

    func test_E2E_fix9_countdownCancel_backsOutCleanly() {
        let harness = EngineHarness()
        var sim = MotionSimulator()
        sim.stand(duration: 1.4)              // user rethinks mid-countdown
        harness.begin(at: 0)
        harness.feed(sim.samples())
        XCTAssertEqual(harness.engine.snapshot().sessionPhase, .countdown)

        harness.cancel(at: 1.4)

        XCTAssertEqual(harness.engine.snapshot().sessionPhase, .idle)
        XCTAssertTrue(harness.completedSessions.isEmpty)
        XCTAssertEqual(harness.draftUpdatedCount, 1, "begin arms the draft")
        XCTAssertEqual(harness.draftClearedCount, 1, "cancel consumes it")
        XCTAssertFalse(harness.haptics.isEmpty)
    }

    // MARK: - Fix #10: no UI notification churn on unchanging samples

    func test_E2E_fix10_noUIChurnOnUnchangingSamples() {
        let harness = EngineHarness()
        var sim = MotionSimulator()
        sim.stand(duration: 4.0)              // countdown elapses, arm stays down
        sim.stand(duration: 2.0)              // 120 identical samples, nothing changes
        harness.begin(at: 0)
        harness.feed(sim.samples())

        XCTAssertEqual(harness.stateChangedCount(after: 4.0), 0,
                       "Samples that change nothing must not notify the UI — the old code re-synced 7 @Published properties at 60 Hz")
    }
}
