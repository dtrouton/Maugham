import SwiftUI
import MaughamCore

/// **Ask about… — what the writer wants THIS round to look at** (editorial
/// letter P2 Task 7, spec §3.7).
///
/// Lerman's step 2, and the one thing the writer could not say before: the
/// intent statement is about the piece, and a worry is about this draft on
/// this morning. The field is one line, per document, and it outlives the
/// round — a worry usually outlasts one reading, and a field that emptied
/// itself after every check would make the writer retype it.
///
/// **Two hosts draw it and neither owns it.** Author's Diagnostics header and
/// Review's round cockpit are the same field over the same per-document value
/// (`DiagnosticsStore.ask(docId:)`), so it lives here rather than being spelled
/// twice — `TurnClauseOffer`'s reason, in a view instead of a verb. The cockpit
/// holds no store, which is why the verbs arrive inside ``Input``;
/// ``commit(_:docId:diagnostics:)`` and ``note(_:docId:diagnostics:)`` below are
/// the one spelling of each, and both hosts call them.
///
/// **It COMMITS on submit and on focus loss, and never per keystroke.**
/// `DiagnosticsStore.setAsk` bumps the store's version and rewrites the asks
/// file on every call, so a per-keystroke binding would be one file write and
/// one full re-render per letter typed. The draft lives here; the store hears
/// about it when the writer is done with the sentence.
///
/// **Every keystroke is NOTED, which is a different act** (fix round 1,
/// Important 1). `DiagnosticsStore.notePendingAsk` is a dictionary write: no
/// file, no version bump, nothing re-rendered. It exists because ⌘R is a menu
/// command that never touches the first responder, so a worry typed and not
/// submitted would otherwise watch its own round go out briefed on the ask the
/// writer had *before*, with the new sentence still on screen in front of them.
/// `CompilerOrchestrator.beginRun` promotes whatever is pending before it reads
/// the ask.
///
/// **That promotion lives in the run rather than in a key handler here, and
/// deliberately.** A subscription in this view would have to be scoped to its
/// window (ADR 0021), and the window arrives through `WindowAccessor` on
/// AppKit's own schedule — measured 2026-09-02 landing after a mounted pane had
/// already been typed into, and arming then disarming as SwiftUI re-attached
/// the representable. It would also have covered only the two keystrokes, where
/// one line in `beginRun` covers those, the cockpit's Run and Fresh Eyes
/// buttons, and the cold-start offer's Read.
///
/// **It never starts a run.** The keystroke is the only trigger (spec §2) —
/// there is no Run button here and no `keyboardShortcut`. What the field
/// changes is what the next round is briefed with.
@MainActor
struct AskField: View {

    /// **Everything a host wires into the field, as one value.**
    ///
    /// Four parallel inputs on the cockpit — the ask, the commit, the note and
    /// the document they belong to — would be four things that must agree about
    /// one subject, with nothing checking that they do (tripwire 6's shape). A
    /// host either has an ask to draw or it does not, and that is one `nil`.
    struct Input {
        /// **Which document this ask belongs to.** The field's identity as
        /// well as the verbs' destination: see ``AskField/body``'s reset.
        let docId: String
        /// The stored ask, as the host reads it back. `nil` is nothing asked.
        let text: String?
        /// Take the words. Answers the refusal to draw, or `nil` when they
        /// landed — ``AskField/commit(_:docId:diagnostics:)`` is what every
        /// production host passes.
        ///
        /// A returned string rather than a `Void` closure plus a `notice`
        /// input: the refusal belongs to the press that caused it, and a
        /// parallel input the host has to keep in step with this one is
        /// tripwire 6's shape again.
        let commit: (String?) -> String?
        /// **Note what is being typed against a document, without committing
        /// it** — `DiagnosticsStore.notePendingAsk`. Called on every keystroke,
        /// which is only affordable because noting writes nothing; see the type
        /// doc.
        ///
        /// **`nil` discards** rather than noting an empty draft, and the two
        /// are different acts: an empty draft is a withdrawal a later round
        /// promotes, while a discard says the words are no longer the writer's
        /// business — which is what leaving a chapter means, and which must
        /// leave that chapter's standing ask alone.
        ///
        /// The document is a parameter because the field notes against the one
        /// it is LEAVING as well as the one it is on.
        let note: (_ text: String?, _ docId: String) -> Void
    }

    let input: Input

    /// **What the writer has typed but not yet committed.** Seeded from the
    /// stored ask and re-seeded when it changes from outside — but never while
    /// the writer is in the field, which would take a half-typed sentence away
    /// from them mid-word.
    @State private var draft = ""
    /// What the last commit refused, if it did. Cleared by anything that makes
    /// it no longer true — see ``clearNotice()``'s callers.
    @State private var notice: String?
    @FocusState private var focused: Bool

    private var ask: String? { input.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                TextField(Self.placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($focused)
                    .onSubmit { commitDraft() }
                    .help(Self.help)
                    // **A handle, because this field is now STANDING in a
                    // header that also reveals fields on demand.** Author's
                    // pane asserts in three places that pressing a row opened
                    // a reply field, and those reads count text fields — with
                    // an unlabelled second field permanently on screen they
                    // can no longer tell the two apart.
                    .accessibilityIdentifier(Self.fieldIdentifier)
                // **Drawn only when there is something to clear.** A ✕ over an
                // empty field is a control that does nothing, and the row is
                // one line in a narrow column.
                if !draft.isEmpty {
                    Button(action: clear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.clearLabel)
                    .help(Self.clearHelp)
                }
            }
            if let notice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { draft = ask ?? "" }
        // **Noted, not committed** — the type doc's distinction, and the whole
        // of what happens per keystroke.
        .onChange(of: draft) { _, now in input.note(now, input.docId) }
        // **A draft belongs to the document it was typed about, and to no
        // other** (fix round 1, Minor 2). Neither host keys this view on the
        // subject, and neither pane is rebuilt when the window's subject
        // changes — so without this a half-typed sentence about chapter one
        // survives a click onto chapter two and the next commit files it
        // there. The reset is deliberately NOT guarded on `focused`, unlike
        // the one below it: the writer has moved on, and there is no
        // half-typed sentence worth keeping for a piece they are no longer
        // looking at.
        //
        // `.id(input.docId)` at each mount would do the same thing, and is
        // what a host would reach for. This lives here instead because there
        // are two hosts and a rule kept in one place cannot be forgotten in
        // the other.
        //
        // **And the chapter being left forgets it too.** The reseed below runs
        // through `draft`, so the note above records the NEW document's value —
        // but the old document would otherwise keep the half-typed sentence in
        // the store's pending buffer and promote it at its next round, an ask
        // the writer typed, abandoned, and can no longer see. Discarded rather
        // than noted empty, so the ask that chapter already had survives.
        .onChange(of: input.docId) { old, _ in
            input.note(nil, old)
            draft = ask ?? ""
            clearNotice()
        }
        // **The outside can move the ask; the writer's own typing must not be
        // clobbered by it.** A commit bumps the store's version, which re-reads
        // the ask and lands right back here — so without the focus guard a
        // commit made on submit would immediately overwrite the draft with its
        // own trimmed echo while the writer is still in the field.
        .onChange(of: ask) { _, now in
            // **The notice goes whatever the focus is** (fix round 1, Minor 3).
            // A refusal is about a draft that could not be stored; a stored ask
            // that has just changed means something landed, and a red line
            // still saying the last one was too long would be describing an
            // attempt that is over.
            clearNotice()
            guard !focused else { return }
            draft = now ?? ""
        }
        // **Focus LOSS commits, focus gain does not.** Clicking away from a
        // typed sentence is the writer being done with it; a writer who clicks
        // into the field and out again with nothing changed commits the same
        // words, which `commitDraft` refuses to write twice.
        .onChange(of: focused) { was, now in
            guard was, !now else { return }
            commitDraft()
        }
    }

    /// **A commit that would change nothing writes nothing.** Focus loss fires
    /// every time the writer clicks anywhere else — including straight after a
    /// Return that already committed the same sentence, and on a field they
    /// only tabbed through. `setAsk` rewrites the asks file and bumps the
    /// store's version on every call, so without this the "never per keystroke"
    /// rule would be kept and then undone one click at a time.
    ///
    /// The comparison is against the stored ask trimmed the way the store
    /// trims it, since that is the string a commit would produce. **The early
    /// return clears the notice** (fix round 1, Minor 3): a writer who
    /// shortened a refused ask back to what already stands has fixed it, and a
    /// red line surviving that would outlive its own cause with no way left to
    /// dismiss it.
    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (ask ?? "") else {
            clearNotice()
            return
        }
        notice = input.commit(draft)
    }

    /// Written once because three call sites clear it and a fourth will come;
    /// `notice = nil` scattered is how one of them ends up not doing it.
    private func clearNotice() {
        if notice != nil { notice = nil }
    }

    /// **Clearing is a commit of nothing, not a local erase.** The writer
    /// pressing ✕ has withdrawn their ask, and a field that emptied itself
    /// while the store still briefed the next round with the old sentence
    /// would be the app lying about what it is about to ask.
    private func clear() {
        draft = ""
        notice = input.commit(nil)
    }

    // MARK: - Copy

    /// The register is the pane's: an invitation, not an instruction.
    static let placeholder = "Ask about\u{2026}"

    static let help =
        "What you want this check to look at \u{2014} \u{201C}I'm worried the middle "
        + "sags\u{201D}. Kept until you clear it, at most "
        + "\(DiagnosticsStore.askLimit) characters."

    /// **"Clear the ask", not "Clear."** The label is what VoiceOver reads and
    /// what a mounted test presses, and a bare "Clear" collides with the
    /// queue's own triage menu one view over.
    static let clearLabel = "Clear the ask"

    /// The accessibility identifier the field carries — see the modifier's own
    /// note. Named here so a test filters on a constant rather than a literal.
    static let fieldIdentifier = "maugham.ask-field"

    static let clearHelp = "Stop asking about this."

    /// **What a refused ask says.** Names the limit, because a writer told only
    /// that it is too long has no way to know how much to cut. Built from the
    /// store's own constant so the sentence and the refusal cannot disagree.
    static let tooLongNotice =
        "That's longer than \(DiagnosticsStore.askLimit) characters. A worry is a "
        + "sentence, not a page \u{2014} shorten it and press Return."

    // MARK: - The two verbs, in one spelling

    /// **What both hosts put in ``Input/commit``.**
    ///
    /// SwiftUI exposes no way to deliver a Return keystroke into a hosted
    /// `TextField`'s editor (`DiagnosticsPaneTests`' own note on the reply
    /// field), so this is the named function the tests drive in the field's
    /// place — and, being one function, it is also what stops Author and
    /// Review refusing a long ask in two different sentences.
    static func commit(
        _ text: String?, docId: String, diagnostics: DiagnosticsStore
    ) -> String? {
        diagnostics.setAsk(text, docId: docId) ? nil : tooLongNotice
    }

    /// **What both hosts put in ``Input/note``** — the keystroke half, in one
    /// spelling for the same reason.
    static func note(
        _ text: String?, docId: String, diagnostics: DiagnosticsStore
    ) {
        if let text {
            diagnostics.notePendingAsk(text, docId: docId)
        } else {
            diagnostics.discardPendingAsk(docId: docId)
        }
    }
}
