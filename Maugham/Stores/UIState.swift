import Foundation

/// Per-project UI state persisted to `.maugham/ui-state.json`.
/// Schema-versioned for forward compatibility.
public struct UIState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var selectedItemId: String?
    public var isNoChromeOn: Bool
    public var scrollLine: Int

    public init(
        schemaVersion: Int = UIState.currentSchemaVersion,
        selectedItemId: String? = nil,
        isNoChromeOn: Bool = false,
        scrollLine: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.selectedItemId = selectedItemId
        self.isNoChromeOn = isNoChromeOn
        self.scrollLine = scrollLine
    }

    public static let empty = UIState()

    /// Load from disk; return `.empty` if file is missing, malformed, or has
    /// an unknown schemaVersion. Forward-compatible by design.
    public static func loadOrEmpty(from url: URL) -> UIState {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        guard let decoded = try? JSONDecoder().decode(UIState.self, from: data) else {
            return .empty
        }
        guard decoded.schemaVersion == currentSchemaVersion else { return .empty }
        return decoded
    }
}
