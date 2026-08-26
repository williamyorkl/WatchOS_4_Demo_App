import XCTest
@testable import FirstWatchApp

/// Golden regression tests pinning the tracker's counting contract.
///
/// These previously targeted `PullUpTrackerViewModel`, which lives in the
/// watch-only `PullUpTrackerView.swift` and is therefore NOT visible to the
/// iOS test host. That made the whole test target fail to compile. They now
/// target the pure `TrackerLogic` value type — which encodes the exact same
/// constants and progress math — restoring the safety net without depending
/// on WatchKit / CoreMotion.
final class PullUpTrackerGoldenTests: XCTestCase {

    func test_progress_matchesViewModelContract() {
        var waiting = TrackerLogic()
        waiting.holdPhase = .waiting
        XCTAssertEqual(waiting.progress, 0)

        var detecting = TrackerLogic()
        detecting.holdPhase = .detecting
        detecting.detectSeconds = 2
        XCTAssertEqual(detecting.progress, 200.0 / 3.0, accuracy: 0.1)

        var holding = TrackerLogic()
        holding.holdPhase = .holding
        holding.holdSeconds = 5
        XCTAssertEqual(holding.progress, 50.0, accuracy: 0.1)
    }

    func test_appConstants_areExpectedValues() {
        var logic = TrackerLogic()
        logic.holdPhase = .detecting
        logic.detectSeconds = 3
        XCTAssertEqual(logic.progress, 100.0, accuracy: 0.1,
                       "detectThreshold should be \(TrackerLogic.detectThreshold)")

        logic.holdPhase = .holding
        logic.holdSeconds = 10
        XCTAssertEqual(logic.progress, 100.0, accuracy: 0.1,
                       "targetHoldSeconds should be \(TrackerLogic.targetHoldSeconds)")

        // Pin the magic constants explicitly so a future refactor can't silently
        // change them and break the rep cadence users have trained to.
        XCTAssertEqual(TrackerLogic.detectThreshold, 3)
        XCTAssertEqual(TrackerLogic.targetHoldSeconds, 10)
    }
}
