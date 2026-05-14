import Foundation

/// Visual layout of the Outline pane: table vs index cards.
public enum OutlineLayout: String, Codable, Equatable, Sendable {
    case table
    case cards
}
