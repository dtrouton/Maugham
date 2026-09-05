import SwiftUI
import MaughamCore

struct DetailPaneToggle<Inspector: View>: View {
    @Bindable var store: ProjectStore
    @Binding var segment: DetailSegment
    @Binding var selectedSubject: BinderSubject?
    /// The item the tree names, converted once at `ProjectWindow`'s boundary.
    /// `nil` for the project and for no selection alike.
    let activeManuscriptItemId: String?
    /// The window's working mode. Decides which segments the picker offers —
    /// see `visibleSegments(persona:)`.
    let persona: Persona
    // History pane props — optional so callers that don't need history can omit them.
    let projectURL: URL?
    /// The non-optional document id the per-document panes take, from the same
    /// boundary. **Not re-substituted here** — this view used to apply a second
    /// `?? "__no-selection__"` to a value the window had already substituted,
    /// which is two spellings of one rule three hops apart.
    let activeDocId: String
    let allDocIds: [String]
    let device: String
    let session: String
    let docPaths: [String: String]
    let documentStore: DocumentStore?
    /// Editor control model — supplies the active translation language and the
    /// per-paragraph freshness entries the Translation segment reads (ADR 0017).
    /// Optional so callers that don't surface translation review can omit it.
    let editorControl: EditorControl?
    /// The window's compiler (M2) — optional so callers that don't surface the
    /// Diagnostics segment (the `StatementMountFixture` probes, in particular)
    /// can omit it. `diagnosticsStore` is `orchestrator.diagnostics` at the
    /// caller's boundary rather than re-read here, so the two cannot disagree
    /// about which store a run replaces into.
    let compilerOrchestrator: CompilerOrchestrator?
    let diagnosticsStore: DiagnosticsStore?
    /// The Intent pane's two lower strata (declared-world Task 6) — Claude's
    /// bible entries, and the derivation cache the ruling verbs drop. Optional
    /// for `diagnosticsStore`'s reason: a caller that surfaces no statement
    /// pane (the `StatementMountFixture` probes) can omit them, and a nil is a
    /// pane with the writer's two strata rather than three.
    let bibleStore: BibleStore?
    let declaredWorldStore: DeclaredWorldStore?
    /// The window's translator and its record of finished rounds (publish
    /// department P4 Task 3) — the pair the department desk's Run needs, threaded
    /// exactly as `compilerOrchestrator`/`diagnosticsStore` are and for the same
    /// reason: a round is started from this column while the session that answers
    /// it belongs to the window, which is the only thing that can tear it down.
    ///
    /// Defaulted, so the probe callers that mount this view without a window
    /// behind it keep compiling and get a desk that reads without acting.
    var translator: TranslatorOrchestrator? = nil
    var translationRuns: TranslationRunLog? = nil
    /// The window's designer (publish department P4 Task 4) — the desk's Design
    /// row runs it. Threaded and defaulted exactly as `translator` is; its own
    /// record of finished rounds is the proposal it stages, which the desk
    /// re-derives, so there is no log beside it.
    var designer: DesignerOrchestrator? = nil
    /// The window's translation pipeline (translation pipeline P3), threaded and
    /// defaulted exactly as `translator` is and travelling to the same desk. The
    /// desk needs it for the one-round-at-a-time gate: a round's cold legs hold
    /// no translator session, so without it every row offers Run while a reader
    /// is out.
    var pipeline: TranslationPipeline? = nil
    /// The window's cold-call runner (translation pipeline P4 Task 6) — the
    /// Translation pane's two spot-checks ask through it. Threaded and
    /// defaulted exactly as `pipeline` is, and for the same reason: it is the
    /// window's, and a pane that made one of its own would be a second session
    /// nothing tears down.
    var coldCall: ColdCall? = nil
    /// **Where the desk's Show sends a proposal** (publish-department P4 Task 5)
    /// — the window's centre column, which this view is not in. Threaded and
    /// defaulted exactly as `onSetActivePass`/`onSetPassState` are, and for the
    /// same reason: what the centre shows is `ProjectWindow`'s question, and a
    /// right-column pane writing it would be a second place it is decided.
    var onShowDesignProposal: (DesignProposalStore.Proposal) -> Void = { _ in }
    /// **Where the desk's other Show sends a translation round** (translation
    /// pipeline P4) — the same centre column, threaded and defaulted exactly as
    /// `onShowDesignProposal` is, and for the same reason: what the centre
    /// shows is `ProjectWindow`'s question.
    var onShowTranslationRound: (TranslationRound) -> Void = { _ in }
    /// The gear menu's persisted choice, and the write-back when it changes —
    /// a value + closure rather than a `Binding` so every existing call site
    /// keeps compiling with the defaults below.
    let compilerModel: CompilerModelChoice
    var onCompilerModelChange: (CompilerModelChoice) -> Void = { _ in }
    /// Which pinned reference the writer has promoted into the assistant column
    /// (M2 §6.2). An object rather than a `Binding` because the shelf is in this
    /// column and the column it promotes into is the window's CENTRE one — see
    /// `AssistantColumnModel`. Optional so a caller that surfaces no References
    /// segment (the `StatementMountFixture` probes) can omit it.
    let assistant: AssistantColumnModel?
    /// How wide the annotations queue is looking (M3 P2 Task 7). Window state
    /// on `ProjectWindow` so Task 9's board click-through can set it from the
    /// centre column; `.constant(.document)` for the probe callers that mount
    /// this view without a window behind it.
    @Binding var annotationScope: AnnotationScope
    /// Record which pass a piece is being reviewed through — the round
    /// cockpit's pass picker (M4 P2 Task 3), `(pieceId, passId)`.
    ///
    /// A closure rather than a store write here: `UIState.activePassMemory`
    /// has ONE writer, `ProjectWindow.recordActivePass`, and the board's chip
    /// click already goes through it. A second `updateUIState` in this file
    /// would be two spellings of one rule, and the RUN reads only one of them.
    var onSetActivePass: (String, String) -> Void = { _, _ in }
    /// The queue's pass-order nudge's own verbs (pass-order nudge gains its
    /// verbs) — `(docId, passId, state)`. Threaded rather than written here
    /// for the same reason as `onSetActivePass`: `setPassState` is a closed
    /// three-file census (`PersonaPaneRegistryTests.passStateWritingFiles`)
    /// and a write in THIS file would be a fourth. `ProjectWindow` supplies
    /// the same `store.setPassState` the board's chip menu and the two
    /// Inspector arms already call.
    var onSetPassState: (String, String, PassState?) -> Void = { _, _, _ in }
    @ViewBuilder var inspectorContent: () -> Inspector

    /// **Whether a visual-language proposal is standing** (translation
    /// pipeline P5) — the Visual Language segment's own badge, read and kept
    /// fresh by `VisualLanguageProposalModifier` below.
    @State private var visualLanguageProposed = false
    /// This picker's hosting window, for the ADR 0021 receive helper's
    /// liveness guard — resolved through `WindowAccessor` because a cached
    /// `nil` is not a close check (`MaughamEvent.isLive`).
    @State private var window: NSWindow?

    /// Local transcription exists only on Apple Silicon (see DocumentStore.makeTranscriber).
    private static var localTranscriptionAvailable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    init(
        store: ProjectStore,
        segment: Binding<DetailSegment>,
        selectedSubject: Binding<BinderSubject?>,
        activeManuscriptItemId: String?,
        persona: Persona = .default,
        projectURL: URL? = nil,
        activeDocId: String = BinderSubject.noDocumentSubject,
        allDocIds: [String] = [],
        device: String = "",
        session: String = "",
        docPaths: [String: String] = [:],
        documentStore: DocumentStore? = nil,
        editorControl: EditorControl? = nil,
        compilerOrchestrator: CompilerOrchestrator? = nil,
        diagnosticsStore: DiagnosticsStore? = nil,
        bibleStore: BibleStore? = nil,
        declaredWorldStore: DeclaredWorldStore? = nil,
        translator: TranslatorOrchestrator? = nil,
        translationRuns: TranslationRunLog? = nil,
        designer: DesignerOrchestrator? = nil,
        pipeline: TranslationPipeline? = nil,
        coldCall: ColdCall? = nil,
        onShowDesignProposal: @escaping (DesignProposalStore.Proposal) -> Void = { _ in },
        onShowTranslationRound: @escaping (TranslationRound) -> Void = { _ in },
        compilerModel: CompilerModelChoice = .standard,
        onCompilerModelChange: @escaping (CompilerModelChoice) -> Void = { _ in },
        assistant: AssistantColumnModel? = nil,
        annotationScope: Binding<AnnotationScope> = .constant(.document),
        onSetActivePass: @escaping (String, String) -> Void = { _, _ in },
        onSetPassState: @escaping (String, String, PassState?) -> Void = { _, _, _ in },
        @ViewBuilder inspectorContent: @escaping () -> Inspector
    ) {
        self.store = store
        self._segment = segment
        self._selectedSubject = selectedSubject
        self.activeManuscriptItemId = activeManuscriptItemId
        self.persona = persona
        self.projectURL = projectURL
        self.activeDocId = activeDocId
        self.allDocIds = allDocIds
        self.device = device
        self.session = session
        self.docPaths = docPaths
        self.documentStore = documentStore
        self.editorControl = editorControl
        self.compilerOrchestrator = compilerOrchestrator
        self.diagnosticsStore = diagnosticsStore
        self.bibleStore = bibleStore
        self.declaredWorldStore = declaredWorldStore
        self.translator = translator
        self.translationRuns = translationRuns
        self.designer = designer
        self.pipeline = pipeline
        self.coldCall = coldCall
        self.onShowDesignProposal = onShowDesignProposal
        self.onShowTranslationRound = onShowTranslationRound
        self.compilerModel = compilerModel
        self.onCompilerModelChange = onCompilerModelChange
        self.assistant = assistant
        self._annotationScope = annotationScope
        self.onSetActivePass = onSetActivePass
        self.onSetPassState = onSetPassState
        self.inspectorContent = inspectorContent
    }

    var body: some View {
        VStack(spacing: 0) {
            segmentPicker
            Divider()
            segmentContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: segment) { _, newValue in
            // `visibleSegments(including:)` always appends an out-of-persona
            // selection now (the one refusal — `.outline` on a collection
            // project — died with the case, stage 3a Task 6), so this snap is
            // normally a no-op; it stays as the belt for whatever the picker
            // cannot render.
            let snapped = Self.snappedSelection(
                newValue, in: pickerSegments, fallback: persona.defaultPane)
            guard snapped == newValue else {
                segment = snapped
                return
            }
            persistSegment(newValue)
        }
        .task {
            // Populate the inbox count so the unread badge is live from window
            // open, before the writer ever visits the inbox segment. Presenter
            // changes (.inbox arm) keep it fresh thereafter.
            await store.documentStore?.inboxStore.refresh()
        }
        // MOUNT, not a persona change — snaps against the SELECTION-CARRYING
        // list, so an out-of-persona pane the writer just asked for survives.
        // See "Two snaps, two lists" below; this is NOT `coerceSegmentIntoView`.
        .onAppear {
            snapSegmentIntoPicker()
            // **A fresh mount persists what it mounted with** — fix-round 1,
            // review Important 2.
            //
            // `.onChange(of: segment)` below is the only writer of
            // `UIState.detailSegment`, and it cannot fire for a change that
            // predates this view's mount. This view mounts CONDITIONALLY, and
            // there are now two ordinary ways to reach it with the writer's
            // pane already in place and unpersisted: a ⌘⌥-letter that reveals a
            // hidden column (the case the snap's own doc comment describes),
            // and — since the study column took this column — a ⌘⌥-letter
            // pressed while a reference is being studied, which dismisses the
            // study and mounts this view fresh on the requested pane. Left
            // alone the project reopens on the pane BEFORE the one the writer
            // asked for.
            //
            // Idempotent by construction: it writes the value already selected,
            // and where the snap moved it, `.onChange` writes the snapped value
            // over this one in the same pass.
            persistSegment(segment)
        }
        // Belt to `PersonaModifier`'s braces: that modifier already runs
        // `Persona.coerce(_:)` on a persona change, but only this view knows
        // which segment is CURRENTLY selected outside the destination's own
        // registry.
        .onChange(of: persona) { _, newPersona in
            coerceSegmentIntoView(of: newPersona)
        }
        .background(WindowAccessor(window: $window))
        .modifier(VisualLanguageProposalModifier(
            projectURL: projectURL, window: window,
            proposed: $visualLanguageProposed))
    }

    // MARK: - Two snaps, two lists — do not conflate them

    // `segment` is pulled onto a renderable pane from two places, and they
    // consult DIFFERENT lists on purpose. Which list a coercion consults has
    // now been wrong three times on this branch, so the split is spelled out:
    //
    // - `snapSegmentIntoPicker()` uses the SELECTION-CARRYING list
    //   (`pickerSegments` = `visibleSegments(including: segment)`). It keeps
    //   whatever is selected, because an out-of-persona segment is appended
    //   and rendered — personas are lenses, not gates. `visibleSegments(
    //   including:)` never refuses an append (the one exception, `.outline`
    //   on a collection project, died with the case in stage 3a Task 6), so
    //   this snap is now always a no-op in production; it stays as the belt.
    //   Callers: `.onAppear` and `.onChange(of: segment)`.
    //
    // - `coerceSegmentIntoView(of:)` uses the persona's BARE registry list.
    //   It deliberately DROPS an out-of-persona segment, because on a persona
    //   change coercion is the intent.
    //   Caller: `.onChange(of: persona)`, and only that.

    /// Snap `segment` onto something the picker renders, honouring an
    /// out-of-persona selection (it is appended, so it is in the list).
    ///
    /// `.onAppear` must use this rather than `coerceSegmentIntoView(of:)`:
    /// this view mounts conditionally on `showInspector`, so a `⌘⌥`-letter
    /// shortcut that reveals a hidden column (`showInspector = true` then
    /// `detailSegment = seg`, `SessionAndNavigationModifier`) mounts it FRESH
    /// with the requested segment already in place. `.onChange(of: segment)`
    /// cannot fire — the change predates the mount — but `.onAppear` does.
    /// Coercing here threw the requested pane away and persisted the wrong
    /// one to `UIState` (whole-branch review, Critical 1).
    /// **The one writer of `UIState.detailSegment`.** Two callers — the mount
    /// and the change — because a conditional mount can arrive with a change
    /// already applied; see `.onAppear`.
    private func persistSegment(_ value: DetailSegment) {
        store.documentStore?.updateUIState { $0.detailSegment = value }
    }

    private func snapSegmentIntoPicker() {
        let snapped = Self.mountSelection(segment, persona: persona)
        if snapped != segment { segment = snapped }
    }

    /// The selection a freshly-mounted picker must carry, given the segment
    /// already in place. Split out as a pure static so a test can pin the
    /// LIST CHOICE — `including: current`, the selection-carrying list — and
    /// not merely the snap. Swapping this to the bare registry list is the
    /// Critical 1 regression, and
    /// `DetailPaneTogglePersonaTests.test_mountSelection_keepsAnOutOfRegistrySegment`
    /// fails when it happens.
    static func mountSelection(
        _ current: DetailSegment,
        persona: Persona
    ) -> DetailSegment {
        let carrying = visibleSegments(persona: persona, including: current)
        return snappedSelection(current, in: carrying, fallback: persona.defaultPane)
    }

    /// Pull `segment` onto a pane this persona registers. No-op when it
    /// already is one, so it never fights a deliberate selection.
    ///
    /// Deliberately asks for the persona's OWN list (no `including:`) — the
    /// selection-carrying list contains `segment` by construction, so passing
    /// it here would make every coercion a no-op and an out-of-persona
    /// selection would never be dropped on a persona switch.
    private func coerceSegmentIntoView(of persona: Persona) {
        let visible = Self.visibleSegments(persona: persona)
        let coerced = Self.snappedSelection(segment, in: visible, fallback: persona.defaultPane)
        if coerced != segment { segment = coerced }
    }

    // MARK: - Which segments this persona offers

    /// The segments this picker shows, in order. Ordering comes from the
    /// persona registry, not from `DetailSegment.allCases` — so adding a case
    /// to the enum does not silently change any picker.
    ///
    /// `selected`, when supplied and not already registered, is **appended**.
    /// Personas are lenses, not gates: every `⌘⌥`-letter pane shortcut fires
    /// in every persona, and `ProjectWindow` force-sets `.translation` on
    /// entering translation review — without this the picker would render with
    /// nothing selected while the pane below it showed the right content.
    /// Appending (rather than inserting in registry order) keeps the persona's
    /// own ordering stable and makes the addition read as transient.
    /// Always appends now: the one refusal this ever had — a collection
    /// project hiding `.outline` — died with the case (stage 3a Task 6).
    static func visibleSegments(
        persona: Persona,
        including selected: DetailSegment? = nil
    ) -> [DetailSegment] {
        var segments = persona.panes
        if let selected, !segments.contains(selected) {
            segments.append(selected)
        }
        return segments
    }

    /// How many segment-widths to shift `badged`'s unread badge left from the
    /// trailing edge of `segments`, or nil when that list does not show it.
    ///
    /// SwiftUI's segmented Picker cannot badge a segment directly, so the
    /// badge is overlaid top-trailing and shifted. This was previously the
    /// hardcoded literal 2 ("inbox is third-to-last"), which silently moved
    /// the badge onto the wrong tab when translation was added.
    ///
    /// Takes the rendered list itself rather than the three arguments the
    /// list is derived from: the caller passes `pickerSegments`, the same
    /// value `ForEach` walks, so badge and picker cannot be computed from
    /// different lists. Re-deriving here was how the literal-drift bug got
    /// back in one level up.
    ///
    /// **Takes the badged segment rather than assuming `.inbox`** as of M2
    /// Task 8: Diagnostics carries a badge too, and the two can be on screen
    /// together even though no persona registers both — ⌘⌥B in Author appends
    /// `.inbox` to a picker that already leads with `.diagnostics`.
    static func badgeOffset(of badged: DetailSegment, in segments: [DetailSegment]) -> Int? {
        guard let index = segments.firstIndex(of: badged) else { return nil }
        return segments.count - 1 - index
    }

    /// The selection the picker should carry, given a proposed one and the
    /// list the picker renders. Everything the picker can show is returned
    /// unchanged — personas are lenses, not gates, so an out-of-persona
    /// segment reached by shortcut stays selected (it is appended by
    /// `visibleSegments(including:)`, which never refuses now — see that
    /// function's doc comment). Falling back at all is the belt for a segment
    /// this list genuinely does not carry.
    static func snappedSelection(
        _ proposed: DetailSegment,
        in segments: [DetailSegment],
        fallback: DetailSegment
    ) -> DetailSegment {
        segments.contains(proposed) ? proposed : (segments.first ?? fallback)
    }

    /// New (`.new`) inbox captures awaiting triage — drives the picker badge.
    /// The unread badge is the discoverability signal for the async phone→Mac
    /// capture loop: without it, captures that sync in while the writer is
    /// heads-down go unnoticed in a six-segment picker.
    private var inboxCount: Int {
        store.documentStore?.inboxStore.entries.count ?? 0
    }

    /// Notes a compiler run landed for the open document while the writer was
    /// somewhere else — the same discoverability argument as `inboxCount`, for
    /// the one pane whose content arrives without being asked for a second
    /// time. Cleared by `DiagnosticsPane` the moment it is on screen.
    private var diagnosticsUnreadCount: Int {
        diagnosticsStore?.unreadCount(docId: activeDocId) ?? 0
    }

    // MARK: - Picker

    /// The one list this picker renders — segment order, badge offset and
    /// badge width all derive from it, so they cannot disagree.
    private var pickerSegments: [DetailSegment] {
        Self.visibleSegments(persona: persona, including: segment)
    }

    @ViewBuilder
    private var segmentPicker: some View {
        Picker("Right pane", selection: $segment) {
            ForEach(pickerSegments, id: \.self) { seg in
                Image(systemName: seg.systemImageName)
                    .tag(seg)
                    .help(seg.helpText)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // Unread badges. SwiftUI's segmented Picker can't badge a segment
        // directly, so we overlay top-trailing and shift left by however many
        // equal-width segments sit to the right of the badged one in THIS
        // persona's picker — derived from `pickerSegments` itself, never a
        // literal and never a re-derivation (see `badgeOffset(of:in:)`).
        // Anchored on the bare picker (before padding) so the width the
        // GeometryReader measures divides evenly across the segments. Each is
        // hidden at zero and absent entirely where its segment is; capped at
        // 99+.
        .overlay(alignment: .topTrailing) {
            badge(over: .inbox, count: inboxCount, tint: .red,
                  help: "\(inboxCount) new capture\(inboxCount == 1 ? "" : "s") "
                      + "in the inbox (\u{2318}\u{2325}B)")
        }
        .overlay(alignment: .topTrailing) {
            // Accent rather than the inbox's red: these are craft notes on
            // prose the writer chose to have checked, not something wrong.
            // The register is the same one the pane's own copy keeps.
            badge(over: .diagnostics, count: diagnosticsUnreadCount, tint: .accentColor,
                  help: "\(diagnosticsUnreadCount) new "
                      + "note\(diagnosticsUnreadCount == 1 ? "" : "s") "
                      + "from the last check (\u{2318}\u{2325}D)")
        }
        .overlay(alignment: .topTrailing) {
            // Accent, on the diagnostics badge's own register — a proposal
            // waiting on the writer is not something wrong (translation
            // pipeline P5).
            badge(over: .visualLanguage, count: visualLanguageProposed ? 1 : 0,
                  tint: .accentColor, help: Self.visualLanguageBadgeHelp)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// The Visual Language segment's badge tooltip (translation pipeline P5)
    /// — carries the shortcut on the other two badges' own convention.
    ///
    /// **A computed `static var`, not a stored one** — `DetailPaneToggle` is
    /// generic over `Inspector`, and Swift does not allow a static STORED
    /// property on a generic type.
    static var visualLanguageBadgeHelp: String {
        "Claude proposed a visual language — open it to adopt or discard (\u{2318}\u{2325}V)"
    }

    /// One unread badge over `segment`, or nothing when the count is zero or
    /// this picker does not render that segment.
    @ViewBuilder
    private func badge(
        over segment: DetailSegment, count: Int, tint: Color, help: String
    ) -> some View {
        if count > 0, let shift = Self.badgeOffset(of: segment, in: pickerSegments) {
            GeometryReader { geo in
                let segmentWidth = geo.size.width / CGFloat(max(pickerSegments.count, 1))
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(tint, in: Capsule())
                    .padding(.trailing, 10)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
                    .help(help)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: -CGFloat(shift) * segmentWidth)
            }
        }
    }

    // MARK: - Content routing

    @ViewBuilder
    private var segmentContent: some View {
        switch segment {
        case .inspector:
            inspectorContent()
        case .annotations:
            annotationsPane
        case .history:
            historyPane
        case .tasks:
            tasksPane
        case .inbox:
            inboxPane
        case .translation:
            translationPane
        case .intent:
            statementPane(kind: .intent)
        case .visualLanguage:
            statementPane(kind: .visualLanguage)
        case .lessons:
            statementPane(kind: .lessons)
        case .diagnostics:
            diagnosticsPane
        case .references:
            referencesPane
        case .department:
            departmentPane
        }
    }

    /// **Publish's desk** (publish-department P4 Task 1). Project-scoped, like
    /// the Review board it is the sibling of: a department works on the book,
    /// not on whichever chapter happens to be open, so this arm asks for a
    /// project and nothing else.
    ///
    /// **The desk arrives through a host, not from this body** (Task 2). The
    /// language union walks every manuscript document's translation store,
    /// reads each one's open annotations and derives coverage against the
    /// current paragraph state; the proposal list (Task 4) reads
    /// `.maugham/design/proposals/`. Neither may run on a `body` path (tripwire
    /// 4), so `DepartmentPaneHost` derives both in a `.task` and hands the pane
    /// plain values — `referencesPane`'s shape below, for the same reason.
    @ViewBuilder
    private var departmentPane: some View {
        if let ds = documentStore, let projectURL {
            DepartmentPaneHost(store: store, documentStore: ds,
                               projectURL: projectURL,
                               // The tree's own subject, unconverted: the run
                               // target has to tell a group from a chapter and a
                               // research note from both, and `activeDocId`'s
                               // sentinel has already flattened all three
                               // (Task 3).
                               subject: selectedSubject,
                               translator: translator,
                               runLog: translationRuns,
                               designer: designer,
                               pipeline: pipeline,
                               onShowProposal: onShowDesignProposal,
                               onShowRound: onShowTranslationRound)
        } else {
            ContentUnavailableView(
                "Open a project",
                systemImage: "person.2",
                description: Text("The department works on a book — its design "
                                  + "and its language editions."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The shelf (M2 §6.2). The pinned set is assembled off the body path in a
    /// `.task` — a manifest walk plus a canvas read is not something a `body`
    /// may do (tripwire 4) — and re-assembled on the three signals that can
    /// change it: the document, the manifest (a link added, a note renamed) and
    /// the canvas's structural revision.
    @ViewBuilder
    private var referencesPane: some View {
        if let projectURL, let assistant,
           activeDocId != BinderSubject.noDocumentSubject {
            ReferencesPaneHost(store: store, projectURL: projectURL,
                               docId: activeDocId, persona: persona, assistant: assistant)
        } else {
            ContentUnavailableView(
                "Select a document",
                systemImage: "pin",
                description: Text("Open a manuscript to see what it's pinned to."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var diagnosticsPane: some View {
        if let ds = documentStore,
           let compilerOrchestrator,
           let diagnosticsStore,
           activeDocId != BinderSubject.noDocumentSubject {
            DiagnosticsPane(
                orchestrator: compilerOrchestrator,
                diagnostics: diagnosticsStore,
                docId: activeDocId,
                currentText: { [weak ds] paragraphId in
                    ds?.document(forDocId: activeDocId)?.paragraph(id: paragraphId)
                },
                compilerModel: compilerModel,
                onCompilerModelChange: onCompilerModelChange,
                activeDocument: { [weak ds] in ds?.document(forDocId: activeDocId) },
                // The answer flow's destination (M2 Task 10). Passed rather
                // than reached for, so the pane still holds no store of its
                // own and a caller that has none simply offers no Answer.
                store: store,
                // …and the cache that answer invalidates. Without it the next
                // run checks the writer against a world derived before their
                // ruling existed, and nothing anywhere says so.
                world: declaredWorldStore,
                // **Who reads this piece's CHECKS** — `AuthorReader` (two
                // loops P1 Task 2). This pane is Author's, and Author checks;
                // the piece's lane on the review board is the round loop's
                // fact and is deliberately not read here.
                reader: store.manifest.authorReader,
                onOpenBoard: { Self.openBoardInReview(selectedSubject: $selectedSubject) })
        } else {
            ContentUnavailableView(
                "Select a document",
                systemImage: "checkmark.seal",
                description: Text("Open a manuscript, then press \u{2318}R to check your writing."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// **Opening the board from the Diagnostics header's reader line.**
    /// Mirrors `MaughamApp.postPersona`/`ProjectWindow`'s persona-bar post —
    /// same event, same payload key — then sets the subject to `.project`
    /// because the board is Review's project-level centre
    /// (`ProjectWindow.reviewCentreShowsBoard`): a chapter subject would open
    /// that chapter's editor instead of the grid the writer just asked to
    /// see. Unlike `annotationsPane`'s `onTravel`
    /// closure at `:675`, which deliberately carries NO persona (a reviewer
    /// following a note about another chapter stays in Review), this one
    /// exists to change persona — the reader line's whole point is "go
    /// change who reads this".
    ///
    /// A named `static func` rather than an inline closure so
    /// `DiagnosticsPaneTests` can pin the exact event spelling without
    /// mounting this view — the call site above is the one production
    /// caller.
    static func openBoardInReview(selectedSubject: Binding<BinderSubject?>) {
        MaughamEvent.post(.maughamSetPersona, to: .keyWindow,
                           payload: [MaughamEvent.personaKey: Persona.review.rawValue])
        selectedSubject.wrappedValue = .project
    }

    /// **This switch is why a new right-pane surface touches this file.**
    /// `Persona.panes`' extension-point comment says adding one is an enum case
    /// plus a registry entry and nothing else; that is true of the picker, the
    /// shortcut table and `ProjectWindow`, and false here — `segmentContent` is
    /// exhaustive over `DetailSegment` with no `default`, so a new case cannot
    /// compile without an arm. The comment has been corrected rather than the
    /// switch loosened: a `default` here would let a segment ship registered,
    /// reachable by shortcut, and rendering the wrong pane.
    @ViewBuilder
    private func statementPane(kind: Statement.Kind) -> some View {
        if let ds = documentStore {
            // The TYPED subject, not `activeManuscriptItemId` — a statement's
            // scope is the one question in this file whose answer differs for
            // "the project" and "nothing selected", and the `String?` boundary
            // spells both `nil`. They still resolve alike; passing the subject
            // is what lets that stay a decision rather than an accident
            // (`StatementPane.effectiveScope`).
            StatementPane(
                store: store, documentStore: ds, kind: kind,
                subject: selectedSubject,
                bible: bibleStore, world: declaredWorldStore)
        } else {
            ContentUnavailableView(
                "Open a project",
                systemImage: kind == .visualLanguage ? "photo.on.rectangle.angled" : "target",
                description: Text("What you're going for lives with the project."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var translationPane: some View {
        if let ds = documentStore,
           let control = editorControl,
           activeDocId != BinderSubject.noDocumentSubject,
           let doc = ds.document(forDocId: activeDocId) {
            TranslationReviewPane(
                document: doc, control: control, store: store,
                // The two spot-checks (P4 Task 6): the window's runner, its
                // documents (the author's language is resolved through the
                // imprint the desk is standing on), the project, the compiler's
                // model setting, and the craft-intent cache a Keep mine filed
                // for every edition has to invalidate.
                coldCall: coldCall, documentStore: ds, projectURL: projectURL,
                model: compilerModel.claudeModel, world: declaredWorldStore)
        } else {
            ContentUnavailableView(
                "Select a document",
                systemImage: "character.book.closed",
                description: Text("Open a manuscript and enter translation review to reply to translator queries."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var inboxPane: some View {
        if let ds = documentStore {
            InboxPane(store: ds.inboxStore, projectStore: store,
                      activeDocumentId: activeManuscriptItemId,
                      canTranscribe: Self.localTranscriptionAvailable,
                      retranscribe: { entry in Task { await ds.retranscribe(entry) } })
        } else {
            ContentUnavailableView(
                "Open a project",
                systemImage: "tray",
                description: Text("Captures from MaughamPhone appear here."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var historyPane: some View {
        if let url = projectURL {
            HistoryPane(
                projectURL: url,
                activeDocId: activeDocId,
                allDocIds: allDocIds,
                device: device,
                session: session,
                docPaths: docPaths,
                documentStore: documentStore
            )
        } else {
            ContentUnavailableView(
                "History unavailable",
                systemImage: "clock.arrow.circlepath"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var annotationsPane: some View {
        if let ds = documentStore {
            // The pane renders with NO open document as of M3 P2 Task 7: its
            // project scope is a view of the whole manuscript, and that is the
            // state a writer arrives in from the board's open-notes column.
            // Document scope's "Select a document" empty state moved inside,
            // so the scope toggle above it stays reachable.
            AnnotationsPane(
                document: activeDocId == BinderSubject.noDocumentSubject
                    ? nil : ds.document(forDocId: activeDocId),
                store: store,
                documentStore: ds,
                scope: $annotationScope,
                onTravel: { docId in
                    // Travelling to a piece is the window's SUBJECT write and
                    // nothing else. No persona rides along: Review's centre
                    // shows documents, so a reviewer clicking a note about
                    // another chapter must land there with their notes still
                    // beside them (`ManuscriptNavigation`'s ruling, and
                    // `AnnotationScopeTests`' census over this closure).
                    selectedSubject = .item(docId)
                },
                // The round cockpit's two stores (M4 P2 Task 3) — the same
                // pair the Diagnostics arm takes, and `nil` in a host that
                // surfaces no compiler, which draws no strip.
                orchestrator: compilerOrchestrator,
                diagnostics: diagnosticsStore,
                // The letter's Add to intent drops the derivation cache the
                // same way the Diagnostics arm's Answer does.
                world: declaredWorldStore,
                onSetActivePass: onSetActivePass,
                compilerModel: compilerModel,
                onCompilerModelChange: onCompilerModelChange,
                onSetPassState: onSetPassState)
        } else {
            ContentUnavailableView(
                "Open a project",
                systemImage: "doc.text",
                description: Text("Annotations live with a project's pieces."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var tasksPane: some View {
        if let ds = documentStore {
            TasksPane(
                store: store,
                documentStore: ds,
                activeDocId: activeDocId,
                projectURL: projectURL)
        } else {
            ContentUnavailableView(
                "Open a project",
                systemImage: "checklist",
                description: Text("Tasks track todos across a project."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// **The Visual Language segment's proposed-badge state** (translation
/// pipeline P5), pulled out of `DetailPaneToggle.body` into a modifier of its
/// own — this file already dodges the type-checker ceiling this way (every
/// pane above is its own `@ViewBuilder` property), and a conditional
/// subscription inlined into `body` is exactly the kind of branch that adds
/// to the count.
///
/// **A no-op with no `projectURL`**, rather than a caller-side `if let` —
/// the probe callers that mount `DetailPaneToggle` without a project on disk
/// (`StatementMountFixture` among them) attach this modifier unconditionally
/// and it does nothing: no task runs, no subscription is made, and
/// `proposed` stays at whatever `DetailPaneToggle` seeded it with (`false`).
private struct VisualLanguageProposalModifier: ViewModifier {
    let projectURL: URL?
    let window: NSWindow?
    @Binding var proposed: Bool

    /// Bumped by `.maughamStatementProposalsChanged` so the `.task` re-keys
    /// and re-reads the slot — `DepartmentPaneHost`'s idiom: the `.task` owns
    /// cancellation, not a direct `await` in the notification closure.
    @State private var reloads = 0

    private struct TaskKey: Equatable {
        let projectPath: String
        let reloads: Int
        /// **The same measured defect `DepartmentPaneHost.ReloadKey` and
        /// `StatementPane.ProposalTaskKey` both carry this field for.**
        /// `WindowAccessor` resolves `window` on an async hop after mount,
        /// and `MaughamEvent.shouldDeliver` drops a `.project` post while it
        /// is still nil — so a proposal staged in this picker's first frames
        /// is a post nothing catches, and nothing else re-keys this `.task`
        /// to pick it up afterwards. Re-reading the slot the moment the
        /// window arrives costs one JSON read, once, and closes the window.
        let windowResolved: Bool
    }

    func body(content: Content) -> some View {
        content
            .task(id: TaskKey(projectPath: projectURL?.path ?? "",
                              reloads: reloads, windowResolved: window != nil)) {
                guard let projectURL else {
                    proposed = false
                    return
                }
                proposed = StatementProposalStore(projectURL: projectURL)
                    .pending(for: .visualLanguage) != nil
            }
            .onProjectEvent(.maughamStatementProposalsChanged,
                            url: projectURL ?? URL(fileURLWithPath: "/"),
                            window: window) { _ in
                guard projectURL != nil else { return }
                reloads += 1
            }
    }
}
