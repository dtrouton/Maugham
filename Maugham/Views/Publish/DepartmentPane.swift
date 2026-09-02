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
    /// **Every chapter the language walk could not open** (issue #43, F-D),
    /// named above the rows.
    ///
    /// A standing line rather than the `notice` channel above: `notice` is for a
    /// refusal the writer just asked for and clears on the next attempt, and
    /// this is a fact about the book that is true until the file is readable
    /// again. The rows this chapter would have contributed are missing from
    /// `languages`, so without the line an unreadable chapter reads as an
    /// untranslated one — and a book whose every chapter failed reads as a book
    /// with no editions, which is why `noLanguagesYet` yields to it below.
    ///
    /// **No default**, so a new mount site has to say what it knows about
    /// unreadable chapters rather than inheriting silence. The whole defect
    /// F-D fixes is a surface that omitted this fact and read as an honest
    /// answer; a defaulted `[]` is that omission spelled as a convenience.
    var unreadable: [EditionStatus.UnreadableDocument]
    /// **Which languages have a proposed edition brief waiting** (translation
    /// pipeline P5) — the badge a language row carries when Claude has staged
    /// one, drawn beside the language's own name. Lowercased tags, matching
    /// `ProposableStatement.key`'s own casing (`DepartmentPaneHost
    /// .proposedLanguages`), so a row whose own `language` came back a
    /// different case still finds its mark.
    var proposedBriefs: Set<String> = []
    /// **A proposed brief for a language the desk has no row for at all** —
    /// Claude proposed an edition the book has never had a paragraph
    /// translated into, so there is no row for the badge above to sit on. Its
    /// own line at the foot of the section, sorted, with the same door a row
    /// would have offered.
    var proposedWithoutRow: [String] = []
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
    /// **Ask for a round on every chapter of this book** (translation pipeline
    /// P4) — the desk's own scope, at last, as a verb.
    ///
    /// A second closure rather than an argument on `runTranslation`, because
    /// the two refuse for different reasons: a chapter run needs the window to
    /// have one open and a book run does not (`DepartmentRunState.bookRefusal`
    /// against `refusal`). A single closure with a flag would have to be read
    /// alongside a predicate to know which refusal applied to it.
    var runBook: (String) -> Void = { _ in }
    /// **Open this edition's newest round in the centre column** — the row's
    /// door, and its only control that is navigation rather than a verb.
    ///
    /// It takes the LANGUAGE and not the round, for `showProposal`'s reason
    /// inverted: which round this is was resolved by the host and is already on
    /// the row's own `DepartmentRunState`, but the pane may not be the thing
    /// that hands a model object back up — the host holds the round it derived
    /// and sends that one, so the round the centre opens and the round
    /// `statusLine` describes cannot be two different objects.
    var showRound: (String) -> Void = { _ in }
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
    /// **The cast sheet's prompt, or nil** (P4 Task 9, widened by
    /// cast-management) — what the desk is asking the writer about one of the
    /// book's people. Set by the host when a Run would mint an unlisted
    /// language's translator with no name (`DepartmentPaneHost
    /// .needsTranslatorName`), and when the writer asks to start an edition.
    var castPrompt: DepartmentCastPrompt? = nil
    /// Answer the sheet — mints (or finds) the role and renames it in one
    /// visible act, then does whatever the ask was standing in front of. The
    /// host's, because every half of it writes.
    var confirmCast: (DepartmentCastAnswer) -> Void = { _ in }
    /// Back out of the sheet. Whatever it was standing in front of does not
    /// happen; the abandon lands in `notice` (Global Constraint 2), which is
    /// why this takes no reason of its own.
    var cancelCast: () -> Void = { }
    /// **Start an edition the book does not have yet** (cast-management) — the
    /// button at the foot of the Languages section. A closure, because opening
    /// the sheet is the host's: the desk's rows are the host's derivation, and
    /// deciding a language is already among them is a question about them.
    var addLanguage: () -> Void = { }
    /// **Say who translates this edition** (cast-management) — the language
    /// row's own rename, by language. A closure for `addLanguage`'s reason:
    /// resolving which role that is may have to mint one first.
    var renameTranslator: (String) -> Void = { _ in }
    /// **Say who designs this book.** No argument: there is one designer, and
    /// the Design row is about them.
    var renameDesigner: () -> Void = { }
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

    /// **Every imprint this project defines**, sorted — the picker's rows, and
    /// nothing more: an imprint's own contents are the config's business and
    /// this pane never opens it.
    ///
    /// Empty is the ordinary case (most books are not published under an
    /// imprint) and is drawn as one line saying where an imprint comes from,
    /// rather than as a picker with a single row that cannot be changed.
    var imprints: [String] = []
    /// **Which imprint the desk is standing on** — `nil` is the book itself.
    ///
    /// A value in, a closure out, because the choice is PERSISTED: it lives in
    /// the project's `UIState` so the writer who compiles the same special
    /// edition all week does not re-pick it every morning, and writing it is
    /// the host's.
    var selectedImprint: String? = nil
    var selectImprint: (String?) -> Void = { _ in }
    /// **What the desk's own compile is doing** (`DeskCompileRunner.state`) —
    /// every sentence and every availability decision as one value, so this
    /// pane holds no orchestrator.
    var compileRun: DepartmentCompileState = DepartmentCompileState()
    /// Press Compile. The sheet below assembles the request; starting it
    /// reaches the runner, which is the host's.
    var runCompile: (DeskCompileRunner.Request) -> Void = { _ in }
    /// Stop the compile in flight. Reachable only while `compileRun.isRunning`
    /// — which is the STORED flag and never the phase, because a refusal
    /// replaces the phase while the run it refused carries on, and a Cancel
    /// that vanished in that moment would leave the writer no way to stop it.
    var cancelCompile: () -> Void = { }
    /// **The book's own language** (`metadata.language`) — the tag the compile
    /// sheet offers checked, and the one `LanguageSet` substitutes back to the
    /// untranslated body. Carried in rather than assumed "en", because a book
    /// written in Spanish with an English edition has this the other way round
    /// and the sheet would otherwise offer to compile the translation as the
    /// source.
    var bookLanguage: String = PublishConfig.Metadata().language

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

    /// **Whether the compile sheet is up** — the pane's second piece of local
    /// state, on `direction`'s rule: it is this surface's own transient UI and
    /// nothing outside reads it, so a `Binding` down from the host would put a
    /// presentation flag on the derivation that walks every document.
    @State private var showingCompileSheet = false

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
            // **The compile sheet hangs on the desk, not on the pane.**
            // `.sheet(isPresented:)` beside `.sheet(item:)` on ONE view do not
            // coexist in SwiftUI — the later declaration wins and the earlier
            // one silently stops presenting, which took the cast sheet's
            // every button with it (measured: `DepartmentRunTests`' rename
            // and mint cases crashed on an empty button array). This is
            // narrower than "two `.sheet` modifiers on one view" — three
            // stacked `.sheet(item:)` modifiers already coexist on one view
            // in `AnnotationsPane.swift` and `InboxPane.swift`. Each sheet
            // here still gets a view of its own.
            desk
                .sheet(isPresented: $showingCompileSheet) {
                    DepartmentCompileSheet(
                        // **The book's own language is never offered twice.**
                        // The sheet draws it as its own checkbox ("The book's
                        // own language (English)"); a translator role named for
                        // the same tag — `Add Language…` with "en" on an
                        // English book, which the desk accepts — put a second
                        // box beside it, and checking both sent `["en", "en"]`
                        // into `LanguageSet`, which refuses a duplicate and
                        // fails the compile red for a request the sheet itself
                        // made offerable. Case-insensitively, because a tag is
                        // matched that way everywhere else on this desk.
                        languages: languages.map(\.language).filter {
                            $0.caseInsensitiveCompare(bookLanguage) != .orderedSame
                        },
                        bookLanguage: bookLanguage,
                        imprint: selectedImprint,
                        onCompile: { request in
                            showingCompileSheet = false
                            runCompile(request)
                        },
                        onCancel: { showingCompileSheet = false })
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // **The cast sheet** (P4 Task 9). The `Binding`'s `set` is the only
        // way this value-taking pane can hear a swipe-away or Esc dismiss —
        // there is no `@State` here for `castPrompt` to live in, so a
        // dismissal that bypassed both buttons still has to reach
        // `cancelCast`, or the host's `castPrompt` would outlive the sheet
        // that showed it and the next render would draw it right back.
        .sheet(item: Binding(get: { castPrompt },
                              set: { if $0 == nil { cancelCast() } })) { prompt in
            DepartmentCastSheet(prompt: prompt,
                                onConfirm: confirmCast, onCancel: cancelCast)
        }
    }

    /// The book's name, and — when there is a choice to make — which imprint
    /// the desk is standing on (spec §6).
    ///
    /// **The picker's home is the header** because what it changes is what the
    /// whole desk is about: the language rows below are summed over the
    /// imprint's own documents, and the Compile it feeds counts that imprint's
    /// own versions. A control down among the rows would read as a property of
    /// the rows.
    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer(minLength: 6)
            if !imprints.isEmpty {
                Picker(DepartmentDesk.imprintLabel,
                       selection: Binding(get: { selectedImprint },
                                          set: { selectImprint($0) })) {
                    Text(DepartmentDesk.bookImprintTitle).tag(String?.none)
                    ForEach(imprints, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .help(DepartmentDesk.imprintHelp)
            }
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
                // **Where an imprint comes from, for a project that has none.**
                // Drawn instead of the picker rather than beside it: a picker
                // with one unchangeable row is a control that can only refuse,
                // and the honest answer to "why can't I pick one" is the
                // sentence naming where imprints are declared.
                //
                // **Inside the scroller, not under the header.** A wrapping
                // `Text` carrying `fixedSize(vertical: true)` OUTSIDE a
                // `ScrollView` demands its full intrinsic height from the
                // column, and this one is drawn for every project that has no
                // imprints — which is most of them. Measured: it grew the whole
                // split view to 1002pt in a 732pt window and took the binder
                // and the writing column with it
                // (`DetailPaneColumnHeightCensusTests`, the exact failure that
                // census names in its own message).
                if imprints.isEmpty {
                    Text(DepartmentDesk.noImprintsYet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                section(DepartmentDesk.designHeading) {
                    designRow
                }
                section(DepartmentDesk.languagesHeading) {
                    // **Above the rows, one line per chapter that would not
                    // open** (issue #43, F-D) — because what is below is
                    // incomplete by exactly these chapters, and the writer
                    // cannot tell that from the rows themselves.
                    ForEach(unreadable, id: \.documentId) { document in
                        PublishNoticeLine(
                            headline: DepartmentDesk.couldNotRead(document.title),
                            detail: document.reason)
                    }
                    if languages.isEmpty {
                        // **"No translations yet." is a claim about the book,
                        // and a failed read cannot support it.** With a chapter
                        // unreadable the honest empty state is the line above:
                        // Maugham does not know what editions this book has.
                        if unreadable.isEmpty {
                            Text(DepartmentDesk.noLanguagesYet)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        addLanguageButton
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
                        addLanguageButton
                    }
                    // **A proposed brief for a language nothing else on the
                    // desk names** — no row above carries its badge, so it
                    // gets a line of its own rather than going unseen.
                    ForEach(proposedWithoutRow, id: \.self) { language in
                        HStack {
                            Text(DepartmentDesk.proposedWithoutRowLine(language: language))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(DepartmentDesk.editionBriefTitle) {
                                openEditionBrief(language)
                            }
                            .controlSize(.small)
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

    /// **The door to an edition the book does not have yet** (cast-management),
    /// at the foot of the section it adds a row to — drawn in both arms,
    /// because the empty one is exactly where a writer with no editions yet
    /// comes to start their first.
    ///
    /// **Not `keyboardShortcut`ed**, on the language rows' own rule: the keys
    /// this window has left belong to the compiler, and a control the writer
    /// presses once per edition has no claim on one. **Compile… inherits that
    /// rule verbatim** — ⌘R is the compiler's in whichever window hosts this
    /// pane, and a second command competing for it is what tripwire 21's
    /// unscoped-broadcast family looks like one layer up.
    private var addLanguageButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(DepartmentDesk.addLanguageTitle) { addLanguage() }
                    .controlSize(.small)
                    .help(DepartmentDesk.addLanguageHelp)
                // **The desk's own press.** Until it existed, every book this
                // app ever made was asked for by Claude over the MCP socket;
                // this is the writer's own door to the same orchestrator.
                Button(DepartmentDesk.compileTitle) { showingCompileSheet = true }
                    .controlSize(.small)
                    .disabled(compileRun.isRunning)
                    .help(compileRun.isRunning
                          ? DepartmentCompileState.alreadyRunning
                          : DepartmentDesk.compileHelp)
                Spacer(minLength: 0)
            }
            compileStatus
        }
        .padding(.top, 2)
    }

    /// **What the compile is doing, and the one way to stop it** — drawn
    /// through the ONE channel `DepartmentCompileState.statusLine` is, beside
    /// the button that starts it.
    ///
    /// **Cancel is gated on `isRunning` and never on the phase.** A second
    /// press while one is running replaces the phase with a refusal and leaves
    /// the run going; a Cancel that read the phase would disappear in exactly
    /// that moment, taking the writer's only way to stop the compile with it.
    /// The refusal sentence still says something is compiling — that is
    /// `statusLine`'s own doing, not a second line here.
    @ViewBuilder
    private var compileStatus: some View {
        if compileRun.statusLine != nil || compileRun.isRunning {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let status = compileRun.statusLine {
                    Text(status)
                        .font(.caption)
                        // Red only for a failure, the cockpit's rule one
                        // section up: a refusal and a cancel are not faults.
                        .foregroundStyle(compileRun.isFailure
                                         ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if compileRun.isRunning {
                    Button(DepartmentCompileState.cancelTitle) { cancelCompile() }
                        .controlSize(.small)
                        .accessibilityLabel(DepartmentDesk.cancelCompileLabel)
                        .help(DepartmentDesk.cancelCompileHelp)
                }
            }
        }
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
                renameButton(DepartmentDesignRow.renameTitle(
                    designerName: design.designerName)) { renameDesigner() }
            }
            .contextMenu {
                Button(DepartmentDesignRow.renameTitle(
                    designerName: design.designerName)) { renameDesigner() }
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
                // A proposed brief waiting on the writer, on the design row's
                // own badge shape (`design.pendingBadge`) — the same visual
                // vocabulary for the same kind of fact, one column apart.
                if proposedBriefs.contains(row.language) {
                    Text(DepartmentDesk.proposedBadge)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .help(DepartmentDesk.proposedHelp(language: row.language))
                }
                Spacer(minLength: 6)
                renameButton(DepartmentDesk.renameTitle(translator: row.translator)) {
                    renameTranslator(row.language)
                }
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
            // `statusLine` decides which — see `DepartmentRunState`. Show sits
            // beside it because it is about that same round: a door drawn up
            // with the verbs would read as a third thing to press before
            // running, rather than as the way into what has already run.
            if run.statusLine != nil || run.offersShow {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let status = run.statusLine {
                        Text(status)
                            .font(.caption)
                            // Red only for a failure, on `ReviewRoundCockpit`'s
                            // rule: a colour that never changes says nothing.
                            .foregroundStyle(run.isFailure ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    // Hidden rather than disabled, and the only control on this
                    // desk that is: every other refusal has a sentence to give,
                    // and a door to a round that does not exist has none — the
                    // row's own status line has already said there is none.
                    if run.offersShow {
                        Button(DepartmentRunState.showRoundTitle) {
                            showRound(row.language)
                        }
                        .controlSize(.small)
                        .accessibilityLabel(
                            DepartmentRunState.showRoundAccessibilityLabel(
                                language: row.language))
                        .help(DepartmentRunState.showRoundHelp)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The pre-flight and the trend, sharing one line beneath the status
            // rather than taking one each (spec §8) — and drawn only while the
            // row is idle, which is `detailLine`'s own rule.
            if let detail = run.detailLine {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(DepartmentDesk.renameTitle(translator: row.translator)) {
                renameTranslator(row.language)
            }
            // In the Rename… menu's company (spec §5). The row's own button is
            // the real door — SwiftUI builds a context menu's items only while
            // the menu is up, so a keyboard, VoiceOver and every
            // accessibility-tree test find nothing here — and this is the
            // gesture a Mac writer reaches for first. Same call, same refusal.
            Button(DepartmentRunState.runBookTitle) { runBook(row.language) }
                .disabled(!run.canRunBook)
        }
    }

    /// **The rename affordance, drawn twice on purpose** — once as this small
    /// control on the row, once as a right-click item beside it.
    ///
    /// A context menu alone would be the whole verb: a writer without a mouse
    /// could not reach it, VoiceOver would not announce it, and no test here
    /// could press it — SwiftUI builds a `.contextMenu`'s items only while the
    /// menu is up, so an accessibility-tree press has nothing to find (the
    /// board's chip verbs record the same finding one persona over). So the
    /// button is the real door and the menu is the gesture a Mac writer will
    /// reach for first; they post the same call.
    ///
    /// A glyph rather than a word because the row already carries two or three
    /// controls in a column 340pt wide, and a third title is what starts
    /// truncating the language's own name. Its accessibility label is the full
    /// sentence, so the tree says what the picture means.
    private func renameButton(_ title: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel(title)
        .help(title)
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
        // **The desk's own scope, and it reads a refusal of its own.** A book
        // run needs no open chapter — the rows already sum every chapter — so
        // it is `bookRefusal` here and never `refusal`, or the one verb that
        // matches what this pane is about would be dead on exactly the subject
        // a writer opens the department on.
        Button(DepartmentRunState.runBookTitle) { runBook(row.language) }
            .controlSize(.small)
            .disabled(!run.canRunBook)
            .accessibilityLabel(
                DepartmentRunState.runBookAccessibilityLabel(language: row.language))
            .help(run.bookRefusal
                  ?? DepartmentRunState.runBookHelp(language: row.language,
                                                    count: run.bookDocumentCount,
                                                    words: run.bookWords))
        if run.isRunning {
            Button(DepartmentRunState.cancelTitle) { cancelRun() }
                .controlSize(.small)
                .help(DepartmentRunState.cancelHelp)
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

    /// **What the desk says about a chapter it could not open** (issue #43,
    /// F-D). Names the chapter as the writer's own tree names it; the failure's
    /// own sentence goes underneath, as the detail.
    ///
    /// "Couldn't read" rather than "Error" or "Failed" for
    /// `PublishCentreNotice`'s reason one column over: what the writer needs is
    /// which of their chapters is missing from what they are looking at, not a
    /// category of fault.
    static func couldNotRead(_ title: String) -> String {
        "Couldn\u{2019}t read \(title)"
    }

    /// **The door to a first (or fourth) edition** (cast-management). The
    /// ellipsis is the platform's promise that a sheet follows rather than an
    /// edition appearing on the spot.
    static let addLanguageTitle = "Add Language\u{2026}"

    static let addLanguageHelp =
        "Start an edition in another language and say who translates it"

    // MARK: - The imprint picker and the desk's own compile (imprints P3 Task 5)

    /// The picker's label. Visible rather than `labelsHidden()`: a bare popup
    /// reading "Book" beside a book's title says nothing about what it changes,
    /// and this is the one control on the desk whose choice re-sums every row
    /// under it.
    static let imprintLabel = "Imprint"

    /// **What `nil` is called.** The book itself — the thing every compile
    /// before imprints existed produced, and the row a project lands on until
    /// the writer picks otherwise.
    static let bookImprintTitle = "Book"

    static let imprintHelp =
        "Which edition of this project the desk is about \u{2014} the book "
        + "itself, or one of the imprints its config declares. An imprint has "
        + "its own template, its own metadata and its own version count."

    /// **What a project with no imprints is told, in place of the picker.**
    /// It names the file, because that is the only place an imprint can be
    /// declared and a writer who cannot find the door has no other clue.
    static let noImprintsYet =
        "This project has no imprints \u{2014} define one in config.json to "
        + "compile a special edition."

    /// The ellipsis is the platform's promise that a sheet follows: the format
    /// and the editions are still to be chosen, and a press here compiles
    /// nothing on its own.
    static let compileTitle = "Compile\u{2026}"

    static let compileHelp =
        "Make the book \u{2014} choose a format and which editions go in it"

    /// **Named rather than left as "Cancel"** — the desk can carry three
    /// controls with that title at once (a translation round, a design round,
    /// and this), and three identical labels in one tree are three controls a
    /// VoiceOver user cannot tell apart.
    static let cancelCompileLabel = "Cancel Compile"

    static let cancelCompileHelp =
        "Stop this compile. Nothing is published \u{2014} a compile that does "
        + "not finish leaves no publication behind."

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

    /// **The row's rename verb, naming the person it is about** — a desk with
    /// four editions offers four of these, and "Rename…" four times is four
    /// controls a VoiceOver user cannot tell apart.
    ///
    /// A row with nobody on it yet asks for a NAME rather than a rename, which
    /// is the honest verb for an unlisted language nothing has minted a role
    /// for — `translatorLine` prints "No translator yet" on the same row.
    static func renameTitle(translator: String?) -> String {
        guard let translator else { return "Name This Translator\u{2026}" }
        return "Rename \(translator)\u{2026}"
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

    // MARK: - The "proposed" mark (translation pipeline P5)

    /// The badge itself, on a row that already has a proposed brief waiting.
    static let proposedBadge = "Proposed"

    static func proposedHelp(language: String) -> String {
        "Claude proposed a brief for "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + ". Open Edition Brief to adopt or discard it."
    }

    /// The foot-of-section line for a language with no row of its own yet.
    ///
    /// **`TranslationPipeline.Environment.languageName`, not
    /// `TranslationReviewIndicator.displayLabel`** — the row's own badge
    /// (`proposedHelp`) uses the row's vocabulary, tag and all, because it
    /// sits beside a name the row already prints that way. This line has no
    /// row to agree with: it is naming a language the desk has never shown
    /// before, in a sentence with no tag anywhere else in it, and "Italian
    /// (it)" reads as a fragment of some other UI pasted in.
    static func proposedWithoutRowLine(language: String) -> String {
        "Claude proposed a brief for "
            + TranslationPipeline.Environment.languageName(tag: language)
            + " — open it to adopt or discard."
    }
}
