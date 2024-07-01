//
//  ViewController.swift
//  FirstWatchApp
//
//  Created by Mehul Parmar on 1/11/18.
//  Copyright © 2018 org. All rights reserved.
//

import UIKit
import WatchConnectivity

class ViewController: UIViewController {
    

    private var countFromWatch: Int = 0
    @IBOutlet weak var countLabel: UILabel!
    
    
    
    private var countSecondTimer = Timer()
    
    private var pullUpAccumulateTime: Int = 0
    
    
    

    
    @IBAction func stopTimerButton(){
        print("按下去了")
        self.countSecondTimer.invalidate()
        
    }
    
    func timer2() {
        var countDownNum = 0
        self.countSecondTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            countDownNum += 1
            self.countLabel.text = String(format:"%d 秒",countDownNum)
        }
    }
    
    
    

    override func viewDidLoad() {
        super.viewDidLoad()
        WCSession.default.delegate = self
        WCSession.default.activate()
        countLabel.text = String(countFromWatch)
        
//        self.countMethod()
        self.timer2()
    }
}

extension ViewController : WCSessionDelegate {
    
    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String : Any]) {
        print(applicationContext)
        if let count = applicationContext["WatchCountKey"],
            let countValue = count as? Int {
            countFromWatch = countValue
            DispatchQueue.main.async {
                self.countLabel.text = String(self.countFromWatch)
            }
        }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) { }
    
    func sessionDidBecomeInactive(_ session: WCSession) { }
    
    func sessionDidDeactivate(_ session: WCSession) { }
}
