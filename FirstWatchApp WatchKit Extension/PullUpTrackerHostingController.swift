import SwiftUI
import WatchKit

struct PullUpTrackerRoot: View {
    var body: some View {
        PullUpTrackerView()
            .persistentSystemOverlays(.hidden)
    }
}

class PullUpTrackerHostingController: WKHostingController<PullUpTrackerRoot> {
    override var body: PullUpTrackerRoot {
        return PullUpTrackerRoot()
    }
}
