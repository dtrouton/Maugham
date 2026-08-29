import SwiftUI
import AppKit
import MaughamCore
import os

private let _departmentLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "Department")

/// **Where the desk's values come from, and where its one door leads**
/// (publish-department P4 Task 2).
///
/// `DepartmentPane` takes values and holds no store (its own census says so),
/// and the values it takes are expensive: the language union walks every
/// manuscript document's translation store, reads each one's open annotations,
/// and derives coverage against the current paragraph state. None of that may
/// happen on a `body` path (tripwire 4), so it happens here in a `.task` and
/// arrives as a plain array — `ReferencesPaneHost`'s shape, for
/// `ReferencesPaneHost`'s reason.
///
/// **It is also where the brief's door goes**, because the door writes: it
/// creates the statement the writer is about to type in and then presents an
/// editor over the desk. A pane that could do either would be a pane holding a
/// store.
struct DepartmentPaneHost: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let projectURL: URL
    /// **What the window's tree is naming** — the input Global Constraint 1 turns
    /// into a run target (Task 3). The desk sums the whole book, but a round is
    /// one chapter's, and this is the only thing on the pane that says which.
    var subject: BinderSubject? = nil
    /// The window's translator (P2), owned by `ProjectWindow` beside the compiler
    /// and reached here the way `DiagnosticsPane` reaches the compiler: passed as
    /// a value, never constructed. Optional so a caller that surfaces no run — the
    /// probe mounts — offers a desk that reads and does not act.
    var translator: TranslatorOrchestrator? = nil
    /// The window's record of finished rounds. Window-scoped rather than held here
    /// because `onRunEnded` is wired when the stores are configured, long before
    /// anybody opens this pane — see `TranslationRunLog`.
    var runLog: TranslationRunLog? = nil
    /// The window's designer (P3), reached exactly as `translator` is and for the
    /// same reason: a round is started from this column while the warm session
    /// that answers it belongs to the window, which is the only thing that can
    /// tear it down (`DesignerOrchestrator.shutdown()`'s contract). Optional so a
    /// caller that surfaces no run — the probe mounts — offers a desk that reads
    /// and does not act.
    var designer: DesignerOrchestrator? = nil
    /// **The window's translation pipeline** (translation pipeline P3), reached
    /// exactly as `translator` is and owned beside it, because the leg it holds
    /// open outlives no window either.
    ///
    /// Passed here for the GATE: a round's cold legs hold no translator session,
    /// so `translator.isRunning` reads false while a reader is out and every row
    /// would offer Run into a round already under way (`DepartmentRunSession
    /// .read`). What its legs LOOK like on the rows is Plan 4's; this is only
    /// the refusal. Optional for `translator`'s reason — a probe mount offers a
    /// desk that reads and does not act.
    var pipeline: TranslationPipeline? = nil
    /// **Where a Show goes** (Task 5) — the window's own centre column, which is
    /// the other side of this split view.
    ///
    /// A closure up rather than a write here, `ReviewBoardPane.onOpenNotes`'
    /// shape: which surface takes the centre is `ProjectWindow`'s question, and
    /// a pane in the right column that wrote it would be the second place the
    /// centre is decided. The whole `Proposal` travels because this host has
    /// just read it — see `proposals` below.
    var onShowProposal: (DesignProposalStore.Proposal) -> Void = { _ in }

    @State private var languages: [EditionStatus.LanguageRow] = []
    /// **Every chapter the language walk could not open** (issue #43, F-D) —
    /// drawn above the rows, because the rows it would have contributed are
    /// missing and an empty desk over an unreadable book is a false claim about
    /// the book. Derived in the same pass as `languages`, from the same value,
    /// so the two cannot describe different walks.
    @State private var unreadable: [EditionStatus.UnreadableDocument] = []
    /// Every design round this project has staged, newest first — the Design
    /// row's second line and its badge (Task 4). Derived off the body path
    /// because it reads `.maugham/design/proposals/`.
    @State private var proposals: [DesignProposalStore.Proposal] = []
    /// The edition whose brief is on screen, or nil for the desk itself.
    @State private var openBrief: OpenedBrief?
    /// A door that would not open. Cleared on the next attempt.
    @State private var notice: String?
    /// **The cast sheet's question, or nil** (P4 Task 9, widened by
    /// cast-management) — set by `run(language:)` when the language it was asked
    /// for would mint a translator with no name, and by `askForALanguage()` when
    /// the writer wants an edition the book does not have yet. Cleared by
    /// whichever of `confirmCast` / `cancelCast` answers it.
    @State private var castPrompt: DepartmentCastPrompt?
    /// This pane's hosting window, for the ADR 0021 receive helpers' liveness
    /// guard — resolved through `WindowAccessor` because a cached `nil` is not
    /// a close check (`MaughamEvent.isLive`).
    @State private var window: NSWindow?
    /// Bumped by the events below so the derivation re-runs. A counter rather
    /// than a direct `await`: `.task(id:)` owns cancellation, and a re-derive
    /// kicked off from a notification closure would not be cancelled when the
    /// writer leaves the pane mid-walk.
    @State private var refreshes = 0

    /// **The desk's own compile** (imprints P3 Task 5), owned here rather than
    /// by the window — unlike the translator and the designer above.
    ///
    /// Those two hold a WARM `claude -p` session whose only reaper is the
    /// window (`DesignerOrchestrator.shutdown()`'s contract); this holds a
    /// `Task` around an orchestrator, and a compile abandoned by a closing pane
    /// is a job the shared `PublishingStores` still knows about — the same
    /// place an MCP compile lives. So there is nothing here for a window to
    /// tear down, and a `@State` runner keeps the press beside the surface that
    /// draws it.
    @State private var compileRunner = DeskCompileRunner()
    /// Every imprint this project's `config.json` declares, sorted — the
    /// picker's rows. Derived off the body path with the language rows,
    /// because reading the config is disk work (tripwire 4).
    @State private var imprints: [String] = []
    /// `metadata.language`, for the compile sheet's "the book's own language"
    /// row. Read in the same pass as `imprints`, from the same config, so the
    /// two cannot describe different files.
    @State private var bookLanguage = PublishConfig.Metadata().language

    /// What `openBrief(language:in:)` answered: the edition, and the statement
    /// the door found or made for it.
    struct OpenedBrief: Equatable, Identifiable {
        let language: String
        let statementID: String

        var id: String { statementID }
    }

    /// **Five signals, and the `.task`'s own mount is a sixth.** The desk's
    /// figures move when a translation is written (a run, or `write_translation`
    /// from outside), when a query is opened or disposed of, when the manifest
    /// changes (a translator renamed, a chapter added or removed), when a design
    /// round ends — and when the gate in the centre column approves, reverts or
    /// finalizes one (P4 Task 6, through `.maughamDesignProposalsChanged` into
    /// `refreshes`). Read as an `Equatable` value so `.task(id:)` re-runs on a
    /// change and on nothing else.
    ///
    /// **The designer's state is in the key rather than behind an event**
    /// (Task 4), and it is the whole of how a finished round reaches the row: a
    /// proposal is staged under `.maugham/design/`, which touches neither the
    /// manifest nor any `MaughamEvent`, so nothing else would tell this pane its
    /// Design row is out of date. Reading the orchestrator's own state here
    /// registers the observation that makes it live, and the redundant re-derive
    /// when a round *starts* costs one proposals listing.
    /// **Internal rather than private, so the joins are assertable.** Each
    /// field here is a re-derive the desk depends on and none of them is
    /// visible in what the pane draws; a join deleted by a later hand fails
    /// nothing until a writer notices their rows describing the wrong book.
    struct ReloadKey: Equatable {
        let manifestModified: Date
        let refreshes: Int
        let designRunState: DesignerOrchestrator.RunState?
        let designerBusy: Bool
        /// **Which language the pipeline is running, and nothing about which
        /// leg.** The row needs running-vs-idle plus the language — which is
        /// exactly `TranslationPipeline.Status.language` — never the leg
        /// itself: a leg transition touches neither the manifest nor an
        /// event, but the leg is NOT this key's job to carry, because what
        /// redraws a row's leg in P4 is `pipeline.status` read directly by
        /// that row, and an entry written by a fix leg already bumps
        /// `refreshes` through `maughamTranslationDidUpdate`. Keying on the
        /// whole `Status` re-derives this pane's language rows — a full
        /// manifest walk apiece — on every leg transition in the round; for a
        /// thirty-chapter book that is 210 whole-book walks a round for a
        /// join this pane never reads past running-vs-idle-plus-language.
        let pipelineLanguage: String?
        /// **Which imprint the desk is standing on.** A change re-sums every
        /// language row against that imprint's own documents, which is the
        /// whole of what picking one does to this pane.
        let imprint: String?
        /// **`config.json`'s modification date** (imprints P3 Task 5) — the one
        /// signal for a picker whose rows live in a file nothing posts an event
        /// about. An imprint is declared by editing that file (by hand, or
        /// through `set_publish_config`), and neither route touches the
        /// manifest, the annotations or a design proposal; keyed on `refreshes`
        /// alone, the picker would not offer the imprint the writer had just
        /// written.
        ///
        /// **One `stat` per body pass, and no more.** Reading it registers no
        /// observation, so it does not drive a redraw of its own — it is read
        /// whenever this pane was going to lay out anyway, which is what makes
        /// it cheap enough to sit on the body path at all. The cost of that:
        /// an imprint written while the desk sits perfectly idle arrives on the
        /// next pass rather than instantly.
        let configModified: Date?
    }

    var reloadKey: ReloadKey {
        ReloadKey(manifestModified: store.manifest.modified, refreshes: refreshes,
                  designRunState: designer?.runState,
                  designerBusy: designer?.isRunning ?? false,
                  pipelineLanguage: pipeline?.status.language,
                  imprint: documentStore.uiState.publishImprint,
                  configModified: Self.configModified(in: projectURL))
    }

    /// The publish config's modification date, or nil when there is no config
    /// yet — which is itself a value the key can compare, so writing the first
    /// one re-derives.
    static func configModified(in projectURL: URL) -> Date? {
        let url = PublishConfigStore.fileURL(in: projectURL)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    var body: some View {
        Group {
            if let openBrief {
                brief(openBrief)
            } else {
                desk
            }
        }
        .background(WindowAccessor(window: $window))
        // `.project`-scoped, both of them: a window on another book must not
        // re-walk its own manuscripts because this one gained a translation,
        // and a closed window must walk nothing at all (tripwire 21).
        .onProjectEvent(.maughamTranslationDidUpdate, url: projectURL, window: window) { _ in
            refreshes += 1
        }
        .onProjectEvent(.maughamAnnotationsChanged, url: projectURL, window: window) { _ in
            refreshes += 1
        }
        // **The gate's verdict, one column over** (P4 Task 6). Approve / Revert /
        // Finalize rewrite a `proposal.json` and nothing else here would notice:
        // the `ReloadKey` below watches the designer's RUN state, and a promotion
        // is not a run. Without this the Design row goes on saying "waiting for
        // your review" over a proposal the writer just approved.
        .onProjectEvent(.maughamDesignProposalsChanged,
                        url: projectURL, window: window) { _ in
            refreshes += 1
        }
    }

    private var desk: some View {
        // **Resolved once per body pass and handed to both consumers.** The
        // pane's own `runTarget` and the rows resolved against it are two
        // readings of one question; asking it twice is two manifest walks and
        // two chances to differ inside a single frame.
        let target = runTarget
        return DepartmentPane(
            title: store.manifest.title,
            languages: languages,
            unreadable: unreadable,
            design: designRow,
            openEditionBrief: { language in
                Task { await present(language: language) }
            },
            notice: notice,
            runTarget: target,
            runs: runStates(for: target),
            runTranslation: { run(language: $0) },
            // One session per window, so the row that is running is the only row
            // that offers this and there is never a question of whose round it
            // ends. Both cancels: `pipeline.cancel()` reaches the live LEG by
            // kind (guarded on `isRunning`, a no-op when there is none), and
            // `translator?.cancel()` covers a desk-started round outside the
            // pipeline. `DepartmentRunSession.read` already refuses every Run
            // on `pipeline.status` — leaving this cancel pipeline-blind would
            // make a cold leg uncancellable while every row reads busy.
            cancelRun: { pipeline?.cancel(); translator?.cancel() },
            runDesign: { runDesign(direction: $0) },
            requestDesignChanges: { requestDesignChanges($0) },
            cancelDesignRun: { designer?.cancel() },
            castPrompt: castPrompt,
            confirmCast: { confirmCast($0) },
            cancelCast: { cancelCast() },
            addLanguage: { askForALanguage() },
            renameTranslator: { askToRename(language: $0) },
            renameDesigner: { askToRenameTheDesigner() },
            // **The newest round, from the listing the row was resolved from**
            // — so the proposal the gate opens is the one `latestLine`
            // describes rather than a second lookup that could differ. The
            // `nil` arm cannot be reached from the pane (`offersShow` is this
            // same emptiness), and doing nothing is the right answer if it ever
            // is: a Show for a round that no longer exists has nowhere to go.
            showProposal: { if let newest = proposals.first { onShowProposal(newest) } },
            imprints: imprints,
            // Read straight off the store rather than mirrored into `@State`:
            // `DocumentStore` is `@Observable`, so a write through
            // `updateUIState` moves the picker with no event and no second
            // copy of the choice to keep in agreement with the persisted one.
            //
            // …through `selection(persisted:among:)`, because a persisted name
            // is not automatically a selection — see there.
            selectedImprint: Self.selection(
                persisted: documentStore.uiState.publishImprint, among: imprints),
            selectImprint: { Self.select(imprint: $0, in: documentStore) },
            compileRun: compileRunner.state,
            runCompile: {
                compileRunner.start($0, projectStore: store, projectURL: projectURL)
            },
            cancelCompile: { compileRunner.cancel() },
            bookLanguage: bookLanguage)
        .task(id: reloadKey) { await derive() }
    }

    // MARK: - The run (Task 3)

    /// **Which chapter a Run would translate**, from the window's own subject.
    ///
    /// Read on the body path on purpose and cheaply: a `TreeWalk.find` over the
    /// manifest and one dictionary lookup in the open-document registry. Both are
    /// observed (`ProjectStore` and `DocumentStore` are `@Observable`), which is
    /// what makes the button follow the tree — the writer clicks a chapter in the
    /// left column and the desk's Run becomes pressable with no event and no poll.
    ///
    /// **This is the first thing to cache if the desk ever feels sticky**, and
    /// the key is the subject: cheap as it is, a walk of a fifty-chapter manifest
    /// on every body pass of this pane is the shape tripwire 4 is about, and the
    /// observation is the only reason it lives here rather than in the `.task`
    /// beside the language rows. A cache would have to be invalidated by the same
    /// two observations, which is why it is not one yet.
    private var runTarget: DepartmentRunTarget {
        DepartmentRunTarget.resolve(
            subject: subject,
            structure: store.manifest.structure,
            isOpen: { documentStore.document(for: $0) != nil })
    }

    /// One resolved run state per row. A pure fold over values the window already
    /// holds — no I/O, so a book with twenty editions costs twenty comparisons.
    ///
    /// **Takes the target rather than reading it**, so the rows and the pane's
    /// own copy are the same answer by construction (see `desk`) and this fold
    /// adds no manifest walk of its own to the body pass.
    private func runStates(
        for target: DepartmentRunTarget) -> [String: DepartmentRunState] {
        let runState = translator?.runState ?? .idle
        let session = DepartmentRunSession.read(
            runState: runState, isRunning: translator?.isRunning ?? false,
            pipeline: pipeline?.status ?? .idle)
        var states: [String: DepartmentRunState] = [:]
        for row in languages {
            states[row.language] = DepartmentRunState.resolve(
                language: row.language, target: target, session: session,
                runState: runState,
                lastRun: target.docId.flatMap {
                    runLog?.run(docId: $0, language: row.language)
                })
        }
        return states
    }

    /// **The click, and everything that can refuse it in words** (Global
    /// Constraint 2).
    ///
    /// The pre-flight is `DepartmentRunState.preflight`'s, so what the disabled
    /// button says and what a click that beat the disable is told are the same
    /// sentence resolved once. Past it the orchestrator's own `!isRunning` guard
    /// and its briefing gather are the only refusals left, and neither can be
    /// reached from here without one of the answers above having been given first.
    ///
    /// **One more gate past the pre-flight, and it is the last one before the
    /// orchestrator** (P4 Task 9): a language nobody has named a translator
    /// for yet. Left alone, the click would reach `translator.runTranslation`
    /// and its own `translatorIdentity` closure — `ProjectStore
    /// .translatorRole(for:)`, find-or-create — would mint a role signed with
    /// nothing but the language tag uppercased, and the writer would never be
    /// asked. The sheet stands in front of exactly that click; `runTarget`'s
    /// `docId` is captured into the prompt rather than re-read at Confirm, so
    /// the run that eventually happens is the chapter this click named, not
    /// whatever the tree names by the time the writer finishes typing.
    private func run(language: String) {
        notice = nil
        guard let translator else {
            notice = Self.noTranslatorWired
            return
        }
        let session = DepartmentRunSession.read(
            runState: translator.runState, isRunning: translator.isRunning,
            pipeline: pipeline?.status ?? .idle)
        if let refusal = DepartmentRunState.preflight(
            language: language, target: runTarget, session: session) {
            notice = refusal
            return
        }
        guard let docId = runTarget.docId else { return }
        if Self.needsTranslatorName(language: language, in: store.manifest) {
            castPrompt = DepartmentCastPrompt(
                ask: .nameForRun(language: language, docId: docId))
            return
        }
        translator.runTranslation(docId: docId, language: language)
    }

    /// A desk mounted with no orchestrator behind it — the probe mounts, and a
    /// window whose stores never finished loading. Saying so is better than a
    /// button that silently does nothing, which is the whole of Constraint 2.
    static let noTranslatorWired =
        "This window isn\u{2019}t ready to run a translation yet. Try again in a "
        + "moment, or reopen the project."

    /// **Would this language's translator mint with no name?** (P4 Task 9.)
    ///
    /// The same read `EditionStatus.translatorName` answers for a row's own
    /// "No translator yet" line, asked from the other side: `nil` there means
    /// no honest name exists — no stored role, and no preset either — which is
    /// exactly the run that must not reach `TranslatorOrchestrator
    /// .runTranslation` unannounced. A preset language (`es`, `fr`, `de`,
    /// `ja`) always answers non-nil, so it never sees the sheet; a language
    /// whose role is already stored answers non-nil too, named or not — an
    /// unnamed stored role's `effectiveName` falls back to the tag rather than
    /// to `nil` — so a second click on an edition the sheet has already named
    /// runs straight through. A pure read (`EditionStatus`'s own rule): it
    /// never mints, so asking the question changes nothing on disk.
    static func needsTranslatorName(language: String, in manifest: ProjectManifest) -> Bool {
        EditionStatus.translatorName(for: language, in: manifest) == nil
    }

    /// Whether `tag` already has a home on this book — a row the desk has
    /// derived OR a translator the manifest already stores. Both, because the
    /// derived rows can lag the manifest by one `derive()` and Confirm carries
    /// a NAME: a miss here is not a duplicate row, it is `nameTranslator`
    /// renaming somebody the writer did not mean to rename (issue #43, F-G).
    /// Drivable without mounting anything (`DepartmentPaneTests`).
    static func languageAlreadyOnTheDesk(
        _ tag: String, derived: [EditionStatus.LanguageRow], manifest: ProjectManifest
    ) -> Bool {
        let onARow = derived.contains {
            $0.language.caseInsensitiveCompare(tag) == .orderedSame
        }
        return onARow || manifest.storedTranslator(for: tag) != nil
    }

    // MARK: - The cast sheet (P4 Task 9, widened by cast-management)

    /// **Open the sheet on an edition the book does not have yet.**
    private func askForALanguage() {
        notice = nil
        castPrompt = DepartmentCastPrompt(ask: .addLanguage)
    }

    /// **Open the sheet on this edition's translator.**
    ///
    /// The current name is `EditionStatus.translatorName`'s — a pure read, the
    /// same one the row prints — so opening the sheet mints nothing, exactly as
    /// looking at the row does not. Its `nil` (an unlisted language nobody has
    /// named) travels as an empty string, which the prompt reads as a naming
    /// rather than a renaming.
    private func askToRename(language: String) {
        notice = nil
        castPrompt = DepartmentCastPrompt(
            ask: .rename(
                subject: .edition(language: language),
                currentName: EditionStatus.translatorName(
                    for: language, in: store.manifest) ?? ""),
            currentReader: EditionStatus.readerName(for: language, in: store.manifest),
            currentCollator: EditionStatus.collatorName(for: language, in: store.manifest))
    }

    /// **Open the sheet on the book's designer.** `designerRole()` is a read
    /// that answers the preset when nothing is stored, so the field starts with
    /// Tschichold on a project that has never customized anybody.
    private func askToRenameTheDesigner() {
        notice = nil
        castPrompt = DepartmentCastPrompt(ask: .rename(
            subject: .designer, currentName: store.designerRole().effectiveName))
    }

    /// **The sheet's Confirm**, routed by what it was asking.
    ///
    /// Both arms end in the same one visible act — see `nameTranslator` — and
    /// the prompt is cleared FIRST, so a failure reported into `notice` cannot
    /// be drawn behind a sheet that is still up.
    private func confirmCast(_ answer: DepartmentCastAnswer) {
        guard let prompt = castPrompt else { return }
        castPrompt = nil
        switch prompt.ask {
        case .nameForRun(let language, let docId):
            guard let translator else { return }
            Task {
                guard await nameCast(language: language, answer: answer)
                else { return }
                translator.runTranslation(docId: docId, language: language)
            }
        case .addLanguage:
            addLanguage(tag: answer.language ?? "", answer: answer)
        case .rename(.edition(let language), _):
            Task { await nameCast(language: language, answer: answer) }
        case .rename(.designer, _):
            renameTheDesigner(to: answer.name)
        }
    }

    /// **The sheet's Cancel.** Whatever it was standing in front of does not
    /// happen — nothing is minted, nothing runs — and the abandon is said in
    /// words, in the desk's one notice slot (Global Constraint 2).
    private func cancelCast() {
        guard let prompt = castPrompt else { return }
        castPrompt = nil
        switch prompt.ask {
        case .nameForRun(let language, _):
            notice = DepartmentCastCopy.cancelledLine(language: language)
        case .addLanguage:
            notice = DepartmentCastCopy.addCancelledLine
        case .rename(_, let currentName):
            notice = DepartmentCastCopy.renameCancelledLine(currentName: currentName)
        }
    }

    /// **Start an edition** (cast-management): mint its translator, named.
    ///
    /// The tag arrives lowercased and validated by the sheet; re-asking here is
    /// the cheap half of a two-sided guard, because this is the verb that writes
    /// and `TranslationWritePipeline` would refuse an unusable tag much later,
    /// somewhere the writer is no longer looking.
    ///
    /// **An edition already on the desk is a no-op with a sentence, never a
    /// second row.** `translatorRole(for:)` is idempotent, so a duplicate was
    /// never the hazard; renaming somebody the writer had not meant to rename
    /// was — Confirm carries a name, and for a language that already has one
    /// this act would overwrite it silently. The row's own Rename verb is where
    /// that decision belongs. **The check is a union of the desk's derived rows
    /// and the manifest's own stored translators** (issue #43, F-G) — `derive()`
    /// can lag a mint by one pass, and a manifest-only match is exactly the
    /// case where a rename would land unannounced.
    ///
    /// Nothing is said on success: the row appearing in the section this button
    /// sits under IS the answer, and the notice slot is for what the writer
    /// cannot otherwise see.
    private func addLanguage(tag: String, answer: DepartmentCastAnswer) {
        notice = nil
        let language = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard TranslationRecord.isValidLanguageTag(language) else {
            notice = DepartmentCastCopy.unusableTag(tag)
            return
        }
        if Self.languageAlreadyOnTheDesk(
            language, derived: languages, manifest: store.manifest) {
            let spelling = languages.first(where: {
                $0.language.caseInsensitiveCompare(language) == .orderedSame
            })?.language ?? storedTranslatorTag(for: language) ?? language
            notice = DepartmentCastCopy.alreadyOnTheDesk(language: spelling)
            return
        }
        Task { _ = await nameCast(language: language, answer: answer) }
    }

    /// The manifest's own spelling of a stored translator's tag, for the
    /// notice line when nothing has been derived for it yet.
    private func storedTranslatorTag(for language: String) -> String? {
        guard case .translator(let tag) = store.manifest.storedTranslator(
            for: language)?.role else { return nil }
        return tag
    }

    /// **Mint-then-rename, the one visible act** — `ProjectStore
    /// +ProductionRoles`'s own idempotent shape: `translatorRole(for:)` finds
    /// the role if something already minted it (`runTranslation`'s own identity
    /// mint can race it into existence), or mints it fresh, and either way the
    /// very next line is what puts the writer's name on it — never a nameless
    /// role left standing for the writer to find later.
    ///
    /// Answers whether it landed, so a caller with something to do afterwards —
    /// the run the sheet was standing in front of — does it only if the person
    /// it would be signed by actually exists.
    /// **Say who designs this book.**
    ///
    /// The id is `designerRole()`'s, which answers the PRESET's id when nothing
    /// is stored — and that is the whole of how the designer every project has
    /// reaches disk for the first time: `renameProductionRole` materializes the
    /// preset rather than throwing "no such role" (P1's own semantics, and the
    /// one place the preset is written). Reading the id here rather than
    /// spelling `ProductionRole.designerPresetID` keeps a project that has
    /// ALREADY stored a designer renaming that one instead of minting a second.
    private func renameTheDesigner(to name: String) {
        let id = store.designerRole().id
        Task {
            do {
                try await store.renameProductionRole(id: id, to: name)
            } catch {
                _departmentLog.error(
                    "could not rename the designer: \(error, privacy: .public)")
                notice = DepartmentCastCopy.designerRenameFailed
            }
        }
    }

    /// **Mint-then-rename, the one visible act — now for the whole cast.**
    /// `translatorRole(for:)` finds or mints; the very next line names them.
    /// The reader and the collator follow the same shape, gated on whether
    /// the sheet sent a name: a blank field is "change nothing". In practice
    /// that gate almost never closes for a preset language (es/fr/de/ja) —
    /// `askToRename` prefills the reader/collator fields from
    /// `EditionStatus.readerName`/`collatorName`, which fall back to the
    /// preset name when nothing is stored yet, so the writer sees all three
    /// names before confirming and Confirm mints all three together (spec
    /// §1: "Rename … on a language row offers all three"). Only a bespoke
    /// tag with nobody named leaves the two companion fields blank, which is
    /// what actually leaves a rename touching the translator alone. Answers
    /// whether the TRANSLATOR landed — the run the sheet may be standing in
    /// front of needs them and nobody else.
    @discardableResult
    private func nameCast(language: String, answer: DepartmentCastAnswer) async -> Bool {
        do {
            let translator = try await store.translatorRole(for: language)
            try await store.renameProductionRole(id: translator.id, to: answer.name)
        } catch {
            _departmentLog.error(
                "could not name the \(language, privacy: .public) translator: \(error, privacy: .public)")
            notice = DepartmentCastCopy.mintFailed(language: language)
            return false
        }
        await nameCompanion(language: language, name: answer.reader,
                            mint: store.readerRole(for:), what: "reader")
        await nameCompanion(language: language, name: answer.collator,
                            mint: store.collatorRole(for:), what: "collator")
        return true
    }

    private func nameCompanion(
        language: String, name: String?,
        mint: (String) async throws -> ProductionRole, what: String
    ) async {
        guard let name else { return }
        do {
            let role = try await mint(language)
            try await store.renameProductionRole(id: role.id, to: name)
        } catch {
            _departmentLog.error(
                "could not name the \(language, privacy: .public) \(what, privacy: .public): \(error, privacy: .public)")
            notice = DepartmentCastCopy.mintFailed(language: language)
        }
    }

    // MARK: - The design round (Task 4)

    /// **The Design row, resolved.**
    ///
    /// The proposals come from the `.task` above; everything else is read here
    /// so the row follows the session with no event — the same reason
    /// `runTarget` is on this path, and cheaper: `designerRole()` is a scan of
    /// the manifest's own tiny role list (a READ, which never mints — that rule
    /// is `ProjectStore+ProductionRoles`'), and the orchestrator's two
    /// properties are observed stored state.
    private var designRow: DepartmentDesignRow {
        let runState = designer?.runState ?? .idle
        return DepartmentDesignRow.resolve(
            designerName: store.designerRole().effectiveName,
            proposals: proposals,
            runState: runState,
            session: DesignSession.read(runState: runState,
                                        isRunning: designer?.isRunning ?? false),
            hasOpenProposalRound: designer?.hasOpenProposalRound ?? false)
    }

    /// **The click, and everything that can refuse it in words** (Global
    /// Constraint 2) — `run(language:)`'s shape one section up the pane.
    ///
    /// **`language` is `nil`, by this milestone's ruling.** A design round is
    /// the book's; there is no picker on this desk and no per-edition round.
    ///
    /// Past the pre-flight the orchestrator's own `!isRunning` guard is the only
    /// refusal left, and it cannot be reached without the busy answer having
    /// been given first.
    ///
    /// Answers whether the round went, so the pane can decide what to do with
    /// the writer's words: spent on a round that started, kept in the box on one
    /// that was refused.
    private func runDesign(direction: String?) -> Bool {
        notice = nil
        guard let designer else {
            notice = DepartmentDesignRow.noDesignerWired
            return false
        }
        let session = DesignSession.read(runState: designer.runState,
                                         isRunning: designer.isRunning)
        if let refusal = DepartmentDesignRow.preflight(
            session: session,
            briefability: DepartmentDesignRow.briefability(
                store: store, projectURL: projectURL)) {
            notice = refusal
            return false
        }
        designer.runDesign(direction: direction, language: nil)
        return true
    }

    /// **The gate's iterate arm, from the desk.**
    ///
    /// `requestChanges` already answers whether it took the words — it is the
    /// one verb in either loop that does — so the refusal is composed from the
    /// conditions it guards on rather than guessed at. It lands in `notice`, the
    /// desk's one transient-message channel, beside every other refusal a click
    /// earned (Task 3's census).
    ///
    /// **The composition itself moved to `DepartmentDesignRow.sendChanges`** (P4
    /// Task 6) the moment the gate in the centre column grew the same verb: one
    /// spelling of the call and of the three refusals it can earn, reached from
    /// both surfaces.
    private func requestDesignChanges(_ words: String) -> Bool {
        notice = DepartmentDesignRow.sendChanges(words, to: designer)
        return notice == nil
    }

    /// The brief itself, over the desk rather than beside it.
    ///
    /// **`StatementPane`, exactly as `⌘⌥N` and `⌘⌥V` present a statement** — the
    /// same editor host, the same op-logged `Document`, and the same rulings
    /// stratum beneath it, which is where a translator's answered query hardens
    /// into a dated ruling (spec §4). A second editor of this pane's own would
    /// be a second answer to how a statement is edited.
    ///
    /// `subject: .project` is stated rather than left nil: an edition brief is
    /// project-scope by construction (`StatementConvention.newPath` has no row
    /// for `(.editionBrief, .document)`), and saying so here means the pane is
    /// not relying on `effectiveScope`'s coercion to reach the right file.
    ///
    /// **No `bible:`, and no `world:` — by design, not because the desk lacks
    /// them** (Task 7). The bible is Claude's reading of what the *manuscript*
    /// establishes and belongs to the craft intent; a brief is about how the
    /// book reads in another language and establishes nothing about Kelly. The
    /// declared world is the same statement's derivation, so there is no cache a
    /// ruling made here can invalidate. Neither omission is load-bearing:
    /// `StatementPane` refuses a bible under a brief on
    /// `BibleStratum.belongsTo`, so handing one down would change nothing on
    /// screen — which is exactly why the test for that rule threads a store in
    /// rather than mounting this call.
    private func brief(_ open: OpenedBrief) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    openBrief = nil
                } label: {
                    Label("Department", systemImage: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .help("Back to the department desk")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            StatementPane(
                store: store, documentStore: documentStore,
                kind: .editionBrief(open.language),
                subject: .project)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func derive() async {
        // **No error arm, because the walk has no throw left in it** (issue #43,
        // F-D). It used to have one, and what the `catch` did was keep whatever
        // the desk last derived and say nothing — which on a first mount is an
        // empty Languages section reading "No translations yet." over a book
        // with four editions and one chapter Maugham could not open. A
        // per-document failure is now a value: `report.unreadable`, drawn as its
        // own line above the rows.
        // **The config, read once and answered from three times** (imprints P3
        // Task 5): the picker's rows, the book's own language for the compile
        // sheet, and — when an imprint is picked and declares a `sections`
        // allowlist — which documents the language rows are summed over. Three
        // reads of one file would be three chances to describe different
        // versions of it inside one derivation.
        //
        // **Read through the store's `nonisolated` door, and that is not an
        // optimization.** `PublishConfigStore` is an actor, and `await`ing it
        // here puts a foreign-executor suspension in front of the language
        // walk: measured on this branch, that alone was enough for eight
        // mounted cases in `DepartmentRunTests` to press a row the desk had not
        // drawn yet. `derive()` is MainActor-confined and already reads
        // `DesignProposalStore.list()` synchronously three lines down; this
        // read keeps that posture.
        let config = (try? PublishConfigStore.read(in: projectURL)) ?? nil
        let picked = documentStore.uiState.publishImprint
        let manuscript = EditionStatus.manuscriptDocumentIds(in: store.manifest)
        imprints = Self.imprintNames(in: config)
        bookLanguage = Self.sourceLanguage(imprint: picked, in: config,
                                           pieceIDs: manuscript)

        let report = await EditionStatus.languageRows(
            in: store, projectURL: projectURL,
            documentIds: Self.scopedDocumentIds(manuscript, imprint: picked,
                                                in: config))
        languages = report.rows
        unreadable = report.unreadable
        do {
            // Newest first, and tolerant of a folder it cannot read — the
            // store's own posture. Same failure policy as the walk above: the
            // row keeps what it last had rather than losing the writer's
            // standing proposal because one listing failed.
            proposals = try DesignProposalStore(projectURL: projectURL).list()
        } catch {
            _departmentLog.error(
                "could not list the project's design proposals: \(error, privacy: .public)")
        }
    }

    private func present(language: String) async {
        notice = nil
        guard let opened = await Self.openBrief(language: language, in: store) else {
            notice = Self.briefRefusal(language: language)
            return
        }
        openBrief = opened
    }

    // MARK: - The imprint (Task 5)

    /// **Remember which imprint the desk is standing on**, per project.
    ///
    /// A verb of its own rather than a closure body, so the write is drivable
    /// without mounting anything — `openBrief` and `needsTranslatorName`'s
    /// shape. `nil` clears it back to the book, which is what the picker's
    /// first row sets.
    @MainActor
    static func select(imprint: String?, in documentStore: DocumentStore) {
        documentStore.updateUIState { $0.publishImprint = imprint }
    }

    /// **The book's own language, as the compile will read it** — the tag the
    /// sheet offers checked and the one `LanguageSet` substitutes back to the
    /// untranslated body.
    ///
    /// **Resolved, and that is the whole point.** `CompileOrchestrator` builds
    /// its `LanguageSet` with `sourceTag: config.metadata.language` off the
    /// config it has already put through `resolved(imprint:pieceIDs:)` — and
    /// says so in its own comment, "because an imprint may spell the book's own
    /// language differently from the book". An imprint whose `metadata`
    /// fragment carries `"language": "es"` therefore has `es` as its source
    /// tag; a sheet reading the TOP-LEVEL `en` would offer "the book's own
    /// language (English)", send `["en"]`, and `LanguageSet` would take that as
    /// a TRANSLATED edition — a coverage refusal for a translation nobody ever
    /// wrote.
    ///
    /// **Through `resolved` rather than by reading the fragment**, which is
    /// Constraint 1's door (`PublishConfig+Imprints.swift`: "Resolution is the
    /// ONE place imprint-awareness lives"). Reaching into
    /// `imprints[name]?.metadata?["language"]` would be a second, hand-rolled
    /// copy of an RFC 7396 merge patch, and the two would drift the first time
    /// the merge learned anything.
    ///
    /// Anything `resolved` refuses — a name the config no longer defines, a
    /// fragment that leaves `metadata` undecodable — falls back to the book's
    /// own tag, which is `scopedDocumentIds`' fallback for the same case and
    /// for the same reason.
    static func sourceLanguage(imprint: String?, in config: PublishConfig?,
                               pieceIDs: [String]) -> String {
        guard let config else { return PublishConfig.Metadata().language }
        let resolved = (try? config.resolved(imprint: imprint,
                                             pieceIDs: pieceIDs)) ?? config
        return resolved.metadata.language
    }

    /// Every imprint the project declares, sorted — the picker's rows, and
    /// empty for a config that has none or a project with no config at all.
    static func imprintNames(in config: PublishConfig?) -> [String] {
        (config?.imprints.keys).map { $0.sorted() } ?? []
    }

    /// **Which documents the desk sums, given the imprint it is standing on.**
    ///
    /// An imprint's `sections` block is an ALLOWLIST (`PublishConfig
    /// .resolved(imprint:pieceIDs:)` materializes every id it does not name as
    /// `include: false`), so a desk standing on one must report the coverage of
    /// what would actually be compiled: an edition is "3 missing" against the
    /// whole novel and complete against the pamphlet cut from it.
    ///
    /// **Filtered against `all` rather than read out of the allowlist**, which
    /// keeps the manifest's own order and silently drops an id the imprint
    /// names but the book no longer holds — a stale entry in a hand-edited
    /// config must not put a chapter that does not exist onto the desk.
    ///
    /// An imprint with NO `sections` inherits the book's own map, so it is the
    /// whole book — the same answer a `nil` imprint gets, and a name the config
    /// does not define falls back to it too: the picker's rows come from that
    /// same config, so a stale `UIState` name is a choice the writer can no
    /// longer see, and summing the whole book is the honest reading of it.
    /// **Which imprint the picker is standing on, given what was persisted.**
    ///
    /// An imprint is declared by editing `config.json` by hand, so one can be
    /// deleted out from under a `UIState.publishImprint` that names it. The
    /// `Picker`'s selection then matched no tag it drew and it went BLANK — not
    /// the imprint, not "Book", nothing, with no way to tell which of the two
    /// the desk was actually about.
    ///
    /// `nil` is the honest answer, and it is the one the rest of the desk had
    /// already reached on its own: `scopedDocumentIds` sums the whole book for a
    /// name the config does not define, and `sourceLanguage` falls back to the
    /// book's own tag. This makes the picker agree with them rather than
    /// disagree in silence.
    ///
    /// The persisted value is deliberately NOT rewritten — a writer who
    /// temporarily renamed an imprint gets their choice back when they rename it
    /// back, and a `body` that wrote to the store would be a write on the draw
    /// path.
    static func selection(persisted: String?, among imprints: [String]) -> String? {
        guard let persisted, imprints.contains(persisted) else { return nil }
        return persisted
    }

    static func scopedDocumentIds(_ all: [String], imprint: String?,
                                  in config: PublishConfig?) -> [String] {
        guard let imprint,
              let sections = config?.imprints[imprint]?.sections else { return all }
        return all.filter { sections.keys.contains($0) }
    }

    /// **The door.** Find-or-create, then present.
    ///
    /// Creating on the click is the right moment: the writer clicked because
    /// they are about to write register and idiom policy into it, and a brief
    /// that mints on the first keystroke instead (`StatementEditorHost`'s own
    /// route for a statement that does not exist) is the same file one moment
    /// later — but the desk would have nothing to name in the meantime.
    ///
    /// **Once, ever.** `createStatement` is find-or-create and idempotent, so
    /// the second click finds what the first made; a door that minted per click
    /// would leave a second empty `edition-brief-es-2.md` beside the writer's
    /// own, because `vacantStatementPath` steers a new mint around an occupied
    /// path — and the next visit would open the empty one.
    ///
    /// Static and free of view state so the rule is drivable without mounting
    /// anything (`DepartmentPaneTests`).
    @MainActor
    static func openBrief(language: String, in store: ProjectStore) async -> OpenedBrief? {
        do {
            let statement = try await store.createStatement(
                kind: .editionBrief(language), scope: .project)
            return OpenedBrief(language: language, statementID: statement.id)
        } catch {
            _departmentLog.error(
                "could not open the \(language, privacy: .public) edition brief: \(error, privacy: .public)")
            return nil
        }
    }

    /// What the desk says when the door would not open. It names the edition,
    /// because a writer with three of them needs to know which one refused.
    static func briefRefusal(language: String) -> String {
        "Couldn’t open the "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + " edition brief. Check that the project folder is still where it was."
    }
}
