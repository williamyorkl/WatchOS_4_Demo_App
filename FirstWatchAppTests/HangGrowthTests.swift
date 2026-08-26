import XCTest
@testable import FirstWatchApp

/// Tests for the gamification growth thresholds. Pins the exact second-boundaries
/// of each plant stage so the "grow a tree" journey can't silently shift.
final class HangGrowthTests: XCTestCase {

    // MARK: - Stage mapping

    func test_zeroSeconds_isSeed() {
        XCTAssertEqual(HangGrowth.stage(forTotalSeconds: 0), .seed)
    }

    func test_justBelowSprout_isSeed() {
        XCTAssertEqual(HangGrowth.stage(forTotalSeconds: 59), .seed)
    }

    func test_atSproutThreshold_isSprout() {
        XCTAssertEqual(HangGrowth.stage(forTotalSeconds: 60), .sprout)
    }

    func test_betweenSproutAndSapling_isSprout() {
        XCTAssertEqual(HangGrowth.stage(forTotalSeconds: 299), .sprout)
    }

    func test_atSapling_isSapling() {
        XCTAssertEqual(HangGrowth.stage(forTotalSeconds: 300), .sapling)
    }

    func test_atYoungTree() {
        XCTAssertEqual(HangGrowth.stage(forTotalSeconds: 900), .youngTree)
    }

    func test_atMatureTree() {
        XCTAssertEqual(HangGrowth.stage(forTotalSeconds: 1800), .matureTree)
    }

    func test_atBlossom() {
        XCTAssertEqual(HangGrowth.stage(forTotalSeconds: 3600), .blossom)
    }

    func test_wellPastBlossom_staysBlossom() {
        XCTAssertEqual(HangGrowth.stage(forTotalSeconds: 100000), .blossom)
    }

    // MARK: - Monotonic progression

    func test_stageProgressesMonotonicallyWithTime() {
        let totals = [0, 60, 300, 900, 1800, 3600, 7200]
        var stages = totals.map { HangGrowth.stage(forTotalSeconds: $0) }
        // Each must be >= the previous.
        for i in 1..<stages.count {
            XCTAssertLessThanOrEqual(stages[i - 1], stages[i],
                                     "Stage must never go down as total rises")
        }
        XCTAssertEqual(stages.first, .seed)
        XCTAssertEqual(stages.last, .blossom)
        // And every distinct threshold yields a distinct stage.
        stages = Set(stages).sorted()
        XCTAssertEqual(stages.count, 6, "All six stages should be reachable")
    }

    // MARK: - Distance to next stage

    func test_secondsToNext_fromZero_isFirstThreshold() {
        XCTAssertEqual(HangGrowth.secondsToNextStage(total: 0), 60)
    }

    func test_secondsToNext_midwayToSprout() {
        XCTAssertEqual(HangGrowth.secondsToNextStage(total: 40), 20)
    }

    func test_secondsToNext_atBlossom_isNil() {
        XCTAssertNil(HangGrowth.secondsToNextStage(total: 3600),
                     "Top stage has no next")
    }

    func test_secondsToNext_justBeforeBlossom() {
        XCTAssertEqual(HangGrowth.secondsToNextStage(total: 3599), 1)
    }

    // MARK: - Stage metadata

    func test_everyStage_hasNonEmptyLabelAndIcon() {
        for stage in HangGrowth.Stage.allCases {
            XCTAssertFalse(stage.label.isEmpty, "\(stage) needs a label")
            XCTAssertFalse(stage.iconName.isEmpty, "\(stage) needs an icon")
            XCTAssertFalse(stage.subtitle.isEmpty, "\(stage) needs a subtitle")
        }
    }

    func test_threshold_forSeed_isZero() {
        XCTAssertEqual(HangGrowth.threshold(for: .seed), 0)
    }

    func test_thresholds_roundTrip() {
        for stage in HangGrowth.Stage.allCases where stage != .seed {
            let t = HangGrowth.threshold(for: stage)
            XCTAssertEqual(HangGrowth.stage(forTotalSeconds: t), stage,
                           "Threshold for \(stage) should map back to \(stage)")
        }
    }

    // MARK: - Integration with real sessions

    func test_stage_fromAccumulatedSessions() {
        // 3 sessions of 30s each = 90s total → sprout.
        let sessions = [
            HangSession(reps: 3, totalSeconds: 30),
            HangSession(reps: 3, totalSeconds: 30),
            HangSession(reps: 3, totalSeconds: 30),
        ]
        let total = HangStats.totalSeconds(sessions)
        XCTAssertEqual(HangGrowth.stage(forTotalSeconds: total), .sprout)
    }
}
