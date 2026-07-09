import Foundation
import MaughamCore

/// Which top-level segment is active in the binder pane.
public enum BinderSegment: String, Codable, Equatable, Sendable {
    case manuscript
    case research
    case palette
    case scenes
    case trash
    case find

    /// The segment where a project's manuscript content lives — where
    /// "navigate to this document" should land. Screenplay binders have NO
    /// Manuscript segment (the picker offers Scenes/Research only; the Scenes
    /// segment IS the slugline navigator within the single `.fountain`), so
    /// forcing `.manuscript` on a screenplay drops it into the one-row novel
    /// BinderView (2026-07-02 smoke finding via the stats-window navigate
    /// path). Every receiver that resets or targets the content segment must
    /// route through here rather than re-deriving the type check.
    public static func documentHome(for projectType: ProjectType) -> BinderSegment {
        projectType == .screenplay ? .scenes : .manuscript
    }
}
