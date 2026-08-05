import SwiftUI
import MaughamCore

/// The compiler's notes on the open document (M2 Task 8) — Author's own pane,
/// reached by ⌘⌥D or by leading its picker (`Persona.author.panes`).
///
/// The register is Maugham's: nothing here bounces, nags, or apologises for
/// what it found. A clean run says so plainly ("Nothing to flag."); a failed
/// one names what went wrong in one honest sentence and nothing more.
@MainActor
struct DiagnosticsPane: View {
    let orchestrator: CompilerOrchestrator
    @Bindable var diagnostics: DiagnosticsStore
    let docId: String
    /// `(paragraphId) -> the paragraph's text now` — `DiagnosticsStore.live`'s
    /// staleness check. Mirrors `CompilerEnvironment+Project`'s
    /// `liveParagraphText` closure rather than reaching for a `Document`
    /// itself, so this view has no opinion about where paragraphs live.
    let currentText: (String) -> String?
    let compilerModel: CompilerModelChoice
    var onCompilerModelChange: (CompilerModelChoice) -> Void = { _ in }
    /// The document a promoted note becomes a task on — `TasksPane.activeDoc()`'s
    /// idiom, a closure rather than a `Document` so this view still holds no
    /// editor state (tripwires 3, 6). Defaulted so the callers that only read
    /// notes keep compiling; a `nil` return means there is nothing to promote
    /// onto, and the note is left where it is rather than dismissed into
    /// nowhere.
    var activeDocument: @MainActor () -> Document? = { nil }
    /// The project the answer flow writes an intent statement into (M2 Task
    /// 10). Optional, and its absence is what takes the **Answer** action off
    /// every row rather than leaving one that presses into nowhere — see
    /// `canAnswer`.
    var store: ProjectStore? = nil

    @Environment(\.undoManager) private var undoManager

    /// Per note: an answer in flight, and the sentence the last one refused
    /// with. Both live on the pane rather than in `DiagnosticRow` because the
    /// commit is asynchronous and the row that started it is gone on success —
    /// a row owning its own in-flight flag could only clear it by outliving
    /// the thing that clears it.
    @State private var answering: Set<String> = []
    @State private var answerFailures: [String: String] = [:]

    // MARK: - Reads

    /// Observing `diagnostics.version` forces re-render on every store
    /// mutation — the `AnnotationsPane.kindStatusAnnotations` idiom.
    private var rows: [Diagnostic] {
        _ = diagnostics.version
        return diagnostics.live(docId: docId, currentText: currentText)
    }

    private var driftNote: Diagnostic? {
        rows.first { $0.anchor == nil }
    }

    private var anchoredNotes: [Diagnostic] {
        rows.filter { $0.anchor != nil }
    }

    private var lastRun: CompilerRun? {
        _ = diagnostics.version
        return diagnostics.lastRun(docId: docId)
    }

    private var state: HeaderState {
        Self.headerState(runState: orchestrator.runState, lastRun: lastRun,
                          noteCount: rows.count, docId: docId)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            diagnostics.load(docId: docId)
            diagnostics.markRead(docId: docId)
        }
        .onChange(of: docId) { _, new in
            diagnostics.load(docId: new)
            diagnostics.markRead(docId: new)
        }
        // Notes landing while this pane is already on screen were never
        // unread: the picker's badge is for a run that finished somewhere the
        // writer wasn't looking. `markRead` does not bump `version`, so this
        // cannot re-enter itself.
        .onChange(of: diagnostics.version) { _, _ in
            diagnostics.markRead(docId: docId)
        }
    }

    // MARK: - Header state — pure, so every state is a test without a mount

    enum HeaderState: Equatable {
        case neverRun
        case idle(lastRun: CompilerRun)
        case running
        case nothingNew(at: Date)
        case failed(CompilerRunFailure, at: Date)
        case clean(lastRun: CompilerRun)
    }

    /// Derives the header's state from the orchestrator's run state, the
    /// last-run record, and how many notes are currently live.
    ///
    /// `runState` wins whenever it describes something that just happened **to
    /// this document** — the `where` clause is on all three run-describing
    /// cases and not only on `.running`, because the run state is per-window
    /// while this pane is per-document. Anything about another document falls
    /// through to what is on disk here, which is also what makes a reopened
    /// project show its last answer rather than reverting to "never run".
    static func headerState(
        runState: CompilerOrchestrator.RunState,
        lastRun: CompilerRun?,
        noteCount: Int,
        docId: String
    ) -> HeaderState {
        switch runState {
        case .running(let runDocId) where runDocId == docId:
            return .running
        case .nothingNew(let runDocId, let at) where runDocId == docId:
            return .nothingNew(at: at)
        case .failed(let runDocId, let failure, let at) where runDocId == docId:
            return .failed(failure, at: at)
        default:
            guard let lastRun else { return .neverRun }
            return noteCount == 0 ? .clean(lastRun: lastRun) : .idle(lastRun: lastRun)
        }
    }

    /// One honest sentence per failure — no apology, no chirp. `cliNotFound`
    /// and `disabledByToggle` each name the surface that fixes them;
    /// `sessionDied` only ever reaches here for a death that was NOT the
    /// writer's own doing (`CompilerOrchestrator.finish` already routes the
    /// other three details to `.idle`), so its detail is worth showing rather
    /// than translating away.
    static func failureCopy(_ failure: CompilerRunFailure) -> String {
        switch failure {
        case .cliNotFound:
            return "Claude Code isn't installed. Set it up, then check "
                + "Settings \u{2192} General \u{2192} Claude integration."
        case .disabledByToggle:
            return "Claude access is off in Settings \u{2014} turn on "
                + "\u{201C}Allow Claude to connect (MCP)\u{201D} to check your writing."
        case .timedOut:
            return "The check took too long and was stopped."
        case .sessionDied(let detail):
            return "The compiler's session ended before it could answer: \(detail)."
        case .unusableOutput:
            return "Claude's answer couldn't be read as notes."
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        // No spinner: the register is understated, and the state word in
        // `headerLine` ("Checking…") already says what's happening — an
        // indeterminate control here would only animate to say it twice.
        HStack(spacing: 8) {
            Text(headerLine)
                .font(.caption)
                .foregroundStyle(isFailureState ? Color.red : .secondary)
                // Wraps rather than truncating: `cliNotFound`'s sentence names
                // the Settings path that fixes it, and a writer who cannot
                // read the end of it has been told nothing.
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if case .running = state {
                Button("Cancel") { orchestrator.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            gearMenu
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private var isFailureState: Bool {
        if case .failed = state { return true }
        return false
    }

    private var headerLine: String { Self.headerCopy(for: state) }

    /// The header's one line, per state. Static and exhaustive for
    /// `emptyState`'s reason: every sentence the pane can say is then assertable
    /// without mounting anything.
    static func headerCopy(for state: HeaderState) -> String {
        switch state {
        case .neverRun:
            return "Not checked yet \u{2014} press \u{2318}R to check your writing."
        case .idle(let run):
            return "Last checked \(relative(run.at)) \u{00b7} \(run.deltaSummary)"
        case .running:
            return "Checking\u{2026}"
        case .nothingNew:
            return "Nothing new since the last check."
        case .failed(let failure, _):
            return failureCopy(failure)
        case .clean(let run):
            let line = "Nothing to flag. Last checked \(relative(run.at))."
            // Appended rather than interleaved: the standing sentence is the
            // one the writer reads at a glance, and this is the footnote to it.
            guard let discarded = discardedNotesSentence(run.droppedDangling) else {
                return line
            }
            return "\(line) (\(discarded))"
        }
    }

    /// **What a run lost, said plainly and without alarm** — or `nil` when it
    /// lost nothing, which is what keeps the clean bill clean.
    ///
    /// One spelling, read by the header and by the empty state, because two
    /// copies of a sentence about the same number are two things that can
    /// disagree. It names what happened (the paragraphs moved) rather than what
    /// Maugham could not do about it: "unknown paragraphs" is the parser's
    /// vocabulary, and to the writer it reads as an error they caused.
    static func discardedNotesSentence(_ count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "1 note arrived against a paragraph that has changed "
            + "and was discarded"
        default: return "\(count) notes arrived against paragraphs that have "
            + "changed and were discarded"
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private var gearMenu: some View {
        Menu {
            ForEach(CompilerModelChoice.allCases, id: \.self) { choice in
                Button {
                    onCompilerModelChange(choice)
                } label: {
                    if choice == compilerModel {
                        Label(choice.displayName, systemImage: "checkmark")
                    } else {
                        Text(choice.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model: \(compilerModel.displayName)")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            let empty = Self.emptyState(for: state)
            ContentUnavailableView(
                empty.title,
                systemImage: empty.symbol,
                description: Text(empty.description))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let driftNote {
                        DiagnosticRow(
                            diagnostic: driftNote, isDrift: true,
                            // **Never for drift, and that is the rule rather
                            // than a defaulted `false`.** Drift is not about a
                            // paragraph — its action is Open Intent, where the
                            // writer edits the statement whole. A reply field
                            // here would be a second door into the same room,
                            // and the narrower one.
                            canAnswer: false,
                            isSubmitting: false, answerFailure: nil,
                            onJump: {},
                            onOpenIntent: { MaughamEvent.postDetailSegment(.intent) },
                            onPromote: { promote(driftNote) },
                            onAnswer: { _ in })
                        Divider()
                    }
                    ForEach(anchoredNotes) { diagnostic in
                        DiagnosticRow(
                            diagnostic: diagnostic, isDrift: false,
                            canAnswer: store != nil,
                            isSubmitting: answering.contains(diagnostic.id),
                            answerFailure: answerFailures[diagnostic.id],
                            onJump: { jump(diagnostic) },
                            onOpenIntent: { MaughamEvent.postDetailSegment(.intent) },
                            onPromote: { promote(diagnostic) },
                            onAnswer: { answer($0, to: diagnostic) })
                        Divider()
                    }
                }
            }
        }
    }

    /// What an empty pane says, per state. Pure and exhaustive so each answer
    /// is assertable without a mount, and so no state can fall through to
    /// another's copy.
    ///
    /// **A failed check gets neither the seal nor "Nothing to flag."** Those
    /// two say the compiler looked and found nothing; a run that died never
    /// looked, and the header is already carrying the honest sentence about
    /// why. Repeating it here would be the pane saying the same thing twice
    /// under a checkmark that contradicts it.
    ///
    /// **Nor does a run that lost every note it raised.** That is the adjacent
    /// case rather than the same one: it looked, it spoke, and Maugham could
    /// not place what it said. The seal is for a run that came back with
    /// nothing to say — 0 raised and 0 discarded — so a discard takes the
    /// checkmark off without borrowing the failure's warning triangle.
    static func emptyState(
        for state: HeaderState
    ) -> (title: String, symbol: String, description: String) {
        switch state {
        case .neverRun:
            return ("Not checked yet", "checkmark.seal",
                    "Press \u{2318}R to ask Claude for notes on what you've written.")
        case .running:
            return ("Checking\u{2026}", "hourglass",
                    "Claude is reading what you've written since the last check.")
        case .failed:
            return ("No notes", "exclamationmark.triangle",
                    "The last check didn't finish, so there are none from it.")
        case .clean(let run) where discardedNotesSentence(run.droppedDangling) != nil:
            return ("Nothing to flag.", "circle.dashed",
                    (discardedNotesSentence(run.droppedDangling) ?? "") + ".")
        case .idle, .nothingNew, .clean:
            // `.idle` is unreachable here — `headerState` returns `.clean` for
            // a last run with no live notes — but it is named rather than
            // defaulted so a new state cannot inherit this copy by omission.
            return ("Nothing to flag.", "checkmark.seal",
                    "The compiler found nothing to raise against the last check.")
        }
    }

    /// The paragraph a click on `diagnostic` should jump to, or `nil` for a
    /// drift note (nothing anchored to jump to). Split out as a pure static
    /// so the mapping is a direct unit test without mounting a view or
    /// simulating a tap gesture, which SwiftUI does not expose the way it
    /// does a `Button`'s press.
    static func paragraphToNavigateTo(for diagnostic: Diagnostic) -> String? {
        diagnostic.anchor?.paragraphId
    }

    /// Turn a note into a durable task and take it off the pane.
    ///
    /// The two halves are deliberately asymmetric about undo. The task is one
    /// undo step — `createPaneTask` registers its own inverse, so ⌘Z takes it
    /// back. The dismissal is not undoable, and that is intended rather than
    /// missing: the diagnostics sidecar is per-device derived state with no
    /// undo of its own, and a note that still stands is raised again by the
    /// next run. A ⌘Z that resurrected it would be claiming the compiler had
    /// re-checked something it has not looked at since.
    private func promote(_ diagnostic: Diagnostic) {
        guard let document = activeDocument() else { return }
        document.createPaneTask(
            body: DiagnosticPromotion.taskBody(for: diagnostic, run: lastRun),
            parentTaskId: nil,
            paragraphId: diagnostic.anchor?.paragraphId,
            undoManager: undoManager)
        diagnostics.dismiss(diagnostic.id, docId: docId)
    }

    // MARK: - The answer (M2 Task 10)

    /// **Write the writer's answer into the piece's intent, and take the note
    /// off the pane once it is there** — the loop this milestone exists for.
    ///
    /// A `static` taking everything it touches, so the whole of it is a direct
    /// test against a real `ProjectStore` and a real `DiagnosticsStore`. SwiftUI
    /// exposes no way to deliver a Return keystroke into a hosted `TextField`'s
    /// editor, so a commit written inline in the field's `.onSubmit` would be
    /// the one part of this path nothing could drive.
    ///
    /// **The dismissal is conditional on the write, and the order is the
    /// contract.** A note dismissed before the append could lose both the note
    /// and the answer to one refusal; dismissed after, the worst case is a note
    /// the writer answers twice. Returns the refusal's own sentence, or `nil`.
    ///
    /// Asymmetric about undo for `promote`'s reason: the answer is an op in the
    /// statement's log and ⌘Z reaches it there, while the dismissal is
    /// per-device derived state with no undo of its own — a ⌘Z that resurrected
    /// the note would claim the compiler had re-checked something it has not
    /// looked at since.
    static func commitAnswer(
        _ text: String, to diagnostic: Diagnostic, docId: String,
        store: ProjectStore, diagnostics: DiagnosticsStore
    ) async -> String? {
        do {
            try await IntentAppendPerformer.append(
                answer: text, forDocId: docId, store: store)
        } catch {
            return error.localizedDescription
        }
        diagnostics.dismiss(diagnostic.id, docId: docId)
        return nil
    }

    private func answer(_ text: String, to diagnostic: Diagnostic) {
        // Unreachable from the UI — `canAnswer` is `store != nil`, so no row
        // without one offers the action — and it refuses rather than asserting,
        // because a caller that got here has a writer's sentence in hand and
        // nothing to gain from a crash.
        guard let store else { return }
        answerFailures[diagnostic.id] = nil
        answering.insert(diagnostic.id)
        Task {
            let failure = await Self.commitAnswer(
                text, to: diagnostic, docId: docId, store: store,
                diagnostics: diagnostics)
            answering.remove(diagnostic.id)
            // Only on failure: on success the row is gone with the note, and
            // an entry for a note nobody can see would surface on the next run
            // that happened to mint the same id.
            answerFailures[diagnostic.id] = failure
        }
    }

    private func jump(_ diagnostic: Diagnostic) {
        // Reuses `AnnotationsPane.jump`'s event rather than a copy — span
        // precision is that pane's alone; a diagnostic anchors a whole
        // paragraph.
        guard let pid = Self.paragraphToNavigateTo(for: diagnostic) else { return }
        MaughamEvent.post(
            .maughamNavigateToParagraph, to: .keyWindow,
            payload: ["paragraph_id": pid])
    }
}

@MainActor
private struct DiagnosticRow: View {
    let diagnostic: Diagnostic
    let isDrift: Bool
    /// Whether this row offers the **Answer** action at all. False for drift,
    /// and false with no project to write into.
    let canAnswer: Bool
    /// An answer of this row's already on its way to the intent statement.
    let isSubmitting: Bool
    /// What the last answer refused with, or `nil`. Its arrival is what tells
    /// the row the round trip is over and the field is the writer's again.
    let answerFailure: String?
    let onJump: () -> Void
    let onOpenIntent: () -> Void
    let onPromote: () -> Void
    let onAnswer: (String) -> Void

    /// The field is REVEALED rather than standing: a text box under every note
    /// is a form, and the pane's register is a margin note.
    @State private var isAnswering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text((diagnostic.category ?? (isDrift ? "Drift" : "Note")).uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(diagnostic.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let anchor = diagnostic.anchor {
                Text(Self.excerpt(anchor.anchorText))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            // Promote is on every row, drift included — a drift note is the one
            // most worth keeping, and it lands as a document-scoped task
            // because there is no ¶ under it to carry.
            HStack(spacing: 6) {
                if isDrift {
                    Button("Open Intent", action: onOpenIntent)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if canAnswer && !isAnswering {
                    Button("Answer", action: reveal)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Say why this is deliberate. It goes into your intent, "
                              + "and the next check reads it.")
                }
                Button("Promote to Task", action: onPromote)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Keep this note as a task on the document.")
            }
            if isAnswering { replyField }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        // The tap-to-jump must not fire from inside the field the writer is
        // typing in — `onTapGesture` on the row would otherwise scroll the
        // editor out from under them mid-sentence.
        .onTapGesture { if !isAnswering { onJump() } }
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

    /// A short, single-line excerpt of the anchored paragraph — not the whole
    /// thing, which can run to a page.
    static func excerpt(_ text: String, limit: Int = 90) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "\u{2026}"
    }
}
