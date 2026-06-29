# Clean `.md` on disk — manuscript files are standard Markdown/Fountain

**Date:** 2026-06-29
**Status:** Proposed
**Area:** `Maugham/OpLog/` (Document load/write/recovery), `Packages/MaughamCore/` (PendingBuffer, MarkdownDisplayFilter)

## Summary

Today a manuscript file on disk carries Maugham's internal join-keys inline —
own-line `<!-- ¶id -->` paragraph anchors and mid-line `<!--t-XXXXXX-->` task
anchors. That makes `chapter.md` a non-standard file: noisy to read, ugly in
`git diff`, awkward in pandoc/other editors. ADR 0018 just made the op log the
*sole* source of truth for manuscripts — nothing reads the `.md` as content
anymore — which means those anchors no longer need to be in the file. This
milestone writes the `.md`/`.fountain` **clean** (the editor's display form),
keeping the anchored truth only in the op log. The files become standard
Markdown/Fountain, fulfilling the app's "plain text on disk, full stop" promise.

## Scope

- **(A) Clean output only.** Editing stays Maugham-only; an external edit to a
  manuscript file is still **discarded** on re-materialize (the existing hard
  invariant — confirmed intended 2026-06-09). This is purely "stop writing our
  internal ids into the output."
- **Lazy migration.** Files are rewritten clean on their next autosave (the
  autosave already rewrites the file; we strip on the way out). Files never
  touched keep their anchors harmlessly — they load from the op log either way.
- **Clean cutover** of the load/recovery path: the `.md` is no longer read for
  content, sequence, or anchors. The op-log domain (op log + pending buffer)
  becomes fully self-sufficient.

**Non-goals:** honoring external edits / round-tripping the file back into the op
log (that would be a separate, much larger milestone that reverses the
edit-through-Maugham invariant); changing the op-log on-disk format; changing the
in-memory/editor representation (it keeps anchors — they are still the join key
*there*).

## The two inline markers (both handled by one strip)

The manuscript `.md` contains exactly two internal marker kinds, and
`MarkdownDisplayFilter.stripAnchors(_)` already removes **both** in one pass (it
is the editor's display form):

1. `<!-- ¶id -->` — own-line paragraph anchors (`ParagraphID.formatComment`).
2. `<!--t-XXXXXX-->` — inline task anchors (for `- [ ]` / `[[todo:]]` checkboxes).

So "write clean" = write `MarkdownDisplayFilter.stripAnchors(materialize())`;
task anchors come along for free. The op log keeps both (the join keys live
there); ADR 0018 Task 6 already routes task derivation through the op log, so the
file omitting `t-` anchors changes nothing about how tasks are derived or toggled.

**Annotations / comments / suggestions are not affected** — they are op-log
entries in the parallel annotation layer, never inline in the `.md`. Wiki links
`[[Title]]`, Fountain syntax, and `*emphasis*` are the writer's content and stay.

## Design

### 1. Write clean

At the single materialize→disk site (`Document.swift` ~226/234, `materialize()`
then `write(to:)`), write `MarkdownDisplayFilter.stripAnchors(materialize())`.
The op log and the in-memory NSTextStorage are unchanged (they keep anchors).

### 2. Echo-guard tracks the clean bytes

The echo guard (`Document.lastDiskEcho: EchoState`) recognises Maugham's own
write-callback so a self-write isn't mistaken for an external edit. It must now
hold the **clean** bytes we wrote. `EchoState.initialLoad` already seeds from the
on-disk bytes (now clean), and `handleExternalDiskChange` compares disk-clean vs
our-clean. An external edit (disk-clean ≠ derived-clean) is **discarded** exactly
as today (re-materialize over it; the existing conflict/discard machinery is
preserved — only the byte form changes from anchored to clean).

### 3. Bootstrap signal → op-log emptiness

`Document.load`'s bootstrap detection currently is:
`needsBootstrap = (!logExists || parsed.allSatisfy { $0.id == nil }) && !parsed.isEmpty`.
The `parsed.allSatisfy { id == nil }` clause means "the `.md` has no anchors → mint
ids" — which becomes ALWAYS-true once files are clean, and would wrongly
re-bootstrap an existing doc. Change to:

```swift
let needsBootstrap = !logExists && !parsed.isEmpty
```

A doc whose op log exists never re-bootstraps (materialise from the op log). A
brand-new or imported plain `.md` with no op log still bootstraps — minting ids
from the file. That bootstrap-from-file is the legitimate **import** read (the
file IS the initial input for a new doc; ADR 0018 only forbids reading the file
as truth for an *existing* doc).

### 4. Load content from the op log, not the file

`Document.reconcile(derived:parsed:)` currently joins the op-log-derived state
against the parsed `.md` (anchor-based orphan repair / sequence recovery). With a
clean file `parsed` carries no ids, so the reconcile has nothing to join — load
becomes op-log-only: `Deriver.derive(ops:)`, falling back to
`deriveWithSequenceFallback` for legacy logs (no explicit sequence) — the
op-log-only, approximate-ancient-ordering behaviour already accepted in ADR 0018.
The `.md` is not a content or sequence source.

### 5. Pending buffer carries the sequence (the recovery fix)

`PendingBuffer` is today an unordered `[String: Op.ParagraphChange]` — it holds
changed paragraphs but **not their order**. The crash-recovery op
(`Document.load`, ~line 227) currently recovers the current order from the
parsed `.md` anchors (`parsed.compactMap(\.id)`). With clean files that's gone.

Fix: have `PendingBuffer` also durably record the current `sequence` (captured
when changes are recorded, or at autosave — the `Document` knows the live order).
The crash-recovery op then captures `sequence` from the pending buffer instead of
the `.md`. This closes the only gap clean-cutover would otherwise open — an
un-flushed reorder/split surviving a crash within the burst window — and makes the
op-log domain genuinely self-sufficient (no `.md` read for recovery).

### 6. Lazy migration

No migration pass. A doc's file becomes clean on its next autosave (strip on
write). Untouched files keep their anchors; they still load correctly because
load reads the op log, not the file. (A doc with a legacy op log loads via
`deriveWithSequenceFallback`; once edited, its next burst captures an explicit
sequence and its file is rewritten clean.) Optional "Clean all files" command is
explicitly out of scope (can be added later if wanted).

## Invariants

- **The op log + pending buffer are the complete truth** for a manuscript;
  neither content, sequence, nor anchors are ever read from the `.md` for an
  existing doc. (Extends ADR 0018 to `Document.load` itself.)
- **The `.md` on disk is the clean display form** — `stripAnchors(materialize())`,
  no `¶id` and no `t-` anchors. The in-memory/editor representation and the op log
  keep anchors (the join key lives there).
- **Editing stays Maugham-only**; external edits to a manuscript file are
  discarded (invariant A).
- The only `.md` reads that remain in `Document.load` are: (a) **import-bootstrap**
  of a new/imported file when the op log is empty, and (b) the **echo-guard**
  comparison reference. Both are consistent with ADR 0018 (the file as initial
  input / comparison reference, never as truth for an existing doc).

## Testing strategy

- **Clean round-trip:** edit a doc → autosave → the on-disk file contains NO
  `<!-- ¶id -->` and NO `<!--t-XXXXXX-->`; reload → content + paragraph identity +
  ordering intact (op log restores anchors in-memory).
- **Task-anchor round-trip:** a doc with inline `- [ ]` tasks → clean file omits
  `t-` anchors; reload → inline tasks still derive, toggle, and reorder correctly
  (op log keeps `t-`).
- **Legacy file load:** a doc whose op log has no explicit sequence loads via
  `deriveWithSequenceFallback` (approximate order), independent of the file.
- **Crash recovery with un-flushed reorder (the new bit):** seed pending changes
  that reorder/split paragraphs, simulate a crash (don't flush), reload → the
  recovered op captures the order from the **pending buffer**, not the file;
  ordering is correct even though the file is clean.
- **External edit discarded:** externally rewrite a clean `.md`; Maugham
  re-materialises the op-log truth over it (the external edit does not enter the
  op log).
- **Bootstrap signal:** new/imported plain `.md` (no op log) → bootstraps and
  mints ids; a doc with an existing op log → never re-bootstraps even though its
  (clean) file has no anchors.
- Full Mac + phone suites green; the existing `Document`/load/reconcile/bootstrap
  tests pass (some will need updating from anchored-`.md` fixtures to clean ones,
  the way ADR 0018 bootstrapped test op logs).

## Risks

- **Most fragile area.** `Document.load` / reconcile / crash recovery is
  load-bearing. Mitigated by: the per-case tests above (esp. crash recovery),
  the existing suite, and an incremental plan (PendingBuffer-sequence first, then
  the write/load changes, lazy so nothing is mass-rewritten).
- **Crash-recovery completeness depends on the pending buffer being durable.**
  The pending buffer is written to `.maugham/` on change; this milestone makes it
  also the order-of-record. Verify the durability + write-ordering claim in the
  plan (the `.md` is materialised *from* op log + pending, so it is never more
  current than they are — the pending buffer is the genuine belt).
- **Behaviour change is visible in files/git** — every edited file's next commit
  drops the anchor lines. That is the intended outcome (clean files), but it is a
  one-time-per-file diff the writer will see. Lazy keeps it spread out, not a mass
  rewrite.
- **No manuscript data changes** — content is identical; only the internal markers
  leave the file.
