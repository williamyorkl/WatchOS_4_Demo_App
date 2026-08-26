import Foundation
@testable import FirstWatchApp

/// A deterministic PHYSICAL-BEHAVIOUR simulator for end-to-end testing.
///
/// It models a person wearing the watch in a configurable way, standing with
/// their arm at their side, then reaching up and hanging from a bar, swaying,
/// dropping and re-gripping — and emits the accelerometer stream (x/y/z at
/// 60 Hz) the same way CoreMotion would.
///
/// Physics model
/// ─────────────
/// The accelerometer reads the specific force f = a − g in the DEVICE frame.
/// Quasi-statically (standing / hanging) a ≈ 0, so the reading is the gravity
/// direction rotated into device coordinates. The two poses differ by the
/// ~180° arm swing from "arm at side" to "arm overhead gripping the bar", so:
///
///     restGravity ≈ −hangGravity   (in device coordinates, per config)
///
/// A `WornConfig` fixes what the device actually reads while hanging — this is
/// where left-vs-right wrist, crown side and grip rotation all show up. The
/// app must work for ANY of them (fix #2), and this simulator can produce
/// streams for configurations the old hard-coded `x < −0.7` predicate could
/// never detect.
///
/// Transitions (reach / drop) interpolate the gravity direction over the move
/// and ADD tangential dynamic acceleration, so the reading's magnitude leaves
/// the 1 G band exactly as a real raise/drop does (the detection pipeline must
/// reject these as unstable).
///
/// Deterministic: noise comes from a seeded SplitMix64 generator, so failures
/// reproduce exactly.
struct MotionSimulator {

    // MARK: - Wearing configuration

    /// What the accelerometer reads for this user's wearing style.
    struct WornConfig {
        /// Device-frame gravity while hanging from the bar.
        let hangGravity: GravityVector
        /// Device-frame gravity with the arm relaxed at the side
        /// (≈ anti-parallel to the hang direction).
        let restGravity: GravityVector

        /// The legacy-compatible configuration: hang reads x-negative, exactly
        /// what the old hard-coded predicate expected.
        static let authorDefault = WornConfig(
            hangGravity: GravityVector(-0.92, -0.08, -0.10).normalized(),
            restGravity: GravityVector(0.92, 0.08, 0.10).normalized()
        )

        /// Watch mirrored onto the other wrist: the hang reading flips x.
        static let mirroredWrist = WornConfig(
            hangGravity: GravityVector(0.92, 0.08, -0.10).normalized(),
            restGravity: GravityVector(-0.92, -0.08, 0.10).normalized()
        )

        /// Crown rotated to the other side: the hang reading swaps the x/z
        /// axes' roles.
        static let crownSwapped = WornConfig(
            hangGravity: GravityVector(-0.10, -0.08, -0.92).normalized(),
            restGravity: GravityVector(0.10, 0.08, 0.92).normalized()
        )
    }

    // MARK: - Samples

    struct Sample {
        let t: TimeInterval
        let x: Double
        let y: Double
        let z: Double
    }

    // MARK: - Timeline segments

    fileprivate enum Segment {
        /// Arm relaxed at the side (or otherwise off the bar) until `end`.
        case stand(end: TimeInterval)
        /// Smooth reach from rest to the bar: interpolated gravity + dynamic
        /// acceleration (magnitude leaves the 1 G band → unstable).
        case reach(end: TimeInterval)
        /// Hanging until `end`, swaying ±`swayDegrees` with period `swayPeriod`.
        case hang(end: TimeInterval, swayDegrees: Double, swayPeriod: TimeInterval)
        /// Controlled drop from the bar back to rest.
        case drop(end: TimeInterval)
        /// ON the bar but shaking (grip adjustment, kipping attempt): hang
        /// gravity + violent short-lived acceleration spikes.
        case shake(end: TimeInterval, spikeG: Double)
    }

    // MARK: - State

    private let config: WornConfig
    private let hz: Double
    private var rngState: UInt64
    private var segments: [Segment] = []
    private var timelineStart: TimeInterval = 0

    init(config: WornConfig = .authorDefault, seed: UInt64 = 0x5EED_0001, hz: Double = 60) {
        self.config = config
        self.hz = hz
        self.rngState = seed
    }

    // MARK: - Script builder (timeline DSL)

    /// Stand with the arm at the side for `duration` seconds.
    @discardableResult
    mutating func stand(duration: TimeInterval) -> MotionSimulator {
        segments.append(.stand(end: timelineStart + duration))
        timelineStart += duration
        return self
    }

    /// Reach up and grab the bar over `duration` seconds (dynamic, unstable).
    @discardableResult
    mutating func reach(duration: TimeInterval = 0.6) -> MotionSimulator {
        segments.append(.reach(end: timelineStart + duration))
        timelineStart += duration
        return self
    }

    /// Hang from the bar for `duration` seconds with a gentle body sway.
    @discardableResult
    mutating func hang(duration: TimeInterval, swayDegrees: Double = 10, swayPeriod: TimeInterval = 2.5) -> MotionSimulator {
        segments.append(.hang(end: timelineStart + duration, swayDegrees: swayDegrees, swayPeriod: swayPeriod))
        timelineStart += duration
        return self
    }

    /// Drop off the bar over `duration` seconds (back to arm-at-side).
    @discardableResult
    mutating func drop(duration: TimeInterval = 0.5) -> MotionSimulator {
        segments.append(.drop(end: timelineStart + duration))
        timelineStart += duration
        return self
    }

    /// A short violent shake while still ON the bar (grip adjustment).
    @discardableResult
    mutating func shake(duration: TimeInterval = 0.12, spikeG: Double = 0.7) -> MotionSimulator {
        segments.append(.shake(end: timelineStart + duration, spikeG: spikeG))
        timelineStart += duration
        return self
    }

    // MARK: - Sample generation

    /// Resolve the whole timeline into a 60 Hz sample stream.
    func samples() -> [Sample] {
        guard let total = segments.map(\.endOffset).max() else { return [] }
        let dt = 1.0 / hz
        var driver = self
        var out: [Sample] = []
        out.reserveCapacity(Int(total * hz) + 2)

        var t = 0.0
        while t <= total {
            out.append(driver.sample(at: t))
            t += dt
        }
        return out
    }

    // MARK: - Physics

    /// Deterministic noise in [−1, 1) from SplitMix64.
    private mutating func nextUnit() -> Double {
        rngState &+= 0x9E37_79B9_7F4A_7C15
        var z = rngState
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53) * 2.0 - 1.0
    }

    /// Sensor noise amplitude per axis (G). Real MEMS accelerometer noise.
    private let noiseSigma = 0.02

    private mutating func sample(at t: TimeInterval) -> Sample {
        let gravity: GravityVector
        let extraAccel: GravityVector

        switch segment(containing: t) {
        case .stand:
            gravity = config.restGravity
            extraAccel = .zero

        case .hang(let end, let swayDegrees, let swayPeriod):
            let localT = t - (end - hangDuration(of: end)) // time since hang started
            gravity = Self.rotate(config.hangGravity,
                                  around: Self.swayAxis(for: config.hangGravity),
                                  degrees: swayDegrees * sin(2 * .pi * localT / swayPeriod))
            extraAccel = .zero

        case .reach(let end):
            let (start, duration) = transitionWindow(end: end)
            let p = progress(t: t, start: start, duration: duration)
            gravity = Self.slerp(config.restGravity, config.hangGravity, p)
            // Dynamic acceleration along the movement direction, peaking
            // mid-move — this is what makes the magnitude leave the 1 G band.
            let tangent = config.hangGravity.subtracting(config.restGravity).normalized()
            extraAccel = tangent.scaled(0.35 * sin(.pi * p))

        case .drop(let end):
            let (start, duration) = transitionWindow(end: end)
            let p = progress(t: t, start: start, duration: duration)
            gravity = Self.slerp(config.hangGravity, config.restGravity, p)
            let tangent = config.restGravity.subtracting(config.hangGravity).normalized()
            extraAccel = tangent.scaled(0.35 * sin(.pi * p))

        case .shake(let end, let spikeG):
            _ = end
            gravity = config.hangGravity
            extraAccel = GravityVector(nextUnit() * spikeG,
                                       nextUnit() * spikeG,
                                       nextUnit() * spikeG)
        }

        let noise = GravityVector(nextUnit() * noiseSigma,
                                  nextUnit() * noiseSigma,
                                  nextUnit() * noiseSigma)
        let reading = gravity.adding(extraAccel).adding(noise)
        return Sample(t: t, x: reading.x, y: reading.y, z: reading.z)
    }

    // MARK: - Segment bookkeeping

    private var segmentStartOffsets: [(offset: TimeInterval, segment: Segment)] {
        var cursor = 0.0
        return segments.map { seg in
            let entry = (offset: cursor, segment: seg)
            cursor = seg.endOffset
            return entry
        }
    }

    private func segment(containing t: TimeInterval) -> Segment {
        for (start, seg) in segmentStartOffsets where t < seg.endOffset && t >= start {
            return seg
        }
        return segments.last ?? .stand(end: 0)
    }

    private func transitionWindow(end: TimeInterval) -> (start: TimeInterval, duration: TimeInterval) {
        let starts = segmentStartOffsets
        guard let idx = starts.firstIndex(where: { $0.segment.endOffset == end }) else {
            return (end - 0.6, 0.6)
        }
        let start = idx == 0 ? 0 : starts[idx - 1].segment.endOffset
        return (start, end - start)
    }

    private func hangDuration(of end: TimeInterval) -> TimeInterval {
        let starts = segmentStartOffsets
        guard let idx = starts.firstIndex(where: { $0.segment.endOffset == end }) else { return 1 }
        let start = idx == 0 ? 0 : starts[idx - 1].segment.endOffset
        return max(end - start, 0.001)
    }

    private func progress(t: TimeInterval, start: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return min(max((t - start) / duration, 0), 1)
    }

    // MARK: - Vector math

    private static func slerp(_ a: GravityVector, _ b: GravityVector, _ p: Double) -> GravityVector {
        let angle = a.angle(to: b) * .pi / 180
        guard angle > 1e-6 else { return a }
        let sinA = sin(angle * (1 - p))
        let sinB = sin(angle * p)
        let sinTotal = sin(angle)
        return a.scaled(sinA / sinTotal).adding(b.scaled(sinB / sinTotal)).normalized()
    }

    private static func swayAxis(for v: GravityVector) -> GravityVector {
        // Any unit axis perpendicular to v; pick the least-aligned world axis
        // and orthogonalise.
        let world = abs(v.x) < 0.9 ? GravityVector(1, 0, 0) : GravityVector(0, 1, 0)
        let parallel = world.scaled(world.dot(v) / v.magnitude)
        return world.subtracting(parallel).normalized()
    }

    /// Rodrigues rotation of v around a unit axis by `degrees`.
    private static func rotate(_ v: GravityVector, around axis: GravityVector, degrees: Double) -> GravityVector {
        let theta = degrees * .pi / 180
        let cosT = cos(theta)
        let sinT = sin(theta)
        let cross = GravityVector(axis.y * v.z - axis.z * v.y,
                                  axis.z * v.x - axis.x * v.z,
                                  axis.x * v.y - axis.y * v.x)
        let dot = axis.dot(v)
        return GravityVector(
            v.x * cosT + cross.x * sinT + axis.x * dot * (1 - cosT),
            v.y * cosT + cross.y * sinT + axis.y * dot * (1 - cosT),
            v.z * cosT + cross.z * sinT + axis.z * dot * (1 - cosT)
        ).normalized()
    }
}

private extension MotionSimulator.Segment {
    /// Absolute end offset of the segment in timeline time.
    var endOffset: TimeInterval {
        switch self {
        case .stand(let end), .reach(let end), .drop(let end): return end
        case .hang(let end, _, _): return end
        case .shake(let end, _): return end
        }
    }
}

private extension GravityVector {
    func scaled(_ s: Double) -> GravityVector {
        GravityVector(x * s, y * s, z * s)
    }

    func adding(_ o: GravityVector) -> GravityVector {
        GravityVector(x + o.x, y + o.y, z + o.z)
    }

    func subtracting(_ o: GravityVector) -> GravityVector {
        GravityVector(x - o.x, y - o.y, z - o.z)
    }
}
