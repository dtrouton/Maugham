import AppKit
import MaughamCore

/// **Comment… and Suggest… on a selection, outside the floating toolbar**
/// (shell p5 Task 7, the owner's added row): a writer comments on her own
/// text without entering read-through. Edit ▸ Comment… (⌘⇧K) and the text's
/// right-click open the SAME composer read-through's selection toolbar opens
/// (`EditorCoordinator.beginAuthoringAnnotation`); the toolbar itself stays
/// read-through's.
///
/// **Offered by the posture, never by read-through state**: a note is the
/// reviewer row — everybody's (`Posture.Verb.annotate`). Suggest… is offered
/// where the posture refuses the words themselves (`.writeText`): a writer
/// who may type changes her text; one who may not proposes the change. Over
/// a translation neither — a note would anchor to source text the selection
/// is not (`SelectionToolbarView.kinds`). Pure.
enum AnnotationOffer {
    static let commentTitle = "Comment\u{2026}"
    static let suggestTitle = "Suggest\u{2026}"
    /// The event payload's key: which composer.
    static let kindKey = "kind"

    /// What the text's right-click offers. `answersAnnotations`: the surface
    /// is a manuscript that writes notes (`createAnnotationHandler` is set).
    static func kinds(posture: Posture?, isReadingTranslation: Bool,
                      hasSelection: Bool, answersAnnotations: Bool) -> [SelectionToolbarView.Kind] {
        guard hasSelection, answersAnnotations, !isReadingTranslation,
              let posture, posture.allows(.annotate) else { return [] }
        return posture.allows(.writeText) ? [.comment] : [.comment, .suggest]
    }

    static func title(of kind: SelectionToolbarView.Kind) -> String {
        switch kind {
        case .suggest: return suggestTitle
        case .comment, .query, .translatorsNote: return commentTitle
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
