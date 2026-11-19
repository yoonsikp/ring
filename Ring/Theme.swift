import SwiftUI
import AppKit

/// Colours that adapt to light and dark mode.
extension Color {
    /// Call / Answer buttons: system green in light mode, a slightly darker green in dark mode.
    static let callGreen = adaptive(light: .systemGreen,
                                    dark: NSColor(srgbRed: 0.16, green: 0.58, blue: 0.27, alpha: 1))
    /// Hang up button: system red in light mode, a slightly darker red in dark mode.
    static let callRed = adaptive(light: .systemRed,
                                  dark: NSColor(srgbRed: 0.80, green: 0.20, blue: 0.18, alpha: 1))
    /// "Unmute" label text (the button background stays the normal one):
    /// red in light mode, system orange in dark mode, both readable on the grey button.
    static let mutedText = adaptive(light: .systemRed, dark: .systemOrange)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
