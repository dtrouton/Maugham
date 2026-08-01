import SwiftUI
import MaughamCore

struct DetailPaneToggle<Inspector: View>: View {
    @Bindable var store: ProjectStore
    @Binding var segment: DetailSegment
    @Binding var outlineLayout: OutlineLayout
    @Binding var selectedSubject: BinderSubject?
    /// The item the tree names, converted once at `ProjectWindow`'s boundary.
    /// `nil` for the project and for no selection alike.
    let activeManuscriptItemId: String?
    /// The window's working mode. Decides which segments the picker offers —
    /// see `visibleSegments(persona:hideOutline:)`.
    let persona: Persona
    let hideOutline: Bool
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
    @ViewBuilder var inspectorContent: () -> Inspector

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
        outlineLayout: Binding<OutlineLayout>,
        selectedSubject: Binding<BinderSubject?>,
        activeManuscriptItemId: String?,
        persona: Persona = .default,
        hideOutline: Bool = false,
        projectURL: URL? = nil,
        activeDocId: String = BinderSubject.noDocumentSubject,
        allDocIds: [String] = [],
        device: String = "",
        session: String = "",
        docPaths: [String: String] = [:],
        documentStore: DocumentStore? = nil,
        editorControl: EditorControl? = nil,
        @ViewBuilder inspectorContent: @escaping () -> Inspector
    ) {
        self.store = store
        self._segment = segment
        self._outlineLayout = outlineLayout
        self._selectedSubject = selectedSubject
        self.activeManuscriptItemId = activeManuscriptItemId
        self.persona = persona
        self.hideOutline = hideOutline
        self.projectURL = projectURL
        self.activeDocId = activeDocId
        self.allDocIds = allDocIds
        self.device = device
        self.session = session
        self.docPaths = docPaths
        self.documentStore = documentStore
        self.editorControl = editorControl
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
            // A ⌘⌥-letter shortcut can select a segment this picker cannot
            // render — `.outline` on a collection project is the only one
            // (`visibleSegments` refuses to append it), and it left the
            // picker with nothing highlighted. Snap onto a segment the
            // picker actually shows; the snap re-enters here and persists.
            let snapped = Self.snappedSelection(
                newValue, in: pickerSegments, fallback: persona.defaultPane)
            guard snapped == newValue else {
                segment = snapped
                return
            }
            store.documentStore?.updateUIState { $0.detailSegment = newValue }
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
        }
        // Belt to `PersonaModifier`'s braces: that modifier already runs
        // `Persona.coerce(_:)` on a persona change, but it cannot see
        // `hideOutline` — a collection project drops `.outline` from the
        // picker after the registry has had its say. This is the only place
        // both facts are known.
        .onChange(of: persona) { _, newPersona in
            coerceSegmentIntoView(of: newPersona)
        }
    }

    // MARK: - Two snaps, two lists — do not conflate them

    // `segment` is pulled onto a renderable pane from two places, and they
    // consult DIFFERENT lists on purpose. Which list a coercion consults has
    // now been wrong three times on this branch, so the split is spelled out:
    //
    // - `snapSegmentIntoPicker()` uses the SELECTION-CARRYING list
    //   (`pickerSegments` = `visibleSegments(including: segment)`). It keeps
    //   whatever is selected, because an out-of-persona segment is appended
    //   and rendered — personas are lenses, not gates. The only value it ever
    //   moves is `.outline` on a collection project, which
    //   `visibleSegments(including:)` refuses to append.
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
    private func snapSegmentIntoPicker() {
        let snapped = Self.mountSelection(
            segment, persona: persona, hideOutline: hideOutline)
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
        persona: Persona,
        hideOutline: Bool
    ) -> DetailSegment {
        let carrying = visibleSegments(
            persona: persona, hideOutline: hideOutline, including: current)
        return snappedSelection(current, in: carrying, fallback: persona.defaultPane)
    }

    /// Pull `segment` onto a pane this persona registers. No-op when it
    /// already is one, so it never fights a deliberate selection.
    ///
    /// Deliberately asks for the persona's OWN list (no `including:`) — the
    /// selection-carrying list contains `segment` by construction, so passing
    /// it here would make every coercion a no-op and a collection project
    /// would sit on `.outline` forever.
    private func coerceSegmentIntoView(of persona: Persona) {
        let visible = Self.visibleSegments(persona: persona, hideOutline: hideOutline)
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
    /// `hideOutline` still wins: a collection project has no outline pane to
    /// show, so an out-of-persona `.outline` selection is not appended either.
    static func visibleSegments(
        persona: Persona,
        hideOutline: Bool,
        including selected: DetailSegment? = nil
    ) -> [DetailSegment] {
        var segments = persona.panes.filter { !(hideOutline && $0 == .outline) }
        if let selected,
           !segments.contains(selected),
           !(hideOutline && selected == .outline) {
            segments.append(selected)
        }
        return segments
    }

    /// How many segment-widths to shift the inbox unread badge left from the
    /// trailing edge of `segments`, or nil when that list has no inbox.
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
    static func badgeOffset(in segments: [DetailSegment]) -> Int? {
        guard let index = segments.firstIndex(of: .inbox) else { return nil }
        return segments.count - 1 - index
    }

    /// The selection the picker should carry, given a proposed one and the
    /// list the picker renders. Everything the picker can show is returned
    /// unchanged — personas are lenses, not gates, so an out-of-persona
    /// segment reached by shortcut stays selected (it is appended by
    /// `visibleSegments(including:)`). The one segment that cannot be
    /// appended is `.outline` on a collection project, whose content falls
    /// through to the inspector; a picker showing nothing selected is the
    /// state this snaps out of.
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

    // MARK: - Picker

    /// The one list this picker renders — segment order, badge offset and
    /// badge width all derive from it, so they cannot disagree.
    private var pickerSegments: [DetailSegment] {
        Self.visibleSegments(persona: persona, hideOutline: hideOutline, including: segment)
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
        // Unread badge over the inbox segment. SwiftUI's segmented Picker can't
        // badge a segment directly, so we overlay top-trailing and shift left by
        // however many equal-width segments sit to the right of inbox in THIS
        // persona's picker — derived from `pickerSegments` itself, never a
        // literal and never a re-derivation (see `badgeOffset(in:)`).
        // Anchored on the bare picker (before padding)
        // so the width the GeometryReader measures divides evenly across the
        // segments. Hidden at zero, and absent entirely in personas without an
        // inbox; capped at 99+.
        .overlay(alignment: .topTrailing) {
            if inboxCount > 0, let shift = Self.badgeOffset(in: pickerSegments) {
                GeometryReader { geo in
                    let segmentWidth = geo.size.width / CGFloat(max(pickerSegments.count, 1))
                    inboxBadge
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: -CGFloat(shift) * segmentWidth)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var inboxBadge: some View {
        Text(inboxCount > 99 ? "99+" : "\(inboxCount)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.red, in: Capsule())
            .padding(.trailing, 10)
            .padding(.top, 2)
            .allowsHitTesting(false)
            .help("\(inboxCount) new capture\(inboxCount == 1 ? "" : "s") in the inbox (⌘⌥B)")
    }

    // MARK: - Content routing

    @ViewBuilder
    private var segmentContent: some View {
        switch segment {
        case .inspector:
            inspectorContent()
        case .annotations:
            annotationsPane
        case .research:
            LinkedResearchPane(
                store: store,
                activeDocumentId: activeManuscriptItemId)
        case .outline:
            if hideOutline {
                inspectorContent()
            } else {
                OutlinePane(
                    store: store,
                    layout: $outlineLayout,
                    selectedSubject: $selectedSubject)
            }
        case .history:
            historyPane
        case .tasks:
            tasksPane
        case .inbox:
            inboxPane
        case .palette:
            PalettePane(store: store)
        case .translation:
            translationPane
        case .intent:
            statementPane(kind: .intent)
        case .visualLanguage:
            statementPane(kind: .visualLanguage)
        }
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
            StatementPane(
                store: store, documentStore: ds, kind: kind,
                activeDocumentId: activeManuscriptItemId)
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
            TranslationReviewPane(document: doc, control: control)
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
        if let ds = documentStore,
           activeDocId != BinderSubject.noDocumentSubject,
           let doc = ds.document(forDocId: activeDocId) {
            AnnotationsPane(document: doc)
        } else {
            ContentUnavailableView(
                "Select a document",
                systemImage: "doc.text",
                description: Text("Open a manuscript to see and act on annotations."))
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
