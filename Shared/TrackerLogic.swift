import Foundation

/// Pure, platform-independent counting logic for the hang tracker.
///
/// This struct has **zero platform dependencies** (only `Foundation`) so it can
/// be compiled into the watchOS extension, the iOS host app, and the unit-test
/// target. It mirrors — exactly — the counting behaviour that previously lived
/// inline inside `PullUpTrackerViewModel`, so existing behaviour and the magic
/// constants (`detectThreshold`, `targetHoldSeconds`) are preserved verbatim.
///
/// The ViewModel now delegates counting to an instance of this type; the
/// state-transition *events* (which come from `MotionStateMachine`) are fed in
/// via `apply(event:)`, and the 1-second timer tick is driven by `tick()`.
///
/// Keeping this logic pure lets us unit-test the entire rep/hold counting
/// pipeline without depending on `CMMotionManager`, `HKWorkoutSession` or
/// `WatchKit` — and without requiring the watch-only `PullUpTrackerView.swift`
/// to be a member of the iOS test host target.
struct TrackerLogic {

    // MARK: - Configuration (magic constants — pinned by tests)

    /// One-second settle tick after the motion pipeline confirms the hang pose.
    /// The heavy lifting (pose confirmation) already happened in
    /// `MotionStateMachine` (detecting + confirmed); this is only a grace tick,
    /// so the total uncounted overhead per grab is ~2 s instead of the old ~5 s
    /// of two stacked detection layers.
    static let detectThreshold: Int = 1

    /// Seconds of continuous hold that count as one completed set/rep.
    static let targetHoldSeconds: Int = 10

    /// How long the user may be off the bar (regrip, chalk, shake-out) before
    /// the in-progress set resets. A drop shorter than this continues the SAME
    /// set when they re-grab; a longer rest starts a fresh set. Hang time is
    /// never lost either way — `totalHoldTime` always accumulates.
    static let regripGraceSeconds: Double = 4.0

    // MARK: - State (value type — cheap to copy, easy to test)

    /// High-level session phase driven by the ViewModel.
    enum SessionPhase: Equatable {
        case idle
        case countdown
        case active
        case summary
    }

    /// Sub-state during `.active`, driven by motion events.
    enum HoldPhase: Equatable {
        case waiting
        case detecting
        case holding
    }

    /// All state is `internal` read/write (the default) rather than
    /// `private(set)`. This is idiomatic for value types whose invariants are
    /// exercised by tests: production code mutates state through the semantic
    /// methods (`startSession`, `tick(motionIsActive:)`, `apply(event:)`), while
    /// tests may shortcut by setting fields to assert on one invariant at a
    /// time via `@testable import`.
    var sessionPhase: SessionPhase = .idle
    var holdPhase: HoldPhase = .waiting

    var detectSeconds: Int = 0
    var holdSeconds: Int = 0
    var totalHoldTime: Int = 0
    var reps: Int = 0

    // MARK: - Countdown

    /// Seconds the user gets to grab the bar before detection starts.
    /// Kept here (not in the view) so it is unit-testable and single-sourced.
    static let countdownSeconds: Int = 3

    /// Current countdown number shown to the user (counts down: 3 → 2 → 1 → 0).
    /// Only meaningful while `sessionPhase == .countdown`.
    var countdownValue: Int = 0

    /// Enter the pre-session countdown. Resets all counters and arms the motion
    /// pipeline, but does NOT start counting yet — the user gets
    /// `countdownSeconds` to prepare. Used by the Idle "Start" button.
    mutating func startCountdown() {
        sessionPhase = .countdown
        countdownValue = TrackerLogic.countdownSeconds
        reps = 0
        totalHoldTime = 0
        detectSeconds = 0
        holdSeconds = 0
        holdPhase = .waiting
    }

    /// Advance the countdown by one second. Returns `true` when the countdown
    /// has just reached zero and the session should transition to `.active`.
    /// The ViewModel drives this from the same 1-second timer that later ticks
    /// the hold counters.
    @discardableResult
    mutating func tickCountdown() -> Bool {
        guard sessionPhase == .countdown else { return false }
        countdownValue -= 1
        if countdownValue <= 0 {
            return true
        }
        return false
    }

    /// Transition from countdown into the active session (counters were already
    /// reset by `startCountdown`).
    ///
    /// `motionAlreadyActive` fixes the early-grab deadlock: the motion
    /// pipeline runs *during* the countdown (by design — the countdown exists
    /// so the user can grab the bar). If the user grabbed early, the state
    /// machine has ALREADY emitted `.enteredActive` and sits in `.active`; an
    /// unconditional `holdPhase = .waiting` here would strand the counters in
    /// waiting forever (no further transition event would ever arrive). Passing
    /// the machine's state in re-enters detection instead.
    mutating func finishCountdown(motionAlreadyActive: Bool = false) {
        sessionPhase = .active
        if motionAlreadyActive {
            holdPhase = .detecting
            detectSeconds = 0
        } else {
            holdPhase = .waiting
        }
    }

    /// Re-enter detection when motion is *already* confirmed active — used when
    /// the user resumes a user-paused session while still hanging. Without this
    /// the same waiting-phase stranding as the countdown deadlock occurs.
    mutating func adoptMotionActive() {
        holdPhase = .detecting
        detectSeconds = 0
    }

    /// Abort the countdown back to idle (user backed out). Mirrors `backToIdle`.
    mutating func cancelCountdown() {
        sessionPhase = .idle
        reps = 0
        totalHoldTime = 0
        countdownValue = 0
    }

    // MARK: - Mutators that mirror the ViewModel's previous behaviour

    /// Begin a fresh session. Mirrors `ViewModel.startSession()` counting effects.
    mutating func startSession() {
        sessionPhase = .active
        reps = 0
        totalHoldTime = 0
        detectSeconds = 0
        holdSeconds = 0
        holdPhase = .waiting
    }

    /// End the session into the summary phase. Mirrors `ViewModel.endSession()`.
    mutating func endSession() {
        sessionPhase = .summary
        holdPhase = .waiting
    }

    /// Return to idle, clearing counters. Mirrors `ViewModel.backToIdle()`.
    mutating func backToIdle() {
        sessionPhase = .idle
        reps = 0
        totalHoldTime = 0
    }

    /// Apply a motion-state-machine event, updating the hold phase.
    ///
    /// - `.enteredPaused` keeps `holdSeconds`: whether the set survives depends
    ///   on how long the user is off the bar, which is only known at resume.
    /// - `.resumedActive(gap:)` continues the SAME set after a short regrip
    ///   (gap ≤ `regripGraceSeconds`) and starts a fresh set after real rest.
    mutating func apply(event: MotionStateMachine.Event) {
        switch event {
        case .enteredActive:
            holdPhase = .detecting
            detectSeconds = 0
        case .enteredPaused:
            holdPhase = .waiting
        case .resumedActive(let gap):
            if gap <= TrackerLogic.regripGraceSeconds {
                holdPhase = .holding
            } else {
                holdPhase = .detecting
                detectSeconds = 0
            }
        }
    }

    /// Advance the 1-second clock. Must only count while the motion state machine
    /// reports `.active`; the caller (ViewModel) gates this by passing
    /// `motionIsActive`. Mirrors `ViewModel.updateTimer()`.
    ///
    /// - Returns: `true` if a rep was just completed on this tick (so the caller
    ///   can fire the celebratory haptic), `false` otherwise.
    @discardableResult
    mutating func tick(motionIsActive: Bool) -> Bool {
        guard motionIsActive else { return false }

        if holdPhase == .detecting {
            detectSeconds += 1
            if detectSeconds >= TrackerLogic.detectThreshold {
                holdPhase = .holding
                holdSeconds = 0
            }
            return false
        } else if holdPhase == .holding {
            holdSeconds += 1
            totalHoldTime += 1

            if holdSeconds >= TrackerLogic.targetHoldSeconds {
                reps += 1
                holdSeconds = 0
                return true
            }
            return false
        }
        return false
    }

    /// Progress percentage (0–100) for the current hold phase. Clamped at 100
    /// for the detecting settle tick so presentation code never sees > 100.
    var progress: Double {
        switch holdPhase {
        case .detecting:
            return min(Double(detectSeconds) / Double(max(TrackerLogic.detectThreshold, 1)), 1) * 100
        case .holding:
            return Double(holdSeconds) / Double(TrackerLogic.targetHoldSeconds) * 100
        case .waiting:
            return 0
        }
    }

    /// Encouragement intensity band for the holding ring, derived from progress.
    ///
    /// The UI maps each band to a colour. Going UP a band as progress rises is
    /// the desired behaviour (closer to goal = more positive), matching Apple's
    /// Activity ring convention. Keeping the banding here (rather than in the
    /// view) makes it unit-testable: a future refactor can't silently flip the
    /// colour semantics without a test catching it.
    enum HoldBand: Equatable {
        case warming   // 0 – <40%  — just started
        case cruising  // 40 – <80% — building
        case finishing // 80 – 100% — about to complete a rep
    }

    /// The encouragement band for the holding phase. Returns `nil` outside
    /// `.holding` (the ring is blue/orange for waiting/detecting, not banded).
    var holdBand: HoldBand? {
        guard holdPhase == .holding else { return nil }
        return TrackerLogic.band(forHoldingProgress: progress)
    }

    /// Pure function mapping a holding-phase progress percentage (0–100) to an
    /// encouragement band. Exposed statically so presentation layers (the watch
    /// `ActiveView`) can compute the band from a plain `progress` value without
    /// needing a `TrackerLogic` instance or the `ViewModel`.
    static func band(forHoldingProgress progress: Double) -> HoldBand {
        if progress < 40 { return .warming }
        if progress < 80 { return .cruising }
        return .finishing
    }
}
