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

    /// Runtime-gated, persona-independent segments that survive a persona
    /// switch: a writer mid-search or looking at the trash must not be
    /// ejected by switching persona. This is the single source both
    /// `PersonaModifier.applyPersonaChange`'s `keepBinder` whitelist and
    /// `BinderSegmentPicker.visibleSegments`'s append draw from, so the two
    /// cannot disagree — a future runtime-gated segment added to one and not
    /// the other would silently eject a writer from it on persona switch.
    /// Today only `.trash` and `.find` qualify; nothing else does.
    public var isTransient: Bool {
        switch self {
        case .trash, .find: return true
        case .manuscript, .research, .palette, .scenes: return false
        }
    }
}

// MARK: - Picker labelling

public extension BinderSegment {
    /// A collection's manuscript segment is labelled "Pieces"; every other
    /// project type calls it "Manuscript". Lives beside the case so the two
    /// binder toggles cannot label the same segment differently.
    func displayName(for projectType: ProjectType) -> String {
        switch self {
        case .manuscript: return projectType == .collection ? "Pieces" : "Manuscript"
        case .research: return "Research"
        case .palette: return "Palette"
        case .scenes: return "Scenes"
        case .trash: return "Trash"
        case .find: return "Find"
        }
    }

    /// SF Symbol to render instead of `displayName(for:)` in the binder
    /// picker, or nil for the text-labelled segments. Only Palette is an icon
    /// — it is the narrow one, and the picker is a 240pt column. Keeping this
    /// beside the case is what lets both toggles share one `ForEach`.
    var pickerSymbolName: String? {
        self == .palette ? "paintpalette" : nil
    }
}
