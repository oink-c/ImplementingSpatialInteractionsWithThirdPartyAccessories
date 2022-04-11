/*
<samplecode>
 <abstract>
  A class that responds to application life cycle events.
 </abstract>
</samplecode>
*/

import UIKit
import NearbyInteraction

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }
}

