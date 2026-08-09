# Maintainability Review — 2026-08-09 (monthly full audit)

Full fresh-eyes audit per `.claude/skills/maintenance-audit/SKILL.md` (monthly mode: the newest full-audit note was `2026-07-11`, 29 days ago — >4 weeks). Method: mechanical git pre-pass → 7 parallel read-only map+find agents (architecture, tests, docs, security, canvas bug-hunt + 2 end-to-end tracers: scrap-lifecycle, promotion-lifecycle) → coordinator synthesis over territory maps → source-verification of the one High. Maps preserved in the session scratchpad (`maps/*.md`).

**Cloud run:** read-only source analysis only. No `xcodebuild`, simulator, or smoke test was possible (nor needed for this audit). **The 58 memory files + `MEMORY.md` live under `~/.claude/…` and are NOT in the cloud checkout — the memory→tripwire promotion dimension (A4) was reduced to the 32 in-repo `CLAUDE.md` tripwires only; the memory-corpus half is unaudited this pass.**

**Headline:** the month's growth is enormous and overwhelmingly one subsystem — **Canvas** (the Plan-persona centre column, ADR 0026), plus the **persona shell** (ADR 0025) and **translation layer** (ADR 0024). Source went **406→500 files, 60k→92k LOC (+53%)** in four weeks. Despite being the least-soaked code in the repo, the Canvas subsystem is **exceptionally well-defended**: every canvas tripwire (26–32) is honored in code, the undo-bracket and membership censuses match their prose exactly, and three independent agents (architecture, bug-hunt, scrap-tracer) each concluded the correctness discipline holds. The real risk concentrates in **one place: the integration of *craft intent* (a `Statement`, not a research item) into the canvas's promotion machinery** — it produced the audit's single **High** (a preview/commit disagreement that fails a legitimate action with a false error) and two related Lows. Beyond that: one genuine **enforcement gap** (tripwire 25 has no recurrence guard), the expected **context-window economics** on three new monoliths, and a small **doc-sweep miss** (a resolved item still marked open in the roadmap).

---

## 1. Trend metrics (longitudinal)

| Metric | 2026-07-11 (full) | 2026-07-19 (sweep) | **2026-08-09 (full)** |
|---|---|---|---|
| Source Swift files / LOC | 406 / 60,374 | 422 / 62,673 | **500 / 92,530** |
| Test Swift files / LOC | 448 / 56,273 | 475 / 62,582 | **615 / 121,618** |
| Source files >800 LOC | 11 | 10 | **16** |
| ADRs | 23 | 23 | **26** (0024 translation, 0025 persona-shell, 0026 canvas) |
| CLAUDE.md tripwires | 21 | 24 | **32** (25–32 mostly canvas) |
| MCP tools (`MCPToolCatalog.all`) | 47 | 48 | **55** (+ translation ×3, canvas list/add ×2, …; DocSync-enforced, docs match) |
| Commits since last full audit | — | — | **50** |

Method (repeatable baseline): `find Maugham MaughamPhone Packages/MaughamCore/Sources -name '*.swift'` for source; `MaughamTests MaughamPhoneTests Packages/MaughamCore/Tests` for tests. Memory dir not countable in cloud.

**Hotspots (churn×LOC since 2026-07-11, top 8):** `ProjectWindow.swift` (11 commits, 2890 LOC), `CanvasView.swift` (10, 2217), `CanvasRenderer.swift` (3, 1668), `CanvasInteraction.swift` (5, 887), `Persona.swift` (7, 533), `CanvasModel.swift` (4, 480), `CanvasUndo.swift` (4, 421), `StatementEditorHost.swift` (2, 1031). **EditorCoordinator's last-audit split held** (2293→1101 core + 5 extensions).

**New source files >800 LOC:** ProjectWindow 2890, CanvasView 2217, CanvasRenderer 1668, Promotion 1439, ProjectStore+CollectionPieces 1064, StatementEditorHost 1031, PromotionPerformer 942, CanvasInteraction 887, ProjectStore+Structure 830.

**Temporal coupling:** the only cross-area co-change pair ≥6 in the window is `CanvasView.swift ↔ CanvasViewMountingTests.swift` (7×) — a file and its own mounting suite, not a hidden seam. No suspicious cross-area coupling this window.

---

## 2. Emergent / cross-cutting finding

**Theme (synthesis payoff): *craft-intent-on-canvas* is the least-integrated sub-seam.** Craft intent is a `Statement` (lives in `manifest.statements`), and it was folded into the canvas's *read* machinery — `ArtifactIndex.over` includes `.intent` statements (`Promotion.swift:363-369`) — but the canvas's *write* paths (`performWikiLink`, `writeOfferedLinks`) only know `manifest.research`. Three findings from three independent agents converge on exactly this gap (F1 High, F10 Low, F9 Low). One hardening slice fixes all three. No single area's review saw it; it only appears when the promotion tracer's data-flow collides with the "statements are a separate manifest" invariant.

### F1 [High] A canvas line drawn *from* a craft-intent card enables Promote, then fails at Commit with a false "no longer in the project" error — VERIFIED against source
`resolvedArtifact` (`Promotion.swift:1189-1196`) returns any node whose `promotedItemID` resolves a title in `ArtifactIndex`, and `ArtifactIndex.over` adds `.intent` statements with a `.craftIntent` entry (`:363-369`). So for a line whose `from` card was promoted to **craft intent**, `targets(for:.line)` passes (`:729` — both endpoints resolve), and `plan` builds `WikiLinkWrite(intoNode: line.from, intoItemID: fromItem)` where `fromItem` is the **statement id** (`:1012-1018`). At commit, `performWikiLink` does `TreeWalk.find(id: link.intoItemID, in: store.manifest.research)` (`PromotionPerformer.swift:559`) → statements are not in `manifest.research` → `nil` → throws `PromotionFailure.artifactMissing`, whose alert reads *"The artifact this card produced is no longer in the project"* — which is false; the statement is right there. The link is silently not written. This is exactly the preview/commit-disagreement class the whole file is otherwise architected to prevent (it unifies `regionBodies`, `pieceFailure`, `existingArtifact` precisely to avoid this). Reachable with default UI: craft intent is one of three scrap targets, and any line drawn *from* such a card hits it (drawn *to* it works, because only the title is read there). — fix-shape: restrict `resolvedArtifact` on the `from`/`into` side to artifacts backed by `manifest.research` (statements have no writable `.path`), **or** have `targets`/`blockedReason` refuse a wiki-link whose `from` mark is a `Statement` — effort: M (+ a regression test drawing a line from a craft-intent card).

---

## 3. Per-dimension findings

### 3.1 Enforcement gap (A2)
- **F2 [Medium] Tripwire 25 (`no .scaleEffect` / `no NSScrollView.magnification` for canvas zoom) has zero recurrence guard.** `TripwireGrepTests.swift` never mentions `scaleEffect` or `magnification` (grep-verified); the claimed enforcer `CanvasCameraTests` only checks `CanvasCamera`'s own coordinate math — it says nothing about a *future* SwiftUI subview reintroducing `.scaleEffect`. `CanvasViewMountingSurfaceTests.swift:878` only names it in a comment. This is the **one** canvas tripwire (of 25–32) whose failure is genuinely silent (blurs text, and at ≥2× the mistranslated point falls outside the view so clicks stop registering — CLAUDE.md's own measurement) **and** has no grep-level protection; every other canvas tripwire has a runtime pin or a source-census. — fix-shape: add a `TripwireGrepTests` entry banning `.scaleEffect(` / `.magnification` assignment inside `Maugham/Canvas/`, mirroring the TW13/14/17 pattern + a planted-offender self-check — effort: S.

### 3.2 Doc-truth (A3 + coordinator pre-pass)
- **F3 [Medium] `docs/roadmap.md:11` still marks "MCP tests that measure the machine" as `•` open**, reproducing the 2026-07-29 unresolved-flake language, while `CLAUDE.md:146` documents it **RESOLVED 2026-08-08** (parallel-worker fix + burn-in) and the cited note itself has a `## Resolution (2026-08-08)` section. This is the `•→✓` sibling-doc-sweep miss that CLAUDE.md Default-Workflow rule 10 exists to prevent — applied faithfully to CLAUDE.md and the note, not fanned out to the roadmap (a *different* file, and the one whose own ✓/• legend makes the staleness most visible). Found independently by the coordinator pre-pass and A3. — fix-shape: flip the bullet to `✓` (or fold into the shipped-history section) summarizing the parallel-workers fix — effort: S.
- **F4 [Low] `docs/roadmap.md:55`** (M1C "Left open") says "naming and deleting a line are mouse-only," but `CanvasView.swift:1729-1736` `deleteSelection()` has a live `.line` case reachable via ⌫ once a line is selected. The *selection* route is still mouse-only (`CanvasAccessibility.swift:78-89`: "a line is not an element of its own") — the underlying VoiceOver gap is real, but the phrasing conflates select-only-by-mouse with delete-only-by-mouse. — fix-shape: reword to "…has no route to select (and therefore delete) one" — effort: S.

### 3.3 Architecture & context-window economics (A1)
- **F5 [Medium] `ProjectWindow.swift` 2890 LOC** — the `ProjectWindow` struct alone is ~2000 lines (`:23-2017`) and still contains four *nested* `ViewModifier` structs while four more sit at file scope; the type-checker-dodge extraction is real but half-done. #1 churn hotspot. — fix-shape: move nested modifiers to `ProjectWindow+Chrome.swift`; pull column/routing builders (`binderColumn`/`contentColumn`/`detailColumn`/`inspectorPane`/`existingInspectorSwitch`) into `ProjectWindow+Columns.swift` — effort: L.
- **F6 [Medium] `CanvasRenderer.draw` is a single ~695-line function** (`:973-1668`) with no sub-functions between signature and EOF — the least-navigable file in the area. — fix-shape: split into `drawRegions`/`drawTethers`/`drawNodes`/`drawLines`/`drawChrome` static helpers taking ctx+camera — effort: M.
- **F7 [Medium] `CanvasView.swift` 2217 LOC** is one `struct CanvasView: View` (lifecycle/measure/clicks/drops/drags/delete/edit-sync all in one type); any edit loads all 2217 lines. Partially mitigated by MARKs. — fix-shape: move `handleClick`/`handleDrop`/`handleDrag`/`deleteSelection` clusters into `CanvasView+Input.swift` same-module extensions — effort: L.
  - Note: `Promotion.swift` (1439) **mitigates** via 13 small top-level types — no split needed; it is the template, alongside the EditorCoordinator split, that F5–F7 haven't yet followed.

### 3.4 Security (A5) — nothing Critical/High; write side hardened
- **F8 [Low] Owned-asset `ownedPath` (schema-8 `canvas.json` sidecar value) is resolved with a bare `appendingPathComponent`, bypassing the `SafeRelativePath` helper this milestone added** — a `../`-containing `ownedPath` escapes the project root at read time. Contained (the escaped URL feeds only an image decoder or a promotion copy-in, both local; writing/syncing `canvas.json` already needs the same local access the check guards) — but it is precisely the "verify SafeRelativePath is applied at the new canvas asset sites" gap, and the sites don't apply it: `CanvasThumbnails.swift:284,:327`, `Promotion.swift:946`, `CanvasItemFacts.swift:90-93`, `CanvasItemPresentation.swift:114`. — fix-shape: route owned-path→URL through `SafeRelativePath.resolve(_, under: projectRoot)` (nil/skip on throw) at the thumbnail + promotion resolution points — effort: S.
- **F13 [Low] Decompression-bomb intermediate decode** — a hostile tiny-on-disk huge image copied verbatim into `canvas_assets/` is decoded via `CGImageSourceCreateThumbnailAtIndex`; output is bounded (2048px, off-main, failure-cached) but peak decode memory can spike before downsampling (`CanvasThumbnails.swift:355-367`). Well-mitigated already. — fix-shape: gate on source pixel dims from `CGImageSourceCopyPropertiesAtIndex` before thumbnailing — effort: M.
- **Re-audit clean:** all 6 pinned CI action SHAs dereference to their claimed tags (no fabrication); the prior audit's toolchain-floating flag is **resolved** (`xcode-version` pinned 26.6/26.3, `xcodegen` pinned 2.45.4 + sha256); updater trust anchor intact (codesign `--verify --deep --strict` + `spctl` + Team-ID match over HTTPS); `add_canvas_scraps` mints all ids server-side, validates before writing, and its signature structurally cannot express a location/path; `list_canvas` omits owned paths from the wire; translation ids are regex/manifest-validated; corrupt `canvas.json` is contained (empty layout, words intact); owned photos survive node & sidecar deletion.

### 3.5 Words-safe & round-trip (T-A scrap tracer + A6 bug-hunt)
- **F11 [Low, constitution-touching] `CanvasStore.writeNow` writes the derived sidecar *before* the content** — `writeSidecar(scene)` then `ScrapText.render(scraps).write` (`CanvasStore.swift:128-131`). The two atomic writes are not an atomic pair; a crash in the gap resurrects a node in `canvas.json` with no text in `canvas.md`, and the scrap reloads empty (**constitution must #1, "the words are safe"**). The window is microseconds and clean teardown is safe, hence Low — but the fix is trivial and the invariant is load-bearing. — fix-shape: write `canvas.md` (content) first, then `canvas.json` (derived), so a mid-write crash can only lag the recoverable derived file — effort: S.
- **F9 [Low] `model.scraps` is never pruned to the node set** (`CanvasModel.swift:289`, `scraps = loaded.scraps` with no filter). An id present in `canvas.md` but absent from `canvas.json` (a codec-dropped node, or a `saveSceneOnly` desync — the craft-intent-adoption seam) survives as orphan text and `ScrapText.render` rewrites it into `canvas.md` on every save. — fix-shape: after load, drop `scraps` keys with no matching `scene.node` — effort: S.
- **F10 [Low] Region→research-note link offer counts members promoted to craft intent, but `writeOfferedLinks` silently skips them** (`Promotion.swift:997-1002` × `PromotionPerformer.swift:703-711`) — "Also link N cards" can exceed the reported "Linked M notes." Benign (skip, not crash); the same root as F1. — fix-shape: filter `offeredLinks` to writable research items — effort: S.
- **F12 [Low] `ScrapText.parse` trims *all* leading/trailing blank lines** via `while … isEmpty` loops, contradicting its own doc ("Trim only the blank lines the renderer added") — a scrap whose body intentionally begins/ends with blank lines loses them on the load round-trip (`ScrapText.swift:64-65`). The one place doc and behavior actually diverge in the canvas files. — fix-shape: strip exactly one leading and one trailing blank line (the render adds exactly one each) — effort: S.

---

## 4. Tripwire promotion table (A4 partial — in-repo tripwires only; memory corpus unaudited in cloud)

Ladder: 1 prose → 2 checklist → 3 grep/CI test → 4 type constraint → 5 impossible-by-construction.

| Item | Now | Achievable | Action |
|---|---|---|---|
| **TW25 (no `.scaleEffect`/`magnification`)** | 1 (prose; camera-math test only) | 3 | **promote** — grep guard + planted-offender (F2) |
| TW26–32 (canvas: TextKit stack, fold-on-change, settle-predicate, redraw-counter, membership, undo-bracket) | 3 (census / runtime pin) | 3–4 | **keep — model implementations**; all verified honored in code |
| TW31/32 censuses | 3 | 3 | keep; best-defended in the batch (converse + planted-offender self-checks) |
| "four routes onto the canvas" (prose ×4: CLAUDE.md, product.md:27, problem-map.md:28, Stores/AREA.md) | 1 | 3 | **promote** — a `CanvasIngestRouteCensus` over the `ingestCanvasAsset` call sites, mirroring `PromotionCommandTests` (generation candidate) |
| "born measured at `itemLabelOnlyHeight`" (copy-repeated across 4 creation callers) | 1 | 3 | consider promote — census the shared constant across CanvasDrop/ExternalDrop/ClaudePlacement |
| Tool count (55) / keybinding table / right-pane order | 3 (DocSync) | 3 | keep — enforcement already mature |

**Note on discipline:** the newest count-shaped claims (canvas schema 8, undo census 7, promotion arms) shipped **with** their enforcement (`CanvasSceneCodecTests`, the bracket census, `PromotionCommandTests`) rather than after a drift finding forced it — a visible improvement over the prior audit's tool-count gap. CLAUDE.md's self-distrusting "count the array, not this cell" cells all checked out accurate; the one drift (F3) was in a *sibling* file with no census.

---

## 5. Binary triage (no "defer until touching the area" bucket — `feedback_no_defer_bucket`)

| Finding | Sev | Verdict | Batch |
|---|---|---|---|
| F1 craft-intent line-promotion preview/commit disagreement | High | **Schedule** (M) | Craft-intent-on-canvas |
| F10 region link-offer overcount (same root) | Low | **Schedule** (S) | Craft-intent-on-canvas |
| F2 TW25 grep-guard | Medium | **Schedule** (S) | Enforcement ladder |
| F3 roadmap MCP-tests `•→✓` | Medium | **Schedule** (S) | Doc-truth |
| F4 roadmap line-deletion wording | Low | **Schedule** (S) | Doc-truth |
| F5 ProjectWindow split | Medium | **Schedule** (L) | Context-window economics |
| F6 CanvasRenderer.draw split | Medium | **Schedule** (M) | Context-window economics |
| F7 CanvasView input-extension split | Medium | **Schedule** (L) | Context-window economics |
| F8 ownedPath → SafeRelativePath | Low | **Schedule** (S) | Canvas robustness |
| F9 orphan-scrap prune | Low | **Schedule** (S) | Canvas robustness |
| F11 write-order (content first) | Low | **Schedule** (S) | Canvas robustness (constitution-touching) |
| F12 ScrapText blank-line trim | Low | **Schedule** (S) | Canvas robustness |
| F13 decompression-bomb pre-gate | Low | **Schedule** (M) | Canvas robustness (lowest priority) |

**Merit-drops (recorded so the next audit doesn't re-litigate):**
- **PromotionCommandTests census is per-token-per-file, not numeric-N** (A2) — a structural consolidation of two census files into one with the same tokens could escape notice. Dropped: the census already prevents the failure it was built for (a *missing* site); guarding against benign file-merges is negative-value ceremony.
- **11 source-scanning canvas test files are brittle to rename/reformat** (A2) — dropped on merit: each carries an in-file rationale that the SwiftUI composition fact it pins has *no runtime seam*; "fixing" toward runtime tests is strictly weaker. Preserve the pattern.
- **`CanvasThumbnails.resolved` O(queue) `contains` scan per visible-missing card per frame** (A6) — self-resolves once decoded; not a defect.
- **Contribution record is single-valued ("most recent wins")** (T-B/A6) — a documented, test-pinned data-model choice, not a bug.

---

## 6. Refuted / resolved suspicions (so the next audit doesn't re-chase)

- **`add_canvas_scraps` arriving mid-type corrupts the writer's in-flight scrap** (two-correct-features class) — **REFUTED by construction**: the write mints *new* nodes and never touches writer-made scraps (A5); the per-keystroke fold keeps `model.scraps[editedID]` current (T-A); layout reuse is text-equality-keyed so the edited TextKit stack is never swapped; `CanvasClaudeWriteTests.test_aWriteArrivingMidVisitDoesNotJoinTheWritersSentence` pins the undo bracket for the same scenario.
- **Cross-surface contract drift from the new subsystems** (phone-v0.1.1 class) — **REFUTED**: Canvas and the persona shell are Mac-only (not in MaughamCore); the translation layer correctly lives in shared MaughamCore (`TranslationStore`/`Deriver`/`Record`) per tripwire 19, and the phone does not consume it yet — no drift, no registry row owed.
- **CI action SHA fabrication** (recurrence of the PR-#1 class) — **REFUTED**: all 6 pins verified live against tags.
- **Canvas persistence reads a derived artifact as source** (output-read-back class) — **RESOLVED/by-design**: `canvas.md` is content, `canvas.json` is the derived sidecar (`adr-0018-ok`); the only real issue on this seam is the write *ordering* (F11), not a read-back.
- **`RegionBinding.references(forPiece:in:)` unwired** (prior "zero production callers" concern) — **RESOLVED**: now has two production callers (`CanvasHighlight.swift`, `CanvasTools.swift`), census-pinned.
- **TW25/26/28/29/30/31/32 honored?** — **VERIFIED in code** by three independent agents (A1, A6, T-A), not from docs.

---

## 7. Review-process notes

- All 7 agents delivered the two-part contract via SendMessage on first attempt — **no idle-without-delivering this pass** (the brief's explicit "SendMessage to main before finishing" line, added after the 2026-07-11 idle problem, worked).
- The one High came from a **tracer's data-flow colliding with a cross-area invariant** ("statements are a separate manifest"), not from any agent's findings list — the synthesis-over-maps design paying off exactly as intended. F1/F9/F10 converging on the craft-intent seam was visible only across three maps.
- **Independent double-confirmation** occurred on F3 (coordinator pre-pass + A3) — worth keeping the coordinator's own cheap doc-truth pass alongside the docs agent.
- **Cloud constraints honored:** no build/smoke; the audit needed none. **Gap to flag for a non-cloud audit:** the memory→tripwire promotion dimension (A4) could only cover the 32 in-repo tripwires — the 58-file memory corpus and `MEMORY.md` were unreachable. A future full audit run on the dev machine should re-include the memory-corpus half (duplicate/contradicting memories, buried-lesson promotion).
