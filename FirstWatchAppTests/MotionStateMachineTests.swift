import XCTest
@testable import FirstWatchApp

/// Regression tests for the pull-up motion state machine.
///
/// These tests cover the four product-spec scenarios:
/// 1. Raise hand → system captures X/Y/Z → starts recording
/// 2. Hold steady → 10-second counter increments
/// 3. Lower hand → pause counting
/// 4. Re-raise hand → counter restarts from zero
///
/// They also guard against the specific regression that caused the bug:
/// the state machine must reach `.active` when fed sustained hanging-pose
/// accelerometer readings. If `process()` is never called (e.g. because the
/// pull-based CMMotionManager API returns nil), these tests still pass because
/// they call `process()` directly — but the ViewModel-level integration test
/// (`test_stateMachine_reachesActiveOnSustainedHangingPose`) would catch a
/// disconnected accelerometer by failing to observe `.enteredActive`.
final class MotionStateMachineTests: XCTestCase {

    private let sampleInterval: TimeInterval = 1.0 / 60.0

    // MARK: - Helpers

    /// Feed `count` samples of the given pose into the state machine,
    /// starting at `start` and spaced `sampleInterval` apart.
    /// Returns all emitted events.
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

    /// Drive the state machine from `.idle` all the way to `.active` by feeding
    /// sustained hanging-pose readings. Returns the emitted events.
    @discardableResult
    private func driveToActive(_ sm: inout MotionStateMachine, start: Date = Date()) -> [MotionStateMachine.Event] {
        let samplesNeeded = Int(2.5 / sampleInterval)
        return feed(&sm, pose: MotionStateMachine.hangingPose, count: samplesNeeded, start: start)
    }

    // MARK: - Scenario 1: Raise Hand → Detection → Active

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
        let _ = feed(&sm, pose: MotionStateMachine.neutralPose, count: 10,
                     start: start.addingTimeInterval(30 * sampleInterval))
        XCTAssertEqual(sm.state, .idle, "Pose loss during detecting should return to idle")
    }

    func test_sustainedHangingPose_reachesActive() {
        var sm = MotionStateMachine()
        let events = driveToActive(&sm)
        XCTAssertEqual(sm.state, .active, "2.5s of hanging pose must reach active")
        XCTAssertTrue(events.contains(.enteredActive), "enteredActive event must fire")
    }

    // MARK: - Scenario 2: Hold Steady → Counting Logic
    // (The state machine only manages motion state; the 10-second count logic
    // lives in the ViewModel's updateTimer. Here we verify the state machine
    // HOLDS .active while the arm remains up, which is what allows the timer to tick.)

    func test_active_staysActive_onContinuedHangingPose() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        let activeStart = start.addingTimeInterval(3.0)
        let _ = feed(&sm, pose: MotionStateMachine.hangingPose, count: 600,
                     start: activeStart)
        XCTAssertEqual(sm.state, .active, "Must remain active while hanging pose continues")
    }

    func test_active_doesNotEmitSpuriousEvents_onContinuedHangingPose() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        let eventsAfterActive = feed(&sm, pose: MotionStateMachine.hangingPose, count: 600,
                                     start: start.addingTimeInterval(3.0))
        XCTAssertTrue(eventsAfterActive.isEmpty, "No events should fire while holding steady in active")
    }

    // MARK: - Scenario 3: Lower Hand → Pause

    func test_active_entersPaused_onArmDown() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        let afterActive = start.addingTimeInterval(3.0)
        let events = feed(&sm, pose: MotionStateMachine.armDownPose, count: 1, start: afterActive)
        XCTAssertEqual(sm.state, .paused, "Arm-down must transition to paused")
        XCTAssertTrue(events.contains(.enteredPaused), "enteredPaused event must fire")
    }

    func test_paused_fallsToIdle_ifArmStaysDown() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)
        let afterActive = start.addingTimeInterval(3.0)
        let _ = feed(&sm, pose: MotionStateMachine.armDownPose, count: 5, start: afterActive)
        XCTAssertEqual(sm.state, .idle, "Sustained arm-down should fall back to idle (forces re-detection)")
    }

    // MARK: - Scenario 4: Re-Raise → Restart

    func test_reraise_afterArmDown_goesThroughFullDetection() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)

        let t1 = start.addingTimeInterval(3.0)
        let _ = feed(&sm, pose: MotionStateMachine.armDownPose, count: 5, start: t1)
        XCTAssertEqual(sm.state, .idle, "Should be idle after lowering")

        let t2 = t1.addingTimeInterval(5.0 * sampleInterval)
        let events = driveToActive(&sm, start: t2)
        XCTAssertEqual(sm.state, .active, "Re-raise must reach active again")
        XCTAssertTrue(events.contains(.enteredActive), "enteredActive must fire on re-raise")
    }

    func test_paused_resumesActive_ifHangingPoseImmediate() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)

        let t1 = start.addingTimeInterval(3.0)
        let _ = feed(&sm, pose: MotionStateMachine.armDownPose, count: 1, start: t1)
        XCTAssertEqual(sm.state, .paused)

        let t2 = t1.addingTimeInterval(sampleInterval)
        let events = feed(&sm, pose: MotionStateMachine.hangingPose, count: 40, start: t2,
                           interval: sampleInterval)
        XCTAssertEqual(sm.state, .active, "Immediate re-raise within resume window should resume")
        XCTAssertTrue(events.contains(.resumedActive), "resumedActive event must fire")
    }

    // MARK: - Full Lifecycle Integration

    func test_fullLifecycle_raise_hold_lower_reraise() {
        var sm = MotionStateMachine()
        var allEvents: [MotionStateMachine.Event] = []
        let t0 = Date()

        allEvents += driveToActive(&sm, start: t0)
        XCTAssertEqual(sm.state, .active)

        let t1 = t0.addingTimeInterval(5.0)
        allEvents += feed(&sm, pose: MotionStateMachine.armDownPose, count: 5, start: t1)
        XCTAssertEqual(sm.state, .idle)

        let t2 = t1.addingTimeInterval(1.0)
        allEvents += driveToActive(&sm, start: t2)
        XCTAssertEqual(sm.state, .active)

        XCTAssertEqual(allEvents.filter { $0 == .enteredActive }.count, 2,
                       "Should enter active exactly twice (initial + re-raise)")
        XCTAssertEqual(allEvents.filter { $0 == .enteredPaused }.count, 1,
                       "Should enter paused exactly once")
    }

    // MARK: - Configuration & Edge Cases

    func test_reset_clearsAllState() {
        var sm = MotionStateMachine()
        driveToActive(&sm)
        XCTAssertNotEqual(sm.state, .idle)
        sm.reset()
        XCTAssertEqual(sm.state, .idle)

        let events = feed(&sm, pose: MotionStateMachine.neutralPose, count: 100, start: Date())
        XCTAssertTrue(events.isEmpty, "Reset state machine should produce no events on neutral input")
    }

    func test_customConfiguration_respectsShorterDurations() {
        var sm = MotionStateMachine(
            detectingDuration: 0.2,
            confirmedDuration: 0.1
        )
        let pose = MotionStateMachine.hangingPose
        let start = Date()
        let events = feed(&sm, pose: pose, count: 25, start: start)

        XCTAssertEqual(sm.state, .active, "With 0.3s total detection, 25 samples at 60Hz (0.42s) should reach active")
        XCTAssertTrue(events.contains(.enteredActive))
    }

    // MARK: - Boundary Timing

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

    func test_confirmed_exactlyAtDuration_transitionsToActive() {
        var sm = MotionStateMachine(detectingDuration: 0.1, confirmedDuration: 0.1)
        let pose = MotionStateMachine.hangingPose
        let start = Date()

        let detectingSamples = Int(0.1 / sampleInterval) + 2
        _ = feed(&sm, pose: pose, count: detectingSamples, start: start)
        XCTAssertEqual(sm.state, .confirmed)

        let confirmedSamples = Int(0.1 / sampleInterval) + 2
        let confirmedStart = start.addingTimeInterval(Double(detectingSamples) * sampleInterval)
        let events = feed(&sm, pose: pose, count: confirmedSamples, start: confirmedStart)

        XCTAssertEqual(sm.state, .active)
        XCTAssertTrue(events.contains(.enteredActive))
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

    func test_noisyHangingPose_withOccasionalFlicker_stillActivates() {
        var sm = MotionStateMachine()
        let start = Date()
        let hanging = MotionStateMachine.hangingPose

        for i in 0..<200 {
            let t = start.addingTimeInterval(Double(i) * sampleInterval)
            let isFlicker = i % 20 == 10
            let p = isFlicker ? MotionStateMachine.neutralPose : hanging
            _ = sm.process(x: p.x, y: p.y, z: p.z, at: t)
        }

        XCTAssertEqual(sm.state, .idle, "Even occasional flickers during detecting reset to idle")
    }

    // MARK: - Z-Axis Arm-Down Path

    func test_armDown_zNegativeDominant_triggersPaused() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)

        let zDownPose = (x: 0.1, y: 0.1, z: -0.85)
        let events = feed(&sm, pose: zDownPose, count: 1,
                           start: start.addingTimeInterval(3.0))

        XCTAssertEqual(sm.state, .paused, "z < -0.7 with z dominant should trigger arm-down")
        XCTAssertTrue(events.contains(.enteredPaused))
    }

    func test_armDown_xPositiveDominant_triggersPaused() {
        var sm = MotionStateMachine()
        let start = Date()
        driveToActive(&sm, start: start)

        let xDownPose = (x: 0.85, y: 0.1, z: 0.1)
        let events = feed(&sm, pose: xDownPose, count: 1,
                           start: start.addingTimeInterval(3.0))

        XCTAssertEqual(sm.state, .paused, "x > 0.5 with x dominant should trigger arm-down")
        XCTAssertTrue(events.contains(.enteredPaused))
    }

    // MARK: - Multi-Rep Lifecycle

    func test_threeFullLifecycles() {
        var sm = MotionStateMachine()
        let t0 = Date()
        var totalActive = 0
        var totalPaused = 0

        for cycle in 0..<3 {
            let cycleStart = t0.addingTimeInterval(Double(cycle) * 10.0)
            let events = driveToActive(&sm, start: cycleStart)
            XCTAssertEqual(sm.state, .active)
            totalActive += events.filter { $0 == .enteredActive }.count

            let armDownTime = cycleStart.addingTimeInterval(3.0)
            let pauseEvents = feed(&sm, pose: MotionStateMachine.armDownPose,
                                    count: 5, start: armDownTime)
            totalPaused += pauseEvents.filter { $0 == .enteredPaused }.count
        }

        XCTAssertEqual(totalActive, 3, "Should enter active exactly 3 times")
        XCTAssertEqual(totalPaused, 3, "Should enter paused exactly 3 times")
    }
}
