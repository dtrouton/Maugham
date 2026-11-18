import Foundation
import MaughamCore

/// **To resolve's triage choice** (shell plan 2 Task 7b, approved by the
/// owner 2026-11-18): the queue's own vocabulary, `AnnotationTriageFilter`
/// (All / Do / Discuss / Decline / Untriaged), never a second one.
typealias ResolveTriageChoice = AnnotationTriageFilter

/// **The triage filter, beside the source chips.** A second, separate,
/// single-choice filter about NOTES, ANDed with the source selection
/// ("Lish's notes I marked Do"). Pure: it takes the items the list already
/// holds, and the list calls it once per regroup (tripwire 4), never per row.
enum ResolveTriage {

    /// **Offered only when a note in the snapshot carries a mark** — a quiet
    /// chapter gains no furniture.
    static func offered(_ items: [ResolveItem]) -> Bool {
        items.contains { item in
            if case .note(let note) = item { return note.annotation.triage != nil }
            return false
        }
    }

    /// The choice in force: the writer's, while the control is offered; All
    /// the moment the last mark is cleared (the control has gone, so a hidden
    /// choice may not keep narrowing the list).
    static func effective(_ choice: ResolveTriageChoice, offered: Bool) -> ResolveTriageChoice {
        offered ? choice : .all
    }

    /// Whether `item` passes `choice`. Under All everything does; under a
    /// mark, or Untriaged, only notes do — check findings and to-dos carry no
    /// triage and show only under All.
    static func matches(_ item: ResolveItem, _ choice: ResolveTriageChoice) -> Bool {
        guard choice != .all else { return true }
        guard case .note(let note) = item else { return false }
        return choice.matches(note.annotation)
    }
}

extension ResolveFilter {
    /// **The one filter the list applies**: the source selection AND the
    /// triage choice, in the items' order.
    static func visible(_ items: [ResolveItem], selection: Set<ResolveSource>,
                        triage: ResolveTriageChoice, localName: String) -> [ResolveItem] {
        visible(items, selection: selection, localName: localName)
            .filter { ResolveTriage.matches($0, triage) }
    }
}
