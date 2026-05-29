import Foundation

/// User-configurable typography settings persisted via @AppStorage in 1b.
/// Per-project overrides arrive in milestone 1c.
public struct TypographySettings: Codable, Equatable, Sendable {
    public var fontFamily: String
    public var fontSize: Int
    public var lineHeightMultiplier: Double
    public var pageWidthCharacters: Int
    public var paragraphSpacingMultiplier: Double
    public var smartQuotes: Bool
    public var emDashAutoReplace: Bool
    public var ellipsisAutoReplace: Bool

    public init(
        fontFamily: String,
        fontSize: Int,
        lineHeightMultiplier: Double,
        pageWidthCharacters: Int,
        paragraphSpacingMultiplier: Double,
        smartQuotes: Bool,
        emDashAutoReplace: Bool,
        ellipsisAutoReplace: Bool
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeightMultiplier = lineHeightMultiplier
        self.pageWidthCharacters = pageWidthCharacters
        self.paragraphSpacingMultiplier = paragraphSpacingMultiplier
        self.smartQuotes = smartQuotes
        self.emDashAutoReplace = emDashAutoReplace
        self.ellipsisAutoReplace = ellipsisAutoReplace
    }

    public static let defaults = TypographySettings(
        fontFamily: "Iowan Old Style",
        fontSize: 17,
        lineHeightMultiplier: 1.7,
        pageWidthCharacters: 70,
        paragraphSpacingMultiplier: 0.6,
        smartQuotes: true,
        emDashAutoReplace: true,
        ellipsisAutoReplace: true
    )

    public struct CuratedFont: Equatable, Sendable {
        public let displayName: String
        public let fontName: String
    }

    public static let curatedFonts: [CuratedFont] = [
        CuratedFont(displayName: "Iowan Old Style", fontName: "Iowan Old Style"),
        CuratedFont(displayName: "New York", fontName: "New York"),
        CuratedFont(displayName: "Charter", fontName: "Charter"),
    ]

    public static let screenplayDefaults = TypographySettings(
        fontFamily: "JetBrains Mono",
        fontSize: 13,
        lineHeightMultiplier: 1.5,
        pageWidthCharacters: 60,
        paragraphSpacingMultiplier: 0.6,
        smartQuotes: false,
        emDashAutoReplace: false,
        ellipsisAutoReplace: false
    )

    public static let curatedScreenplayFonts: [CuratedFont] = [
        CuratedFont(displayName: "JetBrains Mono", fontName: "JetBrains Mono"),
        CuratedFont(displayName: "Menlo", fontName: "Menlo"),
        CuratedFont(displayName: "SF Mono", fontName: "SF Mono"),
    ]
}
