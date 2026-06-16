import XCTest
@testable import FirstWatchApp

final class PullUpTrackerViewModelTests: XCTestCase {

    private let sampleInterval: TimeInterval = 1.0 / 60.0

    private func makeVM() -> PullUpTrackerViewModel {
        let vm = PullUpTrackerViewModel()
        vm.playHaptic = { _ in }
        return vm
    }

    @discardableResult
    private func driveToActive(_ vm: PullUpTrackerViewModel, start: Date = Date()) -> Date {
        let pose = MotionStateMachine.hangingPose
        let samplesNeeded = Int(2.5 / sampleInterval)
        for i in 0..<samplesNeeded {
            vm.processMotion(
                x: pose.x, y: pose.y, z: pose.z,
                at: start.addingTimeInterval(Double(i) * sampleInterval)
            )
        }
        return start
    }

    private func driveToPaused(_ vm: PullUpTrackerViewModel, start: Date) {
        let armDown = MotionStateMachine.armDownPose
        let pausedTime = start.addingTimeInterval(3.0)
        vm.processMotion(x: armDown.x, y: armDown.y, z: armDown.z, at: pausedTime)
    }

    private func resumeFromPaused(_ vm: PullUpTrackerViewModel, pausedAt: Date) {
        let pose = MotionStateMachine.hangingPose
        let resumeStart = pausedAt.addingTimeInterval(sampleInterval)
        for i in 0..<40 {
            vm.processMotion(
                x: pose.x, y: pose.y, z: pose.z,
                at: resumeStart.addingTimeInterval(Double(i) * sampleInterval)
            )
        }
    }

    // MARK: - Detecting Phase Counting

    func test_updateTimer_detectingPhase_incrementsDetectSeconds() {
        let vm = makeVM()
        driveToActive(vm)
        XCTAssertEqual(vm.holdState, .detecting)
        XCTAssertEqual(vm.detectSeconds, 0)

        vm.updateTimer()
        XCTAssertEqual(vm.detectSeconds, 1)

        vm.updateTimer()
        XCTAssertEqual(vm.detectSeconds, 2)
    }

    func test_updateTimer_detectingThreshold_transitionsToHolding() {
        let vm = makeVM()
        driveToActive(vm)

        vm.updateTimer()
        vm.updateTimer()
        XCTAssertEqual(vm.holdState, .detecting)

        vm.updateTimer()
        XCTAssertEqual(vm.holdState, .holding, "After 3 ticks (detectThreshold=3), should transition to holding")
        XCTAssertEqual(vm.holdSeconds, 0, "holdSeconds should reset to 0 on transition")
    }

    func test_detectingPhase_progressIsCorrect() {
        let vm = makeVM()
        driveToActive(vm)

        vm.updateTimer()
        XCTAssertEqual(vm.progress, 100.0 / 3.0, accuracy: 0.1, "1/3 = 33.3%")

        vm.updateTimer()
        XCTAssertEqual(vm.progress, 200.0 / 3.0, accuracy: 0.1, "2/3 = 66.7%")
    }

    // MARK: - Holding Phase Counting

    func test_updateTimer_holdingPhase_incrementsHoldSeconds() {
        let vm = makeVM()
        driveToActive(vm)
        for _ in 0..<3 { vm.updateTimer() }
        XCTAssertEqual(vm.holdState, .holding)

        vm.updateTimer()
        XCTAssertEqual(vm.holdSeconds, 1)

        vm.updateTimer()
        XCTAssertEqual(vm.holdSeconds, 2)
    }

    func test_updateTimer_holdingTarget_incrementsReps() {
        let vm = makeVM()
        driveToActive(vm)
        for _ in 0..<3 { vm.updateTimer() }

        for _ in 0..<10 { vm.updateTimer() }

        XCTAssertEqual(vm.reps, 1, "After 10s hold (targetHoldSeconds=10), reps should increment")
        XCTAssertEqual(vm.holdSeconds, 0, "holdSeconds resets after rep")
    }

    func test_updateTimer_holdingPhase_incrementsTotalHoldTime() {
        let vm = makeVM()
        driveToActive(vm)
        for _ in 0..<3 { vm.updateTimer() }

        for _ in 0..<7 { vm.updateTimer() }
        XCTAssertEqual(vm.totalHoldTime, 7)

        for _ in 0..<3 { vm.updateTimer() }
        XCTAssertEqual(vm.totalHoldTime, 10, "totalHoldTime should be 10 after one full rep")
    }

    func test_holdingPhase_progressIsCorrect() {
        let vm = makeVM()
        driveToActive(vm)
        for _ in 0..<3 { vm.updateTimer() }

        for _ in 0..<5 { vm.updateTimer() }
        XCTAssertEqual(vm.holdSeconds, 5)
        XCTAssertEqual(vm.progress, 50.0, accuracy: 0.1, "5/10 = 50%")
    }

    // MARK: - Guard Logic

    func test_updateTimer_ignoredWhenWaiting() {
        let vm = makeVM()
        XCTAssertEqual(vm.holdState, .waiting)

        vm.updateTimer()
        vm.updateTimer()
        vm.updateTimer()

        XCTAssertEqual(vm.detectSeconds, 0, "Waiting state should not increment any counter")
        XCTAssertEqual(vm.holdSeconds, 0)
        XCTAssertEqual(vm.reps, 0)
    }

    // MARK: - Session Lifecycle

    func test_startSession_setsActiveState() {
        let vm = makeVM()
        vm.startSession()
        vm.stopCountTimer()

        XCTAssertEqual(vm.sessionState, .active)
        XCTAssertEqual(vm.holdState, .waiting)
    }

    func test_startSession_resetsCounters() {
        let vm = makeVM()
        vm.reps = 5
        vm.detectSeconds = 2
        vm.holdSeconds = 8
        vm.totalHoldTime = 50

        vm.startSession()
        vm.stopCountTimer()

        XCTAssertEqual(vm.reps, 0)
        XCTAssertEqual(vm.detectSeconds, 0)
        XCTAssertEqual(vm.holdSeconds, 0)
        XCTAssertEqual(vm.totalHoldTime, 0)
    }

    func test_startSession_doubleCall_isNoOp() {
        let vm = makeVM()
        vm.startSession()
        vm.stopCountTimer()

        vm.reps = 5
        vm.detectSeconds = 99

        vm.startSession()

        XCTAssertEqual(vm.reps, 5, "Second startSession must not reset reps")
        XCTAssertEqual(vm.detectSeconds, 99, "Second startSession must not reset detectSeconds")
        vm.stopCountTimer()
    }

    func test_endSession_setsSummaryState() {
        let vm = makeVM()
        vm.startSession()
        vm.stopCountTimer()

        vm.endSession()

        XCTAssertEqual(vm.sessionState, .summary)
        XCTAssertEqual(vm.holdState, .waiting)
    }

    func test_backToIdle_resetsCounters() {
        let vm = makeVM()
        vm.startSession()
        vm.stopCountTimer()
        vm.reps = 5
        vm.totalHoldTime = 50

        vm.backToIdle()

        XCTAssertEqual(vm.sessionState, .idle)
        XCTAssertEqual(vm.reps, 0)
        XCTAssertEqual(vm.totalHoldTime, 0)
    }

    // MARK: - Event Handling via processMotion

    func test_hangingPose_triggersEnteredActive_setsDetecting() {
        let vm = makeVM()
        driveToActive(vm)

        XCTAssertEqual(vm.holdState, .detecting, "enteredActive should set holdState to detecting")
        XCTAssertEqual(vm.detectSeconds, 0, "enteredActive should reset detectSeconds")
    }

    func test_armDown_triggersEnteredPaused_setsWaiting() {
        let vm = makeVM()
        let t0 = driveToActive(vm)
        driveToPaused(vm, start: t0)

        XCTAssertEqual(vm.holdState, .waiting, "enteredPaused should set holdState to waiting")
    }

    func test_resumedActive_afterPause_setsDetecting() {
        let vm = makeVM()
        let t0 = driveToActive(vm)
        driveToPaused(vm, start: t0)
        XCTAssertEqual(vm.holdState, .waiting)

        resumeFromPaused(vm, pausedAt: t0.addingTimeInterval(3.0))

        XCTAssertEqual(vm.holdState, .detecting, "resumedActive should set holdState to detecting")
        XCTAssertEqual(vm.detectSeconds, 0, "resumedActive should reset detectSeconds")
    }

    // MARK: - Progress Calculation

    func test_progress_waitingState_isZero() {
        let vm = makeVM()
        XCTAssertEqual(vm.progress, 0)
    }

    func test_progress_detectingAtMax_is100() {
        let vm = makeVM()
        driveToActive(vm)
        vm.updateTimer()
        vm.updateTimer()

        XCTAssertEqual(vm.progress, 200.0 / 3.0, accuracy: 0.1)

        vm.updateTimer()
        XCTAssertEqual(vm.holdState, .holding, "Should have transitioned to holding")
    }

    // MARK: - Integration: Full Rep Cycle

    func test_fullRepCycle_detect3s_hold10s_rep() {
        let vm = makeVM()
        driveToActive(vm)

        for _ in 0..<3 { vm.updateTimer() }
        XCTAssertEqual(vm.holdState, .holding, "After 3s detecting, should be holding")

        for _ in 0..<10 { vm.updateTimer() }
        XCTAssertEqual(vm.reps, 1, "After 10s holding, should have 1 rep")
        XCTAssertEqual(vm.holdSeconds, 0)
        XCTAssertEqual(vm.totalHoldTime, 10)
    }

    func test_multipleReps_accumulateCorrectly() {
        let vm = makeVM()
        driveToActive(vm)

        for _ in 0..<3 { vm.updateTimer() }
        for _ in 0..<10 { vm.updateTimer() }
        XCTAssertEqual(vm.reps, 1)

        for _ in 0..<10 { vm.updateTimer() }
        XCTAssertEqual(vm.reps, 2, "Second rep after another 10s hold")
        XCTAssertEqual(vm.totalHoldTime, 20)

        for _ in 0..<10 { vm.updateTimer() }
        XCTAssertEqual(vm.reps, 3, "Third rep")
        XCTAssertEqual(vm.totalHoldTime, 30)
    }

    func test_fullCycleWithPause_resumeResetsDetectSeconds() {
        let vm = makeVM()
        let t0 = driveToActive(vm)

        for _ in 0..<3 { vm.updateTimer() }
        for _ in 0..<5 { vm.updateTimer() }
        XCTAssertEqual(vm.holdState, .holding)
        XCTAssertEqual(vm.holdSeconds, 5)

        driveToPaused(vm, start: t0)
        XCTAssertEqual(vm.holdState, .waiting)

        resumeFromPaused(vm, pausedAt: t0.addingTimeInterval(3.0))
        XCTAssertEqual(vm.holdState, .detecting)
        XCTAssertEqual(vm.detectSeconds, 0, "After resume, detectSeconds resets to 0")
    }
}
