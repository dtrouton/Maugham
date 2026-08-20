import SwiftUI
import MaughamCore

/// **The department desk** (publish-department P4 Task 1) — Publish's own
/// working pane, and `ReviewBoardPane`'s sibling one persona over.
///
/// Review got a board saying where every piece stands on every pass; Publish
/// gets a desk saying where the book's DESIGN stands and where each language
/// EDITION stands. Two sections, and the milestone fills them in order: the
/// language rows and their edition briefs (Task 2), a translation run (Task 3),
/// and the designer's own row with a direction and a run (Task 4). This task is
/// the seat and the skeleton — the pane reads, and nothing here acts yet.
///
/// **It takes values, never a store** (tripwire 4, and the sibling's rule for
/// the sibling's reason). Every input below is a plain value assembled by the
/// mount in `DetailPaneToggle`, so a desk of twenty languages costs twenty rows
/// of layout and no I/O, and the whole surface is mountable in a test with no
/// project on disk — which is what `DepartmentPaneTests` does. The derivations
/// those values come from are expensive on purpose: the language union walks
/// every manuscript document's translation store, and the proposal list reads
/// `.maugham/design/proposals/`. Neither may ever happen on this body path.
///
/// **The empty state is honest about which of the two is missing.** A project
/// with no translations and no design round has nothing for a department to do,
/// and says so rather than drawing two headings over nothing. What it must not
/// do is read as broken: `DepartmentDesk.emptiness` owns that sentence, so the
/// truth table is assertable without mounting anything and the pane cannot
/// disagree with itself about what it is showing.
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
    /// How many design proposals the designer has staged. **Task 4 replaces
    /// this count with the proposals themselves** (the newest pending one's
    /// badge, the round's age, its status); a count is what the skeleton can
    /// honestly draw with no verbs behind it.
    let designProposalCount: Int
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
            if let emptiness = DepartmentDesk.emptiness(
                languageCount: languages.count,
                proposalCount: designProposalCount) {
                ContentUnavailableView {
                    Label(emptiness.title, systemImage: "person.2")
                } description: {
                    Text(emptiness.description)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                desk
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    Text(DepartmentDesk.designSummary(proposalCount: designProposalCount))
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

/// **What the desk says when there is little to say** (publish-department P4
/// Task 1) — the empty state's words and the two section headings, as values.
///
/// Split out of the pane's body for `ReviewBoardOpenNotes`' reason: the truth
/// table is then assertable with nothing mounted, and the words the writer reads
/// live in one place rather than three arms of a `ViewBuilder`.
enum DepartmentDesk {

    static let designHeading = "Design"
    static let languagesHeading = "Languages"

    /// What the Languages section says while the book has one edition only —
    /// the state a project is in until somebody translates a paragraph. Drawn
    /// only when the DESIGN half has something, since a desk with neither is
    /// the empty state below.
    static let noLanguagesYet = "No translations yet."

    /// The empty state's two lines: what is not here, and what would put
    /// something here.
    struct Emptiness: Equatable {
        let title: String
        let description: String
    }

    /// The desk's whole empty state, or `nil` when it has something to draw.
    ///
    /// **Both halves must be missing.** A book with a design round and no
    /// translations is a working department, and so is one with three editions
    /// and no design round — hiding either behind an "unavailable" view would
    /// tell the writer their department is empty while it is holding work.
    static func emptiness(languageCount: Int, proposalCount: Int) -> Emptiness? {
        guard languageCount == 0, proposalCount == 0 else { return nil }
        return Emptiness(
            title: "Nothing on the desk yet",
            description: "The book's design rounds and its language editions "
                + "appear here.")
    }

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

    /// The Design section's one line while the skeleton stands: how many rounds
    /// the designer has proposed. Task 4 replaces it with the round itself.
    static func designSummary(proposalCount: Int) -> String {
        switch proposalCount {
        case 0: return "No design round yet."
        case 1: return "1 design round proposed."
        default: return "\(proposalCount) design rounds proposed."
        }
    }
}
