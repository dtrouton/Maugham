# Op-log spine hardening — post-ADR-0018/0019 review fixes

- **Date:** 2026-07-01
- **Status:** Approved (user: "lets do this whole list")
- **Input:** four-dimension adversarial review of `816d4c4..7ded46d` (ADR 0018 + ADR 0019, shipped v0.12.4/v0.12.5). Full Mac suite was green; the findings below are all silent gaps the suite does not cover.
- **Plan:** `docs/superpowers/plans/2026-07-01-oplog-spine-hardening-plan.md`

## Findings being fixed (verified against current main)

### F1 — CRITICAL: ordering-only edits never reach the op log
Deleting a paragraph (or any pure reorder) records nothing in the pending
buffer — `Document.setFullText` calls `pending.recordChange` only when
`prior != restored` (`Document.swift:468-472`); the deletion only sets the
in-memory `_orderingDirty`. `flushBurstNow` gates ALL op emission on
`!pending.isEmpty()` (`Document.swift:668-669`), so a deletion-then-quit emits
no op. At next load, the crash-recovery fold ignores the pending file's durable
sequence when `changes` is empty (`Document+Load.swift:229`), and `reconcile`
runs with `parsed: []` so the pre-0019 `.md`-anchor rescue (branches 1–3) is
dead. **The deleted paragraph resurrects everywhere.** Pre-0019 the anchored
`.md` was silently load-bearing for this; its designated replacement
(PendingBuffer's durable `sequence`) only works when a text change accompanies
the ordering change.

### F2 — CRITICAL: anchored legacy file + empty op log opens EMPTY
Lazy migration means anchored files persist indefinitely. With no op log
(crash between Bootstrap's `.md` write at `Bootstrap.swift:60` and its op
append at `:68`; user deletes `.maugham/`; backup restore missing hidden
`.maugham/`), `Bootstrap.run` hits `allHaveIds` and returns **without emitting
an op** (`Bootstrap.swift:17-21`); load derives from zero ops with
`parsed: []` → the doc opens empty while the manuscript sits in the file, and
the first edit (including MCP `add_note` on the closed doc) autosaves the
near-empty render over it. No conflicts backup fires on this path.

### F3 — MAJOR: bootstrap re-mint under iCloud partial sync
Post-migration files are clean, so "op log is empty" is the sole bootstrap
signal. iCloud delivering the `.md` before `.maugham/ops/` makes device B
re-mint every ¶id; when the real log merges, `handleExternalLogChange` sees
all original ids as `removedFromLog` and mass-archives every paragraph-anchored
annotation.

### F4 — MAJOR: while-closed external edits destroyed with no backup
The backup-on-discard net (`Document+ExternalChange.swift`) only covers live
presenter events. `Document.load` never compares disk bytes to the derived
render, so a file edited while Maugham was closed is silently overwritten by
the first autosave — no `.maugham/conflicts/` snapshot.

### F5 — MAJOR: read-path perf at scale
One `DerivedManuscript` call replays 100% of a doc's history —
`OpLogStore.loadSyncMerged` fully decompresses + SHA-verifies every sealed
segment and decodes every op; ADR 0016 keyframing is write-side only; no cache
exists (M3 was NO-GO'd against a *single-doc* budget that predates ADR 0018's
N-doc sweeps). Hot offenders: cross-document search (every doc, per debounced
keystroke, `@MainActor`, uninterruptible per-doc; `ProjectSearchEngine.swift:36`)
and project-open word counts (synchronous, zero yields, blocks window;
`ProjectStore.swift:222-236`). Measured ~36–99ms per doc-derive after one
drafting-month; 50–100 docs with history ⇒ est. 1–5s main-actor blocks.
`ProjectStore+Tasks.swift:127-148` already has the right shape (op-log-mtime-
keyed cache).

### F6 — MEDIUM: open-doc staleness is the 30/90s burst window, not 750ms
The 750ms autosave writes the `.md` + pending mirror but appends **no ops**;
ops land at burst close (30s idle / 90s cap / force-flush). Sites that always
derive therefore lag an open doc by up to ~90s: **compile/preview_compile**
(`ProjectStoreASTSource.swift:40` — a persisted PDF/EPUB can silently omit the
newest text; unfiled), in-app search + MCP `search_text` (whose pre-search
`flushPendingSave` only flushes research notes), `list_all_links` /
`find_references` (filed in roadmap, but as "~750ms" — understated).

### F7 — MEDIUM: cross-device `.md` rewrite ping-pong; unbounded conflicts dir
The discard handler auto-rewrites the file with no damping. With op-log sync
lagging the `.md` (iCloud's normal failure mode) or a version-skewed device
writing anchored files, two devices bounce rewrites indefinitely; each bounce
writes an uncapped backup into `.maugham/conflicts/`.

### F8 — MEDIUM: Collection-piece conflict backups land in `pieces/.maugham/`
`writeConflictBackup` (`Document+ExternalChange.swift:90-92`) computes the
project root with a fixed two-level `deletingLastPathComponent()` — the exact
bug `resolveProjectURL` (same commit range, `Document+Load.swift`) exists to
fix. Backups for Collection pieces file where nothing will look.

### F9 — MEDIUM: the ADR 0018 tripwire is a site guard, not an invariant guard
`test_noManuscriptFileReadsOutsideReconciler` scans only the 8 files that held
the original 9 offenders, for only 3 patterns (`String(contentsOf:`,
`Data(contentsOf:`, `String(contentsOfFile:`). New files, other read APIs
(`FileManager.contents(atPath:)`, `FileHandle`, `.resourceBytes`/`.lines`,
multi-line formatting), MaughamCore, and MaughamPhone all evade. The phone's
Read tab reads the manuscript `.md` for display — defensible (freshest render;
no live Document cross-device) but uncontracted anywhere.

### Minor (fixed in passing)
- `read_document` word_count computed over anchored text (~+3 tokens/paragraph, `DocumentTools.swift:83`).
- `performAutosave` swallows pending-flush failure via `try?` (`Document.swift:225`) — the pending file is now the ONLY crash-recovery source.
- Dead code with misleading comments: `Document.reconcile` branches 1–3 (describe rescues that can no longer fire), `Reconciler.classify` (uncalled), `EchoState.afterIngest` (unused).
- Stale comments/docs: `Document+Load.swift:249-251` ("The .md is still ANCHORED on disk at this stage (Task 3 makes it clean)" — Task 3 shipped), `LoadFromOpLogNotMdTests.swift:10-13` header, `CrossDeviceIntegrationTests.swift:10,156-157` ("→ Reconciler.classify"), `ProjectStore+Search.swift:9-10` ("search reads the freshest content from disk"), roadmap "~750ms" claim, ADR 0019 line 17 overstatement ("removed every reader").

## Decisions

1. **F1 fix, both ends.** (a) `flushBurstNow` emits a sequence-bearing op with
   empty `changes` when `pending.isEmpty() && _orderingDirty` (also invalidate
   the tasks cache — a deleted paragraph can carry tasks). (b) Load-time
   recovery also folds when `pending` has no changes but a non-empty `sequence`
   that **differs from the derived sequence**. The difference check is load-
   bearing: `performAutosave` stamps `pending.setSequence` on every 750ms flush
   and `close()` re-creates the pending file after the burst flush, so a
   `{sequence, changes: []}` pending file is the NORMAL post-quit state —
   without the check every launch would append a junk op. Verify the Deriver
   honors an empty-changes typingBurst's sequence (the 2b926fc junk-skip is
   `.bootstrap`-kind-only; keep it that way).
2. **F2 fix at Bootstrap.** In the `allHaveIds` case, when the doc's op log is
   empty (check `OpLogStore.opLogFileURLs` inside `Bootstrap.run` — it is only
   ever invoked from `Document.load` under `!logExists`, but the internal check
   keeps it self-defending), emit a bootstrap op + initial checkpoint seeded
   from the anchored file's existing ids (identity preserved — annotations
   whose log is gone are lost either way, but ids stay stable for any synced
   state). Do NOT rewrite the `.md` in this path. With F2 fixed at the source,
   `reconcile` branches 1–3 stay dead → delete them (branch 4, orphan-drop,
   stays).
3. **F4 fix at load.** After deriving initial state in `Document.load`, when a
   log existed (not the bootstrap path) and
   `MarkdownDisplayFilter.stripAnchors(storedBytes) != stripAnchors(materialize(derived))`,
   write a forensic snapshot via the same conflict-backup writer. Compare
   display forms so a still-anchored (unmigrated) file doesn't false-positive.
   Dedup against the newest existing backup for the doc (byte-equality) so
   repeated open/close of an unchanged divergent file doesn't accumulate copies.
4. **F6 fix by the ADR's own rule** (open doc → live Document), not by
   flushing: `ProjectStoreASTSource`, `ProjectSearchEngine`, `ListAllLinksTool`,
   `FindReferencesTool` take the live `Document`'s in-memory state when the doc
   is open (same pattern as `read_document`/`list_scenes`), deriving only for
   closed docs. No op-chop, no extra I/O, and open docs become *free* instead
   of a derive.
5. **F5 fix with the Tasks-pane pattern generalized:** a per-project
   `DerivedManuscriptCache` keyed on the doc's op-log file set + mtimes
   (+ sizes), fronting `DerivedManuscript` for closed docs; adopted by search,
   word counts, wiki-rename pre-check, and the link tools. Project-open word
   counts move off the blocking load path (async population after the window
   appears, with per-doc yields). Perf guards assert derive-COUNTS (cache hits)
   rather than wall-clock, so CI can't flake; an env-gated timing print stays.
6. **F3 mitigation: first-bootstrap-wins in the Deriver.** A doc bootstraps
   once; any later `.bootstrap` op (a partial-sync re-mint) is skipped during
   derivation, making the re-mint inert once the real log syncs in. Residual
   risk accepted + documented: edits made on top of a re-mint before the merge
   reference re-minted ids and will be orphan-dropped — rarer and smaller than
   today's annotation mass-archive. (A true fix needs a bootstrap tombstone
   that syncs ahead of `ops/`; no such channel exists. Recorded in the ADR
   addendum as a known limitation.)
7. **F7 damping:** per-Document discard-bounce counter — after N (3) distinct-
   bytes discards within a session window, stop auto-rewriting (still snapshot,
   still keep op log authoritative in memory) and log; reset on local edit.
   Retention cap on `.maugham/conflicts/`: keep the newest K (20) per doc,
   prune older on write (mirrors trash sweep's approach).
8. **F9: annotation-based tripwire.** Rewrite the ADR 0018 tripwire in the
   identity-tripwire style: scan ALL Swift under `Maugham/`,
   `Packages/MaughamCore/Sources/`, and `MaughamPhone/` for a widened pattern
   set (`String(contentsOf`, `Data(contentsOf`, `contentsOfFile`,
   `FileManager` `.contents(atPath`, `FileHandle(forReadingFrom`,
   `.resourceBytes`, `url.lines`); every hit must carry `// adr-0018-ok:
   <reason>` (annotate the legitimate research/manifest/publish/help/inbox
   reads). Keep the planted-offender self-test, sharing pattern constants with
   the production check. Add a phone twin; register the phone Read-tab display
   read as a contracted divergence in
   `docs/superpowers/notes/cross-surface-contracts.md`.
9. **Docs are part of done:** ADR 0018 + 0019 addenda describing these fixes
   and correcting the staleness claim (30/90s, not 750ms) and the "removed
   every reader" overstatement; roadmap follow-up items closed/corrected;
   `Maugham/OpLog/AREA.md` + `Maugham/Stores/AREA.md` updated; CLAUDE.md
   tripwire/invariant touch-ups; all stale comments from the findings list
   fixed; `Reconciler.classify` + `EchoState.afterIngest` deleted.

## Out of scope
- Round-tripping external `.md` edits into the op log (explicitly rejected design).
- A persistent on-disk derived cache (`.maugham/cache/`) — the in-memory mtime cache covers the observed hot paths; revisit only if profiling says otherwise.
- Op-log read-side keyframe snapshots (derive short-circuit) — bigger design, separate milestone if the cache proves insufficient.
