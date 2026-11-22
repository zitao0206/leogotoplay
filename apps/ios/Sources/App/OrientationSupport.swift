import UIKit

/// V2.3：只允许播放页按需切横屏，其他页面固定竖屏。
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return OrientationLock.mask
    }
}
