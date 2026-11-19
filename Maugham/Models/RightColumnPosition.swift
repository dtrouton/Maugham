import Foundation

/// **The right column's three positions** (shell plan 3): To resolve, Brief
/// and the pulled-up thing, selected by ⌘1/⌘2/⌘3. One is remembered
/// (`UIState.rightColumnPosition`); what each shows for a given subject is
/// `RightColumnContent.of`. The pulled-up position is hidden, never disabled,
/// while it would show nothing (`RightColumnContent.offersPulledUp`).
public enum RightColumnPosition: String, Codable, CaseIterable, Sendable {
    case resolve, brief, pulledUp

    var systemImageName: String {
        switch self {
        case .resolve: return "tray"
        case .brief: return "target"
        case .pulledUp: return "pin"
        }
    }

    var helpText: String {
        switch self {
        case .resolve: return "To resolve — what has been raised and waits on you (⌘1)"
        case .brief: return "Brief — what this is held to (⌘2)"
        case .pulledUp: return "Pulled up — the one thing you pulled up from the tree (⌘3)"
        }
    }

    var keyEquivalent: Character {
        switch self {
        case .resolve: return "1"
        case .brief: return "2"
        case .pulledUp: return "3"
        }
    }
}
