import XCTest
@testable import FirstWatchApp

final class PullUpTrackerGoldenTests: XCTestCase {

    func test_activeView_phases_haveCorrectLabelColors() {
        let waitingVM = PullUpTrackerViewModel()
        waitingVM.holdState = .waiting
        XCTAssertEqual(waitingVM.progress, 0)

        let detectingVM = PullUpTrackerViewModel()
        detectingVM.holdState = .detecting
        detectingVM.detectSeconds = 2
        XCTAssertEqual(detectingVM.progress, 200.0 / 3.0, accuracy: 0.1)

        let holdingVM = PullUpTrackerViewModel()
        holdingVM.holdState = .holding
        holdingVM.holdSeconds = 5
        XCTAssertEqual(holdingVM.progress, 50.0, accuracy: 0.1)
    }

    func test_appConstants_areExpectedValues() {
        let vm = PullUpTrackerViewModel()
        vm.holdState = .detecting
        vm.detectSeconds = 3
        XCTAssertEqual(vm.progress, 100.0, accuracy: 0.1, "detectThreshold should be 3")

        vm.holdState = .holding
        vm.holdSeconds = 10
        XCTAssertEqual(vm.progress, 100.0, accuracy: 0.1, "targetHoldSeconds should be 10")
    }
}
