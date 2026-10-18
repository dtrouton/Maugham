import SwiftUI
import MaughamCore
import AppKit
import os

/// The canvas's `Promote…` command: enablement, presentation and performance,
/// all in one place so `ProjectWindow.body` gains a single line.
///
/// **`internal`, not `private`, and that is required rather than a style
/// choice**: `@testable import` reaches `internal` and cannot see `private`, and
/// `isPromotable` below is the enablement rule a test drives. `PersonaModifier`
/// in this same file is non-private for exactly that reason; the ones that are
/// private have nothing a test needs.
///
/// **It reads `model.selection` and must NEVER read `model.scene`.**
/// `CanvasModel` is `@Observable` with the whole scene in one stored property,
/// and every drag frame and every coast frame writes it — a read here would put
/// the window's body on the drag loop at 60–120 Hz. `selection` moves on a
/// click. The same rule keeps `store` off this path except inside the two
/// actions below, which run from a user gesture: `begin()` snapshots the
/// manifest once, and `commit(_:)` performs.
///
/// **Measured 2026-07-28** (Debug, macOS 26.5), through a real `CanvasView` in a
/// real `NSHostingView` with the drag driven through the production
/// `CanvasEventNSView` seam: **120 drag frames evaluated this modifier's body
/// once** — the one selection change the opening mouse-down makes — and
/// evaluated the enclosing `ProjectWindow`-shaped body **zero** times. The
/// instrument was calibrated rather than trusted: ten writes to `model.selection`
/// produced exactly ten evaluations, so a result of 1 is a real 1 and not a
/// blind counter. The read is safe because a `ViewModifier`'s body is its own
/// view — SwiftUI's tracking records `selection`, not the window that built it.
struct CanvasPromotionModifier: ViewModifier {
    let window: NSWindow?
    let store: ProjectStore?
    let model: CanvasModel
    /// The window's working mode — the basis of `isPromotable` since stage 2b
    /// Task 6, because the board is Plan's centre column.
    let persona: Persona

    @State private var sheet: PromotionSheetModel?
    @State private var failure: String?
    /// What was just produced, in one sentence. Nil when there is nothing to
    /// confirm — see the overlay in `body`.
    @State private var confirmation: String?
    /// The selected node's kind, resolved OUTSIDE `body`.
    ///
    /// **The read has to happen somewhere that is not the view-update path.** A
    /// `model.scene` read in `body` puts the window on the drag loop (see this
    /// type's own doc comment), and the kind is a fact about the scene. The
    /// `.onChange` below runs on a selection change rather than on a body pass,
    /// so it may read the scene freely; `body` then reads a plain `@State`
    /// value that moves only when the selection does.
    @State private var selectedNodeKind: CanvasNodeKind?

    /// Pure and static so the enablement rule is reachable from a test that
    /// hosts no SwiftUI — and so adding a `CanvasSelection` case makes the
    /// compiler enumerate this decision with everything else.
    ///
    /// **`nodeKind` is the item-node guard, and since 1C-d it reads the
    /// PROVENANCE rather than the kind.** A *referenced* item node already
    /// exists as itself, so `Promotion.targets` offers it nothing — and this
    /// said yes for every `.node`, so `Promote…` was enabled and ⌘⇧↩ opened a
    /// sheet that could never commit. An *owned* one is the case that refusal
    /// was never about (spec §6, 2026-07-30): it exists nowhere but the canvas,
    /// and refusing it strands the photograph the writer just sent there. It
    /// takes the kind rather than the scene on purpose: the whole scene is what
    /// this modifier must never read.
    ///
    /// **This and `Promotion.targets` must agree**, or the two halves of one
    /// decision drift: enabled here and empty there is the dead sheet above,
    /// disabled here and offered there is a command greyed out over a promotion
    /// that would work. `PromotionCommandTests` drives both from one table.
    static func isPromotable(persona: Persona,
                             selection: CanvasSelection?,
                             nodeKind: CanvasNodeKind?) -> Bool {
        // **The predicate, and this was the FOURTH site that spelled the canvas
        // check as an equality** — not one of the three the slice-2 plan named,
        // found by grepping the comparison rather than reading the list. The
        // canvas was on screen under Plan's structure tab with a live selection
        // in it, so an equality here greyed `Promote…` out and dropped ⌘⇧↩ over
        // a card the writer could see and had selected. Re-based on the persona
        // in stage 2b Task 6, which is where it stays: the board is Plan's
        // centre column, and that is the fact enablement turns on.
        guard persona.centresTheCanvas else { return false }
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
            // `sheet == nil` is joined HERE rather than inside `isPromotable`,
            // and that is deliberate: the pure function stays a fact about the
            // canvas (persona plus selection) that a test can drive, while
            // presentation state stays where presentation lives. Without it the
            // File item is still enabled while the sheet is up — selection and
            // persona have not moved — and a ⌘⇧↩ there is dropped by the very
            // rule the inspector buttons' comments cite, because the sheet's own
            // window holds key status. An enabled command that does nothing is
            // the condition `.disabled(promotable != true)` exists to prevent.
            .focusedSceneValue(\.canvasPromotable,
                               sheet == nil
                               && Self.isPromotable(persona: persona,
                                                    selection: model.selection,
                                                    nodeKind: selectedNodeKind))
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
            // **The result reaches the writer.** Every field of
            // `PromotionResult` used to be built and discarded here, and a line
            // promotion sets no mark by design — so the sheet closed and
            // nothing observable changed anywhere, on a surface whose whole
            // promise is that you can see what a command will do. The banner is
            // `MCPNoteBanner`, the house pattern for exactly this, rather than a
            // second one.
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
                                nodeKind: selectedNodeKind) else { return }
        let source: PromotionSource
        switch selection {
        case .node(let id): source = .scrap(id)
        case .region(let id): source = .region(id)
        case .line(let id): source = .line(id)
        }
        let research = store.manifest.research
        sheet = PromotionSheetModel(
            source: source, scene: model.scene, scraps: model.scraps,
            // **Both registries**: since M1A a mark can name a `Statement`, and
            // an index built over research alone answers nil for one — see
            // `ArtifactIndex.over` for the readers that then say something
            // false, and what each of them says.
            artifacts: ArtifactIndex.over(research: research,
                                          statements: store.manifest.statements,
                                          structure: store.manifest.structure),
            // **The canvas's own index, and the SAME builder the canvas is
            // handed above** (1C-d Task 12a). A region's palette promotion
            // carries the pictures in it, and a referenced one's file is the
            // manifest's to know — `ArtifactIndex` deliberately holds no paths.
            // One walk more, at the site that already walks this manifest twice
            // for this gesture, rather than a second path index of its own.
            items: ProjectWindow.canvasItemIndex(in: store),
            // Resolved here with the manifest, once, like the index beside it —
            // the sheet is pure values, and this is the one place the routing
            // table is read for it. The performer resolves it again at Commit,
            // because the plan is a snapshot and the manifest can move under it.
            piece: PromotionPiece.resolve(for: source, in: model.scene, store: store),
            // **The store rather than the captured manifest**, and it is the one
            // value here that is read late by design: `readBody` is called from
            // `select(_:)`, and a statement's text comes from `statementText(of:)`
            // — the pane's live `Document` when there is one, which no snapshot
            // taken at `begin()` can hold. The plain-values discipline above is
            // about what the sheet is HANDED; this is a reader it calls.
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
