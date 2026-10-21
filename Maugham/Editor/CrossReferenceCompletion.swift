import Foundation
import MaughamCore

/// **The cross-reference picker** (report foundations plan 3b Task 4, rulings
/// R-3b-5 and R-3b-6): a `CompletionSource` over the window's cached
/// `ReferenceIndex.targets`, the project's labelled figures, tables and
/// sections in publishing order.
///
/// - **Trigger.** `@` and a letter at a word start — the line's start, or
///   after whitespace, `(`, `[` or `;` — never after an email-like character.
///   The query is everything after the `@` (`fi`, `fig:re`). A bare `@` is a
///   place the picker completes (the menu writes one and opens it there) but
///   a keystroke never opens it (`opensWhenTyped`), and a query nothing
///   matches is no trigger, so a handle (`@sarah`) closes the list at its
///   first unmatched letter and ends as typed.
/// - **What an accept writes.** `@fig:name`, over the `@` and the query, and
///   on through the rest of a label (one with a colon) the caret sat in.
/// - **Filter.** A label or its name by prefix first, then a word prefix in
///   the label, the number ("Figure 3") or the caption, ignoring case and
///   accents; each tier in publishing order.
///
/// `[@` is the citation picker's, asked first: in a bracket the citation
/// picker lets go at the colon of `[@fig:` and this one takes it. The trigger
/// reads the caret's line only; the rows read the cached index.
@MainActor
final class CrossReferenceCompletion: CompletionSource {
    /// R-3b-6's empty result, in this picker's words.
    static let emptyResultMessage = "No matching figures, tables or sections"

    let emptyMessage = CrossReferenceCompletion.emptyResultMessage
    let actionName = "Insert Cross-Reference"

    private let index: () -> ReferenceIndex

    /// `index` returns the window's cached index (`EditorCoordinator.referenceIndex`).
    init(index: @escaping () -> ReferenceIndex) {
        self.index = index
    }

    func trigger(in text: NSString, caret: Int) -> CompletionTrigger? {
        guard let trigger = Self.locate(in: text, caret: caret) else { return nil }
        // A query nothing matches is not a cross-reference (`@sarah`).
        if !trigger.query.isEmpty, Self.matching(index().targets, query: trigger.query).isEmpty {
            return nil
        }
        return trigger
    }

    /// A keystroke opens the list on `@` and a letter, never on the bare `@`.
    func opensWhenTyped(_ trigger: CompletionTrigger) -> Bool { !trigger.query.isEmpty }

    func items(for trigger: CompletionTrigger) -> [CompletionItem] {
        Self.matching(index().targets, query: trigger.query).map(Self.row(for:))
    }

    /// A row: "Figure 3 — caption", the number alone for an uncaptioned table,
    /// or a section's title; the label muted beside it (R-3b-6).
    nonisolated static func row(for target: ReferenceIndex.Target) -> CompletionItem {
        let title = target.detail.isEmpty ? target.text : "\(target.text) — \(target.detail)"
        return CompletionItem(title: title, subtitle: target.label.reference,
                              insertion: "@" + target.label.reference)
    }

    // MARK: - The filter

    /// The targets `query` matches, best first: a label (`fig:re`) or a
    /// label's name (`re`) by prefix, then a word prefix in the label, the
    /// number or the caption; each tier in publishing order. An empty query
    /// keeps them all.
    nonisolated static func matching(_ targets: [ReferenceIndex.Target],
                                     query: String) -> [ReferenceIndex.Target] {
        let q = CompletionMatch.fold(query)
        guard !q.isEmpty else { return targets }
        var first: [ReferenceIndex.Target] = [], rest: [ReferenceIndex.Target] = []
        for target in targets {
            let reference = CompletionMatch.fold(target.label.reference)
            if reference.hasPrefix(q) || CompletionMatch.fold(target.label.name).hasPrefix(q) {
                first.append(target)
            } else if [reference, CompletionMatch.fold(target.text), CompletionMatch.fold(target.detail)]
                        .contains(where: { CompletionMatch.matches($0, q) }) {
                rest.append(target)
            }
        }
        return first + rest
    }

    // MARK: - The trigger

    /// The cross-reference completion at `caret`, or nil (R-3b-5): an `@` at
    /// a word start, then a query that starts with a letter (or none yet).
    /// Code spans and fences are the coordinator's to refuse.
    nonisolated static func locate(in text: NSString, caret: Int) -> CompletionTrigger? {
        guard caret >= 0, caret <= text.length else { return nil }
        var queryStart = caret
        while queryStart > 0, isLabelUnit(text.character(at: queryStart - 1)) { queryStart -= 1 }
        guard queryStart > 0, text.character(at: queryStart - 1) == PickerUnit.at else { return nil }
        let at = queryStart - 1
        guard at == 0 || isWordStartBoundary(text.character(at: at - 1)) else { return nil }
        let query = text.substring(with: NSRange(location: queryStart, length: caret - queryStart))
        if let first = query.unicodeScalars.first, !CharacterSet.letters.contains(first) { return nil }
        // On through the rest of a label the caret sits in — one with a
        // colon, so a word typed after an `@` is never claimed.
        var end = caret
        while end < text.length, isLabelUnit(text.character(at: end)) { end += 1 }
        let token = text.substring(with: NSRange(location: queryStart, length: end - queryStart))
        if !token.contains(":") { end = caret }
        return CompletionTrigger(replaceRange: NSRange(location: at, length: end - at), query: query)
    }

    /// A character a cross-reference query may hold: a query character or the colon.
    private nonisolated static func isLabelUnit(_ unit: unichar) -> Bool {
        unit == PickerUnit.colon || CompletionMatch.isQueryUnit(unit)
    }

    /// What may come before a word-start `@`: whitespace, `(`, `[` or `;`.
    private nonisolated static func isWordStartBoundary(_ unit: unichar) -> Bool {
        if unit == PickerUnit.openParen || unit == PickerUnit.openBracket
            || unit == PickerUnit.semicolon { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
