import SwiftUI
import WatchKit

class PullUpTrackerHostingController: WKHostingController<PullUpTrackerView> {
    override var body: PullUpTrackerView {
        return PullUpTrackerView()
    }
}
