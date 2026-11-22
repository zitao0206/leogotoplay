import SwiftUI

/// macOS 端设计系统：与 iOS 共用一套品牌色与圆角，但控件形态按桌面习惯调整。
enum MacTheme {
    static let accent = Color(hex: 0xFF5C3D)
    static let accentSecondary = Color(hex: 0xFF9A6B)
    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0xFF5C3D), Color(hex: 0xFF8A4B)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let sidebarWidth: CGFloat = 208
    static let cardRadius: CGFloat = 12
    static let pagePadding: CGFloat = 24
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex & 0xFF0000) >> 16) / 255
        let g = Double((hex & 0x00FF00) >> 8) / 255
        let b = Double(hex & 0x0000FF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

extension Double {
    /// 秒 -> "01:23" / "1:02:03"
    var timecode: String {
        guard isFinite, self >= 0 else { return "00:00" }
        let total = Int(rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

extension Int64 {
    var fileSizeText: String {
        guard self > 0 else { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}
