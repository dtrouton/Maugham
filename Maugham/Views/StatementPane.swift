import SwiftUI
import MaughamCore

/// The right pane for a statement — Intent (⌘⌥N), Visual Language (⌘⌥V), or an
/// edition brief reached from the department desk's language row
/// (publish-department P4 Task 2); M1A spec §4.3.
///
/// **Scope follows the window's subject, and this pane has no say in it.** The
/// tree is the subject-picker (persona shell §3.3): select a chapter and Intent
/// shows the chapter's, select the project row and it shows the book's. Visual
/// language is project-scope, so it simply shows.
///
/// It carried a `[<chapter> | Project]` switch of its own until slice 1, and
/// that switch was **a workaround for a hole in the tree** — there was no way to
/// select the project, so the one subject a writer could not otherwise reach had
/// to be reachable from here. The project row closes the hole at the cause, and
/// a second subject-picker beside it is two controls that can disagree about
/// what the window is about. Its removal is also what unblocks
/// `Open`-sets-scope, which collided with it for three fix rounds
/// (`ProjectWindow.openPromotedArtifact`).
///
/// **The header says which scope resolved, because the tree's subject and this
/// pane's scope can legitimately differ.** A group, an id from another project
/// and visual language on any selection all resolve to the project; without a
/// header the writer would be reading the book's intent while the tree named a
/// chapter, with nothing on screen saying so.
///
/// **Absence is valid and stays valid.** A scope with no statement shows an
/// empty editor that mints on the first keystroke, not a "create intent" button
/// and not a nag. `read_craft_intent` already tells Claude that absence is "a
/// valid, deliberate state — do not invent a standard on their behalf", and the
/// UI must not contradict its own MCP surface.
struct StatementPane: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let kind: Statement.Kind
    /// The window's subject, exactly as the tree wrote it. May name a group or
    /// an item from another project — both resolve to the project, see
    /// `effectiveScope`.
    let subject: BinderSubject?
    /// The bible stratum's ledger and the derivation cache the ruling verbs
    /// drop (declared-world Task 6). **Optional, and a nil is a pane with two
    /// strata rather than three** — `ProjectWindow` owns both and every other
    /// mount (the `StatementMountFixture` probes, previews) has none. A default
    /// of `nil` is honest here in a way `RulingPerformer`'s undefaulted `world`
    /// is not: this is a SURFACE deciding what it can show, not a write path
    /// deciding whether to invalidate.
    var bible: BibleStore? = nil
    var world: DeclaredWorldStore? = nil

    /// Which statement this pane is showing.
    ///
    /// Pure and static so it can be asked over the whole product of its inputs
    /// rather than the one path a plan happened to name — the shape that found
    /// both of `ProjectWindow`'s routing bugs. `StatementPaneTests` is that test,
    /// and `StatementPaneSelectionDeliveryTests` is the one that drives the same
    /// rule through the binder, the binding and the mounted editor.
    ///
    /// A subject that is not a manuscript document in this project — the
    /// project itself, a group, an unknown id, no selection at all — resolves to
    /// the project rather than being asked for: `createStatement` throws
    /// `.structureMissing` for one, and a pane that offered it would be offering
    /// a keystroke that fails.
    ///
    /// **`.project` is its own arm rather than a fall-through**, and that is
    /// deliberate: it reaches the same answer either way today, and an implicit
    /// `.project` and a decided one look identical right up until somebody gives
    /// the project row an id that *is* in `structure`.
    static func effectiveScope(
        kind: Statement.Kind,
        subject: BinderSubject?,
        structure: [StructureItem]
    ) -> Statement.Scope {
        // Visual language is project-scope only — the book has one look (§2.1).
        // An `.unknown` kind (a newer build's) is retained and ignored
        // everywhere else, and has no document storage either.
        guard case .intent = kind else { return .project }
        switch subject {
        case .none: return .project
        case .project: return .project
        case .item(let id):
            guard id != StatementPane.noSelectionSentinel,
                  let item = TreeWalk.find(id: id, in: structure),
                  item.type == .document
            else { return .project }
            return .document(id)
        case .research:
            // A research item carries no craft intent of its own — intent is
            // a document/group affair, and a research subject is neither.
            // Permanent, not interim: unlike `validSubject`, there is no
            // research-tree validation this could grow into.
            return .project
        }
    }

    /// The `"__no-selection__"` literal, refused here as an id.
    ///
    /// **Defence, and no longer a value this pane is fed.** It was: this pane
    /// took a `String?` that `ProjectWindow` had already `??`-substituted, so
    /// the sentinel arrived here in the ordinary course of no selection. It
    /// takes the typed subject now, and nothing constructs
    /// `BinderSubject.item("__no-selection__")` — the substitution produces a
    /// `String` for the panes that want one and never a subject. Kept because
    /// removing it is a claim about every id that can reach `structure`, and
    /// because `TreeWalk` would refuse it anyway; not kept because anything
    /// exercises it.
    ///
    /// The literal itself lives on `BinderSubject`, which is where the
    /// substitution that produces it happens; this is the same string and not a
    /// second one.
    static let noSelectionSentinel = BinderSubject.noDocumentSubject

    /// What the header says, given the scope that actually resolved.
    ///
    /// **Derived from the resolved SCOPE, not from the selection**, which is the
    /// whole reason it can be trusted: a second walk of the structure from the
    /// subject — which is what the departed scope switch's label did — is a
    /// second answer to "is this a document?", free to disagree with
    /// `effectiveScope` about the very thing the sentence claims. Given
    /// `.document(id)` the item exists by construction; the title-less arm is
    /// unreachable rather than a fallback, and says nothing it cannot support.
    ///
    /// Static and pure, like `effectiveScope`, so it can be asked over the
    /// product of its inputs.
    static func headerCaption(
        kind: Statement.Kind,
        scope: Statement.Scope,
        structure: [StructureItem]
    ) -> String {
        if case .visualLanguage = kind { return "How this book looks" }
        // **An edition brief names its edition** (publish-department P4 Task
        // 2). Without an arm of its own the Spanish brief wore the craft
        // intent's sentence — "What this project is going for" — over a
        // different document entirely, and the header is the only thing on
        // screen saying which statement the editor beneath it is bound to.
        // Scope-blind, exactly as visual language's is, because `effectiveScope`
        // coerces every subject to `.project` for any kind but `.intent`.
        if case .editionBrief(let language) = kind {
            return "How this book reads in "
                + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
        }
        // **The ledger is about the writer, not about the book** (editorial
        // letter P2). Scope-blind for the same reason the two above are:
        // `effectiveScope` coerces every subject to `.project` for any kind but
        // `.intent`, so without an arm here the ledger wore the craft intent's
        // sentence over a different document entirely.
        if case .lessons = kind { return "What I've learned" }
        guard case .document(let id) = scope else {
            return "What this project is going for"
        }
        guard let item = TreeWalk.find(id: id, in: structure) else {
            return "What this document is going for"
        }
        return "What “\(item.title)” is going for"
    }

    private var scope: Statement.Scope {
        Self.effectiveScope(
            kind: kind, subject: subject,
            structure: store.manifest.structure)
    }

    /// Which paragraph ids are currently live in this statement's scope — fed
    /// to `RulingsStratumView` so it can tell an orphaned directive from a
    /// live one. `nil` until the first resolve; see
    /// `RulingsStratum.partition`'s doc comment for why that must never read
    /// as "orphaned".
    @State private var liveParagraphIds: Set<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            proposalGate
            // **No `.id()`, deliberately.** Keying the host on the scope looked
            // right — a scope switch does want a fresh `Document` — but it made
            // the switch a REMOUNT, which splits the close of the outgoing
            // document (the departing view's `.onDisappear`) from the load of
            // the incoming one (the arriving view's `.task`) with no ordering
            // between them: SwiftUI inserts the new subtree and removes the old
            // in the same update, so the load routinely started first and two
            // `Document`s could be live on one path. One host handles the switch
            // itself, sequentially — see `StatementEditorHost.reconcile`.
            StatementEditorHost(
                store: store, documentStore: documentStore,
                kind: kind, scope: scope)
                // **The one `.id()` the paragraph above allows, and it is a
                // different case entirely.** `hostGeneration` never moves for a
                // scope change; it moves only when an Adopt CREATED the
                // statement this host had already resolved as absent (see
                // `adopt`). The hazard above is the close of an outgoing
                // `Document` racing the load of an incoming one — and on that
                // one path the host bound no `Document` at all, so there is
                // nothing to close and nothing to race.
                .id(hostGeneration)
            strata
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: liveParagraphTaskKey) {
            await resolveLiveParagraphIds()
        }
        .task(id: ProposalTaskKey(
            slot: Self.proposalSlot(kind: kind, scope: scope),
            reloads: proposalReloads, windowResolved: window != nil)) {
            reloadProposal()
        }
        // `.project`-scoped: a window on another book must not re-read this
        // one's slot, and a closed window must read nothing at all (tripwire
        // 21). It is what lets a tool staging a proposal behind an open pane
        // draw the gate with no remount and no poll.
        .onProjectEvent(.maughamStatementProposalsChanged, url: store.url, window: window) { _ in
            proposalReloads += 1
        }
        // **A sentence about the last proposal must not stand over the next
        // one, or over another statement.** Both clears are `onChange` rather
        // than a line in `reloadProposal`, which would race: the verbs set
        // their sentence in a `Task` continuation, while the `.task` above
        // restarts on SwiftUI's own schedule, so a clear inside the read could
        // land after the write it is supposed to precede. A proposal ARRIVING
        // is the transition that matters — one leaving is a verb about to say
        // what it did.
        .onChange(of: pendingProposal) { _, arriving in
            if arriving != nil { proposalNotice = nil }
        }
        .onChange(of: Self.proposalSlot(kind: kind, scope: scope)) { _, _ in
            proposalNotice = nil
        }
        .background(WindowAccessor(window: $window))
    }

    /// Everything that can move an orphan verdict, so the `.task` below
    /// re-fires whenever any of it changes — not only when the (kind, scope)
    /// pair itself changes.
    ///
    /// **`kind|scope` alone missed the commonest Author-persona shape**: the
    /// writer deletes a paragraph in the open manuscript editor while the
    /// Intent pane sits beside it, and a directive anchored there must stop
    /// reading as an ordinary ruling without the pane remounting. Fixed by
    /// widening the key to the two things that can change under a mounted
    /// pane with the scope held fixed: the statement's own set of directive
    /// paragraph ids (`directiveIds` — a newly-typed directive must get
    /// checked too, not only a stale one), and every OPEN manuscript
    /// document's paragraph SEQUENCE (`openDocuments`) — a closed document
    /// cannot change under the pane, and opening or closing one changes the
    /// key on its own.
    ///
    /// No new notification is invented for this (tripwire 21's shape: nothing
    /// fires on an ordinary edit, and a broadcast for one would be a second
    /// unscoped-post defect waiting to happen). Instead this reads live
    /// `@Observable` state that is already in memory: `documentStore
    /// .document(forDocId:)` answers nil for a closed document with no I/O,
    /// and `Document.sequence` is a plain observed property, so reading it
    /// here — on a `body` path — REGISTERS an observation and touches no
    /// disk. `rulings` is the same fringe-reader `strata` already calls
    /// synchronously in `body`. What still runs only inside the `.task` is
    /// the actual walk that resolves a CLOSED document's derived state
    /// (`resolveLiveParagraphIds`, tripwire 4 unchanged).
    private struct LiveParagraphTaskKey: Equatable {
        let scopeKey: String
        let directiveIds: Set<String>
        let openDocuments: [String: [String]]
    }

    private var liveParagraphTaskKey: LiveParagraphTaskKey {
        var openDocuments: [String: [String]] = [:]
        switch scope {
        case .document(let id):
            if let document = documentStore.document(forDocId: id) {
                openDocuments[id] = document.sequence
            }
        case .project, .unknown(_):
            for docId in EditionStatus.manuscriptDocumentIds(in: store.manifest) {
                if let document = documentStore.document(forDocId: docId) {
                    openDocuments[docId] = document.sequence
                }
            }
        }
        return LiveParagraphTaskKey(
            scopeKey: "\(kind.rawValue)|\(scope.rawValue)",
            directiveIds: Set(rulings.compactMap(\.paragraphId)),
            openDocuments: openDocuments)
    }

    /// Resolves which paragraph ids currently exist for this statement's
    /// scope, so `RulingsStratumView` can tell an orphaned directive from a
    /// live one. **Runs in a `.task`, never on a body path** (tripwire 4) —
    /// the read walks a manuscript document's derived state, which is I/O.
    ///
    /// `.document(id)` reads that one document's ids. `.project` (and
    /// `.unknown`, a newer build's scope) reads the UNION of every manuscript
    /// document's ids — an edition brief's directives can anchor into any
    /// chapter, not just one. A document that fails to resolve is skipped
    /// rather than failing the whole read, the shape
    /// `EditionStatus.documentRows` already uses for the same reason.
    private func resolveLiveParagraphIds() async {
        guard StatementEssay.carriesRulings(kind) else {
            liveParagraphIds = nil
            return
        }
        switch scope {
        case .document(let id):
            guard let state = try? currentParagraphState(
                documentId: id, store: store, documentStore: documentStore,
                projectURL: store.url)
            else {
                liveParagraphIds = nil
                return
            }
            liveParagraphIds = Set(state.sequence)
        case .project, .unknown(_):
            var ids = Set<String>()
            for docId in EditionStatus.manuscriptDocumentIds(in: store.manifest) {
                if let state = try? currentParagraphState(
                    documentId: docId, store: store, documentStore: documentStore,
                    projectURL: store.url) {
                    ids.formUnion(state.sequence)
                }
            }
            liveParagraphIds = ids
        }
    }

    // MARK: - The proposal gate (translation pipeline P5, spec §10)

    /// Which proposal slot this pane's statement can have, or nil.
    ///
    /// Pure and static, like `effectiveScope` and `headerCaption`, so
    /// `StatementPaneTests` asks it over the product of its inputs rather than
    /// the one path a plan happened to name. Craft intent has no slot at all —
    /// it is the writer's own yardstick and `ProposableStatement` has no case
    /// to reach it with — and a `.document` scope is intent by construction, so
    /// a brief and the visual language are project-scope only.
    static func proposalSlot(kind: Statement.Kind, scope: Statement.Scope) -> ProposableStatement? {
        guard case .project = scope else { return nil }
        return ProposableStatement(kind: kind)
    }

    /// The proposal standing for this pane's statement, or nil. Read in a
    /// `.task`, never on a body path — see `reloadProposal`.
    @State private var pendingProposal: StatementProposalStore.Proposal?
    /// Bumped by `.maughamStatementProposalsChanged` so the `.task` re-keys and
    /// re-reads the slot. A counter rather than an `await` in the notification
    /// closure, `DepartmentPaneHost`'s idiom: the `.task` owns cancellation.
    @State private var proposalReloads = 0
    /// What the gate last said — a refusal, or the sentence an adoption or a
    /// discard left behind. Sticky until the slot itself changes, because the
    /// banner it was drawn in is gone by the time an Adopt has anything to say.
    @State private var proposalNotice: String?
    /// An adoption in flight. It disables both verbs, which is also the guard
    /// against two `adopt` calls passing `StatementProposalGate`'s pending
    /// check at once: the second press cannot happen, and `adopt` refuses one
    /// that somehow does.
    @State private var proposalBusy = false
    /// Bumped ONLY by an Adopt that created the statement — see the `.id()` in
    /// `body`.
    @State private var hostGeneration = 0
    /// This pane's hosting window, for the ADR 0021 receive helper's liveness
    /// guard — resolved through `WindowAccessor` because a cached `nil` is not
    /// a close check (`MaughamEvent.isLive`).
    @State private var window: NSWindow?
    @Environment(\.undoManager) private var undoManager

    private struct ProposalTaskKey: Equatable {
        let slot: ProposableStatement?
        let reloads: Int
        /// **Whether this pane can hear the changed event yet**, and it is in
        /// the key because until it can, a proposal staged behind it is a post
        /// nothing catches. `WindowAccessor` resolves the window on an async
        /// hop after the mount, and `MaughamEvent.shouldDeliver` drops a
        /// `.project` post whose receiver has no live window — so a tool that
        /// stages one in the pane's first frames would leave the gate blank
        /// until something else happened to re-key this task. Re-reading the
        /// slot the moment the window arrives costs one JSON read, once, and
        /// closes the window (measured: the resolve landed 20 ms after the
        /// post in `test_discardClearsTheGateAndLeavesTheStatementAlone`).
        let windowResolved: Bool
    }

    /// Reads the slot. **In a `.task`, never on a body path** (tripwire 4) — it
    /// is a JSON read under `.maugham/`. Re-keyed by the changed event, so a
    /// tool staging a proposal behind an open pane draws the gate without a
    /// remount and without a poll.
    private func reloadProposal() {
        guard let slot = Self.proposalSlot(kind: kind, scope: scope) else {
            pendingProposal = nil
            return
        }
        pendingProposal = StatementProposalStore(projectURL: store.url).pending(for: slot)
    }

    /// The gate above the editor: the banner while a proposal stands, and
    /// whatever the last verb said once it does not.
    ///
    /// The `current:` text is `store.statementText(of:)` — the same fringe read
    /// `rulings` already makes synchronously in `body`, for the same reason it
    /// is safe there (the live `Document` when the pane has one open, else the
    /// derivation cache), and with the same `try?`: an unreadable statement
    /// draws a diff against nothing rather than a second copy of the editor's
    /// own refusal.
    @ViewBuilder
    private var proposalGate: some View {
        if let proposal = pendingProposal {
            let statement = store.statement(kind: kind, scope: scope)
            StatementProposalBanner(
                proposal: proposal,
                current: statement.flatMap { try? store.statementText(of: $0) },
                statementExists: statement != nil,
                now: Date(),
                notice: proposalNotice,
                busy: proposalBusy,
                onAdopt: { adopt(proposal) },
                onDiscard: { discard(proposal) })
            Divider()
        } else if let proposalNotice {
            // The banner is where a notice belongs while there is one; an Adopt
            // and a Discard both END the banner, so their own sentence would
            // otherwise be written to a state nothing renders.
            Text(proposalNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
    }

    /// The writer's Adopt. `StatementProposalGate` does the writing; this owns
    /// the busy flag, the sentence, and the one case the host cannot see for
    /// itself.
    private func adopt(_ proposal: StatementProposalStore.Proposal) {
        // Re-entrancy: the buttons are disabled while this is true, so this is
        // the belt for a press that arrives anyway (a synthesised one, an
        // accessibility client). Two adoptions can otherwise both pass the
        // gate's own pending check before either discards the slot.
        guard !proposalBusy else { return }
        proposalBusy = true
        let undoManager = undoManager
        Task { @MainActor in
            defer { proposalBusy = false }
            do {
                let adoption = try await StatementProposalGate.adopt(
                    proposal, store: store, world: world,
                    undoManager: undoManager, workTaskSink: { _ in })
                proposalNotice = StatementProposalCopy.adoptedLine(
                    glossary: adoption.glossaryAppended)
                if adoption.created {
                    // **The host resolved this scope as having no statement,
                    // and nothing tells it otherwise.** `reconcile` re-runs on
                    // a SCOPE change alone, and the scope has not changed — so
                    // the editor would go on showing the empty draft it mounted
                    // over a statement that now has the adopted words in it.
                    // Safe as a remount precisely because `created` is true:
                    // the host bound no `Document` for an absent statement, so
                    // the close/load ordering hazard `body` describes has
                    // nothing to close.
                    hostGeneration += 1
                }
            } catch {
                proposalNotice = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            }
            reloadProposal()
        }
    }

    /// The writer's Discard. Clears the slot and nothing else — no statement of
    /// theirs is touched, which is what `discardHelp` promises.
    private func discard(_ proposal: StatementProposalStore.Proposal) {
        do {
            try StatementProposalGate.discard(proposal.kind, store: store)
            proposalNotice = StatementProposalCopy.discardedLine
        } catch {
            proposalNotice = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        }
        reloadProposal()
    }

    // MARK: - The two strata under the essay (declared-world Task 6)

    /// The writer's rulings and Claude's readings, beneath the editor.
    ///
    /// **Both are absent when empty, and neither has an empty state.** No
    /// heading over nothing, no "no rulings yet" — a writer who has never ruled
    /// meets the pane exactly as M1A shipped it, which is the same rule the
    /// editor above follows about a statement that does not exist.
    ///
    /// **Bounded and scrollable, so the strata cannot push the essay off the
    /// pane.** The editor is the surface the writer came here for; a long ledger
    /// squeezing it to a line would be the tail wagging the dog. The ceiling is
    /// on the two together rather than on each, so a piece with one ruling and
    /// twenty facts still spends its allowance where the content is.
    @ViewBuilder
    private var strata: some View {
        if !rulings.isEmpty || !bibleFacts.isEmpty {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !rulings.isEmpty {
                        RulingsStratumView(
                            rulings: rulings, kind: kind, scope: scope, store: store,
                            world: world, liveParagraphIds: liveParagraphIds)
                    }
                    if let bible, !bibleFacts.isEmpty {
                        BibleStratumView(
                            facts: bibleFacts, scope: scope, store: store,
                            bible: bible, world: world)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.strataCeiling)
        }
    }

    /// Roughly four rows. Past it the strata scroll rather than grow.
    static let strataCeiling: CGFloat = 260

    /// The rulings this statement carries **right now**.
    ///
    /// Read through `ProjectStore.statementText` (tripwire 20 — the op log, or
    /// the pane's own live `Document`, never the `.md`), which is also what
    /// makes this list live: with the statement open the reader prefers its
    /// `Document`, whose `@Observable` `displayText` is the same value the
    /// editor above binds. So a ruling landing from a run while the pane is up
    /// invalidates this body with no event, no poll and no push — the property
    /// `IntentStrip.line` documents at length, arriving here through the same
    /// reader. (`test_aRulingReachesTheMountedPane`.)
    ///
    /// Empty for visual language, and by the one rule rather than a second
    /// spelling of it: `StatementEssay.carriesRulings` says which kinds have
    /// strata, and the editor's own split asks the same question.
    private var rulings: [Ruling] {
        guard StatementEssay.carriesRulings(kind),
              let statement = store.statement(kind: kind, scope: scope)
        else { return [] }
        // RULING-54 made `statementText` throw on an unreadable file. The
        // pane's EDITOR half surfaces that refusal through its own load path;
        // this strata read is a fringe reader, so an unreadable file renders
        // no ruling rows rather than a second copy of the same alert.
        guard let text = try? store.statementText(of: statement) else { return [] }
        return RulingsStratum.rows(in: text)
    }

    /// Claude's readings for the scope on screen.
    ///
    /// `_ = bible.version` is the observation — `allFacts()` returns an array
    /// the store rebuilds, so nothing in it is observable on its own and a body
    /// that read only the array would render once and never again
    /// (`DiagnosticsPane.rows`' idiom, and `test_thePaneRerendersWhenEither
    /// StoreBumpsItsVersion` is what holds it).
    ///
    /// **The bible belongs to the craft intent, and it is asked so directly**
    /// (publish department, Task 7). This gated on
    /// `StatementEssay.carriesRulings` — right by coincidence while intent was
    /// the only kind with strata, and a live defect the moment the edition brief
    /// joined it: a brief carries rulings and establishes nothing about the
    /// manuscript, so the proxy would have shown the project's whole bible under
    /// a statement about Spanish register. `BibleStratum.belongsTo` is the
    /// question this actually wants, and it lives with the stratum whose rule it
    /// is.
    private var bibleFacts: [BibleFact] {
        guard BibleStratum.belongsTo(kind), let bible else { return [] }
        _ = bible.version
        return BibleStratum.facts(for: scope, in: bible.allFacts())
    }

    /// One line, always — never a control, and never nothing.
    ///
    /// It was a `Picker` when a document was selected and a caption otherwise,
    /// so deleting the picker would have left a selected document with no header
    /// at all: an empty `VStack` above the divider, and the writer's only cue to
    /// *whose* intent they are reading gone with the control that had been
    /// setting it. Naming the resolved scope is what the switch was really doing
    /// for the reader; setting it is now the tree's job.
    private var header: some View {
        Text(Self.headerCaption(
            kind: kind, scope: scope, structure: store.manifest.structure))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
