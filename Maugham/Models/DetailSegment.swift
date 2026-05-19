import Foundation

/// Which mode the right pane displays.
public enum DetailSegment: String, Codable, Equatable, Sendable {
    case inspector
    case annotations
    case research
    case outline
    case history
}
