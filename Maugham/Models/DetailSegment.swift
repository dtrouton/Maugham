import Foundation

/// Which mode the right pane displays.
public enum DetailSegment: String, Codable, Equatable, Sendable {
    case inspector
    case research
    case outline
}
