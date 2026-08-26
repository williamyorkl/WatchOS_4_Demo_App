import Foundation

/// Orchestrates the whole tracking pipeline — countdown, the motion state
/// machine, the counting logic — as ONE pure value type with zero platform
/// dependencies.
///
/// Previously this wiring lived inside the watch-only `PullUpTrackerViewModel`,
/// which meant (a) the two stacked state machines could disagree with each
/// other (the countdown deadlock), and (b) none of the orchestration was
/// testable — the unit tests could only exercise the machines in isolation,
/// which is exactly why the deadlock shipped.
///
/// The engine consumes two input streams, exactly like the real app:
///
/// - `motionSample(x:y:z:at:)` — 60 Hz accelerometer samples
/// - `secondTick(now:)` — the 1 Hz timer
///
/// and replies with a list of `Signal`s (haptics, persistence, sync, UI
/// change) that a thin platform adapter translates into WKKit/WatchConnectivity
/// side effects. The E2E tests drive this same engine through the physical
/// motion simulator, so what they verify is what the watch runs.
struct SessionEngine {

    // MARK: - Signals

    enum HapticKind: Equatable {
        case click
        case start
        case stop
        case success
    }

    enum Signal: Equatable {
        case haptic(HapticKind)
        /// A rep (10 s set) was completed — celebrate.
        case repCompleted
        /// An observable value (phase/counters) changed. Emitted at most once
        /// per input the values actually changed under — this is what kills the
        /// old 60 Hz @Published flood: identical samples produce no signal.
        case stateChanged
        /// The in-flight session draft changed — persist it (crash recovery).
        case draftUpdated(HangSessionDraft)
        /// The draft is finished/abandoned — remove it from storage.
        case draftCleared
        /// The session finished with real hang time — persist + sync it.
        case sessionCompleted(HangSession)
        /// The user's real hang pose was learned — persist the pose profile.
        case poseLearned(GravityVector)
    }

    /// Everything the UI needs to render, snapshotted for cheap change-detection.
    struct Snapshot: Equatable {
        var sessionPhase: TrackerLogic.SessionPhase = .idle
        var holdPhase: TrackerLogic.HoldPhase = .waiting
        var detectSeconds: Int = 0
        var holdSeconds: Int = 0
        var totalHoldTime: Int = 0
        var reps: Int = 0
        var countdownValue: Int = 0
        var isUserPaused: Bool = false
    }

    // MARK: - State

    private(set) var logic = TrackerLogic()
    private(set) var stateMachine: MotionStateMachine
    private(set) var userPaused = false

    private var draft: HangSessionDraft?
    /// When the active phase started — drives the pose-bootstrap timeout.
    private var activePhaseStartedAt: Date?
    /// The starting-pose gate arms at most once per session: re-arming after
    /// the user leaves the start pose would gate out the pose they moved TO
    /// (e.g. an early-grabber's hang).
    private var didArmGate = false
    private var lastSnapshot = Snapshot()

    init(poseProfile: HangPoseProfile = .default) {
        stateMachine = MotionStateMachine(hangReference: poseProfile.hangGravity)
    }

    // MARK: - Session control

    /// Start a fresh session with the 3-2-1 countdown (idle → countdown, or
    /// summary → countdown for "Again"). Also arms the crash-recovery draft.
    mutating func begin(now: Date = Date()) -> [Signal] {
        guard logic.sessionPhase == .idle || logic.sessionPhase == .summary else { return [] }
        logic.startCountdown()
        stateMachine.reset()
        userPaused = false
        activePhaseStartedAt = nil
        didArmGate = false
        draft = HangSessionDraft(id: UUID(), startedAt: now, reps: 0, totalSeconds: 0)
        var signals: [Signal] = [.haptic(.start), .draftUpdated(draft!)]
        signals.append(contentsOf: stateChange())
        return signals
    }

    /// Abort the countdown (user backed out). Clears the draft so nothing
    /// half-finished lingers in storage.
    mutating func cancel(now: Date = Date()) -> [Signal] {
        guard logic.sessionPhase == .countdown else { return [] }
        logic.cancelCountdown()
        stateMachine.reset()
        userPaused = false
        activePhaseStartedAt = nil
        draft = nil
        return [.draftCleared] + stateChange()
    }

    /// User-initiated pause: freeze counting, KEEP all counters and the draft.
    mutating func pauseUser() -> [Signal] {
        guard logic.sessionPhase == .active, !userPaused else { return [] }
        userPaused = true
        return [.haptic(.stop)] + stateChange()
    }

    /// Resume after a user pause. If motion is already confirmed active
    /// (the user hung on through the pause), re-enter detection — otherwise
    /// the waiting-phase stranding (same family as the countdown deadlock)
    /// freezes the counters.
    mutating func resumeUser() -> [Signal] {
        guard logic.sessionPhase == .active, userPaused else { return [] }
        userPaused = false
        if stateMachine.state == .active {
            logic.adoptMotionActive()
        }
        return [.haptic(.start)] + stateChange()
    }

    /// End the session into the summary phase. Emits `sessionCompleted` (with
    /// the draft's id/startedAt so the record dates to when the user STARTED,
    /// and crash-recovery can dedupe against it) when there was real hang time.
    mutating func end(now: Date = Date()) -> [Signal] {
        guard logic.sessionPhase == .active || logic.sessionPhase == .countdown else { return [] }
        var signals: [Signal] = []
        if logic.totalHoldTime > 0, let draft = draft {
            let session = HangSession(id: draft.id,
                                      date: draft.startedAt,
                                      reps: logic.reps,
                                      totalSeconds: logic.totalHoldTime)
            signals.append(.sessionCompleted(session))
        }
        logic.endSession()
        userPaused = false
        activePhaseStartedAt = nil
        draft = nil
        signals.append(.draftCleared)
        signals.append(contentsOf: stateChange())
        return signals
    }

    /// Leave the summary screen back to idle.
    mutating func backToIdle() -> [Signal] {
        var signals: [Signal] = []
        if draft != nil {
            signals.append(.draftCleared)
            draft = nil
        }
        logic.backToIdle()
        userPaused = false
        activePhaseStartedAt = nil
        signals.append(contentsOf: stateChange())
        return signals
    }

    // MARK: - Input streams

    /// One accelerometer sample (60 Hz in production). Motion is processed
    /// during the countdown too — grabbing the bar early is the intended use
    /// of the countdown, and `finishCountdown(motionAlreadyActive:)` reconciles
    /// the two machines when it elapses.
    mutating func motionSample(x: Double, y: Double, z: Double, at timestamp: Date = Date()) -> [Signal] {
        guard logic.sessionPhase == .active || logic.sessionPhase == .countdown else { return [] }
        let events = stateMachine.process(x: x, y: y, z: z, at: timestamp)
        manageInitialPoseGate()
        var signals: [Signal] = []
        for event in events {
            logic.apply(event: event)
            switch event {
            case .enteredActive:
                learnPose(into: &signals)
                signals.append(.haptic(.start))
            case .resumedActive:
                learnPose(into: &signals)
                signals.append(.haptic(.start))
            case .enteredPaused:
                signals.append(.haptic(.stop))
            }
        }
        bootstrapPoseAdoptionIfNeeded(at: timestamp, into: &signals)
        signals.append(contentsOf: stateChange())
        return signals
    }

    /// One timer tick (1 Hz in production). Drives the countdown numbers and
    /// the hold counters, and keeps the crash-recovery draft current.
    mutating func secondTick(now: Date = Date()) -> [Signal] {
        var signals: [Signal] = []
        if logic.sessionPhase == .countdown {
            if logic.tickCountdown() {
                logic.finishCountdown(motionAlreadyActive: stateMachine.state == .active)
                activePhaseStartedAt = now
                signals.append(.haptic(.start))
            } else {
                signals.append(.haptic(.click))
            }
        } else if logic.sessionPhase == .active, !userPaused {
            if logic.tick(motionIsActive: stateMachine.state == .active) {
                signals.append(.haptic(.success))
                signals.append(.repCompleted)
            }
            if var d = draft, d.reps != logic.reps || d.totalSeconds != logic.totalHoldTime {
                d.reps = logic.reps
                d.totalSeconds = logic.totalHoldTime
                draft = d
                signals.append(.draftUpdated(d))
            }
        }
        signals.append(contentsOf: stateChange())
        return signals
    }

    // MARK: - Snapshot

    func snapshot() -> Snapshot {
        var s = Snapshot()
        s.sessionPhase = logic.sessionPhase
        s.holdPhase = logic.holdPhase
        s.detectSeconds = logic.detectSeconds
        s.holdSeconds = logic.holdSeconds
        s.totalHoldTime = logic.totalHoldTime
        s.reps = logic.reps
        s.countdownValue = logic.countdownValue
        s.isUserPaused = userPaused
        return s
    }

    // MARK: - Pose learning

    /// Manage the starting-pose gate:
    /// 1. During the countdown, the FIRST stable pose seen becomes the gate —
    ///    that is the user's "not on the bar yet" pose (arm at side, usually).
    /// 2. Once the user demonstrably leaves that pose (>45°, i.e. they reached
    ///    for the bar), the gate clears and never re-arms for the session.
    ///
    /// This kills the false start where a mirrored-wrist user's RESTING pose
    /// reads the same gravity as the default hang reference: the app would
    /// "detect a hang" and count while they're still standing.
    private mutating func manageInitialPoseGate() {
        let smoothed = stateMachine.smoothedGravity
        guard smoothed.magnitude > 0.9 else { return }

        if !didArmGate {
            // Arm ONCE, from the countdown's first stable pose (the user's
            // pre-hang posture). After the gate clears (user left the start
            // pose — e.g. grabbed the bar during the countdown) it must NOT
            // re-arm onto the pose they moved to.
            if logic.sessionPhase == .countdown {
                stateMachine.setInitialPoseGate(smoothed)
                didArmGate = true
            }
        } else if let gate = stateMachine.initialPoseGate,
                  smoothed.angle(to: gate) > 45 {
            stateMachine.setInitialPoseGate(nil)
        }
    }

    /// When a hang is confirmed/resumed, nudge the reference toward the pose
    /// the user actually held — corrects drift and adapts when the user changes
    /// grip or tightens their strap over time.
    private mutating func learnPose(into signals: inout [Signal]) {
        let observed = stateMachine.smoothedGravity.normalized()
        guard observed.magnitude > 0.9 else { return }
        guard observed.angle(to: stateMachine.hangReference) > 8 else { return }
        stateMachine.adoptHangReference(observed)
        signals.append(.poseLearned(observed))
    }

    /// Self-healing bootstrap for wearing styles the stored reference doesn't
    /// match (other wrist, crown side, grip): if NOTHING has been detected 6 s
    /// into the active phase while the device sits perfectly stable in some
    /// clearly different direction, adopt that stable direction as the hang
    /// reference. The starting-pose gate rules out adopting the user's resting
    /// pose; if a guess was somehow wrong, the window re-arms and a later
    /// stable pose gets adopted instead. Configured users never hit this path.
    private mutating func bootstrapPoseAdoptionIfNeeded(at timestamp: Date, into signals: inout [Signal]) {
        guard logic.sessionPhase == .active,
              stateMachine.state == .idle,
              let startedAt = activePhaseStartedAt,
              timestamp.timeIntervalSince(startedAt) > 6,
              let candidate = stateMachine.stableGravity(at: timestamp),
              candidate.angle(to: stateMachine.hangReference) > 60
        else { return }
        if let gate = stateMachine.initialPoseGate,
           candidate.angle(to: gate) <= 60 {
            return // the pose the user STARTED in is never the hang
        }
        stateMachine.adoptHangReference(candidate)
        stateMachine.setInitialPoseGate(nil) // the machine has decided this pose IS the hang
        activePhaseStartedAt = timestamp // re-arm so a wrong guess can be corrected
        signals.append(.poseLearned(candidate))
    }

    /// Emit `.stateChanged` only when the observable values actually changed.
    private mutating func stateChange() -> [Signal] {
        let s = snapshot()
        guard s != lastSnapshot else { return [] }
        lastSnapshot = s
        return [.stateChanged]
    }
}

// MARK: - Crash-recovery draft

/// Snapshot of an in-flight session, persisted continuously during a session
/// so that a crash / force-quit / watch restart doesn't silently discard the
/// user's effort. On next launch a leftover draft becomes a completed session
/// (deduped by id, so a normal `end()` can't double-write).
struct HangSessionDraft: Codable, Equatable {
    let id: UUID
    let startedAt: Date
    var reps: Int
    var totalSeconds: Int

    static let storageKey = "hangSessionDraft"

    static func load(from defaults: UserDefaults) -> HangSessionDraft? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(HangSessionDraft.self, from: data)
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: storageKey)
    }

    /// Turn a leftover draft into a completed session in `store`. Returns the
    /// restored session (nil if there was nothing worth restoring). Always
    /// consumes the draft. Deduped by id, so restoring twice — or restoring a
    /// draft whose session was already flushed — writes nothing.
    @discardableResult
    static func restore(into store: HangSessionStore, defaults: UserDefaults) -> HangSession? {
        defer { clear(in: defaults) }
        guard let draft = load(from: defaults) else { return nil }
        guard draft.totalSeconds > 0 else { return nil }
        guard !store.allSessions.contains(where: { $0.id == draft.id }) else { return nil }
        let session = HangSession(id: draft.id,
                                  date: draft.startedAt,
                                  reps: draft.reps,
                                  totalSeconds: draft.totalSeconds)
        store.append(session)
        return session
    }
}

// MARK: - Pose profile persistence

/// The learned "what gravity reads when THIS user hangs" reference, persisted
/// across sessions so detection is instant from the second session on — for
/// any wrist / crown side / grip combination.
struct HangPoseProfile: Codable, Equatable {
    var hangGravity: GravityVector

    static let `default` = HangPoseProfile(hangGravity: MotionStateMachine.defaultHangReference)
}

final class HangPoseProfileStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "hangPoseProfile") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> HangPoseProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HangPoseProfile.self, from: data)
    }

    func save(_ profile: HangPoseProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: key)
        }
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
