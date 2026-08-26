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
    #endif

    /// Single source of truth for the platform-independent counting pipeline.
    /// The `@Published` properties above are kept in sync with this value type
    /// via `syncPublished()`. The pure logic is unit-tested independently
    /// (see `TrackerLogicTests`) so the ViewModel only needs to wire platform
    /// pieces (CoreMotion, HealthKit, haptics) onto it.
    private var logic = TrackerLogic()

    private let motionManager = CMMotionManager()
    private var stateMachine = MotionStateMachine()

    private var countTimer: Timer?

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?

    /// Persists every completed session so the phone can show history/growth.
    /// Injectable so tests can swap in an isolated store.
    var sessionStore: HangSessionStore = HangSessionStore()

    var playHaptic: (WKHapticType) -> Void = { WKInterfaceDevice.current().play($0) }

    var progress: Double {
        logic.progress
    }

    private func startWorkoutSession() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let typesToShare: Set = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: typesToShare, read: nil) { success, _ in
            DispatchQueue.main.async {
                if success { self.beginWorkoutSession() }
            }
        }
    }

    private func beginWorkoutSession() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor

        do {
            workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            workoutSession?.startActivity(with: Date())
        } catch { }
    }

    private func stopWorkoutSession() {
        guard let session = workoutSession else { return }
        session.end()
        workoutSession = nil
    }

    func startSession() {
        guard sessionState != .active else { return }
        logic.startSession()
        stateMachine.reset()
        showHint = true
        isUserPaused = false
        syncPublished()

        print("🔴 [PullUp] startSession called")
        startWorkoutSession()
        startAccelerometers()
        startCountTimer()
    }

    /// UI entry point from the Idle "Start" button. Begins the 3-2-1 countdown
    /// so the user has time to grab the bar before motion detection kicks in.
    /// When the countdown elapses, `updateTimer()` transitions into `.active`.
    func beginSession() {
        guard sessionState == .idle else { return }
        logic.startCountdown()
        stateMachine.reset()
        showHint = true
        isUserPaused = false
        syncPublished()

        print("🔴 [PullUp] beginSession (countdown) called")
        startWorkoutSession()
        startAccelerometers()
        startCountTimer()
        playHaptic(.start)
    }

    /// "Again" from the Summary screen: start a fresh countdown session
    /// (counters reset). Lets the user chain sets without going back to idle.
    func repeatSession() {
        guard sessionState == .summary else { return }
        stopWorkoutSession()           // end the previous workout before starting fresh
        logic.startCountdown()
        stateMachine.reset()
        showHint = true
        isUserPaused = false
        syncPublished()

        startWorkoutSession()
        startAccelerometers()
        startCountTimer()
        playHaptic(.start)
    }

    /// Abort the countdown (e.g. user taps cancel during 3-2-1).
    func cancelCountdown() {
        logic.cancelCountdown()
        syncPublished()
        motionManager.stopAccelerometerUpdates()
        stopCountTimer()
        stopWorkoutSession()
    }

    func endSession() {
        // Persist the session before resetting, but only if something was
        // actually achieved — an accidental immediate end shouldn't write a
        // zero-length record into the history.
        if logic.totalHoldTime > 0 {
            let session = HangSession(reps: logic.reps, totalSeconds: logic.totalHoldTime)
            sessionStore.append(session)
            pushToPhone(session)
        }
        logic.endSession()
        isUserPaused = false
        syncPublished()
        motionManager.stopAccelerometerUpdates()
        stopCountTimer()
        stopWorkoutSession()
    }

    /// Push a completed session to the phone via WatchConnectivity so the
    /// phone's history/stats update without manual sync. Uses
    /// `updateApplicationContext`, which is buffered and delivered when the
    /// phone is reachable (best-effort; the phone also keeps its own copy).
    private func pushToPhone(_ session: HangSession) {
        guard WCSession.isSupported() else { return }
        let wc = WCSession.default
        if wc.activationState != .activated { wc.activate() }
        guard
            let data = try? JSONEncoder().encode(session),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        try? wc.updateApplicationContext([HangConnectivity.sessionKey: object])
    }

    /// User-initiated pause: stop the timer and motion detection but KEEP all
    /// counters so the session can resume. This is distinct from `endSession`,
    /// which finalises into the summary. Previously the "pause" button called
    /// `endSession`, so a user expecting to resume would silently lose their
    /// progress — this fixes that.
    func pauseSession() {
        guard sessionState == .active, !isUserPaused else { return }
        isUserPaused = true
        stopCountTimer()
        motionManager.stopAccelerometerUpdates()
        // Leave the workout session running so background health tracking stays
        // alive during a brief pause; it is ended by endSession/backToIdle.
        holdState = .waiting
        playHaptic(.stop)
        print("🔴 [PullUp] pauseSession (resumable)")
    }

    /// Resume after a user-initiated pause. Restarts the timer and motion
    /// pipeline; counting resumes once the state machine re-confirms the pose.
    func resumeSession() {
        guard sessionState == .active, isUserPaused else { return }
        isUserPaused = false
        startAccelerometers()
        startCountTimer()
        playHaptic(.start)
        print("🔴 [PullUp] resumeSession")
    }

    func backToIdle() {
        logic.backToIdle()
        isUserPaused = false
        syncPublished()
        motionManager.stopAccelerometerUpdates()
        stopCountTimer()
        stopWorkoutSession()
    }

    func dismissHint() {
        showHint = false
    }

    private func startCountTimer() {
        countTimer?.invalidate()
        countTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateTimer()
        }
        RunLoop.current.add(countTimer!, forMode: .common)
    }

    func stopCountTimer() {
        countTimer?.invalidate()
        countTimer = nil
    }

    func updateTimer() {
        // During countdown, the 1-second timer drives the 3-2-1 numbers; once it
        // hits zero we transition into the active session (motion pipeline was
        // already armed in beginSession).
        if logic.sessionPhase == .countdown {
            let reachedZero = logic.tickCountdown()
            if reachedZero {
                logic.finishCountdown()
                playHaptic(.start)
            } else {
                playHaptic(.click)
            }
            syncPublished()
            return
        }

        let repCompleted = logic.tick(motionIsActive: stateMachine.state == .active)
        if repCompleted {
            celebrateRep()
        }
        syncPublished()
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
        print("🔴 [PullUp] startAccelerometers — isAccelerometerAvailable: \(isAvailable)")

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
            guard let data = data, let self = self else {
                print("🔴 [PullUp] accel callback: data=nil or self=nil")
                return
            }
            self.processMotion(x: data.acceleration.x,
                               y: data.acceleration.y,
                               z: data.acceleration.z)
        }
        print("🔴 [PullUp] accelerometer updates started, interval: \(motionManager.accelerometerUpdateInterval)")
    }

    func processMotion(x: Double, y: Double, z: Double, at timestamp: Date = Date()) {
        #if DEBUG
        debugCounter += 1
        if debugCounter % 30 == 0 {
            debugX = x
            debugY = y
            debugZ = z
            debugState = String(describing: stateMachine.state)
        }
        #endif

        let prevState = stateMachine.state
        let events = stateMachine.process(x: x, y: y, z: z, at: timestamp)

        #if DEBUG
        if debugCounter % 60 == 0 {
            let mag = (x * x + y * y + z * z).squareRoot()
            print("🔴 [PullUp] X:\(String(format: "%.2f", x)) Y:\(String(format: "%.2f", y)) Z:\(String(format: "%.2f", z)) |mag|:\(String(format: "%.2f", mag)) state:\(prevState)")
        }
        #endif

        for event in events {
            print("🔴 [PullUp] EVENT: \(event)")
            logic.apply(event: event)
            switch event {
            case .enteredActive, .resumedActive:
                playHaptic(.start)
            case .enteredPaused:
                playHaptic(.stop)
            }
        }
        syncPublished()
    }

    /// Push the pure-logic state back onto the SwiftUI-observed `@Published`
    /// properties. Centralised here so every mutation path stays consistent.
    private func syncPublished() {
        sessionState = TrackerSessionState(logic.sessionPhase)
        holdState = TrackerHoldState(logic.holdPhase)
        detectSeconds = logic.detectSeconds
        holdSeconds = logic.holdSeconds
        totalHoldTime = logic.totalHoldTime
        reps = logic.reps
        countdownValue = logic.countdownValue
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
    @State private var contentOpacity: Double = 0
    @State private var contentScale: CGFloat = 0.95
    #if DEBUG
    @State private var showDebugOverlay = false
    #endif
    
    var body: some View {
        ZStack {
            Color.oledBlack
                .ignoresSafeArea()

            Group {
                switch viewModel.sessionState {
                case .idle:
                    IdleView(onStart: viewModel.beginSession, reduceMotion: reduceMotion)
                        .opacity(contentOpacity)
                        .scaleEffect(contentScale)
                case .countdown:
                    CountdownView(
                        value: viewModel.countdownValue,
                        reduceMotion: reduceMotion
                    )
                    .opacity(contentOpacity)
                    .scaleEffect(contentScale)
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
                    .opacity(contentOpacity)
                    .scaleEffect(contentScale)
                case .summary:
                    SummaryView(
                        reps: viewModel.reps,
                        totalHoldTime: viewModel.totalHoldTime,
                        onDone: viewModel.backToIdle,
                        onRepeat: viewModel.repeatSession,
                        reduceMotion: reduceMotion
                    )
                    .opacity(contentOpacity)
                    .scaleEffect(contentScale)
                }
            }
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
            if reduceMotion {
                contentOpacity = 1.0
                contentScale = 1.0
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    contentOpacity = 1.0
                    contentScale = 1.0
                }
            }
        }
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
                        .foregroundColor(.successGreen)
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
                        .font(.system(size: metrics.buttonFontSize + 1, weight: .bold, design: .rounded))
                        .foregroundColor(Color.oledBlack)
                        .frame(maxWidth: .infinity)
                        .frame(height: metrics.buttonHeight + 8)
                        .background(Color.successGreen)
                        .cornerRadius((metrics.buttonHeight + 8) / 2)
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
    @State private var waitingRingRotation: Double = 0
    /// Shows the Pause/End confirmation overlay. Auto-dismisses after a few
    /// seconds so a stray tap can't leave the user staring at choices.
    @State private var showPauseMenu = false
    @State private var pauseMenuDismissTask: DispatchWorkItem?

    private var repsColor: Color {
        .energyOrange
    }
    
    private var ringTrackColor: Color {
        Color.white.opacity(0.08)
    }
    
    /// Colour for the holding ring, banded by progress. Semantics go from
    /// "just started" (orange) → "building" (yellow) → "about to finish" (green),
    /// so the closer to completing a 10s rep, the more positive the colour.
    /// This matches Apple's Activity ring convention (completing = green) and
    /// is the inverse of the old scheme which turned red near completion.
    private var holdBandColor: Color {
        switch holdBand {
        case .warming:   return .energyOrange
        case .cruising:  return Color(red: 0.99, green: 0.80, blue: 0.18) // warm yellow
        case .finishing: return .successGreen
        case .none:      return .energyOrange
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
            return .neonBlue
        case .detecting:
            return .energyOrange
        case .holding:
            return holdBandColor
        }
    }

    private var phaseLabelColor: Color {
        switch holdState {
        case .waiting:
            return .neonBlue.opacity(0.7)
        case .detecting:
            return .energyOrange.opacity(0.85)
        case .holding:
            return holdBandColor
        }
    }
    
    private var primaryValueColor: Color {
        Color.white.opacity(0.96)
    }

    private var endButtonBorderColor: Color {
        Color(red: 0.58, green: 0.08, blue: 0.11)
    }

    private var endButtonFillColor: Color {
        Color(red: 0.20, green: 0.03, blue: 0.04)
    }

    private var ringProgress: Double {
        guard holdState != .waiting else { return 0.0 }
        return min(progress / 100.0, 1.0)
    }

    private var phaseLabelText: LocalizedStringKey {
        switch holdState {
        case .waiting:
            // waiting = wrist not yet raised for long enough; tell the user what
            // to DO, not what the machine is doing. The old label "Detecting"
            // implied counting had started, which was misleading.
            return "Raise Wrist"
        case .detecting:
            // Motion is being confirmed as a stable hang. No countdown number is
            // shown here (only this prompt) so it doesn't read as a second 3-2-1.
            return "Hold Still\nStarting soon"
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
            return "Raise your wrist to start"
        case .detecting:
            return "Hold still, motion is being confirmed, starting soon"
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

                if holdState == .waiting {
                    Circle()
                        .stroke(
                            Color.neonBlue.opacity(0.35),
                            style: StrokeStyle(
                                lineWidth: ringStrokeWidth,
                                dash: [ringDiameter * 0.08, ringDiameter * 0.05]
                            )
                        )
                        .frame(width: ringDiameter, height: ringDiameter)
                        .rotationEffect(.degrees(waitingRingRotation))
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                                waitingRingRotation = 360
                            }
                        }
                } else if holdState == .holding {
                    // Only the holding phase draws a progress arc. During
                    // `.detecting` the ring stays bare (just the track) so it
                    // doesn't look like a second countdown racing the 3-2-1 —
                    // the motion-detection stability window still runs under the
                    // hood, but it presents as a calm "hold still" prompt.
                    Circle()
                        .trim(from: 0, to: ringProgress)
                        .stroke(
                            ringProgressColor,
                            style: StrokeStyle(lineWidth: ringStrokeWidth, lineCap: .round)
                        )
                        .rotationEffect(arcRotation)
                        .frame(width: ringDiameter, height: ringDiameter)
                        .shadow(color: ringProgressColor.opacity(0.22), radius: 6, x: 0, y: 0)
                }

                Group {
                    switch holdState {
                    case .waiting:
                        VStack(spacing: ringDiameter * 0.028) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: waitingIconSize, weight: .semibold))
                                .foregroundColor(.neonBlue)
                                .scaleEffect(waitingPulse)
                            Text(phaseLabelText)
                                .font(.system(size: phaseLabelSize, weight: .bold, design: .rounded))
                                .foregroundColor(phaseLabelColor)
                        }
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                                waitingPulse = 1.15
                            }
                        }
                    case .detecting:
                        // Motion is being validated but we show NO number here
                        // — only a calm prompt — so it can't be mistaken for a
                        // second countdown competing with the 3-2-1. The
                        // detection window still runs (detectSeconds ticks up in
                        // TrackerLogic) to confirm a stable hanging pose.
                        VStack(spacing: ringDiameter * 0.03) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: waitingIconSize, weight: .semibold))
                                .foregroundColor(.energyOrange)
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
                    Text("\(reps)")
                        .font(.system(size: repsValueSize, weight: .bold, design: .rounded))
                        .foregroundColor(repsColor)
                        .monospacedDigit()
                        .minimumScaleFactor(0.75)
                        .accessibilityLabel("\(reps) sets completed")
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
                                .foregroundColor(.successGreen)
                                .frame(width: pauseButtonSize, height: pauseButtonSize)
                                .background(Circle().fill(Color(red: 0.06, green: 0.16, blue: 0.09)))
                                .overlay(Circle().stroke(Color.successGreen.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("Resume")
                    } else {
                        Button {
                            presentPauseMenu()
                        } label: {
                            Image(systemName: "pause.fill")
                                .font(.system(size: pauseIconSize, weight: .black))
                                .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.47))
                                .frame(width: pauseButtonSize, height: pauseButtonSize)
                                .background(Circle().fill(endButtonFillColor))
                                .overlay(Circle().stroke(endButtonBorderColor, lineWidth: 1))
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

            VStack(spacing: ringDiameter * 0.04) {
                Text("Pause or End?")
                    .font(.system(size: labelSize * 1.3, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                HStack(spacing: ringDiameter * 0.05) {
                    Button {
                        dismissPauseMenu()
                        onPause()
                    } label: {
                        VStack(spacing: ringDiameter * 0.015) {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: buttonSize * 1.1))
                            Text("Pause")
                                .font(.system(size: labelSize, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(width: ringDiameter * 0.3, height: ringDiameter * 0.3)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button {
                        dismissPauseMenu()
                        onEnd()
                    } label: {
                        VStack(spacing: ringDiameter * 0.015) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: buttonSize * 1.1))
                            Text("End")
                                .font(.system(size: labelSize, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.47))
                        .frame(width: ringDiameter * 0.3, height: ringDiameter * 0.3)
                        .background(Circle().fill(endButtonFillColor))
                        .overlay(Circle().stroke(endButtonBorderColor, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
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
                        .foregroundColor(.successGreen)
                        .scaleEffect(checkmarkScale)
                } else {
                    VStack(spacing: h * 0.025) {
                        VStack(spacing: h * 0.02) {
                            HStack(spacing: padding * 0.5) {
                                summaryStat(icon: "figure.pullup", value: "\(reps)", label: "REPS", color: .energyOrange, w: w)
                                summaryStat(icon: "timer", value: formatTime(totalHoldTime), label: "TIME", color: .energyOrange, w: w)
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
                                    .font(.system(size: w * 0.045, weight: .bold, design: .rounded))
                                    .foregroundColor(.successGreen)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: h * 0.12)
                                    .background(Color.successGreen.opacity(0.18))
                                    .cornerRadius(h * 0.06)
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
                        .foregroundColor(.successGreen)
                        .monospacedDigit()
                        .scaleEffect(pulseScale)
                        .contentTransition(.opacity)
                        .accessibilityLabel("\(max(value, 0))")
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
