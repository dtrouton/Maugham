# Document Operation Log — Design Spec

**Status:** Approved 2026-05-17 by user, ready for implementation planning.

**Goal:** Make a per-document append-only operation log the source of truth for manuscript content. The `.md` file on disk becomes a derived artifact, materialized from the log on a fast path. Establishes the foundation that downstream editing features (annotations, accept/reject, craft principles) will build on.

**Why now:** Earlier editorial-conversation thinking exposed that the current "the `.md` is the manuscript" model can't durably hold annotations or remember rejected suggestions across sessions. We need a substrate where the editorial conversation is queryable, restorable, and survives across Maugham instances on different Macs.

**What this spec does *not* cover:** the annotation schema, the suggestion / accept / reject UX, the `craft_principles.md` foundation, the editing-history UI. Those build on top of this log and ship as separate milestones.

---

## 1. Data Model

### 1.1 On-disk layout

```
<project>/
├── manuscript/
│   ├── chapter-01.md          ← derived artifact, includes inline ¶ IDs
│   └── chapter-02.md
├── .maugham/
│   ├── ops/
│   │   ├── doc-a3f9b2.jsonl           ← per-document append-only op log
│   │   ├── doc-a3f9b2.pending.jsonl   ← in-flight burst buffer (transient)
│   │   └── doc-c81e44.jsonl
│   ├── checkpoints.jsonl              ← project-wide named checkpoint roll-up
│   └── conflicts/                     ← external-edit conflict backups (existing)
```

### 1.2 Op envelope

One JSON object per line of `<doc-id>.jsonl`. JSONL is forgiving — a truncated trailing line on crash does not corrupt earlier entries.

```json
{
  "op_id": "01HZK7...",
  "doc_id": "doc-a3f9b2",
  "at": "2026-05-17T14:33:12.512Z",
  "device": "macbook-pro-1",
  "session": "session-uuid",
  "kind": "typing_burst | claude_suggestion | claude_accept | claude_reject | external_edit | checkpoint | checkpoint_restore | bootstrap",
  "changes": [
    {
      "paragraph_id": "¶a3f9",
      "prior": "...",
      "next": "..."
    }
  ],
  "sequence": ["¶a3f9", "¶b21c", "¶c1ee"],
  "provenance": { ... }
}
```

Field notes:

- `op_id` is a ULID: timestamp-prefixed, lexicographically sortable, globally unique. Provides deterministic cross-device ordering without clock-drift surprises.
- `changes` is an array — a burst can touch multiple paragraphs in one op.
- `prior` is optional but stored for fast diff display in the editorial history UI.
- `sequence` is optional. Present when the burst changed paragraph ordering (insert, delete, reorder); absent when only existing paragraphs were edited in place. When absent, sequence is unchanged from the prior op.
- `provenance` is `kind`-specific:
  - `claude_*`: session id, prompt context, tool args.
  - `external_edit`: synthesis source (e.g. `disk_content_at_ingest`), the orphan-recovery method used (`id_preserved` / `shingle_match` / `unmatched`).
  - `checkpoint_restore`: pointer to the source checkpoint.
  - `bootstrap`: marker only.

### 1.3 Checkpoint roll-up

`.maugham/checkpoints.jsonl` is a project-wide append-only log of labeled checkpoints. **All checkpoints are project-scope.** Restore scope is selected at restore time, not capture time.

```json
{
  "checkpoint_id": "cp-01HZK...",
  "label": "end of draft 2",
  "label_source": "user | auto",
  "at": "2026-05-17T15:00:00.000Z",
  "device": "macbook-pro-1",
  "active_doc": "doc-a3f9b2",
  "doc_pointers": {
    "doc-a3f9b2": "op-01HZK...",
    "doc-c81e44": "op-01HZJ..."
  },
  "manuscript_word_count": 42301
}
```

`active_doc` records which document was active at capture time. The History UI shows this as context (`"saved while editing Ch 3"`) and the partial-restore picker uses it as a smart default scope.

A breadcrumb `checkpoint` op also lands on the active doc's log so that doc's in-line history shows when the project was checkpointed. The actual captured state lives in `checkpoints.jsonl` via `doc_pointers`; the in-doc op is a marker only, not the capture itself.

### 1.4 Inline paragraph IDs

Each paragraph in the `.md` is preceded by an HTML comment:

```markdown
<!-- ¶a3f9 -->

The morning began with the smell of toast burning, which Lisa took as a sign.

<!-- ¶b21c -->

She opened the window.
```

- IDs are short ULID-derived strings, 4 chars after `¶`. Per-doc collision risk is negligible at any realistic scale.
- The editor's render filter hides the comments visually; round-trips them on edit so they're preserved in saves.
- Pandoc strips HTML comments by default — they disappear in compiled PDFs / EPUBs.
- External tools that preserve the comment lines (most do) keep IDs anchored to their paragraphs through external edits.

---

## 2. Operational Flow

### 2.1 Five distinct events

| Event | Trigger | Effect |
|---|---|---|
| **Paragraph change tracked** | Editor text change | In-memory only: update `currentDocumentText`, mark touched paragraph IDs as dirty in a per-doc `pendingChanges` buffer. No disk writes. |
| **Materialization (autosave)** | 750 ms debounce after any text change | Write the current derived `.md` to disk via NSFileCoordinator. Write the pending buffer to `<doc-id>.pending.jsonl`. Does **not** emit a typing_burst op. |
| **Burst boundary** | 30 s typing-idle OR 90 s max-duration OR doc-switch OR window-close | Fold `pending.jsonl` into the main `<doc-id>.jsonl` as one `typing_burst` op. Delete `pending.jsonl`. Clear in-memory buffer. |
| **Checkpoint** | ⌘S (auto label) or Shift-⌘S (prompted label) | Force-flush any pending burst, emit a `checkpoint` op on the active doc's log, append an entry to `.maugham/checkpoints.jsonl` with cross-doc pointers, flash the existing ⌘S indicator. |
| **Claude action via MCP** | MCP tool call | Emit a `claude_suggestion` / `claude_accept` / `claude_reject` op with provenance. Materialization happens normally on accept. |

### 2.2 Dual-cadence safety: the pending buffer

The `.md` materializes every 750 ms; ops append every ~30 s. To prevent a hard-crash from losing the 0–30 s of typing in between:

- Every 750 ms autosave also writes the current burst buffer (paragraph_ids dirtied so far + their current text) to `.maugham/ops/<doc-id>.pending.jsonl` via NSFileCoordinator.
- On burst boundary, the pending file is folded into the main `<doc-id>.jsonl` as one `typing_burst` op, and the pending file is deleted.
- On open after a crash: if `pending.jsonl` exists, replay it into a properly-classified `typing_burst` op closed at "now." No data lost; editorial intent preserved.

The pending file is tiny (a handful of JSON lines), and the cadence of writes is unchanged from today's autosave.

### 2.3 Derivation algorithm

Turning a doc's op log into rendered markdown:

```
state = {}          // paragraph_id -> latest text
sequence = []       // ordered paragraph_ids

for op in log_in_op_id_order:
    for change in op.changes:
        state[change.paragraph_id] = change.next
    if op.sequence:
        sequence = op.sequence

markdown = ""
for pid in sequence:
    markdown += "<!-- " + pid + " -->\n\n" + state[pid] + "\n\n"
```

Linear in total changes (not unique paragraphs); materialization is linear in unique paragraphs. See Section 6 for the at-scale numbers.

### 2.4 Editor integration

- `EditorHost` already drives `DocumentStore.scheduleSave(path:text:)`. We add a sibling `DocumentStore.recordParagraphChanges(paragraphIds:)` that drives the burst buffer.
- `DocumentStore` gains a `BurstScheduler` (mirrors the existing `DebounceScheduler` shape) parameterized by 30 s idle / 90 s max-duration.
- Autosave path is unchanged at the disk layer — it still writes the `.md` atomically via NSFileCoordinator. The only difference is what bytes get written: the log-derived form computed in-memory from buffer + log.

### 2.5 Detecting which paragraphs were touched

On burst-boundary flush, re-parse the current text into paragraphs and diff against the last-flushed state to identify changed paragraph IDs. Cheap (~milliseconds for prose-size docs); avoids tying the burst layer to NSTextView range-change internals.

The editor never tries to identify touched paragraphs per-keystroke. The buffer just accumulates "we have unflushed changes since the last burst" — the actual paragraph-id discovery happens once, at flush time.

---

## 3. Reconciliation

Two reconciliation paths because cross-Mac sync and external-tool edits are different problems.

### 3.1 Cross-Mac via iCloud — log merge, transparent

Op log files are append-only JSONL with globally-sortable `op_id`s. iCloud syncs them as ordinary files. The merge algorithm on any presenter callback for `<doc-id>.jsonl` (or app open):

1. Reload the file.
2. Deduplicate by `op_id`.
3. Sort by `op_id` (timestamp-prefixed; deterministic across devices).
4. Re-derive the paragraph-id → latest-text map.
5. Re-materialize the `.md` and reload the editor view if the doc is open.

**No conflict UI fires for this case.** The user's experience: open Maugham on Mac B after writing on Mac A, and the edits are just there.

**Edge case:** if both Macs edit the same paragraph offline, only one survives (last-write-wins by `op_id`). The losing burst remains in the log — it's just superseded — so the writer can recover the lost text via history scrub if they notice. A future enhancement could detect "both Macs touched ¶a3f9 since they last synced" and surface a per-paragraph merge sheet; not in V1.

### 3.2 External-tool edits — conflict sheet, rare path

On presenter callback for the `.md` itself: re-derive expected state from the log, compare to disk.

- **Disk == derived:** echo of our own write. Ignore.
- **Disk differs, paragraph IDs all intact:** silently ingest as a synthesized `external_edit` op, one per touched paragraph. No UI. The diff is unambiguous because every paragraph still has its `¶id` and we can attribute changes precisely.
- **Disk differs, IDs missing or scrambled:** surface a sheet. *"This file was modified outside Maugham — N paragraphs match by content (will be re-anchored), M look new, K look orphaned. Ingest the changes or revert to log-derived?"*

### 3.3 Content-similarity fallback for orphan recovery

When IDs go missing, re-anchor by content similarity in two passes:

1. **Exact-hash pass.** Compute normalized content hash (whitespace stripped, lowercased) for each unidentified paragraph. Match against the prior derived state. Exact matches reattach the original ID.
2. **Shingle-similarity pass.** For still-unmatched paragraphs, compute k-shingle Jaccard similarity (k = 4 words) against the unmatched-from-prior set. Highest similarity above 0.6 wins. Reattach the ID.

Paragraphs that don't match either pass mint new IDs. The op log carries an `external_edit` op flagging the orphan paragraphs by ID so the downstream editing layer can surface a triage tray for any annotations attached to them.

---

## 4. Checkpoints and Restore

### 4.1 Capture: always project-scope

⌘S and Shift-⌘S capture the entire project state. There is no per-document checkpoint. Capture scope is constant; restore scope is selected at restore time.

| Trigger | Label |
|---|---|
| **⌘S** | auto: `"14:33 — 42,301 words (Ch 3)"` (timestamp + project word count + active doc) |
| **Shift-⌘S** | sheet prompts for a user label |

The active doc is recorded as metadata on the checkpoint for context, not for scope.

### 4.2 No auto-checkpoints

Auto-checkpoint-every-N-words is explicitly rejected. The whole point of a labeled checkpoint is "you said this moment matters." Finer-grain restore is available through burst-history view; explicit safe points come from ⌘S.

### 4.3 Restore is append, never rewrite

When the user picks "Revert to checkpoint X" from the History UI:

1. Compute derived state at `cp-X` for the doc(s) in scope — walk each doc's log up to and including the op whose id equals `cp-X.doc_pointers[doc_id]`, and build the paragraph-id → text-at-X map.
2. Diff against current derived state. Build a list of paragraph changes (`prior` = current, `next` = at-X).
3. Emit one `checkpoint_restore` op per affected doc carrying the changes, with `provenance` referencing `cp-X`.
4. Re-materialize the affected `.md` files.

The log stays append-only. The previous state isn't gone — it's still reachable via another restore back to a later `op_id`.

### 4.4 Partial restore

The restore picker scopes to:
- **Whole project** (all docs in the checkpoint),
- **Single document** (default to the checkpoint's `active_doc`),
- **Single paragraph** (selectable from the doc's paragraph list at that checkpoint).

Per-paragraph restore is a single-element `checkpoint_restore` op. Useful for "revert just this line, keep everything else."

### 4.5 History UI sketch (for downstream milestone)

A `History` segment in the right pane shows a reverse-chronological list of project-wide checkpoints. Tap to preview state at that point (read-only); "Revert here" emits the restore. A secondary `Burst history` view shows all ops (every typing_burst, claude_*, external_edit) for forensic time-scrub. The pane's full UX is out of scope here.

---

## 5. Migration

### 5.1 Per-document bootstrap pass

The first time Maugham opens a manuscript that lacks tracking infrastructure (no `<!-- ¶id -->` comments, no `<doc-id>.jsonl`):

1. Parse the `.md` into paragraphs (blank-line separation, standard markdown).
2. Mint a fresh ULID-derived paragraph ID for each.
3. Atomically rewrite the `.md` with `<!-- ¶id -->` comments above each paragraph.
4. Emit a single `bootstrap` op into the new log, carrying the full paragraph_id → text map as one big `changes` array, plus the initial sequence.
5. Append a `bootstrap` entry to `checkpoints.jsonl` with `label = "Initial — pre-tracking content"`, `label_source = auto`.

Silent per-document; takes milliseconds for typical chapters.

### 5.2 One-time project-wide notice

The first time a user opens any manuscript after upgrading Maugham, surface a one-time dismissable notice: *"Maugham now tracks paragraph-level edit history. Invisible marker comments will be added to your manuscript files the first time each is opened. Existing content is preserved exactly; only the inline IDs are new."*

The flag for "shown this notice" lives in `.maugham/ui-state.json`.

---

## 6. Performance at Scale

### 6.1 Worst-case projection

A 5-year-old project with a heavy writer:

- ~1,500 writing sessions × ~100 typing_burst ops/session = 150,000 burst ops
- ~50 Claude actions/session × 1,500 = 75,000 Claude ops
- ~3 checkpoints/session × 1,500 = 4,500 checkpoint ops
- **Total: ~230K ops, distributed ~1,500 per chapter on average across 200 chapters**

### 6.2 File sizes

Per-doc op log: ~1,500 ops × ~800 bytes avg = ~1.2 MB. iCloud syncs each on append; deltas are single-line.

`checkpoints.jsonl`: ~4,500 entries × ~400 bytes = ~1.8 MB. One file, but small.

### 6.3 Derivation cost

Per-doc derivation is linear in that doc's op count. At ~1µs per dictionary write, a 1,500-op chapter derives in **<5 ms**. The whole-project worst case (rederive everything from scratch) is ~230 ms, but is needed only once per project open and only when the doc was never derived in this session.

### 6.4 Escape valve (not for V1)

If a doc's derivation ever exceeds ~50 ms, generate `.maugham/ops/<doc-id>.snapshot.json` every 5,000 ops carrying the derived state at that point. Open-time derivation starts from the latest snapshot + replays only ops since.

**Do not implement in V1.** From the projection above, the threshold won't be hit for years and may never be.

### 6.5 Corruption tolerance

JSONL is robust to trailing-line truncation. The reader skips unparseable lines and surfaces a count in the conflict path: *"3 trailing operations could not be read and were dropped. Backed up to `.maugham/conflicts/`."* The pending buffer covers the in-flight typing case.

---

## 7. Future Extension: Real-Time Collaboration

Recorded so the V1 architecture doesn't paint us into a corner.

**What carries forward unchanged if real-time multi-writer collab is ever added:**

- The op log format (append-only JSONL, ULID-ordered, per-doc).
- ULIDs as deterministic cross-device ordering.
- Inline paragraph IDs as identity anchors.
- The `.md` as derived artifact.
- Checkpoints, restore-as-append, the external-tool conflict UI.

**What would need to evolve — exactly one thing:**

The within-paragraph merge semantics. Today's per-paragraph last-write-wins is correct for solo-writer-cross-Mac but lossy for two writers in the same paragraph simultaneously. The fix is **additive**: introduce a new op kind (e.g. `character_op` with CRDT-style position tokens) that coexists with `typing_burst`. The loader fan-outs by op kind — paragraph-LWW ops merge as today, character ops merge with CRDT semantics within their paragraph. Existing manuscripts and existing log entries stay valid.

**What would be additive on top:**

- Sub-second sync transport (Yjs / Automerge / websocket relay) layered on top of iCloud, not replacing it. Local-first remains intact.
- Awareness primitives (cursor positions, selections, "X is typing"). Ephemeral, never logged.

**Rough scope if pursued:** two milestones. One to add character-op support and the dual-mode merge function. One to add transport + awareness UI. Existing manuscripts don't migrate; they keep using paragraph ops, and new collab edits lay character ops on top.

**The thing that would have been a step change but isn't:** the paragraph-keyed op model was chosen partly because it's CRDT-adjacent. Document-snapshot or diff-per-op would have required throwing out the foundation.

---

## 8. Explicitly Out of Scope for V1

- The editing annotation schema (`suggested_change`, `comment`, `query`, `craft_note`). Builds on this log as `claude_*` ops with provenance, ships as a separate milestone.
- Accept / reject UI for suggestions. Downstream.
- `craft_principles.md` and project-level context loading. Downstream.
- Per-character CRDT-style fine granularity. Explicitly rejected per §2 (the burst-boundary decision).
- Real-time collaborative editing. Future extension per §7.
- Snapshot files for derivation speedup. Add when measured, not before.
- History rewriting / jj-style operations on operations. Restore-as-append covers every case identified; consider V2 only if a real need emerges.
- Per-paragraph merge sheet for concurrent same-paragraph cross-Mac edits. V1 accepts LWW.
- Compile pipeline integration. Pandoc strips HTML comments by default; the inline IDs vanish on compile without any extra work.

---

## 9. Decisions Locked

For traceability — the choices the brainstorm crystallized, with their rationale:

| # | Decision | Rationale |
|---|---|---|
| 1 | Per typing-burst + Claude action granularity (30 s idle / 90 s max) | Sweet spot between forensic detail and editorial-conversation readability. |
| 2 | Cross-Mac = log merge; external-tool = conflict UI (auto-ingest when IDs intact) | Treats two genuinely different problems with two appropriate mechanisms. |
| 3 | Paragraph-keyed last-write-wins ops | Trivially fast derivation, natural anchor for annotations, CRDT-adjacent for future collab. |
| 4 | Inline HTML-comment paragraph IDs + content-similarity fallback | Identity travels with content; orphan recovery covers edge cases. |
| 5 | Always-project-scope checkpoint capture; restore scope chosen at restore time | Capture and restore scoping are independent; capture should match writer's mental model. |
| 6 | Append-only log; restore-as-append (V1, no jj-style history rewriting) | Simpler model; restore-as-tag covers every concrete need. |
| 7 | Per-doc ops + project-wide checkpoints (hybrid layout) | Per-doc keeps iCloud deltas small and isolates corruption; project-wide checkpoints enable whole-novel snapshots. |
| 8 | Pending buffer at 750 ms cadence for dual-cadence safety | Preserves data safety unchanged; preserves editorial classification through crashes. |
| 9 | Silent per-doc bootstrap + one-time project notice | Migration is unobtrusive; user is informed once that the file format gained inline IDs. |
