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
    

    func startAccelerometers() {
        
        // Make sure the accelerometer hardware is available.
        if self.motion.isAccelerometerAvailable {
            print("开始初始化...")
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
                                       self.startRecord(z:z,timer1: timer1)
                                      
                                   }
                               })

            // Add the timer to the current run loop.
            RunLoop.current.add(timer1, forMode: .defaultRunLoopMode)
        }else {
            print("初始化失败...")
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
    
    
    
    
    
    
    func startRecord(z:Double,timer1:Timer) {
        if z > 0.2 {
            // 进入阀值，停止当前传感器的运行
            timer1.invalidate()
            
            self.accelePositionInfo += "上去"
            
            
            // MARK 开始计时器
            var countDownNum = 5
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer2 in
                if countDownNum == 0 {
                    
                    // 开始振动
                    WKInterfaceDevice.current().play(.start)
                    self.accelePositionInfo = "=== 开始计时 ==="
                    
                    
                    
                    // 销毁计时器
                    timer2.invalidate()
                    
                    // 标识 flag
                    self.recordPullUpNumber = 1
                    
                    // 先请一次定时器再开始
                    if self.countSecondTimer.isValid {
                        self.countSecondTimer.invalidate()
                    }
                    self.countMethod()
                    
                    
                    
                } else {
                    self.accelePositionInfo = String(countDownNum)
                    countDownNum -= 1
                }
            }
            
        }
//        NOTE - 下面这块目前还不成熟
//        else if z < -0.8 && self.recordPullUpNumber == 1  {
//            self.accelePositionInfo += "下来"
//            self.recordPullUpNumber = 0
//
//            self.pullUpCount += 1
//
//            // 停止当前传感器的运行
//            timer1.invalidate()
//
//            // 关闭计数器
//            if self.countSecondTimer.isValid {
//                self.countSecondTimer.invalidate()
//            }
//        }
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
        
        
        // 暂停计时器
        self.countSecondTimer.invalidate()
        
        
        
        // 重置累计秒数
        self.acceleLog = String("")
        self.pullUpAccumulateTime = 0
    }
    
    
    // 二、开始
    @IBAction func startTapped(){
        
        // 暂停计时器
        self.countSecondTimer.invalidate()
        
        
        // 初始化加速器方法，初始化后，xyz数值会恢复显示
        self.startAccelerometers()
        
    }
    
    
   
    
    // 三、重置
    @IBAction func resetTapped(){
        // 暂停计时器
        self.countSecondTimer.invalidate()
        
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
    
    
    override func awake(withContext context: Any?) {
        super.awake(withContext: context)
        
//        测试 - 获取用户数据
//        self.sendRequestGetUserInfo()
        
        
        
       // if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
      //  }

//        crownSequencer.delegate = self
        
        
        
    }
    
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


