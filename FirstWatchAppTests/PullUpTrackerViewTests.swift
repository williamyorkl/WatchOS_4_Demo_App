import XCTest
@testable import FirstWatchApp

final class PullUpTrackerViewTests: XCTestCase {

    func test_motionStateMachine_defaultState_isIdle() {
        let sm = MotionStateMachine()
        XCTAssertEqual(sm.state, .idle)
    }

    func test_motionStateMachine_reset_returnsToIdle() {
        var sm = MotionStateMachine()
        let pose = MotionStateMachine.hangingPose
        let start = Date()
        for i in 0..<200 {
            sm.process(x: pose.x, y: pose.y, z: pose.z,
                       at: start.addingTimeInterval(Double(i) * 0.01))
        }
        XCTAssertNotEqual(sm.state, .idle)
        sm.reset()
        XCTAssertEqual(sm.state, .idle)
    }
}
