//
//  InterfaceController.swift
//  FirstWatchApp WatchKit Extension
//
//  Created by Mehul Parmar on 1/11/18.
//  Copyright © 2018 org. All rights reserved.
//

import WatchKit
import Foundation
import WatchConnectivity
import CoreMotion
import os.log
import UIKit
import HealthKit


enum MotionState {
    case idle
    case detecting
    case confirmed
    case active
    case paused
}

/**
 // 1. 吊单杠记录次数
  
 a)  手放上去
 z  >  0.2
  
 b) 手放下来
 z < -0.8
  
 */




class InterfaceController: WKInterfaceController {
    
    private var recordPullUpNumber = 0
    
    
    private var pullUpAccumulateTime: Int = 0
    
    
    private var countSecondTimer = Timer()
    
    
//    let motionManager = CMMotionManager()
//       var isPullingUp = false
//       var startTime: TimeInterval = 0
//    
//    
//
//   override func awake(withContext context: Any?) {
//       super.awake(withContext: context)
//
//       if motionManager.isAccelerometerAvailable {
//           motionManager.accelerometerUpdateInterval = 0.1
//           motionManager.startAccelerometerUpdates(to: .main) { [weak self] (data, error) in
//               guard let data = data else { return }
//
//               let accelerationY = data.acceleration.y
//               
//               let accelerationX = data.acceleration.x
//               
//               let accelerationZ = data.acceleration.z
//               
//               print(String(format: "x: %.1f y: %.1f z: %.1f" ,accelerationX,accelerationY,accelerationZ))
//               
//
//               if accelerationY < -0.8 && !self!.isPullingUp {
//                   // 手腕向上运动
//                   self?.isPullingUp = true
//                   self?.startTime = Date().timeIntervalSince1970
//                   print("Start pulling up")
//               } else if accelerationY > 0.8 && self!.isPullingUp {
//                   // 手腕向下运动
//                   let pullUpTime = Date().timeIntervalSince1970 - (self?.startTime ?? 0)
//                   print("Pull up time: \(pullUpTime) seconds")
//                   print("Stop pulling up")
//                   self?.isPullingUp = false
//               }
//           }
//       }
//   }
    
    let motionManager = CMMotionManager()
      var isPullingUp = false
      var startTime: TimeInterval = 0
      var initialAccelerationY: Double = 0
      var distance: Double = 0
      let g = 9.81
      let timeInterval = 0.1 // 时间间隔为0.1秒

      override func awake(withContext context: Any?) {
          super.awake(withContext: context)

          if motionManager.isAccelerometerAvailable {
              motionManager.accelerometerUpdateInterval = 0.1
              motionManager.startAccelerometerUpdates(to: .main) { [weak self] (data, error) in
                  guard let data = data else { return }

                  let accelerationY = data.acceleration.y

                  if accelerationY < -0.8 && !self!.isPullingUp {
                      // 开始吊单杠
                      self?.isPullingUp = true
                      self?.startTime = Date().timeIntervalSince1970
                      self?.initialAccelerationY = accelerationY
                      self?.distance = 0
                      print("Start pulling up")
                  } else if accelerationY > 0.8 && self!.isPullingUp {
                      // 吊单杠结束
                      let pullUpTime = Date().timeIntervalSince1970 - (self?.startTime ?? 0)
                      print("Pull up time: \(pullUpTime) seconds")
                      self?.isPullingUp = false
                  }

                  if self!.isPullingUp {
                      let distanceChange = 0.5 * self!.g * pow(self!.timeInterval, 2) * (accelerationY - self!.initialAccelerationY)
                      self?.distance += distanceChange
                  }
              }
            }
        }
    
//       func calculateDistance(accelerationY: Double) -> Double {
//           // 假设加速度单位为 g（重力加速度）
//           let g = 9.81
//           let timeInterval = 0.1 // 时间间隔为0.1秒
//
//           // 计算位移（S = 0.5 * a * t^2）
//           let distanceChange = 0.5 * pow(timeInterval, 2) * accelerationY
//
//           // 累加位移
//           distance += distanceChange
//
//           return distance
//       }
//    
    
    
    // 初始化一个全局计时器
    func countMethod() {
        self.countSecondTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer3 in
            
            self.pullUpAccumulateTime += 1
            self.acceleLog = String(format: "已经坚持：%d 秒" ,self.pullUpAccumulateTime)
            
            if self.pullUpAccumulateTime % 10 == 0 {
                // 吊单杠计次 + 1
                self.pullUpCount += 1
                WKInterfaceDevice.current().play(.success)
                
                // 上传数据到 habitica
                self.sendRequestToHabitica(pullUpCount: self.pullUpCount)
            }
        }
        
    }

    
    
    
    /** 测试加速器 */

    let motion = CMMotionManager()
    
    let healthStore = HKHealthStore()
    var workoutSession: HKWorkoutSession?
    
    var motionState: MotionState = .idle
    var stateStartTime: Date?
    var slidingWindow: [Double] = []
    let windowSize = 10
    let baselineMagnitude: Double = 1.0
    let magnitudeThreshold: Double = 0.3
    let detectingDuration: Double = 1.5
    let confirmedDuration: Double = 0.5
    var isHangingState: Bool = false

    func startWorkoutSession() {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("❌ HealthKit 不可用")
            return
        }
        
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
    
    func stopWorkoutSession() {
        workoutSession?.end()
        print("⏹️ Workout Session 已停止")
    }

    func startAccelerometers() {
        
        // Make sure the accelerometer hardware is available.
        if self.motion.isAccelerometerAvailable {
            print("========== 开始初始化加速度传感器 ==========")
            print("采样频率: 60 Hz")
            print("滑动窗口大小: \(windowSize)")
            print("向量模阈值: \(magnitudeThreshold)")
            print("DETECTING 持续时间: \(detectingDuration)秒")
            print("CONFIRMED 持续时间: \(confirmedDuration)秒")
            self.motion.accelerometerUpdateInterval = 1.0 / 60.0  // 60 Hz
            self.motion.startAccelerometerUpdates()

            // Configure a timer to fetch the data.
            let timer1 = Timer(fire: Date(), interval: (1.0/60.0),
                               repeats: true, block: { (timer1) in
                                    // Get the accelerometer data.
                                    if let data = self.motion.accelerometerData {
                                        let x = data.acceleration.x
                                        let y = data.acceleration.y
                                        let z = data.acceleration.z

                                         // Use the accelerometer data in your app.
                                         self.accelePositionInfo =  String(format: "x: %.1f y: %.1f z: %.1f" ,x,y,z)
                                         
                                         // 开始监听加速器并计数
                                         self.startRecord(x: x, y: y, z: z, timer1: timer1)
                                       
                                    }
                                })

            // Add the timer to the current run loop.
            RunLoop.current.add(timer1, forMode: .defaultRunLoopMode)
        }else {
            print("❌ 初始化失败：加速度传感器不可用")
        }
    }
    
    
    func sendRequestToHabitica(pullUpCount:Int){
//        let taskId = "40289356-F1F6-4F96-9001-1B440DFE8A70"
//        let direction = "up"
        
//        let url = String(format: "https://habitica.com/api/v3/tasks//score/%s",taskId,direction )
        
        let url = String(format: "https://habitica.com/api/v3/tasks/40289356-F1F6-4F96-9001-1B440DFE8A70/score/up")
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        
        request.addValue("bfa20849-df4e-4466-a4f1-e047e9772d2e", forHTTPHeaderField: "x-api-user")
        request.addValue("b999b5f5-a4b1-4d2c-aed4-29797551a9f9", forHTTPHeaderField: "x-api-key")
        
        let task = URLSession.shared.dataTask(with: request as URLRequest) { data, response, error in
            if error != nil {
                print("fail")
                self.accelePositionInfo = "发送失败"
                return
            }
            
            do {
                let object = try JSONSerialization.jsonObject(with: data!, options: .allowFragments)
                if let dictionary = object as? [String: AnyObject]{
                    // dictionary 就是 json 数据
                    print(dictionary)
                    self.accelePositionInfo = String(format: "第 %d 次，请求发送成功", pullUpCount)
                }
            } catch _ {
            }
        }
        
        
        // 发送请求
        task.resume()
        
    }
    
    
    // 获取用户信息
    func sendRequestGetUserInfo(){
        
        let url = String(format: "https://habitica.com/api/v3/user")
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "GET"
        
        request.addValue("bfa20849-df4e-4466-a4f1-e047e9772d2e", forHTTPHeaderField: "x-api-user")
        request.addValue("b999b5f5-a4b1-4d2c-aed4-29797551a9f9", forHTTPHeaderField: "x-api-key")
        
        let task = URLSession.shared.dataTask(with: request as URLRequest) { data, response, error in
            if error != nil {
                print("fail")
                self.accelePositionInfo = "发送失败"
                return
            }
            
            do {
                let object = try JSONSerialization.jsonObject(with: data!, options: .allowFragments)
                if let dictionary = object as? [String: AnyObject]{
                    // dictionary 就是 json 数据
                    print(dictionary)
                    self.accelePositionInfo = String(format: "第 %d 次，请求发送成功", self.pullUpCount)
                }
            } catch _ {
            }
        }
        
        
        // 发送请求
        task.resume()
        
    }
    
    
    
    
    
    
    func startRecord(x: Double, y: Double, z: Double, timer1: Timer) {
        let magnitude = sqrt(x * x + y * y + z * z)
        
        slidingWindow.append(magnitude)
        if slidingWindow.count > windowSize {
            slidingWindow.removeFirst()
        }
        
        let avgMagnitude = slidingWindow.reduce(0, +) / Double(slidingWindow.count)
        let magnitudeStable = abs(avgMagnitude - baselineMagnitude) < magnitudeThreshold
        let xDominant = abs(x) > abs(y) && abs(x) > abs(z)
        let isHangingPose = magnitudeStable && xDominant && x < -0.7
        
        print("\n========== 加速度数据 ==========")
        print(String(format: "原始数据 - x: %.3f, y: %.3f, z: %.3f", x, y, z))
        print(String(format: "向量模: %.3f", magnitude))
        print(String(format: "滑动窗口大小: %d", slidingWindow.count))
        print(String(format: "滑动窗口平均值: %.3f", avgMagnitude))
        print(String(format: "基准值: %.3f", baselineMagnitude))
        print(String(format: "向量模稳定性: %@ (|%.3f - %.3f| = %.3f, 阈值: %.3f)", 
                     magnitudeStable ? "✓ 稳定" : "✗ 不稳定", 
                     avgMagnitude, baselineMagnitude, 
                     abs(avgMagnitude - baselineMagnitude), 
                     magnitudeThreshold))
        print(String(format: "X轴主导性: %@ (|x|=%.3f, |y|=%.3f, |z|=%.3f)", 
                     xDominant ? "✓ X轴主导" : "✗ 非X轴主导", 
                     abs(x), abs(y), abs(z)))
        print(String(format: "X轴负值检测: %@ (x=%.3f, 阈值: -0.7)", 
                     x < -0.7 ? "✓ 符合" : "✗ 不符合", x))
        print(String(format: "整体判断: %@", isHangingPose ? "✓ 符合手举高姿态" : "✗ 不符合"))
        print(String(format: "当前状态: %@", getStateName(motionState)))
        
        switch motionState {
        case .idle:
            if isHangingPose {
                motionState = .detecting
                stateStartTime = Date()
                print("⏩ 状态转换: IDLE → DETECTING")
                print("开始计时: \(stateStartTime!)")
            }
            
        case .detecting:
            if isHangingPose {
                let duration = Date().timeIntervalSince(stateStartTime!)
                print(String(format: "DETECTING 持续时间: %.2f 秒 (需要 > %.2f 秒)", 
                             duration, detectingDuration))
                if duration > detectingDuration {
                    motionState = .confirmed
                    stateStartTime = Date()
                    print("⏩ 状态转换: DETECTING → CONFIRMED")
                    print("✅ 检测阶段完成，进入确认阶段")
                }
            } else {
                let previousDuration = Date().timeIntervalSince(stateStartTime!)
                print("❌ 状态不稳定，重置到 IDLE")
                print(String(format: "已持续: %.2f 秒", previousDuration))
                motionState = .idle
                stateStartTime = nil
            }
            
        case .confirmed:
            if isHangingPose {
                let duration = Date().timeIntervalSince(stateStartTime!)
                print(String(format: "CONFIRMED 持续时间: %.2f 秒 (需要 > %.2f 秒)", 
                             duration, confirmedDuration))
                if duration > confirmedDuration {
                    motionState = .active
                    isHangingState = true
                    
                    print("⏩ 状态转换: CONFIRMED → ACTIVE")
                    print("🎉 吊单杠姿态确认！开始倒计时")
                    
                    self.accelePositionInfo += "上去"
                    
                    var countDownNum = 5
                    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer2 in
                        if countDownNum == 0 {
                            WKInterfaceDevice.current().play(.start)
                            self.accelePositionInfo = "=== 开始计时 ==="
                            print("⏱️ 倒计时结束，开始正式计时")
                            timer2.invalidate()
                            self.recordPullUpNumber = 1
                            
                            if self.countSecondTimer.isValid {
                                self.countSecondTimer.invalidate()
                            }
                            self.countMethod()
                        } else {
                            self.accelePositionInfo = String(countDownNum)
                            print("⏱️ 倒计时: \(countDownNum)")
                            countDownNum -= 1
                        }
                    }
                }
            } else {
                let previousDuration = Date().timeIntervalSince(stateStartTime!)
                print("❌ 确认阶段不稳定，重置到 IDLE")
                print(String(format: "已持续: %.2f 秒", previousDuration))
                motionState = .idle
                stateStartTime = nil
            }
            
        case .active:
            let isArmDown = checkArmDown(x: x, y: y, z: z)
            if isArmDown {
                motionState = .paused
                stateStartTime = Date()
                self.countSecondTimer.invalidate()
                WKInterfaceDevice.current().play(.stop)
                self.accelePositionInfo = "=== 已暂停 ==="
                print("⏩ 状态转换: ACTIVE → PAUSED")
                print("⏸️ 检测到手放下，暂停计时")
            } else {
                print("🏃 运动中，手仍在举高")
            }
            
        case .paused:
            if isHangingPose {
                let duration = Date().timeIntervalSince(stateStartTime!)
                print(String(format: "PAUSED 持续时间: %.2f 秒", duration))
                if duration > 0.5 {
                    motionState = .active
                    stateStartTime = nil
                    self.countMethod()
                    WKInterfaceDevice.current().play(.start)
                    self.accelePositionInfo = "=== 继续计时 ==="
                    print("⏩ 状态转换: PAUSED → ACTIVE")
                    print("▶️ 检测到手举高，恢复计时")
                }
            } else {
                print("⏸️ 暂停中，等待手举高")
            }
    }
    
    func checkArmDown(x: Double, y: Double, z: Double) -> Bool {
        let xPositiveDominant = x > 0.5 && abs(x) > abs(y) && abs(x) > abs(z)
        let zNegativeDominant = z < -0.7 && abs(z) > abs(x) && abs(z) > abs(y)
        let isDown = xPositiveDominant || zNegativeDominant
        print(String(format: "手放下检测: xPositiveDominant=%@, zNegativeDominant=%@, 结果=%@",
                     xPositiveDominant ? "✓" : "✗",
                     zNegativeDominant ? "✓" : "✗",
                     isDown ? "手放下了" : "手仍在举高"))
        return isDown
    }
    }
    
    func getStateName(_ state: MotionState) -> String {
        switch state {
        case .idle: return "IDLE (空闲)"
        case .detecting: return "DETECTING (检测中)"
        case .confirmed: return "CONFIRMED (确认中)"
        case .active: return "ACTIVE (运动中)"
        case .paused: return "PAUSED (已暂停)"
        }
    }
    
    
    /*** */

    @IBOutlet var titleLabel: WKInterfaceLabel!
    @IBOutlet var countLabel: WKInterfaceLabel!
    @IBOutlet var pullupLabel: WKInterfaceLabel!
    @IBOutlet var logLabel: WKInterfaceLabel!
    
    
    // 1. 声明一个 UI 对象
    var pullUpCount: Int = 0 {
        didSet {
            setPullUpCount(pullUpCount: String(pullUpCount))
        }
    }
    
    // 一、暂停
    @IBAction func pauseTapped() {
        
        WKInterfaceDevice.current().play(.stop)
        self.accelePositionInfo = "=== 已暂停 ==="
        print("\n========== 暂停 ==========")
        
        // 重置状态机
        motionState = .idle
        stateStartTime = nil
        isHangingState = false
        slidingWindow.removeAll()
        print("状态机已重置到 IDLE")
        print("滑动窗口已清空")
        
        // 暂停计时器
        self.countSecondTimer.invalidate()
        
        // 停止 Workout Session
        stopWorkoutSession()
        
        // 重置累计秒数
        self.acceleLog = String("")
        self.pullUpAccumulateTime = 0
    }
    
    
    // 二、开始
    @IBAction func startTapped(){
        print("\n========== 开始 ==========")
        
        // 启动 Workout Session（后台运行）
        startWorkoutSession()
        
        // 重置状态机
        motionState = .idle
        stateStartTime = nil
        isHangingState = false
        slidingWindow.removeAll()
        print("状态机已重置到 IDLE")
        
        // 暂停计时器
        self.countSecondTimer.invalidate()
        
        
        // 初始化加速器方法，初始化后，xyz数值会恢复显示
        self.startAccelerometers()
        
    }
    
    
   
    
    // 三、重置
    @IBAction func resetTapped(){
        print("\n========== 重置 ==========")
        
        // 重置状态机
        motionState = .idle
        stateStartTime = nil
        isHangingState = false
        slidingWindow.removeAll()
        print("状态机已重置到 IDLE")
        print("滑动窗口已清空")
        
        // 暂停计时器
        self.countSecondTimer.invalidate()
        
        // 停止 Workout Session
        stopWorkoutSession()
        
        // 总次数
        self.pullUpCount = 0
        
        // 重置累计秒数
        self.acceleLog = String("")
        self.pullUpAccumulateTime = 0
        
        
        self.accelePositionInfo = "==已重置值=="
    }
    
    
   
    
//    private var crownDelta = 0.0
    
    private var count: Int = 0 {
        didSet {
            setCount(count: String(count))
            updateAppContext()
        }
    }
    
    // 2. 再在当前应用中声明一个内部变量（注意该变量可以像 js 一样有get 和 set钩子）
    private var accelePositionInfo: String = "" {
        didSet {
            setCount(count:accelePositionInfo)
        }
    }
    
    private var acceleLog:String = "" {
        didSet {
            setPullUpCount(log: acceleLog)
        }
    }
    
    override func didDeactivate(){
        
        // 当 app 退出到后台的时候，唤醒的时候，重置数据
        print("app 已经退出到后台")
        self.resetTapped()
    }
    
    
//    override func awake(withContext context: Any?) {
//        super.awake(withContext: context)
//        
////        测试 - 获取用户数据
////        self.sendRequestGetUserInfo()
//        
//        
//        
//       // if WCSession.isSupported() {
//            WCSession.default.delegate = self
//            WCSession.default.activate()
//      //  }
//
////        crownSequencer.delegate = self
//        
//        
//        
//    }
    
    private func setPullUpCount(pullUpCount:String){
        let fontAttrs = [NSAttributedStringKey.font : UIFont.systemFont(ofSize: 32)]
        let attrString = NSAttributedString(string: pullUpCount, attributes: fontAttrs)
        pullupLabel.setAttributedText(attrString)
    }
    
    private func setPullUpCount(log:String){
        let fontAttrs = [NSAttributedStringKey.font : UIFont.systemFont(ofSize: 16)]
        let attrString = NSAttributedString(string: log, attributes: fontAttrs)
        logLabel.setAttributedText(attrString)
    }
    
    
    
    
    private func setCount(count: String) {
        let fontAttrs = [NSAttributedStringKey.font : UIFont.systemFont(ofSize: 12)]
        let attrString = NSAttributedString(string: count, attributes: fontAttrs)
        countLabel.setAttributedText(attrString)
    }
    
    private func updateAppContext() {
        guard WCSession.isSupported() else {
            return
        }
        do{
//            try WCSession.default.updateApplicationContext(["WatchCountKey" : count])
              try WCSession.default.updateApplicationContext(["WatchCountKey" : accelePositionInfo])
        }
        catch {
            print(error.localizedDescription)
        }
    }
    
    override func willActivate() {
        super.willActivate()
        WKExtension.shared().isAutorotating = true
    }
    
    override func willDisappear() {
        super.willDisappear()
        WKExtension.shared().isAutorotating = false
    }
}

extension InterfaceController: WCSessionDelegate {
    
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) { }
    
    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String : Any]) { }
}


