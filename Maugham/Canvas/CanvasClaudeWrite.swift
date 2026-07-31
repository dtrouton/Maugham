import Foundation

/// **How a plan reaches the canvas — one definition, whether or not the writer has
/// it on screen.**
///
/// Task 3 decided *where* Claude's cards go and never touched anything. This is
/// the impure half: it finds the canvas that is real and writes to it. Both MCP
/// tools in this slice go through here, so a route that placed a batch differently
/// — or lost one — would do so for every caller at once.
///
/// **Two routes, and the discriminator is `CanvasModel.isAttached`, never
/// `liveCanvas != nil`.** The model is created eagerly with `ProjectWindow` and is
/// only attached while the Plan persona is on screen, so a project window whose
/// writer has never opened it holds a model that is real, addressable and
/// unusable — and a detached one's scene is the snapshot from when the persona
/// closed, which cannot see anything the sidecar route has written since. Either
/// way a write into one is accepted, reports real ids, and **vanishes** the next
/// time the writer opens the Plan persona, with nothing red. `CanvasModel`'s own
/// doc comment spells out what each of the two costs.
///
/// | | attached | otherwise |
/// |---|---|---|
/// | read | the model's `scene` and `scraps` | `CanvasStore.load()` |
/// | write | `mutateFromInspector`, then the bump, then `flush()` | `load()` → `apply` → `save` |
///
/// **Nothing here is `async`, deliberately.** `CanvasClaudePlacement.apply` takes
/// an `inout CanvasScene`, and an `inout` cannot cross a suspension point — that is
/// a fact about Swift 6 rather than a style choice, and it is the whole reason
/// `PromotionPerformer` does its awaiting before it touches the scene. Neither
/// route needs to await anything, so the constraint costs nothing; a future
/// caller that must await belongs on the far side of this call, not inside it.
@MainActor
enum CanvasClaudeWrite {

    /// What the writer's Edit menu reads after a batch arrives.
    ///
    /// One name for the whole add — the region, the source page, every card, every
    /// word and every line — because it is one arrival and one ⌘Z. It matches
    /// `CanvasClaudePlacement.defaultRegionLabel`'s "Claude" rather than inventing
    /// a second way to say the same thing, and the tests read this constant rather
    /// than a literal so the two cannot drift.
    static let undoStepName = "Add Scraps from Claude"

    /// The canvas a tool should read, and which one it was.
    ///
    /// `fromOpenCanvas` is reported rather than inferred, for the reason
    /// `read_preview_page` puts the preview's filename and mtime in its response:
    /// where the answer came from is a fact the caller needs and cannot recover.
    static func readScene(store: ProjectStore,
                          projectRoot: URL) -> (scene: CanvasScene,
                                                scraps: [CanvasNodeID: String],
                                                fromOpenCanvas: Bool) {
        if let model = liveModel(of: store) {
            // The scrap the writer is typing into right now is already here: the
            // mounted editor folds every keystroke into `scraps` (tripwire 28), so
            // the live model is ahead of the sidecar and never behind it.
            return (model.scene, model.scraps, true)
        }
        let loaded = CanvasStore(projectRoot: projectRoot).load()
        return (loaded.scene, loaded.scraps, false)
    }

    /// Write a plan to whichever canvas is real.
    ///
    /// **The plan is the whole payload.** It carries each scrap's text
    /// (`Plan.scrapTexts`), so there is no second parameter that could pair the
    /// wrong words with the wrong card — and both routes write the words and the
    /// cards from the one value.
    ///
    /// **A plan is only valid against the scene it was planned against**
    /// (`CanvasClaudePlacement.apply`'s doc comment says why: its ids are unique
    /// against that scene and its frame was computed from that scene's occupancy).
    /// So a caller plans against `readScene` and applies immediately; it must not
    /// hold a plan across anything that could write to the canvas in between.
    ///
    /// `throws` because both callers are throwing MCP handlers and the sidecar
    /// route is a disk write. Nothing throws today — `CanvasStore` swallows its own
    /// I/O errors, the same way every other writer of the sidecar does — and the
    /// signature is the one the tools are written against rather than one they
    /// would have to change to report a failure this layer starts detecting.
    static func apply(_ plan: CanvasClaudePlacement.Plan,
                      store: ProjectStore,
                      projectRoot: URL) throws {
        if let model = liveModel(of: store) {
            // **ONE bracket for the whole batch, and it is `mutateFromInspector`
            // rather than `mutate` — tripwire 32, whose sharpest repro is this
            // one.** An MCP call can arrive while the writer is inside a scrap
            // with "Edit Scrap" held open, and *nothing on this side of the window
            // closes their gesture*: `commitActiveEdit` runs from
            // `CanvasView.handleClick`, which only fires for clicks on the canvas.
            // Through `mutate` the write NESTS — `beginGesture` takes no snapshot
            // at depth 2, `endGesture` registers nothing above depth 0 — so
            // Claude's nodes reach no undo step of their own and ride into the
            // writer's next sentence: a ⌘Z aimed at a sentence takes the whole
            // batch with it, and a quit before returning to the canvas drops the
            // lot. `mutateFromInspector` is close-run-reopen, which is what
            // `CanvasUndo.undo()` already does.
            //
            // The words travel with the scene change rather than around it, so one
            // ⌘Z restores the cards and their text in step; the parameter's doc
            // comment on `CanvasModel` says what each of the two other orderings
            // costs.
            model.mutateFromInspector(undoStepName, scrapTexts: plan.scrapTexts) {
                CanvasClaudePlacement.apply(plan, to: &$0)
            }
            // On its own line after the bracket, exactly as `PromotionPerformer.mark`
            // does it: the accessibility tree and the region inspector's cached
            // member lists are keyed on this counter, and a structural change made
            // from outside the canvas has to reach both.
            model.bumpSceneRevision()
            // Now, not in 750 ms. A tool that answers "added" with the words only
            // in memory has lied if the app is quit inside the debounce window, and
            // the canvas has no op log behind it — `canvas.md` and `canvas.json`
            // are the only records (`Maugham/Canvas/AREA.md`, "The crash floor").
            model.flush()
            return
        }

        let sidecar = CanvasStore(projectRoot: projectRoot)
        var (scene, scraps) = sidecar.load()
        CanvasClaudePlacement.apply(plan, to: &scene)
        // `merge` rather than an assignment per key, and `{ _, new in new }` rather
        // than a trap: the ids are freshly minted against this very scene so a
        // collision is unreachable, and the reasoning that keeps a bad
        // `connections` pair from crashing an MCP call applies here or it applies
        // nowhere.
        scraps.merge(plan.scrapTexts) { _, new in new }
        // `save` rather than `scheduleSave`, for the reason the `flush()` above
        // exists: this store is transient and nothing would ever fire its debounce.
        sidecar.save(scene: scene, scraps: scraps)
    }

    /// The live canvas, or nil — the one place the discriminator is spelled, so the
    /// read and the write cannot come to different conclusions about which canvas
    /// is real.
    ///
    /// **Internal rather than private, for one caller and under a census.**
    /// `CanvasCapture` (1C-d Task 12, spec §8A.4) is the second writer with two
    /// routes into the same pair of canvases, and a second `store.liveCanvas,
    /// model.isAttached` written there would be exactly the divergence this
    /// function exists to prevent. That the pair appears in production **once** is
    /// held by `CanvasLiveSeamTests.test_theLiveCanvasDiscriminatorIsSpelledOnce`,
    /// with a planted-offender companion — not by this comment.
    static func liveModel(of store: ProjectStore) -> CanvasModel? {
        guard let model = store.liveCanvas, model.isAttached else { return nil }
        return model
    }
}
