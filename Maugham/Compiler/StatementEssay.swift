import Foundation
import MaughamCore

/// Where the writer's freeform intent prose ends and the itemized strata begin
/// (declared-world Task 6, spec §3.2).
///
/// `RulingsSection` is the parser and the canonical renderer; this is the one
/// thing it deliberately does not offer — **a way to rewrite the essay and put
/// everything below it back byte for byte.**
///
/// **Why not `RulingsSection.render(essay:rulings:)`.** `render` is a canonical
/// form and its own doc says the round trip *converges* rather than being the
/// identity: what it converges by is discarding anything under the `## Rulings`
/// heading that is not a list item. That is right for a verb the writer invoked
/// on a ruling — they asked for the section to be rewritten — and wrong for the
/// essay editor, which recomposes on **every keystroke**. A writer who typed a
/// paragraph under their own Rulings heading would watch it survive until they
/// touched the essay above it, and then not.
///
/// So the split here is positional and the tail is opaque: `half(of:)` returns
/// exactly the prefix `RulingsSection.parse` calls the essay, and `recomposed`
/// puts a new prefix in front of the remaining bytes without looking at them.
/// `recomposed(essay: half(of: x), into: x) == x` for every `x` — an equality,
/// not a fixpoint, which is what `StatementPaneStrataTests`'
/// `test_puttingTheEssayBackUnchangedIsTheIdentity` asserts over the shapes that
/// have a boundary in a different place.
///
/// **What the editor shows moves when the boundary moves, and that is the one
/// sharp edge left here** (whole-branch review, C1). `half` is a binding get:
/// anything `RulingsSection.parse` decides is below the boundary leaves the
/// mounted buffer within a frame, and `EditorSurface.reconcileTextBuffer`
/// replaces it with `preserveUndoStack: false`. C1 was the reachable case — a
/// heading with nothing under it counted, so typing `## Rulings` yanked it back
/// out — and the parser now requires an item, which is asserted end to end by
/// `StatementPaneStrataTests.test_typingTheRulingsHeadingIntoTheEssayEditor
/// LeavesItWhereTheWriterPutIt`.
///
/// The residual, recorded rather than guarded: with a section ALREADY in the
/// file, typing a *second* `## Rulings` heading at the end of the essay makes
/// the writer's new heading the first blank-delimited one, and the existing
/// items below it qualify it — so that line leaves the buffer on the keystroke
/// that finishes it, and the next verb folds the two headings into one. No
/// words are lost (the tail is opaque to `recomposed`, and `render` adopts a
/// heading rather than duplicating it), the guide no longer sends anyone down
/// this path, and closing it means changing which heading `parse` calls the
/// boundary — a semantic change with a regression of its own for any file that
/// really does carry two sections.
///
/// **The section boundary is asked for exactly once, of `RulingsSection`.** This
/// file does not know what `## Rulings` looks like, whether a heading has to be
/// blank-delimited, or that the delimiter line is stripped back off — it derives
/// the tail from the essay's own length, because the essay is a verbatim prefix
/// of the input by that parser's construction. A second spelling of the boundary
/// rule here is the F-A footgun arriving in a file that cannot see it.
enum StatementEssay {

    /// Which statements have strata beneath the essay at all.
    ///
    /// **Intent and an edition brief — the two destinations `RulingPerformer`
    /// writes a `## Rulings` section into** (publish department, Task 6). This
    /// answers a question about the FILE, not about a surface: a brief carries
    /// rulings by construction the moment a verb puts one there, so answering
    /// `false` for it would not stop the section existing — it would only stop
    /// everything downstream from seeing where the essay ends.
    ///
    /// The live consequence is `ProjectStore.appendToStatement`, which is where
    /// the honest value pays for itself rather than a surface nobody has built:
    /// with `false`, prose appended to a brief that already carries rulings
    /// lands *below* the list, where `RulingsSection.parse` does not read it and
    /// no essay reader can show it — the words safe on disk and invisible in the
    /// surface that owns them, which is the loss that seam's own doc comment
    /// names.
    ///
    /// **Visual language is still false, and that is the switch this was always
    /// about.** It is a statement with no rulings and no verb that writes one;
    /// splitting it would take a `## Rulings` heading a writer typed as an
    /// ordinary heading, hide everything under it from the editor, and list it
    /// as rows whose Revoke refuses. An `.unknown` kind is a newer build's,
    /// retained and ignored everywhere else (`Statement.Kind`); it has no strata
    /// here either.
    ///
    /// **Two things a brief-side pane will need, neither of them this
    /// function's** (recorded here because the pane cannot see them, and
    /// `.editionBrief` reaches neither today — `DetailPaneToggle` builds
    /// `StatementPane` with `.intent` and `.visualLanguage` only). First,
    /// `StatementPane.bibleFacts` gates on this predicate as a proxy for "is
    /// this the intent statement", and the bible belongs to intent alone — it
    /// wants its own question, not a second reading of this one. Second, the
    /// rows' verbs (`RulingsStratum`) still name `.intent` when they call the
    /// performer, so a brief's row would refuse until they take a kind too.
    static func carriesRulings(_ kind: Statement.Kind) -> Bool {
        switch kind {
        case .intent, .editionBrief: return true
        case .visualLanguage, .unknown: return false
        }
    }

    /// The writer's freeform prose: everything above the Rulings section, or the
    /// whole document when there is none.
    static func half(of markdown: String) -> String {
        RulingsSection.parse(markdown).essay
    }

    /// `markdown` with its essay replaced by `essay`, and everything from the
    /// section boundary onward preserved exactly.
    ///
    /// The delimiter is put back only when it has to be: the tail already begins
    /// with the blank line the parser stripped in every case except a document
    /// whose heading is on line 0, and a new essay running straight into
    /// `## Rulings` would leave the heading mid-line and stop being a section at
    /// all.
    static func recomposed(essay: String, into markdown: String) -> String {
        let existing = half(of: markdown)
        guard markdown.hasPrefix(existing) else {
            // Unreachable: `parse`'s essay is a verbatim prefix of its input.
            // The fallback is the section's own canonical form rather than
            // `essay` alone — being wrong about the prefix must not be a way to
            // delete the writer's rulings.
            return RulingsSection.render(
                essay: essay, rulings: RulingsSection.parse(markdown).rulings)
        }
        let tail = String(markdown.dropFirst(existing.count))
        if essay.isEmpty || tail.isEmpty || tail.hasPrefix("\n") { return essay + tail }
        return essay + "\n\n" + tail
    }
}
