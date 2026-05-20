# OpLog — Area guide

This is the **cleanest** area in the codebase per the 2026-05-19 audit. Don't refactor structurally. Read this before touching anything in `Maugham/OpLog/`. Also read the project root `CLAUDE.md` for cross-cutting invariants.

## What this area owns

The manuscript op log: append-only event stream of paragraph-level mutations, paragraph-keyed LWW conflict resolution, project-scope checkpoints with partial restore, cross-Mac log merge, and the inline `<!-- ¶id -->` HTML-comment anchors that join op records to rendered markdown.

**This is the source of truth for manuscripts.** `.md` files on disk are derived from the op log + Bootstrap-minted anchors. The .md is what writers and Claude Desktop read; the op log is what survives merges and history.

## Layout

- `OpLogStore.swift` and `CheckpointStore.swift` — thin wrappers (~30 lines each) over `JSONLAppendStore<T>`. The wrappers keep hot-path (op log, every typing burst) and cold-path (checkpoints, ⌘S) concurrency profiles explicit; `JSONLAppendStore` is the shared persistence primitive.
- `JSONLAppendStore.swift` — generic append + read + tail for any JSONL-typed store. Extend here if you need new shared persistence semantics.
- `Bootstrap.swift` — mints `¶id` anchors on first-open of a document. **Must be called from any production load path.** Wired into `Document.load` since `milestone-document-first-class` (2026-05-19); `BootstrapWiringTests` enforces the contract. Any new manuscript-load path must route through `Document.load`.
- `EchoState.swift` — typed snapshot of "bytes we just wrote to disk." Only three named factories construct it (`initialLoad`, `afterWrite`, `afterIngest`); the echo guard in `Document.handleExternalDiskChange` reads `lastDiskEcho.bytes` to suppress presenter callbacks that arrive in response to our own writes. See [ADR 0010](../../docs/adr/0010-typed-cross-area-seams.md).
- `SweepReason.swift` — typed pending orphan-annotation sweep carrying the *observed* removed-paragraph-id set. Replaces an earlier bool flag. Sweep archives only annotations on `reason.removed` — never "anything missing from sequence." See [ADR 0010](../../docs/adr/0010-typed-cross-area-seams.md).
- `ParagraphID.swift` — exactly 4 chars. Validation is enforced in production but several tests violate this silently.
- `Reconciler.swift` — ingests external edits (writer edited the .md outside the app, or iCloud delivered a remote write) back into the op log.
- `RenderFilter.swift` — derives the rendered .md from the op log. **Lives at `Maugham/Editor/RenderFilter.swift`** (it's consumed by the editor's display path; conceptually owned by this area). Three matching tiers for the "which historical paragraph does this orphan line belong to" question.
- `ShingleMatcher.swift` — k-shingle Jaccard matcher used by RenderFilter and Reconciler.
- `PendingBuffer.swift` — in-memory buffer between live typing and op-log appends (debounce window).
- `OpKind.swift` — the closed set of operation types. Adding a new one touches every store and the renderer.

## Invariants

These hold by construction. If you find code that violates one, treat it as a bug.

- **Op log is append-only.** No mutation, no deletion. Checkpoints capture state; they don't truncate history.
- **`¶id` anchors are 4-char.** No exceptions. Tests that use 1-char IDs are wrong and silently bypass validation.
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

2. **Don't use 1-char paragraph IDs in tests.** `ParagraphID` requires exactly 4 chars. `PendingBufferTests` (and old `RenderFilterTests`) violate this silently. New tests must use 4-char IDs. Existing violations are known carry-forward; don't propagate.

3. **Don't add a new `OpKind` without checking all consumers.** Adding a case touches `OpLogStore` (serialization), `RenderFilter` (rendering), `Reconciler` (external-edit reverse mapping), and probably `MCP/Tools/` (if the new op is annotation-visible). Audit before adding.

4. **Don't change paragraph-ID minting in `Bootstrap`** without thinking about existing on-disk op logs. New IDs in existing docs would orphan all prior op records.

5. **Don't bypass `PendingBuffer`** to write directly to the op log on every keystroke. The debounce is load-bearing for I/O cost; bypassing it will hit disk hundreds of times per second.

## Outstanding correctness

- **`Reconciler`'s classifier still unit-only.** End-to-end coverage of the silent-ingest and needs-sheet branches lives in `EditorIntegrationHarnessTests`; echo-guard coverage lives in `PresenterRoutingTests`. What's missing is a focused test that simulates "writer edits .md externally with subtle changes (whitespace shifts, near-duplicate paragraphs) and the classifier picks the right matcher tier."
- **No regression test for the bigram-tier matcher in `RenderFilter`.** Tier 2 / tier 3 disagreement is silent; a test that creates near-duplicate paragraphs and asserts the right matcher fires would catch unification regressions.

## Tests worth knowing about

- `MaughamTests/OpLog/` — unit tests for each store + the matchers.
- `MaughamTests/OpLog/BootstrapWiringTests.swift` — asserts every production manuscript-load path (`Document.load` and `withAnnotationDocument`) runs Bootstrap on an unanchored .md. Touch this whenever a new manuscript-load entry point is added.
- `MaughamTests/Integration/PresenterRoutingTests.swift` — asserts the echo-guard contracts hold (autosave + keep-mine round-trips don't reingest) and that the new `SweepReason` keeps MCP annotation writes against a live doc from triggering spurious archives.
- **Missing high-value coverage:** the bigram-tier matching in `RenderFilter` (tier-2 / tier-3 disagreement is silent) and Reconciler classifier edge cases on subtle external edits.

## What's intentionally NOT here

- The editor (NSTextView, tokenization, styling) — `Maugham/Editor/`.
- Document load coordination, autosave timing, conflict UI — `Maugham/Stores/DocumentStore.swift`.
- Project-folder filesystem layout (`.maugham/ops/` etc.) — owned conceptually by Stores; this area writes *into* `.maugham/ops/` but doesn't decide the layout.
- Annotation layer (paragraph-anchored comments from Claude/MCP) — `Maugham/MCP/` + a Stores extension.
