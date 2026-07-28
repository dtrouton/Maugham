import Foundation
import MaughamCore

/// Which top-level segment is active in the binder pane.
public enum BinderSegment: String, Codable, Equatable, Sendable, CaseIterable {
    case manuscript
    case research
    case palette
    case scenes
    /// The Plan persona's centre column — the freeform planning canvas (M1C).
    /// One canvas per project (spec §2); regions do all the dividing.
    case canvas
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
        case .manuscript, .research, .palette, .scenes, .canvas: return false
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
        case .canvas: return "Canvas"
        case .trash: return "Trash"
        case .find: return "Find"
        }
    }

    /// SF Symbol the binder picker renders for this segment. EVERY segment has
    /// one, and the picker renders nothing else — `displayName(for:)` survives
    /// as the tooltip and the accessibility label.
    ///
    /// It used to be `String?`, icon for Palette and text for the rest, which
    /// made the picker's `ForEach` emit two different child types behind an
    /// `if let`. That is a `_ConditionalContent` whose branch is cached per
    /// POSITION, and a segmented `Picker` updates its `NSSegmentedControl` in
    /// place: as soon as a persona change reshaped the list, the stale branch
    /// stayed on the old index and the picker rendered `Pieces | 🎨Research |
    /// 🎨` — a palette icon glued to Research, and, in a persona with no
    /// Palette segment at all, a palette icon on a segment that selects
    /// Research. That is 2026-07-25 smoke defect C, and why the writer could
    /// not reach the palette wall. Reproduced by driving the list through a
    /// persona switch offscreen; the uniform-`Image` picker is stable through
    /// the same sequence.
    ///
    /// Text for every segment was measured and rejected: the segmented control
    /// will not compress below its ideal width, and `Manuscript | Research |
    /// Palette` alone measures 264pt against a 240pt ideal column (352pt with
    /// Trash, 440pt with Find), so it truncates from the leading edge. The
    /// icon set measures 87–145pt and always fits — and it matches the right
    /// pane's picker, which has been icon-only since ADR 0005.
    var pickerSymbolName: String {
        switch self {
        case .manuscript: return "doc.text"
        case .research: return "books.vertical"
        case .palette: return "paintpalette"
        case .scenes: return "film"
        case .canvas: return "square.on.circle"
        case .trash: return "trash"
        case .find: return "magnifyingglass"
        }
    }
}
