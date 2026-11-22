import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// V1.1.0：系统音量读写。用隐藏的 MPVolumeView 拿到系统音量滑杆，改它的 value 即改系统音量。
@MainActor
final class SystemVolumeController: ObservableObject {
    let volumeView: MPVolumeView
    @Published private(set) var value: Float = 0.5

    private var slider: UISlider? {
        Self.findSlider(in: volumeView)
    }

    /// 模拟器上 MPVolumeView 可能拿不到系统音量滑杆，此时退回播放器自身音量。
    var isAvailable: Bool { slider != nil }

    private static func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for sub in view.subviews {
            if let found = findSlider(in: sub) { return found }
        }
        return nil
    }

    /// 等 MPVolumeView 完成布局再取滑杆；最多等 ~2s。
    func refreshWhenReady() async {
        for _ in 0..<20 {
            if slider != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        refresh()
    }

    init() {
        volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 240, height: 44))
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        volumeView.alpha = 0.01
    }

    /// 挂进视图层级后调用一次，读到真实系统音量。
    func refresh() {
        if let slider {
            value = slider.value
        }

    }

    func set(_ newValue: Float) {
        let clamped = min(max(newValue, 0), 1)
        value = clamped
        guard let slider else { return }
        if abs(slider.value - clamped) > 0.001 {
            slider.setValue(clamped, animated: false)
        }
    }
}

/// 把 MPVolumeView 挂进视图层级（不挂进去拿不到可用的 slider）。
struct SystemVolumeHost: UIViewRepresentable {
    let controller: SystemVolumeController

    func makeUIView(context: Context) -> MPVolumeView {
        controller.volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
