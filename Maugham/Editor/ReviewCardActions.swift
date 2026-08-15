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
    /// Stet (M3 P2) — read, considered, and the words stand. Not an accept
    /// (nothing is applied), not a reject (nothing is refused), not an archive
    /// (it was not set aside unread).
    case stet
    /// Archive (dismiss without accept/reject).
    case archive
    /// Reply to a query (re-uses the inline composer for the reply text).
    case reply
    /// Edit your OWN annotation's body / replacement (own-only).
    case edit
    /// Delete (withdraw) your OWN annotation (own-only; confirmed first).
    case delete

    /// Short label — used as the icon button's tooltip (the narrow card uses
    /// icon-only buttons, so this no longer renders as a title and can't truncate).
    func label(for kind: AnnotationKind) -> String {
        switch self {
        case .accept:  return kind == .comment ? "Got it" : "Accept"
        case .reject:  return "Reject"
        case .stet:    return "Stet"
        case .archive: return "Archive"
        case .reply:   return "Reply"
        case .edit:    return "Edit"
        case .delete:  return "Delete"
        }
    }

    /// SF Symbol for the margin card's icon-only button (avoids truncation in the
    /// narrow card; the `label` becomes the tooltip).
    var systemImageName: String {
        switch self {
        case .accept:  return "checkmark"
        case .reject:  return "xmark"
        // The proofreader's stet mark itself: dots under the words that stand.
        case .stet:    return "textformat.abc.dottedunderline"
        case .archive: return "archivebox"
        case .reply:   return "arrowshape.turn.up.left"
        case .edit:    return "pencil"
        case .delete:  return "trash"
        }
    }
}

/// Pure policy: which actions a margin card shows for a given annotation kind
/// and ownership. This is the single source mirrored against
/// `AnnotationsPane.actionRow` (disposition) + `ownAffordances` (edit/delete),
/// extracted so it's directly unit-testable without an NSView context.
///
/// Disposition (always, per kind):
/// - `.comment`    → Accept ("Got it"), Stet, Archive
/// - `.suggestedChange` → Accept, Reject, Stet, Archive
/// - `.query`      → Reply, Stet, Archive
/// - `.craftNote`  → Accept, Reject, Stet, Archive
///
/// Own-only (appended when `isOwn`): Edit, Delete.
///
/// **One deliberate asymmetry with the pane (M3 P2): triage is not here.**
/// The pane's rows carry a Do / Decline / Discuss menu and this set does not,
/// because triage is a QUEUE verb, not a margin verb — it is how a writer plans
/// a pass across many notes, and the margin card is one note beside the sentence
/// it is about, with no pile to sort. Stet, by contrast, is a resolution like
/// the other three, so it reaches the card wherever Archive does.
enum ReviewCardActions {
    static func actions(for kind: AnnotationKind, isOwn: Bool) -> [ReviewCardAction] {
        var actions: [ReviewCardAction]
        switch kind {
        case .comment:
            actions = [.accept, .stet, .archive]
        case .suggestedChange, .craftNote:
            actions = [.accept, .reject, .stet, .archive]
        case .query:
            actions = [.reply, .stet, .archive]
        }
        if isOwn {
            actions.append(.edit)
            actions.append(.delete)
        }
        return actions
    }
}
