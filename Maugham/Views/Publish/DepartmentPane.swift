import SwiftUI
import MaughamCore

/// **The department desk** (publish-department P4 Task 1) — Publish's own
/// working pane, and `ReviewBoardPane`'s sibling one persona over.
///
/// Review got a board saying where every piece stands on every pass; Publish
/// gets a desk saying where the book's DESIGN stands and where each language
/// EDITION stands. Two sections, filled in over the milestone: the language rows
/// and their edition briefs (Task 2), a translation run (Task 3), and the
/// designer's own row with a direction and a run (Task 4).
///
/// **It takes values, never a store** (tripwire 4, and the sibling's rule for
/// the sibling's reason). Every input below is a plain value assembled by
/// `DepartmentPaneHost`, so a desk of twenty languages costs twenty rows of
/// layout and no I/O, and the whole surface is mountable in a test with no
/// project on disk — which is what `DepartmentPaneTests` does. The derivations
/// those values come from are expensive on purpose: the language union walks
/// every manuscript document's translation store, and the design row's
/// proposals read `.maugham/design/proposals/`. Neither may ever happen on this
/// body path.
///
/// **The desk has no empty state, and that is Task 4's doing.** Task 1 drew a
/// `ContentUnavailableView` over a project with neither translations nor
/// proposals — honest while nothing on the pane could act. It stopped being
/// honest the moment the Design row grew a Run: every project has a designer
/// from the moment it exists (`ProductionRole.presetDesigner`), so asking for
/// the book's first design round is exactly what a writer with an empty
/// department came here to do, and an "unavailable" view would have hidden the
/// one verb that is always available.
struct DepartmentPane: View {
    /// The project's title, as the sibling board takes it — the desk is a
    /// project-level surface and names the book it is the department for.
    let title: String
    /// One row per language this book has an edition in — the union
    /// `translation_status` reports, with that tool's own figures, derived by
    /// `EditionStatus` off the body path. The pane derives no second version of
    /// anything here: a desk and a tool disagreeing about how far along an
    /// edition is gives the writer no way to find out which is wrong.
    let languages: [EditionStatus.LanguageRow]
    /// **The Design row, whole** (Task 4) — who designs this book, what the
    /// newest round produced, what a round in flight is doing, and whether
    /// either verb may be pressed.
    ///
    /// A resolved value rather than the proposals themselves: reading
    /// `DesignProposalStore.list()` is disk work the host owns, and *deciding*
    /// what the row says about it is `DepartmentDesignRow`'s, so the truth table
    /// is assertable with nothing mounted. This replaces Task 1's placeholder
    /// count, which was what a skeleton with no verbs could honestly draw.
    var design: DepartmentDesignRow = DepartmentDesignRow()
    /// Open the edition brief for a language — the row's own door.
    ///
    /// A closure, because the door WRITES: it creates the statement the writer
    /// is about to type in, and then presents an editor. Both belong to the
    /// host (`DepartmentPaneHost`), which is what keeps this pane's census
    /// (`test_theSourceReadsNoStoreAtAll`) true while the row grows a verb.
    var openEditionBrief: (String) -> Void = { _ in }
    /// Something the desk needs to say that is not a row — a door that would
    /// not open, so far. Nil in the ordinary case.
    ///
    /// **A refusal the writer cannot see is the failure mode this exists for.**
    /// Creating an edition brief can fail (a full disk, a project folder gone),
    /// and the honest answer is neither a silent no-op nor an editor over a
    /// statement that does not exist.
    ///
    /// **This is the desk's ONE transient-message channel** (Task 3). A run the
    /// desk refused before it reached the orchestrator — a second click while a
    /// session is warm, a language tag no edition can be written for — lands
    /// here too, naming its edition, rather than growing a second line per row:
    /// two message slots on one pane is two places a writer has to learn to
    /// look for one answer. What does NOT come here is a row's run STATE, which
    /// is not a message but a standing fact about that edition and belongs on
    /// the row that is about it. `DepartmentRunTests
    /// .test_theDeskCarriesOneMessageChannelAndNotTwo` is the census.
    var notice: String? = nil
    /// **Which document a Run would run** — Global Constraint 1, resolved by the
    /// host from the window's own subject.
    ///
    /// The desk is project-scope and a round is a document's, so this is the one
    /// input on the pane that is not about the book: it is about what the tree is
    /// naming right now. `.unavailable` carries the sentence, and the pane draws
    /// it above the rows rather than hiding it in a tooltip — a disabled control
    /// whose explanation lives in a hover is an explanation most writers never
    /// read.
    var runTarget: DepartmentRunTarget = .unavailable(DepartmentRunTarget.openAChapter)
    /// One row's run half, by language. Absent means idle and pressable — the
    /// default a row gets before anything has been run, so a desk mounted with
    /// no runs at all still offers every verb.
    var runs: [String: DepartmentRunState] = [:]
    /// Ask for a round of this language. A closure, because starting one reaches
    /// the window's `TranslatorOrchestrator` and refuses in the host.
    var runTranslation: (String) -> Void = { _ in }
    /// End the round in flight — `TranslatorOrchestrator.cancel()`. Only reachable
    /// from the row that is running, which is the only row with anything to end.
    var cancelRun: () -> Void = { }
    /// **Ask for a design round**, with the writer's words for it or `nil` for a
    /// bare one briefed on the visual language statement alone.
    ///
    /// Answers whether the round actually went, which is what lets the row clear
    /// the direction field: words used are words spent, and words *refused* must
    /// stay in the box for the writer to press again with. The refusal itself
    /// travels through `notice` — see below.
    var runDesign: (String?) -> Bool = { _ in false }
    /// **Send the writer's words back into the session that made the standing
    /// proposal** — `DesignerOrchestrator.requestChanges`, whose own `Bool` is
    /// what this returns.
    var requestDesignChanges: (String) -> Bool = { _ in false }
    /// End the design round in flight — `DesignerOrchestrator.cancel()`.
    var cancelDesignRun: () -> Void = { }
    /// **The mint sheet's prompt, or nil** (P4 Task 9) — set by the host when a
    /// Run would mint an unlisted language's translator with no name
    /// (`DepartmentPaneHost.needsTranslatorName`), so the writer names them
    /// before the round the sheet is standing in front of ever reaches
    /// `TranslatorOrchestrator`.
    var mintPrompt: DepartmentMintPrompt? = nil
    /// Answer the sheet with a name — mints (or finds) the role and renames it
    /// in one visible act, then starts the run the sheet was standing in front
    /// of. The host's, because both halves write.
    var confirmMint: (String) -> Void = { _ in }
    /// Back out of the sheet. The run it was standing in front of does not
    /// happen; the abandon lands in `notice` (Global Constraint 2), which is
    /// why this takes no reason of its own.
    var cancelMint: () -> Void = { }
    /// **Put the newest round in the centre column** (Task 5) — the desk's door
    /// to the gate, and the row's only control that is navigation rather than a
    /// verb.
    ///
    /// **It takes no argument on purpose.** Which proposal Show is about is a
    /// question about `.maugham/design/proposals/`, and this pane may not reach
    /// the disk to answer it (tripwire 4, and `DepartmentPaneTests
    /// .test_theSourceReadsNoStoreAtAll`). The host already holds the listing it
    /// resolved the Design row from and supplies the newest from it — so the
    /// proposal the gate opens and the one `latestLine` describes are the same
    /// object, not two lookups that could differ.
    var showProposal: () -> Void = { }

    /// **The writer's words for the next round**, and the pane's only mutable
    /// state.
    ///
    /// It lives here rather than on the host because it is the field's own text
    /// and nothing else reads it: a `Binding` down from the host would put a
    /// keystroke-rate write on the surface that derives the language union
    /// (tripwire 3's shape). Both verbs take it — Run as the round's direction,
    /// Request Changes as the change request — because on this row they are the
    /// same sentence answered by two different sessions.
    @State private var direction = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            desk
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // **The mint sheet** (P4 Task 9). The `Binding`'s `set` is the only
        // way this value-taking pane can hear a swipe-away or Esc dismiss —
        // there is no `@State` here for `mintPrompt` to live in, so a
        // dismissal that bypassed both buttons still has to reach
        // `cancelMint`, or the host's `mintPrompt` would outlive the sheet
        // that showed it and the next render would draw it right back.
        .sheet(item: Binding(get: { mintPrompt },
                              set: { if $0 == nil { cancelMint() } })) { prompt in
            DepartmentMintSheet(language: prompt.language,
                                onName: confirmMint, onCancel: cancelMint)
        }
    }

    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
        }
        .padding(8)
    }

    /// The two sections. A `ScrollView` because a book with a dozen editions is
    /// taller than the column, and a right-column pane may never grow the split
    /// view past the window it is a column of
    /// (`DetailPaneColumnHeightCensusTests`).
    private var desk: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section(DepartmentDesk.designHeading) {
                    designRow
                }
                section(DepartmentDesk.languagesHeading) {
                    if languages.isEmpty {
                        Text(DepartmentDesk.noLanguagesYet)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        // **Said once, above the rows it applies to.** Every Run
                        // on the desk refuses for the same reason when the window
                        // is not on a chapter, so a copy of it per row would be
                        // the same sentence four times; and Global Constraint 1
                        // asks for the reason to be VISIBLE, which a tooltip on a
                        // disabled button is not.
                        if let reason = runTarget.reason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(languages) { row in
                            languageRow(row)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// **The book's design: who makes it, where the last round stands, and the
    /// two verbs** (spec §5's Design row, Task 4).
    ///
    /// One row for the whole book rather than one per edition. The milestone's
    /// ruling is that `runDesign` is called with `language: nil` — there is no
    /// picker here and no per-edition round — so what this row is about is the
    /// book's design, and a round started for an edition from somewhere else
    /// still says which edition it is for (`DepartmentDesignRow.designingLine`).
    private var designRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(design.designerName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // A proposal waiting on the writer is the one thing on this row
                // that is asking them for something, so it is a badge rather
                // than another grey line. At most one can be pending —
                // `DesignProposalStore.stage` supersedes the rest — so it never
                // has to carry a number.
                if let badge = design.pendingBadge {
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                Spacer(minLength: 6)
                // **A door, drawn where the language rows draw theirs** — the
                // name line, right-aligned — and deliberately not down among
                // the two session verbs: those refuse while a round is warm and
                // this one never does, because reading a staged proposal
                // contends with nothing. Absent rather than disabled when there
                // is no round, on the `offersRequestChanges` argument: a control
                // that can only refuse teaches the writer nothing, and the verb
                // that WOULD get them a proposal is already on this row.
                if design.offersShow {
                    Button(DepartmentDesignRow.showTitle) { showProposal() }
                        .controlSize(.small)
                        .accessibilityLabel(DepartmentDesignRow.showAccessibilityLabel)
                        .help(DepartmentDesignRow.showHelp)
                }
            }
            Text(design.latestLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField(DepartmentDesignRow.directionPrompt, text: $direction,
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .font(.callout)
            designControls
            if let status = design.statusLine {
                Text(status)
                    .font(.caption)
                    // Red only for a failure, the cockpit's rule: a colour that
                    // never changes is a colour that says nothing.
                    .foregroundStyle(design.isFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **Run, Request Changes while there is something to change, and Cancel
    /// while a round is in flight.**
    ///
    /// Run is drawn in every state and **disabled** rather than hidden
    /// (`ReviewRoundCockpit.runRow`'s rule, which the language rows follow one
    /// section down). Request Changes is the opposite and deliberately so: it is
    /// drawn only while `hasOpenProposalRound`, because outside that window it
    /// does not merely refuse — the honest verb is Run, with the writer's words
    /// as the round's direction, and that button is already here. A permanently
    /// disabled second control teaching the writer to use the first is worse
    /// than not drawing it.
    ///
    /// **Both buttons carry an accessibility label of their own.** The visible
    /// titles are the spec's, and "Run" is also what every language row's button
    /// says — three identical labels in one tree are three controls a VoiceOver
    /// user cannot tell apart, since the row that disambiguates them visually is
    /// not something a linear tree carries.
    ///
    /// **No `keyboardShortcut`**, for the language rows' reason: ⌘R is the
    /// compiler's in whichever window hosts this pane.
    @ViewBuilder
    private var designControls: some View {
        HStack(spacing: 6) {
            Button(DepartmentDesignRow.runTitle) {
                let words = direction.trimmingCharacters(in: .whitespacesAndNewlines)
                if runDesign(words.isEmpty ? nil : words) { direction = "" }
            }
            .controlSize(.small)
            .disabled(!design.canRun)
            .accessibilityLabel(DepartmentDesignRow.runAccessibilityLabel)
            .help(design.refusal
                  ?? DepartmentDesignRow.runHelp(designerName: design.designerName))
            if design.offersRequestChanges {
                Button(DepartmentDesignRow.requestChangesTitle) {
                    if requestDesignChanges(direction) { direction = "" }
                }
                .controlSize(.small)
                .disabled(!design.canRun)
                .help(design.refusal ?? DepartmentDesignRow.requestChangesHelp)
            }
            if design.isRunning {
                Button(DepartmentRunState.cancelTitle) { cancelDesignRun() }
                    .controlSize(.small)
                    .accessibilityLabel(DepartmentDesignRow.cancelAccessibilityLabel)
                    .help(DepartmentDesignRow.cancelHelp)
            }
            Spacer(minLength: 0)
        }
    }

    private func section<Content: View>(
        _ heading: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One edition: who translates it, how much of it stands, what is still
    /// unanswered, and the door to its brief (spec §5's language row, minus the
    /// Run that is Task 3's).
    ///
    /// **Every string here is `DepartmentDesk`'s**, so the whole row is
    /// assertable with nothing mounted — the split `ReviewBoardOpenNotes` made
    /// for the same reason. The one exception is the language's own name, which
    /// is `TranslationReviewIndicator.displayLabel`: the tag the writer reads on
    /// the desk and the one they read in the translation indicator must be the
    /// same string, and that is where it is spelled.
    private func languageRow(_ row: EditionStatus.LanguageRow) -> some View {
        let run = runs[row.language] ?? DepartmentRunState()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TranslationReviewIndicator.displayLabel(forLanguageTag: row.language))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Button(DepartmentDesk.editionBriefTitle) {
                    openEditionBrief(row.language)
                }
                .controlSize(.small)
                .help(DepartmentDesk.editionBriefHelp(language: row.language))
                runControls(row, run: run)
            }
            Text(DepartmentDesk.translatorLine(row.translator))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(DepartmentDesk.coverageLine(
                fresh: row.fresh, stale: row.stale, missing: row.missing))
                .font(.caption)
                .foregroundStyle(.secondary)
            // Absent at zero rather than rendered as "0 open queries": the line
            // is a debt the writer owes a translator, and a surface that says
            // "0" of it every time trains them to stop reading it.
            if let queries = DepartmentDesk.queryLine(openQueries: row.openQueries) {
                Text(queries)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // What the round is doing, or what the last one did. One slot, and
            // `statusLine` decides which — see `DepartmentRunState`.
            if let status = run.statusLine {
                Text(status)
                    .font(.caption)
                    // Red only for a failure, on `ReviewRoundCockpit`'s rule: a
                    // colour that never changes is a colour that says nothing.
                    .foregroundStyle(run.isFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **Run, and — only while this edition is the one in flight — Cancel.**
    ///
    /// The Run button is drawn in every state and **disabled** rather than hidden
    /// (`ReviewRoundCockpit.runRow`'s rule): a control that vanishes teaches
    /// nothing about why it is unavailable, and the writer who came to the desk to
    /// translate a chapter needs to learn that a chapter is what a round is for.
    /// The reason travels as `help` here and is drawn in full above the rows.
    ///
    /// **No `keyboardShortcut`** — a translation is started from the desk, and the
    /// window's ⌘R belongs to the compiler. A binding here would be a second
    /// command competing for that key in whichever window hosts this pane.
    @ViewBuilder
    private func runControls(_ row: EditionStatus.LanguageRow,
                             run: DepartmentRunState) -> some View {
        Button(DepartmentRunState.runTitle) { runTranslation(row.language) }
            .controlSize(.small)
            .disabled(!run.canRun)
            .help(run.refusal
                  ?? DepartmentRunState.runHelp(language: row.language,
                                                target: runTarget))
        if run.isRunning {
            Button(DepartmentRunState.cancelTitle) { cancelRun() }
                .controlSize(.small)
                .help("Stop this round. Nothing it has translated is written "
                      + "\u{2014} a run that does not finish writes nothing at all.")
        }
    }
}

/// **The desk's own words** (publish-department P4 Task 1) — the section
/// headings and every string a row prints, as values.
///
/// Split out of the pane's body for `ReviewBoardOpenNotes`' reason: the truth
/// table is then assertable with nothing mounted, and the words the writer reads
/// live in one place rather than three arms of a `ViewBuilder`. The Design row's
/// own words are `DepartmentDesignRow`'s, beside the decisions they belong to.
enum DepartmentDesk {

    static let designHeading = "Design"
    static let languagesHeading = "Languages"

    /// What the Languages section says while the book has one edition only —
    /// the state a project is in until somebody translates a paragraph. The
    /// section is always drawn, because the Design row above it always has
    /// something to offer (Task 4 retired the pane's empty state).
    static let noLanguagesYet = "No translations yet."

    // MARK: - A language row's words (Task 2)

    /// The door on every language row. **"Brief" and not "Open Brief"** — the
    /// row is the edition, so the verb is in the click.
    static let editionBriefTitle = "Edition Brief"

    /// What a row says where a person's name goes when there is none.
    ///
    /// `EditionStatus.translatorName` answers nil for an unlisted, unminted
    /// language, which is the honest answer for `translation_status`'s field —
    /// it omits it. A desk row cannot omit a line without leaving a blank where
    /// a name goes, and a blank reads as a bug rather than as somebody the
    /// writer has not named yet.
    static let noTranslatorYet = "No translator yet"

    /// What the coverage line says for a language nobody has translated a
    /// paragraph of — the query-first edition, whose figures are all zero
    /// because there is no file to derive them from. "0 fresh · 0 stale · 0
    /// missing" would read as a book with no paragraphs in it.
    static let notStarted = "Not started"

    static func translatorLine(_ translator: String?) -> String {
        translator ?? noTranslatorYet
    }

    /// The three figures `translation_status` reports, in its own vocabulary
    /// and its own order.
    static func coverageLine(fresh: Int, stale: Int, missing: Int) -> String {
        guard fresh + stale + missing > 0 else { return notStarted }
        return "\(fresh) fresh · \(stale) stale · \(missing) missing"
    }

    /// What the writer still owes this edition's translator, or nil when they
    /// owe nothing.
    static func queryLine(openQueries: Int) -> String? {
        guard openQueries > 0 else { return nil }
        return "\(openQueries) open quer\(openQueries == 1 ? "y" : "ies")"
    }

    static func editionBriefHelp(language: String) -> String {
        "Register, idiom policy and what stays untranslated for the "
            + "\(TranslationReviewIndicator.displayLabel(forLanguageTag: language)) "
            + "edition"
    }
}
