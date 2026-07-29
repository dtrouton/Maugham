# Planning canvas + promotion (M1C) — design

*Brainstormed 2026-07-25. This is milestone M1's third and final plan, after 1B (the persona shell, merged `b250c6d`) and 1A (the spine, unwritten). It designs the Plan persona's centre column: a freeform canvas, and the promotion step that turns scratch into durable artifacts.*

*Umbrella design: [`2026-07-25-mode-based-ux-redesign-design.md`](2026-07-25-mode-based-ux-redesign-design.md) §7 (canvas + promotion) and §8 (the bridge to authoring). That document deliberately left the canvas thin; this one fills it in.*

---

## 1. What the canvas is for

The canvas is **where you think before things have firmed up**. Messy, spatial, associative, no schema. Most of what lands on it will never become anything, and that is the point — the value of scratch is that most of it never has to be decided about.

Everything else in Maugham is the opposite: the op log is truth, the manifest is structured, annotations are adjudicated. The canvas is the one surface where nothing has to resolve. **Promotion** is the single seam between the two worlds.

**The governing rule, stated once and enforced everywhere below:** nothing on the canvas becomes durable except by an explicit act the writer performs and can predict the outcome of.

### 1.1 Why this shape — the evidence

This design is not invented. The research (2026-07-25, in-session) surveyed Obsidian Canvas, Scapple, Tinderbox, Kinopio, FigJam, tldraw, Milanote, Scrivener's corkboard, and the spatial-hypertext literature. Four findings bind the design:

- **Shipman & Marshall, *Formality Considered Harmful* (CSCW 8(4), 1999)** is the spine. Writers refuse to formalise for four reasons — cognitive overhead, tacit knowledge, premature structure, situational structure — and the second is the one that matters here: *the scrap you cannot yet name is the one worth keeping*. Their licence for machine inference is conditional: inference is safe **iff the writer sees it and can reject it cheaply**.
- **No surveyed tool cashes spatial membership into a durable link graph.** Obsidian canvas edges write nothing into markdown, produce no backlink, and don't appear in graph view — held for three years against a standing feature request. Scapple's background shapes are pure geometry and its Scrivener handoff drops connections entirely.
- **Kinopio deleted author-typed connections in April 2026**, after shipping them for years, because "connection types were confusing for people I observed using the tool for the first time." Untyped edges with an optional free-text label is the empirically supported floor.
- **Scrivener's freeform corkboard is the cleanest promotion precedent in writing software**: cards move in 2D without touching the binder, then an explicit **Commit** reorders it by a stated rule. Named, predictable, previewable, single-purpose.

---

## 2. Scope and relationship to existing surfaces

**One canvas per project.** Regions do all the dividing. For a collection like Playlist you see every piece at once and the space between them is meaningful, which is what a collection needs. Crowding is answered by zoom and by collapsing a region, not by minting more canvases.

Maugham now has three card-based surfaces, and the distinction must be stated in the UI, not discovered:

| Surface | Cards are | Position means | Lives in |
|---|---|---|---|
| **Corkboard** (existing) | documents | manuscript order | structure view |
| **Palette wall** (existing) | palette cards | nothing (grid) | binder segment |
| **Canvas** (new) | anything, mostly scraps | nothing | Plan persona, centre column |

The Corkboard is **structural** — its cards are real documents and their order is the book's. The palette wall is **resolved** — its cards are finished palette cards. The canvas is **pre-structural**: most of what is on it is not anything yet, and never will be.

So the two existing surfaces show artifacts that already exist, arranged by a rule; the canvas shows work in progress, arranged by hand. **Both survive.** The canvas is one way of arriving at a palette card; the wall is where the palette cards you arrived at are kept. Replacing the wall with the canvas would confuse "the mess I am making" with "the decisions I have made", which is the exact distinction this milestone exists to draw.

---

## 3. What lives on the canvas

Two kinds of node, and the distinction is the whole data model.

### 3.1 Items — things that already exist

Research notes, palette cards, images, and craft-intent docs appear on the canvas **as themselves**. The canvas holds only their position; the file on disk is untouched and remains the truth. Deleting a node from the canvas removes it from the canvas, never from the project.

> **Amendment, 2026-07-30 (Denver, deriving §8A.4).** An item node has **two provenances**, and only the first is described above.
>
> - **Referenced** — the thing already exists in the project. The canvas holds a position and nothing else, and the paragraph above is exactly right about it.
> - **Owned** — the thing arrived *here*, from a capture or a drop, and had nowhere else to live. The canvas ingests the file and owns it.
>
> The second is not a weakening of the first, it is what a queue forces: an inbox capture's asset lives under `.maugham/inbox/`, which the writer *clears*, so a node pointing at one dangles the moment they tidy up. Something has to give the file a home, and §8A.4 rules that the canvas does — the way a palette card owns its `<slug>_assets/` rather than referencing wherever the photo came from.
>
> **This is the palette's shape, adopted rather than invented**, and the adoption is the whole ruling: one ingestion pair (`ProjectStore.addImage(toPaletteCard:image:)` / `(…fileURL:)`, `ProjectStore+Palette.swift:143` and `:153`) over one saver already shared with research notes (`ImagePasteHandler.saveAndReference…`), with **five callers across three routes** — three pastes and a file drop in the card editor, plus `InboxStore.promoteToPaletteCard` (`InboxStore.swift:305`), and MCP `promote_inbox_entry` reaching the identical seam. The inbox never needed a storage rule of its own there and does not need one here: **every route is a caller, not a decision.**
>
> **An owned image is referenced by PATH, not by an item id**, matching the palette's own model — and arriving independently from the other direction, since tripwire 22 already requires the thumbnail cache be keyed by path rather than id. Two forces landing on one answer. The encoding is 1C-d's (`CanvasNodeKind.item(referenceId:)` currently carries a project item id, and a path in the same field would be two namespaces in one string); what is settled here is that a path is what identifies it.
>
> **§8's "the canvas never writes to a research note, a palette card, or an image" stays true and now needs to say what it is about.** It is about **items**, and an owned capture is not one. Read as written it forbids the asset store §8A.4 requires.

### 3.2 Scraps — things that exist only here

A loose thought typed straight onto the canvas is a **scrap**. Scraps are canvas-local: they do not appear in the research tree, cost no filename, and require no decision about what they are.

**Scraps are still plain text on disk.** They live as entries in a single human-readable file (`canvas.md` at project root, or under `research/` — the plan decides), so a writer can read them in any editor forever and Maugham's plain-text guarantee is not weakened by a sidecar-only content store. Positions live in the sidecar; the words do not.

This is the one place the design admits a new content location, and it is justified: making every scribble a research `.md` means creating files in order to have a thought, which is the opposite of scratch.

---

## 4. Regions

A **region** is a labelled area you draw on the canvas. Regions are the canvas's only grouping primitive.

### 4.1 Regions own their contents, for movement

Drag a region and its members travel. This is what makes reorganising one gesture rather than a marquee-select.

### 4.2 Membership is explicit, and no *transition* changes it

Membership changes **only** by deliberate act: dropping a node onto a region adds it; drawing a region around cards adds them; an explicit remove takes it out. **Moving or resizing a region changes nothing.**

**This eliminates a bug class every surveyed tool has.** Obsidian leaves behind a card poking one pixel outside a group. tldraw ejects children when a frame is resized — *despite* storing membership explicitly ([issue #6017](https://github.com/tldraw/tldraw/issues/6017)) — because the geometry→membership transition rule is the hazard, independent of storage. Scapple recomputes from live geometry and has an unfixed bug where a note shared by two overlapping shapes moves with whichever shape you happen to grab.

The cost is that a node can sit visually outside the region that owns it. That is a rendering problem (draw the relationship), not a correctness one, and it is the better trade.

> **Amendment, 2026-07-28 (Denver, after the 1C-b smoke).** This section first read "Coordinates never add or remove a member", and creation was covered by that. It is not any more: **sweeping a region around cards takes in every card whose centre is inside the swept rect, and a scrap made inside a region joins it.**
>
> The reason the original rule survives the change is that all three bugs above are **transitions** — a tool deciding whether an *existing* relationship survives a change to geometry. Creation is not a transition: there is no prior state for it to contradict, and sweeping a rectangle around five particular cards is as deliberate an act as this surface offers. The partial-overlap objection is answered the way drops already answer it, by the card's centre.
>
> So the firewall now reads: **creation absorbs, transitions do not.** Move and resize are the load-bearing half and are unchanged. Two exclusions, both cases where "the writer swept around it" is untrue: an unmeasured card (no frame, so nothing was drawn to sweep around) and a card hidden inside a collapsed region (not drawn at all). A card that already lives in another region *is* taken in — one home, always (§4.3), and this is the writer moving it.

### 4.3 Membership is not exclusive — one home, many appearances

Planning is associative: the street photo belongs to *Good Luck Babe* and to the book's visual language; October's swatch is in the palette cluster and the falls cluster. A strict ownership tree would force duplication or a premature choice.

So a node **lives in** exactly one region (or nowhere, loose on the canvas) and can **also appear in** any number of others.

- *Lives here* is the tiebreak that makes §4.1 work: **only a node's home region moves it.** Drag the region a node lives in and it travels; drag a region it merely appears in and it stays put. A visitor is not luggage — being cited by a cluster should not let that cluster drag you around the canvas.
- *Also appears in* is a reference, not a copy. **Copies are rejected outright**: Maugham is single-source-plus-derivation everywhere (op log → `.md`, palette card model → markdown, one docs source → three surfaces), and two editable copies of one note is precisely the failure the architecture exists to prevent.

**An appearance must not render identically to the thing itself** — otherwise the copy problem returns visually and you cannot tell which is real. An appearance reads as a reference: smaller, or a chip carrying the title with a hairline to its home. Any region should answer "which of these live here and which are visiting" at a glance.

### 4.4 Regions bind to pieces — this is the bridge

> **Amendment, 2026-07-29 (Denver).** This binding is no longer only 1A's to consume. It is the **piece association** of §6.2, and it decides where a promotion from that region — or from a scrap that lives in it — lands. Same field, same picker; a second reader, which exists today. The binding is *not* a promotion target: it produces no artifact and the picker already sets it. See §6's 2026-07-29 amendment.

A region may optionally bind to a piece. That binding is the mechanism from umbrella §8: **the nodes that live in a piece's region become the pinned references beside the editor when you write it, and the context the authoring compiler reads.** The clustering you did while planning pays off twice, with no separate curation step.

Only nodes that *live* in the region are bound. Visitors are not, or two regions sharing a card would each claim it.

---

## 5. Lines

Freeform, **untyped**, with an optional free-text label. Stored in the sidecar. They carry no semantics and assert nothing.

A line costs nothing to draw and nothing to be wrong about, which is what thinking needs. `[[wiki-links]]` remain the durable relationship layer — reached deliberately, through promotion.

**No typed edge vocabulary in v1.** Kinopio built exactly that, shipped it for years, and removed it three months ago for costing more than it returned.

**Precedence must be stated in the UI, once, plainly:** wiki-links are durable, canvas lines are scratch. Obsidian's three-year confusion is entirely a consequence of never answering "which of these is the real relationship?"

---

## 6. Promotion

**One verb.** Not a gradient, not an automatic mode, not a background process.

| Promote | Produces |
|---|---|
| A scrap | a research note, a palette card, or an intent statement |
| A region | a research note, or a palette card |
| A line | a `[[wiki-link]]`, when both ends have themselves been promoted |

> **Amendment, 2026-07-29 (Denver, after the 1C-c2 smoke).** The region row read *"a palette card, or a piece binding"*. Both halves were wrong in practice, and the smoke is what showed it.
>
> **A piece binding is not a promotion.** It produces no artifact — it sets `CanvasRegion.boundPieceID`, which the region inspector's own **Piece** picker already sets, so the sheet offered a second door to an existing control while wearing the words "Produce" and "Goes to". And the field's only intended reader is 1A's reference rail, which is unbuilt: measured 2026-07-29, `RegionBinding.references(forPiece:)` has **zero production callers**. The writer's report was simply "I don't see it doing anything", which was accurate. Removed as a target; the picker stays.
>
> **A region produces a research note.** A cluster of text scraps is a note — grouped, in the region's own reading order, with §6.1's offer to link each promoted member to it. The palette card **stays** on the row, and its case gets stronger rather than weaker in 1C-d: a palette card is worth making from a region that holds an *image*, which the canvas cannot hold until then. Today it makes a card of joined prose with no swatches and no images, which is why it could not be the only option.

### 6.2 A piece association, and where a promotion lands

*Added 2026-07-29 (Denver), same ruling.*

A **scrap** and a **region** may each carry an optional piece association. It is the same field on both (`boundPieceID`), it is set in the inspector, and it now has two readers rather than none: 1A's reference rail later, and **where a promotion lands** today.

**Resolution is by precedence, and nothing is ever overwritten.** A promotion's piece is:

1. the scrap's **own** association, if set;
2. else its **home** region's association;
3. else none — the project's own research.

Setting a region's piece never rewrites its members' — the more specific setting wins, exactly as a per-piece craft intent already beats the project's. The alternative considered and rejected was a region-level set cascading onto its scraps: it destroys a deliberate per-card choice invisibly, and it reintroduces §4.2's rejected bug class in a new place, since a card *cited* in two regions bound to different pieces would follow whichever was touched last. **Home decides and visitors do not** is already §4.3's rule for dragging; this is the same rule, applied to destination.

**Where the artifact goes is already decided, and not by this design.** `ResearchScope` (2026-07-07's scoped-research milestone) routes `.document(id)` by project type, and promotion adopts it rather than inventing a second rule — checked against `Maugham/Stores/ResearchScope.swift:26-86`:

| Project | Route | What the association becomes |
|---|---|---|
| Collection, **loose** piece | `.pieceFolder` | containment — the note is created in the piece's own `research/` |
| Collection, **reference** piece | throws | the piece keeps research in its own project |
| **Novel** | `.sharedPlusLink` | shared `research/`, plus a `linkResearch` record, written automatically |
| **Short story / screenplay** | `.sharedOnly` | shared `research/`, no link — derivation already surfaces everything as that document's |

So "capture the association on the note when there is no structural place for it" is not new work: `route(_:shared:piece:)` already does exactly that, and the dormant-link rule (2026-07-17) already stops containment and a manual link double-counting the same pair.

**The picker offers only pieces this can route.** `ProjectStore.researchScopeTargets()` exists for precisely that — its own doc comment says it "drives the promote-target picker" — and the region inspector's picker currently offers every `.document`, including the reference pieces the router throws on. Using it means a promotion can never fail on a piece the writer was invited to choose.

A **palette card** is not routed: the wall is project-level and a card must live under the palette group. It takes the link when the routing would have been `.sharedPlusLink`, and nothing otherwise — the same decision, read from the same function.

**The writer is told which route was taken, in the preview**, before committing. A piece that keeps no research of its own says so in the sheet rather than throwing or silently redirecting: §6.1 requires the writer see what will be produced and *where*, and a fallback nobody can see fails that test. In a novel the writer is not thinking in pieces at all, so the fallback is the ordinary case and not an error.

**The craft intent takes the scope and never the link.** `createCraftIntent(forPieceId:)` already handles a loose piece; anywhere else it falls back to project scope and stops. An intent doc is a singleton per scope, and linking the *project's* intent to one chapter would misrepresent what it is.

### 6.1 Rules

- **Explicit and user-initiated.** Nothing promotes because it sat somewhere long enough or looked like something.
- **Previewable.** The writer sees what will be produced, and where, before committing — Scrivener's Commit is the model: a named command with a stated rule and a predictable outcome.
- **Allowed to be lossy, and that is a feature.** Promoting a region need not preserve its lines or its layout. The spatial work was thinking; it earned its keep by producing the artifact. Scapple → Scrivener keeps nodes and drops connections, deliberately.
- **May suggest, must never impose.** Promoting a region may *offer* to link its text members to the artifact it produced — "these six scraps are in 'Act II fog' — promote as a note, link them, or just keep the label?" That sits squarely inside Shipman & Marshall's licence **because the writer sees the inference and can decline it**. The same inference applied silently is forbidden: membership is n-ary and vague, wiki-links are binary and specific, and the silent conversion manufactures precision the writer never claimed — into a layer with backlinks and rename propagation, where it is expensive to undo.
- **A line only promotes once its ends exist.** `[[X]]` resolves against the manifest — documents and research items — and a scrap is in neither, so promoting a line between two unpromoted scraps would write a link that resolves to nothing. That is the *manufactures precision the writer never claimed* failure this section forbids, arriving through the one row that looked safest. So `.wikiLink` is offered only when both endpoints carry a promoted item, and the refusal has to teach the precedence rather than merely decline: the durable layer is reached by promoting the things first.

- **Promotion is never required.** The canvas must be completely usable by a writer who never promotes anything. Readiness counts promoted artifacts and stays silent about the canvas (umbrella §7, §9).

> **Amendment, 2026-07-28 (Denver, re-deriving 1C-c2 against the built canvas).** Four rulings, none of which change the table above. Recorded here rather than in a second spec, so §6 stays the one place promotion is described.
>
> **1. A promotion is a SNAPSHOT taken by an explicit act, and it never syncs.** The mark a promoted card carries is *provenance*, not a live link, and there is no reconciliation because none is promised. This is not a concession — **the region row forces it**: promoting "Act II fog" to a palette card joins six scraps' text while all six stay on the canvas, so a copy at a moment is already what §6 describes. Making a scrap's promotion behave differently (moving its words out to the note) would give one verb two rules and would pull item-card rendering — 1C-d's work — forward to stop every promoted card drawing as a dashed placeholder.
>
> **2. Re-promoting offers Update or New, and the writer picks every time.** A card that has been promoted names its artifact in the sheet, which then offers to rewrite that artifact's body from the card, or to produce a second one. Neither is the default. "Always update" eats edits made in `research/`; "always new" leaves `The falls at night 2`, `… 3` and two orphans nobody asked for. The choice is one sentence of preview, which is what §6.1 already requires of everything else here.
>
> **3. The gesture is a menu command on the current selection.** `Promote…`, ⌘⇧↩ (⌘⇧P is taken by Toggle Research Preview), plus a `Promote…` button in each arm of the canvas inspector — region, line, and a new **scrap** arm, which is also where a card says what it became. Every one of those buttons posts the **same** command the menu posts, so the button and the keystroke cannot drift into behaving differently. This closes §10's first open question; ADR 0026 carries it.
>
> **4. The line row ships with a reader.** §6.1's rule above is right about the *target* side — `ListAllLinksTool`'s title index covers documents **and** research items. The *source* side was not checked and is narrower: `ListAllLinksTool.swift:93` and `ReferenceTools.swift:180` scan `[[…]]` **only in manuscript documents**, `ResearchNoteEditor` has no wiki-link handling at all, and rename propagation (`ProjectStore+Structure.swift:400`) walks documents only. Since promotion never produces a manuscript document, every link it writes lands in a research note — inert on all four counts. So 1C-c2 teaches `list_all_links` and `find_references` to scan research bodies in the same slice. Shipping the row without that would be this area's fifth built-and-unreachable half, and the previous four were each found by counting callers rather than by a test.

---

### 6.3 What a promotion records on the cards it consumed

*Added 2026-07-29 (Denver, after the 1C-c2a smoke).* Promoting a region produced the note and told the region so — and left every card whose words are now in that note reporting **"Not promoted yet"** in its own inspector. The writer's report: *"not all the scraps know they were promoted, some think they weren't — all did turn up in the research note though."* The cards that did say promoted were the ones promoted individually earlier, carrying their own mark. Two truths on one screen, and the screen was lying.

**A contributing card carries a record, and it is NOT the promotion mark.** The distinction is load-bearing rather than tidy. `promotedItemID` means *"I am this artifact"*, and `existingArtifact` reads it to offer **Rewrite**. Stamping a contributor with the same field would mean promoting one member afterwards offers to rewrite the six-card note with that one card's text — which is the 1C-c2 Critical (a mark that did not record the artifact's *kind*) returning as a mark that does not record its *cardinality*. So:

- **`promotedItemID`** — this card produced this artifact. Readable as an Update.
- **the contribution record** — this card's words are *in* that artifact, along with others'. **Never** an Update; re-promoting a contributing card offers only a new artifact.

**Who is recorded, and when.** Exactly the members whose text went in — home members with non-empty text, which is already one function (`Promotion.regionBodies`) read by the preview, the refusal and the body. Recorded at promotion time, not derived from live membership: a card added to the region *afterwards* has no words in that note and must not claim to.

**One gesture, one undo step.** The region's mark and every contribution record are written in a single bracket, so one ⌘Z takes back the whole promotion's canvas-side effect rather than leaving cards claiming a note the region no longer names.

**An update re-records.** Rewriting a region's note rebuilds its contributors: cards that have left the region since stop claiming it, and cards that joined start. The note is written from the current members, so the record follows the same set. **The record is single-valued and the most recent contribution wins**: a card dragged from one promoted region into another, which is then promoted, names only the later note while its words are in both. That is the cost of one field, and it is accepted — a *set* would put a growing, never-collected list of ids on every card, each able to dangle, to describe a snapshot the writer took once, and provenance reads most usefully as the most recent act.

**A card may carry both**, and they say different things: it produced its own note, *and* its words are in a region's. The inspector shows both rather than choosing.

**The record is shown in the inspector and deliberately NOT drawn on the canvas.** The promoted mark's stripe means *this produced that*; a second stripe of the same kind for *this went into that* would assert on the canvas the very distinction this section spends its length drawing, and the writer would have no way to tell which one they were looking at. The record is an inspector fact, reached by selecting the card. **It is not announced either** — `CanvasAccessibility` names the mark and says nothing about the record — so a VoiceOver user meets the same silence rather than a different one, which is the consistent answer and not an omission on top of a decision. Stated here because a smoke session cannot overturn what a smoke session cannot perceive: if the ruling is revisited, the record needs a visual language and an announcement of its **own**, never the mark's.


## 7. How it feels

The editor is deliberately austere to protect flow. Planning is associative and messy, so the canvas can afford to feel like somewhere else — and the persona bar has already told the writer they *are* somewhere else.

### 7.1 The ground

- **Light:** a muted canvas weave. **Dark:** slate under a lamp — a different material, not the same texture inverted. Paper is a light-mode idea.
- **Washed 3–5% by the project's own sensory palette swatches.** Playlist's canvas looks like Playlist; a hospital novel's does not. This is the through-line made visible on the surface where it is assembled, and nothing else on the market can do it, because nothing else holds the palette. **Dosage is the risk**: at 15% a grim palette yields a canvas you cannot work on. The wash is felt, not seen.
- Light falls from one corner. Light ages better than texture.

### 7.2 The cards

Crisp edges. Each card sits at a **seeded fraction of a degree** — nothing is rough, but everything was *put down* rather than snapped to a grid. **The card you are editing straightens to level and stays there until you leave it** — see §7A.5, where that turns an architectural collision into the focus affordance.

The seed is derived from the node's id and is **stable**: a card must never shimmer or shift between renders. Deterministic irregularity, not random.

Rejected, with reasons: displacement-filtered "inked" edges read beautifully but cost a per-node SVG filter, and at canvas scale that is a performance question we would rather not answer. A CSS transform costs nothing at two hundred cards. Literal paper fibre on the *cards* (as opposed to the ground) was rejected as the thing that dates — cork boards looked like that in 2011.

The texture lives in the world; the cards are honest objects sitting on it. The real/manufactured line runs between the ground and the cards rather than through each card.

### 7.3 Motion

Cards carry momentum and come to rest rather than snapping. This is where tools actually acquire feel, it reads as craft rather than theme, and unlike texture it never dates.

*Candidate, not committed:* a trackpad haptic tick when a node joins a region. Genuinely sensory, well supported on Mac, almost nothing uses it well. Include only if it survives the smoke without feeling gimmicky.

---

## 7A. Rendering architecture

*Added 2026-07-25 after research into how comparable surfaces are actually built. This section is binding: it constrains §7's feel work and every task in the plan.*

### 7A.1 Draw the nodes; mount one real editor on focus

**A single SwiftUI `Canvas` renders every node, region and line. Exactly one real `NSTextView` is mounted, on the scrap currently being edited.**

This is unanimous convergence, not a preference. Excalidraw, tldraw, Miro, Figma and AudioKit's `Flow` all do it; `Flow`'s source says so in a header comment (*"We found this is faster than using a View for each Node"*), and its author's other project states plainly that SwiftUI "simply can't handle big node graphs very well — we have tried." Apple's own Freeform is the same shape: its binary links MetalKit and bundles `TSDrawables`, the iWork drawing engine, and `NSTextView` does not appear in it at all.

Three constraints force it:

- **`.scaleEffect` scales *rendered output*.** Text blurs when magnified, and geometry read back through `GeometryProxy` is in unscaled layout space. It also breaks `NSCursor` tracking (Apple Forums 780215, macOS 15.4/15.5, DTS-acknowledged, no workaround). "Crisp text at all zoom levels" rules it out as the zoom mechanism, and it is the only thing that makes a pure-SwiftUI canvas pleasant.
- **macOS 15 `_hitTestForEvent` regression** — trackpad scrolling spends 70–85% of its time hit-testing, scaling with view count (Forums 764264, still reported March 2025). A trackpad-panned canvas holding hundreds of interactive views is exactly this bug's shape. Drawing means ~2 views on screen instead of 300.
- **SwiftUI has no lazy 2D container.** `LazyVGrid` is 1-D; `ZStack` and the `Layout` protocol are eager. Culling must be manual — and culling by removing entries from a `ForEach` destroys view identity, losing focus and any in-progress edit. Drawing sidesteps the whole problem: culling is `guard rect.intersects(viewport) else { continue }`.

**Camera** comes from a transparent `NSViewRepresentable` overriding `scrollWheel(with:)` and `magnify(with:)`. SwiftUI cannot do this: it exposes no scroll-wheel API on macOS, `MagnificationGesture` provides no centre point, and `.simultaneousGesture(DragGesture())` never fires on macOS at all (Forums 718959). Apply the camera with `cx.translateBy`/`cx.scaleBy` so glyphs rasterise under the final CTM and are crisp at every zoom.

**Hit testing** is an inverse transform plus a reverse-z rect test against the model. Exact, cheap, and it never touches SwiftUI's event machinery.

**Lines and regions draw in the same pass**, off the same model. Because the model already owns every node's position, there is no geometry to read back — which is the only reason `anchorPreference` exists, and it costs a double body evaluation per frame that a drag cannot afford.

### 7A.2 The biggest risk: the seam between drawn text and edited text

When a scrap gains focus, a real `NSTextView` replaces the drawn glyphs. **If its layout differs from the drawing by even a fraction — line breaking, leading, hyphenation — the text visibly jumps every time the writer clicks in, and again when they click out.** On every edit, in a tool whose whole promise is that the surface is trustworthy.

**Mitigation is structural and must be designed in, not patched on: draw with the same TextKit stack you edit with.** Lay out once through `NSTextStorage`/`NSTextLayoutManager` and use that same layout for both the `Canvas` draw and the mounted editor. Never SwiftUI `Text` for display and `NSTextView` for editing. Maugham already owns a TextKit stack in `Maugham/Editor/`, which makes this tractable — but the renderer must consume TextKit output from day one.

**Pin it the moment it works:** focus and blur a scrap, assert the rendered glyph origins are identical. This is the regression most likely to creep back.

Two rules borrowed from tools that shipped this: **stop drawing a scrap while its editor is live** (Excalidraw — the editor *is* the visible text, so there is no double-draw), and **place the caret from the click point** via `NSTextView.characterIndexForInsertion(at:)` (Miro), so clicking into a scrap lands where the writer aimed.

### 7A.3 Scrap geometry — width is authoritative

A scrap stores a **width**; its text reflows to fit and its height is derived. Resizing rewraps.

This is a schema decision and cannot be retrofitted. It is consistent with where scraps go when promoted — a research note is plain Markdown that reflows — and with the codebase's single-source-plus-derivation grain. Rejected: baking rendered line breaks, which would make a thinking surface behave like a layout surface.

**Known cost:** if the canvas font changes (theme, OS update, a Maugham release), heights shift and previously tidy cards may overlap. Cache the measured height so layout is stable until something forces a re-measure.

### 7A.4 The ground

`Rectangle().fill(ShaderLibrary.…)` — a Metal shader (`[[stitchable]]`, macOS 14+) with **pan and zoom passed as uniforms, sampled in content space**.

- A shader using bare `position` makes the grain **crawl** across the paper as you pan.
- Core Graphics patterns are disqualified outright: pattern space maps to base user space *"regardless of the state of the current transformation matrix"* (Quartz 2D Programming Guide), so `NSColor(patternImage:)` pans but **cannot zoom**.
- CPU tiling measured **2.77 ms/frame** over 2560×1600, flat across zoom — ~17% of a 60 Hz frame and over budget at 120 Hz.
- Seeded `SplitMix64` noise generation is effectively free (0.115 ms for a 512² tile). `UInt8.random(in:)` is ~60× slower because it is CSPRNG-backed — an easy and invisible trap.
- **Fade grain amplitude as a function of zoom** to kill moiré on zoom-out; analytically `fwidth(content) == 1.0/zoom`, so no derivative functions are needed.

**Hard constraint:** a shader applied *over* a subtree containing an `NSViewRepresentable` logs a warning and renders a placeholder (documented on `colorEffect`/`layerEffect`/`distortionEffect`). The ground must be a **sibling layer beneath** the content, never an overlay across it.

### 7A.5 Cards — and focus straightens the card

§7.2's seeded sub-degree rotation becomes a transform in the draw call rather than a view modifier — cheaper still, and the stability requirement is unchanged: seeded from the node id, never random per frame.

**The rotation collides with §7A.1, and the resolution is a feature rather than a compromise.** A mounted `NSTextView` cannot be rotated: `.rotationEffect` blurs text and breaks `NSCursor` tracking (the same defect that disqualified `.scaleEffect` in §7A.1). So a card drawn at an angle whose editor mounts level would snap its text straight on every click — precisely the §7A.2 failure, reached by a route §7A did not anticipate.

**So the whole card straightens when it takes focus, and that is the focus affordance.**

- Click a card → the **entire** card animates to level, chrome and text together, over ~120 ms.
- The editor mounts the instant the card is clicked — so nothing typed straight after a double-click is lost — but it stays **invisible** until the card is level, and the card goes on drawing its own text (live, and rotating) until then. The editor is therefore always axis-aligned by the time it *is* the visible text. `.rotationEffect` never enters the picture.
- On blur the card settles back to its seeded angle.
- The card being edited is therefore the only square one on the canvas — a "this one is live" signal that costs nothing, because everything else stays tilted.

This is the physical metaphor the surface is already reaching for: you pick the paper up and square it to write on.

**It makes §7A.2 easier to guarantee, not harder.** At mount time both the drawn and the edited layout are unrotated, so the glyph-origin pin compares two axis-aligned layouts. The rotation never participates in the agreement the spike measured.

**Two requirements that follow:**

1. **Compute the caret index before animating.** Miro's rule is that clicking into text lands the caret where the writer aimed. If the card straightens first, the click point has moved out from under the cursor — so resolve the caret at click time in the card's **local, unrotated** space, which inverse-transform hit-testing already produces, then animate, then mount with the target already known.
2. **Animate, never snap.** An instant jump reads as a rendering bug; a brief straightening reads as the card responding. The rotation is a value the renderer interpolates — the same per-frame shape as §7.3's momentum decay, so no new machinery.

**Watch in smoke:** there is a beat between click and caret. At ~120 ms it should read as responsiveness rather than lag, but only the hand can tell.

### 7A.6 Costs accepted, stated plainly

- **More code than a `ZStack`.** Accepted; the alternatives fail a stated requirement.
- **We own accessibility for the canvas.** Drawn content has no AX tree, and the W3C's enumeration of what you forfeit by drawing text — IME, caret placement, spell-check, selection, magnification following the caret — is the reason the one-real-editor-on-focus rule exists. Budget an AX layer mirroring the scene graph; Figma does exactly this. **Not optional in a writing tool.**

### 7A.7 Spike before committing

The plan's first task is a **timeboxed spike**, not construction. The runner-up architecture — `NSScrollView` with a document view and real subviews — gets crisp text and real editing for free, plus `setMagnification(_:centeredAt:)` (zoom-to-cursor, correctly, including clamping). It is held at second only by three unresolved risks: an `NSScrollView`-magnification coordinate-translation bug against SwiftUI content (reported 2021, **unverified on macOS 15**), `_NSTiledLayer` seams at certain zoom factors (Forums 663536, open since 2020), and per-node `NSHostingView` cost.

**If that coordinate bug is fixed on macOS 15, the runner-up may beat the recommendation on effort.** Verifying it is the single cheapest experiment available, and the spike must answer it — along with `_NSTiledLayer` seams at ~1.5× zoom, which are a hazard for *any* magnification route.

---

## 8. Persistence

- **Node positions, region geometry, membership, lines, and seeds** → sidecar under `.maugham/`. Derived UI state; deletable without loss of content; never the truth about anything.
- **Scrap text** → the plain-text scraps file (§3.2). Content, not state.
- **Referenced items** → untouched. The canvas never writes to a research note, a palette card, or an image **it did not ingest**. *(Qualified 2026-07-30 — see §3.1's amendment: the rule is about items, and an owned capture is not one. Unqualified, this line forbids the asset store below.)*
- **Owned captures** → an assets folder beside the scraps file, at the project root. Content, exactly as scrap text is content: deleting the sidecar costs the arrangement and never the words, and it must never cost the photographs either. Written **only** through the one ingestion pair §3.1's amendment names, so the canvas has one place that decides where an image lands and one deletion story to keep. *(Added 2026-07-30, §8A.4; built in 1C-d.)*

Membership is **stored**, never recomputed from coordinates at read time (§4.2).

---

## 8A. Getting things onto the canvas

*Added 2026-07-25 after the plan review. Three routes, in descending order of how often a writer will use them.*

### 8A.1 Drag in from research

The binder is beside the canvas in the Plan persona, and its research tree is the natural source. **Dropping a research item onto the canvas creates an item node** (§3.1) — the file is untouched, the canvas holds only its position.

- **Internal drags** carry the item id and follow the app's established `.draggable(id)` / `.dropDestination(for: String.self)` pattern.
- **External drags** — a photo from Finder or a browser — route through `DropClassification`. Browser image drags carry rendered bitmaps rather than file URLs, so `.dropDestination(for: URL.self)` silently rejects them; do not hand-roll this.

**Images are in scope for this milestone, not deferred past it** — they belong to plan **1C-d** alongside the rest of §8A, not to 1C-a, which owns the surface and scraps. The distinction matters: M1C is not finished without them, and no plan may cite this section as authorising their omission from the milestone. The canvas is the first surface in Maugham with an unbounded image count, and no image cache or real downsampling exists anywhere in the app today — the palette wall's helper decodes at full size then redraws. Image nodes need a `CGImageSource` thumbnail path and a bounded cache **keyed by path, not id** (tripwire 22).

### 8A.2 Paper → photo → Claude → canvas

The writer draws on actual paper, photographs it, and it lands in Maugham — through the phone Capture inbox, or dropped straight onto the canvas. **Claude reads the image over MCP and adds what it finds to the canvas as nodes.**

This is a new MCP surface: the canvas gains a small write path alongside its read tool. It is the first time Claude creates canvas content.

**Constitutionally this is permitted, and the reasoning must be recorded rather than assumed.** Must-not #1 forbids AI originating *manuscript* text; the canvas is a planning surface in the parallel plane, exactly where Claude already writes annotations, translations and palette material. Nothing Claude puts on the canvas is manuscript, and nothing reaches the manuscript except through promotion (§6), which is a deliberate writer act.

**Two constraints follow, and both are load-bearing:**

1. **Claude-created nodes must be visibly marked as such.** The writer must be able to tell at a glance what they wrote from what was read off a photograph. Reuse the annotation layer's provenance shape rather than inventing one.

2. **The reproduction corollary applies in full.** Must-not #1's corollary treats transcription as the disguised authoring case — *"a confident fabrication in a reproduction channel wears the writer's own voice and invites acceptance instead of scrutiny"* — and requires that the reproduction and its source be checkable side by side. So: **the photo stays on the canvas, and what Claude derives from it is visibly tied to it.** A region containing both the image and its derived scraps is the natural form, and it means "what was read off this page" is answerable by looking. Derived nodes must never be placed loose where their origin is unrecoverable.

No accept/reject queue is needed. The canvas is scratch by construction — the writer moves, edits, deletes or promotes Claude's nodes exactly as they would their own. The marking is what makes that a real choice.

### 8A.3 Collapse to the canvas

A writer will want the canvas at full width with everything else out of the way.

**This is a deliberate toggle, never automatic on entering the persona.** Auto-collapsing would fight §8A.1 — you need the binder open to drag research in, and only then do you want it gone. Note the palette wall *does* hide the inspector automatically on entry (`PaletteSegmentModifier`); the canvas deliberately does not follow that precedent, for this reason.

**Reuse `⌘\` rather than adding a key.** Focus mode already hides the titlebar, traffic lights, persona bar and status footer. On the canvas it additionally collapses both side columns. That extends existing muscle memory instead of teaching a new gesture, and the exit is the key the writer already knows.

Two hazards, both already scarred into this file:

- `PersonaModifier.clearsPaletteStash` exists because `PaletteSegmentModifier`'s `.onChange` fires in a *later* update pass and would otherwise restore stashed inspector visibility over a persona switch's force-open. Any canvas column-collapse that stashes state inherits this exact ordering hazard and must extend the predicate rather than defer a pass (tripwire 2).
- Column visibility must not add an expression to `ProjectWindow.body` (§7A / zero budget).

### 8A.4 Inbox → canvas, directly

*Added 2026-07-30 (Denver, re-deriving 1C-c3). Built in **1C-d**, with the rest of §8A.*

**A capture goes from the inbox onto the canvas in one act, and it must not have to travel through Claude or through a research note to get there.** The writer's words: *"this should NOT need to go via claude or research notes. In many ways inbox to canvas to research makes more sense, but in some cases going from inbox to research is fine."*

**The pipeline is inbox → canvas → research, and only the first arrow is missing.** The second one shipped: promotion (§6) is already how something on the canvas becomes a durable artifact. That ordering is the point rather than a convenience — requiring a capture be promoted to research *before* it can be thought about builds the durable artifact first and does the thinking afterwards, which inverts what the canvas is for (§1). Inbox → research stays exactly as it is and stays appropriate; it must simply stop being the only road onto the canvas.

**One action, all three capture kinds**, and the two halves are not symmetric:

- **Text and voice** need nothing new. The capture's text or transcript becomes a **scrap** — words into the scraps file, keyed by the new node's id, exactly as a typed scrap is — and promotion later turns it into a note if the writer wants one. No new storage, no new namespace, nothing that can dangle.
- **A photograph** becomes an **owned item node** (§3.1's 2026-07-30 amendment): the asset is ingested into the canvas's assets folder through the one ingestion pair, and the node references its path.

**It ships for all three kinds or it does not ship.** An action live for text and voice and absent on photos teaches the writer it is broken, and the photographed page is not an edge case — it is §8A.2's own example and the reason this route was asked for. That is also why this section is **1C-d's and not 1C-c3's**: the photo half *is* the image work (the ingestion seam, the owned-asset store, the path-referenced node, the `CGImageSource` thumbnail and the path-keyed cache), and splitting the action by capture kind to fit it into an earlier slice would ship the bad seam on purpose.

**It reuses the promote contract rather than restating it.** `InboxStore.promoteToResearch` and `.promoteToPaletteCard` already settle the parts that are easy to get wrong and identical here: copy-then-remove the original so a failure leaves a harmless duplicate rather than losing the capture, and flip the entry to `.promoted` **only after every mutating step has succeeded**, so a half-promoted entry is not reachable. A third sibling belongs beside them, not a new spelling of them.

**Where the writer finds it:** the Inbox pane, beside "Promote to Palette" — the precedent for a second destination on the same list, including the case where the destination is picked rather than assumed.

**No MCP write path for this route, and the asymmetry is deliberate.** Claude's way onto the canvas is §8A.2, and its source is a research item — not because that is better but because `read_document` is the only image reader in the catalogue, so a photograph Claude can *see* is one that has already been promoted. Recorded here so the next author meets a decision rather than a gap: if Claude is ever to read a capture in place, the missing piece is an image response on `read_inbox_entry` (today: text, transcript, kind and asset *filename* only), and the corollary in §8A.2 would still require the photograph itself to reach the canvas.

---

## 9. Out of scope

- **Phone.** The canvas is Mac-only. `Packages/MaughamCore` and `MaughamPhone` are untouched, exactly as 1B was. (Note §8A.2's photo route *starts* on the phone via the existing Capture inbox — no new phone code.)
- **Typed edges** (§5), and **automatic linking** (§6.1).
- **Canvas-as-a-file** — no user-facing `.canvas` documents to name and file; one canvas per project (§2).
- **Nested regions.** Possible later; not needed for the bridge, and Milanote's board-in-board model is a different product shape.
- **Real-time collaboration on the canvas.** The collaborator layer is its own bet.

---

## 10. Open questions for the plan

- ~~**The promotion gesture.** Drag onto an artifact rail, a context action, or a keystroke. Deliberately unresolved — it wants trying in the app rather than deciding on paper.~~ **RESOLVED 2026-07-28 (1C-c2): a menu command on the current selection, ⌘⇧↩, plus a `Promote…` button in each arm of the canvas inspector, all posting one command.** See §6.1's amendment and ADR 0026. The artifact rail lost because the canvas has no rail and adding persistent chrome to hold one is a bigger change than the verb it would serve.
- **Where the scraps file lives** — project root or `research/` — and whether it is one file or one per region.
- **Performance bounds.** What node count must stay smooth. §7A.1 settles *how* it virtualises (viewport intersection in the draw loop); the open part is the number. `TypingLatencyProbeTests` is the precedent for a fixture-gated probe rather than a wall-clock assertion. For reference, tldraw ships a hard 4,000-shape cap and freezes zoom level above 500 shapes; Excalidraw degrades around 5,000.
- **Collapsing a region to a tile** — needed for crowding at Playlist scale, but is it v1?
- **Whether the canvas replaces the Corkboard's freeform mode** if one is ever added, or stays deliberately separate (§2).
- **What the binder shows when Canvas is the selected segment.** Adding `case canvas` to `BinderSegment` breaks two exhaustive left-column routers (`BinderPaneToggle`, `CollectionBinderPaneToggle`), and this design only ever describes the canvas as the *centre* column. Provisional answer: the research tree, matching umbrella §6.3's "Plan Left = Research tree" — which §8A.1 now depends on, since dragging research in requires it to be there.
- **The shape of the MCP canvas write surface** (§8A.2) — one tool or several, and how a region is addressed when Claude groups a photo with what it read.
- **Accessibility.** §7A.6 states we own the AX tree and calls it not optional in a writing tool. No plan currently carries it. Either it becomes a task or that claim is softened — it must not lapse silently.
- **Undo.** Canvas edits are sidecar state, not op-log ops. Whether ⌘Z spans them, and if so how, given ADR 0023's op-log-backed model.
