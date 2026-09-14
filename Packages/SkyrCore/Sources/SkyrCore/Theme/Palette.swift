import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated extension Color {
    /// Creates a colour from a "#rrggbb" string.
    public init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: String(hex.drop(while: { $0 == "#" }))).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A colour that resolves differently in light and dark appearance.
    public init(light: Color, dark: Color) {
        #if os(watchOS)
        // The watch is always dark.
        self = dark
        #elseif canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #endif
    }
}

/// Brand palette taken from the design file.
public enum Palette {
    public static let ink = Color(light: Color(hex: "#1c1b1a"), dark: Color(hex: "#f3f2ef"))
    public static let onInk = Color(light: .white, dark: Color(hex: "#111111"))
    public static let paper = Color(light: Color(hex: "#f7f6f3"), dark: Color(hex: "#141414"))
    public static let neutralTint = Color(hex: "#b8b3a8")
    /// The pink of the note in the app icon.
    public static let brand = Color(hex: "#ff0d62")
}

