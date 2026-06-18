import Foundation
import MaughamCore

/// One disposition / authoring action a reviewer can take on an annotation from
/// the interactive margin card. Mirrors the affordances `AnnotationsPane`
/// offers per kind so the editor card and the pane stay in lock-step.
enum ReviewCardAction: Equatable {
    /// Accept a suggestion (applies the replacement) or acknowledge a
    /// comment/craft note. Labelled "Got it" for comments, "Accept" otherwise —
    /// matching `AnnotationsPane.actionRow`.
    case accept
    /// Reject a suggestion / craft note (opens the reasoning sheet in the pane;
    /// here it records a reject with no reason — the card has no text field).
    case reject
    /// Archive (dismiss without accept/reject).
    case archive
    /// Reply to a query (re-uses the inline composer for the reply text).
    case reply
    /// Edit your OWN annotation's body / replacement (own-only).
    case edit
    /// Delete (withdraw) your OWN annotation (own-only; confirmed first).
    case delete

    /// Short button title for the margin card. Kept terse — the card is narrow.
    func label(for kind: AnnotationKind) -> String {
        switch self {
        case .accept:  return kind == .comment ? "Got it" : "Accept"
        case .reject:  return "Reject"
        case .archive: return "Archive"
        case .reply:   return "Reply"
        case .edit:    return "Edit"
        case .delete:  return "Delete"
        }
    }
}

/// Pure policy: which actions a margin card shows for a given annotation kind
/// and ownership. This is the single source mirrored against
/// `AnnotationsPane.actionRow` (disposition) + `ownAffordances` (edit/delete),
/// extracted so it's directly unit-testable without an NSView context.
///
/// Disposition (always, per kind):
/// - `.comment`    → Accept ("Got it"), Archive
/// - `.suggestedChange` → Accept, Reject, Archive
/// - `.query`      → Reply, Archive
/// - `.craftNote`  → Accept, Reject, Archive
///
/// Own-only (appended when `isOwn`): Edit, Delete.
enum ReviewCardActions {
    static func actions(for kind: AnnotationKind, isOwn: Bool) -> [ReviewCardAction] {
        var actions: [ReviewCardAction]
        switch kind {
        case .comment:
            actions = [.accept, .archive]
        case .suggestedChange, .craftNote:
            actions = [.accept, .reject, .archive]
        case .query:
            actions = [.reply, .archive]
        }
        if isOwn {
            actions.append(.edit)
            actions.append(.delete)
        }
        return actions
    }
}
