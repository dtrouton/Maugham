import AppKit
import Foundation
import UniformTypeIdentifiers

/// **What a thing dropped on the canvas means, and how it lands** (spec §8A.1).
///
/// The binder sits beside the canvas in the Plan persona and its research tree is
/// the natural source, so dropping a research item on the canvas makes an item
/// node at the drop point: the file is untouched, the canvas holds a position
/// (§3.1). Until 1C-d nothing in production made an item node except
/// `CanvasClaudePlacement`, on Claude's behalf; this is the writer's own route.
///
/// **Why the decision is a pure function and the mount is a census.** SwiftUI's
/// drop delivery is not drivable from XCTest — there is no seam to post a drag
/// session into, the way `CanvasEventNSView.applyMouseDown` gives the mouse one.
/// So the *decision* lives somewhere a test can reach exhaustively, and the
/// *wiring* is pinned by
/// `PromotionCommandTests.test_theCanvasWiringCensusNamesEveryProductionSite`
/// instead. That is 1C-b's recorded lesson (routing decisions want a pure
/// function tested over the whole product) applied to a surface where the
/// alternative is not available: a router with no modifier on it would be this
/// area's fifth built-and-unreachable half, and all four previous ones were found
/// by counting callers rather than by a test.
///
/// **The payload is a bare research item id, and the id space is about to have a
/// neighbour.** `ResearchRow.swift:64` sends `item.id` through `.draggable`, which
/// is the app's established pattern — but the binder sends manuscript pieces and
/// tasks with the *same* raw-id payload (`PieceRow.swift`, `TasksPane.swift`), so
/// a string arriving here is not necessarily a research item at all. Everything
/// this router refuses, it refuses by not finding the id in `CanvasItemIndex`;
/// see `decide`. **A second id space must therefore arrive PREFIXED** — an inbox
/// entry's ULID and a research id are not tellable apart, and a bare one would be
/// silently refused by the rule in the paragraph above rather than routed.
@MainActor
enum CanvasDrop {

    /// What the writer's Edit menu reads after a drop.
    ///
    /// One name for the whole act — the card and its membership together — because
    /// it is one gesture and one ⌘Z. Read by the tests as a constant rather than
    /// as a literal, so the assertion and the menu cannot drift apart.
    static let undoStepName = "Add to Canvas"

    /// What a dropped payload means. Three answers, and the middle one is the
    /// whole reason this is a decision rather than an insert.
    enum Decision: Equatable {
        /// The payload names nothing this canvas can hold. Nothing happens, and
        /// the drop is declined so the source shows the writer a refusal.
        case ignored

        /// The item already has a node here. Select it and bring it on screen —
        /// **do not re-create it and do not move it.**
        case reveal(CanvasNodeID)

        /// Make this node. Already carries its origin, its width, its z and a
        /// measured height — see `decide`.
        case create(CanvasNode)
    }

    /// Decide what a payload dropped at `contentPoint` means.
    ///
    /// **Validated against `CanvasItemIndex` before anything is created**, and the
    /// index is already a parameter of `CanvasView`, so this costs no new wiring.
    /// A node created for an id in no manifest draws `CanvasItemFacts.missingTitle`
    /// — *"No longer in the project."* — **from birth**: a card the writer can
    /// neither fix nor explain, made by an act they performed correctly. Refusing
    /// is the only honest answer, and it also disposes of every id space the binder
    /// drags that is not research (a manuscript piece, a task).
    ///
    /// **A research GROUP is accepted**, and the two neighbouring rulings do not
    /// disagree with that even though they read as if they might.
    /// `AddCanvasScrapsTool` *refuses* a group id, because a folder is not a page
    /// Claude can have read a batch of scraps off, and `item:<groupId>` would be a
    /// node minted by no other route. This is the opposite case: the writer is
    /// pointing at a folder they can see in their own binder, `CanvasItemKind.group`
    /// exists for exactly that, and Task 4 already ruled that resolving a group is
    /// right because *"'no longer in the project' said over a folder the writer can
    /// see in the binder is a lie"*. So the glyph, the title and the card all
    /// already work; refusing would be inventing a second rule for the case the
    /// first one was written for.
    ///
    /// **A second drop of an id already on the canvas is `.reveal`, never a second
    /// `.create`.** `CanvasNodeID.item(_:)` derives the id from the reference, so
    /// both drops resolve to one id, and `CanvasScene.insert` is keyed by id — a
    /// re-insert would **overwrite** the existing node, silently discarding its
    /// membership, its promotion mark, its width, its z and its author. Moving it
    /// to the new drop point is not the alternative either: that is a
    /// geometry-driven change to something the writer placed, which is the
    /// transition rule §4.2 exists to eliminate and is why
    /// `CanvasClaudePlacement.PlannedSource` cites an existing page rather than
    /// relocating it.
    ///
    /// **The created node is born MEASURED, at `CanvasCardMetrics.itemLabelOnlyHeight`.**
    /// A node with no `cachedHeight` has no `frame`, and both
    /// `CanvasScene.nodes(intersecting:)` and `topmostNode(at:)` drop one that has
    /// none — neither drawn nor clickable, and persisted that way through a save.
    /// That is 1C-c3's whole-branch Critical, and this is the door it would arrive
    /// through next. The floor is the honest number rather than a placeholder: an
    /// item card's height *is* the label-only floor until its thumbnail decodes, and
    /// the decode is unbounded while the writer is holding a mouse button.
    /// `CanvasClaudePlacement` writes the same constant at creation for the same
    /// reason, and `CanvasView.rebuildLayouts` refines it to the picture's real
    /// shape on the very next pass — inside the same undo bracket, see `apply`.
    ///
    /// The drop point is the card's ORIGIN, exactly as `CanvasInteraction.createScrap`
    /// treats a double-click's point: one rule for where a new card appears.
    static func decide(payload: String,
                       at contentPoint: CGPoint,
                       in scene: CanvasScene,
                       index: CanvasItemIndex) -> Decision {
        guard index.entry(of: payload) != nil else { return .ignored }
        let id = CanvasNodeID.item(payload)
        guard scene.node(id) == nil else { return .reveal(id) }
        return .create(CanvasNode(id: id,
                                  kind: .item(.project(id: payload)),
                                  origin: contentPoint,
                                  width: CanvasInteraction.defaultScrapWidth,
                                  cachedHeight: CanvasCardMetrics.itemLabelOnlyHeight,
                                  z: scene.topZ + 1))
    }

    /// Land a `.create` decision: one undo step, one card, and the membership the
    /// drop point means.
    ///
    /// **`mutateFromInspector` and not `mutate` — tripwire 32, from a fifth
    /// direction.** A drag that starts in the binder never reaches
    /// `CanvasView.handleClick`, and `handleClick` is the only thing that runs
    /// `commitActiveEdit`. So the writer can be inside a scrap with "Edit Scrap"
    /// held open at the moment the drop lands, and *nothing on either side of the
    /// drag closes their bracket*: double-click bare canvas, type, then drag a
    /// research row in without touching the canvas again. Through the inside verbs
    /// this **nests** — `beginGesture` takes no snapshot at depth 2 and
    /// `endGesture` registers nothing above depth 0 — so the card reaches no undo
    /// step of its own and rides into the writer's next sentence, where a ⌘Z aimed
    /// at that sentence takes the card with it. The verb's delivery *site* is the
    /// canvas view; what tripwire 32 turns on is whether the arriving mutation has
    /// a bracket **of its own** to protect, and a drop has none, exactly as an
    /// `add_canvas_scraps` call has none. `CanvasView.deleteSelection`'s refusal is
    /// the other answer and is wrong here: mid-gesture a ⌫ is genuinely ambiguous,
    /// and a drop is not — refusing would make dragging a note in do nothing at
    /// all whenever the writer had a scrap open, silently.
    ///
    /// The accepted cost, which is the same one every other user of this verb
    /// pays: with "Edit Scrap" open, the drop closes the writer's run of typing
    /// into its own step first and reopens the visit afterwards, so they get one
    /// extra ⌘Z boundary in a sentence they were part-way through.
    ///
    /// **Insert and join in ONE body, and there is no ordering to get wrong here
    /// because the node arrives measured.** `joinTarget` reads the node's CENTRE
    /// and returns nil for a node with no `frame`, so a join asked of an
    /// unmeasured node silently joins nothing — on every drop, for ever, with
    /// nothing red. `decide` closes that by construction rather than by an
    /// ordering: the card is born at `CanvasCardMetrics.itemLabelOnlyHeight`, the
    /// same constant `CanvasClaudePlacement` writes at creation for the same
    /// reason. The refinement to the picture's real height arrives on the next
    /// line anyway — `mutateFromInspector` fires `onSceneChangedExternally`, which
    /// `CanvasView` binds to `rebuildLayouts`, **inside this bracket** — so the
    /// re-measure belongs to the step the writer can take back.
    ///
    /// The consequence of measuring at the floor is stated rather than avoided:
    /// the centre the join reads is the label-only card's, so an item whose
    /// photograph has not decoded yet joins by a centre 17 pt below its origin
    /// rather than by the taller card's. Awaiting a decode to make it exact is not
    /// available — the wait is unbounded and the writer is holding a mouse button.
    ///
    /// **The bump is on its own line**, as it is for every writer that reaches the
    /// scene through this verb: a region inspector open in the other column has to
    /// see the card that just joined, or it goes on showing "No cards live in this
    /// region yet" over a card the canvas has already drawn inside it.
    static func apply(_ node: CanvasNode, in model: CanvasModel) {
        model.mutateFromInspector(undoStepName) { scene in
            scene.insert(node)
            // Tripwire 31: this is the drop's ONE geometric reading, it is
            // `CanvasInteraction.joinTarget`'s rather than a second
            // `region.frame.contains(…)` written here, and it reads the node's
            // CENTRE. Creation absorbs; transitions never do.
            if let home = CanvasInteraction.joinTarget(for: node.id, in: scene) {
                CanvasMembership.join(node.id, home: home, in: &scene)
            }
        }
        model.bumpSceneRevision()
    }
}

/// The canvas's asset well, as a pair of closures the view can be handed.
///
/// **A seam, and it exists for two reasons that both matter.** `CanvasView` has
/// ~70 test hosts and no `ProjectStore` — handing it the store to reach two
/// methods would put the whole store on a view whose job is drawing — and the
/// *routing* (which drag reaches which twin) is the only part of this task that
/// is not already covered by `CanvasAssetIngestionTests`, so it has to be
/// drivable without a project on disk.
///
/// **`unavailable` throws rather than returning nil, deliberately.** A default
/// that quietly did nothing is precisely how a wiring omission goes unnoticed;
/// throwing puts the failure in front of the writer, and the production wiring
/// is censused by name in
/// `PromotionCommandTests.test_theCanvasWiringCensusNamesEveryProductionSite`.
@MainActor
struct CanvasAssetIngest {
    /// Copy a file the writer dropped into the well. Extension preserved.
    var file: (URL) async throws -> String
    /// Ingest a rendered bitmap (a browser drag) into the well, as PNG.
    var image: (NSImage) async throws -> String

    struct Unavailable: Error {}

    static var unavailable: CanvasAssetIngest {
        CanvasAssetIngest(file: { _ in throw Unavailable() },
                          image: { _ in throw Unavailable() })
    }
}

/// **A photograph dropped on the canvas from the Finder or a browser** (spec
/// §8A.1) — the *external* half of the drop target, beside `CanvasDrop`'s
/// internal one.
///
/// **Owned, because it exists nowhere else in the project.** A research row
/// dragged out of the binder is a *reference*: the file has a home already and
/// the canvas holds only its position. A photograph from Pictures or from a web
/// page has no home here at all, so it is ingested into `canvas_assets/` and the
/// node holds `CanvasItemReference.owned(path:)`. The id is MINTED — there is
/// nothing to deduplicate, and a filesystem path in an identity would put
/// tripwire 22's rename hazard in the one field nothing may rewrite
/// (`CanvasNodeID`).
///
/// **`[.fileURL, .image]` providers, never `.dropDestination(for: URL.self)`.**
/// A browser image drag carries a *rendered bitmap* and no file URL, so that
/// modifier rejects it with CoreTransferable error 0: nothing logged, nothing
/// red, nothing on screen. The canvas is `DropClassification`'s **fifth**
/// adopter and adds no classification logic of its own — it routes that type's
/// two answers to the two halves of `ProjectStore.ingestCanvasAsset`, which is
/// the palette well's shape one surface over. `TripwireGrepTests` censuses the
/// required token and bans the forbidden one, because SwiftUI's drop delivery
/// has no seam a test can post a drag session into.
@MainActor
enum CanvasExternalDrop {

    /// What one drop did, and what to tell the writer about it.
    ///
    /// Refusals and failures are separate because they are separate facts: a
    /// `.txt` was never something the canvas could hold, while a `.png` that
    /// threw is something that should have worked.
    struct Outcome: Equatable {
        /// Project-relative paths, in drop order, one per file that landed.
        var paths: [String] = []
        /// Names the canvas declined — not pictures.
        var refused: [String] = []
        /// Names whose ingestion threw.
        var failed: [String] = []

        /// **What the writer reads, or nil when everything landed.**
        ///
        /// A failed drop that says nothing is indistinguishable from a broken
        /// surface, which is this route's named failure. It NAMES the files,
        /// because a writer who dragged four photographs in needs to know which
        /// one did not arrive.
        var message: String? {
            var parts: [String] = []
            if !refused.isEmpty {
                parts.append("The canvas holds pictures, so \(Self.list(refused)) "
                             + (refused.count == 1 ? "was" : "were") + " not added.")
            }
            if !failed.isEmpty {
                parts.append("Couldn't add \(Self.list(failed)) to the canvas.")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        private static func list(_ names: [String]) -> String {
            names.map { "“\($0)”" }.joined(separator: ", ")
        }
    }

    /// A generic name for a drag that carries no filename at all — a browser's
    /// rendered bitmap. Used only in a failure message.
    static let bitmapName = "the dropped image"

    /// Whether this provider is one the canvas could take. Read **synchronously**
    /// by the drop modifier so a drag carrying neither a file nor an image is
    /// declined outright and springs back, rather than being accepted and then
    /// silently amounting to nothing.
    static func accepts(_ provider: NSItemProvider) -> Bool {
        classify(provider) != .ignore
    }

    /// Whether the canvas can hold this file.
    ///
    /// **Scoped to the canvas on purpose.** The shared saver
    /// (`ImagePasteHandler.saveAndReferenceFile`) takes `pathExtension` as given
    /// and validates nothing, so an unchecked drop copies a `.txt` into
    /// `canvas_assets/`, mints an owned node, draws the photograph glyph and
    /// queues a decode that can only fail — and `CanvasThumbnails` **memoises
    /// failures** with no `invalidate`, so it is one permanent dead cache entry
    /// per mistake. The hole is probably wider than the canvas (research notes
    /// and palette cards reach the same saver), and widening the shared saver is
    /// not this task's to do; checking here fixes the surface that is being built.
    ///
    /// The file's real type first, its extension second: a file with no extension
    /// still has a type on disk, and a drag from a sandboxed source may not.
    static func isIngestableImage(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .image)
    }

    /// Ingest every provider a drop carried, in order.
    ///
    /// **Await first, touch the scene second** — which is Swift rather than
    /// style: `ingestCanvasAsset` is `async throws` and an `inout CanvasScene`
    /// cannot cross a suspension point. So this returns paths and `apply` makes
    /// the cards, exactly as `CanvasClaudeWrite` and `PromotionPerformer` split
    /// for the same reason.
    static func ingest(providers: [NSItemProvider],
                       using ingest: CanvasAssetIngest) async -> Outcome {
        var outcome = Outcome()
        for provider in providers {
            switch classify(provider) {
            case .fileURL:
                guard let url = await DropClassification.fileURL(from: provider) else {
                    outcome.failed.append(bitmapName)
                    continue
                }
                guard isIngestableImage(url) else {
                    outcome.refused.append(url.lastPathComponent)
                    continue
                }
                do { outcome.paths.append(try await ingest.file(url)) }
                catch { outcome.failed.append(url.lastPathComponent) }

            case .image:
                guard let image = await DropClassification.image(from: provider) else {
                    outcome.failed.append(bitmapName)
                    continue
                }
                do { outcome.paths.append(try await ingest.image(image)) }
                catch { outcome.failed.append(bitmapName) }

            case .ignore:
                continue
            }
        }
        return outcome
    }

    /// Land the ingested paths as owned item nodes: **one undo step for the whole
    /// drop**, each card measured, each joined by its own centre.
    ///
    /// **`mutateFromInspector`, carried from Task 10 and for its reason.** What
    /// tripwire 32 turns on is whether the arriving mutation has a bracket of its
    /// own to protect, and a drag beginning in the Finder has none — the writer
    /// can be inside a scrap with "Edit Scrap" open, and *nothing on either side
    /// of the drag closes it*. Through the inside verbs the drop nests and reaches
    /// no undo step of its own, so a ⌘Z aimed at a sentence takes the photograph
    /// with it.
    ///
    /// **Born measured at `CanvasCardMetrics.itemLabelOnlyHeight`**, the same
    /// constant `CanvasDrop.decide` and `CanvasClaudePlacement` write at creation:
    /// a node with no `cachedHeight` has no `frame`, so it is neither drawn nor
    /// clickable *and* `joinTarget` returns nil for it — a join that silently
    /// joins nothing. `CanvasView.rebuildLayouts` refines the height to the
    /// picture's real shape on the next pass, inside this bracket.
    ///
    /// **Several files CASCADE rather than stacking or columning.** Two cards at
    /// one point read as one card, and the writer concludes the rest were lost.
    /// A column is the other candidate and is not available here: a column has to
    /// be laid out against the cards' heights, and an item card's height is its
    /// photograph's, which has not decoded yet and cannot be waited for while the
    /// writer holds a mouse button. A cascade at `CanvasClaudePlacement.cardGap`
    /// stays true whatever the pictures turn out to be.
    @discardableResult
    static func apply(paths: [String],
                      at contentPoint: CGPoint,
                      in model: CanvasModel) -> [CanvasNodeID] {
        guard !paths.isEmpty else { return [] }
        var made: [CanvasNodeID] = []
        model.mutateFromInspector(CanvasDrop.undoStepName) { scene in
            for (step, path) in paths.enumerated() {
                // Minted against the LIVE scene as each card is inserted, so a
                // batch cannot collide with itself (tripwire 23's lesson).
                let id = CanvasInteraction.newNodeID(in: scene)
                let gap = CanvasClaudePlacement.cardGap * CGFloat(step)
                scene.insert(CanvasNode(
                    id: id,
                    kind: .item(.owned(path: path)),
                    origin: CGPoint(x: contentPoint.x + gap, y: contentPoint.y + gap),
                    width: CanvasInteraction.defaultScrapWidth,
                    cachedHeight: CanvasCardMetrics.itemLabelOnlyHeight,
                    z: scene.topZ + 1))
                // Tripwire 31: the drop's ONE geometric reading, the existing
                // spelling, and it reads the node's CENTRE. Creation absorbs.
                if let home = CanvasInteraction.joinTarget(for: id, in: scene) {
                    CanvasMembership.join(id, home: home, in: &scene)
                }
                made.append(id)
            }
        }
        model.bumpSceneRevision()
        return made
    }

    private static func classify(_ provider: NSItemProvider) -> DropAction {
        DropClassification.action(
            hasFileURL: provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            canLoadImage: provider.canLoadObject(ofClass: NSImage.self))
    }
}
