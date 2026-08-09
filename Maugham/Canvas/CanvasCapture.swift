import Foundation

/// **A capture from the inbox, landing on the canvas** (spec §8A.4) — the first
/// arrow of `inbox → canvas → research`, whose second arrow has been promotion
/// (§6) since 1C-c2.
///
/// Until this slice the only road out of the inbox was *promote to research*,
/// which builds the durable artifact **before** the thinking and inverts what the
/// canvas is for (§1). Denver's ruling: *"this should NOT need to go via claude or
/// research notes. In many ways inbox to canvas to research makes more sense."*
///
/// **Two routes, and they differ in exactly one thing: where the card lands.**
/// The drag is primary — the row is dropped on the canvas and the capture lands
/// where the writer let go of it, so the canvas gains no placement rule for it.
/// The command has no drop point and takes the one stated fallback, `Placement`
/// below. Everything else — what each kind becomes, the undo bracket, which
/// canvas is real — is one path for both, which is what keeps an action from
/// behaving differently depending on how it was reached.
///
/// **It ships for all three capture kinds or it does not ship** (§8A.4). Text and
/// voice become a **scrap** — words into `canvas.md`, keyed by the new node's id,
/// exactly as a typed scrap's are — and a photograph becomes an **owned** item
/// node, because the inbox is a queue the writer *clears* and a node pointing into
/// one dangles the day they tidy up.
///
/// **This is a sibling of `CanvasClaudeWrite`, not a second spelling of it**, and
/// the part they must share is `liveModel` — the one place `store.liveCanvas` and
/// `isAttached` are written together, so no two writers can come to different
/// conclusions about which canvas is real. The file is deliberately *not* a
/// generalisation of that one: its name is about Claude and this is the writer's
/// own act, drawn tilted rather than straight and never announced as Claude's.
@MainActor
enum CanvasCapture {

    /// What the writer's Edit menu reads after a capture lands.
    ///
    /// One name for both routes and it matches the command's own label, so a ⌘Z
    /// after clicking **Send to Canvas** names the thing that was clicked. It is
    /// *not* `CanvasDrop.undoStepName` ("Add to Canvas"): that step is about a
    /// thing the project already has being placed on the canvas, and this one is
    /// about a capture leaving the inbox for good. The tests read this constant
    /// rather than a literal so the assertion and the menu cannot drift.
    static let undoStepName = "Send to Canvas"

    /// What a capture turns into. Two cases, because a photograph is the one kind
    /// with a file behind it — and the ingestion has already happened by the time
    /// a value of this type exists (`InboxStore.sendToCanvas` awaits it), which is
    /// what lets everything below be synchronous.
    enum Content: Equatable {
        /// A typed note's text, or a voice memo's transcript.
        case words(String)
        /// A project-relative path into `canvas_assets/`, from the one ingestion
        /// pair (`ProjectStore.ingestCanvasAsset`).
        case picture(path: String)
    }

    /// Where it lands — the two routes' only difference, as a value, so the
    /// ruling below is a thing a test can drive over the whole product rather
    /// than a sentence in a comment.
    enum Placement: Equatable {
        /// **The drag.** Exactly where the writer let go, joining whatever region
        /// its CENTRE lands in. The third caller of Task 10's drop target.
        case dropped(at: CGPoint)

        /// **The command.** No drop point, so: loose, clear of the writer's
        /// existing work, and **never in a region**.
        ///
        /// The asymmetry with §8A.2 is the amendment's own ruling rather than an
        /// inconsistency: *"Claude's batches take a region because constraint 2
        /// requires a derived scrap stay tied to its source, and a writer sending
        /// one capture has already decided what it is. A container they did not
        /// ask for and will delete is friction."* So this route does not call
        /// `joinTarget` — adding it for symmetry with the drag is that ruling
        /// broken, not a tidy-up.
        case loose
    }

    /// One capture's landing, decided and not yet written.
    ///
    /// **The words travel WITH the node**, exactly as `CanvasClaudePlacement.Plan`
    /// pairs its scraps with their text: a string handed alongside would be a
    /// second chance for the card and its words to disagree about which is which,
    /// and nothing downstream could tell.
    struct Landing: Equatable {
        let node: CanvasNode
        /// nil for a picture. A `scraps` entry for an item node would draw an
        /// empty card's worth of nothing over the photograph.
        let text: String?
        /// Whether this landing may take a region's membership. False for the
        /// command, by the ruling on `Placement.loose`.
        let joinsARegion: Bool

        /// The words keyed by the node that will hold them — the shape both
        /// `CanvasModel.mutateFromInspector(_:scrapTexts:)` and
        /// `CanvasStore.save(scene:scraps:)` want. Derived, so it cannot drift.
        var scrapTexts: [CanvasNodeID: String] {
            guard let text else { return [:] }
            return [node.id: text]
        }
    }

    // MARK: - Decide

    /// Decide where a capture lands, without touching the scene.
    ///
    /// **The node is born MEASURED.** A node with no `cachedHeight` has no
    /// `frame`, and both `CanvasScene.nodes(intersecting:)` and `topmostNode(at:)`
    /// drop one that has none — neither drawn nor clickable, and persisted that
    /// way through a save (1C-c3's whole-branch Critical). It also makes
    /// `joinTarget` silently return nil, so the drag's membership would join
    /// nothing, on every drop, for ever, with nothing red. A scrap is measured
    /// from its own words; a picture takes `itemLabelOnlyHeight`, the honest floor
    /// the other two item-node creators write, refined to the picture's real shape
    /// by `CanvasView.rebuildLayouts` on the next pass — inside the same bracket.
    static func plan(_ content: Content,
                     _ placement: Placement,
                     captureID: String,
                     in scene: CanvasScene) -> Landing {
        // DERIVED from the capture, never minted (RULING-8, M8-IN-004): a
        // promoted entry can never be re-sent (`entryNotFound`), so the only
        // reachable second send is the retry after a failed status flip — and
        // a derived id makes it land on the SAME card instead of a second one,
        // the shape the canvas already uses for a research row's second drop.
        let id = CanvasNodeID("cap-" + captureID)
        let origin: CGPoint
        let joins: Bool
        switch placement {
        case .dropped(let point):
            origin = point
            joins = true
        case .loose:
            // The ONE spelling of "clear of the writer's work" (§8A.4 amendment
            // names it by its rule). A second `occupied.maxX + gutter` here would
            // be two answers to one question that will drift.
            origin = CanvasClaudePlacement.looseOrigin(in: scene)
            joins = false
        }
        let width = CanvasInteraction.defaultScrapWidth
        switch content {
        case .words(let text):
            return Landing(
                node: CanvasNode(id: id, kind: .scrap, origin: origin, width: width,
                                 cachedHeight: CanvasScrapMeasure.height(text: text,
                                                                        cardWidth: width),
                                 z: scene.topZ + 1),
                text: text,
                joinsARegion: joins)
        case .picture(let path):
            return Landing(
                node: CanvasNode(id: id, kind: .item(.owned(path: path)), origin: origin,
                                 width: width,
                                 cachedHeight: CanvasCardMetrics.itemLabelOnlyHeight,
                                 z: scene.topZ + 1),
                text: nil,
                joinsARegion: joins)
        }
    }

    /// The only writer of a `Landing`, so the two persistence routes below produce
    /// identical scenes rather than similar ones.
    static func apply(_ landing: Landing, to scene: inout CanvasScene) {
        scene.insert(landing.node)
        guard landing.joinsARegion else { return }
        // Tripwire 31: the drop's ONE geometric reading, in the existing spelling,
        // reading the node's CENTRE. Creation absorbs; transitions never do.
        if let home = CanvasInteraction.joinTarget(for: landing.node.id, in: scene) {
            CanvasMembership.join(landing.node.id, home: home, in: &scene)
        }
    }

    // MARK: - Write

    /// Send a capture to whichever canvas is real, and report the node it made.
    ///
    /// **Planned against the scene it is about to be written to, each time.** A
    /// `Landing`'s id is unique against *that* scene, so planning once and
    /// applying twice would be the shape `CanvasClaudePlacement.apply`'s doc
    /// comment refuses; the two routes each plan for themselves.
    ///
    /// **`mutateFromInspector` and not `mutate` — tripwire 32.** What that
    /// tripwire turns on is whether the arriving mutation has a bracket **of its
    /// own** to protect, and neither route has one: a command from another column
    /// has no gesture at all, and a drag that begins in the Inbox pane never
    /// reaches `CanvasView.handleClick`, which is the only thing that runs
    /// `commitActiveEdit`. So the writer can be inside a scrap with "Edit Scrap"
    /// held open and *nothing on either side closes their bracket*. Through the
    /// inside verbs this nests — `beginGesture` takes no snapshot at depth 2 and
    /// `endGesture` registers nothing above depth 0 — so the capture reaches no
    /// undo step of its own and rides into the writer's next sentence.
    ///
    /// **The words travel INSIDE the bracket** via `scrapTexts:`, so one ⌘Z
    /// restores the card and its text in step; `CanvasModel` records both other
    /// orderings as measured failures. **The bump is on its own line**, because a
    /// region inspector open in the other column has to see a card that just
    /// joined. And `flush()` rather than `scheduleSave()`: this call returns to a
    /// writer who has been told the capture left the inbox, and the canvas has no
    /// op log behind it — a quit inside the 750 ms debounce would lose it.
    @discardableResult
    static func send(_ content: Content,
                     _ placement: Placement,
                     captureID: String,
                     store: ProjectStore,
                     projectRoot: URL) -> CanvasNodeID {
        let model: CanvasModel? = CanvasClaudeWrite.liveModel(of: store)
        if let model {
            let landing = plan(content, placement, captureID: captureID, in: model.scene)
            // The retry: the capture's derived node is already on the scene, so
            // there is nothing to write — the caller retries only the flip.
            if model.scene.node(landing.node.id) != nil { return landing.node.id }
            model.mutateFromInspector(undoStepName, scrapTexts: landing.scrapTexts) {
                apply(landing, to: &$0)
            }
            model.bumpSceneRevision()
            model.flush()
            return landing.node.id
        }

        // The Plan persona is closed — which is the command's whole point, since a
        // drag is unreachable from the keyboard and unavailable in another
        // persona. `CanvasClaudeWrite`'s second arm, for its reasons.
        let sidecar = CanvasStore(projectRoot: projectRoot)
        var (scene, scraps) = sidecar.load()
        let landing = plan(content, placement, captureID: captureID, in: scene)
        if scene.node(landing.node.id) != nil { return landing.node.id }
        apply(landing, to: &scene)
        scraps.merge(landing.scrapTexts) { _, new in new }
        // `save` and not `scheduleSave`: this store is transient and nothing would
        // ever fire its debounce.
        sidecar.save(scene: scene, scraps: scraps)
        return landing.node.id
    }

    // MARK: - Telling the writer

    /// Select the capture and bring it into sight — **now if a canvas is on
    /// screen, on its next appearance otherwise** (`CanvasModel.reveal` parks the
    /// request past `attach()`).
    ///
    /// **This is how the command route says *where*, and it may not be silent**
    /// (§8A.4's amendment): its landing place is `occupied.maxX + gutter`, which
    /// on any non-empty canvas is *by construction* outside the bounding box of
    /// the writer's own work and therefore outside their viewport. A send that
    /// left the inbox and appeared nowhere the writer is looking is the failure
    /// this route exists to remove.
    ///
    /// **The drag does not call this**, and that is the asymmetry doing its job:
    /// that capture landed under the pointer, so moving the camera to it would be
    /// a jump to somewhere the writer is already looking.
    ///
    /// `liveCanvas` without `isAttached`, deliberately and not an oversight: a
    /// detached model *parks* the request and replays it on the far side of the
    /// next `attach()`, which is the first moment its scene holds the node this
    /// send wrote to the sidecar. Asking `isAttached` here would drop the reveal
    /// in precisely the case the command exists for.
    static func show(_ node: CanvasNodeID, in store: ProjectStore) {
        guard let model = store.liveCanvas else { return }
        model.selection = .node(node)
        model.reveal(.node(node))
    }
}
