#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Minimal Notion/Linear-style palette: neutral greys, Mak8r terracotta as the only accent.
enum Theme {
    static let accent = dynamic(light: 0x9A5145, dark: 0xC46A5A)
    static let background = dynamic(light: 0xFFFFFF, dark: 0x0F0F10)
    static let sidebar = dynamic(light: 0xF7F7F5, dark: 0x161617)
    static let line = dynamic(light: 0xEDEDEB, dark: 0x242426)
    static let text = dynamic(light: 0x1F1F1F, dark: 0xE6E6E6)
    static let muted = dynamic(light: 0x8C8C8C, dark: 0x7D7D7D)
    static let hover = dynamic(light: 0xF2F2F0, dark: 0x1B1B1D)
    static let selected = dynamic(light: 0xEBEBE9, dark: 0x232325)
    static let checked = dynamic(light: 0xF6ECEA, dark: 0x2A1C19)

    #if os(macOS)
    // Scaled by the user's text size (TextScale.swift); views redraw when it changes.
    @MainActor static var body: Font { font(13) }
    @MainActor static var meta: Font { font(12) }
    @MainActor static var emphasis: Font { font(13, weight: .medium) }
    @MainActor static var title: Font { font(14, weight: .semibold) }
    #else
    static let body = Font.system(size: 16)
    static let meta = Font.system(size: 14)
    static let emphasis = Font.system(size: 16, weight: .medium)
    static let title = Font.system(size: 17, weight: .semibold)
    #endif
    static let radius: CGFloat = 6

    #if os(macOS)
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
    #else
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
    #endif
}

/// Thin 1 px rule in the theme's line colour.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}
