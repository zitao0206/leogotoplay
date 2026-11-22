import UIKit

/// V2.3 / V2.4：App 本体固定竖屏，播放页的「横屏」是把播放页整页旋转 90°，
/// 不改设备方向，所以列表和其它页面永远不会跟着转。
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return OrientationLock.mask
    }
}
