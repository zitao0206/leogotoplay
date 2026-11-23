import SwiftUI
import LeogotoPlayCore

/// 设计系统：颜色、圆角、间距、卡片样式。
enum Theme {
    static let accent = Color(hex: 0xFF5C3D)
    static let accentSecondary = Color(hex: 0xFF9A6B)
    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0xFF5C3D), Color(hex: 0xFF8A4B)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// 浅色品牌渐变：给白卡叠一层从主色到浅橙的淡色晕染，亮/暗色模式都成立。
    static let accentSoftGradient = LinearGradient(
        colors: [accent.opacity(0.18), accentSecondary.opacity(0.04)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let darkGradient = LinearGradient(
        colors: [Color(hex: 0x1B1C21), Color(hex: 0x2B2320)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardRadius: CGFloat = 18
    static let pagePadding: CGFloat = 20
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

extension Double {
    /// 列表展示用的完整时长，固定 hh:mm:ss，例如「00:03:04」。
    var listTimecode: String {
        guard isFinite, self >= 0 else { return "00:00:00" }
        let total = Int(rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

extension Int64 {
    /// 列表展示用的大小，固定一位小数，例如「1.8 MB」「94.1 MB」。
    var fileSizeText: String {
        guard self > 0 else { return "0 KB" }
        let bytes = Double(self)
        if self >= 1_000_000_000 {
            return String(format: "%.1f GB", bytes / 1_000_000_000)
        }
        if self >= 1_000_000 {
            return String(format: "%.1f MB", bytes / 1_000_000)
        }
        if self >= 1_000 {
            return String(format: "%.1f KB", bytes / 1_000)
        }
        return "\(self) B"
    }
}

extension Date {
    /// 列表展示用的添加日期，例如「2026-11-22」。
    var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }
}
