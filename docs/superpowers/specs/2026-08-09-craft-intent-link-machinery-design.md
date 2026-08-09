# The link machinery learns statements — craft-intent-on-canvas hardening

**Date:** 2026-08-09
**Source:** Issue #24 (audit findings F1 [High] + F10 from the 2026-08-09 full audit; S1 + S2 from the 2026-08-02 sweep — F1 and S1 are the same defect, found independently twice)
**Decided with Denver:** make it work (not refuse); statements + research notes both; statement titles become resolvable link targets.

## 1. Problem

M1A made craft intent a `Statement` (in `manifest.statements`) and folded it into the canvas's **read** machinery — `ArtifactIndex.over` deliberately indexes `.intent` statements so a promoted card's mark resolves. But three downstream surfaces never learned:

1. **`PromotionPerformer.performWikiLink`** finds the from-endpoint's artifact via `TreeWalk.find(id:, in: store.manifest.research)`. A line drawn *from* a craft-intent-marked card passes `targets`/`plan` (the index resolves the mark), then throws `PromotionFailure.artifactMissing` at Commit — whose alert says the artifact "is no longer in the project," which is false. This is the preview/commit disagreement the whole file is architected to prevent. (F1/S1, High.)
2. **`PromotionPerformer.writeOfferedLinks`** has the same `manifest.research`-only lookup, so a region's "Also link N cards" counts intent-marked members it will then silently skip. (F10.)
3. **`ProjectStore.propagateWikiLinkRename`** walks only `manifest.structure` — renaming a document silently orphans `[[…]]` links inside statements (new with M1A) and research-note bodies (pre-existing since 1C-c2; ADR 0026 records it "recorded, not fixed") while `list_all_links`/`find_references` keep reporting them. (S2.)

And one adjacent gap the design review surfaced: the graph tools' `titleIndex` resolves `[[…]]` against research + manuscript titles only, so a line drawn *to* a craft-intent card commits successfully but writes `[[Craft Intent · Chapter]]` — a link reported `wiki_unresolved` forever (the sweep's "sharper half").

## 2. Principle

Everywhere the machinery touches a `[[…]]`, a statement is a first-class endpoint: written **from** (the performer appends into its op log), linked **to** (its composed title resolves), and **maintained** (renames rewrite links inside it, and rewrite links *to* its composed title).

Nothing changes on the preview side (`Promotion.targets`/`plan`/`blockedReason` were already correct), in what a mark can name (`.intent` only), or in the tool count (all read-tool changes are widenings; M1A precedent).

## 3. Design

### 3.1 The write side (F1 + F10)

`PromotionPerformer` gains one private resolver:

```swift
enum WritableDestination { case researchFile(path: String), statement(Statement) }
func writableDestination(of itemID: String) -> WritableDestination?
```

Lookup order: `manifest.research` first (unchanged behavior for every existing case), then `manifest.statements`. Both write sites call it instead of their raw `TreeWalk.find(in: manifest.research)`:

- **`performWikiLink`** — `.researchFile`: exactly today's path (flush, read body, dedupe against file, append, coordinated write). `.statement`: dedupe via `statementText(of:)` (the single sanctioned statement reader — its live arm is fresher than the op log by a burst window), then `appendToStatement(link.appendedText, to:, session: promotionSession)`. No flush dance and no read-back: the op log is the source of truth and an append cannot be raced by the 750 ms save (that method's own documented property). The live-pane-open case and the open gate are already handled inside `appendToStatement`.
- **`writeOfferedLinks`** — same branch per offer. An intent-marked region member gets its `[[artifact]]` appended into its statement rather than being skipped, so offered count and written count agree by *writing*, not by filtering. The existing skip remains only for genuinely-gone items (both registries miss).
- `PromotionFailure.artifactMissing` becomes reachable only when the artifact truly is gone; its alert text is true again. `dedupe` for the statement arm checks `statementText(of:).contains(link.linkText)` — same rule as the file arm, against the freshest text.

Tripwire 32 is untouched: `PromotionPerformer` is already a census entry, and `appendToStatement` is already how `performCraftIntent` writes through it.

**Correction (2026-08-09):** the line above names `link.appendedText`; the built
code (`PromotionPerformer.swift:625`) correctly passes `link.linkText` —
padding around the appended text is `appendToStatement`'s job, not the
caller's. Specs are records too — corrected here rather than silently
rewritten.

### 3.2 Resolution (the junk-link half)

`ListAllLinksTool` and `ReferenceTools` each hand-build a title → (id, title) index. Extract **one shared builder** (working name `WikiTitleIndex.build`, living beside the statement seam so both tools and any future reader call the same spelling) that produces today's index **plus** statement composed titles (`ArtifactIndex.statementTitle`) mapping to `stmt-` ids.

- Collision precedence: research < docs today (docs win, "caller should be using unique titles"); statements slot **below research** — a statement's composed title contains ` · ` and a kind word, so real collisions are near-impossible, and if one occurs the writer-named artifact should win.
- A statement's body containing its own composed title is not a self-link (mirror the research-note rule).
- Tool count stays 55; this is a widening of two existing reads (M1A precedent). `MCP/AREA.md` gets a sentence.

### 3.3 Rename maintenance (S2)

`propagateWikiLinkRename` grows two loops beside the manuscript one, plus one new rewrite rule:

- **Statements** — mirror the manuscript loop: derived-text pre-check (`derivedCache`), live instance via `openStatementDocument(id:)` else transient `Document.load` behind `lockStatementOpen`/`unlockStatementOpen` (the gate exists for exactly this), `WikiLinkRewriter.rewrite`, `setFullText`, `close()` if transient. Op log only, never the `.md`. Per-statement failures logged via `projectStoreLog` and skipped, like the manuscript loop.
- **Research-note bodies** — not op-logged, so: read the file (`// adr-0018-ok:` — research note, not manuscript), rewrite, `flushPendingSave` then coordinated `performFileSave` (the performer's flush-before-write discipline; a queued autosave must not resurrect the stale body).
- **Composed titles** — a document rename changes the composed title of every statement scoped to it, so the rename also propagates `[[<kind> · Old]] → [[<kind> · New]]` for each such statement (both kinds — `.intent` and `.visualLanguage` — via `ArtifactIndex.statementTitle` before/after), across all three body kinds (manuscripts, research notes, statements). Implemented as additional `(oldTitle, newTitle)` pairs fed to the same loops — `WikiLinkRewriter` called once more per pair, no new machinery. (Statement *file* paths are slug-derived at creation and deliberately not renamed — identity is the manifest entry; only link text is maintained.)

ADR 0026's Consequences "recorded, not fixed" line gets a **dated amendment** (appended, house style) recording that rename propagation now covers research notes and statements.

### 3.4 Error handling

- Rename loops: non-throwing method, per-item log-and-skip (existing discipline; one bad doc must not abort propagation).
- Performer: both-registries miss → `artifactMissing` (now truthful); `appendToStatement` throws propagate exactly as they do for `performCraftIntent`; `linkAlreadyPresent` refusal works for both arms with each arm's own freshest-text read.

## 4. Testing

1. **F1 end-to-end regression:** promote a scrap to craft intent, draw a line from it, commit — the link text lands in the statement (assert via `statementText`/op log), no throw. And the mirror: line *to* an intent-marked card resolves in the graph after §3.2.
2. **F10 honesty:** region containing an intent-marked member — offered count == written count; statement body gains `[[artifact]]`; second promotion dedupes (skip, count excludes it).
3. **Live-pane interleaving:** the existing `test_promotingWhileTheIntentPaneIsOpenDoesNotOpenASecondDocument` pattern extended to the wiki-link arm — a line-promotion landing while the intent pane is open does not lose the writer's next keystroke.
4. **Rename round-trips:** `[[old]]` inside a statement body; inside a research-note body; a `[[Craft Intent · Old]]` composed-title link inside a manuscript — all rewritten after renaming the document; `list_all_links` reports zero `wiki_unresolved` across the rename.
5. **Shared index:** statement titles resolve in both tools to `stmt-` ids; docs-beat-research-beat-statements precedence pinned; statement self-title not an edge.
6. **Paragraph-ID discipline:** any test crossing the `.md` ↔ op log boundary uses `ParagraphID.mint()` or valid 4-char literals (tripwire 8).

No new censuses: no new undo-bracket entries, no new tools, no new promotion arms.

## 5. Out of scope

- Making statements reachable from `⌘⌥F` (the M1A roadmap's recorded stop, unchanged).
- Any change to what a mark can name (`.intent` only), promotion targets, or `blockedReason` wording.
- The reference RAIL (M2's), `search_text` scope, phone surfaces (statements are Mac-only today; no cross-surface contract moves).
