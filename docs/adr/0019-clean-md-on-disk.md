# 0019 — Manuscript files on disk are clean Markdown/Fountain (anchors live only in the op log)

- **Status:** Accepted
- **Date:** 2026-06-29
- **Design detail:** `docs/superpowers/specs/2026-06-29-clean-md-on-disk-design.md`
- **Builds on:** ADR 0018 (manuscript reads always derive from the op log)

## Context

Maugham's manuscript files carried Maugham's internal join-keys inline — own-line
`<!-- ¶id -->` paragraph anchors and mid-line `<!--t-XXXXXX-->` task anchors —
because, historically, things read the file *back* and needed those anchors to
re-join its paragraphs/tasks to the op log. That made `chapter.md` a non-standard
file (noisy to read, ugly in `git diff`, awkward in pandoc / other editors) — a
wart on the app's "plain text on disk, full stop" promise.

ADR 0018 removed every reader that treated the file as truth: the op log is now
the *sole* source of truth for manuscripts. With nothing reading the file as
content, the anchors no longer need to live in it.

## Decision

**Write manuscript files clean** — the editor's display form,
`MarkdownDisplayFilter.stripAnchors(materialize())`, which strips BOTH the
`¶id` paragraph anchors and the `t-` task anchors in one pass. The anchored truth
(the join keys) lives only in the op log and the in-memory editor representation.

Scope: **clean OUTPUT only**. Editing stays Maugham-only; an external edit to a
manuscript file is still discarded on re-materialize (the existing invariant).
Round-tripping external edits back into the op log is explicitly NOT in scope.

The load/recovery path takes a **clean cutover**: the `.md` is no longer read for
content, sequence, or anchors for an existing doc. To make the op-log domain
self-sufficient for crash recovery (the file's last remaining job was recovering
the order of un-flushed reorders), `PendingBuffer` now also durably records the
current `sequence`, so the crash-recovery op captures order from the pending
buffer, not the file. The bootstrap signal moves from "the `.md` has no anchors"
to "the op log is empty," so an existing doc never re-bootstraps from its now
anchor-less file while a new/imported file still bootstraps.

Migration is **lazy**: a file is rewritten clean on its next autosave; untouched
files keep their anchors harmlessly (load reads the op log either way).

## Consequences

- **Manuscript files are standard Markdown/Fountain** — readable, `git diff`-clean,
  pandoc-able. The "plain text on disk" promise is fully kept.
- **The op log + pending buffer are the complete truth.** Neither content,
  sequence, nor anchors are read from the `.md` for an existing doc — extends
  ADR 0018 to `Document.load` itself.
- **The remaining `.md` reads in `Document.load` are the import-bootstrap (a
  new/imported file when the op log is empty) and the echo-guard comparison** —
  both the file-as-initial-input / comparison-reference category, not truth.
  These stay consistent with the ADR 0018 tripwire.
- **The CLAUDE.md "inline `¶id` anchors are the join key" invariant is refined:**
  the anchors are the join key in the **op log and in-memory**, not on disk. The
  on-disk file is a clean derived render.
- **Task anchors come free** — the same `stripAnchors` pass removes them; ADR 0018
  Task 6 already routes task derivation through the op log, so inline tasks still
  derive/toggle/reorder with the file carrying no `t-` anchors.
- **Annotations are unaffected** — they were never inline in the `.md` (op-log
  annotation layer).
- **Visible in git/files:** each edited file's next commit drops its anchor lines
  (a one-time-per-file diff). Lazy migration spreads this out rather than a mass
  rewrite.
- **No manuscript data changes** — content is identical; only internal markers
  leave the file.
