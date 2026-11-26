import SwiftUI
import MaughamCore

// MARK: - The cold-start offer

/// To resolve's empty state for an open piece worth reading that has never
/// been checked (spec §4: *"one refusable offer... On-demand, never
/// background, never re-asked as a nag."*). **Read** asks for ⌘R's check
/// through the command's one delivery path (`MaughamEvent.postRun`), never the
/// orchestrator directly; **Not now** records the refusal in
/// `DiagnosticsStore` and the offer never renders again for this document.
@MainActor
struct DiagnosticsColdStartOffer: View {
    let docId: String
    let diagnostics: DiagnosticsStore
    /// `CheckNarrative.otherLoopLine`: non-`nil` refuses Read and says why.
    let otherLoopLine: String?
    /// What the project calls this piece (`PieceNoun`).
    let noun: PieceNoun

    var body: some View { coldStartOffer }

    /// **The cold-start offer** (spec §4). Understated, on `content`'s
    /// register: no sheet, no alert — the same two-button margin-note shape
    /// the pane uses everywhere else (`DiagnosticRow`'s Answer/Promote row).
    @ViewBuilder
    private var coldStartOffer: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            // **No `fixedSize(horizontal:vertical:)` here, and the absence is
            // load-bearing** — see `header`'s own note. This sentence carried
            // one, and it is what Denver's 2026-08-08 smoke found: the whole
            // window's three columns laid out ~600pt taller than the window,
            // so the tree showed a band scrolled off the top that could not be
            // scrolled back, and the centre column's editor sat above the
            // visible region entirely. `DiagnosticsPaneColumnHeightTests`
            // measures it.
            Text(CheckNarrative.coldStartOfferSentence(noun))
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            HStack(spacing: 8) {
                Button("Not now") { diagnostics.refuseColdStart(docId: docId) }
                    .buttonStyle(.bordered)
                // A check, said literally (two loops P1) — and asked for the
                // way ⌘R asks: the command, whose receiver reads the window's
                // open piece, which is the only piece this offer is drawn on
                // (`ResolvePane`, shell plan 2 Task 7).
                Button("Read") {
                    MaughamEvent.postRun(.checkWriting)
                }
                    .buttonStyle(.borderedProminent)
                    // Refused up front while another run holds the session
                    // (#83), saying whose run it waits for.
                    .disabled(CheckNarrative.refusesColdStartRead(otherLoopLine: otherLoopLine))
                    .help(otherLoopLine ?? CheckNarrative.coldStartOfferSentence(noun))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The drift line

/// The one line above the conformance summary — see `driftLine` below.
@MainActor
struct DiagnosticsDriftLine: View {
    /// `DriftDetector.drift` over the document's clause history.
    let driftFindings: [DriftFinding]

    var body: some View { driftLine }

    /// **The drift line — a pattern across runs, not a note about one.**
    /// Above the conformance summary because it is a claim about a clause the
    /// summary is about to name again (spec §4's last bullet). Not a
    /// `Diagnostic`: no id, no dismissal, no reply field — pressing it opens
    /// Brief, and the pattern breaking is what takes the line away, not a
    /// tap. See `driftNote`.
    @ViewBuilder
    private var driftLine: some View {
        if let line = CheckNarrative.driftNote(driftFindings) {
            Button {
                MaughamEvent.postPosition(.brief)
            } label: {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Divider()
        }
    }
}

// MARK: - One note

@MainActor
struct DiagnosticRow: View {
    let diagnostic: Diagnostic
    /// Whether this row offers the **Answer** action at all — false for a
    /// reader report, false with no project to write into, and false for every
    /// row of a preview (`CheckNarrative.offersDurableActions`).
    let canAnswer: Bool
    /// Whether this row offers **Promote to Task**. Its own flag rather than
    /// `canAnswer`'s: a reader's report has no answer to give and promotes
    /// perfectly well, so the two are false on different rows for different
    /// reasons and only a preview takes both away at once.
    let canPromote: Bool
    /// An answer of this row's already on its way to the piece's rulings.
    let isSubmitting: Bool
    /// What the last answer refused with, or `nil`. Its arrival is what tells
    /// the row the round trip is over and the field is the writer's again.
    let answerFailure: String?
    let onJump: (String) -> Void
    let onPromote: () -> Void
    let onAnswer: (String) -> Void

    /// The field is REVEALED rather than standing: a text box under every note
    /// is a form, and the pane's register is a margin note.
    @State private var isAnswering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(diagnostic.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            // **The writer's prose, never its id** (requirement 3). One chip a
            // line: a chip is already a short quotation, and two side by side in
            // a pane this narrow would each be truncated to nothing.
            ForEach(diagnostic.refs ?? [], id: \.paragraphId) { ref in
                ExcerptChip(ref: ref, onJump: onJump)
            }
            HStack(spacing: 6) {
                if canAnswer && !isAnswering {
                    Button("Answer", action: reveal)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Say why this is deliberate. It becomes a ruling in your "
                              + "intent, and the next check reads it.")
                }
                if canPromote {
                    Button("Make a To-Do", action: onPromote)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Keep this note as a to-do on the document.")
                }
            }
            if isAnswering { replyField }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        // The tap-to-jump must not fire from inside the field the writer is
        // typing in — `onTapGesture` on the row would otherwise scroll the
        // editor out from under them mid-sentence.
        .onTapGesture {
            guard !isAnswering,
                  let pid = CheckNarrative.paragraphToNavigateTo(for: diagnostic)
            else { return }
            onJump(pid)
        }
    }

    /// **Understated on purpose.** A plain field with a prompt rather than a
    /// bordered box with a Send button: the writer is answering a margin note,
    /// not filling in a form, and this pane's whole register is that nothing on
    /// it nags.
    @ViewBuilder
    private var replyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Why is this deliberate?", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($fieldFocused)
                .disabled(isSubmitting)
                .onSubmit { commit() }
                .onExitCommand { cancel() }
            if let answerFailure {
                Text(answerFailure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Reveal the field and put the caret in it. The deferral is tripwire 16's:
    /// a single `DispatchQueue.main.async` tick loses the race with SwiftUI's
    /// own focus pass, and a field the writer has to click into is an action
    /// that only half happened. `BinderRow.claimFocus()` is the canonical
    /// spelling.
    private func reveal() {
        isAnswering = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            fieldFocused = true
        }
    }

    /// **The words go up and the field stays open** — closing it is not this
    /// method's job. The pane owns the round trip: on success the note is
    /// dismissed and this whole row goes with it, and on failure the row stays
    /// exactly as it is with the draft still in it, because a commit that
    /// emptied the field would take the writer's sentence with it on the one
    /// path where they still need it.
    ///
    /// Return on an untouched field is a cancel rather than a refusal: nothing
    /// was said, so there is nothing to report.
    private func commit() {
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            cancel()
            return
        }
        onAnswer(words)
    }

    /// Escape: the field goes away and nothing is written. The draft goes with
    /// it — the writer said no.
    private func cancel() {
        isAnswering = false
        fieldFocused = false
        draft = ""
    }
}

// MARK: - One note from this check (spec §7.0)

/// A paragraph the note points at, drawn as **the words it said** — the whole
/// of requirement 3 on this surface. Pressing it makes the same jump the row
/// makes; the id it carries is a payload and never a label.
@MainActor
/// **The words a reference travels as**, never its paragraph id
/// (requirement 3). Internal rather than file-private since the editorial
/// letter's own section draws the same chip: a second capsule with the same
/// job would be two answers to what a reference looks like.
struct ExcerptChip: View {
    let ref: Diagnostic.Ref
    let onJump: (String) -> Void

    /// What the chip's press does: the jump, with its own reference's
    /// paragraph — pinned without a press (tripwire 33, #120).
    func jump() {
        onJump(ref.paragraphId)
    }

    var body: some View {
        Button {
            jump()
        } label: {
            Text("\u{201C}\(ref.excerpt)\u{201D}")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Go to this paragraph")
    }
}
