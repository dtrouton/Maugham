# Canvas — area guide

The Plan persona's centre column: a freeform planning canvas of scraps (the writer's words on cards), item nodes (research the canvas points at, or photographs it owns), regions, lines and the promotion that turns any of them into project artifacts. The one rule from CLAUDE.md: **membership never changes on a move or resize (tripwire 31).** The canvas carries tripwires 25–33. Its words live in `canvas.md` at the project root; its arrangement in the derived, deletable .maugham/canvas.json; its owned photographs in `canvas_assets/`. The why behind every rule below, and the history of each, is in `docs/history/canvas.md`.

## Map

Every file in `Maugham/Canvas/` appears once.

### The scene model (pure values)
- `CanvasScene.swift` — the scene: nodes, regions, lines, the hidden set; `nodes`/`unorderedNodes`, `topmostNode(at:)`, `nodes(intersecting:)`, `drawnLines`, `selectionTarget(at:)`, `remove`, `insertLine`.
- `CanvasNode.swift` — `CanvasNodeID` (`item(_:)` derives an item node's id), `CanvasNodeKind` (`.scrap`, `.item`; `carriesAMark`, `isScrap`), `CanvasNode`, and `CanvasCardMetrics`, the one card-geometry arithmetic.
- `CanvasItemReference.swift` — an item node's two provenances: `.project(id:)` (referenced) and `.owned(path:)` (a project-relative file in `canvas_assets/`).
- `CanvasRegion.swift` — `CanvasRegion` (label, frame, home members, appearances, bound piece, collapsed), `CanvasSelection`, `CanvasRegionMetrics`.
- `CanvasLine.swift` — `CanvasLine` (an untyped edge with an optional name), `CanvasDrawnLine`, `CanvasLineHit` (clamped segment distance, `tolerance`).
- `CanvasMembership.swift` — the whole membership mutation surface: `join`, `addAppearance`, `leave`, `homeRegion`, `appearanceRegions`, `residents`. Takes no point, rect or overlap (tripwire 31).
- `RegionBinding.swift` — `references(forPiece:in:)`, the reference projection (residents only, unioned across regions).
- `ScrapText.swift` — renders and parses `canvas.md`, the scrap text keyed by node id.

### Drawing and geometry
- `CanvasView.swift` — the SwiftUI view: layer stack, camera, layouts cache, editing focus, the straighten, momentum, `revision`/`sceneRevision` mirror, click/drag/drop/delete handlers (tripwires 27, 30, 32). Its header comment lists its source-layout contracts.
- `CanvasRenderer.swift` — the one draw pass (regions, lines, cards, chips, tethers), `CanvasFocusStraighten`, `cardTransform`/`seededRotation`, `paper(for:)`, `cullingBleed`, `rotationOverhang(of:)`, `elide` (tripwires 26, 29).
- `CanvasCamera.swift` — the manual pan/zoom transform; `bring(_:toViewPoint:)` and `revealViewPoint` (tripwire 25).
- `CanvasMaterial.swift` — every calibration constant of the canvas's look: ground, paper, tilt band, Claude's tints, dim (`dimmedAlpha(lit:)`).
- `CanvasGround.swift` — the ground view and `CanvasGroundPalette`, beneath the content.
- `CanvasGround.metal` — the ground shader; takes all material numbers as uniforms and holds no literals.
- `ScrapLayout.swift` — the one TextKit 2 stack per scrap, shared by the draw pass and the mounted editor (tripwire 26).
- `CanvasScrapMeasure.swift` — `height(of:)`/`height(text:cardWidth:)`, the only place `cardHeight(forTextHeight:)` meets `measuredHeight`; `scrapFont`; item-card metrics.
- `CanvasThumbnails.swift` — off-frame image decoding, an LRU byte-budgeted pixel cache, and the permanent aspect-ratio memo (tripwire 22's path key).

### Input
- `CanvasEventView.swift` — `CanvasEventNSView`: mouse, keys (⌫/⌦ as `backwardDelete`/`forwardDelete`), undo forwarding, Escape-consumer registration with `WindowEscapeArbiter`.
- `CanvasInteraction.swift` — the gesture state machine (move, resize, sweep, line), `joinTarget`, `absorbedNodes`, `isCaught`, `caughtRegions`, `sweepOutcome`, `regionHit`, `endLine`; `CanvasMomentum` (tripwire 31).
- `CanvasEscapeMonitor.swift` — the window-scoped local `NSEvent` monitor `WindowEscapeArbiter` holds one of per window.
- `ScrapEditorHost.swift` — the one mounted `NSTextView` (`ScrapEditorContainer`), its visibility and pointer transparency, `undo:`/`redo:` forwarding, `ScrapEditorGeometry` (tripwires 27, 28).
- `CanvasEditGate.swift` — what a read-only (refused-sidecar) canvas still offers: every gesture, key, drop and inspector control asks it first.

### State, persistence, undo
- `CanvasModel.swift` — the shared state the canvas and the inspector column both read: scene, scrap text, selection, store, `CanvasUndo`, `sceneRevision`, `mutate`/`mutateFromInspector`, the three model→view hooks, `attach`/`detach`, read-only state (tripwire 32).
- `CanvasUndo.swift` — snapshot undo on a canvas-owned `UndoManager`: gesture brackets, `breakGesture`, `mutateFromOutsideTheCanvas`, `renameGesture`; `ScrapUndoBeat`.
- `CanvasStore.swift` — reads and writes `canvas.md` and the sidecar; `load`/`SidecarState`/`SidecarRefused`, `loadForTransientWrite`, debounced `scheduleSave`, `flush`, the damaged-file rename.
- `CanvasSceneCodec.swift` — `CanvasSceneDTO` and its schema; one-home repair, sorted membership arrays, `authorKind`.

### Item nodes
- `CanvasItemFacts.swift` — `CanvasItemFacts` (title, kind glyph, thumbnail path), `CanvasItemKind`, and `CanvasItemIndex` with its content-derived `fingerprint`.
- `CanvasItemPresentation.swift` — the one resolved value the draw pass, the measurement pass and the accessibility tree all read.
- `ItemInspector.swift` — the item node's inspector arm: title, glyph, provenance, Open in Research, Promote… for an owned picture.

### The dim (the tree's selection)
- `CanvasSubject.swift` — what the tree names, resolved against the manifest: whole project, piece, group, research item.
- `CanvasHighlight.swift` — the lit sets (regions, cards, lines, tethers, chips), each question a `Set.contains`.
- `CanvasPieceTitles.swift` — the id→title map; `boundElsewhere(_:isDimmed:)` and `missingPieceName`.
- `CanvasBindingOffer.swift` — the standing "nothing bound" / "card not here" chrome beneath the event view.

### Inspectors
- `RegionInspector.swift` — `RegionInspectorPane` (routes by kind in a `switch`) and the region arm: name, collapse, Piece picker, members, Cite a Card.
- `ScrapInspector.swift` — the card arm: piece association, promotion records, author line.
- `LineInspector.swift` — the line arm: the label, `normalise`.
- `CanvasAuthorLine.swift` — the one "From Claude" provenance row every arm renders: `forCard`/`forRegion`/`forItem`, `CanvasAuthorLineRow`.
- `PromotedArtifactSection.swift` — what a marked thing became and what its words are in; `Subject`, `Provenance`, `ContributionState`.

### Promotion
- `Promotion.swift` — the pure half: `PromotionSource`, `PromotionTarget`, `ArtifactKind`, `ArtifactIndex`, `PromotionPlan`, `PromotionPiece`, `blockedReason`, `regionBodies`, `piece(for:in:)`.
- `PromotionPerformer.swift` — the impure half: `@MainActor async throws`, validate-then-write, marks and contribution records, `PromotionResult`, `PromotionFailure` (tripwire 32 census).
- `PromotionSheet.swift` — `PromotionSheetModel` and the sheet.

### Routes onto the canvas
- `CanvasDrop.swift` — `CanvasDrop` (internal drag: `payload`, `decide`, `apply`, `inboxPayload`), `CanvasExternalDrop` (Finder/browser images), `CanvasAssetIngest`, `CanvasCaptureDrop` (tripwire 32 census).
- `CanvasCapture.swift` — an Inbox capture onto the canvas, by drag or by command; `liveModel` is shared (tripwire 32 census).
- `CanvasClaudePlacement.swift` — where Claude's batch lands: pure `plan`, `apply`, `PlannedSource`, `looseOrigin`, `defaultRegionLabel`.
- `CanvasClaudeWrite.swift` — Claude's write and read through the one attached/detached discriminator (`liveModel`, `readScene`, `undoStepName`) (tripwire 32 census).

### Accessibility and notices
- `CanvasAccessibility.swift` — the synthetic accessibility tree: reading order, labels (`claudeTerm`, `dimmedTerm`, `promotedTerm`, `regionKind`, `itemKind`), `connectionPhrase`, `summary`; `CanvasAXChildren` (tripwire 30).
- `CanvasReadOnlyNotice.swift` — the banner over a canvas whose sidecar this build refused.

Outside this folder but canvas-only: `Maugham/Views/CanvasPromotionModifier.swift` (the Promote… command), `Maugham/Views/CanvasClaudeArrivalModifier.swift` (Claude's arrival banner), `Maugham/Views/CanvasCollapseModifier.swift` (`⌘\`), `Maugham/MCP/Tools/CanvasTools.swift` (`list_canvas`, `add_canvas_scraps`), `Maugham/Stores/ProjectStore+CanvasAssets.swift` (the asset well).

## Rules

### Rendering
- **One SwiftUI `Canvas` draws every node; exactly one real `NSTextView` is mounted, on the scrap being edited; the camera is a manual CTM inside the draw call.** `NSScrollView` with real subviews is disqualified by measurement: SwiftUI content under magnification reports one frame at every zoom and stops taking clicks at 2× (tripwire 25; `CanvasCameraTests`, `TripwireGrepTests.test_noCanvasZoomViaScaleEffectOrMagnification`).
- **`contentStorage.textStorage = NSTextStorage(...)`, never `contentStorage.attributedString = ...`** — the other spelling renders perfectly and refuses every keystroke (tripwire 26; `ScrapLayoutTests.test_mountedEditorActuallyEditsTheSharedStack`).
- **`lineFragmentPadding = 0`, `widthTracksTextView = false`, `textContainerInset = .zero`** on the shared stack — any default shifts drawn text against edited text, and the inset moves pixels while every geometry assertion passes (`ScrapLayoutTests` keeps a bitmap diff).
- **Never derive the raster scale by hand**: no `backingScaleFactor`/`convertToBacking`/`convertFromBacking`/`pixelsWide`/`pixelsHigh` in this directory; `GraphicsContext.withCGContext` already hands over the right scale (`CanvasRendererTests.test_noFileInTheCanvasAreaDerivesItsOwnRasterScale`).
- **Every `ScrapLayout` construction here names `textColor: CanvasRenderer.cardInk`** — the default is the same colour today, so forgetting would break nothing visible (`CanvasRendererTests.test_everyScrapLayoutInProductionNamesTheCardInk`).
- **No `rotationEffect(` or `rotate(by:)` in this directory**; `CanvasRenderer.cardTransform` is the one card rotation and `localPoint` inverts it, never a second hand-written inverse — a flipped sign doubles the caret error and a round-trip test passes either way (`CanvasRendererTests.test_noFileInTheCanvasAreaRotatesOutsideCardTransform`).
- **Layer order is ground → drawn nodes → events → editor (frontmost)**; with the event view in front, click-to-place-caret, drag-select and double-click-word all die (tripwire 27; `CanvasCompositionTests`, `ScrapEditorHostTests`).
- **The ground is a sibling beneath the content, never an overlay or a `.colorEffect` over anything containing `CanvasEventView` or the editor** — a shader over an `NSViewRepresentable` renders a grey placeholder with nothing red. Pass it the same live camera the draw pass uses, or the grain crawls under the cards (`CanvasCompositionTests.test_theGroundIsHandedTheLiveCameraAndTheProjectsWash`).

### Card metrics live in `CanvasCardMetrics`, and nowhere else
- **The card inset, card height and item-card geometry are spelled once, in `CanvasCardMetrics`**; a second spelling puts drawn and edited glyphs on different rects ("text jumps on focus"). A scrap's height is `CanvasScrapMeasure.height(of:)`; an item card's is `CanvasCardMetrics.itemCardHeight(forCardWidth:pictureAspect:)`, picture over its own aspect, then `itemPictureGap` (6), then one label line, with `itemLabelOnlyHeight` as the floor.
- **Every node has a measured height before anything reads its frame** — a node with no `cachedHeight` is neither drawn nor clickable, and `joinTarget` silently joins nothing for it. Creators write `itemLabelOnlyHeight` at creation (`CanvasDrop`, `CanvasClaudePlacement`, `CanvasCapture`); `rebuildLayouts` heals a missing height on load; `CanvasView.remeasure` re-derives both kinds per drag frame (`CanvasViewMountingSurfaceTests.test_aCornerDragOnClaudesSourcePageResizesItAndStaysOnTheCanvas`, `test_anItemNodeThatArrivesWithNoHeightIsHealedOnLoad`).
- **A nil height is never persisted, and a derived height is never a reason to save**: the sidecar's copy is an optimisation, re-measured on every load.
- **Width is authoritative and height derived, for both kinds**, so a corner drag scales a photograph and never distorts it; `CanvasInteraction.minimumCardWidth` (120) clamps every kind, with no second minimum.
- **The resize target is the whole `CanvasRenderer.resizeHandleSize` corner square and the mark is the triangle below its hypotenuse, on every card of either kind.** Do not shrink the target to the ink, and never put a kind test on one without the other — the mark and the target are one decision (`CanvasInteractionTests.test_theUnmarkedHalfOfTheCornerSquareStillResizes`, `CanvasRendererTests.test_anItemNodeTakesTheSameBorderAndResizeMarkAsAScrap`).
- **The connect dot reserves room for the resize square on every card**; its clamp bites only below 42 pt, so the corner belongs to resize on a short card (`CanvasLineRenderTests.test_theConnectDotsReservationIsForAMarkEveryCardNowDraws`).

### Focus straightens the card
- **Every card and region carries a seeded tilt (FNV-1a over the id, never random per frame); the focused card animates level and settles back on blur.** `CanvasRenderer.seededRotation` takes the node or region, never a bare id, because the author decides whether it tilts.
- **Straight means Claude**: the writer's things lean between `minimumTiltDegrees` (0.4°) and `maximumTiltDegrees` (1.0°), Claude's cards and regions are drawn at exactly 0° (`CanvasRendererTests.test_theTiltBandLeavesTrueZeroToClaude`, `test_claudesCardsAndRegionsAreDrawnExactlyStraight`). The ceiling exists because the unrotated hit test drifts from the ink by `r·θ`, which the 14 pt target must keep absorbing.
- **The editor MOUNTS on the click and becomes VISIBLE on `isLevel`; never merge the two.** Gating the mount loses the first keystrokes; showing it on the click snaps glyphs straight over a tilted card. One value (`visibleEditorNodeID`) feeds both `ScrapEditorHost.isEditorVisible` and `CanvasRenderer.draw` (tripwire 27; `CanvasCompositionTests.test_theEditorMountsOnTheClickSoNoKeystrokeIsLost`, `test_theRendererAndTheEditorSwapOnTheSamePredicate`, `ScrapEditorHostTests`, `CanvasRendererTests`).
- **While invisible the editor is transparent to the pointer (`alphaValue` and `hitTest(_:)`); never `isHidden`/`.hidden()`** — AppKit moves first responder off a hidden view and drops it from the accessibility tree.
- **`CanvasFocusStraighten.isSettled` compares each card to its own target, never to 1**, or the card stays level for the rest of the session; `step(elapsed:)` returns `!isSettled` for a non-positive delta on purpose (tripwire 29; `CanvasRendererTests.test_blurSettlesTheCardBackToItsSeededAngle`).
- **Resolve the caret index in the card's unrotated space before the animation starts**, or the click point moves out from under the cursor.
- **The editor is level by design, not because AppKit forces it** (`NSView.frameRotation` rotates a real view crisply); do not write down otherwise.
- **Hit testing is on the unrotated rect, for cards and regions alike**; only a region's drawing is rotated. `cullingBleed` and `rotationOverhang(of:)` carry the `r·θ` term so a tilted corner still on screen is never culled (`CanvasRendererTests.test_theCullingBleedCoversTheRotationOverhangAtTheCalibratedTilt`).

### Regions and membership
- **Creation absorbs; transitions do not.** Moving or resizing never adds or removes a member. A sweep takes in every card whose CENTRE is inside it (`absorbedNodes(by:in:)`), a scrap made inside a region joins it, and a drop joins by centre (`joinTarget(for:in:)`, at `.ended` of a node move only). Those are the only geometric readings for membership; never `region.frame.contains(…)` in a move or resize path, and never `contains(node.origin)` anywhere (tripwire 31; `CanvasMembershipTests`, `CanvasRegionInteractionTests`, `CanvasViewMountingRegionTests`).
- **`CanvasMembership` decides nothing geometric**: deciding is the gesture's job, recording is this file's. Absorption skips unmeasured and hidden cards; a card already living elsewhere is taken in and `join` moves its home.
- **Drop ties resolve greatest overlap, then the smaller region, then the smaller id; collapsed regions are skipped** — a card that joins a collapsed region vanishes on drop. Dropping outside every region removes nothing; removal is its own act (⌫, the inspector's minus).
- **One home, many appearances, disjoint by construction**; copies were rejected. Home uniqueness is enforced in `CanvasMembership.join` and in `CanvasSceneCodec`'s loader, both "first in id order keeps it", the loser demoted to an appearance rather than dropped. `homeRegion` walks `scene.regions`, never `unorderedRegions` (seeded per process).
- **Region drags carry residents, never visitors**; `residents` filters against the live scene.
- **Collapse hides residents in the scene (`hiddenNodes`), not in the renderer**, so drawing, culling, hit testing and accessibility agree. `unorderedNodes` still returns hidden nodes, because `rebuildLayouts` must keep measuring them.
- **Citing is an inspector act**: `RegionInspector.cite` (the writer's hand) and `CanvasClaudePlacement`'s `.cited` case are the only production callers of `addAppearance` (`RegionBindingTests.test_makingAnAppearanceHasAProductionCaller`, which fails when the list empties or grows). Cite a Card's offer reaches the view only through the `(sceneRevision, regionID)`-gated snapshot (`test_theOfferReachesTheViewOnlyThroughTheGatedSnapshot`); an empty offer is a sentence, not a live menu.
- **`caughtRegions` reads a region's centre to decide a BINDING, never a membership**, and through the one predicate `isCaught(_:by:)` that `absorbedNodes` uses (`test_theSweepAsksTheSameCentreQuestionOfACardAndOfARegion`). It has no exclusions and no `minimumSide` floor: a collapsed region is drawn at its frame, and `begin` refuses to start a sweep inside any region.

### Lines
- **A line is an untyped edge with an optional name; it must not gain a `kind`.** It is undirected: `[0,1]` and `[1,0]` are one line, so `connect` refuses a repeated or reversed pair (`invalid_connection`).
- **⇧-drag from any card and a drag out of the selected card's connect mark resolve to one `Bool` (`connecting:`, no default) before `CanvasInteraction` sees anything.** The modifier is threaded through `CanvasEventNSView.applyMouseDown`, never read off `NSEvent.modifierFlags`.
- **The connect mark is drawn only on the SELECTED card**, inside `drawCard`'s `isSelected` block; the promoted stripe and the resize triangle stay unconditional. Moving any of the three across that line is a design change.
- **The first press on an unselected card's handle position must not connect**: read `CanvasView.selectionWhenPressed`, captured at the head of `handleClick`, never live `model.selection`. The route also requires `topmostNode(at:)` to be the selected card.
- **`endLine` is called above `interaction.end()`, never inside the `.ended` chain**, or no line is ever created.
- **Endpoints are node centres; a line to an unmeasured node or to a resident of a collapsed region is neither drawn nor clickable** (`CanvasScene.drawnLines` filters `!isHidden(_:)`). `CanvasLineHit.distance` clamps at both ends and `line(at:)` takes the nearest.
- **The label is edited in the right-hand column through `mutateFromInspector`**, never in a sheet and never through `mutate` (`LineInspector.swift` is in the tripwire 32 census).
- **Cards over lines over regions, in drawing and in hit testing alike** (`test_theClickOrderIsTheDrawOrderReadBackwards`); draw order and click order move together or the defect returns.
- **A press resolving to a line leaves `mode = .idle` and starts no sweep; a double-click on a line mints nothing.**
- **The press-dead corridor `CanvasLineHit.tolerance` leaves around a line is accepted**; if it ever bites, shrink the tolerance, never give one press two meanings.
- **No pointer sequence ends with a line selected and a gesture open**, so a test needing that state opens the bracket directly and also probes `begin` at the line.
- **The draw pass culls with `visibleLines`, never `drawnLines`.** Keep its hairline inset: `!box.intersection(viewport).isEmpty` culls every horizontal line, and the true reason is that `CGRect.intersects` is false only for a null rect.
- **Deleting a node deletes its lines; self-lines are rejected in `insertLine`**, which the codec also goes through.
- **A whitespace-only label is no name, by one trim (`.whitespacesAndNewlines`) in `LineInspector.normalise`, `CanvasAccessibility.connectionPhrase` and `CanvasRenderer.lineLabelBox`** (`CanvasLineRenderTests.test_aWhitespaceOnlyLabelDrawsNoPill`). Clearing a label is its own step, "Clear Line Label".

### The dim
- **Selecting in Plan's tree dims the board**: a chapter lights its bound regions and their residents, a group the union of its children's, a research item its own card; the project row (or nothing) leaves everything lit. An id the tree cannot find resolves to `.wholeProject`, undimmed — the dim is entered by a click, and a deletion is not one.
- **`CanvasSubject` is resolved in the window and handed in as a `let`**; the canvas does not hold the manifest. `CanvasHighlight` calls `RegionBinding.references(forPiece:in:)` rather than re-deriving it.
- **The lit set is cached on `sceneRevision`, the subject and `pieceTitles.fingerprint`, written only by `CanvasView.rebuildHighlightAndTree()`** (tripwire 30). The tree and the dim come from one resolved value in that function; two handlers leave the tree one click behind (`CanvasHighlightTests.test_theTreeAndTheDimAreDerivedFromOneResolvedValue`).
- **Bringing an arriving research card into view is its own `.onChange(of: subject)` with no `initial:`**: a restore is not an arrival, and keying it on `revision` or `sceneRevision` snatches the card from under the writer's hand (`CanvasViewMountingSurfaceTests.test_movingTheRevealedCardNeverRecentersTheCamera`).
- **The dim is de-emphasis, never disabling**: dimmed things stay hit-tested and selectable, the selection ring stays full strength, and the sweep and pending line are never dimmed.
- **Alpha is replaced, never multiplied** — through `CanvasMaterial.dimmedAlpha(lit:)` or `CanvasRenderer.alpha(_:dimmed:)`; the region wash and card border stay as they are; card words go through `textInk(_:dimmed:)` (`CanvasHighlightRenderTests`).
- **The dim is a mode and its only indicator**: while anything is dimmed, a sweep binds to the subject; on an undimmed board a sweep is just a sweep. Never add a second "binding is armed" signal.
- **A binding sweep assigns what it catches and creates only when it catches nothing; it never re-binds a bound region** — routed by the pure `CanvasInteraction.sweepOutcome(for:subject:in:)`, whose third case `.doNothing` covers a sweep over only bound regions (`test_aSweepCatchingOnlyBoundRegionsCreatesNothingEither`). A group subject makes a plain region. Changing a binding stays the inspector's Piece picker.
- **The bind happens inside `handleDrag(.ended)`'s `model.withScene(persist: false)`**, so one ⌘Z takes back the whole act; never `mutateFromInspector` there. The step is renamed at `.ended` through `CanvasModel.renameGesture`, and a bind without a mint still bumps `sceneRevision` (`test_aSweepAcrossExistingRegionsBindsThemAndCreatesNothing`).
- **Escape is the keyboard spelling of the project row** — `CanvasView.selectTheProjectRow` is a one-way ask the window answers by writing the project row's own tag, so the canvas gets the answer (`CanvasSubject`) and never the question. On an undimmed board Escape is refused and travels on; never a menu key equivalent, which is app-wide.
- **Escape is delivered by `WindowEscapeArbiter`'s one monitor per window, never by `CanvasEventNSView.keyDown`.** The canvas registers as a consumer only while dimmed; it loses to a mounted scrap editor by two mechanisms (`escapeAsksForTheWholeBoard` and `CanvasEscapeMonitor.disposition`), each with its own test. Escape tests go through `NSApp.sendEvent(_:)` to a key window and count delivered events on `CanvasHostWindow`, because `NSWindow.sendEvent(_:)` bypasses monitors and monitor order is not stable.
- **`CanvasBindingOffer` reads `litNothing` and the subject's case in one `message(subject:highlight:)`**, sits beneath `CanvasEventView`, and has no timer. A piece gets `nothingBound` (sweep a region); a research subject whose card is absent gets `cardNotHere`, which names the tree and never the sweep. A group subject never gets the offer, though `litNothing` is true for one. A bound-but-empty region is not the offer state.
- **On a dimmed board a region bound elsewhere draws and speaks that piece's name** through one resolver, `CanvasPieceTitles.boundElsewhere(_:isDimmed:)`; a deleted piece says `missingPieceName`. The map is built over the whole structure, never `pieceChoices`' routable subset.
- **When a region's chrome bar is too narrow, its own label yields to the borrowed piece name** (`CanvasRenderer.regionLabelWidthBudget`).
- **Shorten a label by string (`CanvasRenderer.elide`), never by clipping the context** — clipped text puts a noise floor under every two-render diff fixture.

### Item nodes and thumbnails
- **`CanvasItemPresentation` is one resolved value with three consumers** (draw, measure, accessibility), resolved once per structural change at the head of `rebuildLayouts` (never per node inside the `Canvas` closure), cached on `(sceneRevision, CanvasItemIndex.fingerprint)`. The fingerprint is content-derived through `StableHash`; never `hashValue`, never `.onChange(of: index)`.
- **A model-held closure must not read a value-type view property that changes**: the model keeps its own `itemIndex` copy (`@ObservationIgnored`), written in `load()` and on the fingerprint change (`CanvasViewMountingSurfaceTests.test_anItemAddedAfterTheCanvasAppearedResolvesThroughTheWindowsCurrentIndex`).
- **A deleted reference says `CanvasItemFacts.missingTitle`, never an id; an owned image's title is the fixed noun "Image"**, because ingest discards the writer's filename. The missing state is asked of `CanvasItemIndex`, never read back out of the title.
- **A glyph is fitted into its box, never stretched; the title is drawn in `secondaryLabelColor`.**
- **Nothing decodes on the frame path.** `CanvasThumbnails.resolved` is a lookup that records a miss; `servicePending()` runs from `.task(id: thumbnailServiceTicket)`, a monotonic ticket and never `revision` (tripwire 30) or a pending count. A landed decode calls `rebuildLayouts()`, not a redraw, because the height changes.
- **Pixels are a cache; a shape is a fact.** Measurement reads `CanvasThumbnails.aspect(_:in:)`, never the resident image. A fresh decode that differs from the memo by more than `aspectReshapeTolerance` (1%) moves it and `dropOtherBuckets(of:)` drops that path's other pixels (`test_aReshootMovesTheShapeMemoAndTheStalePixelsWithIt`).
- **`rebuildLayouts(bumpsThumbnailTicket: false)` is the servicing call**, so the cache cannot feed itself (`CanvasViewMountingSurfaceTests.test_aCanvasOverTheThumbnailBudgetSettlesInsteadOfLooping`). A decode landing never queues a save, and the thumbnail request never follows the zoom.
- **`RegionInspectorPane` routes by kind in a `switch`**; an item node never reaches `ScrapInspector`.
- **`ItemInspector` mutates nothing and posts commands only**; anything that writes needs `mutateFromInspector` deliberately (`test_theArmMutatesNothing`). It has no Delete button.
- **Open in Research is a value (`OpenAffordance`)**; an owned picture gets a sentence, never Reveal in Finder, and a dangling reference is a sentence with no id, not an error state.
- **`ItemInspector.promotes(_:)` is asserted against `Promotion.targets` and `isPromotable`** (`test_theArmsGateAgreesWithTheTargetsAndTheCommand`).

### Routes onto the canvas
- **What a drop means is a pure decision (`CanvasDrop.decide`) plus a model verb (`apply`)**; that the modifiers are mounted at all is pinned only by `PromotionCommandTests`' wiring census, since no test can post a drag session.
- **Validation is membership in `CanvasItemIndex`**: anything not there is refused. A second id space arrives prefixed — an Inbox capture's payload is `inbox:<id>`, spelled only in `CanvasDrop.inboxPayload(for:)` and destructured first by `CanvasDrop.payload`.
- **A research group is accepted by the drop** (where `add_canvas_scraps` refuses one as a source page): the writer is pointing at a folder in their own binder.
- **A second drop of the same item REVEALS (select and bring on screen); it never re-creates and never moves**, since moving would be a geometry-driven transition.
- **Drops, captures and Claude's writes go through `mutateFromInspector`**: a drag that begins outside the canvas has no bracket of its own, and the delivery site is not what tripwire 32 turns on.
- **External images: never `.dropDestination(for: URL.self)`**; use `[.fileURL, .image]` providers and `DropClassification` (`TripwireGrepTests.test_theCanvasExternalDropUsesTheProviderRouteAndNeverAUrlDestination`). The external `.onDrop` is applied first (innermost) and the `String.self` destination after it.
- **A non-image is refused before anything is copied** with `ImagePasteHandler.isIngestableImage`, so a refusal and a failure stay separate sentences (`CanvasDropTests.test_theCanvasDropStillRefusesItInItsOwnWords`). Await ingestion first, touch the scene second. Several files cascade at `CanvasClaudePlacement.cardGap`.
- **A failure is an alert naming the files, not another transient banner.** `ProjectStore` never reaches this view; `CanvasAssetIngest` and `CanvasCaptureDrop` closures do.
- **A capture sent from the Inbox** is `CanvasCapture`, sibling of `CanvasClaudeWrite`: `.dropped(at:)` joins by centre, `.loose` (the command) never joins a region (`Landing.joinsARegion`). The command's card is told by selecting it, a camera request and a line in `InboxPane`. The store half is `InboxStore.sendToCanvas` (`Maugham/Stores/AREA.md`).
- **`CanvasClaudeWrite.liveModel` is the one place `store.liveCanvas` and `isAttached` are written together** (`CanvasLiveSeamTests.test_theLiveCanvasDiscriminatorIsSpelledOnce`).

### Promotion
- **A promotion is a snapshot and its mark is provenance, not a link**; nothing syncs either way.
- **The pure half (`Promotion`) and the impure half (`PromotionPerformer`) are two files, and the line between them is load-bearing**: `Promotion` only plans (`test_planningNeverMutatesTheScene`); the performer awaits first and changes the scene through `CanvasModel` after, because an `inout CanvasScene` cannot cross an `await`. Validate first, write second.
- **Every scene change the performer makes is `mutateFromInspector`** — the sheet can be opened mid-visit (tripwire 32).
- **`ArtifactIndex` (id → title and kind) is passed in, never reached for**; it covers research and statements (`over(research:statements:structure:)`), and `statementTitle` is the one composed statement name. A kind mismatch declines the update rather than overwriting another target's artifact; `performResearchNote` re-checks against the live manifest.
- **A rewrite does not rename, keeps what it writes over, and refuses before writing**: `Promotion.plannedTitle`, `PromotionSheetModel.namesTheArtifact`, `PromotionPerformer.preservePriorVersion` (sends the prior file to the trash as `TrashSubject.priorVersion`), `precheckOfferedLinks`.
- **`PromotionTarget.namesItsArtifact` is the one name-asking decision**, read by `validate` and the sheet alike, and never spelled `updatableTargets.contains(_:)`; `Promotion.blockedReason` answers empty scraps, empty regions and referenced items before any plan.
- **The mark (`promotedItemID`, "I am this artifact") and the contribution record (`contributedToItemIDs`, "my words or picture are in that") are separate fields; never let `existingArtifact` fall back to the record** (`PromotionContributionTests`). Records are multi-valued, append-on-stamp, written at promotion time, and never rebuilt from live membership.
- **`record` removes then stamps for an artifact (its clear skips item nodes, via `isScrap`, never `carriesAMark`; its stamp is unfiltered); `recordPicture` stamps without clearing**, because an image well is append-only for every producer. Records are never rebuilt on load; a dangling one resolves through the deferred `artifactTitle` lookup to `PromotedArtifactSection.Subject.contributionArtifactMissing`, never an id. One `mutateFromInspector` bracket writes the mark and every record: one ⌘Z.
- **A contribution is neither drawn nor announced**; `CanvasRenderer` and `CanvasAccessibility` do not read `contributedToItemIDs`. The pane shows both records through two straight `switch`es, and `Provenance.saysNotPromotedYet` is true only when neither exists.
- **An owned picture promotes (research asset, or onto a palette card) by copying the file; the node stays owned.** The research row writes the mark, the palette row a contribution only; neither picture row is updatable. A referenced item node is never promoted. No refusal an owned node can reach calls it a card (`test_noRefusalAnOwnedNodeCanReachCallsItACard`): a card is the node, a picture the file. `CanvasPromotionModifier.isPromotable` takes the node's kind, resolved in an `.onChange` action and never in `body`. `CanvasNodeKind.carriesAMark` is the one draw-and-speak predicate for the mark.
- **A refusal names only controls on the arm the writer is looking at** (`Promotion.canCarryItsOwnPiece(_:in:)`, undefaulted).
- **A region's palette promotion copies the pictures of its home members, on a `.new` promotion only** (a rewrite copies none); `requirePicture` refuses an empty list; `PromotionPlan.pictures` is a list; in `performPaletteCard`, `updatePaletteCard` runs before any append, or its stale image list overwrites the new pictures.
- **The piece association resolves by precedence — the scrap's own, else its HOME region's, else none** (`Promotion.piece(for:in:)`); nothing is ever overwritten. `pieceIsInherited` is one rule with two readers.
- **Routing is `ProjectStore.researchRouting`, met only in `PromotionPiece.resolve`; never a `switch manifest.type` under `Maugham/Canvas/`.** Both pickers offer `researchScopeTargets()` and share `noPieceTag`; `ProjectWindow.pieceChoices` is deliberately eager on the body path, since deferring it puts the walk on the drag loop (tripwire 30).
- **A stale association REFUSES rather than redirecting**, through `Promotion.pieceFailure`, and only for a new research note; a craft intent on an unroutable piece falls back to project scope and a palette card is never routed.
- **A refusal for an inherited piece never sends the writer to clear a Picker already reading None**, and the pane tells the refusal's story: `ScrapInspector.unoffered` builds both pickers' orphan row from the whole-structure `pieceTitle` lookup.
- **A promotion to craft intent appends through the op log, through the one live `Document`** (`ProjectStore.openStatementDocument(id:)`, under `lockStatementOpen`) — never a second `Document` on one path. `PromotionPerformer.intentScope` and `Promotion.craftIntentDestination` move together. A draft the writer typed before the statement existed is merged into what the promotion put there (`StatementTextTarget.deposit(into:for:)`, reached from `bind`), never replaces it.
- **What a promotion produced reaches the writer**: `PromotionResult.confirmation(for:)` reads the plan's own destination and shows in `MCPNoteBanner`. Promote… buttons post `.maughamPromoteCanvasSelection` to `.keyWindow`, which works from the inspector column and is dropped from inside a sheet.
- **`artifactTitle` and `onOpenResearchItem` have no default on `RegionInspector`**, so the section cannot go missing silently.
- **Open on a statement mark routes through `ProjectWindow.statementPane(forMark:in:)`, a `switch` over the kind**, and does not choose the pane's scope; driving the window's subject from Open is a design decision still owed, not a fix.

### Ownership, counters and undo
- **`CanvasModel` holds the scene, text, selection, store and recorder; `CanvasView` holds only what belongs to one view of it** (camera, layouts, focus, straighten, momentum, both counters' view copies).
- **The canvas is mounted at exactly one site** (`CentreColumn.editorPane`'s `.canvas` arm, `canvasCentre`); a second branch is a second view identity that resets camera and reloads everything (`RegionBindingTests` counts `canvasCentre(`). Every "is the centre the canvas" check asks `Persona.centresTheCanvas`.
- **Three `@ObservationIgnored` hooks run model → view** (`onSceneReplacedByUndo`, `onSceneChangedExternally`, `onRevealRequested`), bound in `CanvasView.load()` and nil'd together in `detach()` (`CanvasLiveSeamTests`' assigner census). `onRevealRequested` carries a region and the model parks it until `attach()`.
- **`CanvasModel` hosts `CanvasUndo`; never reimplement it** — a second mechanism loses `breakGesture`, deferred grouping, depth and the mid-gesture re-baseline.
- **Two counters**: `revision` ticks every animation frame and keys the `Canvas` redraw only; `sceneRevision` ticks on structural change and keys the accessibility tree, the lit set and the inspector's gated lists. **Nothing scene-proportional keys off `revision`** (tripwire 30; `CanvasAccessibilityTests.test_theTreeIsNotKeyedOnTheRedrawCounter`, `CanvasCompositionTests`). Read `revision` in `body`, not inside the draw closure.
- **`CanvasModel.sceneRevision` is the counter and is bumped unconditionally; `CanvasView`'s same-named `@State` copy is written only by the mirror in `body`** (`CanvasAccessibilityTests` greps for `.onChange(of: sceneRevision`).
- **Every structural bump is `model.bumpSceneRevision()`; never reintroduce a view-side bump.** A caller that bumps on its own line passes `rebuildLayouts(bumpsStructuralCounter: false)` (grep for the callers). A sweep or line drag that changed nothing is not a structural change (`test_aBareCanvasPressThatDriftedIsNotAStructuralChange`); `commitActiveEdit`'s bump is guarded on a scrap having been focused, which is why a press that truncates a coast bumps at `handleDrag(.began)`.
- **The writer's words leave the editor on every keystroke** (`textDidChange` → `onTextChanged` → `syncActiveEdit()`), plus `.onDisappear` and `CanvasStore.beforeFlush` (tripwire 28; `ScrapEditorHostTests.test_typingReportsItselfSoTheCanvasCanFoldItIntoTheModel`, `CanvasStoreTests.test_beforeFlushCanReplaceThePayloadOnItsWayOut`). `syncActiveEdit` folds the string only; only a real keystroke moves an undo boundary (`fromKeystroke:` defaults to `false`).
- **Undo is snapshot-based on a canvas-owned `UndoManager`, never the window's**; canvas state is not op-logged.
- **`beginGesture` opens no `UndoManager` group; tests set `groupsByEvent = false`, production must not.** An undo serviced mid-gesture re-baselines that gesture.
- **The mounted editor has `allowsUndo = false`** (snapshots own scrap text); never delete the `undo:`/`redo:` forwarding expecting the responder chain or `undoManagerForTextView:` to take over. **⌘Z reaches the canvas stack by exactly two routes**, each an explicit `undo:`/`redo:` pair with `validateUserInterfaceItem`: `ScrapEditorContainer` (a scrap focused) and `CanvasEventNSView` (nothing focused). An `undoManager` override is not a route (`CanvasViewMountingEditingTests.test_undoIsReachableFromTheEditMenuWithNoScrapFocused`).
- **Inside a scrap the undo granularity is the sentence**: `breakGesture()` on a finished sentence or `ScrapUndoBeat.idleSeconds` of stillness; the idle beat is asked before the keystroke is folded in, the sentence rule after.
- **A change from the other column goes through `CanvasModel.mutateFromInspector`, never `mutate`** — it closes the open "Edit Scrap", runs, and reopens it; the reopen is load-bearing. `CanvasView` keeps `mutate`, being inside its own bracket by construction. The census is `TripwireGrepTests.test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly` — count its array (tripwire 32).
- **The repro for the region arm is a double-click on a region's chrome bar; for the card arm, a double-click on the card.** Each arm has its own repro and neither one's is the other's.
- **A caller writing scrap text from outside passes it as `mutateFromInspector(_:scrapTexts:)`, inside the bracket**; `setScrapText` before or after the call registers the words under the wrong step. The tripwire 32 census scans `Maugham/` only, so a test doing this is not caught.
- **A replaced `ScrapLayout` must be a new instance**, never the old one mutated, so the editor's rebind shows the restored words. `mount` rebinds on layout identity (a `weak` reference compared with `!==`), never on `textView == nil` or an `ObjectIdentifier`.
- **The undo apply calls `onSceneReplacedByUndo`: `momentum.stop()` first, focus reconcile after.**

### The mounted editor and Delete
- **Focus is requested, not taken**: `makeFirstResponder` in `makeNSView` is a no-op; `updateNSView` re-claims it (tripwire 27; `ScrapEditorHostTests`).
- **Zoom is bounds scaling; never `.scaleEffect`, never a re-layout.** `mount` writes both rectangles, frame then bounds, every call; do not "harden" it against external frame writes.
- **Caret clamping is in UTF-16 units.**
- **⌫ is `CanvasEventNSView.keyDown` → `CanvasView.deleteSelection()`**, a `keyDown` and not `deleteBackward(_:)`. The keys are `NSDeleteCharacter` (⌫) and `NSDeleteFunctionKey` (⌦); `NSBackspaceCharacter` is Ctrl-H. Keep the condition as an `if` in the case body: a `where` binds only to the last pattern.
- **A ⌫ while any gesture is open deletes nothing** (`CanvasModel.isInGesture`, tripwire 32); anything new hung off a key on this view inherits the same hazard. **⌫ never fights the editor** — while a scrap is focused the mounted `NSTextView` is first responder and deletes a character.
- **A region delete keeps its cards; a node delete takes its words and its lines; a line delete keeps both cards** — one ⌘Z restores each whole.
- **Nothing selected is a no-op and the key travels on to `super` (the beep)**; `deleteSelection()` reports whether anything went. The tests send a real `NSEvent` and read disk (`test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain`, `test_backspaceInsideAScrapDeletesACharacterAndNotTheCard`); do not replace them with a direct call.

### Persistence
- **canvas.json is derived and deletable; `canvas.md` and `canvas_assets/` are content.** Region, line, mark, association and author state is sidecar state, so the inspector takes a `CanvasModel`, never a `ProjectStore`. `CanvasStore.writeNow` writes content before the sidecar.
- **A node's `ownedPath` is project-relative** — never absolute, a `file://` URL or a Markdown ref — and every resolution against the root goes through `SafeRelativePath` (`CanvasThumbnails`' decode queue, `PromotionPerformer.assetURL`). The well's name is derived from `canvas.md`'s path, never spelled (`Maugham/Stores/AREA.md`).
- **`referenceId` and `ownedPath` are disjoint**; a node carrying both loads as owned, one carrying neither is dropped (`CanvasSceneCodecTests`).
- **Every additive schema bump is additive-optional, on the DTO of the thing it describes**, never a new top-level collection; bump `CanvasSceneDTO.currentSchemaVersion`. `author` is a raw `String?` that only `CanvasSceneCodec.authorKind` turns into a `SourceKind` (an unknown value decodes nil). Membership arrays are written `.sorted()` (`test_regionMembershipArraysAreWrittenSortedRegardlessOfSetIterationOrder`).
- **`CanvasStore.load` refuses a newer or damaged sidecar and returns an empty layout with the scraps intact**, reporting `SidecarState` (`.decoded`, `.absent`, `.refused` with `SidecarRefused.Reason`).
- **A refused canvas is read-only on every route**: the store's saves no-op, the model's verbs change nothing, `CanvasEditGate` gates every gesture, key, drop and inspector control (`CanvasEditGateTests`), and Promote… is off.
- **Claude and the Inbox are refused with `canvas_sidecar_unreadable` before any asset copy.**
- **Only a damaged file offers Start a Fresh Layout**, which renames it aside; a newer one never does.
- **A `canvas.json` or `canvas.md` that exists but can't be read right now (iCloud placeholder, permissions) is refused `.unreadable`**, never treated as absent: read-only, no Start a Fresh Layout; `CanvasModel.retryUnreadable` (Try Again, and a bounded auto-retry) lifts it in-session once both read (#88, `CanvasUnreadableTests`).
- **`CanvasModel.attach` surfaces orphan words** (text with no node) as loose cards, and drops blank ones; a refused sidecar is never written back at load.
- **`CanvasStore.load()` reads both files directly under `// adr-0018-ok:`** — scrap text has one persisted representation, so ADR 0018's drift cannot arise.
- **`flush()` covers app quit through `NSApplication.willTerminateNotification` with `queue: nil`** — with a queue the block may never run before exit.
- **The crash floor: a force-quit loses up to 750 ms of typing.** The canvas has no op log behind it, so do not let "matches `DocumentStore`" imply parity.

### Accessibility
- **We own the tree**: `CanvasAccessibility` mirrors every node in rows-then-columns order (a proximity walk with `rowBand`); never `.accessibilityElement(children: .ignore)` on the stack, and never name it or `accessibilityHidden(true)` even in a comment in `CanvasView.swift` (a raw-source scan).
- **Elements carry content-space frames and are rebuilt from `.onChange(of: sceneRevision)`, never in `body` or from `revision`; the children live in `CanvasAXChildren` with `.equatable()`** (tripwire 30).
- **The kind goes in the label** (`CanvasAXRole` is never published): "Scrap", "Reference" (`itemKind`), `regionKind` (`test_everyRoleNamesItselfInTheLabelBecauseTheRoleItselfIsNeverPublished`). `CanvasAccessibility.label` is the one ordering: `dimmedTerm` and `boundElsewhereTerm` first, then kind, name, `claudeTerm`, durable facts.
- **The dimmed element is the marked one, and the dim never removes elements** (`test_aDimmedCardIsStillReachableAndStillReadsOutItsWords`); its word is not the system's "dimmed" (`test_theSpokenTermIsNotTheSystemsWordForUnavailable`).
- **`summary` counts the whole line set and every node, collapsed regions included**; a collapsed region says separately what it holds.
- **Claude's provenance is spoken on every primitive with one wording** shared with `CanvasClaudePlacement.defaultRegionLabel` and `CanvasClaudeWrite.undoStepName` (`test_theSpokenTermAgreesWithTheRegionLabelAndTheUndoStep`). The tree is flat, so the term is repeated on each card of a Claude region and is not suppressed when a region's name already contains it.
- **A line is not an element; it is named at both its ends** (`connectionPhrase`, built from one index in one pass — `CanvasPerformanceProbeTests.test_theAccessibilityRebuildDoesNotGoQuadraticInTheLines`). A line to a hidden end is not named; one to an unmeasured end is. Phrase names follow `scene.lines`' id order.
- **The surface has two deliberate drawn/spoken divergences, in opposite directions**: a Claude item node is announced and not tinted; a contribution record is neither drawn nor announced. One rule covers both: a signal is added to a channel that would otherwise be silent about a fact the writer needs, and withheld where it would be ambiguous with one already there. Any other divergence is decided and recorded here, or it is a defect.
- **On macOS 14/15 a lone card publishes its container's frame**; nothing in production works around it, and `test_aLoneCardOnTheCanvasIsAnElementOfItsOwn` skips on the observation, never on `#available`.

### Claude on the canvas
- **`add_canvas_scraps` cannot express a position, a node id or a region id** (`test_theSignatureCannotExpressAPositionOrAnId`); placement is `CanvasClaudePlacement`'s, `connect` indexes the call's own scraps, and the result carries ids only.
- **The discriminator is `CanvasModel.isAttached`, never `liveCanvas != nil`**, spelled only in `CanvasClaudeWrite`. Attached: `mutateFromInspector(_:scrapTexts:)`, then `bumpSceneRevision()`, then `flush()`. Otherwise `loadForTransientWrite()` → `CanvasClaudePlacement.apply` → `save`. Neither route says "saved", because `writeNow` swallows I/O errors.
- **One arrival, one region, one ⌘Z, one name**; the region lands at `looseOrigin`, clear of the writer's work, floored at `CanvasRegionMetrics.minimumSide`, and every card is measured at creation. The source page is created, adopted or cited (`PlannedSource`), never moved (tripwire 31).
- **A source item node is `author: .claude`, drawn straight and untinted** — `CanvasRenderer.paper(for:)` never tints an item node; never use `author = nil` to get a colour.
- **Every refusal comes before anything is written**: validation from the call alone, and `canvas_sidecar_unreadable` raised by the write on both routes through `CanvasStore.loadForTransientWrite()` (sidecar) or the attached model's `sidecarRefusal` — never a second `!= .refused` at a call site. Refuse rather than dedupe. The placement is synchronous (`apply` takes an `inout CanvasScene`); a caller that must await does so before the call.
- **`list_canvas` reads the live model when attached** (`read_from: "open_canvas"`) and enforces `MCPResponseBudget` itself.
- **The arrival banner (`CanvasClaudeArrivalModifier`) is project-scoped, says "added", and its Show writes the persona directly** (not through `PersonaModifier`), forces the inspector open, and moves the camera through `onRevealRequested` — a hook, never a `MaughamEvent`; `CanvasCamera.bring(_:toViewPoint:)` never touches zoom. `MCPBannerModel` is not reused.
- **`CanvasAuthorLine` is rendered by every `*Inspector.swift` arm that can carry it, from one implementation**; the census discovers the files (`RegionBindingTests.test_everyInspectorArmRendersTheOneAuthorLine`). `forItem` never forwards to `forCard` (`test_aSourcePageDoesNotSayItWasReadFromItself`). A `store` is never read from a `body`.

### Material
- **Every calibration number of the look lives in `CanvasMaterial.swift`; never inline one into the shader.**
- **Quote a figure in this file as the code span followed by its value**, e.g. `maximumTiltDegrees` (1.0°) — `DocSyncTests.test_theCalibrationFiguresInTheCanvasAreaFileMatchTheirConstants` compares each with its constant.
- **Light and dark are two materials**; every differing knob is a pair (`CanvasGroundTests.test_theTwoAppearancesAreCalibratedSeparately`).
- **The card stays lighter than the ground in both appearances, at peak grain** (`test_theCardIsLighterThanTheGroundInBothAppearances`). Author colours in sRGB. `cardPaper` is `textBackgroundColor` in light only; dark takes `darkCardPaper` (0.235, 0.232, 0.226).
- **Whose hand made a thing is said by material and tilt, never by a further mark.** In light mode red is the bound channel (the grain peaks at 0.9575 over `lightBase` (0.930, 0.915, 0.880)): lower red, bring green down to meet it, keep blue at 1.000, as `lightClaudeCardPaper` (0.980, 0.980, 1.000) does. More headroom means recalibrating `lightBase`/`lightGrainAmplitude`, which is Denver's call, not a tidy-up. A chip carries neither signal.
- **Test the dark ground by rendering it** (`test_theDarkGroundIsAMaterialRatherThanABlackFill`).

### `⌘\` gives the canvas the window
- **The collapse is `.doubleColumn` plus `showInspector == false`, never `.detailOnly`** (which hides the canvas); `ProjectWindow.canvasCollapse` is the pure decision and carries the visibility in its payload.
- **It watches the no-chrome flag, never the key** — one subscription, so `⌘⇧F` collapses too — and never fires automatically on entering the persona; off the canvas nothing is written.
- **The stash is the "already collapsed" flag; persona changes release it through `PersonaModifier.releasesCanvasCollapse`**, which also hands the sidebar back. Extend that predicate; never defer a pass (tripwire 2).

### Scale and tests
- **Supported: 2,000 nodes** (`CanvasPerformanceProbeTests.supportedNodeCount`). There is no spatial index; `nodes(intersecting:)` filters then sorts — read `CanvasScene`'s doc comment rather than leaning on the probe budgets, which catch O(n²) and not a lost constant factor. Nothing times `CanvasRenderer.draw`. Per-frame callers use `count` or `unorderedNodes`, never `nodes`. Lines, tethers and chips are per-frame work nothing bounds; if one ever measures, add an `unorderedLines` peer (as `nodes`/`unorderedNodes`) rather than a cache, cull a tether by its segment and never its region, and never cache tethers on `sceneRevision`.
- **Read `CanvasView.swift`'s header before reformatting it**: its source-layout contracts are read by tests as text, and one crashes rather than fails.
- **The `CanvasViewMounting*` family runs shortened real clocks** (`CanvasViewMountingCase.makeModel()`): "reached disk" is `pumpUntilSaved()`, a precondition that the debounce has not fired needs `makeModelOnProductionClocks()`, and an elapsed-time assertion uses `waitOut(_:)` — `pump` does not wait for its argument.
- **`revision` cannot be covered by a test whose redraw is driven by a `@State` mutation**; keep the bump, record the measurement in the comment beside it, and do not write an assertion for what cannot be covered.
- **No test presses a mounted control and then waits for its effect, and no test synthesises a mouse click, outside the named allow-lists** (`pressThenWaitRepresentatives`, `clickRepresentatives`). Drive the canvas through `CanvasEventNSView.applyMouseDown`, which is not an event and is out of scope (tripwire 33; `TripwireGrepTests.test_noNewTestPressesAControlAndThenWaitsForItsEffect`, `test_noNewTestClicksOutsideTheNamedRepresentatives`).
- **`NSTextView.mouseDown` runs a modal loop**: where a real click is warranted at all, it is a named `clickRepresentatives` entry, and it posts mouseDown and mouseUp before pumping.
- **A mounted test gets an exact accessibility frame only from the first published card**; later frames drift by position, so frame assertions on other cards are about ordering.
- **An undo test asserts the step's name** (`CanvasUndo.undoMenuItemTitle`) or puts an unrelated edit between, never only the scene.
- **A grep census matches the call as written** (bare member names with an identifier guard) and carries a planted-offender companion; it reads through `SourceScan.codeLines`, so comments cannot satisfy it.
- **Before calling a primitive done, grep its production callers**; where it matters, assert them by name (`test_makingAnAppearanceHasAProductionCaller`, `PromotionCommandTests.test_theCanvasWiringCensusNamesEveryProductionSite`).
- **Every negative result needs a control that passed**; no `XCTAssertNil`/`XCTAssertEqual(…, nil)` through `?.` in `MaughamTests/Canvas` without `// nil-chain-ok:` (`TripwireGrepTests.test_noXCTAssertNilReachesItsSubjectThroughAnOptionalChain`).
- **Raster fixtures resolve dynamic colours under `performAsCurrentDrawingAppearance`**; the test process runs under DarkAqua.
- **A `NotificationCenter.default.post(` in this area or its tests needs `// adr-0021-ok:`** on its line.
- **Counts of a censused list are read off the array, never written here.**

### Accepted costs and open questions
Each is decided or deliberately open; do not record it as a bug, and do not record its opposite.
- **A region holding only pictures is refused as empty**, with a sentence untrue of it (`PromotionRegionPictureTests.test_aRegionHoldingOnlyPicturesIsRefusedWithASentenceThatIsNotTrueOfIt`) — not a dead sheet. Closing it is a per-target ruling on what "empty" means.
- **The promoted `[[…]]` reads as plain text in the research pane**; the link layer reads it and renames rewrite it.
- **Appending into a note another window has open** can be overwritten by that window's buffer — the same class as `AddNoteTool`'s.
- **Three transient top banners can overlap**; the fix is one banner host per window, never a fourth overlay.
- **The focus straighten is invisible on a Claude card**, which is already level; inventing a lean would undo the provenance signal.
- **Claude cannot see an owned picture's pixels**; `list_canvas` reports `provenance`, never the path. An image read keyed on a node id is a decision still owed.
- **Open for a VoiceOver session**: the focused scrap is announced twice; a line cannot be reached to select it; two owned photographs sound identical ("Reference", "Image").
- **Unmeasured costs on stated terms**: `ScrapInspector.association` and `CanvasAuthorLine`'s walking resolvers do scene-proportional work in a `body`, bounded by the region count; a gate exists one file over (`RegionInspector`'s `(sceneRevision, id)` cache). Never write "there is no gated way", and never write "measured" without a figure and a date.

## Recipes

### Add a change made from outside the canvas (an inspector control, a drop, a store or MCP writer)
1. Make the change through `CanvasModel.mutateFromInspector` in `CanvasModel.swift` (with `scrapTexts:` if it writes words), then `model.bumpSceneRevision()` on its own line if it is structural.
2. Add the file to the tripwire 32 census in `MaughamTests/TripwireGrepTests.swift` (`test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly`).
3. Ask `CanvasEditGate` (`offersVerbs`/`editsValues`/`accepts`) before offering it, and add the token to `MaughamTests/Canvas/CanvasEditGateTests.swift`.
4. If it is a new production site wired from the window, add its token to `PromotionCommandTests`' wiring census.
5. If an inspector caches anything scene-proportional for it, gate the cache on `(sceneRevision, id)` as `RegionInspector.swift` does.

Checks: the tripwire 32 census, `CanvasEditGateTests`, and an undo test that asserts the step's name.

### Add a node kind or an item provenance
1. `CanvasNode.swift` (a `CanvasNodeKind` case) or `CanvasItemReference.swift` (a provenance); answer `carriesAMark` and `isScrap`.
2. `CanvasSceneCodec.swift` — an additive-optional field on `NodeDTO` and a `currentSchemaVersion` bump.
3. Measure it at creation: `CanvasScrapMeasure.swift` / `CanvasCardMetrics`; heal it in `CanvasView.rebuildLayouts` and `remeasure`.
4. Fix every switch the compiler flags (the list is a guide; the grep is the truth) — today in `Maugham/Compiler/PinnedReferences.swift`, `CanvasRenderer.swift`, `CanvasAccessibility.swift`, `CanvasView.swift`, `Promotion.swift`, `PromotionPerformer.swift`, `PromotionSheet.swift`, `RegionInspector.swift`, `Maugham/MCP/Tools/CanvasTools.swift`, `Maugham/Views/CanvasPromotionModifier.swift`; find them with `grep -rn 'case \.scrap'`.
5. For an item: `CanvasItemFacts.swift` (title, glyph, thumbnail) and `CanvasItemPresentation.swift`.
6. Its inspector arm: a case in `RegionInspectorPane`'s `switch` and an `*Inspector.swift` that renders `CanvasAuthorLineRow` and asks `CanvasEditGate`.
7. Its accessibility kind word: a constant in `CanvasAccessibility.swift`.

Checks: the compiler, `CanvasSceneCodecTests`, `RegionBindingTests.test_everyInspectorArmRendersTheOneAuthorLine`, `test_everyRoleNamesItselfInTheLabelBecauseTheRoleItselfIsNeverPublished`.

### Add a canvas MCP verb
1. The tool beside the existing two in `Maugham/MCP/Tools/CanvasTools.swift`, registered in `MCPToolCatalog.all` (`Maugham/MCP/AREA.md`'s recipe).
2. Read through `CanvasClaudeWrite.readScene`; for a write, choose the route with `CanvasClaudeWrite.liveModel` (never a third discriminator) and mirror `apply`'s attached/sidecar arms in `CanvasClaudeWrite.swift`.
3. Decide placement in a pure planner (the `CanvasClaudePlacement.plan`/`apply` split); the signature expresses no position and no writer's id.
4. Refuse before writing, including `canvas_sidecar_unreadable` through `CanvasStore.loadForTransientWrite()`; call `MCPResponseBudget.enforce` for unbounded text.
5. Announce a write with `.maughamCanvasNodesAdded` (`Maugham/Events/MaughamEvent.swift`) for `CanvasClaudeArrivalModifier`.

Checks: `MCPCatalogConsistencyTests`, `CanvasToolsTests`, the tripwire 32 census.

### Add a region or line behaviour on the canvas
1. The gesture in `CanvasInteraction.swift`: a pure query or a `Kind`; membership only through `joinTarget`/`absorbedNodes`, never on a move or resize.
2. Its wiring in `CanvasView.swift` (`handleDrag`/`handleClick`), inside the view's own bracket (`mutate`/`withScene`), with `CanvasEditGate.dragBegins` asked first.
3. Record through `CanvasMembership.swift` or the scene's own verbs in `CanvasScene.swift`.
4. Draw it in `CanvasRenderer.swift` in the existing pass order and hit-test it in the same order read backwards.
5. Speak it in `CanvasAccessibility.swift`, rebuilt from `sceneRevision`.

Checks: `CanvasMembershipTests`, `CanvasRegionInteractionTests`, `CanvasViewMountingRegionTests`, `test_theClickOrderIsTheDrawOrderReadBackwards`.

### Add a calibration knob
1. A `static let` in `CanvasMaterial.swift` (a light/dark pair if it differs), passed to `CanvasGround.metal` as a uniform if the shader needs it.
2. A row in the knob table below, with any quoted value in the figure notation.

Checks: `DocSyncTests.test_theCalibrationFiguresInTheCanvasAreaFileMatchTheirConstants`, `CanvasGroundTests`.

| To change | Edit |
|---|---|
| more / less texture | `lightGrainAmplitude`, `darkGrainAmplitude` |
| stronger / weaker lamp | `lightLampDepth`/`darkLampDepth` (how fast), `lightLampFloor`/`darkLampFloor` (how far); `lampReach` for the throw |
| lighter / darker ground | `lightBase`, `darkBase` |
| more / less card separation | `darkCardPaper` up, or `darkBase` down |
| more / less tilt | `maximumTiltDegrees` |
| how far a human thing must lean before straight can mean Claude | `minimumTiltDegrees` (0.4°) |
| how strongly a card says Claude put me here | `lightClaudeCardPaper`, `darkClaudeCardPaper` |
| how strongly a line says it | `lightClaudeLineStroke`, `darkClaudeLineStroke` |
| how far a dimmed thing recedes | `dimmedOpacity` (0.22), applied by `dimmedAlpha(lit:)` |

## Pointers
- Design: `docs/superpowers/specs/2026-07-25-planning-canvas-design.md` (§7A binding: §7A.2 the drawn/edited seam, §7A.5 focus, §7A.6 accessibility; §4 regions and the dim; §6 promotion; §8A input routes).
- ADR 0026 (`docs/adr/0026-planning-canvas-rendering.md`): rendering, membership (§8), promotion (§9), the ADR 0018 exception. ADR 0023 for the op-log undo the canvas does not use.
- Measurements: `docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md`.
- `docs/tripwires.md` rows 25–33.
- Neighbouring guides: `Maugham/Stores/AREA.md` (Rules → "Statement and canvas asset wells"; `sendToCanvas` under "The inbox"), `Maugham/MCP/AREA.md` (`list_canvas`, `add_canvas_scraps`), `Maugham/Views/AREA.md` (the window, personas).
- Tests worth knowing: `CanvasMembershipTests`, `CanvasCompositionTests`, `RegionBindingTests`, `PromotionCommandTests`, `CanvasLiveSeamTests`, `CanvasEditGateTests`, the `CanvasViewMounting*` family.
- History, rationale and every measurement behind these rules: `docs/history/canvas.md`.
