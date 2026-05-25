# OpLog — Area guide

This is the **cleanest** area in the codebase per the 2026-05-19 audit. Don't refactor structurally. Read this before touching anything in `Maugham/OpLog/`. Also read the project root `CLAUDE.md` for cross-cutting invariants.

## What this area owns

The manuscript op log: append-only event stream of paragraph-level mutations, paragraph-keyed LWW conflict resolution, project-scope checkpoints with partial restore, cross-Mac log merge, and the inline `<!-- ¶id -->` HTML-comment anchors that join op records to rendered markdown.

**This is the source of truth for manuscripts.** `.md` files on disk are derived from the op log + Bootstrap-minted anchors. The .md is what writers and Claude Desktop read; the op log is what survives merges and history.

## Layout

- `OpLogStore.swift` and `CheckpointStore.swift` — thin wrappers (~30 lines each) over `JSONLAppendStore<T>`. The wrappers keep hot-path (op log, every typing burst) and cold-path (checkpoints, ⌘S) concurrency profiles explicit; `JSONLAppendStore` is the shared persistence primitive.
- `JSONLAppendStore.swift` — generic append + read + tail for any JSONL-typed store. Extend here if you need new shared persistence semantics.
- `Bootstrap.swift` — mints `¶id` anchors on first-open of a document. **Must be called from any production load path.** Wired into `Document.load` since `milestone-document-first-class` (2026-05-19); `BootstrapWiringTests` enforces the contract. Any new manuscript-load path must route through `Document.load`.
- `EchoState.swift` — typed snapshot of "bytes we just wrote to disk." The `init` is `private`; the only construction paths are the three named factories (`initialLoad`, `afterWrite`, `afterIngest`), which is a compile-checked invariant. The echo guard in `Document.handleExternalDiskChange` reads `lastDiskEcho.bytes` to suppress presenter callbacks that arrive in response to our own writes. See [ADR 0010](../../docs/adr/0010-typed-cross-area-seams.md).
- `SweepReason.swift` — typed pending orphan-annotation sweep carrying the *observed* removed-paragraph-id set. Replaces an earlier bool flag. Sweep archives only annotations on `reason.removed` — never "anything missing from sequence." See [ADR 0010](../../docs/adr/0010-typed-cross-area-seams.md).
- `ParagraphID.swift` — paragraph IDs are 4 chars from a restricted alphabet (`0123456789abcdefghjkmnpqrstvwxyz`, no `iloux` to dodge ambiguity). `mint()` produces them; `parseComment()` only accepts strings matching `[alphabet]{4}`. The 4-char rule is enforced **at the .md round-trip boundary** — `recordChange(paragraphId:)` and other in-memory APIs accept any string, so OpLog unit tests legitimately use short IDs like `"a"`/`"b"`. If your test crosses the .md ↔ op log boundary (Bootstrap, Reconciler ingest, RenderFilter against parsed comments), use 4-char alphabet-restricted IDs or `ParagraphID.mint()`.
- `TaskAnchorID.swift` — task anchors are 6 chars from the same restricted alphabet. `mint()` and `parseComment()` mirror `ParagraphID`, but the comment format is `<!--t-XXXXXX-->` (vs the paragraph-anchor `<!-- ¶XXXX -->`). Use `TaskAnchorID.mint()` (not literal strings) in tests that cross the .md boundary. See [ADR 0011](../../docs/adr/0011-tasks-first-class-with-inline-anchors.md) for why anchors are 6 chars (birthday-collision safety to ~30K tasks per doc).
- `Reconciler.swift` — ingests external edits (writer edited the .md outside the app, or iCloud delivered a remote write) back into the op log.
- `RenderFilter.swift` — derives the rendered .md from the op log. **Lives at `Maugham/Editor/RenderFilter.swift`** (it's consumed by the editor's display path; conceptually owned by this area). Three matching tiers for the "which historical paragraph does this orphan line belong to" question.
- `ShingleMatcher.swift` — k-shingle Jaccard matcher used by RenderFilter and Reconciler.
- `PendingBuffer.swift` — in-memory buffer between live typing and op-log appends (debounce window).
- `OpKind.swift` — the closed set of operation types. Adding a new one touches every store and the renderer.
- `RewindCursor.swift` — typed scrub state (`.now` vs `.atOp(opId, at)`) consumed by `Deriver.derive(ops:upTo:)` and `RewindWindow`.
- `RewindRestoreResult.swift` — return value of `Document.restoreToOp`.
- `SynthesisSource.swift` — typed cause of synthesized ops (`paragraph_deleted`, `disk_at_ingest`, `use_cloud_resolution`, `rewind`).

## Task anchors — first-class inline identity

Task anchors (`<!--t-XXXXXX-->`) join paragraph anchors as the second instance of the "first-class inline identity" pattern. See [ADR 0011](../../docs/adr/0011-tasks-first-class-with-inline-anchors.md) for the architectural decision and the general rule: *use anchors for any manuscript-derived data item whose lifecycle (priority, status, parent) must survive text restructuring.*

Key machinery:
- `Document.rebuildTasksCache` calls `TaskDeriver.derive` and receives `mintedAnchors` as a side-channel. It injects the new anchors into `paragraphs[paragraphId]` so the autosave path writes them back to disk. Re-entrancy is guarded via `_isRebuildingTasks`.
- `Document.archiveTask(id:)` does **two things**: emits a `.taskArchive` op AND mutates the manuscript text (splice rules per spec §2.7). Auto-archive on manual line delete is emitted from `setFullText` Pass 3 of the V2 alignment.
- `Document.setFullText` now accepts optional `preEditCursor` / `postEditCursor` for V2 cursor-bias cross-paragraph alignment. Legacy callers pass nil and get per-paragraph-only alignment (no regression to existing code paths).
- `RenderFilter.stripComments` strips `<!--t-…-->` markers before display; `RenderFilter.restoreTaskAnchors(prior:displayed:)` re-injects them after each edit. The round-trip property `restoreTaskAnchors(prior, stripComments(prior)) == prior` is property-tested in `RenderFilterTaskAnchorTests`.

## Invariants

These hold by construction. If you find code that violates one, treat it as a bug.

- **Op log is append-only.** No mutation, no deletion. Checkpoints capture state; they don't truncate history.
- **`¶id` anchors are 4-char.** No exceptions. Tests that use 1-char IDs are wrong and silently bypass validation.
- **Task anchors are 6-char.** Same alphabet as paragraph anchors. `<!--t-XXXXXX-->` only — no uppercase, no other prefix.
- **Paragraph-keyed LWW.** Concurrent writes to the same paragraph resolve by timestamp, not by line position. Cross-Mac merges depend on this.
- **`Bootstrap.run` is idempotent.** Calling it twice on the same document is safe (it skips paragraphs that already have anchors).
- **`.md` on disk is derived.** A reader can always rebuild it from `op-log.jsonl` + the renderer. Don't introduce any state that lives *only* in .md and not in the op log.
- **Checkpoints can do partial restore.** Restore-this-document, not restore-everything.

## RenderFilter's three matching tiers (subtle)

When the renderer encounters a paragraph in the .md that doesn't have a `¶id` anchor (e.g., external edit), it tries to attach it to a known op-log paragraph in three tiers:

1. **Exact text match** — text == known paragraph.
2. **Shingle Jaccard ≥ threshold** — `ShingleMatcher` (k-shingle similarity).
3. **Character bigram match ≥ 0.6** — added late in T16 as a fallback for very-short paragraphs where shingling underperforms. **This third tier exists in `RenderFilter` but NOT in `ShingleMatcher`.** That's not a bug, but it's a planned cleanup — when you unify them, preserve the bigram threshold.

Failure modes:
- All three tiers miss → orphan paragraph (logged, surfaced in the audit).
- Tier 2 matches the wrong paragraph (false positive on near-duplicate scenes) → silent corruption. The bigram tier doesn't cause this; tier 2 alone could.

## Tripwires

1. **Don't collapse the OpLogStore / CheckpointStore wrappers into bare `JSONLAppendStore<T>` calls at every callsite.** The two thin wrappers exist precisely to keep the hot-path (op log: every typing burst) vs cold-path (checkpoint: ⌘S / project-close) concurrency profiles explicit at the type level. If you need new shared persistence semantics, extend `JSONLAppendStore<T>` and let both wrappers benefit; don't push the difference into call sites.

2. **Use 4-char alphabet-restricted paragraph IDs in any test that crosses the .md boundary.** In-memory tests of `PendingBuffer`, `Deriver`, `Op` serialization, `CrossMacMerge` etc. don't cross the boundary and short IDs (`"a"`) are fine. Tests exercising Bootstrap, Reconciler ingest, or RenderFilter-against-parsed-anchors need 4-char IDs from the alphabet, otherwise `parseComment` won't recognize them and the test will silently exercise only half the round-trip.

3. **Don't add a new `OpKind` without checking all consumers.** Adding a case touches `OpLogStore` (serialization), `RenderFilter` (rendering), `Reconciler` (external-edit reverse mapping), and probably `MCP/Tools/` (if the new op is annotation-visible). Audit before adding.

4. **Don't change paragraph-ID minting in `Bootstrap`** without thinking about existing on-disk op logs. New IDs in existing docs would orphan all prior op records.

5. **Don't bypass `PendingBuffer`** to write directly to the op log on every keystroke. The debounce is load-bearing for I/O cost; bypassing it will hit disk hundreds of times per second.

## Tests worth knowing about

- `MaughamTests/OpLog/` — unit tests for each store + the matchers.
- `MaughamTests/OpLog/BootstrapWiringTests.swift` — asserts every production manuscript-load path (`Document.load` and `withAnnotationDocument`) runs Bootstrap on an unanchored .md. Touch this whenever you add a new manuscript-load entry point.
- `MaughamTests/Integration/PresenterRoutingTests.swift` — asserts the echo-guard contracts hold (autosave + keep-mine round-trips don't reingest) and that `SweepReason` keeps MCP annotation writes against a live doc from triggering spurious archives.
- `MaughamTests/OpLog/DeriverUpToTests.swift` — `derive(ops:upTo:)` semantics.
- `MaughamTests/Integration/RewindFlowTests.swift` — end-to-end `Document.restoreToOp`.
- `MaughamTests/Integration/SynthesisSourceMigrationTests.swift` — string raw value on disk decodes into the enum.

Known thin coverage (file an issue before relying on these areas for novel behavior):

- `Reconciler` tier-selection on subtle external edits (whitespace shifts, near-duplicate paragraphs) is only indirectly covered through `EditorIntegrationHarnessTests`.
- `RenderFilter`'s third (bigram) matching tier doesn't have a focused tier-2-vs-tier-3 disagreement test.

## What's intentionally NOT here

- The editor (NSTextView, tokenization, styling) — `Maugham/Editor/`.
- Document load coordination, autosave timing, conflict UI — `Maugham/Stores/DocumentStore.swift`.
- Project-folder filesystem layout (`.maugham/ops/` etc.) — owned conceptually by Stores; this area writes *into* `.maugham/ops/` but doesn't decide the layout.
- Annotation layer (paragraph-anchored comments from Claude/MCP) — `Maugham/MCP/` + a Stores extension.
