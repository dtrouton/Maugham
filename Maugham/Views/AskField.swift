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
/// holds no store, which is why the commit arrives as a closure; ``commit(_:docId:diagnostics:)``
/// below is the one spelling of what that closure does, and both hosts call it.
///
/// **It commits on submit and on focus loss, and never per keystroke.**
/// `DiagnosticsStore.setAsk` bumps the store's version and rewrites the asks
/// file on every call, so a per-keystroke binding would be one file write and
/// one full re-render per letter typed. The draft lives here; the store hears
/// about it when the writer is done with the sentence.
///
/// **It never starts a run.** The keystroke is the only trigger (spec §2) —
/// there is no Run button here, no `keyboardShortcut`, and submitting commits
/// the words and nothing else. What the ask changes is what the NEXT ⌘R is
/// briefed with.
@MainActor
struct AskField: View {
    /// The stored ask, as the host reads it back. `nil` is nothing asked.
    let ask: String?
    /// Take the words. Answers the refusal to draw, or `nil` when they landed
    /// — see ``commit(_:docId:diagnostics:)``, which is what every production
    /// host passes.
    ///
    /// A returned string rather than a second `notice` input beside a `Void`
    /// closure: the refusal belongs to the press that caused it, and a parallel
    /// input the host has to keep in step with this one is the shape tripwire 6
    /// is about.
    let commit: (String?) -> String?

    /// **What the writer has typed but not yet committed.** Seeded from ``ask``
    /// and re-seeded when it changes from outside — but never while the writer
    /// is in the field, which would take a half-typed sentence away from them
    /// mid-word.
    @State private var draft = ""
    /// What the last commit refused, if it did. Cleared by the next one that
    /// lands, so a shortened sentence takes its own notice away.
    @State private var notice: String?
    @FocusState private var focused: Bool

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
        // **The outside can move the ask; the writer's own typing must not be
        // clobbered by it.** The commit below bumps the store's version, which
        // re-reads ``ask`` and lands right back here — so without the focus
        // guard a commit made on submit would immediately overwrite the draft
        // with its own trimmed echo while the writer is still in the field.
        .onChange(of: ask) { _, now in
            guard !focused else { return }
            draft = now ?? ""
        }
        // **Focus LOSS commits, focus gain does not.** Clicking away from a
        // typed sentence is the writer being done with it; a writer who clicks
        // into the field and out again with nothing changed commits the same
        // words, which the store takes as a no-op.
        .onChange(of: focused) { was, now in
            guard was, !now else { return }
            commitDraft()
        }
    }

    /// **A commit that would change nothing writes nothing.** Focus loss is
    /// the second trigger, and it fires every time the writer clicks anywhere
    /// else — including straight after a Return that already committed the
    /// same sentence, and on a field they only tabbed through. `setAsk`
    /// rewrites the asks file and bumps the store's version on every call, so
    /// without this the "never per keystroke" rule would be kept and then
    /// undone one click at a time.
    ///
    /// The comparison is against the stored ask trimmed the way the store
    /// trims it, since that is the string a commit would produce.
    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (ask ?? "") else { return }
        notice = commit(draft)
    }

    /// **Clearing is a commit of nothing, not a local erase.** The writer
    /// pressing ✕ has withdrawn their ask, and a field that emptied itself
    /// while the store still briefed the next round with the old sentence
    /// would be the app lying about what it is about to ask.
    private func clear() {
        draft = ""
        notice = commit(nil)
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

    // MARK: - The commit, in one spelling

    /// **What both hosts hand to ``commit``.**
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
}
