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

    private enum CodingKeys: String, CodingKey {
        case fontFamily, fontSize, lineHeightMultiplier, pageWidthCharacters,
             paragraphSpacingMultiplier, smartQuotes, emDashAutoReplace,
             ellipsisAutoReplace
    }

    /// Cross-version forward-tolerance (ADR 0014). All eight fields are
    /// non-optional — the synthesized decoder throws `keyNotFound` if any is
    /// absent, which is a landmine for the next field added: old
    /// `project.maugham.json` / preferences written before the field exists
    /// would fail to decode the whole `typography` block. `decodeIfPresent`
    /// against `.defaults` makes a missing field fall back instead of throwing,
    /// so adding a ninth field later doesn't break decode of older data. (Note
    /// this decodes against prose `.defaults`; per-project screenplay overrides
    /// always write all fields, so a partial screenplay override is not a real
    /// on-disk shape.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TypographySettings.defaults
        self.fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? d.fontFamily
        self.fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? d.fontSize
        self.lineHeightMultiplier = try c.decodeIfPresent(Double.self, forKey: .lineHeightMultiplier) ?? d.lineHeightMultiplier
        self.pageWidthCharacters = try c.decodeIfPresent(Int.self, forKey: .pageWidthCharacters) ?? d.pageWidthCharacters
        self.paragraphSpacingMultiplier = try c.decodeIfPresent(Double.self, forKey: .paragraphSpacingMultiplier) ?? d.paragraphSpacingMultiplier
        self.smartQuotes = try c.decodeIfPresent(Bool.self, forKey: .smartQuotes) ?? d.smartQuotes
        self.emDashAutoReplace = try c.decodeIfPresent(Bool.self, forKey: .emDashAutoReplace) ?? d.emDashAutoReplace
        self.ellipsisAutoReplace = try c.decodeIfPresent(Bool.self, forKey: .ellipsisAutoReplace) ?? d.ellipsisAutoReplace
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
