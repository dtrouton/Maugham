import Foundation

/// Which top-level segment is active in the binder pane.
public enum BinderSegment: String, Codable, Equatable, Sendable {
    case manuscript
    case research
    case scenes
}
