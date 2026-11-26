import AppKit
import MaughamCore

/// **What a selection is offered — one answer for the text's right-click and
/// read-through's floating toolbar** (shell p5 Task 7; fix round 1, I3, the
/// lead's ruling), so the same selection always gets the same offers. Edit ▸
/// Comment… (⌘⇧K) and the right-click open the SAME composer the toolbar
/// opens (`EditorCoordinator.beginAuthoringAnnotation`); the toolbar itself
/// stays read-through's.
///
/// - Over a translation: the Translator's note only — a note would anchor to
///   source text the selection is not.
/// - Where the posture refuses a note (`.annotate`), or no door stands
///   behind the editor (no posture): nothing.
/// - Where the writer may edit the words (`.writeText`) and they are not
///   read-through's frozen text: Comment… only — she changes her words
///   herself.
/// - Where she may not (someone else's piece, read-through): what the
///   toolbar offered before — Comment, Suggest, Query and the Translator's
///   note (⌘⌥C's window command, which writes no annotation).
///
/// The posture is the window's one door's answer (`EditorControl.posture`);
/// no permit rung is compared (tripwires 47, 51). Pure.
enum AnnotationOffer {
    static let commentTitle = "Comment\u{2026}"
    static let suggestTitle = "Suggest\u{2026}"
    static let queryTitle = "Query\u{2026}"
    static let translatorsNoteTitle = "Translator\u{2019}s Note\u{2026}"
    /// Edit ▸ Comment…'s tooltip: it acts on the words selected (fix round 1, M6).
    static let commentHelp = "Select words in the text to comment on them"
    /// The event payload's key: which composer.
    static let kindKey = "kind"

    /// `answersAnnotations`: the surface is a manuscript that writes notes
    /// (`createAnnotationHandler` is set).
    static func kinds(posture: Posture?, isReadingTranslation: Bool, inReadThrough: Bool,
                      hasSelection: Bool, answersAnnotations: Bool) -> [SelectionToolbarView.Kind] {
        guard hasSelection else { return [] }
        if isReadingTranslation { return [.translatorsNote] }
        guard answersAnnotations, let posture, posture.allows(.annotate) else { return [] }
        return posture.allows(.writeText) && !inReadThrough ? [.comment] : SelectionToolbarView.Kind.allCases
    }

    static func title(of kind: SelectionToolbarView.Kind) -> String {
        switch kind {
        case .comment: return commentTitle
        case .suggest: return suggestTitle
        case .query: return queryTitle
        case .translatorsNote: return translatorsNoteTitle
        }
    }

    /// The kind a `.maughamCommentOnSelection` post names.
    static func kind(of userInfo: [AnyHashable: Any]?) -> SelectionToolbarView.Kind? {
        (userInfo?[kindKey] as? String).flatMap(SelectionToolbarView.Kind.init(rawValue:))
    }

    /// **The text's right-click menu, composed** — the one builder
    /// `MaughamTextView.menu(for:)` runs, so a test pins exactly what the
    /// writer gets: Convert to Table Figure first in a pipe table, then the
    /// annotation items, then AppKit's own, each group parted by a separator.
    static func compose(base: NSMenu?, convert: NSMenuItem?, annotate: [NSMenuItem]) -> NSMenu? {
        let leading = (convert.map { [$0] } ?? []) + annotate
        guard !leading.isEmpty else { return base }
        let menu = base ?? NSMenu()
        var at = 0
        if let convert {
            menu.insertItem(convert, at: at); at += 1
            if !annotate.isEmpty { menu.insertItem(.separator(), at: at); at += 1 }
        }
        for item in annotate { menu.insertItem(item, at: at); at += 1 }
        if menu.items.count > at { menu.insertItem(.separator(), at: at) }
        return menu
    }
}
