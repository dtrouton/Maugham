import Foundation

/// Per-project UI state persisted to `.maugham/ui-state.json`.
/// Schema-versioned for forward compatibility.
public struct UIState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var selectedItemId: String?
    public var isNoChromeOn: Bool
    public var scrollLine: Int
    public var binderSegment: BinderSegment
    public var researchPreviewVisible: Bool
    public var detailSegment: DetailSegment
    public var outlineLayout: OutlineLayout

    public init(
        schemaVersion: Int = UIState.currentSchemaVersion,
        selectedItemId: String? = nil,
        isNoChromeOn: Bool = false,
        scrollLine: Int = 0,
        binderSegment: BinderSegment = .manuscript,
        researchPreviewVisible: Bool = false,
        detailSegment: DetailSegment = .inspector,
        outlineLayout: OutlineLayout = .table
    ) {
        self.schemaVersion = schemaVersion
        self.selectedItemId = selectedItemId
        self.isNoChromeOn = isNoChromeOn
        self.scrollLine = scrollLine
        self.binderSegment = binderSegment
        self.researchPreviewVisible = researchPreviewVisible
        self.detailSegment = detailSegment
        self.outlineLayout = outlineLayout
    }

    public static let empty = UIState()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, selectedItemId, isNoChromeOn, scrollLine, binderSegment,
             researchPreviewVisible, detailSegment, outlineLayout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.selectedItemId = try c.decodeIfPresent(String.self, forKey: .selectedItemId)
        self.isNoChromeOn = (try? c.decode(Bool.self, forKey: .isNoChromeOn)) ?? false
        self.scrollLine = (try? c.decode(Int.self, forKey: .scrollLine)) ?? 0
        self.binderSegment = (try? c.decode(BinderSegment.self, forKey: .binderSegment)) ?? .manuscript
        self.researchPreviewVisible = (try? c.decode(Bool.self, forKey: .researchPreviewVisible)) ?? false
        self.detailSegment = (try? c.decode(DetailSegment.self, forKey: .detailSegment)) ?? .inspector
        self.outlineLayout = (try? c.decode(OutlineLayout.self, forKey: .outlineLayout)) ?? .table
        // hasShownOpLogBootstrapNotice was removed in v0.3.1 (the dead-code
        // sweep after Tasks shipped). Existing on-disk JSONs may still have
        // the key — JSON decoding ignores unknown keys silently, so old
        // ui-state.json files load fine.
    }

    /// Load from disk; return `.empty` if file is missing, malformed, or has
    /// a schemaVersion newer than this build understands. v1 JSONs upgrade
    /// to v2 transparently — missing fields default.
    public static func loadOrEmpty(from url: URL) -> UIState {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        guard let decoded = try? JSONDecoder().decode(UIState.self, from: data) else {
            return .empty
        }
        guard decoded.schemaVersion <= currentSchemaVersion else { return .empty }
        // Stamp the loaded state with the current schema; on next save, the
        // file becomes a v2 file.
        var upgraded = decoded
        upgraded.schemaVersion = currentSchemaVersion
        return upgraded
    }
}
