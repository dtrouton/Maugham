# 0011 — Tasks first-class with inline anchors

**Status:** Proposed
**Date:** 2026-05-25

## Context

The milestone-tasks identity model derived inline-task identity from `(docId, paragraphId, bodyHash)`. Three smoke runs surfaced cascading failures all rooted in the same source:

1. Splitting a checkbox paragraph created phantom rows in the Tasks pane (orphan paragraphs in the deriver's accumulator).
2. Merging two checkbox paragraphs lost drag-ordering for one side (paragraph_id changed → synth_id changed → priority op orphaned).
3. Renaming a body lost identity entirely (bodyHash changed → synth_id changed).
4. Deleting a duplicate task shifted occurrence indices for surviving same-body siblings (when we tried `inline:<docId>:<bodyHash>:<n>` as a mitigation).

Each individual fix (load-time orphan drop, live-edit orphan prune, closed-doc aggregation) treated a symptom. The underlying issue was design: **task identity was tied to text structure, but the writer's mental model is that tasks are first-class things and paragraphs are where they happen to live.**

A parallel pattern already exists in the codebase. **Paragraph anchors** (`<!-- ¶XXXX -->`) give paragraphs stable identity that survives every text mutation that preserves the anchor. Renaming a paragraph's body, reordering paragraphs, splitting / merging — all preserve paragraph identity through the anchor. The same shape applied per-task yields the same stability for tasks.

The deeper question the smoke surfaced: **for any feature whose data is "derived from manuscript text", do we want first-class identity (anchor-based) or text-derived identity (regex-on-text)?** Annotations went first-class from day one (each `add_note` mints an op id, surfaces as `Annotation.id`). Tasks were modeled text-derived in the original spec. The smoke shows text-derived doesn't scale beyond toy workflows.

## Decision

**Inline tasks become first-class entities identified by minted-once inline anchors persisted in the `.md`.**

Anchor format: `<!--t-XXXXXX-->` where `XXXXXX` is 6 characters from the alphabet `[0123456789abcdefghjkmnpqrstvwxyz]` (the alphabet from CLAUDE.md tripwire #8). Placed at end of line for `- [ ]` tasks, immediately after the closing `]]` for `[[todo: …]]` tasks. 6 chars × 32-alphabet = ~1B combinations, birthday-collision-safe to ~30K anchors per doc.

Identity: `inline:<docId>:<anchorId>`. No paragraphId. No bodyHash. No occurrence index. The anchor is the identity.

Bootstrap-style minting at `Document.load`: any `- [ ]` line or `[[todo: …]]` segment without an anchor gets one minted on first encounter. The autosave path persists the anchored `.md` back to disk. Subsequent loads see anchored content; no further minting needed.

Editor display strips anchors via the existing `RenderFilter.stripComments` / `restoreComments` pipeline (same one that strips paragraph anchors). The `.md` on disk and the in-memory `paragraphs[id]` keep anchors; only `displayText` is stripped.

Lifecycle is now coherent: Open → Done (text flips bracket) → Archived (text deleted, archive op emitted). Manual text deletion auto-archives, preserving an audit trail in the op log.

## When this pattern applies

For any feature whose data is "derived from manuscript text" and whose data items have lifecycle (priority, parent, status, etc.) that should survive text restructuring:

- **Prefer first-class with anchors.** Mint an anchor per item. Persist the anchor in the .md. Strip it from display. Strip-and-restore via `RenderFilter`. Use the anchor as the identity for all ops keyed to the item.

- **Use text-derived only if the item has no per-item lifecycle.** E.g., "highlighted spans" in a search-results view need no identity beyond "this is span N in the current result set" — they're transient. Tasks, annotations, and any future "manuscript-resident first-class object" need identity.

- **Anchor minting flows through autosave.** Don't introduce new I/O channels. Mint in-memory, write back through the existing `Document.setParagraph` → typing_burst → autosave path. This means a load-time mint is observable as a typing_burst op in the next session — useful for cross-Mac merge faithfulness.

- **Anchor stripping must round-trip.** Anything that strips anchors from display MUST round-trip — `restoreComments(stripComments(x)) == x`. Property-test this.

## Consequences

**Positive:**

- Identity survives merge / split / rename / duplicate-add-remove. The class of bugs that drove the three smoke iterations stops being possible.
- Lifecycle becomes clean. Archive action does a concrete user-meaningful thing (removes text) that's symmetric with the writer's mental model. Manual text deletion auto-archives for audit trail.
- The .md gets noisier (per-task anchors visible in raw `.md`). Same trade-off paragraph anchors already make; writers don't see them in Maugham itself. Anyone opening the `.md` in a non-Maugham editor will see them.
- Pattern is reusable. Future "manuscript-resident first-class object" milestones (highlighted-comment-style margin notes? line-anchored citations?) can follow the same anchor → strip → mint-on-bootstrap pipeline.

**Negative:**

- Migration cost. Existing test data must be discarded — there's no clean mapping from `(paraId, bodyHash)` synth_ids to anchor-based ones. The user has explicitly okayed test data deletion (CLAUDE.md tripwire #11 / this conversation).
- `.md` files become harder to grep with vanilla tools. `rg '- \[ \] tighten'` still works but the writer sees an HTML-comment suffix on each match.
- Stripping anchors from display is a critical seam. A bug here drops anchors from the `.md` on autosave, killing identity. Implementation needs aggressive round-trip tests.

**Neutral:**

- Op log shape doesn't change. Existing op kinds (`.taskCreate`, `.taskArchive`, etc.) keep their semantics; only the identity inside `provenance.taskId` changes form.
- MCP read tools (`list_tasks`, `get_task`) need no schema change. The `id` field surfaces the new shape; consumers don't care about the internal structure.

## Instances at time of writing

- **Tasks** (this ADR): inline anchors `<!--t-XXXX-->` for `- [ ]` lines and `[[todo: …]]` segments. Implementation pending.
- **Paragraphs** (precedent): inline anchors `<!-- ¶XXXX -->` for each paragraph. Established before milestone-1a; load-bearing across the entire OpLog architecture.

Other manuscript-derived data:
- **Annotations** are already first-class — `add_note` mints an op id; identity persists via the op log. Not text-derived, so this ADR doesn't change them.
- **Scene navigator** entries (Fountain) are text-derived but have no per-scene lifecycle beyond display position. Stay text-derived.
- **Find-and-replace match spans** are text-derived and transient. Stay text-derived.

## Decisions settled in design conversation (2026-05-25)

- **Anchor length: 6 chars.** 4 chars (~1M space) had birthday collision after ~1000 anchors per doc — within realistic novel-writing range. 6 chars (~1B space) is safe to ~30K anchors per doc.
- **Alignment tier: V2 (cursor-bias cross-paragraph).** Threads pre/post cursor through `setFullText`; cross-paragraph correlation catches cut/paste of any size including whole-paragraph moves. Residual: delete-then-retype-the-same-thing is treated as a new task. Documented and accepted.
- **Anchor density in `.fountain`** is acceptable because anchors are invisible in Maugham's render; they're only visible if you cat the file. Clean-export action (roadmap item) generates anchor-stripped copies in `Exports/` for sharing.

## Open questions

- **Cross-Mac merge anchor uniqueness.** Two Macs mint the same anchor for two different tasks → collision. Realistically prevented by entropy (1B space, two random draws collide ~vanishingly rarely) but not impossible. If it bites, salt the anchor with a per-device prefix. Defer.
- **Tier V3 alignment (delete-then-retype detection).** Hooking into `NSTextStorageDelegate` for full edit-range tracking. Not in this milestone. Additive upgrade if V2 turns out to leak the residual case enough to matter.

## References

- Companion spec: `docs/superpowers/specs/2026-05-25-task-anchors-and-lifecycle.md`
- Supersedes the identity model in: `docs/superpowers/specs/2026-05-23-tasks-design.md` §3.2
- Builds on the strip/restore pattern from paragraph anchors: `Maugham/OpLog/RenderFilter.swift`
