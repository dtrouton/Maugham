# Issue #44 — a canvas this build refuses opens read-only (research)

Researched 2026-10-18 on `fix/canvas-refused-sidecar-44` (off main `baf82aaa`). Read-only investigation; nothing built or run. Line numbers are as of that commit.

## Ruling

Denver, 2026-10-18 (last comment on #44): **read-only + banner.** When this build opens a canvas whose sidecar `CanvasStore` refuses (`SidecarState.refused` — newer schema or damaged bytes), the canvas draws, but **nobody can change it** — not the writer, not Claude's `add_canvas_scraps` (attached route), not an Inbox drag/send (`CanvasCapture.send` live route). A line says *"This canvas was saved by a newer version of Maugham — update to edit it."* **Nothing writes over the refused file.**

This supersedes #33's Global Constraint 6 ("the live-model arms are unchanged") and the AREA.md position that "the writer's own next edit flushes over it (arguably their own act)".

## What `.refused` covers

`CanvasStore.load()` (`Maugham/Canvas/CanvasStore.swift:117-135`) returns `.refused` from ONE guard (`:127-133`) for two different facts:

| case | how it arises | what the writer can do today |
|---|---|---|
| **newer schema** | `dto.schemaVersion > CanvasSceneDTO.currentSchemaVersion` (9) | update Maugham — the ruling's sentence is right |
| **damaged** | `JSONDecoder().decode(CanvasSceneDTO.self…)` throws: not JSON, truncated, a hand edit, a required field missing | **nothing in the app.** There is no backup, restore, quarantine or repair path for `canvas.json` anywhere (grepped `Maugham/` for `canvas.json`/`sidecarRelativePath`: only the store, codec, docs). Outside the app: restore the file from Time Machine/iCloud versions, or delete `.maugham/canvas.json` by hand (AREA.md calls it "derived and deletable" — the words survive, the arrangement is lost) |

**The ruling's sentence is false for the damaged case**: updating Maugham does not help, and the canvas would stay locked forever with no in-app way out. Proposed second sentence (see Open questions for the product choice):

> *"This canvas's layout file is damaged, so Maugham won't change it. Your words are all here."* (+ optionally a **Start a Fresh Layout** button — see Q1)

**Telling them apart** needs a change inside `load()`: probe `{"schemaVersion": Int}` first; `> current` ⇒ newer (whatever the rest of the file looks like — a newer build may also have changed shapes this build can't decode); probe fails, or version ≤ current and the full decode throws ⇒ damaged. Carry it as `SidecarState.refused(Reason)` (or a `Loaded.refusal: SidecarRefused?` with a `reason`), and give `SidecarRefused` a `reason` so every surface (banner, inbox alert, MCP payload) says the right sentence from one value. Today's `SidecarRefused.errorDescription` (`:143-145`) says "newer version … or is damaged" in one breath.

**What "draws normally" actually draws** — worth knowing for the banner wording. A refused sidecar loads as an EMPTY scene with the scraps intact; `CanvasModel.attach` then runs `surfaceOrphanScraps` (`CanvasModel.swift:328`, `:424-448`), so the writer sees **every scrap as a loose card in a row** — words yes, but none of the regions, lines, positions, item/picture cards, marks or bindings the file holds. The canvas does not show the writer's layout; it shows their words. (Q2.)

**Adjacent hazard, out of scope:** a sidecar that exists but cannot be READ (`Data(contentsOf:)` throws — an iCloud-evicted placeholder, a permissions error) takes the `guard let data` at `:124` and is reported **`.absent`** ("nothing to lose"), so the F9 repair and every edit write over it. Worth a follow-up issue; not this branch.

## Write paths

Everything that writes either file goes through `CanvasStore.writeNow` (`:200-207`: `canvas.md` first, then `canvas.json`) or `saveSceneOnly` (`:196`). **Both files are at risk, not just the sidecar**: `writeNow` re-renders `canvas.md` from the in-memory `scraps` (`ScrapText.render`) — a newer build's `canvas.md` may hold syntax this build's `ScrapText.parse` dropped, and `scraps` after attach-over-refused is whatever this build understood. Scrap TEXT lives in `canvas.md`, so read-only must block text edits too (the ruling says "cannot be changed", so yes).

### Live model (`CanvasModel`) — all funnel to `scheduleSave`/`flush`

`CanvasModel.scheduleSave()` (`CanvasModel.swift:529`) → `store?.scheduleSave` and `flush()` (`:531`) are unconditional. `attach` (`:318-380`) reads `loaded.sidecar` once (`:379`) and keeps nothing. Callers:

| path | file:line | what it writes |
|---|---|---|
| **single click** (selection only!) | `CanvasView.swift:1447-1467` — `model.scheduleSave()` at `:1466` | **an unchanged scene — i.e. the orphan row — over the refused file, 750 ms after one click.** Today's AREA claim "replaced only by an edit the writer actually makes" is already false: a click is enough |
| double click: enter scrap / create scrap | `CanvasView.swift:1470-1571` (`beginGesture("Edit Scrap")` `:1495`, create `:1502-1551`, save `:1571`) | scene + `canvas.md` |
| typing into a mounted scrap (tripwire 28) | `ScrapEditorHost` `onTextChanged` → `syncActiveEdit` `CanvasView.swift:1321-1349` → `setScrapText` `:1340` | `canvas.md` + sidecar |
| fold at teardown/quit | `.onDisappear` `:707-722` → `syncActiveEdit()` + `model.detach()` (`flush`, `CanvasModel.swift:483`); `beforeFlush` wired at `CanvasView.swift:839`; `CanvasStore` quit observer `CanvasStore.swift:46-51` | whatever is queued |
| drag: move/resize card, move/resize region, sweep region, draw line | `handleDrag` `CanvasView.swift:1984`; gesture opens at `.began` `:2034-2036`; per-frame `withScene(persist:false)` `:2041/:2081/:2095/:2192`; save at end `:2310` | sidecar |
| momentum coast | `CanvasView.swift:450-466` (`scheduleSave` `:459`) — only after a drag | sidecar |
| ⌫ / ⌦ delete card/region/line | `deleteSelection` `CanvasView.swift:1769-1825` | both |
| research row dropped | `handleDrop` `:1617` → `CanvasDrop.apply` (`CanvasDrop.swift:212-213`, `mutateFromInspector`) | sidecar |
| Inbox row dragged on | `handleCaptureDrop` `:1679` → `captureDrop.send` → `InboxStore.sendToCanvas` → `CanvasCapture.send` live arm | both |
| Finder/browser picture dropped | `handleExternalDrop` `:1712` → `CanvasExternalDrop.ingest` (**copies into `canvas_assets/` FIRST**, `CanvasDrop.swift:376-410`) → `CanvasExternalDrop.apply` (`:446-451`, `mutateFromInspector`) | sidecar (+ an asset copy) |
| region inspector: rename, collapse, bind piece, cite, remove from region, delete | `RegionInspector.swift:712/720/728/760/770/783` | sidecar |
| line inspector: label, delete | `LineInspector.swift:166/186` | sidecar |
| scrap inspector: piece picker | `ScrapInspector.swift:373` | sidecar |
| promotion mark / contribution records / picture record | `PromotionPerformer.swift:1104/1109/864` (`mark`, `recordPicture`); reached from `Promote…` (`ProjectWindow.swift:5377` `isPromotable`, `begin` `~:5462`) and the inspector Promote buttons (`RegionInspector:297`, `LineInspector:84`, `ScrapInspector:193`, `ItemInspector:132`) | sidecar — **and the artifact (note/card) is created before the mark** |
| Claude, attached route | `CanvasClaudeWrite.apply` live arm `CanvasClaudeWrite.swift:88-120` (`mutateFromInspector` `:107`, `flush` `:119`) | both, immediately |
| Inbox Send to Canvas, live route | `CanvasCapture.send` live arm `CanvasCapture.swift:242-254` (`flush` `:252`); `refuseUnlessWritable` `:277-280` returns early for any live model | both, immediately |
| undo/redo apply | `CanvasModel.swift:334-359` (`scheduleSave` `:358`) | both — moot if nothing was ever registered |
| load-time repair | `CanvasModel.swift:379` — **already withheld** on `.refused` (#28) | — |

`withScene(persist: false)` is also used for pure re-measures that must keep working on a read-only canvas (`remeasure` `CanvasView.swift:1263-1281`, `onSceneChangedExternally`, thumbnail rebuilds) — in memory only.

### No live model (already refused by #33)

`CanvasClaudeWrite.apply` sidecar arm (`CanvasClaudeWrite.swift:122-141`), `CanvasCapture.send` sidecar arm (`CanvasCapture.swift:257-270`), `CanvasCapture.refuseUnlessWritable` (`:277-280`), `ProjectStore.repointCanvasMarks` (`ProjectStore+StatementAdoption.swift:299`, silent return) — all through `CanvasStore.loadForTransientWrite()` (`CanvasStore.swift:150-156`). Unchanged by #44.

## Gate design

Three layers, one fact. The fact is computed once at `attach` and held by the model; nothing re-spells `!= .refused` (#33 GC1).

1. **The fact — `CanvasModel.sidecarRefusal: CanvasStore.SidecarRefused?`** (observable, NOT `@ObservationIgnored`, so the banner and inspectors redraw), set in `attach` from the load, plus `var isReadOnly: Bool { sidecarRefusal != nil }`. Holding the *error value* rather than a Bool means the live route throws exactly the error the sidecar route throws — the MCP payload and the inbox alert are identical by construction. Add a third named reader on `SidecarState` (e.g. `acceptsAnEdit`) over the same private `isWritable`, or move the decision into `CanvasStore.Loaded` (`var refusal: SidecarRefused?`) and have `loadForTransientWrite` use it too — one home for both routes. Re-evaluated on every `attach`; `detach` leaves it (the next attach overwrites).

2. **The backstop — nothing writes.** Make the store itself refuse: `CanvasStore` remembers that its `load()` answered `.refused`, and `scheduleSave`/`save`/`flush`/`saveSceneOnly` return without writing (`hasPendingWrite` stays false). This is the one object every write passes through, live or transient, so "nothing writes over the refused file" becomes a property of the writer rather than of call-site discipline — the single click at `CanvasView.swift:1466` and the undo apply's `scheduleSave` are covered without touching them. (Alternative: guard `CanvasModel.scheduleSave`/`flush`. Weaker — a transient caller that `load()`s and `save()`s by mistake bypasses it.) Also guard the two named verbs `mutate`/`mutateFromInspector` and `setScrapText`/`removeScrapText` to return without mutating when read-only, so an in-memory change can never appear on screen and silently fail to persist. Leave `withScene(persist:false)` alone — it carries the re-measures.

3. **The doors — refuse loudly, before any copy.**
   - Outside callers ask ONE helper beside `CanvasClaudeWrite.liveModel(of:)` (so `CanvasLiveSeamTests.test_theLiveCanvasDiscriminatorIsSpelledOnce` keeps one spelling): e.g. `CanvasClaudeWrite.refusal(of store:, projectRoot:) -> SidecarRefused?` = live model's `sidecarRefusal` if attached, else `loadForTransientWrite`'s. `CanvasClaudeWrite.apply` live arm, `CanvasCapture.send` live arm and `CanvasCapture.refuseUnlessWritable` all `throw` it **before** `mutateFromInspector`. `refuseUnlessWritable` stops returning early for a live model.
   - The view refuses at entry (the surface), mirroring P3c's "hidden on its surface and refused at its door" and the editor membrane (`EditorControlMirror.membrane` → `lockEditing`; editor stays selectable): in `CanvasView` read `model.isReadOnly` and
     - `handleClick` with `clickCount >= 2` behaves like a single click (no create, no enter, no editor mount — the drawn text stays legible; mounting a non-editable `NSTextView` for copy is possible via `ScrapLayout.swift:112` but adds undo-forwarding surface for little gain);
     - single click still selects (the inspector then shows the subject read-only); its `scheduleSave` is harmless behind layer 2;
     - `handleDrag(.began)` does not call `interaction.begin`/`beginGesture`, so `.changed`/`.ended` bail on `interaction.isActive` (every `CanvasInteraction.Kind` mutates; pan/zoom are scroll/magnify and keep working);
     - `deleteSelection` returns `false` (the beep — "that key means nothing here", AREA §Delete);
     - `handleDrop`: `.reveal` may still select+pan (no mutation), a `.place`/capture payload returns `false`; `handleExternalDrop` returns `false` **before** `CanvasExternalDrop.ingest`, or a refused drop strands copies in `canvas_assets/` (the same ordering lesson as #33's `refuseUnlessWritable`).
   - Inspectors (`RegionInspector`, `LineInspector`, `ScrapInspector`): fields that show a value (name `TextField`, Collapsed `Toggle`, Piece `Picker`) `.disabled(model.isReadOnly)`; verb buttons (Delete, Cite, Remove from Region, Promote…) hidden. `ItemInspector`'s Promote… hidden; *Open in Research* stays.
   - `Promote…`: add the fact to `CanvasPromotionModifier.isPromotable` (`ProjectWindow.swift:5377`) so the File item greys and ⌘⇧↩ is dropped, and `PromotionPerformer` checks before creating the artifact — otherwise a note/card is made and its mark is then refused. (Q3: allow promoting OUT of a read-only canvas?)
   - Do NOT route this through `Posture` — that is the permit's (tripwire 51 forbids building one elsewhere). The precedent is `ProjectWindow.shareIsReadOnly`: an OS/file lock *beside* the posture, feeding a membrane and a notice, never a role.

Tripwire notes for the plan: 32's census (`TripwireGrepTests.swift:4452`) is unaffected as long as no new `mutate`/inside verb appears in the outside files — reading `model.isReadOnly`/`sidecarRefusal` is fine. `CanvasView.swift` has five source-layout contracts in its header (AREA "Writing tests") — read it before editing. `CanvasCompositionTests` counts hit-testing opt-outs in `CanvasView`'s ZStack, which is one reason to mount the banner outside it.

## MCP and Inbox

- **`add_canvas_scraps`**: with the live arm throwing `SidecarRefused`, the existing catch in `AddCanvasScrapsTool.handle` (`CanvasTools.swift:517-536`) produces `canvas_sidecar_unreadable` on BOTH routes with no new code path. Fix the hint (`:532-534`): it says `list_canvas` reported an "empty scene", which is false on the live route (it reports the orphan row from the open model). Suggested: *"Update Maugham on this Mac before adding to this canvas. The canvas list_canvas reported is only what this version can read — not the writer's real layout."* With a `reason`, the message is the reason's sentence. Also move the marker comment at `:501-503` ("on the sidecar route" → both routes).
- **`list_canvas`** (`CanvasTools.swift:201-204`): today Claude cannot tell an unreadable canvas from an empty one until a write fails. Recommend widening the read with a field (e.g. `"layout_readable": false` + the reason) on both routes — `readScene` returns the model's `sidecarRefusal` or the load's state. A widening of an existing read; catalogue count unchanged.
- **Inbox Send to Canvas** (`InboxPane.swift:620-635`): unchanged UI — `refuseUnlessWritable` now throws for a live read-only model too, before the copy and the flip, and the existing *"Couldn't promote"* alert shows `SidecarRefused.errorDescription`. Update its text with the reason split. The row stays in the Inbox (`.new`).
- **Inbox drag onto the canvas**: declined at `handleDrop` (returns `false`, the drag springs back) with the banner already on screen saying why. (If declining feels too quiet, `handleCaptureDrop` already has a `dropError` alert, `CanvasView.swift:589-593`, that could show the same sentence — a choice for the plan, not a product question.)

**TOCTOU from the issue** (`refuseUnlessWritable` sees a live model → `sendToCanvas` suspends in `ingestCanvasAsset` (`InboxStore.swift:904`) → Plan closes → `send` takes the sidecar route and refuses after the copy). With the refusal held by the model, a live model over a refused sidecar refuses at the FIRST statement (`InboxStore.swift:861`), before the copy. The remaining window needs the model to have been WRITABLE at the check — meaning the file decoded or was absent at attach — and `detach` then flushes a current-schema file, so the sidecar route's `loadForTransientWrite` succeeds. It can only still refuse if something outside this process replaces `canvas.json` with a newer/damaged one inside that one suspension; the cost is one stranded asset copy, not lost work. The model-held state closes it in practice; keep the sidecar route's re-check as the backstop. Record the residue in a comment, don't build for it.

## Banner

- **Where**: the canvas's top edge, mounted in `ProjectWindow.canvasCentre` (`ProjectWindow.swift:2430-…`, "the one place the canvas is mounted") as `.safeAreaInset(edge: .top)`, the same mechanism as `ViewOnlyShareNotice` (`ProjectWindow.swift:1501-1508`) and `PostureStandingLineView` (`:1485-1499`). Outside `CanvasView`'s ZStack, so `CanvasCompositionTests`' layer/hit-testing censuses and the frontmost-editor rule (tripwire 27) are untouched, and it does not fight `CanvasPromotionModifier`'s transient `.overlay(alignment: .top)` `MCPNoteBanner`. Not `CanvasBindingOfferView` (`CanvasBindingOffer.swift:106`) — that is centred, secondary-styled chrome for the dim, beneath the event view.
- **Look**: `ViewOnlyShareNotice`'s (lock glyph, cool slate, non-dismissable, `static let sentence` so tests ask production for the words, an explicit `accessibilityLabel`, and NO `fixedSize(horizontal:false, vertical:true)` — its comment records why). Either parametrise that view into a shared lock notice or write a sibling `CanvasReadOnlyNotice` with the same style; two sentences keyed on the reason.
- **⌘\ (no chrome)**: recommend the notice stays visible — it is a safety fact, like the view-only share notice, which is not chrome-gated. Plain `CanvasView` hides nothing for it.
- **VoiceOver**: the canvas's own label (`CanvasAccessibility.canvasLabel`, `CanvasView.swift:434`) could append "read-only" — optional.

## Tests

All windowless except one drawn-check; tripwire 33 bans synthesised clicks and press-then-wait outside the named lists.

Seeding a refused sidecar: copy the existing helpers — `CanvasModelTests.seedUnreadableSidecar` (`MaughamTests/Canvas/CanvasModelTests.swift:366-372`: newer = `{"schemaVersion":999,"nodes":[{"id":"futr","kind":"scrap","x":10,"y":10,"width":240,"z":3}]}`; damaged = `not json at all`; plus a `canvas.md` with `ScrapText.banner` + `## ghst`), `CanvasClaudeWriteTests.seedUnreadableSidecar` (`:426`, with `sidecarFromANewerBuild`), `InboxToCanvasTests.seedUnreadableSidecar` (`:819`). Ids are 4-char from `[0-9a-hjkmnp-tv-z]` (tripwire 8). Every refusal asserts `Data(contentsOf:)` of BOTH files byte-identical (#33 GC4) and has a control against `.absent`/`.decoded` that still writes (GC5).

1. **`CanvasStoreTests`** — the reason split: `999` ⇒ newer, `not json at all` ⇒ damaged, a truncated current-schema file ⇒ damaged, a `999` file whose body is also undecodable ⇒ still newer; the store that loaded `.refused` writes nothing on `scheduleSave`+`flush`, `save`, `saveSceneOnly` (bytes unchanged, `hasPendingWrite == false`); control: absent/decoded store still writes.
2. **`CanvasModelTests`** — attach over each refused case ⇒ `isReadOnly`, `sidecarRefusal?.reason`; then `mutate`, `mutateFromInspector(scrapTexts:)`, `setScrapText`, `scheduleSave`, `detach` ⇒ scene/scraps unchanged in memory AND both files byte-identical. Control: attach over absent/decoded ⇒ not read-only, same calls write.
3. **`CanvasClaudeWriteTests`** — new: live model attached over a refused sidecar, `store.liveCanvas = model` (fixture `:45-70`), `apply` throws `SidecarRefused` with the right reason; model scene unchanged; files byte-identical. Existing `test_aClosedCanvasWithAnUnreadableSidecarRefusesTheWrite` (`:485`) / `test_aDamagedSidecarRefusesTheWriteToo` (`:495`) stay; existing live-route tests are the control.
4. **`CanvasToolsTests`** — mirror `test_addCanvasScrapsRefusesAnUnreadableSidecarWithANamedError` (`:1206`) on the live route: same `canvas_sidecar_unreadable`, same `project` field, no `maughamCanvasNodesAdded`. If `list_canvas` is widened, assert the field on both routes.
5. **`InboxToCanvasTests`** — live model over refused: text capture throws, status still `.new`; image capture throws **before the copy** (`canvas_assets/` absent/empty, original still in the inbox) — the live twin of `:881-935`.
6. **Pure view decisions**: `CanvasView`'s handlers are `private` and drops have no test seam (AREA: "SwiftUI's drop delivery has no seam a test can post into"). Extract the read-only answers as statics a test can drive — e.g. `CanvasPromotionModifier.isPromotable(…, isReadOnly:)` (driven by `PromotionCommandTests`' table), a `CanvasDrop.decide`-level read-only refusal, and a tiny `CanvasReadOnly.allows(_ act:)` the view consults — and pin them over every case. The model/store backstop guarantees no write even where a view path is missed.
7. **Drawn**: one mounted check that the notice is drawn over a refused canvas and absent over a decoded one (tripwire 33's "assert only that the control is drawn") — or skip the mount and test the notice's `static` sentence + the decision predicate.

## Docs

Sweep in the same commits (CLAUDE.md rule 10):

- `Maugham/Canvas/AREA.md:692` (Persistence) — rewrite the bold #44 exclusion sentence and "The file is replaced only by an edit the writer actually makes from this build" (already false: a single click writes). New position: a refused canvas opens read-only, the store refuses every write, and the three outside routes refuse with one `SidecarRefused`.
- `Maugham/Canvas/AREA.md:850` (MCP refusals) — `canvas_sidecar_unreadable` is no longer "on the sidecar route only"; drop "the live-model arm cannot refuse … #44's territory".
- `Maugham/Canvas/AREA.md` "The mounted editor"/"Delete"/"Undo" — one line each where read-only changes behaviour (no editor mounts; ⌫ beeps).
- Code comments that become false: `CanvasModel.swift:365-378` (attach), `CanvasClaudeWrite.swift:76-84` ("The live-model arm cannot refuse") and the table at `:24`, `CanvasCapture.swift:232-235` and `:273-276` (`refuseUnlessWritable`: "With a canvas open there is nothing to ask"), `InboxPane.swift:612-619`, `CanvasTools.swift:501-503` and the hint, `CanvasStore.swift:96-105`/`:137-146`.
- `Maugham/Stores/AREA.md` Inbox → canvas seam (~`:366`) — the refusal now applies with the canvas open too.
- `Maugham/MCP/AREA.md:90` (`add_canvas_scraps`) — refusal on both routes; `list_canvas` field if added (`:89`).
- `docs/guide/getting-started.md:154` — the *Failing-loudly* sentence quotes the old one-breath message; update the quote and add that the canvas itself opens read-only with a line saying why. Add a short *Failing-loudly* line under **The planning canvas** (`:30`). `docs/guide/claude-desktop.md`'s canvas section if it describes `add_canvas_scraps` refusals (it did not mention them at time of reading).
- `docs/roadmap.md` / register: grep for #33/#44 lines at close.

## Open questions

**For Denver (product):**

- **Q1 — damaged file, not a newer one.** Updating won't help a damaged layout file, so a locked canvas would stay locked forever. Should Maugham (a) stay locked and say *"This canvas's layout file is damaged, so Maugham won't change it. Your words are all here."* — leaving the fix to restoring a backup by hand — or (b) also offer a **Start a Fresh Layout** button that keeps the damaged file aside (not deleted) and lets you arrange your words again from the loose row? Recommendation: (b), with the damaged file moved under `.maugham/` rather than deleted.
- **Q2 — what the locked canvas shows.** An older Maugham can't read a newer canvas's arrangement, so it shows your words as a row of loose cards — no regions, lines, pictures or positions. Should the line say so? Suggested: *"This canvas was saved by a newer version of Maugham, so this version shows only its words — update to see and edit your layout."*
- **Q3 — promoting out of a locked canvas.** Turning a card into a research note doesn't change the canvas's layout file except for the little "promoted" mark it leaves. Should Promote… be off on a locked canvas (simplest, and what "cannot be changed" says), or allowed without leaving the mark (useful for rescuing words from a damaged canvas)? Recommendation: off.

**For the plan (engineering):** store-level vs model-level backstop (recommend store); whether `list_canvas` gains the readable field (recommend yes); decline-vs-alert for an Inbox drag onto a locked canvas (recommend decline; banner explains); the `.absent`-on-read-error hazard above as a separate issue; a newer build rewriting `canvas.json` on another Mac while this one has the canvas open is not detected (no file watcher) — out of scope, worth recording.
