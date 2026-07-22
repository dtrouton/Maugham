import Foundation

/// Which mode the right pane displays.
public enum DetailSegment: String, Codable, Equatable, Sendable, CaseIterable {
    case inspector
    case annotations
    case research
    case outline
    case history
    case tasks      // milestone-tasks
    case inbox      // iphone-companion: triage captures from MaughamPhone
    case palette    // sensory-palette: write against a palette card (⌘⌥7)
    case translation // translation-layer: source text + translator queries (⌘⌥8)
}
