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

### 3.2 Scraps — things that exist only here

A loose thought typed straight onto the canvas is a **scrap**. Scraps are canvas-local: they do not appear in the research tree, cost no filename, and require no decision about what they are.

**Scraps are still plain text on disk.** They live as entries in a single human-readable file (`canvas.md` at project root, or under `research/` — the plan decides), so a writer can read them in any editor forever and Maugham's plain-text guarantee is not weakened by a sidecar-only content store. Positions live in the sidecar; the words do not.

This is the one place the design admits a new content location, and it is justified: making every scribble a research `.md` means creating files in order to have a thought, which is the opposite of scratch.

---

## 4. Regions

A **region** is a labelled area you draw on the canvas. Regions are the canvas's only grouping primitive.

### 4.1 Regions own their contents, for movement

Drag a region and its members travel. This is what makes reorganising one gesture rather than a marquee-select.

### 4.2 Membership is explicit, and geometry never changes it

Membership changes **only** by deliberate act: dropping a node onto a region adds it; an explicit remove takes it out. Coordinates never add or remove a member.

**This eliminates a bug class every surveyed tool has.** Obsidian leaves behind a card poking one pixel outside a group. tldraw ejects children when a frame is resized — *despite* storing membership explicitly ([issue #6017](https://github.com/tldraw/tldraw/issues/6017)) — because the geometry→membership transition rule is the hazard, independent of storage. Scapple recomputes from live geometry and has an unfixed bug where a note shared by two overlapping shapes moves with whichever shape you happen to grab.

The cost is that a node can sit visually outside the region that owns it. That is a rendering problem (draw the relationship), not a correctness one, and it is the better trade.

### 4.3 Membership is not exclusive — one home, many appearances

Planning is associative: the street photo belongs to *Good Luck Babe* and to the book's visual language; October's swatch is in the palette cluster and the falls cluster. A strict ownership tree would force duplication or a premature choice.

So a node **lives in** exactly one region (or nowhere, loose on the canvas) and can **also appear in** any number of others.

- *Lives here* is the tiebreak that makes §4.1 work: **only a node's home region moves it.** Drag the region a node lives in and it travels; drag a region it merely appears in and it stays put. A visitor is not luggage — being cited by a cluster should not let that cluster drag you around the canvas.
- *Also appears in* is a reference, not a copy. **Copies are rejected outright**: Maugham is single-source-plus-derivation everywhere (op log → `.md`, palette card model → markdown, one docs source → three surfaces), and two editable copies of one note is precisely the failure the architecture exists to prevent.

**An appearance must not render identically to the thing itself** — otherwise the copy problem returns visually and you cannot tell which is real. An appearance reads as a reference: smaller, or a chip carrying the title with a hairline to its home. Any region should answer "which of these live here and which are visiting" at a glance.

### 4.4 Regions bind to pieces — this is the bridge

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
| A region | a palette card, or a piece binding |
| A line | a `[[wiki-link]]`, when both ends are text |

### 6.1 Rules

- **Explicit and user-initiated.** Nothing promotes because it sat somewhere long enough or looked like something.
- **Previewable.** The writer sees what will be produced, and where, before committing — Scrivener's Commit is the model: a named command with a stated rule and a predictable outcome.
- **Allowed to be lossy, and that is a feature.** Promoting a region need not preserve its lines or its layout. The spatial work was thinking; it earned its keep by producing the artifact. Scapple → Scrivener keeps nodes and drops connections, deliberately.
- **May suggest, must never impose.** Promoting a region may *offer* to link its text members to the artifact it produced — "these six scraps are in 'Act II fog' — promote as a note, link them, or just keep the label?" That sits squarely inside Shipman & Marshall's licence **because the writer sees the inference and can decline it**. The same inference applied silently is forbidden: membership is n-ary and vague, wiki-links are binary and specific, and the silent conversion manufactures precision the writer never claimed — into a layer with backlinks and rename propagation, where it is expensive to undo.
- **Promotion is never required.** The canvas must be completely usable by a writer who never promotes anything. Readiness counts promoted artifacts and stays silent about the canvas (umbrella §7, §9).

---

## 7. How it feels

The editor is deliberately austere to protect flow. Planning is associative and messy, so the canvas can afford to feel like somewhere else — and the persona bar has already told the writer they *are* somewhere else.

### 7.1 The ground

- **Light:** a muted canvas weave. **Dark:** slate under a lamp — a different material, not the same texture inverted. Paper is a light-mode idea.
- **Washed 3–5% by the project's own sensory palette swatches.** Playlist's canvas looks like Playlist; a hospital novel's does not. This is the through-line made visible on the surface where it is assembled, and nothing else on the market can do it, because nothing else holds the palette. **Dosage is the risk**: at 15% a grim palette yields a canvas you cannot work on. The wash is felt, not seen.
- Light falls from one corner. Light ages better than texture.

### 7.2 The cards

Crisp edges. Each card sits at a **seeded fraction of a degree** — nothing is rough, but everything was *put down* rather than snapped to a grid.

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

### 7A.5 Cards

§7.2's seeded sub-degree rotation becomes a transform in the draw call rather than a view modifier — cheaper still, and the stability requirement is unchanged: seeded from the node id, never random per frame.

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
- **Items** → untouched. The canvas never writes to a research note, a palette card, or an image.

Membership is **stored**, never recomputed from coordinates at read time (§4.2).

---

## 8A. Getting things onto the canvas

*Added 2026-07-25 after the plan review. Three routes, in descending order of how often a writer will use them.*

### 8A.1 Drag in from research

The binder is beside the canvas in the Plan persona, and its research tree is the natural source. **Dropping a research item onto the canvas creates an item node** (§3.1) — the file is untouched, the canvas holds only its position.

- **Internal drags** carry the item id and follow the app's established `.draggable(id)` / `.dropDestination(for: String.self)` pattern.
- **External drags** — a photo from Finder or a browser — route through `DropClassification`. Browser image drags carry rendered bitmaps rather than file URLs, so `.dropDestination(for: URL.self)` silently rejects them; do not hand-roll this.

**Images are therefore in scope for the first slice, not deferred.** The canvas is the first surface in Maugham with an unbounded image count, and no image cache or real downsampling exists anywhere in the app today — the palette wall's helper decodes at full size then redraws. Image nodes need a `CGImageSource` thumbnail path and a bounded cache **keyed by path, not id** (tripwire 22).

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

## 9. Out of scope

- **Phone.** The canvas is Mac-only. `Packages/MaughamCore` and `MaughamPhone` are untouched, exactly as 1B was. (Note §8A.2's photo route *starts* on the phone via the existing Capture inbox — no new phone code.)
- **Typed edges** (§5), and **automatic linking** (§6.1).
- **Canvas-as-a-file** — no user-facing `.canvas` documents to name and file; one canvas per project (§2).
- **Nested regions.** Possible later; not needed for the bridge, and Milanote's board-in-board model is a different product shape.
- **Real-time collaboration on the canvas.** The collaborator layer is its own bet.

---

## 10. Open questions for the plan

- **The promotion gesture.** Drag onto an artifact rail, a context action, or a keystroke. Deliberately unresolved — it wants trying in the app rather than deciding on paper.
- **Where the scraps file lives** — project root or `research/` — and whether it is one file or one per region.
- **Performance bounds.** What node count must stay smooth. §7A.1 settles *how* it virtualises (viewport intersection in the draw loop); the open part is the number. `TypingLatencyProbeTests` is the precedent for a fixture-gated probe rather than a wall-clock assertion. For reference, tldraw ships a hard 4,000-shape cap and freezes zoom level above 500 shapes; Excalidraw degrades around 5,000.
- **Collapsing a region to a tile** — needed for crowding at Playlist scale, but is it v1?
- **Whether the canvas replaces the Corkboard's freeform mode** if one is ever added, or stays deliberately separate (§2).
- **What the binder shows when Canvas is the selected segment.** Adding `case canvas` to `BinderSegment` breaks two exhaustive left-column routers (`BinderPaneToggle`, `CollectionBinderPaneToggle`), and this design only ever describes the canvas as the *centre* column. Provisional answer: the research tree, matching umbrella §6.3's "Plan Left = Research tree" — which §8A.1 now depends on, since dragging research in requires it to be there.
- **The shape of the MCP canvas write surface** (§8A.2) — one tool or several, and how a region is addressed when Claude groups a photo with what it read.
- **Accessibility.** §7A.6 states we own the AX tree and calls it not optional in a writing tool. No plan currently carries it. Either it becomes a task or that claim is softened — it must not lapse silently.
- **Undo.** Canvas edits are sidecar state, not op-log ops. Whether ⌘Z spans them, and if so how, given ADR 0023's op-log-backed model.
