import Foundation
import AppKit

/// User-selectable theme. `followSystem` resolves to `.light` or `.dark`
/// based on the running app's effective appearance.
public enum Theme: String, Codable, CaseIterable, Equatable, Sendable {
    case light
    case dark
    case sepia
    case followSystem = "follow_system"

    public func resolved(systemAppearanceIsDark: Bool) -> Theme {
        switch self {
        case .followSystem: return systemAppearanceIsDark ? .dark : .light
        default: return self
        }
    }

    public var palette: ThemePalette {
        switch self {
        case .light:        return .light
        case .dark:         return .dark
        case .sepia:        return .sepia
        case .followSystem:
            // Should not happen — UI should resolve before calling palette.
            // Default to light for safety.
            return .light
        }
    }
}

public struct ThemePalette: Equatable, Sendable {
    public var background: NSColor
    public var bodyText: NSColor
    public var syntaxPunctuation: NSColor
    public var heading: NSColor
    public var code: NSColor
    public var link: NSColor
    public var blockquoteBar: NSColor
    public var caret: NSColor
    public var selection: NSColor

    public static let light = ThemePalette(
        background: NSColor(rgbHex: 0xFFFFFF),
        bodyText: NSColor(rgbHex: 0x1A1A1A),
        syntaxPunctuation: NSColor(rgbHex: 0xA0A0A0),
        heading: NSColor(rgbHex: 0x0A0A0A),
        code: NSColor(rgbHex: 0x5A4A20),
        link: NSColor(rgbHex: 0x0066CC),
        blockquoteBar: NSColor(rgbHex: 0xD0D0D0),
        caret: NSColor(rgbHex: 0x0A0A0A),
        selection: NSColor(rgbHex: 0xB5D5FF)
    )

    public static let dark = ThemePalette(
        background: NSColor(rgbHex: 0x1E1E1E),
        bodyText: NSColor(rgbHex: 0xE0E0E0),
        syntaxPunctuation: NSColor(rgbHex: 0x6E6E6E),
        heading: NSColor(rgbHex: 0xFFFFFF),
        code: NSColor(rgbHex: 0xD5C18A),
        link: NSColor(rgbHex: 0x5AA8FF),
        blockquoteBar: NSColor(rgbHex: 0x404040),
        caret: NSColor(rgbHex: 0xE0E0E0),
        selection: NSColor(rgbHex: 0x264F78)
    )

    public static let sepia = ThemePalette(
        background: NSColor(rgbHex: 0xFBF0D9),
        bodyText: NSColor(rgbHex: 0x3C2E1F),
        syntaxPunctuation: NSColor(rgbHex: 0xA6916D),
        heading: NSColor(rgbHex: 0x2D1F0F),
        code: NSColor(rgbHex: 0x5A4520),
        link: NSColor(rgbHex: 0x704528),
        blockquoteBar: NSColor(rgbHex: 0xD8C2A0),
        caret: NSColor(rgbHex: 0x3C2E1F),
        selection: NSColor(rgbHex: 0xE2C9A8)
    )
}

extension NSColor {
    /// Convenience initializer from a 6-digit hex value (0xRRGGBB).
    public convenience init(rgbHex: UInt32) {
        let r = CGFloat((rgbHex >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgbHex >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgbHex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
