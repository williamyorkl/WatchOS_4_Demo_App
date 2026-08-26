import XCTest
@testable import FirstWatchApp

/// Regression tests for the reference-based motion state machine.
///
/// Product-spec scenarios under the new (fix #2 / #5) semantics:
/// 1. Grab bar → sustained hang-pose readings reach `.active` (~1 s)
/// 2. Hold steady → machine stays `.active` (the 1 Hz counter ticks elsewhere)
/// 3. Drop → pause only after a SUSTAINED clearly-not-hang window (debounced;
///    a single noisy sample or sway spike can no longer kill the set)
/// 4. Re-grab → `resumedActive(gap:)`; the gap drives set-continuity elsewhere
/// 5. Reference learning: detection works for ANY wearing style once the
///    reference is adopted — no hardcoded axis assumption
final class MotionStateMachineTests: XCTestCase {

    private let sampleInterval: TimeInterval = 1.0 / 60.0

    // MARK: - Helpers

    private func feed(
        _ sm: inout MotionStateMachine,
        pose: (x: Double, y: Double, z: Double),
        count: Int,
        start: Date,
        interval: TimeInterval? = nil
    ) -> [MotionStateMachine.Event] {
        let dt = interval ?? sampleInterval
        var events: [MotionStateMachine.Event] = []
        for i in 0..<count {
            let t = start.addingTimeInterval(Double(i) * dt)
            events.append(contentsOf: sm.process(x: pose.x, y: pose.y, z: pose.z, at: t))
        }
        return events
    }

    /// Drive from `.idle` to `.active` with sustained hanging-pose readings
    /// (detecting 0.8 s + confirmed 0.2 s + margin).
    @discardableResult
    private func driveToActive(_ sm: inout MotionStateMachine, start: Date = Date()) -> [MotionStateMachine.Event] {
        let samplesNeeded = Int(1.5 / sampleInterval)
        return feed(&sm, pose: MotionStateMachine.hangingPose, count: samplesNeeded, start: start)
    }

    /// Sustained arm-down long enough to cross the 0.4 s pause debounce
    /// (plus window-flush margin).
    @discardableResult
    private func dropToPaused(_ sm: inout MotionStateMachine, start: Date) -> [MotionStateMachine.Event] {
        feed(&sm, pose: MotionStateMachine.armDownPose, count: Int(1.0 / sampleInterval), start: start)
    }

    // MARK: - Scenario 1: Grab Bar → Detection → Active

    func test_idle_staysIdle_onNeutralPose() {
        var sm = MotionStateMachine()
        let _ = feed(&sm, pose: MotionStateMachine.neutralPose, count: 200, start: Date())
        XCTAssertEqual(sm.state, .idle, "Neutral pose should never leave idle")
    }

    func test_idle_entersDetecting_onHangingPose() {
        var sm = MotionStateMachine()
        let pose = MotionStateMachine.hangingPose
        let start = Date()
        _ = sm.process(x: pose.x, y: pose.y, z: pose.z, at: start)
        let _ = feed(&sm, pose: pose, count: 15, start: start.addingTimeInterval(sampleInterval))
        XCTAssertEqual(sm.state, .detecting, "Sustained hanging pose should enter detecting")
    }

    func test_briefFlicker_doesNotActivate() {
        var sm = MotionStateMachine()
        let pose = MotionStateMachine.hangingPose
        let start = Date()
        let _ = feed(&sm, pose: pose, count: 30, start: start)
        XCTAssertEqual(sm.state, .detecting)
        let _ = feed(&sm, pose: MotionStateMachine.neutralPose, count: 24,
                     start: start.addingTimeInterval(30 * sampleInterval))
        XCTAssertEqual(sm.state, .idle, "Pose loss during detecting should return to idle")
    }

    func test_sustainedHangingPose_reachesActive() {
        var sm = MotionStateMachine()
        let events = driveToActive(&sm)
        XCTAssertEqual(sm.state, .active, "~1.5s of hanging pose must reach active")
        XCTAssertTrue(events.contains(.enteredActive), "enteredActive event must fire")
    }

    // MARK: - Scenario 2: Hold Steady

    func test_active_staysActive_onContinuedHangingPose() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        let activeStart = start.addingTimeInterval(2.0)
        let _ = feed(&sm, pose: MotionStateMachine.hangingPose, count: 600,
                     start: activeStart)
        XCTAssertEqual(sm.state, .active, "Must remain active while hanging pose continues")
    }

    func test_active_doesNotEmitSpuriousEvents_onContinuedHangingPose() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        let eventsAfterActive = feed(&sm, pose: MotionStateMachine.hangingPose, count: 600,
                                     start: start.addingTimeInterval(2.0))
        XCTAssertTrue(eventsAfterActive.isEmpty, "No events should fire while holding steady in active")
    }

    // MARK: - Scenario 3: Drop → Debounced Pause

    func test_singleArmDownSample_doesNotPause() {
        // Fix #5 regression guard: the old machine paused on ONE raw sample that
        // matched a fixed arm-down axis predicate. Sway/noise spikes during a
        // hang must not kill the set.
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        let t = start.addingTimeInterval(2.0)
        _ = sm.process(x: MotionStateMachine.armDownPose.x,
                       y: MotionStateMachine.armDownPose.y,
                       z: MotionStateMachine.armDownPose.z, at: t)
        XCTAssertEqual(sm.state, .active, "A single arm-down sample is under the debounce and must not pause")
    }

    func test_briefNoiseBurst_doesNotPause() {
        // ~0.12 s of unstable readings (a shake/spike) stays under the 0.4 s
        // debounce → no pause.
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        let burstStart = start.addingTimeInterval(2.0)
        for i in 0..<7 {
            let t = burstStart.addingTimeInterval(Double(i) * sampleInterval)
            let spike = (i % 2 == 0) ? MotionStateMachine.armDownPose : MotionStateMachine.neutralPose
            _ = sm.process(x: spike.x, y: spike.y, z: spike.z, at: t)
        }
        let after = burstStart.addingTimeInterval(7 * sampleInterval)
        let _ = feed(&sm, pose: MotionStateMachine.hangingPose, count: 30, start: after)
        XCTAssertEqual(sm.state, .active, "A sub-debounce noise burst must not pause the hang")
    }

    func test_sustainedArmDown_pausesAfterDebounce() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        let events = dropToPaused(&sm, start: start.addingTimeInterval(2.0))
        XCTAssertEqual(sm.state, .paused, "Sustained arm-down must reach paused after the debounce")
        XCTAssertTrue(events.contains(.enteredPaused), "enteredPaused event must fire")
    }

    func test_paused_staysPaused_whileArmDown() {
        // The old machine fell back to .idle on the first non-hang sample while
        // paused. Paused is now terminal within a session — rest between sets
        // is part of the session; only ending the session leaves it.
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        dropToPaused(&sm, start: start.addingTimeInterval(2.0))
        let _ = feed(&sm, pose: MotionStateMachine.armDownPose, count: 300,
                     start: start.addingTimeInterval(3.5))
        XCTAssertEqual(sm.state, .paused, "Sustained arm-down keeps the machine paused, not idle")
    }

    // MARK: - Scenario 4: Re-Grab → Resumed with gap

    func test_regrip_resumesWithGap() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        dropToPaused(&sm, start: start.addingTimeInterval(2.0))

        // Re-grab after ~1 s off the bar (within the regrip grace).
        let regrabAt = start.addingTimeInterval(3.2)
        let events = feed(&sm, pose: MotionStateMachine.hangingPose, count: Int(1.0 / sampleInterval),
                          start: regrabAt)
        XCTAssertEqual(sm.state, .active, "Sustained re-grab must resume active")
        guard case .resumedActive(let gap)? = events.first(where: {
            if case .resumedActive = $0 { return true }
            return false
        }) else {
            return XCTFail("resumedActive(gap:) must fire on re-grab")
        }
        XCTAssertGreaterThan(gap, 0.5, "Gap must include the contiguous stability window")
        XCTAssertLessThan(gap, 2.0, "Gap should reflect the actual pause duration")
    }

    func test_singleFlicker_whilePaused_doesNotResume() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        dropToPaused(&sm, start: start.addingTimeInterval(2.0))

        // One hang-pose sample then arm-down again: resume requires a
        // CONTIGUOUS 0.5 s run, so a single flicker must not resume.
        let t = start.addingTimeInterval(3.5)
        _ = sm.process(x: MotionStateMachine.hangingPose.x,
                       y: MotionStateMachine.hangingPose.y,
                       z: MotionStateMachine.hangingPose.z, at: t)
        let _ = feed(&sm, pose: MotionStateMachine.armDownPose, count: 30,
                     start: t.addingTimeInterval(sampleInterval))
        XCTAssertEqual(sm.state, .paused, "A single flicker must not resume counting")
    }

    // MARK: - Full Lifecycle

    func test_fullLifecycle_grab_hold_drop_regrip() {
        var sm = MotionStateMachine()
        var allEvents: [MotionStateMachine.Event] = []
        let t0 = Date()

        allEvents += driveToActive(&sm, start: t0)
        XCTAssertEqual(sm.state, .active)

        let t1 = t0.addingTimeInterval(5.0)
        allEvents += dropToPaused(&sm, start: t1)
        XCTAssertEqual(sm.state, .paused)

        let t2 = t1.addingTimeInterval(2.0)
        allEvents += feed(&sm, pose: MotionStateMachine.hangingPose,
                          count: Int(1.0 / sampleInterval), start: t2)
        XCTAssertEqual(sm.state, .active)

        XCTAssertEqual(allEvents.filter { $0 == .enteredActive }.count, 1,
                       "Initial grab enters active exactly once")
        XCTAssertEqual(allEvents.filter { $0 == .enteredPaused }.count, 1,
                       "Should enter paused exactly once")
        XCTAssertEqual(allEvents.filter {
            if case .resumedActive = $0 { return true }
            return false
        }.count, 1, "Re-grab resumes exactly once")
    }

    func test_threeFullLifecycles() {
        var sm = MotionStateMachine()
        let t0 = Date()
        var totalActive = 0
        var totalPaused = 0
        var totalResumed = 0

        for cycle in 0..<3 {
            let cycleStart = t0.addingTimeInterval(Double(cycle) * 10.0)
            if cycle == 0 {
                totalActive += driveToActive(&sm, start: cycleStart)
                    .filter { $0 == .enteredActive }.count
            } else {
                totalResumed += feed(&sm, pose: MotionStateMachine.hangingPose,
                                     count: Int(1.0 / sampleInterval),
                                     start: cycleStart)
                    .filter { if case .resumedActive = $0 { return true }; return false }.count
            }
            XCTAssertEqual(sm.state, .active)
            totalPaused += dropToPaused(&sm, start: cycleStart.addingTimeInterval(3.0))
                .filter { $0 == .enteredPaused }.count
        }

        XCTAssertEqual(totalActive, 1)
        XCTAssertEqual(totalPaused, 3)
        XCTAssertEqual(totalResumed, 2)
    }

    // MARK: - Reference Learning (fix #2)

    func test_customReference_detectsItsOwnPose() {
        // A wearing style whose hang gravity is +Y-dominant (e.g. mirrored
        // wrist): with that reference adopted, its pose is detected and the
        // legacy x-negative pose is not.
        let ref = GravityVector(0.05, -0.98, 0.15)
        var sm = MotionStateMachine(hangReference: ref)

        let events = feed(&sm, pose: (0.05, -0.98, 0.15), count: Int(1.5 / sampleInterval),
                          start: Date())
        XCTAssertEqual(sm.state, .active, "Reference-matched pose must reach active")
        XCTAssertTrue(events.contains(.enteredActive))

        var sm2 = MotionStateMachine(hangReference: ref)
        let _ = feed(&sm2, pose: MotionStateMachine.hangingPose,
                     count: Int(1.5 / sampleInterval), start: Date())
        XCTAssertEqual(sm2.state, .idle,
                       "A pose ~orthogonal to the reference must never activate")
    }

    func test_adoptHangReference_changesDetectionImmediately() {
        var sm = MotionStateMachine()
        driveToActive(&sm)
        sm.reset()

        let newPose = (x: 0.0, y: -0.95, z: 0.3)
        // Not detectable against the default reference…
        let _ = feed(&sm, pose: newPose, count: Int(1.5 / sampleInterval), start: Date())
        XCTAssertEqual(sm.state, .idle)

        // …until the reference is adopted.
        sm.adoptHangReference(GravityVector(newPose.x, newPose.y, newPose.z))
        let events = feed(&sm, pose: newPose, count: Int(1.5 / sampleInterval), start: Date())
        XCTAssertEqual(sm.state, .active)
        XCTAssertTrue(events.contains(.enteredActive))
    }

    func test_reset_keepsLearnedReference() {
        var sm = MotionStateMachine()
        sm.adoptHangReference(GravityVector(0, -1, 0))
        sm.reset()
        let events = feed(&sm, pose: (0, -1, 0), count: Int(1.5 / sampleInterval), start: Date())
        XCTAssertEqual(sm.state, .active, "Learned reference must survive a session reset")
        XCTAssertTrue(events.contains(.enteredActive))
    }

    func test_stableGravity_reportsCandidateAfterStabilityWindow() {
        var sm = MotionStateMachine()
        let start = Date()
        let pose = (x: 0.0, y: 1.0, z: 0.0)
        // 1 s of stability: below the 2 s adoption window.
        let _ = feed(&sm, pose: pose, count: Int(1.0 / sampleInterval), start: start)
        XCTAssertNil(sm.stableGravity(at: start.addingTimeInterval(1.0)),
                     "Below the stability window there is no adoption candidate")
        // 2.1 s total: candidate available.
        let _ = feed(&sm, pose: pose, count: Int(1.2 / sampleInterval),
                     start: start.addingTimeInterval(1.0))
        let candidate = sm.stableGravity(at: start.addingTimeInterval(2.2))
        XCTAssertNotNil(candidate, "After 2 s of stability the candidate must be reported")
        XCTAssertEqual(candidate!.angle(to: GravityVector(0, 1, 0)), 0, accuracy: 2.0)
    }

    func test_stableGravity_nilWhenUnstable() {
        var sm = MotionStateMachine()
        let start = Date()
        // Alternating poses keep the averaged vector far from unit length.
        for i in 0..<Int(3.0 / sampleInterval) {
            let t = start.addingTimeInterval(Double(i) * sampleInterval)
            let pose = i % 2 == 0 ? (x: 0.0, y: 1.0, z: 0.0) : MotionStateMachine.neutralPose
            _ = sm.process(x: pose.x, y: pose.y, z: pose.z, at: t)
        }
        XCTAssertNil(sm.stableGravity(at: start.addingTimeInterval(3.0)),
                     "Unstable readings must never produce an adoption candidate")
    }

    // MARK: - Configuration & Boundaries

    func test_reset_clearsSessionState() {
        var sm = MotionStateMachine()
        driveToActive(&sm)
        XCTAssertNotEqual(sm.state, .idle)
        sm.reset()
        XCTAssertEqual(sm.state, .idle)

        let events = feed(&sm, pose: MotionStateMachine.neutralPose, count: 100, start: Date())
        XCTAssertTrue(events.isEmpty, "Reset state machine should produce no events on neutral input")
    }

    func test_detecting_exactlyAtDuration_doesNotTransition() {
        var sm = MotionStateMachine(detectingDuration: 0.2, confirmedDuration: 99.0)
        let pose = MotionStateMachine.hangingPose
        let start = Date()
        let exactCount = Int(0.2 / sampleInterval)

        _ = feed(&sm, pose: pose, count: exactCount, start: start)
        XCTAssertEqual(sm.state, .detecting, "At exactly detectingDuration, uses > not >=, so stays detecting")

        _ = sm.process(x: pose.x, y: pose.y, z: pose.z,
                       at: start.addingTimeInterval(Double(exactCount) * sampleInterval))
        XCTAssertEqual(sm.state, .confirmed, "One tick past duration should transition to confirmed")
    }

    // MARK: - Noise Rejection

    func test_alternatingPoses_neverReachesActive() {
        var sm = MotionStateMachine()
        let start = Date()

        for i in 0..<600 {
            let t = start.addingTimeInterval(Double(i) * sampleInterval)
            let pose = i % 2 == 0 ? MotionStateMachine.hangingPose : MotionStateMachine.neutralPose
            _ = sm.process(x: pose.x, y: pose.y, z: pose.z, at: t)
        }

        XCTAssertNotEqual(sm.state, .active, "Alternating hanging/neutral every tick should never sustain long enough to activate")
    }

    func test_singleFlickerDuringDetecting_isAbsorbedBySmoothing() {
        // Window-averaged detection (fix #5): one noisy sample must NOT knock
        // the machine out of detecting — the averaged pose barely moves.
        var sm = MotionStateMachine()
        let start = Date()
        let hanging = MotionStateMachine.hangingPose

        _ = feed(&sm, pose: hanging, count: 15, start: start)
        XCTAssertEqual(sm.state, .detecting)

        _ = sm.process(x: MotionStateMachine.neutralPose.x,
                       y: MotionStateMachine.neutralPose.y,
                       z: MotionStateMachine.neutralPose.z,
                       at: start.addingTimeInterval(15 * sampleInterval))
        XCTAssertEqual(sm.state, .detecting,
                       "A single flicker is absorbed by the sliding-window average")
    }

    func test_sustainedPoseLossDuringDetecting_resetsToIdle() {
        var sm = MotionStateMachine()
        let start = Date()
        let hanging = MotionStateMachine.hangingPose

        _ = feed(&sm, pose: hanging, count: 30, start: start)
        XCTAssertEqual(sm.state, .detecting)

        // ~0.4 s of arm-down flushes the window: the averaged pose rotates far
        // enough away that detecting resets.
        let _ = feed(&sm, pose: MotionStateMachine.armDownPose, count: 30,
                     start: start.addingTimeInterval(30 * sampleInterval))
        XCTAssertEqual(sm.state, .idle,
                       "Sustained pose loss during detecting must reset to idle")
    }

    // MARK: - Starting-pose gate (fix #2, mirrored-wrist false start)

    func test_initialPoseGate_blocksThePoseTheSessionStartedIn() {
        // A mirrored-wrist user's RESTING pose reads nearly the same gravity as
        // the default hang reference. With the gate armed to that rest pose,
        // standing still must NOT activate; reaching the (real) hang must.
        let rest = GravityVector(-0.92, -0.08, 0.10).normalized()   // ≈ default ref
        var sm = MotionStateMachine()                                // ref = (-0.92,-0.08,-0.10)
        sm.setInitialPoseGate(rest)

        // Standing: matches the reference (≈14°) but is the gated start pose.
        let _ = feed(&sm, pose: (rest.x, rest.y, rest.z),
                     count: Int(1.5 / sampleInterval), start: Date())
        XCTAssertEqual(sm.state, .idle,
                       "The pose the session started in must never count as a hang")

        // Leave the gate, then hang in the mirrored orientation.
        sm.setInitialPoseGate(nil)
        let hang = MotionSimulator.WornConfig.mirroredWrist.hangGravity
        _ = sm.adoptHangReference(hang) // engine's bootstrap would do this
        let events = feed(&sm, pose: (hang.x, hang.y, hang.z),
                          count: Int(1.5 / sampleInterval), start: Date().addingTimeInterval(5))
        XCTAssertEqual(sm.state, .active, "After the gate clears, the real hang must activate")
        XCTAssertTrue(events.contains(.enteredActive))
    }

    func test_reset_clearsTheGate() {
        var sm = MotionStateMachine()
        sm.setInitialPoseGate(GravityVector(0, 1, 0))
        sm.reset()
        XCTAssertNil(sm.initialPoseGate)
    }
}
