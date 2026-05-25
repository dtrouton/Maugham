# Task Anchors and Lifecycle — First-Class Inline Tasks

**Status:** Draft — pending user approval before implementation.

**Goal:** Replace the milestone-tasks paragraph-derived task identity (`inline:<docId>:<paraId>:<bodyHash>`) with **per-task inline anchors** (`<!--t-XXXX-->`) that survive paragraph restructuring, body edits, and duplicate-add/remove. Add a coherent **open / done / archived** lifecycle where Archive removes the task's text from the manuscript and a manual text deletion auto-archives. Add a **"Archive all done"** bulk action.

**Why now:** Three smoke runs against the milestone-tasks build surfaced a cascading set of bugs all rooted in the same design: paragraph_id was load-bearing in task identity. Each fix (load-time orphan drop, live-edit orphan prune, closed-doc aggregation) revealed the next layer. The writer's expressed mental model is that tasks are first-class — paragraphs are where they happen to live, not what defines them. This spec changes the identity model to match that mental model.

**Conformance contract:** Must not regress any test currently green (990 passing at branch tip). No regression to tripwire #7 (`applyExternalText` callers stay at 1 production caller). No new manuscript-load entry point. Bootstrap mints task anchors on first encounter the same way it mints paragraph anchors — anchor minting is a write-back to disk that flows through autosave, not a new I/O channel. Migration: existing test data is discarded (per CLAUDE.md tripwire #11 and explicit user okay).

**Working title:** `milestone-task-anchors`.

---

## 1. Problems addressed

### 1.1 Identity drifts on paragraph restructuring

Current: synth_id = `inline:<docId>:<paraId>:<bodyHash>`. A writer who splits one checkbox paragraph into six, or merges two back into one, sees:
- Drag-ordering reset (priority ops orphaned)
- Parent-nesting reset
- Phantom rows in the pane until the next load-time recovery
- Click-to-jump no-op'd for tasks whose paraId no longer exists

### 1.2 Identity drifts on body edit

Renaming `tighten this` → `tighten Anna's dialogue` produces a new bodyHash → new synth_id → orphaned priority/parent ops. Writers rename frequently.

### 1.3 Identity drifts on duplicate add/remove

A doc with three `- [ ] tighten this` lines, where the writer deletes the middle one, shifts the occurrence indices for the surviving two. Any priority op keyed to "occurrence 2" now points at "occurrence 1". Affects the common case (mark-done → archive → delete) hard.

### 1.4 No way to express mid-paragraph todos with stable identity

`- [ ] body` is line-start-only by markdown convention. Writers want marginal reminders inside prose: *"Anna walked across the room [[todo: tighten this dialogue]] and saw the cat."* Maugham already recognizes `[[todo: …]]` via the Fountain boneyard discriminator, but identity drifts the same way as `- [ ]` tasks under the current model.

### 1.5 Archive and delete are conflated

Today, deleting the line silently nukes the task — no audit trail. Marking done leaves the line forever. No "tidy up" action removes done tasks from the manuscript. The writer wants:
- **Done**: visible (struck-through) in text, awaiting tidy-up
- **Archived**: explicitly removed from text by an Archive action
- **Manual delete**: implicitly archived (audit trail preserved)

---

## 2. Architecture overview

### 2.1 Anchor format

Per-task anchor in the `.md`, mirroring paragraph anchors:

```markdown
<!-- ¶mnj6qx -->

- [ ] Write the big opening <!--t-9k2x6a-->
- [ ] tighten this dialogue <!--t-p3rtab-->
- [ ] tighten this dialogue <!--t-w8mqcd-->
- [ ] tighten this dialogue <!--t-jqdz7n-->
```

- Anchor id: 6 chars from the alphabet `[0123456789abcdefghjkmnpqrstvwxyz]` (CLAUDE.md tripwire #8 — same alphabet as paragraph IDs)
- Wrapped: `<!--t-XXXXXX-->` (6 alphabet chars after the `t-` prefix)
- Position: at the end of the line for `- [ ]`, immediately after the closing brackets for `[[todo: …]]`
- 6 chars × 32-alphabet = ~1B combinations; birthday collision becomes negligible until ~30K anchors per doc

```markdown
Anna walked across the room [[todo: tighten this dialogue]]<!--t-9k2x6a--> and saw the cat.
```

Note no space between `]]` and `<!--t-`. Spacing immediately around the anchor MAY appear because of how the writer typed — the renderer collapses it consistently so the editor display is clean.

### 2.2 Identity

New synth_id: `inline:<docId>:<anchorId>` (e.g., `inline:doc-XYZ:t-9k2x`).

- No paraId
- No bodyHash
- No occurrence index
- Anchor never changes once minted

Result: identity stable across every operation that preserves the anchor in text. Identity ends only when the anchor leaves the text (= the task is archived or deleted).

### 2.3 Bootstrap-style minting

Like paragraph anchors. On `Document.load`, the parser detects `- [ ]` lines (and `[[todo: …]]` segments) without anchors and mints them. The first `Document.load` after a writer types a new task triggers a write-back to the .md via the existing autosave path. Subsequent opens see anchored content.

Minting flow:
1. `MarkdownCheckboxScanner` / `FountainBoneyardScanner` return an optional `anchorId` (nil if unanchored)
2. `TaskDeriver.derive` enumerates tasks; for any task with `anchorId == nil`, mint a fresh `TaskAnchorID`
3. Deriver returns a side-channel `mintedAnchors: [(paragraphId, lineOrRangeWithinParagraph, anchorId)]`
4. `Document.rebuildTasksCache` applies the minted anchors back to `paragraphs[paragraphId]` by inserting the anchor markers, then bumps `tasksVersion`
5. Autosave catches the paragraph mutation and persists to disk on the next 750ms cycle

The first burst that captures the minted anchors fires an `.taskCreate` op for each new anchor — recording authoritative creation timestamps + session ids.

### 2.4 Editor display: anchors stripped

`RenderFilter` strips `<!--t-XXXX-->` from `displayText` (mirror of how it strips `<!-- ¶XXXX -->`). The editor's `NSTextView` storage shows the stripped form. The .md on disk and the in-memory `paragraphs[id]` keep anchors.

Critical seam: `Document.setFullText` reconciles the displayed (stripped) text back to anchored paragraph text. This needs to **preserve existing anchors** on lines that didn't change. Implementation: when ParagraphParser parses the new stored form (which still has paragraph anchors injected by `restoreComments`), each paragraph's text is the displayed text. We need a second-stage round-trip that re-injects task anchors per line by matching to the prior anchored text.

### 2.4.1 Alignment algorithm (V2 — cursor-bias cross-paragraph)

Per-paragraph alignment with a cross-paragraph correlation pass for cut/paste detection. Threads pre-edit and post-edit cursor positions through `setFullText` so the alignment can disambiguate moves from independent delete+insert pairs.

Inputs to alignment:
- `priorText: [String: String]` — anchored prior paragraph text by id
- `newText: [String: String]` — stripped new paragraph text by id (after `restoreComments` for paragraph anchors)
- `preEditCursor: Int` — character offset in priorText (whole-doc coord)
- `postEditCursor: Int` — character offset in newText (whole-doc coord)

Three-pass algorithm:

**Pass 1 — Per-paragraph body match + LCS.**
For each paragraph independently:
1. Split prior anchored text by `\n` → `priorLines`
2. Split new stripped text by `\n` → `newLines`
3. Strip task anchors from `priorLines` → `priorStripped`
4. **Body-match pass:** for each `newLines[i]`, find an unclaimed `priorStripped[j]` where `priorStripped[j] == newLines[i]`. Pair them; mark both claimed.
5. **LCS pass over unclaimed:** standard longest-common-subsequence pairs body-edited lines (renames) against their best-fit prior line.
6. Yield: paired lines (carry anchor forward), unpaired-new lines (no anchor yet), unpaired-prior lines (deletions).

**Pass 2 — Cross-paragraph cut/paste detection.**
Collect all unpaired-prior lines (deletions) across paragraphs into one pool, and all unpaired-new lines (orphans) across paragraphs into another. For each unpaired-new line:
1. Look for a matching unpaired-prior line (same body, stripped of anchor)
2. If exactly one match exists, AND the cursor delta is consistent with the move (pre-edit position falls within the source paragraph; post-edit position falls within the destination paragraph), pair them
3. The orphan inherits the deleted line's anchor
4. The source paragraph's deletion is rescinded; no `.taskArchive` op fires

If multiple matches exist, prefer the one whose source paragraph contains `preEditCursor`. If still ambiguous, leave both unpaired (anchor lost; archive op fires for the unpaired-prior).

**Pass 3 — Finalize.**
1. For each remaining unpaired-prior: emit `.taskArchive` op with `provenance.userResponse = "user-deleted"`
2. For each remaining unpaired-new that looks like a task (matches the checkbox or `[[todo:]]` pattern): leave unanchored; the deriver mints in the next pass
3. Re-inject anchors into the new paragraph text
4. Update `paragraphs[paragraphId]` with the re-anchored text

### 2.4.2 What V2 resolves

- **Per-paragraph rename**: anchor preserved (body-match against position; LCS handles the rename)
- **Within-paragraph reorder**: anchor preserved (body-match pairs by body, not by position)
- **Cross-paragraph cut/paste** (the case the writer specifically called out — cutting a chunk of text or a whole paragraph containing todos): anchor follows the body via Pass 2's cross-paragraph correlation
- **Search-and-replace** across the document (e.g., `tighten` → `polish`): anchors preserved via positional alignment within each paragraph
- **Insert a new task between existing ones**: new line is unanchored; minted on next derive

### 2.4.3 What V2 cannot resolve

- **Delete a `- [ ]` line, then minutes later type the same line from scratch**: two separate `setFullText` calls. The first archives the anchor; the second mints a fresh one. No correlation possible without explicit pasteboard tracking. Documented as accepted residual.
- **Multiple identical bodies in one paragraph where the writer deletes a non-cursor one**: pass 1's LCS picks an arbitrary alignment for ambiguous deletions. Probably matches the writer's deletion most of the time (cursor is on the deleted line) but not guaranteed for batch operations. Accepted.

This is the most subtle part of the implementation and the place where most tests live (~25 test cases anticipated across `TaskAnchorAlignmentTests`).

### 2.5 Distinct todo styling

ProseMode (and ScreenplayMode for `[[todo:]]`) paints the task body region with a distinct color/weight so the writer can tell at a glance where they are. New `Token.Kind.taskBody`:
- Emitted by the markdown tokenizer for the body region of `- [ ] body`
- Emitted by the Fountain tokenizer for the body region of `[[todo: body]]`

Style: muted color + slightly smaller leading? Or italic? Defer the exact palette pick to implementation taste; the contract is "visually distinct from surrounding prose."

The anchor span (`<!--t-XXXX-->`) gets `Token.Kind.invisibleAnchor` — fully transparent foregroundColor, zero-width visual presence. (Existing `<!-- ¶XXXX -->` handling already does this for paragraph anchors; reuse.)

### 2.6 Lifecycle

| State | Text representation | How to enter |
|---|---|---|
| `.open` | `- [ ] body <!--t-XXXX-->` or `[[todo: body]]<!--t-XXXX-->` | Writer types markup; deriver mints anchor |
| `.done` | `- [x] body <!--t-XXXX-->` or `[[done: body]]<!--t-XXXX-->` | Checkbox click flips bracket; routes through `setParagraph` (no separate op kind — text-is-state) |
| `.archived` | NOT in text | Archive action emits `.taskArchive` AND deletes the line / splices the bracketed segment |

Transitions:
- **Open → Done**: pane checkbox click → `setParagraph` flip → typing_burst captures the text change
- **Done → Archived**: kebab "Archive" → `archiveTask(id:)` emits `.taskArchive` op AND `setParagraph` removes the line / splices the segment
- **Open → Archived**: same as Done → Archived (allowed: "I'm not doing this")
- **Archived → Restored**: not in V1. Recovery path: rewind past the archive op.
- **Manual line delete (writer deletes the line in editor)**: deriver detects "anchor X was here, now gone." Emits `.taskArchive` op with `provenance.userResponse = "user-deleted"` so the audit trail records the cause.

### 2.7 Archive action: text mutation rules

For line-style tasks (`- [ ] body <!--t-XXXX-->`):
- Delete the whole line
- Also delete one of the surrounding `\n` chars (the line's `\n` — keeps paragraph structure correct)
- If the line was the only content in its paragraph, the paragraph collapses to empty (sequence may drop the paragraph_id, sweep handles its annotations)

For inline tasks (`Anna walked across the room [[todo: body]]<!--t-XXXX--> and saw the cat.`):
- Splice out `[[todo: body]]<!--t-XXXX-->` (the entire bracketed segment + its anchor)
- Collapse adjacent whitespace to a single space if both sides become whitespace-bordered
- Don't break the surrounding paragraph

Regression test: the bracketed segment splice must not leave a double-space or stranded punctuation.

### 2.8 Bulk "Archive all done"

Pane toolbar gains a kebab → "Archive all done in [scope]" item:
- Scope follows the pane's current scope (Doc or Project)
- Iterates `tasks(filter:)` for status == .done
- For each, emits a `.taskArchive` op + the text mutation per §2.7
- Wraps the iteration in a single autosave debounce so the .md is written once at the end

If the writer has many done tasks across multiple chapters in Project scope, this can cross multiple Documents. Each Document gets its own batch of mutations. No cross-doc atomicity required.

---

## 3. Data model

### 3.1 `WriterTask` (unchanged shape, new identity semantics)

The struct doesn't change. Only the interpretation of `id` changes: now `inline:<docId>:<anchorId>` always (no fallback to paraId/bodyHash).

`anchor.paragraphId` continues to point at the paragraph currently containing the task — recomputed on every derive. It's metadata, not identity.

### 3.2 `TaskAnchorID`

New type, mirrors `ParagraphID`:

```swift
public enum TaskAnchorID {
    /// Mint a fresh anchor id. 4 chars from the alphabet
    /// [0123456789abcdefghjkmnpqrstvwxyz].
    public static func mint() -> String { ... }

    /// Recognize `<!--t-XXXX-->` and return the inner id; nil otherwise.
    public static func parseComment(_ s: String) -> String? { ... }

    /// Format an anchor as the inline comment span.
    public static func formatComment(_ id: String) -> String { ... }
}
```

### 3.3 Op kinds — no new cases needed

Existing op kinds cover everything:
- `.taskCreate` fires when an anchor is minted (was previously pane-only)
- `.taskStatusChange` still pane-tasks only (inline status remains text-is-state via typing_burst)
- `.taskPriorityChange` keyed by new synth_id (anchor-based)
- `.taskParentChange` same
- `.taskArchive` keyed by new synth_id; fires from both explicit archive action AND auto-archive-on-delete (distinguished by `provenance.userResponse`)
- `.taskBodyEdit` pane-tasks only (inline body edits are typing_burst; the anchor preserves identity)

---

## 4. Migration

Per CLAUDE.md tripwire #11 and explicit user okay (this session): **delete existing test data**. The `Test Novel` project will be removed and recreated.

No migration code. The first `Document.load` against a doc with no anchors mints them; the .md is rewritten with anchors on the next autosave. From the writer's perspective: the first time they open a doc after this milestone ships, anchors appear silently in the .md.

If a doc is opened that contains `- [ ]` lines, anchors are minted for each. Existing `.taskPriorityChange` ops keyed to the old paraId-based synth_ids fall into the deriver's `inlineOverrides` accumulator and are silently ignored (their target ids don't match any anchor-based task). The op log keeps them for rewind faithfulness but they have no effect on current state.

---

## 5. Render filter & tokenizer changes

### 5.1 `RenderFilter.stripComments`

Already strips paragraph anchors. Extend to also strip task anchors:

```swift
// Before: only matches <!-- ¶XXXX -->
// After: matches <!-- ¶XXXX --> AND <!--t-XXXX-->
```

Single regex with alternation, OR two passes. The latter is easier to reason about.

### 5.2 `RenderFilter.restoreComments`

Already re-injects paragraph anchors on the round-trip from display → stored. Extend to also re-inject task anchors. This is the **load-bearing seam** for the line-aware diff described in §2.4.

### 5.3 `MarkdownCheckboxScanner.match`

Extend `Match` to include `anchorId: String?` — nil if the line is unanchored. The deriver mints if nil.

Regex extension: `^(\s*)- \[( |x)\] (.*?)(\s*<!--t-([a-z0-9]+)-->)?$`

Body capture group does NOT include the anchor markup.

### 5.4 `FountainBoneyardScanner.matchTodo`

Same shape — extract anchor id if present at end of bracketed segment. Pattern:

```
\[\[(todo|done):\s*(.*?)\]\](<!--t-([a-z0-9]+)-->)?
```

### 5.5 New tokens

- `Token.Kind.taskBody` — emitted by markdown + Fountain tokenizers for the body region. Painted distinctly.
- `Token.Kind.invisibleAnchor` — emitted for `<!--t-XXXX-->` (and reused for `<!-- ¶XXXX -->`). Painted fully transparent.

The existing `Token.Kind.checkbox(checked:)` continues to cover the bracket glyph.

---

## 6. Acceptance criteria

A writer can:

1. Type `- [ ] tighten this` into a paragraph. On next autosave, the .md contains `<!--t-XXXX-->` at the end of the line. The editor still displays `- [ ] tighten this`.
2. Open the .md in a non-Maugham text editor and see the anchors. They're noise, like paragraph anchors — but the writer understands them by now.
3. Add `- [ ] tighten this` two more times in the same doc. The pane shows 3 rows, each with a unique anchor in the underlying .md.
4. Reorder via drag. Priority ops emit keyed by anchor id.
5. Delete one of the duplicate lines. The pane shows 2 rows; the deleted one moves to the Archived filter; the surviving two retain their drag order. The op log gets a `.taskArchive` op with `provenance.userResponse = "user-deleted"`.
6. Rename one body to `tighten Anna's dialogue`. The pane row updates its body text immediately. Drag position survives. The anchor is unchanged.
7. Mark a task Done. The .md flips `[ ]` → `[x]`. The pane row shows strikethrough. The task remains in the pane under "Done" filter.
8. Click "Archive" on a Done task. The .md line is removed. The task moves to "Archived" filter. The drag position of remaining tasks doesn't shift.
9. Click "Archive all done" in the pane kebab. Every Done task in the current scope is archived in one batch. The .md is rewritten once.
10. Restart Maugham. Anchored tasks reload with stable identity. Drag order persists.
11. Write `Anna walked across the room [[todo: tighten this]] and saw the cat.` mid-paragraph. The deriver mints an anchor. The pane shows a Fountain-badge row. The paragraph displays cleanly (anchor stripped).
12. Click Archive on the inline `[[todo: …]]` task. The bracketed segment is spliced out; the paragraph now reads `Anna walked across the room and saw the cat.` with single-spacing preserved.

---

## 7. Out of scope

Captured to make the boundary explicit:

- **Restore from archive.** V1 punts. Rewind to before the archive op is the recovery path.
- **Done → Archived auto-promote.** Stays manual. Bulk "Archive all done" gives the writer one-click cleanup.
- **Anchor as MCP tool surface.** `list_tasks` and `get_task` continue to surface tasks; the `id` field shifts from `inline:<docId>:<paraId>:<bodyHash>` to `inline:<docId>:<anchorId>`. No new tools.
- **Cross-doc reorder via drag.** Same as before — per-doc only.
- **Anchor preservation across cross-Mac merge.** Same as paragraph anchors: anchors are bytes in the .md; cross-Mac merge sees them as part of the text and preserves them.
- **Tier V3 alignment (delete-then-retype detection).** Hooking into `NSTextStorageDelegate.textStorage(_:didProcessEditing:range:changeInLength:)` for full edit-range tracking could catch delete-then-retype-the-same-thing. Not in this milestone; the residual ambiguity is documented as accepted.
- **Clean export (`Exports/` directory).** A future milestone item: an "Export → Clean Markdown / Fountain" action that strips ALL Maugham anchors (paragraph + task) from the `.md` / `.fountain` and writes a clean copy to `Exports/<docName>.md`. With optional writer-selected filters (strip done items, strip `[[todo: …]]` segments). Out of scope here; tracked in `docs/roadmap.md`.

---

## 8. Risks and known unknowns

- **Round-trip integrity of the display strip / restore.** `RenderFilter.restoreComments` for task anchors is the most subtle piece. A bug here means anchors get dropped from the .md on autosave or mid-edit. Mitigation: extensive line-aware-diff tests + a property test that asserts `restoreComments(stripComments(x)) == x` for any anchored input.

- **Edit-while-deriving race.** The mint flow writes back to `paragraphs[paragraphId]` from `rebuildTasksCache`. If the writer is typing concurrently, the burst flush must serialize correctly. Document is `@MainActor`; same-actor reentrancy is the concern. The existing `_isRebuildingTasks` guard catches the obvious case; need to verify minting doesn't cause `setParagraph` reentry.

- **The Fountain `[[todo: …]]<!--t-XXXX-->` form is dense.** Writers will hate seeing it in their `.fountain` files. Consider whether to place the anchor on the line above instead (`<!--t-XXXX-->\n[[todo: …]]`), or use a different syntax altogether. Decision deferred to design feedback during implementation.

- **Done auto-archive after some time** is NOT in this milestone but might be a future ask. Anchor-based identity makes it easy to add: just a timer that calls `archiveTask` on each Done task older than N days.

- **Anchor collisions.** Mint should check that the new anchor doesn't collide with existing ones in the doc. With a 4-char alphabet of 32 chars, the space is 32⁴ = ~1M. Birthday collision likely after ~1000 anchors per doc — within shouting distance for very task-heavy docs. Mitigation: mint a 6-char anchor instead? Punt to implementation; can extend later without breaking compatibility (just longer ids).

- **`<!--t-XXXX-->` clashing with a literal `<!--t-...-->` someone hand-wrote.** Extremely unlikely. Accept the collision risk; document the reserved syntax in `Maugham/OpLog/AREA.md`.

---

## 9. Related documents

- **ADR 0011** (forthcoming) — Tasks first-class with inline anchors. Records the cross-area decision pattern for this kind of "text-derived → first-class with anchor" shift.
- **Supersedes** the milestone-tasks identity model from `docs/superpowers/specs/2026-05-23-tasks-design.md` §3.2.
- **Mirrors** the paragraph-anchor pattern from `docs/superpowers/specs/2026-05-17-document-operation-log-design.md`.
