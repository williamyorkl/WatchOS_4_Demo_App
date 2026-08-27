import SwiftUI
import CoreMotion
import WatchKit
import Combine
import HealthKit
import WatchConnectivity

enum TrackerSessionState {
    case idle
    case countdown
    case active
    case summary

    /// Bridge from the platform-independent `TrackerLogic.SessionPhase`.
    init(_ phase: TrackerLogic.SessionPhase) {
        switch phase {
        case .idle:      self = .idle
        case .countdown: self = .countdown
        case .active:    self = .active
        case .summary:   self = .summary
        }
    }
}

enum TrackerHoldState {
    case waiting
    case detecting
    case holding

    /// Bridge from the platform-independent `TrackerLogic.HoldPhase`.
    init(_ phase: TrackerLogic.HoldPhase) {
        switch phase {
        case .waiting:   self = .waiting
        case .detecting: self = .detecting
        case .holding:   self = .holding
        }
    }
}

class PullUpTrackerViewModel: ObservableObject {
    // MARK: DEBUG scripted-motion driver (-demoMotion)
    @Published var sessionState: TrackerSessionState = .idle
    @Published var holdState: TrackerHoldState = .waiting

    @Published var detectSeconds: Int = 0
    @Published var holdSeconds: Int = 0
    @Published var totalHoldTime: Int = 0
    @Published var reps: Int = 0
    @Published var showHint: Bool = true
    @Published var countdownValue: Int = 0
    @Published var isUserPaused: Bool = false

    #if DEBUG
    @Published var debugX: Double = 0
    @Published var debugY: Double = 0
    @Published var debugZ: Double = 0
    @Published var debugState: String = "idle"
    @Published var debugAccelStatus: String = "not started"
    private var debugCounter = 0
    private var lastDebugState: String = ""

    /// DEBUG-only UI driving:
    /// `-demoMotion` — scripted physical performance replaces the accelerometer.
    /// `-uiFixture <case>` — force-render a screen state with ticking data
    ///   (no sensors): idle | waiting | detecting | holding | summary.
    /// DEBUG-only deterministic screen-state driving. Launch arguments,
    /// spawn-defaults and marker files all proved unreliable channels into the
    /// watch extension process, so fixtures are triggered at RUNTIME instead
    /// (long-press on the root view cycles them). This only touches presented
    /// values — sensor/counting logic stays fully covered by unit+E2E tests.
    private var fixtureTimer: Timer?
    var fixtureProgressOverride: Double?

    func debugStopFixture() {
        fixtureTimer?.invalidate(); fixtureTimer = nil
    }

    func debugApplyFixture(_ modeRaw: String) {
        debugStopFixture()
        let mode = modeRaw.lowercased()
        let ticking = (mode == "holding")
        switch mode {
        case "waiting", "detecting", "holding":
            sessionState = .active
            holdState = mode == "waiting" ? .waiting : (mode == "detecting" ? .detecting : .holding)
            detectSeconds = mode == "detecting" ? 0 : TrackerLogic.detectThreshold
            holdSeconds = 4
            reps = 2
            totalHoldTime = 24
            fixtureProgressOverride = ticking
                ? Double(holdSeconds) / Double(TrackerLogic.targetHoldSeconds) * 100
                : (mode == "detecting" ? 60 : 40)
            if ticking {
                fixtureTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.holdSeconds = (self.holdSeconds + 1) % TrackerLogic.targetHoldSeconds
                    self.totalHoldTime += 1
                    self.fixtureProgressOverride =
                        Double(self.holdSeconds) / Double(TrackerLogic.targetHoldSeconds) * 100
                    if self.totalHoldTime % TrackerLogic.targetHoldSeconds == 0 { self.reps += 1 }
                }
                RunLoop.current.add(fixtureTimer!, forMode: .common)
            }
        case "summary":
            sessionState = .summary
        default:
            break
        }
    }

    #endif

    /// Pure orchestration core (countdown + motion pipeline + counting). This
    /// same engine drives the E2E tests, so what the simulator verifies is what
    /// the watch runs. This ViewModel is only the platform adapter: CoreMotion,
    /// HealthKit, haptics, persistence, WatchConnectivity.
    private var engine: SessionEngine
    private let poseStore: HangPoseProfileStore

    private let motionManager = CMMotionManager()

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutStartDate: Date?
    /// Authorization is requested once per launch, at app start — never
    /// mid-countdown (the old flow popped the HealthKit sheet exactly when the
    /// user was grabbing the bar).
    private var didRequestHealthAuth = false

    /// Persists every completed session so the phone can show history/growth.
    /// Injectable so tests can swap in an isolated store.
    var sessionStore: HangSessionStore

    /// Injectable UserDefaults for the crash-recovery draft.
    var draftDefaults: UserDefaults

    var playHaptic: (WKHapticType) -> Void = { WKInterfaceDevice.current().play($0) }

    /// DEBUG fixture override so `-uiFixture holding` can render a live
    /// progress arc without driving the motion pipeline.
    #if DEBUG
    var progress: Double { fixtureProgressOverride ?? engine.logic.progress }
    #else
    var progress: Double { engine.logic.progress }
    #endif

    init(sessionStore: HangSessionStore = HangSessionStore(),
         poseStore: HangPoseProfileStore = HangPoseProfileStore(),
         draftDefaults: UserDefaults = .standard) {
        self.sessionStore = sessionStore
        self.poseStore = poseStore
        self.draftDefaults = draftDefaults
        self.engine = SessionEngine(poseProfile: poseStore.load() ?? .default)
        // Crash recovery: a leftover draft means the app died mid-session —
        // turn it into a completed session instead of silently dropping it.
        if let restored = HangSessionDraft.restore(into: sessionStore, defaults: draftDefaults) {
            pushToPhone(restored)
        }
        syncPublished(force: true)
    }

    // MARK: - HealthKit

    /// Called once when the app appears. Prompts for HealthKit write access
    /// BEFORE any session starts, so the system sheet never collides with the
    /// 3-2-1 countdown. If the user denies, sessions still work — they just
    /// don't get recorded to Health or benefit from workout background running.
    func prepareHealthKit() {
        guard !didRequestHealthAuth else { return }
        didRequestHealthAuth = true
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let typesToShare: Set = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: typesToShare, read: nil) { _, _ in }
    }

    /// Start the background workout session ONLY if authorization was already
    /// granted. Never prompts — no system sheet mid-session.
    private func beginWorkoutSessionIfAuthorized() {
        guard HKHealthStore.isHealthDataAvailable(),
              healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        do {
            workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            workoutSession?.startActivity(with: Date())
            workoutStartDate = Date()
        } catch { }
    }

    /// End the workout session and — unlike the old code, which requested
    /// HealthKit permission and then wrote NOTHING — actually save an
    /// HKWorkout with the hang stats as metadata, so the permission finally
    /// buys the user a real Health record. Pass `record: false` when the
    /// workout produced nothing (e.g. a cancelled countdown) so Health isn't
    /// polluted with zero-length workouts.
    private func stopWorkoutSessionAndRecord(reps: Int, totalSeconds: Int, record: Bool = true) {
        guard let session = workoutSession else { return }
        let start = workoutStartDate ?? Date()
        let end = Date()
        session.end()
        workoutSession = nil
        workoutStartDate = nil
        guard record else { return }
        recordHangWorkout(start: start, end: end, reps: reps, totalSeconds: totalSeconds)
    }

    private func recordHangWorkout(start: Date, end: Date, reps: Int, totalSeconds: Int) {
        guard HKHealthStore.isHealthDataAvailable(),
              healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: healthStore,
                                       configuration: configuration,
                                       device: .local())
        builder.beginCollection(withStart: start) { ok, _ in
            guard ok else { return }
            let metadata: [String: Any] = [
                "williamyorkl.hangtracker.reps": NSNumber(value: reps),
                "williamyorkl.hangtracker.hangSeconds": NSNumber(value: totalSeconds),
            ]
            builder.addMetadata(metadata) { _, _ in
                builder.endCollection(withEnd: end) { _, _ in
                    builder.finishWorkout { _, _ in }
                }
            }
        }
    }

    // MARK: - Session control

    func beginSession() {
        guard sessionState == .idle else { return }
        apply(engine.begin())
        print("🔴 [PullUp] beginSession (countdown) called")
        beginWorkoutSessionIfAuthorized()
        startAccelerometers()
        startCountTimer()
    }

    /// "Again" from the Summary screen: start a fresh countdown session
    /// (counters reset). Lets the user chain sets without going back to idle.
    func repeatSession() {
        guard sessionState == .summary else { return }
        apply(engine.begin())
        beginWorkoutSessionIfAuthorized()
        startAccelerometers()
        startCountTimer()
    }

    /// Abort the countdown (user backed out) — now wired to a Cancel button
    /// on the countdown screen (previously dead code with no UI).
    func cancelCountdown() {
        apply(engine.cancel())
        motionManager.stopAccelerometerUpdates()
        stopCountTimer()
        stopWorkoutSessionAndRecord(reps: 0, totalSeconds: 0, record: false)
    }

    func endSession() {
        let snapshot = engine.snapshot()
        apply(engine.end())
        motionManager.stopAccelerometerUpdates()
        stopCountTimer()
        stopWorkoutSessionAndRecord(reps: snapshot.reps, totalSeconds: snapshot.totalHoldTime)
    }

    /// Push a completed session to the phone via WatchConnectivity so the
    /// phone's history/stats update without manual sync.
    ///
    /// Uses `updateUserInfo` (FIFO QUEUE, guaranteed delivery of every item)
    /// instead of the old `updateApplicationContext` (latest-wins snapshot):
    /// if the phone was unreachable, completing sessions S1 then S2 used to
    /// silently DROP S1 — its context was overwritten before delivery.
    private func pushToPhone(_ session: HangSession) {
        guard WCSession.isSupported() else { return }
        let wc = WCSession.default
        if wc.activationState != .activated { wc.activate() }
        guard
            let data = try? JSONEncoder().encode(session),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        try? wc.transferUserInfo([HangConnectivity.sessionKey: object])
    }

    /// User-initiated pause: stop the timer and motion detection but KEEP all
    /// counters so the session can resume.
    func pauseSession() {
        apply(engine.pauseUser())
        stopCountTimer()
        motionManager.stopAccelerometerUpdates()
        print("🔴 [PullUp] pauseSession (resumable)")
    }

    /// Resume after a user-initiated pause. The engine re-enters detection if
    /// motion is still confirmed active, so counters can't strand in waiting.
    func resumeSession() {
        apply(engine.resumeUser())
        startAccelerometers()
        startCountTimer()
        print("🔴 [PullUp] resumeSession")
    }

    func backToIdle() {
        apply(engine.backToIdle())
        motionManager.stopAccelerometerUpdates()
        stopCountTimer()
        stopWorkoutSessionAndRecord(reps: 0, totalSeconds: 0)
    }

    func dismissHint() {
        showHint = false
    }

    // MARK: - Timer & motion wiring

    private func startCountTimer() {
        countTimer?.invalidate()
        countTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateTimer()
        }
        RunLoop.current.add(countTimer!, forMode: .common)
    }

    private var countTimer: Timer?

    private func stopCountTimer() {
        countTimer?.invalidate()
        countTimer = nil
    }

    func updateTimer() {
        apply(engine.secondTick())
    }

    private func celebrateRep() {
        playHaptic(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.playHaptic(.click)
        }
    }

    private func startAccelerometers() {
        motionManager.stopAccelerometerUpdates()
        let isAvailable = motionManager.isAccelerometerAvailable

        guard isAvailable else {
            #if DEBUG
            debugAccelStatus = "UNAVAILABLE"
            #endif
            return
        }
        #if DEBUG
        debugAccelStatus = "started"
        #endif

        motionManager.accelerometerUpdateInterval = 1.0 / 60.0
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let data = data, let self = self else { return }
            self.processMotion(x: data.acceleration.x,
                               y: data.acceleration.y,
                               z: data.acceleration.z)
        }
    }

    func processMotion(x: Double, y: Double, z: Double, at timestamp: Date = Date()) {
        #if DEBUG
        debugCounter += 1
        if debugCounter % 30 == 0 {
            debugX = x
            debugY = y
            debugZ = z
            let stateName = String(describing: engine.stateMachine.state)
            if stateName != lastDebugState {
                debugState = stateName
                lastDebugState = stateName
            }
        }
        #endif

        apply(engine.motionSample(x: x, y: y, z: z, at: timestamp))
    }

    // MARK: - Signal application

    private func apply(_ signals: [SessionEngine.Signal]) {
        for signal in signals {
            switch signal {
            case .haptic(let kind):
                playHaptic(Self.hapticMap[kind] ?? .click)
            case .repCompleted:
                celebrateRep()
            case .stateChanged:
                // The engine only emits this when observable values actually
                // changed, so the UI refreshes at most ~1 Hz while counting —
                // not at the 60 Hz accelerometer rate.
                syncPublished()
            case .draftUpdated(let draft):
                draft.save(to: draftDefaults)
            case .draftCleared:
                HangSessionDraft.clear(in: draftDefaults)
            case .sessionCompleted(let session):
                sessionStore.append(session)
                pushToPhone(session)
                HangSessionDraft.clear(in: draftDefaults)
            case .poseLearned(let gravity):
                poseStore.save(HangPoseProfile(hangGravity: gravity))
            }
        }
    }

    private static let hapticMap: [SessionEngine.HapticKind: WKHapticType] = [
        .click: .click,
        .start: .start,
        .stop: .stop,
        .success: .success,
    ]

    /// Push the engine snapshot onto the SwiftUI-observed properties. Guarded
    /// assignment: `@Published` fires `objectWillChange` on EVERY assignment,
    /// even when the value is unchanged — so only assign on real changes.
    private func syncPublished(force: Bool = false) {
        let s = engine.snapshot()
        let newState = TrackerSessionState(s.sessionPhase)
        if force || sessionState != newState { sessionState = newState }
        let newHold = TrackerHoldState(s.holdPhase)
        if force || holdState != newHold { holdState = newHold }
        if force || detectSeconds != s.detectSeconds { detectSeconds = s.detectSeconds }
        if force || holdSeconds != s.holdSeconds { holdSeconds = s.holdSeconds }
        if force || totalHoldTime != s.totalHoldTime { totalHoldTime = s.totalHoldTime }
        if force || reps != s.reps { reps = s.reps }
        if force || countdownValue != s.countdownValue { countdownValue = s.countdownValue }
        if force || isUserPaused != s.isUserPaused { isUserPaused = s.isUserPaused }
    }
}

// Colour palette now lives in Shared/HangTheme.swift so the iOS app can reuse
// the exact same values. (See HangTheme.swift.)

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

struct WatchLayoutMetrics {
    let size: CGSize
    let isCompact: Bool
    let horizontalPadding: CGFloat
    let sectionSpacing: CGFloat
    let tightSpacing: CGFloat
    let ringMinDiameter: CGFloat
    let ringMaxDiameter: CGFloat
    let badgeSize: CGFloat
    let badgeIconSize: CGFloat
    let repsLabelSize: CGFloat
    let repsValueSize: CGFloat
    let hintHeight: CGFloat
    let hintTextSize: CGFloat
    let hintIconSize: CGFloat
    let idleIconSize: CGFloat
    let titleSize: CGFloat
    let subtitleSize: CGFloat
    let stateCardHeight: CGFloat
    let stateIconSize: CGFloat
    let stateTitleSize: CGFloat
    let stateSubtitleSize: CGFloat
    let stateMetricSize: CGFloat
    let stateProgressWidth: CGFloat
    let buttonHeight: CGFloat
    let buttonFontSize: CGFloat
    let cardCornerRadius: CGFloat
    let statIconSize: CGFloat
    let statValueSize: CGFloat
    let statLabelSize: CGFloat
    let statCardVerticalPadding: CGFloat
    
    init(size: CGSize) {
        self.size = size
        
        let compactHeight = size.height <= 215
        let compactWidth = size.width <= 176
        isCompact = compactHeight || compactWidth
        
        horizontalPadding = (size.width * 0.065).clamped(to: 10...16)
        sectionSpacing = isCompact ? 8 : 10
        tightSpacing = isCompact ? 4 : 6
        ringMinDiameter = isCompact ? 76 : 88
        ringMaxDiameter = isCompact ? 118 : 138
        badgeSize = isCompact ? 32 : 38
        badgeIconSize = isCompact ? 14 : 17
        repsLabelSize = isCompact ? 10 : 11
        repsValueSize = isCompact ? 42 : 50
        hintHeight = isCompact ? 34 : 38
        hintTextSize = isCompact ? 9 : 10
        hintIconSize = isCompact ? 14 : 16
        idleIconSize = isCompact ? 42 : 52
        titleSize = isCompact ? 17 : 19
        subtitleSize = isCompact ? 10 : 12
        stateCardHeight = isCompact ? 44 : 50
        stateIconSize = isCompact ? 12 : 14
        stateTitleSize = isCompact ? 10 : 11
        stateSubtitleSize = isCompact ? 8 : 9
        stateMetricSize = isCompact ? 11 : 12
        stateProgressWidth = isCompact ? 54 : 64
        buttonHeight = isCompact ? 30 : 34
        buttonFontSize = isCompact ? 10 : 11
        cardCornerRadius = isCompact ? 12 : 14
        statIconSize = isCompact ? 12 : 14
        statValueSize = isCompact ? 18 : 22
        statLabelSize = isCompact ? 7 : 8
        statCardVerticalPadding = isCompact ? 8 : 10
    }
}

// MARK: - Main View
struct PullUpTrackerView: View {
    @StateObject private var viewModel = PullUpTrackerViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @State private var showDebugOverlay = false
    @State private var fixtureIndex = -1
    @State private var debugModeLabel: String = ""
    #endif

    /// System transition vocabulary: soft cross-fade with a barely-there
    /// scale insert — how Apple's own watch apps move between states.
    private var screenTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96)),
            removal: .opacity
        )
    }

    var body: some View {
        ZStack {
            Color.oledBlack
                .ignoresSafeArea()

            #if DEBUG
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if !debugModeLabel.isEmpty {
                        Text("FIXTURE: \(debugModeLabel)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.yellow)
                            .cornerRadius(3)
                    }
                }
                Spacer()
            }
            #endif
            Group {
                switch viewModel.sessionState {
                case .idle:
                    IdleView(onStart: viewModel.beginSession, reduceMotion: reduceMotion)
                        .transition(screenTransition)
                case .countdown:
                    CountdownView(
                        value: viewModel.countdownValue,
                        onCancel: viewModel.cancelCountdown,
                        reduceMotion: reduceMotion
                    )
                    .transition(screenTransition)
                case .active:
                    ActiveView(
                        holdState: viewModel.holdState,
                        detectSeconds: viewModel.detectSeconds,
                        holdSeconds: viewModel.holdSeconds,
                        reps: viewModel.reps,
                        progress: viewModel.progress,
                        totalHoldTime: viewModel.totalHoldTime,
                        onEnd: viewModel.endSession,
                        onPause: viewModel.pauseSession,
                        onResume: viewModel.resumeSession,
                        isUserPaused: viewModel.isUserPaused,
                        onDismissHint: viewModel.dismissHint,
                        showHint: viewModel.showHint,
                        reduceMotion: reduceMotion
                    )
                    .transition(screenTransition)
                case .summary:
                    SummaryView(
                        reps: viewModel.reps,
                        totalHoldTime: viewModel.totalHoldTime,
                        onDone: viewModel.backToIdle,
                        onRepeat: viewModel.repeatSession,
                        reduceMotion: reduceMotion
                    )
                    .transition(screenTransition)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                       value: viewModel.sessionState)
        }
        #if DEBUG
        .overlay(alignment: .bottom) {
            if viewModel.sessionState == .active && showDebugOverlay {
                VStack(spacing: 1) {
                    Text(String(format: "X:%.2f Y:%.2f Z:%.2f",
                                viewModel.debugX, viewModel.debugY, viewModel.debugZ))
                    Text("\(viewModel.debugState) | \(viewModel.debugAccelStatus)")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.green)
                .padding(3)
                .background(Color.black.opacity(0.8))
                .cornerRadius(4)
                .padding(.bottom, 2)
            }
        }
        .onLongPressGesture(minimumDuration: 2.0) {
            if viewModel.sessionState == .active {
                showDebugOverlay.toggle()
            }
        }
        #endif
        .onAppear {
            // Request HealthKit access up front so the system permission sheet
            // never interrupts the 3-2-1 countdown mid-session.
            viewModel.prepareHealthKit()
        }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            // Bottom-right hot corner: tap cycles deterministic UI fixtures
            // (waiting → detecting → holding → summary → off) so every screen
            // can be captured without depending on simulator sensor input.
            // (Long-press isn't injectable by idb; taps are reliable. The
            // bottom-right corner is free of system chrome on every screen.)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: 30, height: 44)
                .onTapGesture {
                    let modes = ["waiting", "detecting", "holding", "summary"]
                    fixtureIndex = (fixtureIndex + 1) % (modes.count + 1)
                    if fixtureIndex == modes.count {
                        viewModel.debugStopFixture()
                    } else {
                        viewModel.debugApplyFixture(modes[fixtureIndex])
                    }
                    debugModeLabel = fixtureIndex == modes.count ? "" : modes[fixtureIndex]
                }
        }
        .ignoresSafeArea(edges: .bottom)
        #endif
        .persistentSystemOverlays(.hidden)
    }
}

// MARK: - Idle View
struct IdleView: View {
    let onStart: () -> Void
    let reduceMotion: Bool
    @State private var buttonScale: CGFloat = 1.0
    @State private var iconScale: CGFloat = 1.0
    
    var body: some View {
        GeometryReader { geometry in
            let metrics = WatchLayoutMetrics(size: geometry.size)
            
            VStack(spacing: metrics.sectionSpacing) {
                Spacer(minLength: 0)
                
                VStack(spacing: metrics.sectionSpacing * 1.5) {
                    Image(systemName: "figure.core.training")
                        .font(.system(size: metrics.idleIconSize))
                        .foregroundColor(.orange)
                        .scaleEffect(iconScale)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                                iconScale = 1.1
                            }
                        }
                    
                    VStack(spacing: metrics.tightSpacing) {
                        Text("Hang Tracker")
                            .font(.system(size: metrics.titleSize, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.75)

                        Text("Hang 10s = 1 set")
                            .font(.system(size: metrics.subtitleSize, weight: .medium, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .padding(.horizontal, metrics.horizontalPadding)
                
                Spacer(minLength: metrics.sectionSpacing)
                
                // Apple Workout start control: full-width vivid-green pill
                // (HIG Buttons), black label for contrast.
                Button(action: {
                    if !reduceMotion {
                        buttonScale = 0.95
                        withAnimation(.easeOut(duration: 0.1)) {
                            buttonScale = 1.0
                        }
                    }
                    onStart()
                }) {
                    Text("Start Session")
                        .font(.system(size: metrics.buttonFontSize + 2, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.green)
                        .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
                .scaleEffect(buttonScale)
                .padding(.horizontal, metrics.horizontalPadding)
                .accessibilityLabel("Start session")
                .accessibilityHint("Begins a 3 second countdown, then tracks your hang")
            }
            .padding(.vertical, metrics.sectionSpacing)
        }
    }
}

// MARK: - Active View
struct ActiveView: View {
    let holdState: TrackerHoldState
    let detectSeconds: Int
    let holdSeconds: Int
    let reps: Int
    let progress: Double
    let totalHoldTime: Int
    let onEnd: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let isUserPaused: Bool
    let onDismissHint: () -> Void
    let showHint: Bool
    let reduceMotion: Bool

    @State private var showStartFlash = false
    @State private var waitingPulse: CGFloat = 1.0
    /// Shows the Pause/End confirmation overlay. Auto-dismisses after a few
    /// seconds so a stray tap can't leave the user staring at choices.
    @State private var showPauseMenu = false
    @State private var pauseMenuDismissTask: DispatchWorkItem?

    // Apple Fitness vocabulary, expressed in SYSTEM colors so vibrancy and
    // accessibility settings behave exactly like first-party apps:
    // orange = live workout accent, blue = waiting on the user,
    // green = completion, red = end/stop.
    private var repsColor: Color {
        holdState == .waiting ? Color.white.opacity(0.35) : .orange
    }
    
    private var ringTrackColor: Color {
        Color.white.opacity(0.12)
    }
    
    /// Colour for the holding ring, banded by progress. Semantics go from
    /// "just started" (orange) → "building" (yellow) → "about to finish" (green),
    /// so the closer to completing a 10s rep, the more positive the colour.
    /// This matches Apple's Activity ring convention (completing = green) and
    /// is the inverse of the old scheme which turned red near completion.
    private var holdBandColor: Color {
        switch holdBand {
        case .warming:   return .orange
        case .cruising:  return .yellow
        case .finishing: return .green
        case .none:      return .orange
        }
    }

    /// Encouragement band derived purely from `holdState` + `progress` via the
    /// shared `TrackerLogic` so the colour semantics stay single-sourced and
    /// unit-tested.
    private var holdBand: TrackerLogic.HoldBand? {
        guard holdState == .holding else { return nil }
        return TrackerLogic.band(forHoldingProgress: progress)
    }

    private var ringProgressColor: Color {
        switch holdState {
        case .waiting:
            return .blue
        case .detecting:
            return .orange
        case .holding:
            return holdBandColor
        }
    }

    private var phaseLabelColor: Color {
        switch holdState {
        case .waiting:
            return Color.blue.opacity(0.85)
        case .detecting:
            return .orange
        case .holding:
            return holdBandColor
        }
    }
    
    private var primaryValueColor: Color {
        Color.white.opacity(0.96)
    }

    private var ringProgress: Double {
        guard holdState != .waiting else { return 0.0 }
        return min(progress / 100.0, 1.0)
    }

    private var phaseLabelText: LocalizedStringKey {
        switch holdState {
        case .waiting:
            // Instruction for the user's NEXT action, valid both before the
            // first grab and after a drop: get on the bar. ("Raise Wrist"
            // was misleading once they were already hanging.)
            return "Grab the Bar"
        case .detecting:
            // ~1 s settle window after the pose is confirmed. The ring now
            // fills during this phase, so the user SEES confirmation working
            // instead of a static prompt.
            return "Locked On\nStarting…"
        case .holding:
            return "Keep Going!"
        }
    }

    /// VoiceOver-friendly description of the ring's centre, combining the phase
    /// with the live count so a user not looking at the screen still gets the
    /// essential "how long / how many" signal.
    private var centerAccessibilityLabel: String {
        switch holdState {
        case .waiting:
            return "Grab the bar to start counting"
        case .detecting:
            return "Hang confirmed, starting soon"
        case .holding:
            return "Holding, \(holdSeconds) of \(TrackerLogic.targetHoldSeconds) seconds"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height

            let strokeRatio: CGFloat = 0.038
            let ringDiameter = (screenWidth - 2) / (1 + strokeRatio)
            let ringStrokeWidth = max(ringDiameter * strokeRatio, 8.0)
            let countdownSize = ringDiameter * 0.28
            let repsValueSize = ringDiameter * 0.14
            let phaseLabelSize = ringDiameter * 0.058
            let waitingIconSize = ringDiameter * 0.13
            let pauseButtonSize = ringDiameter * 0.13
            let pauseIconSize = ringDiameter * 0.052
            let topInset = ringDiameter * 0.11
            let bottomInset = ringDiameter * 0.11
            let centerValueOffsetY = -ringDiameter * 0.01
            let arcRotation = Angle.degrees(-68)
            
            ZStack {
                Circle()
                    .stroke(ringTrackColor, lineWidth: ringStrokeWidth)
                    .frame(width: ringDiameter, height: ringDiameter)

                if holdState != .waiting {
                    // Waiting keeps a bare, quiet track (no dashed spinner —
                    // "processing" is not Apple's language for "your turn").
                    // The ring fills during BOTH the ~1 s settle window
                    // (detecting) and the hold itself, sweeping smoothly.
                    Circle()
                        .trim(from: 0, to: ringProgress)
                        .stroke(
                            ringProgressColor,
                            style: StrokeStyle(lineWidth: ringStrokeWidth, lineCap: .round)
                        )
                        .rotationEffect(arcRotation)
                        .frame(width: ringDiameter, height: ringDiameter)
                        .shadow(color: ringProgressColor.opacity(0.15), radius: 4, x: 0, y: 0)
                // Activity-ring trick: values change once per second, but a 1 s
                // LINEAR interpolation makes the arc glide through the second.
                        .animation(reduceMotion ? nil : .linear(duration: 1.0), value: ringProgress)
                }

                Group {
                    switch holdState {
                    case .waiting:
                        VStack(spacing: ringDiameter * 0.03) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: waitingIconSize * 0.82, weight: .medium))
                                .foregroundColor(.blue)
                                .scaleEffect(waitingPulse)
                            Text(phaseLabelText)
                                .font(.system(size: phaseLabelSize * 1.15, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                                waitingPulse = 1.15
                            }
                        }
                    case .detecting:
                        // The hang pose is confirmed; the ring fills while the
                        // ~1 s settle tick elapses, giving visible feedback that
                        // detection worked and counting is about to start.
                        VStack(spacing: ringDiameter * 0.03) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: waitingIconSize, weight: .semibold))
                                .foregroundColor(.orange)
                                .scaleEffect(waitingPulse)
                            Text(phaseLabelText)
                                .font(.system(size: phaseLabelSize * 1.25, weight: .semibold, design: .rounded))
                                .foregroundColor(phaseLabelColor)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.7)
                                .lineLimit(2)
                        }
                    case .holding:
                        VStack(spacing: ringDiameter * 0.022) {
                            Text("\(holdSeconds)")
                                .font(.system(size: countdownSize, weight: .heavy, design: .rounded))
                                .foregroundColor(primaryValueColor)
                                .monospacedDigit()
                                .minimumScaleFactor(0.72)
                                .lineLimit(1)
                                .contentTransition(.numericText())
                                .animation(reduceMotion ? nil : .linear(duration: 0.25), value: holdSeconds)
                            Text(phaseLabelText)
                                .font(.system(size: phaseLabelSize, weight: .medium, design: .rounded))
                                .foregroundColor(phaseLabelColor)
                        }
                    }
                }
                .offset(y: centerValueOffsetY)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(centerAccessibilityLabel)
                .accessibilityValue("\(Int(progress)) percent of current set")

                if showStartFlash {
                    Circle()
                        .trim(from: 0, to: ringProgress)
                        .stroke(ringProgressColor, style: StrokeStyle(lineWidth: ringStrokeWidth, lineCap: .round))
                        .rotationEffect(arcRotation)
                        .frame(width: ringDiameter, height: ringDiameter)
                        .shadow(color: ringProgressColor.opacity(0.6), radius: 18)
                        .blur(radius: 2)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    if reps == 0 && holdState == .waiting {
                        EmptyView()
                    } else {
                        Text("\(reps)")
                        .font(.system(size: repsValueSize, weight: .bold, design: .rounded))
                        .foregroundColor(repsColor)
                        .monospacedDigit()
                        .minimumScaleFactor(0.75)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7), value: reps)
                        .accessibilityLabel("\(reps) sets completed")
                    }
                }
                .padding(.top, topInset)
            }
            .overlay(alignment: .bottom) {
                // Bottom control. When the user has paused, this is a single
                // "Resume" button. Otherwise a tap opens an inline Pause/End
                // confirmation overlay (auto-dismisses) — so a tap never
                // silently ends the session and discards progress.
                Group {
                    if isUserPaused {
                        Button(action: onResume) {
                            Image(systemName: "play.fill")
                                .font(.system(size: pauseIconSize, weight: .black))
                                .foregroundColor(.green)
                                .frame(width: pauseButtonSize, height: pauseButtonSize)
                                .background(Circle().fill(Color.green.opacity(0.18)))
                                .overlay(Circle().stroke(Color.green.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("Resume")
                    } else {
                        // Pause is a workout CONTROL (orange), not a danger —
                        // red stays reserved for the End action in the sheet.
                        Button {
                            presentPauseMenu()
                        } label: {
                            Image(systemName: "pause.fill")
                                .font(.system(size: pauseIconSize, weight: .black))
                                .foregroundColor(holdState == .waiting ? .white : .orange)
                                .frame(width: pauseButtonSize, height: pauseButtonSize)
                                .background(Circle().fill(
                                    holdState == .waiting
                                        ? Color.white.opacity(0.12)
                                        : Color.orange.opacity(0.18)))
                                .overlay(Circle().stroke(
                                    holdState == .waiting
                                        ? Color.white.opacity(0.25)
                                        : Color.orange.opacity(0.5),
                                    lineWidth: 1))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("Pause or end")
                    }
                }
                .padding(.bottom, bottomInset)
            }
            .frame(width: ringDiameter, height: ringDiameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.oledBlack)
            // Inline Pause/End confirmation. Replaces the old contextMenu (which
            // required a long-press on watchOS and felt broken). A tap on the
            // pause button reveals these two choices centred on the ring; they
            // auto-dismiss after a few seconds so nothing is left dangling.
            .overlay {
                if showPauseMenu {
                    pauseConfirmationOverlay(ringDiameter: ringDiameter,
                                             buttonSize: pauseButtonSize,
                                             labelSize: phaseLabelSize)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: holdState) { newState in
            if newState == .holding {
                withAnimation(.easeOut(duration: 0.2)) {
                    showStartFlash = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.easeIn(duration: 0.2)) {
                        showStartFlash = false
                    }
                }
            }
        }
    }

    // MARK: - Pause confirmation

    /// Show the Pause/End choices and schedule an auto-dismiss.
    private func presentPauseMenu() {
        withAnimation(.easeOut(duration: 0.15)) { showPauseMenu = true }
        pauseMenuDismissTask?.cancel()
        let task = DispatchWorkItem { dismissPauseMenu() }
        pauseMenuDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
    }

    private func dismissPauseMenu() {
        withAnimation(.easeIn(duration: 0.15)) { showPauseMenu = false }
        pauseMenuDismissTask?.cancel()
        pauseMenuDismissTask = nil
    }

    /// Two-button overlay: Pause (resumable) and End (finish → summary). Tapping
    /// anywhere else on the dimmed backdrop cancels. Sized via the caller's
    /// geometry-derived values.
    @ViewBuilder
    private func pauseConfirmationOverlay(ringDiameter: CGFloat,
                                          buttonSize: CGFloat,
                                          labelSize: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { dismissPauseMenu() }

            // True watchOS-alert vocabulary: a dark rounded CARD carrying the
            // title + buttons (kills background bleed-through), translucent
            // capsules with white labels; the destructive action is RED TEXT,
            // not a red fill. No icons — system confirmations are text-only.
            VStack(spacing: ringDiameter * 0.035) {
                Text("Pause or End?")
                    .font(.system(size: labelSize * 1.35, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                VStack(spacing: ringDiameter * 0.026) {
                    Button {
                        dismissPauseMenu()
                        onPause()
                    } label: {
                        Text("Pause")
                            .font(.system(size: labelSize * 1.3, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: buttonSize * 0.72)
                            .background(Color.white.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Pause session")

                    Button(role: .destructive) {
                        dismissPauseMenu()
                        onEnd()
                    } label: {
                        Text("End")
                            .font(.system(size: labelSize * 1.3, weight: .bold, design: .rounded))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: buttonSize * 0.72)
                            .background(Color.white.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("End session")
                }
            }
            .padding(.horizontal, ringDiameter * 0.055)
            .padding(.vertical, ringDiameter * 0.05)
            .background(RoundedRectangle(cornerRadius: ringDiameter * 0.1)
                .fill(Color(white: 0.10)))
            .padding(.horizontal, ringDiameter * 0.06)
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Summary View
struct SummaryView: View {
    let reps: Int
    let totalHoldTime: Int
    let onDone: () -> Void
    let onRepeat: () -> Void
    let reduceMotion: Bool

    @State private var showContent = false
    @State private var checkmarkScale: CGFloat = 0.3

    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private var avgHoldTime: String {
        reps > 0 ? String(format: "%.1f", Double(totalHoldTime) / Double(reps)) : "0"
    }

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let padding = w * 0.06

            ZStack {
                Color.oledBlack.ignoresSafeArea()

                if !showContent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: min(w, h) * 0.22))
                        .foregroundColor(.green)
                        .scaleEffect(checkmarkScale)
                } else {
                    VStack(spacing: h * 0.025) {
                        VStack(spacing: h * 0.02) {
                            HStack(spacing: padding * 0.5) {
                                summaryStat(icon: "figure.pullup", value: "\(reps)", label: "REPS", color: .orange, w: w)
                                summaryStat(icon: "timer", value: formatTime(totalHoldTime), label: "TIME", color: .orange, w: w)
                            }

                            HStack(spacing: padding * 0.5) {
                                summaryStat(icon: "stopwatch", value: "\(avgHoldTime)s", label: "AVG HOLD", color: .white, w: w)
                                // "SET" = the per-set target (10s). This used to be a
                                // decorative "GOAL: 10s" card with no real meaning; it is
                                // now labelled honestly as the per-set target reference.
                                summaryStat(icon: "target", value: "10s", label: "SET", color: .white, w: w)
                            }
                        }
                        .frame(maxHeight: .infinity)

                        HStack(spacing: padding * 0.4) {
                            Button(action: onRepeat) {
                                Text("Again")
                                    .font(.system(size: w * 0.048, weight: .bold, design: .rounded))
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                                    .background(Color.green)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .accessibilityLabel("Start another set")

                            Button(action: onDone) {
                                Text("Done")
                                    .font(.system(size: w * 0.045, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: h * 0.12)
                                    .background(Color.white.opacity(0.15))
                                    .cornerRadius(h * 0.06)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, padding)
                    .padding(.vertical, h * 0.04)
                    .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            if reduceMotion {
                showContent = true
                checkmarkScale = 1.0
            } else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    checkmarkScale = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showContent = true
                    }
                }
            }
        }
    }

    private func summaryStat(icon: String, value: String, label: String, color: Color, w: CGFloat) -> some View {
        VStack(spacing: w * 0.012) {
            Image(systemName: icon)
                .font(.system(size: w * 0.06))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: w * 0.1, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: value)

            Text(label)
                .font(.system(size: w * 0.035, weight: .semibold, design: .rounded))
                .foregroundColor(color.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardBackground)
        .cornerRadius(w * 0.045)
    }
}

// MARK: - Countdown View
//
// Shown for the 3-2-1 seconds between tapping "Start" and motion detection
// actually beginning. Gives the user time to grab the bar and raise their
// wrist. The number is driven by `ViewModel.countdownValue`; each tick also
// fires a `.click` haptic from the ViewModel so the user can feel the cadence
// without looking.
struct CountdownView: View {
    let value: Int
    let onCancel: () -> Void
    let reduceMotion: Bool

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height) * 0.42

            ZStack {
                Color.oledBlack.ignoresSafeArea()

                VStack(spacing: geometry.size.height * 0.03) {
                    Text("Get Ready")
                        .font(.system(size: geometry.size.width * 0.06,
                                      weight: .semibold, design: .rounded))
                        .foregroundColor(Color.white.opacity(0.5))

                    Text("\(max(value, 0))")
                        .font(.system(size: size, weight: .heavy, design: .rounded))
                        .foregroundColor(.orange)
                        .monospacedDigit()
                        .scaleEffect(pulseScale)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: value)
                        .accessibilityLabel("\(max(value, 0))")

                    // One-tap exit from a mis-started countdown. Previously
                    // cancelCountdown() existed but nothing called it — users
                    // had to ride out the countdown, then pause-menu → End →
                    // Done to back out of an accidental Start.
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: geometry.size.width * 0.042,
                                          weight: .semibold, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.75))
                            .padding(.horizontal, geometry.size.width * 0.08)
                            .padding(.vertical, geometry.size.height * 0.014)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(geometry.size.height * 0.03)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Cancel countdown")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .onChange(of: value) { _ in
            // Pop the number on each tick so the change reads even at a glance.
            guard !reduceMotion else { return }
            pulseScale = 1.25
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
                pulseScale = 1.0
            }
        }
    }
}

struct PullUpTrackerView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ActiveView(
                holdState: .waiting,
                detectSeconds: 0,
                holdSeconds: 0,
                reps: 2,
                progress: 0,
                totalHoldTime: 24,
                onEnd: {},
                onPause: {},
                onResume: {},
                isUserPaused: false,
                onDismissHint: {},
                showHint: true,
                reduceMotion: false
            )
            .previewDisplayName("Waiting — SE 40mm")
            .previewLayout(.fixed(width: 324, height: 394))

            ActiveView(
                holdState: .detecting,
                detectSeconds: 2,
                holdSeconds: 0,
                reps: 1,
                progress: 66,
                totalHoldTime: 12,
                onEnd: {},
                onPause: {},
                onResume: {},
                isUserPaused: false,
                onDismissHint: {},
                showHint: false,
                reduceMotion: false
            )
            .previewDisplayName("Detecting — SE 44mm")
            .previewLayout(.fixed(width: 368, height: 448))

            ActiveView(
                holdState: .holding,
                detectSeconds: 3,
                holdSeconds: 7,
                reps: 4,
                progress: 72,
                totalHoldTime: 68,
                onEnd: {},
                onPause: {},
                onResume: {},
                isUserPaused: false,
                onDismissHint: {},
                showHint: false,
                reduceMotion: false
            )
            .previewDisplayName("Holding — SE 40mm")
            .previewLayout(.fixed(width: 324, height: 394))

            ActiveView(
                holdState: .waiting,
                detectSeconds: 0,
                holdSeconds: 0,
                reps: 4,
                progress: 0,
                totalHoldTime: 68,
                onEnd: {},
                onPause: {},
                onResume: {},
                isUserPaused: true,
                onDismissHint: {},
                showHint: false,
                reduceMotion: false
            )
            .previewDisplayName("Paused (resume button) — SE 40mm")
            .previewLayout(.fixed(width: 324, height: 394))

            SummaryView(
                reps: 4,
                totalHoldTime: 40,
                onDone: {},
                onRepeat: {},
                reduceMotion: false
            )
            .previewDisplayName("Summary — SE 40mm")
            .previewLayout(.fixed(width: 324, height: 394))
        }
    }
}
