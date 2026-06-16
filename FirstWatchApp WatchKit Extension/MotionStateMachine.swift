import Foundation

/// Pure-motion state machine for the pull-up tracker.
///
/// This struct has **zero platform dependencies** (no CoreMotion, WatchKit,
/// SwiftUI or UIKit) so it can be compiled into both the watchOS extension
/// target and the iOS host-app target, making it fully unit-testable from
/// `FirstWatchAppTests` via `@testable import FirstWatchApp`.
///
/// The state flow mirrors the product spec:
///
///     idle → detecting → confirmed → active ⇄ paused
///                                         ↓
///                                    (arm down → idle)
///
/// - `.detecting`: wrist has been raised; accumulate `detectingDuration` of
///   stable hanging-pose readings before trusting the gesture.
/// - `.confirmed`: short re-validation window (`confirmedDuration`) to reject
///   transient flickers.
/// - `.active`: arm is up; the ViewModel's count-timer is allowed to tick.
/// - `.paused`: arm was lowered; counting pauses until the wrist is raised
///   again (`pausedResumeDuration` of stable hanging pose resumes to `.active`).
///   If the arm stays down the machine falls back to `.idle`, forcing a full
///   re-detection on the next raise (per spec: "计数器重新开始").
struct MotionStateMachine {

    // MARK: - Types

    enum State: Equatable {
        case idle
        case detecting
        case confirmed
        case active
        case paused
    }

    /// Side-effecting transitions the ViewModel reacts to (haptics, hold-state, etc.).
    enum Event: Equatable {
        case enteredActive   // confirmed → active   : hand-raise accepted, start counting
        case enteredPaused   // active   → paused     : arm lowered, pause counting
        case resumedActive   // paused   → active     : re-raised, resume counting
    }

    // MARK: - Configuration

    private let windowSize: Int
    private let baselineMagnitude: Double
    private let magnitudeThreshold: Double
    private let detectingDuration: TimeInterval
    private let confirmedDuration: TimeInterval
    private let pausedResumeDuration: TimeInterval

    // MARK: - Mutable State

    private(set) var state: State = .idle
    private var stateStartTime: Date?
    private var slidingWindow: [Double] = []

    // MARK: - Init

    init(windowSize: Int = 10,
         baselineMagnitude: Double = 1.0,
         magnitudeThreshold: Double = 0.3,
         detectingDuration: TimeInterval = 1.5,
         confirmedDuration: TimeInterval = 0.5,
         pausedResumeDuration: TimeInterval = 0.5) {
        self.windowSize = windowSize
        self.baselineMagnitude = baselineMagnitude
        self.magnitudeThreshold = magnitudeThreshold
        self.detectingDuration = detectingDuration
        self.confirmedDuration = confirmedDuration
        self.pausedResumeDuration = pausedResumeDuration
    }

    // MARK: - Reset

    mutating func reset() {
        state = .idle
        stateStartTime = nil
        slidingWindow.removeAll()
    }

    // MARK: - Processing

    /// Feed one accelerometer sample into the state machine.
    ///
    /// - Parameters:
    ///   - x, y, z: Raw accelerometer acceleration values (G).
    ///   - timestamp: The time the sample was observed. Injected for deterministic tests.
    /// - Returns: Events the caller should react to (may be empty).
    @discardableResult
    mutating func process(x: Double, y: Double, z: Double, at timestamp: Date = Date()) -> [Event] {
        let magnitude = (x * x + y * y + z * z).squareRoot()

        slidingWindow.append(magnitude)
        if slidingWindow.count > windowSize {
            slidingWindow.removeFirst()
        }

        let avgMagnitude = slidingWindow.reduce(0, +) / Double(slidingWindow.count)
        let magnitudeStable = abs(avgMagnitude - baselineMagnitude) < magnitudeThreshold
        let xDominant = abs(x) > abs(y) && abs(x) > abs(z)
        let isHangingPose = magnitudeStable && xDominant && x < -0.7

        var events: [Event] = []

        switch state {
        case .idle:
            if isHangingPose {
                state = .detecting
                stateStartTime = timestamp
            }

        case .detecting:
            if isHangingPose {
                if let startTime = stateStartTime {
                    if timestamp.timeIntervalSince(startTime) > detectingDuration {
                        state = .confirmed
                        stateStartTime = timestamp
                    }
                }
            } else {
                state = .idle
                stateStartTime = nil
            }

        case .confirmed:
            if isHangingPose {
                if let startTime = stateStartTime {
                    if timestamp.timeIntervalSince(startTime) > confirmedDuration {
                        state = .active
                        stateStartTime = nil
                        events.append(.enteredActive)
                    }
                }
            } else {
                state = .idle
                stateStartTime = nil
            }

        case .active:
            if isArmDown(x: x, y: y, z: z) {
                state = .paused
                stateStartTime = timestamp
                events.append(.enteredPaused)
            }

        case .paused:
            if isHangingPose {
                if let startTime = stateStartTime {
                    if timestamp.timeIntervalSince(startTime) > pausedResumeDuration {
                        state = .active
                        stateStartTime = nil
                        events.append(.resumedActive)
                    }
                }
            } else {
                // Arm stayed down: fall back to idle so the next raise
                // re-runs the full detection pipeline (spec: 计数器重新开始).
                state = .idle
                stateStartTime = nil
            }
        }

        return events
    }

    // MARK: - Helpers

    private func isArmDown(x: Double, y: Double, z: Double) -> Bool {
        let xPositiveDominant = x > 0.5 && abs(x) > abs(y) && abs(x) > abs(z)
        let zNegativeDominant = z < -0.7 && abs(z) > abs(x) && abs(z) > abs(y)
        return xPositiveDominant || zNegativeDominant
    }
}

// MARK: - Test Fixtures

extension MotionStateMachine {
    /// Accelerometer reading that satisfies the "hanging pose" (wrist raised) predicate.
    /// `x` is strongly negative and dominant; overall magnitude sits near 1 G.
    static var hangingPose: (x: Double, y: Double, z: Double) {
        (-0.92, -0.08, -0.10)
    }

    /// Accelerometer reading that satisfies the "arm down" predicate.
    /// `x` is strongly positive and dominant.
    static var armDownPose: (x: Double, y: Double, z: Double) {
        (0.92, 0.08, 0.10)
    }

    /// Neutral reading that triggers neither hanging-pose nor arm-down.
    /// Magnitude ≈ 0.52 (outside the 0.7–1.3 stability band) so `isHangingPose`
    /// is guaranteed false; `x` and `z` are both weak so `isArmDown` is also false.
    static var neutralPose: (x: Double, y: Double, z: Double) {
        (0.3, 0.3, 0.3)
    }
}
