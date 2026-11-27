import AVFoundation
import SwiftUI

/// macOS 播放画布：直接用 `AVPlayerLayer`（AVFoundation），不使用 AVKit 的 SwiftUI 组件，
/// 避免在部分系统版本上触发 AVKit Swift 覆盖层的运行时问题；控件由 SwiftUI 自己画。
final class MacPlayerLayerView: NSView {
    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}

struct MacPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    /// 画布准备好后把 view 交出去（画中画需要拿到 AVPlayerLayer）
    var onReady: ((MacPlayerLayerView) -> Void)? = nil

    func makeNSView(context: Context) -> MacPlayerLayerView {
        let view = MacPlayerLayerView()
        view.wantsLayer = true
        view.playerLayer?.player = player
        onReady?(view)
        return view
    }

    func updateNSView(_ view: MacPlayerLayerView, context: Context) {
        if view.playerLayer?.player !== player {
            view.playerLayer?.player = player
        }
    }
}
