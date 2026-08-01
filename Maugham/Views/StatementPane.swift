import SwiftUI
import MaughamCore

/// The right pane for a statement — Intent (⌘⌥N) or Visual Language (⌘⌥V),
/// M1A spec §4.3.
///
/// **Scope follows selection.** Intent shows the selected document's, or the
/// project's when no document is selected, with the other one click away — a
/// chapter's intent and the book's are never further apart than that. Visual
/// language is project-scope, so it simply shows.
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
    /// Whatever the binder has selected. May be a group, a piece from another
    /// project, or `ProjectWindow`'s `"__no-selection__"` sentinel — all of
    /// which resolve to the project (see `effectiveScope`).
    let activeDocumentId: String?
    /// A scope somebody has asked this pane to show — today, **Open** on a card
    /// promoted to craft intent (M1A Task 7). Nil in the ordinary case.
    var scopeRequest: ScopeRequest? = nil

    /// "Show me this scope", from outside the pane.
    ///
    /// **The token is not decoration.** A request is honoured until the writer
    /// moves the binder selection, and pressing **Open** on the same card twice
    /// must work both times — with the scope alone, the second press is an
    /// unchanged value, `.onChange` does not fire, and the pane sits wherever
    /// the selection last put it. The counter makes every press a new request.
    struct ScopeRequest: Equatable {
        let scope: Statement.Scope
        let token: Int
    }

    /// Set when the writer asks for the *project's* intent while a document is
    /// selected. Reset by a selection change, so moving to another chapter shows
    /// that chapter's intent rather than silently keeping the book's.
    ///
    /// **It is the pane's only scope state, and it is right that it dies with
    /// the pane.** A segment switch destroys this view, and this comes back at
    /// its neutral value — the pane returns to its declarative answer. A copy of
    /// the *request* alongside it did not have that property: it came back
    /// STALE, because what it copied outlives the pane (fix round 2, N1). So
    /// there is no copy; `scopeRequest` is read where it is needed, and the
    /// window revokes it.
    @State private var prefersProjectScope = false

    /// Which statement this pane is showing.
    ///
    /// Pure and static so it can be asked over the whole product of its inputs
    /// rather than the one path a plan happened to name — the shape that found
    /// both of `ProjectWindow`'s routing bugs. `StatementPaneTests` is that test.
    ///
    /// A scope that is not a manuscript document in this project — a group, an
    /// unknown id, the no-selection sentinel — resolves to the project rather
    /// than being asked for: `createStatement` throws `.structureMissing` for
    /// one, and a pane that offered it would be offering a keystroke that fails.
    static func effectiveScope(
        kind: Statement.Kind,
        activeDocumentId: String?,
        structure: [StructureItem],
        prefersProjectScope: Bool,
        requested: Statement.Scope? = nil
    ) -> Statement.Scope {
        // Visual language is project-scope only — the book has one look (§2.1).
        // An `.unknown` kind (a newer build's) is retained and ignored
        // everywhere else, and has no document storage either.
        guard case .intent = kind else { return .project }
        // **The switch is asked BEFORE the request, and that is what keeps it a
        // live control** (fix round 2). A request outranking it left the writer
        // pressing Project on a pane pinned by Open and watching nothing happen.
        // The two acts do not need an ordering rule between them, only a rule
        // that the LATER one wins — and the other half of that is the pane
        // clearing this flag when a new request arrives, so an Open after a
        // switch press is not swallowed either. That half is a `.onChange`
        // rather than a term here, because "which came last" is not a fact this
        // function's inputs carry.
        if prefersProjectScope { return .project }
        // **A request wins over the selection, and only over the selection.** It
        // is the writer saying "take me to what this card became" (M1A Task 7),
        // and a chapter's intent is the ordinary case now — so `Open` landing on
        // whatever the binder happens to have selected shows an intent that is
        // not the one the card produced, frequently an empty one, and the writer
        // either concludes the promotion did nothing or types into the wrong
        // scope believing it is the one they just added to.
        //
        // **A request naming a document this project does not hold is ignored
        // rather than obeyed**: `createStatement` throws `.structureMissing` for
        // one, so honouring it would put the pane on a scope whose first
        // keystroke fails. That is the orphaned-statement case (the document was
        // deleted and its intent outlived it), and falling back to the pane's own
        // rule is the honest answer.
        if let requested {
            switch requested {
            case .project: return .project
            case .document(let id)
                where TreeWalk.find(id: id, in: structure)?.type == .document:
                return .document(id)
            case .document, .unknown: break
            }
        }
        guard let id = activeDocumentId,
              id != StatementPane.noSelectionSentinel,
              let item = TreeWalk.find(id: id, in: structure),
              item.type == .document
        else { return .project }
        return .document(id)
    }

    /// `ProjectWindow` passes this for "nothing is selected" (`DetailPaneToggle`
    /// threads it through as `activeDocId`). It is a real value that arrives
    /// here, not a hypothetical.
    static let noSelectionSentinel = "__no-selection__"

    private var scope: Statement.Scope {
        Self.effectiveScope(
            kind: kind, activeDocumentId: activeDocumentId,
            structure: store.manifest.structure,
            prefersProjectScope: prefersProjectScope,
            requested: scopeRequest?.scope)
    }

    /// The document the picker's left segment stands for — **the pane's own
    /// answer with the project switch off**, which is the requested document
    /// while one is being honoured and the binder's selection otherwise.
    ///
    /// Asked of `effectiveScope` rather than read off `activeDocumentId`, so the
    /// switch cannot name one document while the editor below it shows another's
    /// intent. Pure and static for that function's reason.
    ///
    /// **A `.project` request falls back to the selection, and that second
    /// question is the whole of fix round 2's N2.** Asking once left the switch
    /// off screen whenever a project-scoped Open landed with a document
    /// selected — the common case, since `PromotionPerformer.intentScope` routes
    /// every unroutable piece to the project — and the pane's own way back went
    /// with it: re-clicking the same binder row fires no change, so the only
    /// escape left was selecting a DIFFERENT document, which moves the writer's
    /// open manuscript. The switch's job is to name what there is to switch
    /// **to**, and there is something to switch to exactly when the binder holds
    /// a document.
    static func pickerDocumentId(
        kind: Statement.Kind,
        activeDocumentId: String?,
        structure: [StructureItem],
        requested: Statement.Scope?
    ) -> String? {
        if case .document(let id) = effectiveScope(
            kind: kind, activeDocumentId: activeDocumentId, structure: structure,
            prefersProjectScope: false, requested: requested) {
            return id
        }
        if case .document(let id) = effectiveScope(
            kind: kind, activeDocumentId: activeDocumentId, structure: structure,
            prefersProjectScope: false, requested: nil) {
            return id
        }
        return nil
    }

    /// That document's title, when there is one — the label the scope switch
    /// offers, and what decides whether there is a switch at all.
    private var selectedDocumentTitle: String? {
        guard let id = Self.pickerDocumentId(
            kind: kind, activeDocumentId: activeDocumentId,
            structure: store.manifest.structure, requested: scopeRequest?.scope)
        else { return nil }
        return TreeWalk.find(id: id, in: store.manifest.structure)?.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The writer moving the binder takes the switch back to neutral. **It
        // does not take the REQUEST back — `ProjectWindow` does**, on the same
        // selection change, because the request outlives this view and a
        // revocation recorded here would not (fix round 2, N1).
        .onChange(of: activeDocumentId) { _, _ in prefersProjectScope = false }
        // **A fresh Open beats a stale switch press**, which is the other half
        // of "the later act wins": `effectiveScope` asks the switch first, so
        // without this an Open arriving after the writer had pressed Project
        // would change nothing. The token is what makes a SECOND press of the
        // same Open a change here.
        .onChange(of: scopeRequest) { _, _ in prefersProjectScope = false }
    }

    @ViewBuilder
    private var header: some View {
        Group {
            if let title = selectedDocumentTitle {
                Picker("Intent for", selection: $prefersProjectScope) {
                    Text(title).tag(false)
                    Text("Project").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var caption: String {
        switch kind {
        case .visualLanguage: return "How this book looks"
        case .intent, .unknown: return "What this project is going for"
        }
    }
}
