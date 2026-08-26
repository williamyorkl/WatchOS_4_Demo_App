import XCTest
@testable import FirstWatchApp

/// Comprehensive coverage for the pure counting pipeline.
///
/// These tests migrate the lifecycle/regression coverage that previously lived
/// in `PullUpTrackerViewModelTests.swift` — which could never compile because
/// `PullUpTrackerViewModel` is defined in the watch-only `PullUpTrackerView.swift`
/// and is invisible to the iOS test host. By targeting the platform-independent
/// `TrackerLogic` value type instead, we restore the safety net that protects
/// the **main counting flow** (detect → hold → rep, pause/resume, progress math)
/// without depending on CoreMotion / HealthKit / WatchKit.
///
/// Every assertion here mirrors the contract documented in
/// `PullUpTrackerViewModel` so a behavioural drift between the logic layer and
/// the ViewModel is caught immediately.
final class TrackerLogicTests: XCTestCase {

    // MARK: - Detecting Phase Counting

    func test_tick_detectingPhase_incrementsDetectSeconds() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)   // → detecting
        XCTAssertEqual(logic.holdPhase, .detecting)
        XCTAssertEqual(logic.detectSeconds, 0)

        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.detectSeconds, 1)

        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.detectSeconds, 2)
    }

    func test_tick_detectingThreshold_transitionsToHolding() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)

        logic.tick(motionIsActive: true)
        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.holdPhase, .detecting)

        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.holdPhase, .holding, "After 3 ticks (detectThreshold=3), should transition to holding")
        XCTAssertEqual(logic.holdSeconds, 0, "holdSeconds should reset to 0 on transition")
    }

    func test_detectingPhase_progressIsCorrect() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)

        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.progress, 100.0 / 3.0, accuracy: 0.1, "1/3 = 33.3%")

        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.progress, 200.0 / 3.0, accuracy: 0.1, "2/3 = 66.7%")
    }

    // MARK: - Holding Phase Counting

    func test_tick_holdingPhase_incrementsHoldSeconds() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        for _ in 0..<3 { logic.tick(motionIsActive: true) }   // → holding
        XCTAssertEqual(logic.holdPhase, .holding)

        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.holdSeconds, 1)

        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.holdSeconds, 2)
    }

    func test_tick_holdingTarget_incrementsReps_andSignals() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        for _ in 0..<3 { logic.tick(motionIsActive: true) }   // detecting → holding

        // 9 ticks: no rep yet
        for _ in 0..<9 {
            XCTAssertFalse(logic.tick(motionIsActive: true))
        }
        // 10th tick completes the rep and signals.
        let signaled = logic.tick(motionIsActive: true)
        XCTAssertTrue(signaled, "tick should return true when a rep completes")
        XCTAssertEqual(logic.reps, 1, "After 10s hold (targetHoldSeconds=10), reps should increment")
        XCTAssertEqual(logic.holdSeconds, 0, "holdSeconds resets after rep")
    }

    func test_tick_holdingPhase_incrementsTotalHoldTime() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        for _ in 0..<3 { logic.tick(motionIsActive: true) }   // → holding

        for _ in 0..<7 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.totalHoldTime, 7)

        for _ in 0..<3 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.totalHoldTime, 10, "totalHoldTime should be 10 after one full rep")
    }

    func test_holdingPhase_progressIsCorrect() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        for _ in 0..<3 { logic.tick(motionIsActive: true) }   // → holding

        for _ in 0..<5 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.holdSeconds, 5)
        XCTAssertEqual(logic.progress, 50.0, accuracy: 0.1, "5/10 = 50%")
    }

    // MARK: - Guard Logic

    func test_tick_ignoredWhenMotionNotActive() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)   // detecting

        // motionIsActive=false: must be a complete no-op (this is the guard
        // that previously lived in ViewModel.updateTimer).
        for _ in 0..<5 {
            XCTAssertFalse(logic.tick(motionIsActive: false))
        }
        XCTAssertEqual(logic.detectSeconds, 0, "Ticks must be ignored when motion is not active")
        XCTAssertEqual(logic.holdSeconds, 0)
        XCTAssertEqual(logic.reps, 0)
    }

    func test_tick_ignoredWhenWaiting() {
        var logic = TrackerLogic()
        logic.startSession()
        // No event applied → still .waiting
        XCTAssertEqual(logic.holdPhase, .waiting)

        for _ in 0..<3 { logic.tick(motionIsActive: true) }

        XCTAssertEqual(logic.detectSeconds, 0, "Waiting state should not increment any counter")
        XCTAssertEqual(logic.holdSeconds, 0)
        XCTAssertEqual(logic.reps, 0)
    }

    // MARK: - Session Lifecycle

    func test_startSession_setsActivePhase() {
        var logic = TrackerLogic()
        logic.startSession()
        XCTAssertEqual(logic.sessionPhase, .active)
        XCTAssertEqual(logic.holdPhase, .waiting)
    }

    func test_startSession_resetsCounters() {
        var logic = TrackerLogic()
        logic.reps = 5
        logic.detectSeconds = 2
        logic.holdSeconds = 8
        logic.totalHoldTime = 50

        logic.startSession()

        XCTAssertEqual(logic.reps, 0)
        XCTAssertEqual(logic.detectSeconds, 0)
        XCTAssertEqual(logic.holdSeconds, 0)
        XCTAssertEqual(logic.totalHoldTime, 0)
    }

    func test_endSession_setsSummaryPhase() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.endSession()
        XCTAssertEqual(logic.sessionPhase, .summary)
        XCTAssertEqual(logic.holdPhase, .waiting)
    }

    func test_backToIdle_resetsCounters() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.reps = 5
        logic.totalHoldTime = 50

        logic.backToIdle()

        XCTAssertEqual(logic.sessionPhase, .idle)
        XCTAssertEqual(logic.reps, 0)
        XCTAssertEqual(logic.totalHoldTime, 0)
    }

    // MARK: - Event Handling

    func test_enteredActive_setsDetecting() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)

        XCTAssertEqual(logic.holdPhase, .detecting, "enteredActive should set holdPhase to detecting")
        XCTAssertEqual(logic.detectSeconds, 0, "enteredActive should reset detectSeconds")
    }

    func test_enteredPaused_setsWaiting() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        logic.apply(event: .enteredPaused)

        XCTAssertEqual(logic.holdPhase, .waiting, "enteredPaused should set holdPhase to waiting")
    }

    func test_resumedActive_afterPause_setsDetecting() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        logic.apply(event: .enteredPaused)
        XCTAssertEqual(logic.holdPhase, .waiting)

        logic.apply(event: .resumedActive)

        XCTAssertEqual(logic.holdPhase, .detecting, "resumedActive should set holdPhase to detecting")
        XCTAssertEqual(logic.detectSeconds, 0, "resumedActive should reset detectSeconds")
    }

    // MARK: - Progress Calculation

    func test_progress_waitingState_isZero() {
        var logic = TrackerLogic()
        XCTAssertEqual(logic.progress, 0)
    }

    func test_progress_detectingAtMax_is100() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        logic.tick(motionIsActive: true)
        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.progress, 200.0 / 3.0, accuracy: 0.1)

        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.holdPhase, .holding, "Should have transitioned to holding")
    }

    // MARK: - Integration: Full Rep Cycle

    func test_fullRepCycle_detect3s_hold10s_rep() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)

        for _ in 0..<3 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.holdPhase, .holding, "After 3s detecting, should be holding")

        for _ in 0..<10 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.reps, 1, "After 10s holding, should have 1 rep")
        XCTAssertEqual(logic.holdSeconds, 0)
        XCTAssertEqual(logic.totalHoldTime, 10)
    }

    func test_multipleReps_accumulateCorrectly() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)

        for _ in 0..<3 { logic.tick(motionIsActive: true) }
        for _ in 0..<10 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.reps, 1)

        for _ in 0..<10 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.reps, 2, "Second rep after another 10s hold")
        XCTAssertEqual(logic.totalHoldTime, 20)

        for _ in 0..<10 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.reps, 3, "Third rep")
        XCTAssertEqual(logic.totalHoldTime, 30)
    }

    func test_fullCycleWithPause_resumeResetsDetectSeconds() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)

        for _ in 0..<3 { logic.tick(motionIsActive: true) }   // → holding
        for _ in 0..<5 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.holdPhase, .holding)
        XCTAssertEqual(logic.holdSeconds, 5)

        // Pause
        logic.apply(event: .enteredPaused)
        XCTAssertEqual(logic.holdPhase, .waiting)

        // While paused, the timer guard (motionIsActive=false) must freeze counts.
        for _ in 0..<10 { logic.tick(motionIsActive: false) }
        XCTAssertEqual(logic.reps, 0, "Paused ticks must not count toward a rep")
        XCTAssertEqual(logic.totalHoldTime, 5)

        // Resume → re-detect
        logic.apply(event: .resumedActive)
        XCTAssertEqual(logic.holdPhase, .detecting)
        XCTAssertEqual(logic.detectSeconds, 0, "After resume, detectSeconds resets to 0")
    }

    // MARK: - Hold Band (encouragement colour semantics)
    //
    // The band must INCREASE in positivity as progress rises (warming → cruising
    // → finishing), so the ring colour approaches green near a completed rep.
    // These guard against accidentally reverting to the old "red near completion"
    // alarm semantics.

    func test_band_progressBelow40_isWarming() {
        XCTAssertEqual(TrackerLogic.band(forHoldingProgress: 0), .warming)
        XCTAssertEqual(TrackerLogic.band(forHoldingProgress: 39.9), .warming)
    }

    func test_band_progress40to80_isCruising() {
        XCTAssertEqual(TrackerLogic.band(forHoldingProgress: 40), .cruising)
        XCTAssertEqual(TrackerLogic.band(forHoldingProgress: 79.9), .cruising)
    }

    func test_band_progressAtOrAbove80_isFinishing() {
        XCTAssertEqual(TrackerLogic.band(forHoldingProgress: 80), .finishing)
        XCTAssertEqual(TrackerLogic.band(forHoldingProgress: 100), .finishing)
    }

    func test_holdBand_isNilOutsideHolding() {
        var logic = TrackerLogic()
        logic.startSession()
        XCTAssertNil(logic.holdBand, "No band while waiting")

        logic.apply(event: .enteredActive)
        XCTAssertNil(logic.holdBand, "No band while detecting")

        for _ in 0..<3 { logic.tick(motionIsActive: true) }   // → holding
        XCTAssertNotNil(logic.holdBand)
        XCTAssertEqual(logic.holdBand, .warming, "Just entered holding → warming")
    }

    func test_holdBand_progressesWithTicks() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        for _ in 0..<3 { logic.tick(motionIsActive: true) }   // → holding, holdSeconds=0

        // progress = holdSeconds/10*100. 4 ticks → 40% → cruising boundary.
        for _ in 0..<4 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.holdBand, .cruising)

        // 8 ticks total → 80% → finishing boundary.
        for _ in 0..<4 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.holdBand, .finishing)
    }

    // MARK: - Countdown

    func test_startCountdown_setsPhaseAndValue() {
        var logic = TrackerLogic()
        logic.startCountdown()

        XCTAssertEqual(logic.sessionPhase, .countdown)
        XCTAssertEqual(logic.countdownValue, TrackerLogic.countdownSeconds,
                       "countdownValue should start at countdownSeconds (\(TrackerLogic.countdownSeconds))")
        XCTAssertEqual(logic.reps, 0, "Counters must be reset on countdown start")
        XCTAssertEqual(logic.holdPhase, .waiting)
    }

    func test_tickCountdown_decrementsAndSignalsAtZero() {
        var logic = TrackerLogic()
        logic.startCountdown()
        XCTAssertEqual(logic.countdownValue, 3)

        XCTAssertFalse(logic.tickCountdown())
        XCTAssertEqual(logic.countdownValue, 2)

        XCTAssertFalse(logic.tickCountdown())
        XCTAssertEqual(logic.countdownValue, 1)

        // 1 → 0: signals completion.
        XCTAssertTrue(logic.tickCountdown(), "Final countdown tick must signal completion")
        XCTAssertEqual(logic.countdownValue, 0)
    }

    func test_finishCountdown_transitionsToActive() {
        var logic = TrackerLogic()
        logic.startCountdown()
        while !logic.tickCountdown() {}
        logic.finishCountdown()

        XCTAssertEqual(logic.sessionPhase, .active)
        XCTAssertEqual(logic.holdPhase, .waiting)
        XCTAssertEqual(logic.reps, 0, "Counters stay reset across the countdown boundary")
    }

    func test_cancelCountdown_returnsToIdle() {
        var logic = TrackerLogic()
        logic.startCountdown()
        logic.tickCountdown()

        logic.cancelCountdown()

        XCTAssertEqual(logic.sessionPhase, .idle)
        XCTAssertEqual(logic.countdownValue, 0)
        XCTAssertEqual(logic.reps, 0)
    }

    func test_tickCountdown_ignoredOutsideCountdownPhase() {
        var logic = TrackerLogic()
        // Not in countdown phase → no-op.
        XCTAssertFalse(logic.tickCountdown())
        XCTAssertEqual(logic.countdownValue, 0)
    }

    func test_fullFlow_countdownThenActive() {
        // End-to-end: countdown elapses, then a normal hold/rep cycle runs.
        var logic = TrackerLogic()
        logic.startCountdown()
        for _ in 0..<TrackerLogic.countdownSeconds { _ = logic.tickCountdown() }
        logic.finishCountdown()

        XCTAssertEqual(logic.sessionPhase, .active)
        logic.apply(event: .enteredActive)

        for _ in 0..<3 { logic.tick(motionIsActive: true) }   // detecting → holding
        for _ in 0..<10 { logic.tick(motionIsActive: true) }  // hold → 1 rep
        XCTAssertEqual(logic.reps, 1)
        XCTAssertEqual(logic.totalHoldTime, 10)
    }
}
