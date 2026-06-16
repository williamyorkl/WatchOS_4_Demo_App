import XCTest
@testable import FirstWatchApp

final class FirstWatchAppTests: XCTestCase {

    func test_motionStateMachineFixtures_areSelfConsistent() {
        let hanging = MotionStateMachine.hangingPose
        let magnitude = (hanging.x * hanging.x + hanging.y * hanging.y + hanging.z * hanging.z).squareRoot()
        XCTAssertGreaterThan(magnitude, 0.7, "Hanging pose magnitude should be in stability band")
        XCTAssertLessThan(magnitude, 1.3)

        XCTAssertTrue(abs(hanging.x) > abs(hanging.y), "Hanging pose: x should be dominant")
        XCTAssertTrue(abs(hanging.x) > abs(hanging.z))
        XCTAssertLessThan(hanging.x, -0.7, "Hanging pose: x should be < -0.7")

        let armDown = MotionStateMachine.armDownPose
        XCTAssertTrue(armDown.x > 0.5, "Arm-down pose: x should be > 0.5")

        let neutral = MotionStateMachine.neutralPose
        let neutralMag = (neutral.x * neutral.x + neutral.y * neutral.y + neutral.z * neutral.z).squareRoot()
        XCTAssertLessThan(neutralMag, 0.7, "Neutral pose magnitude should be outside stability band")
    }
}
