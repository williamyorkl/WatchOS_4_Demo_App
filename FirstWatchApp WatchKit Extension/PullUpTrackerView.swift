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

enum TrackerMotionState {
    case idle
    case detecting
    case confirmed
    case active
    case paused
}

class PullUpTrackerViewModel: ObservableObject {
    @Published var sessionState: TrackerSessionState = .idle
    @Published var holdState: TrackerHoldState = .waiting
    
    @Published var detectSeconds: Int = 0
    @Published var holdSeconds: Int = 0
    @Published var totalHoldTime: Int = 0
    @Published var reps: Int = 0
    
    private let detectThreshold = 5
    private let targetHoldSeconds = 10
    
    private let motionManager = CMMotionManager()
    private var motionState: TrackerMotionState = .idle
    private var stateStartTime: Date?
    private var slidingWindow: [Double] = []
    private let windowSize = 10
    private let baselineMagnitude: Double = 1.0
    private let magnitudeThreshold: Double = 0.3
    private let detectingDuration: Double = 1.5
    private let confirmedDuration: Double = 0.5
    
    private var countTimer: Timer?
    private var lastUpdateTime: Date?
    
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    
    var progress: Double {
        if holdState == .detecting {
            return Double(detectSeconds) / Double(detectThreshold) * 100
        } else if holdState == .holding {
            return Double(holdSeconds) / Double(targetHoldSeconds) * 100
        }
        return 0
    }
    
    private func startWorkoutSession() {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("❌ HealthKit 不可用")
            return
        }
        
        let typesToShare: Set = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: typesToShare, read: nil) { success, error in
            DispatchQueue.main.async {
                if success {
                    print("✅ HealthKit 权限已获取")
                    self.beginWorkoutSession()
                } else {
                    print("❌ HealthKit 权限被拒绝: \(error?.localizedDescription ?? "未知错误")")
                }
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
            print("✅ Workout Session 已启动 - 后台运行已启用")
        } catch {
            print("❌ 启动 Workout Session 失败: \(error)")
        }
    }
    
    private func stopWorkoutSession() {
        guard let session = workoutSession else {
            print("⏹️ Workout Session 不存在，跳过停止")
            return
        }
        session.end()
        workoutSession = nil
        print("⏹️ Workout Session 已停止")
    }
    
    func startSession() {
        sessionState = .active
        reps = 0
        totalHoldTime = 0
        detectSeconds = 0
        holdSeconds = 0
        holdState = .waiting
        motionState = .idle
        slidingWindow.removeAll()
        
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
        stopWorkoutSession()
    }
    
    private func startCountTimer() {
        countTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateTimer()
        }
        RunLoop.current.add(countTimer!, forMode: .commonModes)
    }
    
    private func stopCountTimer() {
        countTimer?.invalidate()
        countTimer = nil
    }
    
    private func updateTimer() {
        guard motionState == .active else { return }
        
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
                WKInterfaceDevice.current().play(.success)
            }
        }
    }
    
    private func startAccelerometers() {
        guard motionManager.isAccelerometerAvailable else { return }
        
        motionManager.accelerometerUpdateInterval = 1.0 / 60.0
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let data = data, let self = self else { return }
            
            let x = data.acceleration.x
            let y = data.acceleration.y
            let z = data.acceleration.z
            
            self.processMotion(x: x, y: y, z: z)
        }
    }
    
    private func processMotion(x: Double, y: Double, z: Double) {
        let magnitude = sqrt(x * x + y * y + z * z)
        
        slidingWindow.append(magnitude)
        if slidingWindow.count > windowSize {
            slidingWindow.removeFirst()
        }
        
        let avgMagnitude = slidingWindow.reduce(0, +) / Double(slidingWindow.count)
        let magnitudeStable = abs(avgMagnitude - baselineMagnitude) < magnitudeThreshold
        let xDominant = abs(x) > abs(y) && abs(x) > abs(z)
        let isHangingPose = magnitudeStable && xDominant && x < -0.7
        
        switch motionState {
        case .idle:
            if isHangingPose {
                motionState = .detecting
                stateStartTime = Date()
            }
            
        case .detecting:
            if isHangingPose {
                let duration = Date().timeIntervalSince(stateStartTime!)
                if duration > detectingDuration {
                    motionState = .confirmed
                    stateStartTime = Date()
                }
            } else {
                motionState = .idle
                stateStartTime = nil
            }
            
        case .confirmed:
            if isHangingPose {
                let duration = Date().timeIntervalSince(stateStartTime!)
                if duration > confirmedDuration {
                    motionState = .active
                    holdState = .detecting
                    detectSeconds = 0
                    WKInterfaceDevice.current().play(.start)
                }
            } else {
                motionState = .idle
                stateStartTime = nil
            }
            
        case .active:
            let isArmDown = checkArmDown(x: x, y: y, z: z)
            if isArmDown {
                motionState = .paused
                stateStartTime = Date()
                holdState = .waiting
                WKInterfaceDevice.current().play(.stop)
            }
            
        case .paused:
            if isHangingPose {
                let duration = Date().timeIntervalSince(stateStartTime!)
                if duration > 0.5 {
                    motionState = .active
                    stateStartTime = nil
                    holdState = .detecting
                    WKInterfaceDevice.current().play(.start)
                }
            }
        }
    }
    
    private func checkArmDown(x: Double, y: Double, z: Double) -> Bool {
        let xPositiveDominant = x > 0.5 && abs(x) > abs(y) && abs(x) > abs(z)
        let zNegativeDominant = z < -0.7 && abs(z) > abs(x) && abs(z) > abs(y)
        return xPositiveDominant || zNegativeDominant
    }
}

struct PullUpTrackerView: View {
    @StateObject private var viewModel = PullUpTrackerViewModel()
    
    let orangeColor = Color(red: 1.0, green: 0.549, blue: 0.0)
    
    var body: some View {
        Group {
            switch viewModel.sessionState {
            case .idle:
                IdleView(onStart: viewModel.startSession, orangeColor: orangeColor)
            case .active:
                ActiveView(
                    holdState: viewModel.holdState,
                    detectSeconds: viewModel.detectSeconds,
                    holdSeconds: viewModel.holdSeconds,
                    reps: viewModel.reps,
                    progress: viewModel.progress,
                    onEnd: viewModel.endSession,
                    orangeColor: orangeColor
                )
            case .summary:
                SummaryView(
                    reps: viewModel.reps,
                    totalHoldTime: viewModel.totalHoldTime,
                    onDone: viewModel.backToIdle,
                    orangeColor: orangeColor
                )
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
}

struct IdleView: View {
    let onStart: () -> Void
    let orangeColor: Color
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.pullup")
                .font(.system(size: 48))
                .foregroundColor(orangeColor)
            
            Text("Pull-up Tracker")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            
            Text("10 seconds = 1 rep")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            
            Button(action: onStart) {
                Text("Start Session")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(orangeColor)
                    .cornerRadius(25)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

struct ActiveView: View {
    let holdState: TrackerHoldState
    let detectSeconds: Int
    let holdSeconds: Int
    let reps: Int
    let progress: Double
    let onEnd: () -> Void
    let orangeColor: Color
    
    var body: some View {
        let redColor = Color(red: 1.0, green: 0.27, blue: 0.23)
        
        return GeometryReader { geometry in
            let circleSize = min(geometry.size.width, geometry.size.height) - 16
            
            ZStack {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 8)
                    
                    Circle()
                        .trim(from: 0, to: progress / 100)
                        .stroke(
                            holdState == .detecting ? Color.gray : orangeColor,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: progress)
                    
                    VStack(spacing: 2) {
                        Text("REPS")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                        Text("\(reps)")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(orangeColor)
                    }
                    .offset(y: -circleSize * 0.30)
                    
                    VStack(spacing: 6) {
                        switch holdState {
                        case .waiting:
                            Image(systemName: "hand.raised")
                                .font(.system(size: 28))
                                .foregroundColor(.gray.opacity(0.6))
                            Text("Raise Hand")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                            
                        case .detecting:
                            Text("\(detectSeconds)")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundColor(.gray)
                            Text("of 5s")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                            
                        case .holding:
                            Text("\(holdSeconds)")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundColor(.white)
                            Text("of 10s")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                        
                        Button(action: onEnd) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 14))
                                .foregroundColor(redColor)
                                .frame(width: 40, height: 40)
                                .background(redColor.opacity(0.15))
                                .cornerRadius(20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(redColor.opacity(0.3), lineWidth: 1)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .offset(y: circleSize * 0.10)
                }
                .frame(width: circleSize, height: circleSize)
                .offset(y: 8)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct SummaryView: View {
    let reps: Int
    let totalHoldTime: Int
    let onDone: () -> Void
    let orangeColor: Color
    
    @State private var contentHeight: CGFloat = 0
    
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
            let scaleFactor = min(geometry.size.height / 242, 1.0)
            
            VStack {
                Spacer()
                VStack(spacing: 8 * scaleFactor) {
                    HStack(spacing: 5 * scaleFactor) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14 * scaleFactor))
                            .foregroundColor(.green)
                        Text("Complete")
                            .font(.system(size: 13 * scaleFactor, weight: .bold))
                            .foregroundColor(.white)
                    }
                    
                    HStack(spacing: 8 * scaleFactor) {
                        VStack(spacing: 2 * scaleFactor) {
                            Image(systemName: "figure.pullup")
                                .font(.system(size: 14 * scaleFactor))
                                .foregroundColor(orangeColor)
                            Text("\(reps)")
                                .font(.system(size: 28 * scaleFactor, weight: .bold))
                                .foregroundColor(.white)
                            Text("REPS")
                                .font(.system(size: 8 * scaleFactor))
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10 * scaleFactor)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12 * scaleFactor)
                        
                        VStack(spacing: 2 * scaleFactor) {
                            Image(systemName: "timer")
                                .font(.system(size: 14 * scaleFactor))
                                .foregroundColor(orangeColor)
                            Text(formatTime(totalHoldTime))
                                .font(.system(size: 28 * scaleFactor, weight: .bold))
                                .foregroundColor(.white)
                            Text("TIME")
                                .font(.system(size: 8 * scaleFactor))
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10 * scaleFactor)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12 * scaleFactor)
                    }
                    
                    HStack(spacing: 8 * scaleFactor) {
                        VStack(spacing: 2 * scaleFactor) {
                            Text("\(avgHoldTime)s")
                                .font(.system(size: 20 * scaleFactor, weight: .bold))
                                .foregroundColor(.white)
                            Text("AVG HOLD")
                                .font(.system(size: 8 * scaleFactor))
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8 * scaleFactor)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12 * scaleFactor)
                        
                        Button(action: onDone) {
                            Text("Done")
                                .font(.system(size: 12 * scaleFactor, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10 * scaleFactor)
                                .background(orangeColor)
                                .cornerRadius(12 * scaleFactor)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 8 * scaleFactor)
                Spacer()
            }
        }
    }
}

struct PullUpTrackerView_Previews: PreviewProvider {
    static var previews: some View {
        PullUpTrackerView()
    }
}
