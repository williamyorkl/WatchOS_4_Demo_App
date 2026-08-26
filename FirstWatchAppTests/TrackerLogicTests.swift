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
    //
    // detectThreshold is now a SINGLE settle tick: the pose was already
    // confirmed by MotionStateMachine (detecting 0.8 s + confirmed 0.2 s), so
    // the old second 3 s detection layer was pure uncounted overhead (fix #3).

    func test_tick_detectingPhase_transitionsToHolding_afterOneTick() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        XCTAssertEqual(logic.holdPhase, .detecting)
        XCTAssertEqual(logic.detectSeconds, 0)

        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.detectSeconds, 1)
        XCTAssertEqual(logic.holdPhase, .holding, "After 1 tick (detectThreshold=1), should transition to holding")
        XCTAssertEqual(logic.holdSeconds, 0, "holdSeconds should reset to 0 on transition")
    }

    func test_detectingPhase_progressIsCorrect() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        XCTAssertEqual(logic.progress, 0, "Detecting starts at 0%")

        // The settle window is one tick; verify the progress math directly
        // (the transition to holding happens on the same tick).
        logic.holdPhase = .detecting
        logic.detectSeconds = TrackerLogic.detectThreshold
        XCTAssertEqual(logic.progress, 100.0, accuracy: 0.1,
                       "The 1-tick settle window reads as full confirmation progress")
    }

    // MARK: - Holding Phase Counting

    func test_tick_holdingPhase_incrementsHoldSeconds() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        for _ in 0..<1 { logic.tick(motionIsActive: true) }   // settle → holding
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
        for _ in 0..<1 { logic.tick(motionIsActive: true) }   // settle → holding

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
        for _ in 0..<1 { logic.tick(motionIsActive: true) }   // settle → holding

        for _ in 0..<7 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.totalHoldTime, 7)

        for _ in 0..<3 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.totalHoldTime, 10, "totalHoldTime should be 10 after one full rep")
    }

    func test_holdingPhase_progressIsCorrect() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        for _ in 0..<1 { logic.tick(motionIsActive: true) }   // settle → holding

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

    func test_resumedActive_afterLongRest_setsDetecting_freshSet() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        logic.tick(motionIsActive: true)  // → holding
        logic.tick(motionIsActive: true)  // holdSeconds = 1
        logic.apply(event: .enteredPaused)
        XCTAssertEqual(logic.holdPhase, .waiting)

        // Real rest (gap beyond the regrip grace) restarts the set.
        logic.apply(event: .resumedActive(gap: TrackerLogic.regripGraceSeconds + 1))

        XCTAssertEqual(logic.holdPhase, .detecting, "Long rest must re-enter detection for a fresh set")
        XCTAssertEqual(logic.detectSeconds, 0)
    }

    func test_resumedActive_quickRegrip_continuesSameSet() {
        // Fix #4: a quick regrip (drop, chalk, re-grab within the grace
        // window) must NOT throw away the in-progress set. Old behaviour: the
        // set reset to zero, so 8 s + regrip + 8 s still counted nothing.
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        logic.tick(motionIsActive: true)  // → holding
        for _ in 0..<8 { logic.tick(motionIsActive: true) }   // holdSeconds = 8
        XCTAssertEqual(logic.holdSeconds, 8)

        logic.apply(event: .enteredPaused)
        XCTAssertEqual(logic.holdPhase, .waiting)
        XCTAssertEqual(logic.holdSeconds, 8, "enteredPaused must PRESERVE holdSeconds pending the resume gap")

        logic.apply(event: .resumedActive(gap: 2.0))

        XCTAssertEqual(logic.holdPhase, .holding, "Quick regrip must resume the SAME set")
        XCTAssertEqual(logic.holdSeconds, 8, "The in-progress set continues where it left off")

        // Two more hanging seconds complete the rep that the old code lost.
        for _ in 0..<2 { _ = logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.reps, 1, "8 s + regrip + 2 s must complete the set")
    }

    func test_regripGraceBoundary() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        logic.tick(motionIsActive: true)
        for _ in 0..<5 { logic.tick(motionIsActive: true) }
        logic.apply(event: .enteredPaused)

        // Exactly at the grace boundary: still the same set.
        logic.apply(event: .resumedActive(gap: TrackerLogic.regripGraceSeconds))
        XCTAssertEqual(logic.holdPhase, .holding)

        // One second beyond: fresh set.
        logic.apply(event: .enteredPaused)
        logic.apply(event: .resumedActive(gap: TrackerLogic.regripGraceSeconds + 0.1))
        XCTAssertEqual(logic.holdPhase, .detecting)
    }

    func test_adoptMotionActive_reentersDetection() {
        // Fix #1's sibling: resuming a USER pause while still hanging must not
        // strand the counters in .waiting.
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.holdPhase, .holding)

        // Simulate a user pause: phase frozen mid-hold.
        // (User pause leaves holdPhase as-is in the engine; resuming while the
        // machine is still .active calls adoptMotionActive.)
        logic.holdPhase = .waiting

        logic.adoptMotionActive()
        XCTAssertEqual(logic.holdPhase, .detecting)
        XCTAssertEqual(logic.detectSeconds, 0)
    }

    // MARK: - Progress Calculation

    func test_progress_waitingState_isZero() {
        var logic = TrackerLogic()
        XCTAssertEqual(logic.progress, 0)
    }

    func test_progress_detectingIsCappedAt100() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.holdPhase, .holding, "Should have transitioned to holding after the settle tick")
        // Manually push detectSeconds past the threshold: progress must clamp.
        logic.holdPhase = .detecting
        logic.detectSeconds = 5
        XCTAssertEqual(logic.progress, 100.0, accuracy: 0.1,
                       "Detecting progress must clamp at 100, never exceed it")
    }

    // MARK: - Integration: Full Rep Cycle

    func test_fullRepCycle_settle1s_hold10s_rep() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)

        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.holdPhase, .holding, "After the 1-tick settle, should be holding")

        for _ in 0..<10 { logic.tick(motionIsActive: true) }
        XCTAssertEqual(logic.reps, 1, "After 10s holding, should have 1 rep")
        XCTAssertEqual(logic.holdSeconds, 0)
        XCTAssertEqual(logic.totalHoldTime, 10)
    }

    func test_multipleReps_accumulateCorrectly() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)

        logic.tick(motionIsActive: true)                     // settle
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

        for _ in 0..<1 { logic.tick(motionIsActive: true) }   // settle → holding
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

        // Resume after a LONG rest (gap beyond grace) → re-detect, fresh set
        logic.apply(event: .resumedActive(gap: TrackerLogic.regripGraceSeconds + 1))
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

        for _ in 0..<1 { logic.tick(motionIsActive: true) }   // settle → holding
        XCTAssertNotNil(logic.holdBand)
        XCTAssertEqual(logic.holdBand, .warming, "Just entered holding → warming")
    }

    func test_holdBand_progressesWithTicks() {
        var logic = TrackerLogic()
        logic.startSession()
        logic.apply(event: .enteredActive)
        for _ in 0..<1 { logic.tick(motionIsActive: true) }   // settle → holding, holdSeconds=0

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

    func test_finishCountdown_motionAlreadyActive_reentersDetection() {
        // Fix #1 regression guard: the user grabbed the bar DURING the 3-2-1
        // countdown (the countdown's entire purpose), so the motion machine
        // already emitted .enteredActive and sits in .active. The old
        // unconditional `holdPhase = .waiting` here stranded the counters
        // forever — no further transition event could ever arrive. The
        // reconciled finish must re-enter detection instead.
        var logic = TrackerLogic()
        logic.startCountdown()
        // Early grab: the event arrives while still counting down.
        logic.apply(event: .enteredActive)
        XCTAssertEqual(logic.holdPhase, .detecting)

        while !logic.tickCountdown() {}
        logic.finishCountdown(motionAlreadyActive: true)

        XCTAssertEqual(logic.sessionPhase, .active)
        XCTAssertEqual(logic.holdPhase, .detecting,
                       "Reconciliation must preserve detection for an already-confirmed hang")
        XCTAssertEqual(logic.detectSeconds, 0)

        // And counting proceeds normally from there.
        logic.tick(motionIsActive: true)
        XCTAssertEqual(logic.holdPhase, .holding)
    }

    func test_finishCountdown_withoutMotion_staysWaiting() {
        var logic = TrackerLogic()
        logic.startCountdown()
        while !logic.tickCountdown() {}
        logic.finishCountdown(motionAlreadyActive: false)

        XCTAssertEqual(logic.sessionPhase, .active)
        XCTAssertEqual(logic.holdPhase, .waiting,
                       "No grab yet → waiting until the motion pipeline confirms a hang")
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

        for _ in 0..<1 { logic.tick(motionIsActive: true) }   // settle → holding
        for _ in 0..<10 { logic.tick(motionIsActive: true) }  // hold → 1 rep
        XCTAssertEqual(logic.reps, 1)
        XCTAssertEqual(logic.totalHoldTime, 10)
    }
}
