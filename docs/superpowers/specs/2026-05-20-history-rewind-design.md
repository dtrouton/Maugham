# History Rewind — Design Spec

**Status:** Approved 2026-05-20 by user, ready for implementation planning.

**Goal:** Ship first-class time travel over the per-doc op log. A writer can open a dedicated **Rewind** modal, scrub through every past op of the active document with read-only preview (doc view or diff toggle), and from any past point either **Snapshot** that moment as a labelled project-scope checkpoint or **Restore** the live document to it. Secondary: a per-row "↺" button in HistoryPane that opens the same modal pre-positioned at that op, for fast few-minutes-back recoveries.

**Why now:** The op-log infrastructure shipped in `milestone-document-operation-log` and `milestone-editing` makes time travel comparatively cheap to implement — the data is already an append-only event stream, the deriver already replays from start, and `checkpointRestore` already exists as an op kind. The HistoryPane shows the unified timeline today but only checkpoint rows offer "Revert here…". This milestone closes the loop: any past point is reachable; any past point can be snapshotted or restored.

**Why this specific design:** The user's framing is *experimentation*: writers want to draft, revisit past states, decide whether to keep the new work or go back, and capture a past moment as a checkpoint when they realize after the fact that they should have marked it. The scrubber affordance gives them exploration; the two terminal actions (Snapshot / Restore) cover both "remember this moment for later" and "actually go back." Per-row revert covers the lighter-weight "I know roughly where I want to go" path. All three end-states reuse existing machinery (`CheckpointStore.append`, `checkpointRestore` op kind, the orphan-annotation sweep). The new code is concentrated in one place (the modal UI) plus tight typed value contracts at the seams.

**What this spec does NOT cover (deferred to v2 / future):**
- Project-scope rewind (scrubbing across multiple docs' op logs simultaneously). v1 is per-doc.
- Live update of the scrubber as new ops arrive (e.g. an MCP write from Claude during a scrub session). v1 snapshots the op log at modal-open.
- An "un-archive annotation" lifecycle action for annotations auto-archived during a rewind that the writer later wants back. v1 archives are terminal until v2 ships the inverse.
- Keyboard shortcut for opening the modal (e.g. ⌘⌥R). Not opposed but not load-bearing for the milestone.

**Conformance contract:** must not regress any test currently green (`~770 tests + 10/10 EditorIntegrationHarness`). All existing `PresenterRoutingTests`, `BootstrapWiringTests`, `MCPCatalogConsistencyTests` continue passing — rewind doesn't add a new manuscript-load entry point, doesn't add a new MCP tool, doesn't change the editor's binding contract.

---

## 1. Architecture overview + scope

### 1.1 Surface

A new SwiftUI modal: `Maugham/Views/RewindWindow.swift`. Opened via:

1. **HistoryPane "Rewind…" header button** (primary entry point — opens the modal at "now" so the writer can scrub freely).
2. **HistoryPane per-row "↺" icon button** (secondary entry point — opens the modal pre-positioned at that op).

Sheet-style fullscreen-feel overlay. ESC dismisses without action. The modal is opened from `ProjectWindow` via a `@State` flag, presented with `.sheet(isPresented:)` so it composes with the rest of the SwiftUI hierarchy cleanly.

### 1.2 Scope (v1)

**Per-document.** The scrubber walks the active doc's op log. The terminal actions operate at the project-checkpoint granularity by populating `Checkpoint.docPointers` correctly — `docPointers[activeDocId] = scrubOpId`, all other docs = their current `latestOpId`.

**Why not project-wide v1**: scrubbing multiple docs' op logs simultaneously needs a UX answer to "which doc's clock am I on?" and "what if doc B has 200 ops in the window doc A has 5?" The CheckpointStore data model already supports the multi-doc shape, so project-wide is a future UX extension rather than a data refactor. Easier to ship per-doc first and add `.project` if writers actually want it.

### 1.3 Op log semantics

Restore appends a new `checkpointRestore` op carrying the past state's paragraphs as `changes` and the past state's `sequence` as the op's `sequence` field. The op log stays append-only. The `Deriver.derive(ops:)` replay naturally produces the restored state: prior ops apply, the `checkpointRestore` op wipes paragraphs back, any new edits build on the restored state.

A writer can scrub through ops that have been "undone" by a previous restore — they're still in the op log. Restoring to one of them issues another `checkpointRestore` op that re-walks the chain. The op log is the source of truth; checkpoints and rewinds are pointers into it.

### 1.4 Reuse map

| New work | Existing component reused |
|---|---|
| Modal UI | New file (`Maugham/Views/RewindWindow.swift`) |
| State-at-past-op derivation | `Deriver.derive(ops:upTo:)` — new overload on existing `Deriver` |
| Snapshot from rewind | `CheckpointStore.append(_:)` — existing, no changes |
| Snapshot label entry | `CheckpointLabelPromptSheet` — existing |
| Restore from rewind | `Document.restoreToOp(opId:)` — new Document method that wraps appending the `checkpointRestore` op and triggering the sweep |
| Orphan annotation cleanup | Existing `_pendingSweep` / `SweepReason` machinery in `Document` — no changes to the sweep logic itself |
| HistoryPane row rendering of rewind ops | Existing `HistoryRow.resolvedBody` + `kindLabel` switch — add new branches for `synthesisSource == .rewind` |

---

## 2. Scrubber + preview UI

### 2.1 Modal layout (header → scrubber → preview → footer)

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Rewind — Tank Park Salute                                  [×]           │
├──────────────────────────────────────────────────────────────────────────┤
│ REWINDING                                                                │
│ Wed 2:14 PM · 47 ops ago · between Day 2/3 burst and Claude's comment    │
│                                              ┌──────┬──────┐             │
│                                              │ Doc  │ Diff │             │
│                                              └──────┴──────┘             │
├──────────────────────────────────────────────────────────────────────────┤
│ Mon morning      Tue 9 AM       Wed 12 PM       Today 3 PM      [Now]   │
│ ▼                                                                        │
│ │█│ │█│█│ ❙ │█│█│█│█│█│ ◆ │█│█│█│ ▼ │█│█│ ❙ │█│█│█│ ◆ ◆ ◆ │█│█│ █│      │
│ typed   checkpoint   Claude annotation   external edit                   │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  # Tank Park Salute // Billy Bragg                                       │
│                                                                          │
│  At the top of the stairs is darkness. And there is something in it…     │
│                                                                          │
│  I was having bad dreams. I could never tell my mum what it was that…    │
│                                                                          │
│  ## Day 1/3                                                              │
│  …                                                                       │
│                                                                          │
│              [— preview of doc as it was at this point —]                │
│                                                                          │
├──────────────────────────────────────────────────────────────────────────┤
│ Restoring would undo 2,341 words / 47 paragraphs. 3 annotations would    │
│ be auto-archived.                                                        │
│                              [Cancel] [Snapshot here…] [Restore here…]   │
└──────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Scrubber behaviour

- Click anywhere on the scrubber bar to jump; drag for continuous scrub.
- Op ticks color-coded by kind:
  - **typed** (`typing_burst`, `bootstrap`): blue (`#88aabb`)
  - **checkpoint** (`checkpoint`, `checkpoint_restore`): green (`#6ce0a8`), taller than other ticks
  - **Claude annotation** (`claude_comment`, `claude_suggestion`, `claude_query`, `claude_craft_note`, `claude_accept`, `claude_reject`, `claude_archive`): orange (`#ffa940`)
  - **external** (`external_edit`): purple (`#c590f0`)
- The current scrub position is a purple cursor with a downward chevron at the top.
- The right edge of the scrubber is anchored "Now" with a small label.
- Hovering a tick shows a tooltip with op kind, timestamp, and a one-line summary (for annotations: the body; for typing bursts: the number of paragraphs touched; for checkpoints: the label).

### 2.3 Density (smart visual clustering)

For a doc with hundreds of ops, the scrubber width can't render every tick distinctly. Rules:

- If two ops are within ~1px of each other at the current scrubber width, only the first tick is drawn; the underlying ops are still scrubbable by drag (the modal computes the nearest op to the drag-x position).
- Checkpoint ticks always draw at full height (`+2px` taller than others); they're navigation landmarks the writer needs to see even in dense ranges.
- Pan / zoom is **not** in v1 scope — the auto-density rule is the only adaptive behaviour. Pan/zoom is a known refinement (carry-forward) but unlikely to be needed until docs grow past ~1000 ops.

### 2.4 Header context line

Live-updated as the cursor moves. Format: `{absolute time} · {ops since now} ago · {between ops description}`. Examples:

- `Wed 2:14 PM · 47 ops ago · between Day 2/3 burst and Claude's comment`
- `Mon 10:33 AM · 412 ops ago · just before the first checkpoint`
- `Today 3:12 PM · 4 ops ago · 2 paragraphs into the latest burst`

The "between" descriptor uses neighbouring ops' kind labels + any human-meaningful name (checkpoint labels, claude annotation bodies). Format function in `RewindWindow.Helpers`.

### 2.5 Preview toggle (Doc / Diff)

Top-right of the header. Default = **Doc**.

- **Doc**: clean prose, no inline diff colors. The manuscript as it was. Optimized for re-reading and recognition.
- **Diff**: paragraphs that would be removed on restore shown with red strikethrough; paragraphs that would come back shown with green underline. Inline word-level diff inside paragraphs that exist in both states but differ. Optimized for impact assessment.

The toggle is a binary `PreviewMode` enum carried in modal `@State`. Switching is instant (no re-derive needed — both views project from the same `RewindRestoreResult` shape held in modal state).

### 2.6 Preview area

Read-only manuscript view. Plain prose styled with the user's current typography. No editing affordances (no cursor, no selection beyond passive text selection for copy). Renders the same way as the editor's display layer (re-uses `RenderFilter.stripComments` to drop the `<!-- ¶id -->` anchors that exist in the materialized form).

For very long docs: the preview is scrollable. The scroll position resets to the top when the scrub cursor moves (so the writer always sees the doc's beginning at the new state — they can scroll down if they want to find a specific paragraph).

### 2.7 Action footer

Three buttons + an impact summary line:

- **Cancel** (secondary) — dismisses the modal. Equivalent to ESC.
- **Snapshot here…** (secondary) — opens the existing `CheckpointLabelPromptSheet` with a default label suggestion (see §3.2).
- **Restore here…** (primary, purple) — opens a small confirm sheet (see §3.3).

The summary line: `Restoring would undo {N} words / {M} paragraphs since this point. {K} annotations would be auto-archived.` Numbers computed from `RewindRestoreResult.previewSummary`. Hidden when `RewindCursor == .now` (no impact at "now").

---

## 3. Action behaviour (Snapshot / Restore)

### 3.1 Pending-burst handling on modal open

Before showing the scrubber: call `Document.flushBurstNow()` on the active doc. Reasons:

1. The "Now" anchor needs to reflect the writer's latest typing — otherwise scrubbing to "now" lands at a stale tip.
2. The scrubber's tick layout is computed from `_opLogMirror`; flushing ensures the mirror contains the latest user input.
3. If the writer types a few more characters between opening the modal and scrubbing, those edits are lost in the modal's view but still preserved in the live editor (since the modal opens with a snapshot of the op log at open-time; user edits during the modal session don't appear until close + reopen).

The modal then snapshots `_opLogMirror` at open-time into an `let ops: [Op]` field — *not* a binding to the live mirror. This is intentional: the modal's view of history is frozen at open-time. v2 could live-update.

If MCP writes (Claude annotations) arrive while the modal is open, they don't appear in the timeline. v1 simplification.

### 3.2 Snapshot here

The writer scrubs to a past op X, hits "Snapshot here…":

1. Opens `CheckpointLabelPromptSheet` with default label suggestion: `"Snapshot of {docTitle} at {scrub date} {time}"` — e.g. `"Snapshot of Tank Park at Wed 2:14 PM"`. Writer can edit before confirming.
2. On confirm: constructs a new `Checkpoint` with:
   - `id` = fresh ULID
   - `at` = `Date()` (the moment of snapshot creation, not the scrub op's timestamp — the snapshot itself is a present-time action)
   - `label` = the writer's input
   - `labelSource` = `.user`
   - `manuscriptWordCount` = computed from the past state's text (the rewound doc plus current text of all other docs)
   - `activeDoc` = `activeDocId`
   - `docPointers[activeDocId] = scrubOpId`
   - `docPointers[otherDocId] = otherDoc.latestOpId` for every other doc in the project
3. `CheckpointStore.append(checkpoint)`. Posts `.maughamCheckpointAdded` so HistoryPane refreshes.
4. Modal closes. Live editor is unchanged.

The new checkpoint appears in HistoryPane immediately. Reverting to it through the existing checkpoint-row "Revert here…" flow restores doc A to scrubOpId via `PartialRestorePicker` — same path as any other project-scope checkpoint restore.

**Mental model:** "I'm marking this past moment of THIS doc as a project-scope snapshot. Other docs are captured at their current state."

### 3.3 Restore here

The writer scrubs to a past op X, hits "Restore here…":

1. Inline confirm sheet (not full `PartialRestorePicker` — see §3.4 below):
   > Restore **Tank Park** to **Wed 2:14 PM**?
   > 
   > This will undo **2,341 words / 47 paragraphs** written after this point. **3 annotations** will be auto-archived (you can find them in History under the Annotations filter).
   > 
   > `[Cancel]` `[Restore]`
2. On confirm: `Document.restoreToOp(opId:)`:
   - Derives state-at-X via `Deriver.derive(ops: _opLogMirror, upTo: .atOp(opId: X, at: opTime))`.
   - Appends a `checkpointRestore` op on doc A's log with:
     - `changes` = `[ParagraphChange]` covering every paragraph in the past state (so the deriver replay produces the right paragraphs map)
     - `sequence` = the past state's sequence
     - `provenance.synthesisSource` = `.rewind`
     - `provenance.sourceCheckpoint` = `X` (the scrub op_id, overloading this existing field — see §7.3 for the typed alternative we considered)
   - Updates `self.paragraphs`, `self.sequence` to the past state.
   - Sets `_pendingSweep = SweepReason(removed: priorSequence - newSequence)`.
   - Triggers `flushBurstNow()` immediately so the sweep fires now rather than waiting for the next burst — the writer expects the auto-archives to be reflected when the modal closes.
   - Returns `RewindRestoreResult` (see §7.5).
3. Modal closes; live editor's `displayText` reflects the restored state.
4. autosave 750ms later writes the new `.md`.

### 3.4 Why no PartialRestorePicker for v1 rewind restore

The existing `PartialRestorePicker` exists because checkpoints carry multi-doc state — restoring from a checkpoint reasonably asks "this doc only or all docs?" The History Rewind scrubber is fundamentally **per-doc** (it's walking doc A's op log; doc B's clock isn't synced). There's no second option to pick, so the picker would be a useless dialog with one button.

When v2 ships project-scope rewind, the picker comes back — but for v1 the rewind restore is unambiguous "restore doc A to op X." Checkpoint-row reverts continue to use `PartialRestorePicker` as today.

### 3.5 Edge cases

- *Bootstrap-only doc* — only one op exists; "Rewind…" button disabled. The per-row "↺" button doesn't appear on bootstrap rows.
- *Scrubbing past a previous rewind* — all historical ops are walkable; the prior rewind is just another tick. Restoring through it re-walks the chain.
- *Long op log (10k+ ops)* — scrubber tick decimation kicks in (see §2.3). Preview derivation via `Deriver.derive(ops:upTo:)` is O(N) on op count; should stay <100ms for tens of thousands of ops.
- *Restore to "now"* — `RewindCursor == .now` disables the "Restore here…" button (no-op). Snapshot at "now" is allowed (equivalent to ⌘S — a present-time checkpoint).

---

## 4. Per-row "Revert here…" (the cheap secondary)

### 4.1 Inclusion

Yes in v1. Cost is essentially zero: the per-row button opens the Rewind modal with `RewindCursor.atOp(opId: rowOpId, at: rowOp.at)`. All the heavy lifting (modal, scrubber, preview, action machinery) is shared.

### 4.2 Which rows get the button

Rows whose op `kind` is in the manuscript-mutating set (matches `Deriver.appliesToManuscript`):

- ✓ `typing_burst`
- ✓ `external_edit`
- ✓ `claude_accept` (suggested_change accept that mutated the manuscript)
- ✓ `checkpoint_restore` (a previous rewind; lets the writer "undo the undo")
- ✗ `bootstrap` — reverting to before bootstrap = empty doc, meaningless
- ✗ `checkpoint` — keeps its existing "Revert here…" → `PartialRestorePicker` flow
- ✗ `claude_comment`, `claude_suggestion`, `claude_query`, `claude_craft_note` — no manuscript mutation
- ✗ `claude_reject`, `claude_archive` — no manuscript mutation

### 4.3 UI shape

A small `↺` icon button at the right edge of the row (next to the timestamp), with tooltip *"Rewind to before this point…"*. Always visible — same visual weight as the existing "Revert here…" button on checkpoint rows.

Click → posts the new `.maughamOpenRewind` notification with `userInfo: ["paragraph_id"-style: ..., "scrub_op_id": rowOpId]`. ProjectWindow's `.onReceive` handler opens the modal pre-positioned at the cursor.

> **2026-08-08 amendment (M4-RW-002).** `scrub_op_id` is now the row op's **predecessor** in the
> opId-ordered log, not the row op itself. `derive(upTo:)` is inclusive by contract, so posting the
> row op landed the writer *after* the change they wanted gone — the opposite of the label. Ruled by
> Denver (RULING-22 disposition): fix the behaviour, not the label. A row whose op has no
> predecessor (the first op) offers no deep-link, because "before this" does not exist there —
> `HistoryPane.predecessorIndex`, pinned by `HistoryPaneRewindTargetTests`.

### 4.4 Mental model for the writer

- *Quick path:* HistoryPane → click `↺` on a recent burst → modal opens at that op → glance at preview → confirm Restore → done. ~4 clicks for a "go back 10 minutes" recovery.
- *Deep path:* HistoryPane → click `Rewind…` header button → modal opens at "now" → scrub → preview → Snapshot or Restore. The exploration affordance.

Same modal, two entry points. Header button = "I want to explore." Per-row button = "I know roughly where I want to go."

---

## 5. Annotation + checkpoint interaction

### 5.1 Annotations after a Restore

Annotation creation ops remain in the op log forever (append-only invariant). After a restore, `AnnotationDeriver` re-derives the annotation set from the full `_opLogMirror` + current paragraphs:

- **Survives:** annotations whose `paragraph_id` is still in the post-restore `sequence` (the paragraph existed at the restore point — likely if the writer's later edits didn't substantially rewrite that paragraph). Stays `open`.
- **Auto-archived:** annotations whose `paragraph_id` is missing from the post-restore sequence. The existing sweep machinery handles this via `_pendingSweep = SweepReason(removed: priorSequence - newSequence)`.

Each auto-archive emits a `claude_archive` op with:
- `provenance.synthesisSource = .rewind`
- `provenance.sourceAnnotationId = <annotation op id>`

The HistoryPane row rendering branches on `synthesisSource`: shows *"Auto-archived: paragraph removed by rewind"* for `.rewind` vs *"Auto-archived: paragraph deleted"* for `.paragraphDeleted`.

### 5.2 Checkpoints after a Restore

Unaffected. Checkpoints are project-scope pointers into the op log; they reference op IDs that still exist post-rewind. A writer who rewinds doc A can later restore from a checkpoint that was made *between* the rewind point and the prior "now" — that's effectively "go forward" after a rewind. The op log is the source of truth; checkpoints are pointers into it.

### 5.3 Forensic display

Rewind restore op: `kind=checkpointRestore`, `synthesisSource=.rewind`, `sourceCheckpoint=<past_op_id>`. HistoryPane row renders *"Rewound to Wed 2:14 PM"* (using the scrub op's timestamp) instead of the existing *"Restored from checkpoint '\<label\>'"* used by checkpoint-row reverts.

The discriminator at render-time: if `synthesisSource == .rewind`, it's a rewind; else it's a normal checkpoint restore. Pattern lives in `HistoryRow.collapsedPreview` / `expandedDetail`.

### 5.4 Edge case — paragraph survives rewind, then re-typed similar content

If a paragraph_id was created at T1, the writer rewinds to T0 (before T1), and the paragraph_id no longer exists in the restored state, the sweep archives the annotation. If the writer then re-types similar content and `restoreComments` happens to assign the same paragraph_id again (bigram match), the annotation is still archived — sweep already ran.

**Carry-forward for v2:** an "un-archive" annotation action would let the writer restore archived annotations whose paragraph_id is back in sequence. Out of v1 scope.

---

## 6. Testing strategy

### 6.1 Unit tests

`MaughamTests/OpLog/DeriverUpToTests.swift` — new `Deriver.derive(ops:upTo:)` overload:

1. `test_deriveUpTo_now_returnsFullDerivation` — `.now` cursor returns same result as the no-arg `derive(ops:)`.
2. `test_deriveUpTo_atOp_returnsStateAtThatPoint` — manuscript-only stream, verify paragraphs + sequence at a mid-stream op match what the writer had at that moment.
3. `test_deriveUpTo_atOp_ignoresLaterOps` — adding more ops after the target op_id doesn't change the result.
4. `test_deriveUpTo_atOp_includesAnnotationOps_butSkipsTheirChanges` — annotation creation ops up to the target are included in the walk (so `_hasAnyAnnotationOps` is set correctly) but their `changes.next == ""` is not applied to paragraphs (the existing `Deriver.appliesToManuscript` rule).
5. `test_deriveUpTo_atOp_withPriorRestore_handlesUndoChain` — stream contains a prior `checkpointRestore`; verify the rewind through it produces the right state.
6. `test_deriveUpTo_atOp_atBootstrap_returnsInitialState` — degenerate case.
7. `test_deriveUpTo_atOp_unknownId_returnsNow` — defensive: an op_id not in the stream is treated as `.now` rather than throwing.

`MaughamTests/Views/RewindDensityTests.swift` — tick decimation helper extracted as pure function:

8. `test_decimateTicks_underWidth_returnsAll` — 50 ticks in 1000px width, all rendered.
9. `test_decimateTicks_overWidth_collapsesAdjacent` — 1000 ticks in 600px width, density rule reduces to one tick per px.
10. `test_decimateTicks_checkpointsAlwaysVisible` — even in dense range, checkpoint ticks are never collapsed.

### 6.2 Integration tests

`MaughamTests/Integration/RewindFlowTests.swift`:

11. `test_restoreToPastOp_revertsManuscriptText` — `doc.displayText` reverts to the past state.
12. `test_restoreToPastOp_appendsCheckpointRestoreOpWithRewindSource` — new op has `kind == .checkpointRestore`, `synthesisSource == .rewind`, `sourceCheckpoint == <past_op_id>`.
13. `test_restoreToPastOp_archivesOrphanAnnotations` — annotation on a paragraph that's no longer in post-restore sequence auto-archives with `synthesisSource == .rewind`.
14. `test_restoreToPastOp_preservesAnnotationsOnSurvivingParagraphs` — annotation whose paragraph_id is still in post-restore sequence stays `open`.
15. `test_snapshotFromRewind_createsCheckpointWithMixedDocPointers` — `docPointers[activeDocId] == scrubOpId`, all other docs == their `latestOpId`.
16. `test_rewindThenForwardCheckpoint_canRestoreToPostRewindState` — a checkpoint made between rewind point and "now" remains valid; reverting to it is the "go forward after rewind" path.
17. `test_rewindThenScrubBeforePriorRewind_walksFullHistory` — op log is append-only; scrubbing back through a previous rewind still works.
18. `test_restoreFlushesPendingBurstFirst` — open the modal with an unflushed burst pending; assert the burst lands as an op before the modal computes the timeline.

`MaughamTests/Integration/RewindEntryPointsTests.swift`:

19. `test_headerButtonAndRowButtonRouteSameDocumentMethod` — both entry points call `Document.restoreToOp(opId:)` with the same argument shape; prevents divergent code paths.

`MaughamTests/Integration/RewindForensicProvenanceTests.swift`:

20. `test_restoreOpCarriesRewindSynthesisSource` — verify the restore op's `provenance.synthesisSource` is `.rewind`.
21. `test_sweepArchiveOpsCarryRewindSynthesisSource` — verify sweep-emitted archive ops also use `.rewind`.

`MaughamTests/Integration/SynthesisSourceMigrationTests.swift`:

22. `test_existingOpLog_withStringSynthesisSource_decodesToEnum` — backwards-compat: an op_log.jsonl line with `"synthesis_source": "paragraph_deleted"` (the old shape) decodes correctly into `SynthesisSource.paragraphDeleted`. Important because existing user op logs on disk use the string form.
23. `test_newOpLog_withEnumSynthesisSource_roundTripsViaCodable` — round-trip a synthesized op through encode/decode and verify the synthesisSource value is preserved.

### 6.3 Manual smoke

User-runs-it pattern:

1. Open a doc, type several paragraphs across ~30s (so burst fires).
2. ⌘S to capture a checkpoint mid-stream.
3. Open Rewind via HistoryPane header button. Verify scrubber shows ticks; checkpoints stand taller; color coding is legible; header context line is human-readable.
4. Scrub to a past point. Toggle Doc / Diff. Verify preview matches the past state in Doc mode and shows red/green deltas in Diff mode.
5. Hit Snapshot here, label it. Verify new checkpoint appears in HistoryPane.
6. Reopen Rewind, scrub further back, hit Restore here. Confirm. Verify editor reverts; if there were annotations on now-missing paragraphs, verify they're archived in AnnotationsPane with "Auto-archived: paragraph removed by rewind."
7. Per-row Revert: click `↺` on a typing_burst row in HistoryPane. Verify modal opens pre-positioned. Restore. Verify state.
8. Final smoke: ⌘Q, relaunch, reopen the doc — verify the restored state persists.

### 6.4 Conformance contracts preserved

- Full test suite still green (~770 baseline + ~13 new rewind tests + the existing-tests-touched-by-SynthesisSource-refactor count; should land around 783+).
- `EditorIntegrationHarnessTests` 10/10 — the binding contract is untouched.
- `PresenterRoutingTests` — rewind uses the established echo-guarded write path; no changes needed there.
- `MCPCatalogConsistencyTests` — no new MCP tools.
- `BootstrapWiringTests` — modal doesn't introduce a new manuscript-load path.

### 6.5 Test patterns to follow

- Project-on-disk harness: copy from `OpLog/DocumentTests.swift` (`makeProject(initialMd:)`).
- `ProjectRegistry + DocumentStore + Document` wired: copy from `MCP/Tools/AnnotationCreationToolsTests.swift`.
- Paragraph-id-sensitive tests: 4-char alphabet-restricted IDs per `CLAUDE.md` tripwire #8 (`[0-9abcdefghjkmnpqrstvwxyz]{4}`).

---

## 7. Contract tightening (typed values + seam tests)

Following ADR 0010: every new cross-area value gets a typed shape.

### 7.1 `RewindCursor` (new file `Maugham/OpLog/RewindCursor.swift`)

```swift
internal enum RewindCursor: Equatable, Sendable {
    case now
    case atOp(opId: String, at: Date)
}
```

- The modal's scrub state.
- `.now` and `.atOp(latestOpId, latestDate)` are *not* equivalent — the former means "writer hasn't scrubbed yet"; the latter means "writer scrubbed to the latest op and explicitly chose to land there."
- `Deriver.derive(ops:upTo:)` takes this enum; `.now` returns full derivation, `.atOp(id, _)` returns state-as-of-id.
- Lives in `Maugham/OpLog/` because the deriver consumes it; the views layer imports the OpLog module's public surface.

### 7.2 `RewindAction` (new file `Maugham/Views/RewindAction.swift`)

```swift
internal enum RewindAction: Equatable {
    case cancel
    case snapshotHere(label: String)
    case restoreHere
}
```

- The modal's terminal action. Dispatcher in `ProjectWindow` (or in `RewindWindow`'s `onDismiss` callback) switches over it exhaustively; adding a future action becomes a compile error rather than a missed case.
- The Snapshot label is non-optional in the `snapshotHere` case — matches the `CheckpointLabelPromptSheet` contract that the writer must confirm a label.

### 7.3 `SynthesisSource` (new file `Maugham/OpLog/SynthesisSource.swift`) — refactor in scope

Currently `Op.Provenance.synthesisSource: String?` carries `"paragraph_deleted"`, `"disk_at_ingest"`, `"use_cloud_resolution"`. This milestone adds `"rewind"`. Type it:

```swift
public enum SynthesisSource: String, Codable, Equatable, Sendable {
    case paragraphDeleted = "paragraph_deleted"
    case diskAtIngest = "disk_at_ingest"
    case useCloudResolution = "use_cloud_resolution"
    case rewind
}
```

`Op.Provenance.synthesisSource: SynthesisSource?` (was `String?`). Codable raw value is the snake_case string, so:

- Existing op logs on disk with `"synthesis_source": "paragraph_deleted"` decode to `.paragraphDeleted` automatically (raw-value Codable handles this).
- New ops encode the same string values, so cross-Mac sync to an older client wouldn't break (forwards-compat).
- Decoding an unknown raw value (e.g. a future `synthesis_source` value) decodes to `nil` per `RawRepresentable` semantics — the field is optional, so this is the right failure mode.

Touches:
- `Op.swift` — change the field type, update `init` signature.
- `Document.swift` — `sweepOrphanedAnnotations` emit site (currently writes `"paragraph_deleted"`), all four external-change handler emit sites.
- `HistoryRow.swift` — branch in collapsed/expanded preview already reads `synthesisSource`; switch from string comparison to enum case match.
- Tests touching synthesisSource — `OpTests.swift` Provenance encode/decode test, the existing `DocumentAnnotationCacheTests` orphan-archive test that asserts `synthesisSource == "paragraph_deleted"`.

Backwards-compat is asserted by `SynthesisSourceMigrationTests` (§6.2 test 22).

### 7.4 `RewindScope` (new file `Maugham/Views/RewindScope.swift`)

```swift
internal enum RewindScope: Equatable, Sendable {
    case thisDoc      // v1 — only inhabitant
    // case project   // v2 — exhaustive switch will require handling when added
}
```

Single-case enum looks gratuitous but it's the right shape: when `.project` lands in v2, every consumer that switches over `RewindScope` becomes a compile error and we don't miss a code path. ADR 0010 pattern applied prospectively.

### 7.5 `RewindRestoreResult` (returned by `Document.restoreToOp`)

```swift
internal struct RewindRestoreResult: Equatable {
    let restoreOp: Op                  // the appended checkpointRestore op
    let archivedAnnotationOpIds: [String]  // op ids of claude_archive ops emitted by sweep
    let removedParagraphIds: [String]  // paragraphs that no longer exist post-restore
    let priorSequenceCount: Int        // pre-restore paragraph count, for the impact summary
    let newSequenceCount: Int          // post-restore paragraph count
}
```

`Document.restoreToOp(opId: String) async throws -> RewindRestoreResult`. The modal uses the result to show a confirmation toast (*"Restored. 3 annotations auto-archived."*) and to display the impact summary in the action footer pre-restore. Tests assert the full effect from one return value.

### 7.6 Seam tests (owned by neither side)

Three explicit cross-area tests beyond the unit + integration tests in §6.2:

- `RewindEntryPointsTests` (test 19) — both header button and per-row "↺" route through `Document.restoreToOp`. Prevents drift where one entry point gets a convenience code path.
- `RewindForensicProvenanceTests` (tests 20-21) — every rewind-emitted op carries `synthesisSource == .rewind`. HistoryPane row rendering depends on this; future tools (cross-Mac merge audit, MCP `list_history` if added) will too.
- `SynthesisSourceMigrationTests` (tests 22-23) — old String value decodes correctly into the new enum. Important because existing user op logs on disk have the string shape.

---

## 8. Documentation update step (milestone-close discipline)

The last task in the milestone plan: `Tn: refresh context docs`. Mechanical pass through the following files; user reviews the diff before commit.

| File | What to update |
|---|---|
| `CLAUDE.md` | Per-area OpLog: new `RewindCursor`, `SynthesisSource` enum, `Deriver.derive(ops:upTo:)` overload, restore semantics. Per-area Views: new `RewindWindow.swift`. Tripwires if new "don't do X" rules emerged (e.g. "don't reintroduce a bare `String?` for synthesisSource"). |
| `Maugham/OpLog/AREA.md` | Add `RewindCursor.swift`, `SynthesisSource.swift` to layout. New `Deriver.derive(ops:upTo:)` documented. Update tests-worth-knowing to cite the new test files. |
| `Maugham/Views/AREA.md` | Create the file if it doesn't exist (Views is now large enough — AnnotationsPane, HistoryPane, RewindWindow, EditorHost). Document the rewind entry-point seam (header button, per-row ↺, both routing through `Document.restoreToOp`). |
| `Maugham/Stores/AREA.md` | Verify no changes — `CheckpointStore.append` is reused as-is. |
| `Maugham/Editor/AREA.md` | Verify no changes — editor binding path untouched. |
| `Maugham/MCP/AREA.md` | Verify no changes — MCP layer untouched. |
| `docs/roadmap.md` | Move History Rewind under Group 4 from "Open" to "Shipped" with the milestone summary. List v2 carry-forwards explicitly (project-scope rewind, live-update during scrub, un-archive action, scrubber pan/zoom). |
| `docs/adr/0010-typed-cross-area-seams.md` | Add `RewindCursor`, `RewindAction`, `RewindScope`, `SynthesisSource` to the instances table. Same pattern, four new instances. |

Same shape as the post-editing-milestone cleanup commit `cd1e11c`. Mechanical haiku task.

---

## 9. Decisions locked

| # | Decision | Rationale |
|---|---|---|
| 1 | Dedicated full-window modal (`RewindWindow.swift`) | Doc/diff preview needs the main-area space; HistoryPane is too narrow. ESC dismisses, opening a fresh session is cheap. |
| 2 | Per-doc scope only in v1 | Scrubbing multiple docs' op logs simultaneously needs its own UX answer ("which doc's clock am I on?"). CheckpointStore.docPointers already supports multi-doc data; v2 is a UX extension, not a data refactor. |
| 3 | Hybrid every-op with smart density | Most flexible. Auto-decimation rule (one tick per px, checkpoints always visible) handles long op logs in v1 without pan/zoom. |
| 4 | Both Doc + Diff preview modes with toggle | Doc is the focused reading view; Diff is the impact-assessment view. Toggle is instant — no re-derive. |
| 5 | Two terminal actions (Snapshot, Restore) | Covers both "remember this past moment" and "actually go back." Snapshot reuses CheckpointStore; Restore appends checkpointRestore op. |
| 6 | Per-row "↺" button as a deep-link into the modal | Zero new code paths. Same preview, same confirm. Header button = explore; per-row = "I know roughly where I want to go." |
| 7 | No PartialRestorePicker for v1 rewind restore | Scrubber is doc A's clock; nothing to pick. Checkpoint-row reverts continue using PartialRestorePicker. |
| 8 | flushBurstNow() on modal open | Ensures "Now" anchor reflects in-flight typing. Modal snapshots the op log at open-time — no live updates. |
| 9 | Append-only op log, including ops that have been rewound past | Source-of-truth invariant. Writer can scrub back through previously-undone ranges. |
| 10 | Auto-archive orphan annotations with synthesisSource=.rewind | Existing sweep machinery handles it. Distinguishes rewind cause from paragraph_deleted in HistoryPane row rendering. |
| 11 | SynthesisSource refactor rolled into this milestone | String-typed values for a closed set are a latent bug factory. Cost is bounded (4 emit sites, a handful of read sites). |
| 12 | Documentation update step is a first-class task at milestone-close | Captures the lesson from the post-editing-milestone audit. Mechanical, but load-bearing. |
