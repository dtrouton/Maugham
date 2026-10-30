import SwiftUI
import MaughamCore

// MARK: - The cold-start offer

/// `DiagnosticsPane`'s empty state for a document worth reading that has never
/// been checked — see `coldStartOffer` below and the pane's own doc.
@MainActor
struct DiagnosticsColdStartOffer: View {
    let docId: String
    let diagnostics: DiagnosticsStore
    let orchestrator: CompilerOrchestrator
    /// `DiagnosticsPane.otherLoopLine`: non-`nil` refuses Read and says why.
    let otherLoopLine: String?

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
            Text(DiagnosticsPane.coldStartOfferSentence)
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            HStack(spacing: 8) {
                Button("Not now") { diagnostics.refuseColdStart(docId: docId) }
                    .buttonStyle(.bordered)
                // The cold-start offer is the Diagnostics pane's, which is
                // Author's report — a check, said literally (two loops P1).
                Button("Read") {
                    orchestrator.runRequested(docId: docId, kind: .check)
                }
                    .buttonStyle(.borderedProminent)
                    // Refused up front while another run holds the session
                    // (#83), saying whose run it waits for.
                    .disabled(DiagnosticsPane.refusesColdStartRead(otherLoopLine: otherLoopLine))
                    .help(otherLoopLine ?? DiagnosticsPane.coldStartOfferSentence)
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
    /// Intent, and the pattern breaking is what takes the line away, not a
    /// tap. See `driftNote`.
    @ViewBuilder
    private var driftLine: some View {
        if let line = DiagnosticsPane.driftNote(driftFindings) {
            Button {
                MaughamEvent.postDetailSegment(.intent)
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

// MARK: - This check

/// The wet-ink view — see `thisCheckSection` below.
@MainActor
struct DiagnosticsThisCheckSection: View {
    /// `DiagnosticsPane.thisCheckAnnotations`, already in manuscript order.
    let thisCheckAnnotations: [Annotation]
    let currentText: (String) -> String?
    /// `offersDurableActions` and the posture's `offersDisposal`, together.
    let canDispose: Bool
    let answerFailures: [String: String]
    let onGotIt: (Annotation) -> Void
    let onNotThis: (Annotation) -> Void

    var body: some View { thisCheckSection }

    /// **The wet-ink view** (spec §7.0) — the notes this check just raised,
    /// drawn in the pane's own register rather than the queue's.
    ///
    /// It draws above the drift line and the conformance summary because those
    /// two are the standing account of the writer's declared world, and this is
    /// what the keystroke they just pressed came back with. Nothing here says
    /// who wrote it, and no row needs to: these notes carry the byline of
    /// whoever read the piece — its stage editor, the coach (Le Guin, on a
    /// piece with no pass set, since Task 5), or Claude where nobody reads it
    /// — and that reader is already named once, in the header's reader
    /// line. A byline on every row would repeat it down the whole pane.
    ///
    /// No section at all when there is nothing to draw, rather than a heading
    /// over an empty list: this is a view of one run's output, and a run that
    /// raised nothing has nothing to show for itself here.
    @ViewBuilder
    private var thisCheckSection: some View {
        let notes = thisCheckAnnotations
        if !notes.isEmpty {
            PaneSectionHeader(title: "This check") { EmptyView() }
            ForEach(notes) { note in
                CompilerNoteRow(
                    annotation: note,
                    excerpt: DiagnosticsPane.jumpExcerpt(for: note, currentText: currentText),
                    canDispose: canDispose,
                    failure: answerFailures[note.id],
                    onJump: { DiagnosticsPane.jump(toParagraph: $0) },
                    onGotIt: { onGotIt(note) },
                    onNotThis: { onNotThis(note) })
                Divider()
            }
        }
    }
}

// MARK: - Conformance

/// The report's first section — see `conformanceSection` below.
@MainActor
struct DiagnosticsConformanceSection: View {
    let clauses: [DiagnosticIngest.ClauseStatus]
    /// `DiagnosticsPane.strains` — the conformance strains alone.
    let strains: [Diagnostic]
    /// Whether a clause's strains offer Answer: a project to file into, a
    /// finished run, and a posture that may edit this piece's intent. Each
    /// note also asks `DiagnosticsPane.offersAnAnswer(_:)` of its own kind.
    let canAnswer: Bool
    let canPromote: Bool
    let answering: Set<String>
    let answerFailures: [String: String]
    let onPromote: (Diagnostic) -> Void
    let onAnswer: (String, Diagnostic) -> Void

    var body: some View { conformanceSection }

    /// **The report's first section, and the reason the pane exists** — the
    /// writer's own clauses, quoted, each with how this draft sat against it.
    @ViewBuilder
    private var conformanceSection: some View {
        let paired = DiagnosticsPane.conformanceRows(clauses: clauses, strains: strains)
        if !paired.rows.isEmpty || !paired.orphans.isEmpty {
            PaneSectionHeader(title: "Conformance") {
                // The clauses are derived from the writer's intent statement,
                // and this is the door to it — the one place on the pane where
                // the declared world can be changed rather than answered.
                Button("Open Intent") { MaughamEvent.postDetailSegment(.intent) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(paired.rows) { row in
                ClauseRow(row: row,
                          canAnswer: canAnswer,
                          canPromote: canPromote,
                          answering: answering, answerFailures: answerFailures,
                          onJump: { DiagnosticsPane.jump(toParagraph: $0) },
                          onPromote: { onPromote($0) },
                          onAnswer: { onAnswer($0, $1) })
                Divider()
            }
            // A strain whose clause is not in this run's summary at all. It
            // cannot happen through the ingest — a strain and its `ClauseStatus`
            // are minted from the same entry — and it is drawn anyway, because
            // the alternative is a note the compiler raised disappearing with
            // nothing said.
            ForEach(paired.orphans) { note in
                noteRow(note)
                Divider()
            }
        }
    }

    // **The Continuity and "The reader" sections are gone** (M4 P1 Task 3),
    // and with them the reader's truncation sentence. Both kinds now mint as
    // annotations at the end of a run, so the writer answers them where every
    // other note about their prose lives — in the queue, under the round and
    // the editor that raised them, surviving the next check. A pane that still
    // drew them would be the second home this milestone exists to close.
    // `CompilerRun.truncatedReader` is still recorded; nothing reads it here,
    // because the sentence belongs beside the reports it is about.

    @ViewBuilder
    private func noteRow(_ diagnostic: Diagnostic) -> some View {
        DiagnosticRow(
            diagnostic: diagnostic,
            canAnswer: canAnswer && DiagnosticsPane.offersAnAnswer(diagnostic),
            canPromote: canPromote,
            isSubmitting: answering.contains(diagnostic.id),
            answerFailure: answerFailures[diagnostic.id],
            onJump: { DiagnosticsPane.jump(toParagraph: $0) },
            onPromote: { onPromote(diagnostic) },
            onAnswer: { onAnswer($0, diagnostic) })
    }
}

// MARK: - Sections

@MainActor
private struct PaneSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// One clause of the conformance summary: the writer's sentence, how the draft
/// sat against it, and — when it strains — what pulled.
@MainActor
private struct ClauseRow: View {
    let row: DiagnosticsPane.ConformanceRow
    let canAnswer: Bool
    /// Passed through to every strain under this clause — see
    /// `DiagnosticsPane.offersDurableActions`. Separate from `canAnswer`
    /// because the two are false for different reasons: no project to write a
    /// ruling into, versus a run still arriving.
    let canPromote: Bool
    let answering: Set<String>
    let answerFailures: [String: String]
    let onJump: (String) -> Void
    let onPromote: (Diagnostic) -> Void
    let onAnswer: (String, Diagnostic) -> Void

    /// **Open, and collapsible — not closed and expandable.** The note under a
    /// strain is the finding; a summary that hid it behind a chevron would make
    /// the writer click once per strain to learn what the run actually said,
    /// and a finding one click away is a finding half the time.
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: DiagnosticsPane.statusSymbol(row.status.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(DiagnosticsPane.statusWord(row.status.status))
                // The writer's own words, quoted — never a summary of them.
                Text("\u{201C}\(row.status.clauseQuote)\u{201D}")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !row.strains.isEmpty {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(isExpanded ? "Hide what pulls" : "Show what pulls")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, row.strains.isEmpty || !isExpanded ? 10 : 0)

            if isExpanded {
                ForEach(row.strains) { strain in
                    DiagnosticRow(
                        diagnostic: strain,
                        canAnswer: canAnswer && DiagnosticsPane.offersAnAnswer(strain),
                        canPromote: canPromote,
                        isSubmitting: answering.contains(strain.id),
                        answerFailure: answerFailures[strain.id],
                        onJump: onJump,
                        onPromote: { onPromote(strain) },
                        onAnswer: { onAnswer($0, strain) })
                }
            }
        }
    }
}

// MARK: - One note

@MainActor
private struct DiagnosticRow: View {
    let diagnostic: Diagnostic
    /// Whether this row offers the **Answer** action at all — false for a
    /// reader report, false with no project to write into, and false for every
    /// row of a preview (`DiagnosticsPane.offersDurableActions`).
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
                    Button("Promote to Task", action: onPromote)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Keep this note as a task on the document.")
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
                  let pid = DiagnosticsPane.paragraphToNavigateTo(for: diagnostic)
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

/// **One note the latest run raised** — `DiagnosticRow`'s shape over an
/// `Annotation` rather than a `Diagnostic`.
///
/// A sibling rather than a widening of that row, and the two are not the same
/// thing wearing two types: a `Diagnostic` is a conformance strain read beside
/// the clause it pulls against, whose fates are a ruling and a task; this is a
/// note about the WORDS, whose fates are the annotation layer's own accept and
/// decline. A row generic over both would be two rows sharing a body with a
/// branch on every line of it.
///
/// **No byline.** The note is signed in the queue by the pass's named editor;
/// in Author the voice is Claude's and unremarked, because wet-ink feedback is
/// not a pass (spec §7.0).
@MainActor
private struct CompilerNoteRow: View {
    let annotation: Annotation
    /// The words the jump chip shows, or `nil` for a note with nowhere to jump
    /// — `DiagnosticsPane.jumpExcerpt`.
    let excerpt: Diagnostic.Ref?
    /// Whether the two verbs are offered at all — false for every row of a
    /// preview (`DiagnosticsPane.offersDurableActions`), because a run still
    /// arriving has not raised these notes yet in the only sense that matters:
    /// `finish` is what mints them, and what is on screen mid-stream is the
    /// last finished run's.
    let canDispose: Bool
    /// What the last disposition of this note refused with, or `nil` — the
    /// pane's `answerFailures` idiom, keyed by the annotation's own id. A
    /// refusal that reached only the log would leave a row that looks pressed
    /// and a note that did not move.
    let failure: String?
    let onJump: (String) -> Void
    let onGotIt: () -> Void
    let onNotThis: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The kind's own glyph and its own word, from MaughamCore's
                // single spelling — the queue draws these notes with the same
                // two, and a second mapping here is how one surface comes to
                // call a question something the other does not.
                Image(systemName: annotation.kind.systemImageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(annotation.kind.displayName)
                Text(annotation.body)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let excerpt {
                ExcerptChip(ref: excerpt, onJump: onJump)
            }
            if canDispose {
                HStack(spacing: 6) {
                    Button("Got it", action: onGotIt)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Take the note. It settles here and in your queue.")
                    Button("Not this", action: onNotThis)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Let it go. Nothing to explain \u{2014} the written "
                              + "decline belongs to a review pass.")
                }
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let paragraphId = annotation.paragraphId else { return }
            onJump(paragraphId)
        }
    }
}

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
