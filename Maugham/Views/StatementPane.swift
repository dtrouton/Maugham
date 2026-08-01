import SwiftUI
import MaughamCore

/// The right pane for a statement — Intent (⌘⌥N) or Visual Language (⌘⌥V),
/// M1A spec §4.3.
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
