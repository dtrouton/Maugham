import SwiftUI
import MaughamCore

// MARK: - The header view

/// **The pane's header** — the run's one line (a clock while a run is live),
/// Cancel, Reread, the other loop's line, the reader picker and the Ask field.
/// Values in and closures out: it owns no state, and every sentence it draws
/// is one of `DiagnosticsPane`'s pure statics.
@MainActor
struct DiagnosticsPaneHeader: View {
    /// `DiagnosticsPane.state` — the pane's one reading of the run.
    let state: DiagnosticsPane.HeaderState
    let wetInk: DiagnosticsPane.WetInk
    /// `DiagnosticsPane.visibleQueue`: `nil` when the pane cannot see a queue.
    let visibleQueue: [Annotation]?
    let reviewPasses: [ReviewPass]
    /// `DiagnosticsPane.otherLoopLine`, read once by the pane.
    let otherLoopLine: String?
    let orchestrator: CompilerOrchestrator
    let diagnostics: DiagnosticsStore
    let docId: String
    let reader: AuthorReader
    let store: ProjectStore?
    let compilerModel: CompilerModelChoice
    let onCompilerModelChange: (CompilerModelChoice) -> Void
    let onChooseReader: (AuthorReaderChoice) -> Void
    let onOpenProjectSettings: () -> Void

    var body: some View { header }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            // No spinner: the register is understated, and the state word in
            // `headerLine` ("Checking 14 new paragraphs…") already says what's
            // happening — an indeterminate control here would only animate to say
            // it twice.
            HStack(spacing: 8) {
                // **This wraps, and it must NOT be made to wrap with
                // `fixedSize(horizontal: false, vertical: true)`.** A `Text`
                // already reports its WRAPPED height as its ideal for whatever
                // width it is proposed, so it wraps here without the modifier;
                // what the modifier adds is an *unbreakable minimum* height, and
                // AppKit resolves that minimum at a probe width far narrower than
                // the column — `cliNotFound`'s sentence came back ~400pt tall.
                // `NSSplitView` takes the tallest column, so a pane that cannot be
                // broken grows all three columns past the window: the tree is laid
                // out taller than the window and shows a band the writer cannot
                // scroll back up from, and the centre column's content is pushed
                // above the visible region. There is no max-height constraint for
                // AppKit to break here, which is why this fails differently from
                // the WIDTH conflict `DetailColumnWidthTests` documents.
                // Measured 2026-08-08 (macOS 26.5); see
                // `DiagnosticsPaneColumnHeightTests`.
                //
                // **While a run is live the line is a clock** (spec
                // 2026-09-09 §5), so it is redrawn once a second and only
                // then. Tripwire 30 is about scene-proportional work keyed on
                // a redraw counter; this is one `Text` at 1 Hz, and it stops
                // the moment the state leaves `.running`.
                if case .running = state {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        // No queue read at 1 Hz: `.running` never reaches
                        // the `.clean` arm the queue feeds.
                        Text(DiagnosticsPane.headerCopy(
                            for: state, wetInk: wetInk, now: context.date,
                            annotations: [], passes: []))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(headerLine)
                        .font(.caption)
                        .foregroundStyle(isFailureState ? Color.red : .secondary)
                        .help(timingHelp)
                }
                Spacer()
                // The pane's own check, or Review's round (#77 F7 review
                // ruling) — one session, one `cancel()`.
                if DiagnosticsPane.offersCancel(state: state, otherLoopLine: otherLoopLine) {
                    Button("Cancel") { orchestrator.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                // **Reread — Author's ⌘⇧R, given a control** (two loops P1
                // Task 7). Same reader, the whole piece, read cold: a check
                // with `freshEyes: true`, never a round, because this pane is
                // the check loop's own surface.
                //
                // **No `keyboardShortcut` here**, on the cockpit's rule: ⌘⇧R
                // is bound once, in `MaughamApp`, and this is a second
                // DELIVERY site for that command rather than a second binding
                // of the key. Two bindings of one keystroke in one window is a
                // race over which view claims it.
                //
                // Refuses while a run is in flight and in no other state —
                // `.failed`'s remedy is another read, and a control that
                // reports a failure then withholds the button answering it is
                // RULING-35's dead control with a red line over it.
                Button(DiagnosticsPane.rereadTitle) {
                    orchestrator.runRequested(docId: docId, kind: .check, freshEyes: true)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    // A round on this piece holds the window's one session
                    // too (#77 F7): Reread stays refused exactly as it was
                    // while the header read `.running` over that round, and
                    // now says whose run it is waiting for.
                    .disabled(isRunningState || otherLoopLine != nil)
                    .help(otherLoopLine ?? DiagnosticsPane.rereadHelp)
                gearMenu
            }
            // **The picker P1 promised, and it travels nowhere** (two loops
            // P2 Task 6). This line used to be a button that switched the
            // window to Review — the mode error P1 removed, because who reads
            // a CHECK is not chosen on the review board. What replaces the
            // label is a menu over the READERS themselves: every item writes
            // the choice and stays on this pane.
            // **The other loop's run, in one line** (#77 F7): under the
            // header's own state, never in place of it.
            if let otherLoopLine {
                Text(otherLoopLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            readerMenu
            // **Under the reader line, because it is addressed TO them**
            // (spec §3.7). The header already says who reads this piece; the
            // ask is what the writer wants them to look at, and it belongs in
            // the same breath rather than buried in the report below.
            askField
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    /// **Ask about…, in Author's header** — the same field SHAPE Review's
    /// cockpit draws (`AskField`), but each home reads and writes its own
    /// tempo's sentence (two loops P1 Task 6): this one is `.check`, the
    /// cockpit's is `.round`, independent asks over the same document. This
    /// pane holds the store, so the commit is direct; the cockpit's arrives
    /// as a closure.
    @ViewBuilder
    private var askField: some View {
        AskField(input: AskField.Input(
            docId: docId,
            kind: .check,
            text: storedAsk,
            commit: { AskField.commit($0, docId: docId, kind: .check, diagnostics: diagnostics) },
            note: { text, doc in
                AskField.note(text, docId: doc, kind: .check, diagnostics: diagnostics)
            }))
    }

    /// Version-gated like every other read of the sidecar here.
    ///
    /// **Reads the CHECK's ask, never the round's** (two loops P1 Task 6) —
    /// this header is Author's, and a worry typed for the reader who checks
    /// must not echo back a different sentence typed for the editor who runs
    /// the round in Review's cockpit.
    private var storedAsk: String? {
        _ = diagnostics.version
        return diagnostics.ask(docId: docId, kind: .check)
    }

    private var isFailureState: Bool {
        if case .failed = state { return true }
        return false
    }

    /// The one state Reread refuses in — the same predicate Cancel's presence
    /// turns on, read off `state` rather than the orchestrator so both
    /// controls in this row answer to one description of the run.
    private var isRunningState: Bool {
        if case .running = state { return true }
        return false
    }

    private var headerLine: String {
        DiagnosticsPane.headerCopy(for: state, wetInk: wetInk,
                        annotations: visibleQueue, passes: reviewPasses)
    }

    /// **What the run cost, behind the line rather than on it** (spec
    /// 2026-09-09 §5). Only a finished run has any of it, and `.help("")`
    /// draws no tooltip at all — so the two states that can carry a
    /// record answer, and every other state silently declines.
    private var timingHelp: String {
        if case .idle(let run) = state, let timing = run.timing {
            return RoundNarrative.timingDetail(timing)
        }
        if case .clean(let run) = state, let timing = run.timing {
            return RoundNarrative.timingDetail(timing)
        }
        return ""
    }

    private var readerLine: String { DiagnosticsPane.readerCopy(for: reader) }

    /// **The picker, labelled by the line it replaces** (two loops P2 Task 6).
    ///
    /// The label is `readerLine` unchanged, so a writer who never opens the
    /// menu reads exactly the sentence P1's label said. Items are the readers
    /// this project actually has (`readerMenuItems`), radio-style on whoever
    /// currently RESOLVES rather than on the stored choice — a choice whose
    /// subject has gone falls back to the default rule, and a checkmark beside
    /// a reader who is not reading would be the picker disagreeing with the
    /// line above it.
    ///
    /// **Nothing here travels.** Every item writes `authorReaderChoice` and
    /// leaves the writer on this pane; the one item that opens anything opens
    /// Project Settings, which is where her name is typed — not Review, whose
    /// board is the round loop's furniture.
    ///
    /// **No `fixedSize`, on the header sentence's own rule** — see the note on
    /// `headerLine` above: an unbreakable minimum here is what grew all three
    /// columns past the window (`DiagnosticsPaneColumnHeightTests`).
    ///
    /// A pane with no project draws the plain label it always did: there is
    /// nothing to choose between when there is no manifest to read the coach's
    /// seat or the first reader's name off.
    @ViewBuilder
    private var readerMenu: some View {
        if let manifest = store?.manifest {
            Menu {
                ForEach(DiagnosticsPane.readerMenuItems(manifest: manifest), id: \.self) { candidate in
                    Button {
                        onChooseReader(candidate)
                    } label: {
                        if candidate == DiagnosticsPane.resolvedChoice(for: reader) {
                            Label(DiagnosticsPane.readerMenuTitle(candidate, manifest: manifest),
                                  systemImage: "checkmark")
                        } else {
                            Text(DiagnosticsPane.readerMenuTitle(candidate, manifest: manifest))
                        }
                    }
                }
                if !DiagnosticsPane.hasFirstReader(manifest) {
                    Divider()
                    Button(DiagnosticsPane.defineFirstReaderTitle) { onOpenProjectSettings() }
                }
            } label: {
                Text(readerLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .help("Choose who reads this project\u{2019}s checks")
        } else {
            Text(readerLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// **Moved to `CompilerModelMenu`** (editorial letter P1, Task 8) so
    /// Review's round cockpit can mount the identical control — one view
    /// type, one `ForEach(CompilerModelChoice.allCases` site.
    private var gearMenu: some View {
        CompilerModelMenu(choice: compilerModel, onChange: onCompilerModelChange)
    }
}

// MARK: - The header's words and the reader menu's items

extension DiagnosticsPane {
    /// Reread's word and its promise. `static let` for `headerCopy`'s reason:
    /// every sentence this pane says is assertable without mounting anything,
    /// and the help text names the keystroke because the button IS the
    /// keystroke's second delivery site.
    static let rereadTitle = "Reread"
    static let rereadHelp = "Read the whole piece cold (\u{2318}\u{21e7}R)"

    /// **"Le Guin reads this piece", "Claude reads this piece"** — who reads
    /// this piece's CHECKS, in the header's own shape. The round cockpit drew
    /// a sentence like it until two loops P1 Task 8; it does not any more,
    /// because the seat has nothing to do with a round.
    ///
    /// **One shape, because `AuthorReader` has one held arm** (two loops P1
    /// Task 2). The "editor · pass" spelling this used to carry for a stage is
    /// gone with the stage arm: the coach and the vacant seat both read as an
    /// introduction, because neither is ever a lane a control can select
    /// (`ReviewPass.laneDisplayName`'s reasoning — her pass name, "Workshop",
    /// is never drawn), and a stage's lane is named in Review, where the round
    /// it belongs to is run.
    ///
    /// Static and pure for `emptyState`'s reason: every sentence this pane can
    /// say is assertable without mounting anything, and a test constructing
    /// one `AuthorReader` gets the header's answer and the empty state's from
    /// the same value rather than two independently-spelled copies.
    static func readerCopy(for reader: AuthorReader) -> String {
        "\(reader.editorName) reads this piece"
    }

    /// **The one item that opens something**, and it opens the place the name
    /// is typed. `static let` for `headerCopy`'s reason.
    static let defineFirstReaderTitle = "Define a first reader\u{2026}"

    /// **Which readers this project has to offer** — pure, so the four cells
    /// are assertable with nothing mounted (tripwire 33).
    ///
    /// A reader is offered only while their premise stands, which is the same
    /// rule `ProjectManifest.authorReader(choice:statementText:)` resolves by:
    /// the coach while her seat is held, the first reader while a name is set.
    /// Offering one whose premise has gone would be a menu item that selects
    /// somebody and then silently resolves to somebody else.
    ///
    /// `.nobody` is always last and always offered: it is the one choice with
    /// no premise to lose, and "read by nobody in particular" must stay
    /// reachable however the project is configured.
    static func readerMenuItems(manifest: ProjectManifest) -> [AuthorReaderChoice] {
        var items: [AuthorReaderChoice] = []
        if manifest.effectiveCoach != nil { items.append(.coach) }
        if hasFirstReader(manifest) { items.append(.firstReader) }
        items.append(.nobody)
        return items
    }

    /// What an item is CALLED. Names come from the same places the resolution
    /// reads them, so the menu cannot name a reader the header does not.
    static func readerMenuTitle(
        _ choice: AuthorReaderChoice, manifest: ProjectManifest
    ) -> String {
        switch choice {
        case .coach:
            return (manifest.effectiveCoach ?? ReviewPass.coachPreset).effectiveEditorName
        case .firstReader:
            return firstReaderName(manifest) ?? ""
        case .nobody:
            return AuthorReader.nobody.editorName
        }
    }

    /// Which item wears the checkmark: the arm the reader RESOLVED to, so the
    /// mark and the line above it are one answer.
    static func resolvedChoice(for reader: AuthorReader) -> AuthorReaderChoice {
        switch reader {
        case .coach: return .coach
        case .firstReader: return .firstReader
        case .nobody: return .nobody
        }
    }

    /// Trimmed for `ProjectManifest.authorReader`'s reason: a hand-edited
    /// `project.json` is a writer of this field too, and a name that is one
    /// space is not a reader anybody can pick.
    fileprivate static func firstReaderName(_ manifest: ProjectManifest) -> String? {
        let name = (manifest.firstReaderName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    fileprivate static func hasFirstReader(_ manifest: ProjectManifest) -> Bool {
        firstReaderName(manifest) != nil
    }
}
