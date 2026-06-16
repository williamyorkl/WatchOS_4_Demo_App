import XCTest
@testable import FirstWatchApp

class PullUpTrackerViewTests: XCTestCase {
  func testInstantiationDoesNotCrash() {
    let _ = PullUpTrackerView()
    XCTAssertTrue(true)
  }
}
