import SwiftUI
import CoreMotion
import WatchKit
import Combine
import HealthKit

enum TrackerSessionState {
    case idle
    case active
    case summary
}

enum TrackerHoldState {
    case waiting
    case detecting
    case holding
}

class PullUpTrackerViewModel: ObservableObject {
    @Published var sessionState: TrackerSessionState = .idle
    @Published var holdState: TrackerHoldState = .waiting

    @Published var detectSeconds: Int = 0
    @Published var holdSeconds: Int = 0
    @Published var totalHoldTime: Int = 0
    @Published var reps: Int = 0
    @Published var showHint: Bool = true

    #if DEBUG
    @Published var debugX: Double = 0
    @Published var debugY: Double = 0
    @Published var debugZ: Double = 0
    @Published var debugState: String = "idle"
    @Published var debugAccelStatus: String = "not started"
    private var debugCounter = 0
    #endif

    private let detectThreshold = 3
    private let targetHoldSeconds = 10

    private let motionManager = CMMotionManager()
    private var stateMachine = MotionStateMachine()

    private var countTimer: Timer?

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?

    var playHaptic: (WKHapticType) -> Void = { WKInterfaceDevice.current().play($0) }

    var progress: Double {
        if holdState == .detecting {
            return Double(detectSeconds) / Double(detectThreshold) * 100
        } else if holdState == .holding {
            return Double(holdSeconds) / Double(targetHoldSeconds) * 100
        }
        return 0
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
        sessionState = .active
        reps = 0
        totalHoldTime = 0
        detectSeconds = 0
        holdSeconds = 0
        holdState = .waiting
        stateMachine.reset()
        showHint = true

        print("🔴 [PullUp] startSession called")
        startWorkoutSession()
        startAccelerometers()
        startCountTimer()
    }

    func endSession() {
        sessionState = .summary
        holdState = .waiting
        motionManager.stopAccelerometerUpdates()
        stopCountTimer()
        stopWorkoutSession()
    }

    func backToIdle() {
        sessionState = .idle
        reps = 0
        totalHoldTime = 0
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

    private func stopCountTimer() {
        countTimer?.invalidate()
        countTimer = nil
    }

    private func updateTimer() {
        guard stateMachine.state == .active else { return }

        if holdState == .detecting {
            detectSeconds += 1
            if detectSeconds >= detectThreshold {
                holdState = .holding
                holdSeconds = 0
            }
        } else if holdState == .holding {
            holdSeconds += 1
            totalHoldTime += 1

            if holdSeconds >= targetHoldSeconds {
                reps += 1
                holdSeconds = 0
                celebrateRep()
            }
        }
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

    private func processMotion(x: Double, y: Double, z: Double) {
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
        let events = stateMachine.process(x: x, y: y, z: z)

        #if DEBUG
        if debugCounter % 60 == 0 {
            let mag = (x * x + y * y + z * z).squareRoot()
            print("🔴 [PullUp] X:\(String(format: "%.2f", x)) Y:\(String(format: "%.2f", y)) Z:\(String(format: "%.2f", z)) |mag|:\(String(format: "%.2f", mag)) state:\(prevState)")
        }
        #endif

        for event in events {
            print("🔴 [PullUp] EVENT: \(event)")
            switch event {
            case .enteredActive:
                holdState = .detecting
                detectSeconds = 0
                playHaptic(.start)
            case .enteredPaused:
                holdState = .waiting
                playHaptic(.stop)
            case .resumedActive:
                holdState = .detecting
                detectSeconds = 0
                playHaptic(.start)
            }
        }
    }
}

// MARK: - Color System
extension Color {
    static let oledBlack = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let successGreen = Color(red: 0.133, green: 0.773, blue: 0.369)
    static let energyOrange = Color(red: 0.976, green: 0.451, blue: 0.086)
    static let neonBlue = Color(red: 0.0, green: 0.8, blue: 1.0)
    static let dangerRed = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let cardBackground = Color(red: 0.102, green: 0.102, blue: 0.102)
    static let cardBackgroundAlt = Color(red: 0.110, green: 0.110, blue: 0.118)
    static let subtleBorder = Color.white.opacity(0.05)
}

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
    
    var body: some View {
        ZStack {
            Color.oledBlack
                .ignoresSafeArea()

            Group {
                switch viewModel.sessionState {
                case .idle:
                    IdleView(onStart: viewModel.startSession, reduceMotion: reduceMotion)
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
                        reduceMotion: reduceMotion
                    )
                    .opacity(contentOpacity)
                    .scaleEffect(contentScale)
                }
            }
        }
        #if DEBUG
        .overlay(alignment: .bottom) {
            if viewModel.sessionState == .active {
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

// MARK: - Start Hint Overlay
struct StartHintOverlay: View {
    let metrics: WatchLayoutMetrics
    let onTap: () -> Void
    let reduceMotion: Bool
    @State private var bounceOffset: CGFloat = 0
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: metrics.tightSpacing) {
                ZStack {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: metrics.hintIconSize, weight: .semibold))
                        .foregroundColor(.neonBlue)
                    
                    Image(systemName: "arrow.up")
                        .font(.system(size: metrics.hintIconSize * 0.72, weight: .heavy))
                        .foregroundColor(.neonBlue)
                        .offset(x: metrics.hintIconSize * 0.8, y: -metrics.hintIconSize * 0.5)
                }
                .offset(y: bounceOffset)
                
                Text("抬腕开始")
                    .font(.system(size: metrics.hintTextSize, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundColor(.neonBlue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: metrics.hintHeight)
            .padding(.horizontal, metrics.horizontalPadding)
            .background(
                Capsule()
                    .fill(Color.neonBlue.opacity(0.15))
                    .overlay(
                        Capsule()
                            .stroke(Color.neonBlue.opacity(0.3), lineWidth: 1)
                    )
            )
            .shadow(color: Color.neonBlue.opacity(0.18), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                bounceOffset = -4
            }
        }
    }
}

// MARK: - Progress Ring Component
struct ProgressRing: View {
    let progress: Double
    let diameter: CGFloat
    let strokeWidth: CGFloat
    
    private var progressGradient: AngularGradient {
        let p = progress / 100.0
        if p < 0.4 {
            return AngularGradient(
                gradient: Gradient(colors: [.successGreen, .successGreen]),
                center: .center,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + 360 * p)
            )
        } else if p < 0.8 {
            return AngularGradient(
                gradient: Gradient(colors: [.successGreen, .energyOrange]),
                center: .center,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + 360 * p)
            )
        } else {
            return AngularGradient(
                gradient: Gradient(colors: [.successGreen, .energyOrange, .dangerRed]),
                center: .center,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + 360 * p)
            )
        }
    }
    
    private var glowColor: Color {
        let p = progress
        if p < 40 { return .successGreen }
        else if p < 80 { return .energyOrange }
        else { return .dangerRed }
    }
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.cardBackgroundAlt, lineWidth: strokeWidth)
                .frame(width: diameter, height: diameter)
            
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: min(progress / 100, 1.0))
                    .stroke(
                        progressGradient,
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter, height: diameter)
                    .shadow(color: glowColor.opacity(0.3), radius: 6, x: 0, y: 0)
            }
        }
    }
}

// MARK: - State Badge Component
struct StateBadge: View {
    let holdState: TrackerHoldState
    let progress: Double
    let reduceMotion: Bool
    let size: CGFloat
    let iconSize: CGFloat
    @State private var pulseScale: CGFloat = 1.0
    
    private var badgeColor: Color {
        switch holdState {
        case .waiting: return .neonBlue
        case .detecting: return .energyOrange
        case .holding:
            let p = progress
            if p < 40 { return .successGreen }
            else if p < 80 { return .energyOrange }
            else { return .dangerRed }
        }
    }
    
    private var iconName: String {
        switch holdState {
        case .waiting: return "hand.raised.fill"
        case .detecting: return "arrow.triangle.2.circlepath"
        case .holding: return "lock.fill"
        }
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(badgeColor.opacity(0.2))
                .frame(width: size, height: size)
            
            Image(systemName: iconName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(badgeColor)
                .scaleEffect(holdState == .waiting ? pulseScale : 1.0)
                .rotationEffect(.degrees(holdState == .detecting && !reduceMotion ? 360 : 0))
                .animation(holdState == .detecting && !reduceMotion ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: holdState)
        }
        .onAppear {
            guard holdState == .waiting, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseScale = 1.1
            }
        }
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
                            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                                iconScale = 1.1
                            }
                        }
                    
                    VStack(spacing: metrics.tightSpacing) {
                        Text("Pull-up Tracker")
                            .font(.system(size: metrics.titleSize, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.75)
                        
                        Text("10 seconds = 1 rep")
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
    let onDismissHint: () -> Void
    let showHint: Bool
    let reduceMotion: Bool

    @State private var showStartFlash = false
    @State private var waitingPulse: CGFloat = 1.0
    @State private var waitingRingRotation: Double = 0

    private var repsColor: Color {
        .energyOrange
    }
    
    private var ringTrackColor: Color {
        Color.white.opacity(0.08)
    }
    
    private var ringProgressColor: Color {
        switch holdState {
        case .waiting:
            return .neonBlue
        case .detecting:
            return .energyOrange
        case .holding:
            let p = progress
            if p < 40 { return .successGreen }
            else if p < 80 { return .energyOrange }
            else { return .dangerRed }
        }
    }

    private var phaseLabelColor: Color {
        switch holdState {
        case .waiting:
            return .neonBlue.opacity(0.7)
        case .detecting:
            return .energyOrange.opacity(0.85)
        case .holding:
            let p = progress
            if p < 40 { return .successGreen }
            else if p < 80 { return .energyOrange }
            else { return .dangerRed }
        }
    }
    
    private var primaryValueColor: Color {
        Color.white.opacity(0.96)
    }
    
    private var secondaryTextColor: Color {
        Color(red: 0.32, green: 0.38, blue: 0.50)
    }
    
    private var endButtonBorderColor: Color {
        Color(red: 0.58, green: 0.08, blue: 0.11)
    }
    
    private var endButtonFillColor: Color {
        Color(red: 0.20, green: 0.03, blue: 0.04)
    }
    
    private var currentGoalSeconds: Int {
        holdState == .holding ? 10 : 3
    }
    
    private var displayedPrimaryValue: Int {
        switch holdState {
        case .waiting:
            return 0
        case .detecting:
            return detectSeconds
        case .holding:
            return holdSeconds
        }
    }
    
    private var ringProgress: Double {
        guard holdState != .waiting else { return 0.0 }
        return min(progress / 100.0, 1.0)
    }
    
    private var helperText: String {
        switch holdState {
        case .waiting:
            return "of 3s"
        case .detecting:
            return "of 3s"
        case .holding:
            return "of 10s"
        }
    }

    private var phaseLabelText: String {
        switch holdState {
        case .waiting:
            return "检测中"
        case .detecting:
            return "保持稳定"
        case .holding:
            return "坚持！"
        }
    }
    
    private var statusText: String {
        "REPS"
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
                } else {
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
                        VStack(spacing: ringDiameter * 0.022) {
                            Text("\(detectSeconds)")
                                .font(.system(size: countdownSize, weight: .heavy, design: .rounded))
                                .foregroundColor(primaryValueColor)
                                .monospacedDigit()
                                .minimumScaleFactor(0.72)
                                .lineLimit(1)
                            Text(phaseLabelText)
                                .font(.system(size: phaseLabelSize, weight: .medium, design: .rounded))
                                .foregroundColor(phaseLabelColor)
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

                if showStartFlash {
                    Text("开始！")
                        .font(.system(size: countdownSize * 0.48, weight: .black, design: .rounded))
                        .foregroundColor(.successGreen)
                        .transition(.scale.combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    Text("\(reps)")
                        .font(.system(size: repsValueSize, weight: .bold, design: .rounded))
                        .foregroundColor(repsColor)
                        .monospacedDigit()
                        .minimumScaleFactor(0.75)
                }
                .padding(.top, topInset)
            }
            .overlay(alignment: .bottom) {
                Button(action: onEnd) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: pauseIconSize, weight: .black))
                        .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.47))
                        .frame(width: pauseButtonSize, height: pauseButtonSize)
                        .background(
                            Circle()
                                .fill(endButtonFillColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(endButtonBorderColor, lineWidth: 1)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.bottom, bottomInset)
            }
            .frame(width: ringDiameter, height: ringDiameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.oledBlack)
        }
        .ignoresSafeArea()
        .onChange(of: holdState) { newState in
            if newState == .holding {
                withAnimation(.easeOut(duration: 0.2)) {
                    showStartFlash = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.easeIn(duration: 0.2)) {
                        showStartFlash = false
                    }
                }
            }
        }
    }
}

// MARK: - Summary View
struct SummaryView: View {
    let reps: Int
    let totalHoldTime: Int
    let onDone: () -> Void
    let reduceMotion: Bool
    
    @State private var contentOpacity: Double = 0
    @State private var contentScale: CGFloat = 0.95
    
    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    private var avgHoldTime: String {
        if reps > 0 {
            return String(format: "%.1f", Double(totalHoldTime) / Double(reps))
        }
        return "0"
    }
    
    var body: some View {
        GeometryReader { geometry in
            let metrics = WatchLayoutMetrics(size: geometry.size)
            
            VStack(spacing: metrics.sectionSpacing) {
                Spacer(minLength: 0)
                
                VStack(spacing: metrics.tightSpacing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: metrics.stateIconSize + 6))
                        .foregroundColor(.successGreen)
                    
                    Text("Session Complete")
                        .font(.system(size: metrics.titleSize, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
                .opacity(contentOpacity)
                .scaleEffect(contentScale)
                
                HStack(spacing: metrics.sectionSpacing) {
                    StatCard(
                        icon: "figure.pullup",
                        value: "\(reps)",
                        label: "REPS",
                        color: .energyOrange,
                        metrics: metrics
                    )
                    
                    StatCard(
                        icon: "timer",
                        value: formatTime(totalHoldTime),
                        label: "TIME",
                        color: .energyOrange,
                        metrics: metrics
                    )
                }
                
                HStack(spacing: metrics.sectionSpacing) {
                    StatCard(
                        icon: nil,
                        value: "\(avgHoldTime)s",
                        label: "AVG HOLD",
                        color: .white,
                        metrics: metrics
                    )
                    
                    StatCard(
                        icon: "target",
                        value: "10s",
                        label: "GOAL",
                        color: .white,
                        metrics: metrics
                    )
                }
                
                Spacer(minLength: 0)
                
                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: metrics.buttonFontSize + 1, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: metrics.buttonHeight + 4)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(metrics.cardCornerRadius)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.sectionSpacing)
        }
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
    }
}

// MARK: - Stat Card Component
struct StatCard: View {
    let icon: String?
    let value: String
    let label: String
    let color: Color
    let metrics: WatchLayoutMetrics
    
    var body: some View {
        VStack(spacing: metrics.tightSpacing) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: metrics.statIconSize))
                    .foregroundColor(color)
            }
            
            Text(value)
                .font(.system(size: metrics.statValueSize, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            
            Text(label)
                .font(.system(size: metrics.statLabelSize, weight: .semibold, design: .rounded))
                .tracking(1)
                .foregroundColor(Color.white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, metrics.statCardVerticalPadding)
        .background(Color.cardBackground)
        .cornerRadius(metrics.cardCornerRadius)
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
                onDismissHint: {},
                showHint: false,
                reduceMotion: false
            )
            .previewDisplayName("Holding — SE 40mm")
            .previewLayout(.fixed(width: 324, height: 394))
        }
    }
}
