import Foundation

/// Which mode the right pane displays.
public enum DetailSegment: String, Codable, Equatable, Sendable {
    case inspector
    case annotations
    case research
    case outline
    case history
    case tasks      // milestone-tasks
    case inbox      // iphone-companion: triage captures from MaughamPhone
}
