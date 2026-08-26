import Foundation

/// A 3-axis vector plus the small amount of math the pose detection needs.
/// `Codable` so a learned pose reference can be persisted between sessions.
struct GravityVector: Equatable, Codable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    var magnitude: Double {
        (x * x + y * y + z * z).squareRoot()
    }

    func normalized() -> GravityVector {
        let m = magnitude
        guard m > 1e-9 else { return self }
        return GravityVector(x / m, y / m, z / m)
    }

    func dot(_ other: GravityVector) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    /// Angle to another vector in degrees (0–180). Degenerate (zero-length)
    /// vectors report 180° — "maximally unlike" — so they can never match.
    func angle(to other: GravityVector) -> Double {
        let m1 = magnitude
        let m2 = other.magnitude
        guard m1 > 1e-9, m2 > 1e-9 else { return 180 }
        let cos = dot(other) / (m1 * m2)
        return acos(max(-1, min(1, cos))) * 180 / .pi
    }

    static let zero = GravityVector(0, 0, 0)
}

/// Pure-motion state machine for the hang tracker.
///
/// Zero platform dependencies (no CoreMotion, WatchKit, SwiftUI or UIKit) so it
/// compiles into the watchOS extension, the iOS app and the test target.
///
///     idle → detecting → confirmed → active ⇄ paused
///
/// Pose detection is **reference-based**, not axis-hardcoded: the machine is
/// initialised with (or learns) the gravity direction the accelerometer reads
/// *while this particular user hangs from a bar in their particular wearing
/// style* — left/right wrist, crown side, grip rotation all fold into that one
/// learned vector. A reading counts as "hanging" when the smoothed gravity
/// stays within `hangAngleTolerance` of that reference. This replaces the old
/// `x < -0.7 && xDominant` predicate, which only worked for one specific
/// wrist/crown/grip combination.
///
/// Robustness rules:
/// - Pause is **debounced**: leaving `.active` requires the pose to be clearly
///   not-hanging (or unstable) continuously for `pauseDebounceDuration`, so a
///   single noisy sample or a brief sway spike cannot kill the current set.
/// - Resume from `.paused` requires a *contiguous* run of hanging samples, so
///   one flicker doesn't restart counting.
/// - `.paused` is terminal within a session (no idle fallback): rest between
///   sets is a normal part of a session; only the session itself ends it.
struct MotionStateMachine {

    // MARK: - Types

    enum State: Equatable {
        case idle
        case detecting
        case confirmed
        case active
        case paused
    }

    /// Side-effecting transitions the caller reacts to (haptics, hold-state).
    /// `resumedActive` carries the pause `gap` so the counting logic can decide
    /// between "quick regrip — continue the current set" and "real rest —
    /// start a fresh set".
    enum Event: Equatable {
        case enteredActive
        case enteredPaused
        case resumedActive(gap: TimeInterval)
    }

    // MARK: - Configuration

    /// Smoothed-gravity window (≈0.2 s at 60 Hz).
    let windowSize: Int
    /// |length(averaged vector) − 1 G| must stay below this to count as stable.
    /// Averaging first makes dynamic spikes cancel out; a shaken or swinging
    /// wrist shrinks the averaged vector length below the band.
    let magnitudeTolerance: Double
    /// Angle to the hang reference within which a stable reading is a hang.
    let hangAngleTolerance: Double
    /// Angle beyond which a stable reading is clearly NOT a hang (hysteresis
    /// band between the two prevents flapping).
    let pauseAngleTolerance: Double
    let detectingDuration: TimeInterval
    let confirmedDuration: TimeInterval
    let pausedResumeDuration: TimeInterval
    /// Sustained clearly-not-hang time required before `enteredPaused` fires.
    let pauseDebounceDuration: TimeInterval
    /// How long a *stable* pose in any direction must persist before it can be
    /// adopted as a new hang reference (self-healing bootstrap for a wearing
    /// style the stored reference doesn't match).
    let adoptionStabilityDuration: TimeInterval
    /// Poses within this angle of `initialPoseGate` are NOT hanging. See below.
    let gateAngleTolerance: Double

    /// The gravity direction this session STARTED in (the user's arm at rest
    /// when they tapped Start), captured once stable during the countdown.
    ///
    /// Why: a static reading cannot distinguish "hanging" from "arm at side"
    /// for every wearing style — e.g. a mirrored-wrist user's RESTING pose
    /// reads nearly the same as the default hang reference. Blocking the
    /// session's starting pose (until the user demonstrably leaves it) kills
    /// that false start without needing to tell the two apart.
    private(set) var initialPoseGate: GravityVector?

    /// The gravity direction that means "hanging" for this user/device.
    private(set) var hangReference: GravityVector

    // MARK: - Mutable State

    private(set) var state: State = .idle
    private var stateStartTime: Date?
    private var notHangSince: Date?
    private var hangStreakSince: Date?
    private var stableSince: Date?
    private var slidingWindow: [GravityVector] = []
    /// Window-averaged gravity — the smoothed signal all decisions use.
    private(set) var smoothedGravity: GravityVector = .zero

    // MARK: - Init

    /// Default reference preserves the legacy behaviour (x strongly negative)
    /// for devices/wearing styles that matched the original hard-coded axis.
    static let defaultHangReference = GravityVector(-0.92, -0.08, -0.10).normalized()

    init(hangReference: GravityVector = MotionStateMachine.defaultHangReference,
         windowSize: Int = 12,
         magnitudeTolerance: Double = 0.25,
         hangAngleTolerance: Double = 45,
         pauseAngleTolerance: Double = 70,
         detectingDuration: TimeInterval = 0.8,
         confirmedDuration: TimeInterval = 0.2,
         pausedResumeDuration: TimeInterval = 0.5,
         pauseDebounceDuration: TimeInterval = 0.4,
         adoptionStabilityDuration: TimeInterval = 2.0,
         gateAngleTolerance: Double = 60) {
        self.hangReference = hangReference.normalized()
        self.windowSize = windowSize
        self.magnitudeTolerance = magnitudeTolerance
        self.hangAngleTolerance = hangAngleTolerance
        self.pauseAngleTolerance = pauseAngleTolerance
        self.detectingDuration = detectingDuration
        self.confirmedDuration = confirmedDuration
        self.pausedResumeDuration = pausedResumeDuration
        self.pauseDebounceDuration = pauseDebounceDuration
        self.adoptionStabilityDuration = adoptionStabilityDuration
        self.gateAngleTolerance = gateAngleTolerance
    }

    // MARK: - Reset

    /// Reset session state. The learned hang reference survives (a property of
    /// the user's wearing style); the starting-pose gate does not (a new
    /// session starts a new pre-hang pose).
    mutating func reset() {
        state = .idle
        stateStartTime = nil
        notHangSince = nil
        hangStreakSince = nil
        stableSince = nil
        slidingWindow.removeAll()
        smoothedGravity = .zero
        initialPoseGate = nil
    }

    // MARK: - Reference learning

    /// Adopt a new hang reference (engine calls this when the user's real hang
    /// pose is confirmed, or during the bootstrap fallback).
    mutating func adoptHangReference(_ reference: GravityVector) {
        hangReference = reference.normalized()
    }

    /// Arm / disarm / re-point the starting-pose gate. `nil` disables it.
    mutating func setInitialPoseGate(_ gate: GravityVector?) {
        initialPoseGate = gate?.normalized()
    }

    /// The current stable gravity direction if readings have been continuously
    /// stable for at least `adoptionStabilityDuration` — candidate for a
    /// bootstrap reference adoption when detection has failed entirely.
    func stableGravity(at timestamp: Date) -> GravityVector? {
        guard let since = stableSince else { return nil }
        guard timestamp.timeIntervalSince(since) >= adoptionStabilityDuration else { return nil }
        return smoothedGravity.normalized()
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
        let sample = GravityVector(x, y, z)

        slidingWindow.append(sample)
        if slidingWindow.count > windowSize {
            slidingWindow.removeFirst()
        }

        // Window average: direction changes (sway, spikes) partially cancel,
        // so a near-unit-length average means "sustained, consistent reading".
        let count = Double(slidingWindow.count)
        let avg = slidingWindow.reduce(into: GravityVector.zero) { acc, v in
            acc.x += v.x / count
            acc.y += v.y / count
            acc.z += v.z / count
        }
        smoothedGravity = avg

        let stable = abs(avg.magnitude - 1.0) < magnitudeTolerance
        let direction = avg.normalized()
        let hangAngle = direction.angle(to: hangReference)
        // The starting-pose gate: whatever the user was doing when the session
        // began is by definition NOT a hang entered during this session. Once
        // they leave that pose the engine clears the gate.
        let gateBlocked = initialPoseGate.map {
            direction.angle(to: $0) < gateAngleTolerance
        } ?? false
        let isHangPose = stable && hangAngle < hangAngleTolerance && !gateBlocked
        // Unstable readings (mid-swing, grip adjustment) don't immediately mean
        // "left the bar" either — the debounce below demands *sustained*
        // departure before pausing.
        let clearlyNotHang = !stable || hangAngle > pauseAngleTolerance

        if stable {
            if stableSince == nil { stableSince = timestamp }
        } else {
            stableSince = nil
        }

        var events: [Event] = []

        switch state {
        case .idle:
            if isHangPose {
                state = .detecting
                stateStartTime = timestamp
            }

        case .detecting:
            if isHangPose {
                if let startTime = stateStartTime,
                   timestamp.timeIntervalSince(startTime) > detectingDuration {
                    state = .confirmed
                    stateStartTime = timestamp
                }
            } else {
                state = .idle
                stateStartTime = nil
            }

        case .confirmed:
            if isHangPose {
                if let startTime = stateStartTime,
                   timestamp.timeIntervalSince(startTime) > confirmedDuration {
                    state = .active
                    stateStartTime = nil
                    events.append(.enteredActive)
                }
            } else {
                state = .idle
                stateStartTime = nil
            }

        case .active:
            if clearlyNotHang {
                if notHangSince == nil { notHangSince = timestamp }
                if timestamp.timeIntervalSince(notHangSince!) >= pauseDebounceDuration {
                    state = .paused
                    stateStartTime = timestamp
                    notHangSince = nil
                    events.append(.enteredPaused)
                }
            } else {
                notHangSince = nil
            }

        case .paused:
            if isHangPose {
                if hangStreakSince == nil { hangStreakSince = timestamp }
                if timestamp.timeIntervalSince(hangStreakSince!) > pausedResumeDuration,
                   let pausedAt = stateStartTime {
                    let gap = timestamp.timeIntervalSince(pausedAt)
                    state = .active
                    stateStartTime = nil
                    hangStreakSince = nil
                    events.append(.resumedActive(gap: gap))
                }
            } else {
                hangStreakSince = nil
            }
        }

        return events
    }
}

// MARK: - Test Fixtures
//
// Poses are expressed relative to the DEFAULT reference (x-negative), matching
// the legacy behaviour, so plain `MotionStateMachine()` fixtures keep working.
extension MotionStateMachine {
    /// Accelerometer reading that satisfies the "hanging pose" predicate
    /// against the default reference: near (-0.92, -0.08, -0.10), 1 G.
    static var hangingPose: (x: Double, y: Double, z: Double) {
        (-0.92, -0.08, -0.10)
    }

    /// Arm-down reading: roughly anti-parallel to the hang reference.
    static var armDownPose: (x: Double, y: Double, z: Double) {
        (0.92, 0.08, 0.10)
    }

    /// Neutral reading that is neither stable-hang nor clearly-arm-down:
    /// magnitude ≈ 0.52 falls outside the stability band.
    static var neutralPose: (x: Double, y: Double, z: Double) {
        (0.3, 0.3, 0.3)
    }
}
