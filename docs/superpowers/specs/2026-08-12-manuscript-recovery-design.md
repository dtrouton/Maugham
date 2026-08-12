# Manuscript Recovery Options — the ladder above the refusal floor

*2026-08-12. Brainstormed with Denver (four rulings captured verbatim below). Roadmap
Group 4's "Manuscript recovery options (thoughtful auto-repair)" entry, scheduled
2026-08-09 on landing the RULING-54 op-log refusal. Denver's founding intent,
verbatim: "so the author isn't just stuck with an unopenable file — give them some
options to get to some of the data but non destructively."*

## 1. The floor this stands on, and the one constraint

Since the RULING-54 op-log slice (M9-OL-001/002/003), a document whose op-log file
set contains an unreadable-yet-present file REFUSES to open, with the file named, in
the pane where the manuscript would be (`EditorHost.loadError`) and as a project
notice. The refusal exists because the alternative was catastrophic in slow motion:
the doc opened SHORTER, the next autosave truncated the `.md` to match, and the new
sequence keyframe superseded the unreadable file's paragraphs when it returned —
text surviving in the log but never reappearing.

Today the refusal is also the ceiling: the writer's remedies are Finder-level
self-surgery or the whole-project restore window, if they know it exists.

**The one constraint every rung inherits: nothing derived from a partial view is
ever written over durable state.** The read-only rung is load-bearing for every
other rung. This is the roadmap entry's own sentence and the spec's acceptance bar.

## 2. Scope (Denver's ruling: "full ladder, restore-lite")

This milestone builds all four rungs, with rung 4 as a pointer, not a build:

1. **Read-only partial open** — a clearly-labelled partial view from the readable
   files; no autosave, no ops.
2. **Wait-and-retry for iCloud** — detect a dataless stub, say so, trigger the
   download, auto-open when it lands.
3. **Quarantine-and-continue** — set the unreadable file aside untouched, keep
   writing; merge honestly when it returns.
4. **Guided restore, lite** — the refusal offers the EXISTING whole-project
   restore-beside window. **Single-document restore (op-log surgery) is explicitly
   out of scope** — it remains the backup milestone's deferred "marquee piece,
   wants its own milestone".

## 3. The refusal pane becomes the ladder

On refusal, classify the cause before writing the message:

- **Dataless iCloud stub** (the URL's ubiquitous-item properties:
  `isUbiquitousItem` + downloading status): the pane says what is actually
  happening — "iCloud hasn't downloaded this file yet" — calls
  `startDownloadingUbiquitousItem`, and polls. The moment the file reads, the
  document **auto-opens editable** (Denver's ruling: auto from the refusal pane —
  the writer is looking at an error, nothing shifts under them). The stub path
  **never offers quarantine**: moving a stub aside would fight the download, and
  the cause is transient by definition.
- **Everything else** (permissions break, squatting directory entry): the honest
  RULING-54 message plus three actions — **Open Read-Only** (rung 1), **Set the
  File Aside and Keep Writing** (rung 3, worded as what it does), **Restore from
  Backup…** (rung 4-lite).
- **The unlistable ops directory** (M9-OL-003's case): nothing is enumerable, so
  no partial view and no quarantine are possible. iCloud-shaped → the wait-and-retry
  treatment; otherwise message + Restore only.

## 4. Rung 1 — the read-only partial open

**Architecture: a recovery mode on `Document.load` itself, not a second render
path.** `Document.load(recovery: .readOnlyPartial)` derives from the readable
files only and stamps the Document `isReadOnlyRecovery`. Every mutation entry
point guards on it exactly the way `isClosed` already does (`setFullText` /
`setParagraph` / `insert` / `delete` / `reorder` / `performAutosave` /
`flushBurstNow` → no-op + `documentLog`), and no autosave scheduler is created at
all — the strongest form of "no writes" is machinery that does not exist. This
keeps the Bootstrap contract (`Document.load` is the one load path; both existing
production callers unaffected), reuses the whole editor render stack, and uses a
shipped guard pattern instead of a new parallel state shape (tripwires 3/6).

The view opens in the normal editor chrome, locked, **text selectable** (copying
out is half the point), with a persistent banner:

> Read-only — 2 history files can't be read (`doc-x.phone.jsonl`). What you see
> may be missing recent work from those devices.

Banner behaviours (both ruled by Denver):

- **The return is an offer, never a yank**: when the missing file becomes readable
  while the view is open, the banner gains "Full history is back — Reopen". Text
  never moves under a reader. (Auto-reopen happens only from the refusal/waiting
  pane, §3.)
- **Typing surfaces the quarantine offer**: the first keystroke is refused and
  answered — the banner emphasises and offers "Keep writing anyway — set the
  unreadable history aside (kept safe, merged back when it returns)". Typing
  intent is exactly when rung 3 is wanted. Nothing is buffered (the scratch-layer
  option is the parallel-state shape tripwires 3/6 exist to prevent).

The partial view is **not registered in `DocumentStore`'s document registry** —
that registry is how MCP's `read_document` resolves an open doc by docId, and a
registered partial view would hand Claude exactly the partial state §6 forbids.
The window binds it directly (EditorHost holds the instance as it already does);
checkpoint capture, the seal step, and every registry-walking consumer therefore
never see it. If a registry entry proves unavoidable for navigation, it must be a
typed recovery entry the MCP resolvers refuse — the plan decides, the constraint
does not move.

## 5. Rung 3 — quarantine-and-continue, and the return merge

**The quarantine act** (writer-initiated, from the refusal pane or the read-only
banner): the unreadable file is moved *untouched* — bytes never opened — to
`.maugham/conflicts/quarantined-ops/<original-name>.<stamp>`, routed through the
typed mover discipline (tripwire 14: no raw `moveItem` on durable state; the mover
gains a sidecar-scoped verb if the existing ones don't fit). A sidecar record
(`<name>.<stamp>.quarantine.json`) remembers: docId, device filename, when, and
the read error at the time. The document then opens **fully editable** from the
remaining files. The History pane carries a standing notice for the doc — "Part of
this document's history is set aside (unreadable when quarantined)" with a
**Retry** button — so the state is never invisible.

**The return** (Denver's ruling: op-log merge + orphan report — the roadmap
title's "thoughtful auto-repair"):

1. Re-probe opportunistically: on document open, and on Retry. A clean, fully
   verified read of every line is required before anything moves; a torn line
   means the file STAYS quarantined and the existing salvage/quarantine-record
   path is offered instead.
2. On a clean read, the file moves back into `.maugham/ops/` and its ops merge by
   the existing cross-device sync rules (ADR 0012: opId-ordered,
   last-writer-wins-per-paragraph). The writer's post-quarantine edits win
   wherever both sides touched the same paragraph.
3. **The orphan report — the one new mechanism**: every recovered paragraph NOT in
   the current draft's derived sequence (superseded by newer keyframes, or never
   seen by them) is surfaced: "7 paragraphs from the recovered history aren't in
   your draft", with **View** (read-only, copyable) and **Append to End** — which
   lands them as ordinary new ops: rewindable, undoable, overwriting nothing.
   Zero orphans → "Recovered history merged — nothing was missing."

The orphan set is computed, not stored: derive the returned file's ops alone,
derive the merged doc, and diff paragraph membership. A paragraph counts as
recovered-and-present if its id is in the merged sequence; everything else in the
returned derivation is an orphan.

## 6. Rung 4-lite, and the named non-goals

**Restore from Backup…** on the refusal opens the existing `RestoreWindow` scoped
to this project. Nothing new is built.

Non-goals, stated so they don't creep:

- **Single-document restore** (op-log surgery from a backup generation) — its own
  future milestone.
- **MCP stays strict** — every tool keeps refusing on the unreadable doc with the
  descriptive error. Recovery is the writer's deliberate act in the app; a partial
  view behind `read_document` would let Claude-derived output leak from a partial
  state. (A quarantined-and-continued doc is a NORMAL doc to MCP — it is fully
  editable and its log is the truth-so-far.)
- **No auto-quarantine, ever.** Every rung above wait-and-retry is
  writer-initiated.
- **No changes to the refusal semantics themselves** — the floor stays exactly as
  M9-OL-001/002/003 pinned it.

## 7. Safety properties, tests, claims

Each rung's safety property gets a pinned test in the RED-watched style:

1. **The partial view writes nothing**: open read-only-partial, interact, close —
   zero ops appended, `.md` byte-identical, no pending file, no checkpoint, no
   seal. (The load-bearing claim; pin it across close, not just while open.)
2. **Typing in the partial view mutates nothing** and surfaces the offer (banner
   state assertable without a window mount where possible; wiring censused
   otherwise, the `predecessorIndex` / delivery-census pattern).
3. **The quarantine move is byte-identical** (hash before/after) and lands beside
   its sidecar record; the doc opens editable afterward.
4. **The merge loses neither side**: for every paragraph in the returned file's
   own derivation, it is either in the merged sequence or in the orphan report —
   the union is total, property-testable with generated op sets.
5. **Append-to-end is ordinary ops**: rewindable, undoable (compensating restore
   sweeps, RULING-25's precedent applies if annotations ride along).
6. **The stub path never offers quarantine**; the directory case never offers a
   partial view.
7. **Return-offer semantics**: readable-again while the view is open → banner
   offer, no reload; from the refusal pane → auto-open.

Claims ship WITH the milestone (phase-4 steady state) as new `M9-OL-` rows in the
OpLog module (or a Recovery module file if the count warrants it); the
quarantine-and-continue filings cite RULING-54 and RULING-4's recoverability
clause; the merge's report cites RULING-28/52's family (what landed, what didn't).

## 8. Risks and tripwire contact points

- **Tripwire 7** (no 4th caller to `applyExternalText`): the return merge must NOT
  route through the cloud-conflict resolution text path. It is an op-log-level
  merge; if the doc is open when the merge lands, the reload rides the existing
  op-log-change path (path-keyed, tripwire 22), never a text splice.
- **Tripwires 3/6** (no parallel observable state / heavy binding work): the
  read-only mode adds NO new observable text state — same Document, same binding,
  editing disabled.
- **Tripwire 14**: the quarantine move goes through the typed mover.
- **Tripwire 17** (iCloud + JSONL): quarantine moves a file OUT of the synced
  tree's ops directory into `.maugham/conflicts/` — still inside `.maugham/`, so
  iCloud may sync the move; the sidecar record makes the state legible on the
  other device, and the other device's reader simply sees one fewer op file (its
  own strict-read behaviour is unchanged). The spec accepts this; the plan should
  add the cross-device probe test.
- **`BackupSignature`/`ProjectIntegrity`**: a quarantined file leaves the ops
  glob, so integrity's dangling-pointer check runs on the post-quarantine truth —
  correct, and the History-pane standing notice is the honest signal. The
  quarantine sidecar lives under `.maugham/conflicts/` which backups exclude — the
  M9-OL-010 filing already records that exclusion as a future decision; this
  milestone doesn't move it.
- **Two-clone coordination**: `EditorHost` and the refusal pane are shared
  surfaces with the primary clone's shell work — notify after any push.

## 9. Plan sequencing (rules 11/12)

Two plans, the second written only after the first is built: **Plan A** — the
classification + ladder pane, wait-and-retry, rung 1's read-only mode, and
rung 4-lite (the refusal's Restore button). **Plan B** — quarantine-and-continue
and the return merge with the orphan report, re-derived against Plan A's built
code. Each stays under the ~10-task cap.

## 10. Rulings captured in this brainstorm (verbatim choices)

1. **Scope**: "Full ladder, restore-lite" — rungs 1+2+3, rung 4 as the existing
   restore window; single-doc restore stays a future milestone.
2. **The return**: "Offer in view; auto from refusal" — auto-open editable from
   the refusal/waiting pane; a banner offer, never a yank, from an open partial
   view.
3. **The merge**: "Op-log merge + orphan report" — sync-rules merge, writer's
   newer edits win, every not-in-draft recovered paragraph surfaced with View /
   Append to End.
4. **Typing intent**: "Surface the quarantine offer" — first keystroke refused
   and answered with the rung-3 offer in the banner; nothing buffered.
