import SwiftUI
import MaughamCore
import AppKit

/// The canvas's `Promote…` command: enablement, presentation and performance,
/// all in one place so `ProjectWindow.body` gains a single line.
///
/// **`internal`, not `private`, and that is required**: `@testable import`
/// cannot see `private`, and `isPromotable` below is the enablement rule a
/// test drives.
///
/// **It reads `model.selection` and must NEVER read `model.scene`.**
/// `CanvasModel` is `@Observable` with the whole scene in one stored property,
/// and every drag frame and every coast frame writes it — a read here would put
/// the window's body on the drag loop at 60–120 Hz. `selection` moves on a
/// click. The same rule keeps `store` off this path except inside the two
/// actions below, which run from a user gesture: `begin()` snapshots the
/// manifest once, and `commit(_:)` performs.
///
/// Measured (2026-07-28, through a real canvas and the production
/// `CanvasEventNSView` seam): 120 drag frames evaluated this body once and
/// the enclosing window body zero times — a `ViewModifier`'s body is its own
/// view, so SwiftUI records `selection`, not the window that built it.
struct CanvasPromotionModifier: ViewModifier {
    let window: NSWindow?
    let store: ProjectStore?
    let model: CanvasModel
    /// The window's working mode — the basis of `isPromotable`, because the
    /// board is Plan's centre column.
    let persona: Persona

    @State private var sheet: PromotionSheetModel?
    @State private var failure: String?
    /// What was just produced, in one sentence. Nil when there is nothing to
    /// confirm — see the overlay in `body`.
    @State private var confirmation: String?
    /// The selected node's kind, resolved OUTSIDE `body`.
    ///
    /// **The read has to happen somewhere that is not the view-update path**: a
    /// `model.scene` read in `body` puts the window on the drag loop. The
    /// `.onChange` below runs on a selection change, so it may read the scene;
    /// `body` reads a plain `@State` that moves only when the selection does.
    @State private var selectedNodeKind: CanvasNodeKind?

    /// Pure and static so the enablement rule is reachable from a test that
    /// hosts no SwiftUI — and so adding a `CanvasSelection` case makes the
    /// compiler enumerate this decision with everything else.
    ///
    /// **`nodeKind` is the item-node guard, and it reads the PROVENANCE.** A
    /// *referenced* item node already exists as itself, so `Promotion.targets`
    /// offers it nothing; an *owned* one exists nowhere but the canvas (spec §6,
    /// 2026-07-30), so refusing it would strand the photograph. It takes the
    /// kind rather than the scene: the whole scene is what this modifier must
    /// never read.
    ///
    /// **This and `Promotion.targets` must agree**, or the two halves of one
    /// decision drift: enabled here and empty there is the dead sheet above,
    /// disabled here and offered there is a command greyed out over a promotion
    /// that would work. `PromotionCommandTests` drives both from one table.
    ///
    /// **`isReadOnly` greys it out whatever is selected** (issue #44): promoting
    /// writes a mark into the layout file this build refused, and the artifact
    /// would be made before the mark was refused. `PromotionPerformer` refuses
    /// the same fact at its door.
    static func isPromotable(persona: Persona,
                             selection: CanvasSelection?,
                             nodeKind: CanvasNodeKind?,
                             isReadOnly: Bool) -> Bool {
        // The predicate, never a persona equality: the board is Plan's centre
        // column, and that is the fact enablement turns on. An equality here
        // once greyed `Promote…` out over a card the writer had selected.
        guard persona.centresTheCanvas, !isReadOnly else { return false }
        switch selection {
        case .node:
            switch nodeKind {
            case .scrap: return true
            case .item(let reference):
                if case .owned = reference { return true }
                return false
            case nil: return false
            }
        case .region, .line: return true
        case nil: return false
        }
    }

    func body(content: Content) -> some View {
        content
            // `sheet == nil` is joined HERE rather than inside `isPromotable`: the
            // pure function stays a fact about the canvas a test can drive, and
            // presentation state stays where presentation lives. Without it the
            // File item stays enabled while the sheet is up, and a ⌘⇧↩ there is
            // dropped because the sheet's window holds key status — an enabled
            // command that does nothing.
            .focusedSceneValue(\.canvasPromotable,
                               sheet == nil
                               && Self.isPromotable(persona: persona,
                                                    selection: model.selection,
                                                    nodeKind: selectedNodeKind,
                                                    isReadOnly: model.isReadOnly))
            // Reading `model.scene` HERE is safe and in `body` is not: an action
            // closure runs on a change rather than inside a view update, so the
            // scene never becomes a dependency of this modifier's body.
            .onChange(of: model.selection, initial: true) { _, selection in
                guard case .node(let id) = selection else { selectedNodeKind = nil; return }
                selectedNodeKind = model.scene.node(id)?.kind
            }
            .onKeyWindowCommand(.maughamPromoteCanvasSelection, window: window) { _ in begin() }
            .sheet(item: $sheet) { model in
                PromotionSheet(model: model,
                               onCommit: { commit($0) },
                               onCancel: { sheet = nil })
            }
            // **The result reaches the writer.** A line promotion sets no mark by
            // design, so without this the sheet closed and nothing observable
            // changed. The banner is `MCPNoteBanner`, the house pattern.
            .overlay(alignment: .top) {
                if let confirmation {
                    MCPNoteBanner(message: confirmation,
                                  onDismiss: { self.confirmation = nil })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: confirmation)
            .task(id: confirmation) {
                guard confirmation != nil else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                confirmation = nil
            }
            .alert("Promotion failed",
                   isPresented: Binding(get: { failure != nil },
                                        set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
    }

    /// The manifest is read ONCE, here, and handed to the sheet as plain values.
    private func begin() {
        guard let store, let selection = model.selection,
              Self.isPromotable(persona: persona, selection: selection,
                                nodeKind: selectedNodeKind,
                                isReadOnly: model.isReadOnly) else { return }
        let source: PromotionSource
        switch selection {
        case .node(let id): source = .scrap(id)
        case .region(let id): source = .region(id)
        case .line(let id): source = .line(id)
        }
        let research = store.manifest.research
        sheet = PromotionSheetModel(
            source: source, scene: model.scene, scraps: model.scraps,
            // **Both registries**: a mark can name a `Statement`, and an index
            // over research alone answers nil for one (see `ArtifactIndex.over`).
            artifacts: ArtifactIndex.over(research: research,
                                          statements: store.manifest.statements,
                                          structure: store.manifest.structure),
            // **The canvas's own index, the SAME builder the canvas is handed**.
            // A region's palette promotion carries the pictures in it, and a
            // referenced one's file is the manifest's to know — `ArtifactIndex`
            // deliberately holds no paths.
            items: ProjectWindow.canvasItemIndex(in: store),
            // Resolved here with the manifest, once: the sheet is pure values. The
            // performer resolves it again at Commit, because the plan is a snapshot
            // and the manifest can move under it.
            piece: PromotionPiece.resolve(for: source, in: model.scene, store: store),
            // **The store rather than the captured manifest**, the one value read
            // late by design: `readBody` is called from `select(_:)`, and a
            // statement's text comes from `statementText(of:)` — the pane's live
            // `Document` when there is one. The plain-values rule is about what the
            // sheet is HANDED; this is a reader it calls.
            readBody: { ProjectWindow.promotionDestinationBody(of: $0, in: store) })
    }

    private func commit(_ plan: PromotionPlan) {
        guard let store else { return }
        sheet = nil
        Task { @MainActor in
            do {
                let result = try await PromotionPerformer(store: store, model: model)
                    .perform(plan)
                confirmation = result.confirmation(for: plan)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
