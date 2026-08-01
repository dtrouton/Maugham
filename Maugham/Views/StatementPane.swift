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

    /// Set when the writer asks for the *project's* intent while a document is
    /// selected. Reset by a selection change, so moving to another chapter shows
    /// that chapter's intent rather than silently keeping the book's.
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
        prefersProjectScope: Bool
    ) -> Statement.Scope {
        // Visual language is project-scope only — the book has one look (§2.1).
        // An `.unknown` kind (a newer build's) is retained and ignored
        // everywhere else, and has no document storage either.
        guard case .intent = kind else { return .project }
        guard !prefersProjectScope,
              let id = activeDocumentId,
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
            prefersProjectScope: prefersProjectScope)
    }

    /// The selected document's title, when the selection is one — the label the
    /// scope switch offers.
    private var selectedDocumentTitle: String? {
        guard case .intent = kind,
              let id = activeDocumentId, id != Self.noSelectionSentinel,
              let item = TreeWalk.find(id: id, in: store.manifest.structure),
              item.type == .document
        else { return nil }
        return item.title
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
        .onChange(of: activeDocumentId) { _, _ in prefersProjectScope = false }
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
