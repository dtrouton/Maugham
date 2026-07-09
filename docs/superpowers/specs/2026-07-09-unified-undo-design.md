# Unified ⌘Z undo (op-log-backed) — spec

**Date:** 2026-07-09
**Origin:** roadmap Group 1 "Comprehensive ⌘Z undo" bullet, picked up after v0.17.0 (annotation undo) shipped the pattern's first case. Brainstormed 2026-07-09.

## Goal

Make ⌘Z span every writer-initiated mutation, not just typing and suggestion accepts. Today the window's native undo covers keystrokes, and v0.17.0 added undo-of-accept (`claudeAcceptRevert`). Still not undoable: annotation reject/archive/edit/withdraw, all six task ops, and a History Rewind restore.

This milestone closes three roadmap items at once:
1. Group 1 "Comprehensive ⌘Z undo" (the whole bullet).
2. The History Rewind carry-forward "un-archive annotation lifecycle action" (falls out of the new reopen op).
3. Group 5 "Annotations undo / reopen" from the phone (deferred from phone-v0.2.0; folded in here).

## User decisions (2026-07-09)

- **Scope:** everything writer-initiated, including undo of a History Rewind restore.
- **Phone:** gets a Reopen action on resolved annotations in this milestone (not derive-only).
- **Phone reopen of an accepted suggestion:** full revert, identical to Mac's Revert — text restored + note reopened. Not status-only.
- **Architecture:** Approach B — a typed inverse-op seam consumed by one thin Mac registrar and the phone's Reopen, over per-case ad-hoc registration.

## Invariant framing

Undo **appends compensating ops**; it never truncates or rewrites the log (same append-only invariant History Rewind honors). A later Rewind session shows the undo ops in its timeline — the undo is part of history. History Rewind stays the deliberate forensic modal; ⌘Z is the muscle-memory path that appends the same class of ops for the specific thing just done.

## D1 — The inverse-op seam (two homes, one shape)

A pure function per domain: given the op being undone plus current derived state, return the compensating op to append, or a typed refusal the caller surfaces as a loud no-op (`.stateDrifted`, `.paragraphGone`, `.taskGone`). No I/O, no UndoManager (MaughamCore stays UndoManager-free — v0.17.0 rule).

- **MaughamCore:** `AnnotationInverse` — compiler-exhaustive over the annotation lifecycle op kinds. Shared verbatim by Mac ⌘Z and phone Reopen (tripwire 19: the phone writes exactly what the factory returns; zero phone-local inverse logic).
- **Mac** (`Maugham/OpLog/`, beside `TaskDeriver`): `TaskInverse` — task types are Mac-only; the phone has no tasks surface, so this does not belong in Core.

Exhaustive switches mean a future op kind cannot compile without an explicit inverse decision (which may be "not undoable").

## D2 — The inverse table and the one new op kind

| Writer action | ⌘Z appends | New op kind? |
|---|---|---|
| Accept suggestion | `claudeAcceptRevert` (with changes) | shipped v0.17.0 |
| Reject / archive annotation | **`annotationReopen`** (`"annotation_reopen"`) → derived status `.open`; redo re-performs preserving the original `userResponse` (fdbf12f precedent) | **Yes — the only new kind** |
| Withdraw own review annotation | `annotationReopen` | No (reuses it) |
| Edit own review annotation | another `annotationEdit` carrying the prior body | No — self-inverse |
| Task status / priority / parent / body edit | same op kind with the prior value (payloads already carry prior/next-style fields) | No — self-inverse |
| Create pane task | `taskArchive` | No |
| Archive task | `taskStatusChange` back to the pre-archive status | No |
| Inline `- [ ]` toggle (pane or editor click) | self-inverse `taskStatusChange`; the manuscript text rewrite rides the normal text-op path, using the v0.17.0 D2 external-apply ordering rules | No |
| History Rewind restore | see D4 | No |

- **Schema:** one new op kind → `ProjectManifest.currentSchemaVersion` bump to **3** → **paired Mac + phone release** (the v0.17.0 / phone-v0.4.0 shape). Old apps hit the existing unknown-case rejection window (ADR 0015); additive only, no migration (tripwire 11).
- **`AnnotationDeriver`:** `annotationReopen` is a lifecycle op mapping to `.open`; carries no `changes` (never applies to the manuscript — unlike `claudeAcceptRevert` it has no with-changes variant; accepted-suggestion reversal always goes through `claudeAcceptRevert`).
- **Provenance rule:** MCP- and cross-device-originated ops never register on any undo stack. ⌘Z undoes only what the writer did in this window; Claude's annotations are dispositioned in the pane, not undone.

## D3 — Mac registrar and native-stack interleaving

One Mac-side helper, `OpUndoRegistrar`, wraps every undoable pane/editor mutation:

1. **Perform** the mutation through the existing Document path.
2. **Capture** the inverse now, against pre-mutation state — the captured compensating op is inert data, not a closure over live objects (the B3 dangling-reference crash class cannot recur by construction).
3. **Register** with the acting window's `NSUndoManager`: undo = append the captured op + apply in-memory + `recomputeDisplayText()` where text changed; redo = re-perform via the original path preserving original metadata. Descriptive action names ("Undo Reject Suggestion", "Undo Reorder Task").
4. **Guard at fire time:** re-check derived state (the `revertAccept` rule); drift → loud no-op (log + return), never crash, never a wrong-target apply.

Interleaving contract (all inherited from v0.17.0 D1/D2, now general):
- **One stack per window** — typing undo and op-undo actions interleave chronologically on the window's native `NSUndoManager`. No second stack.
- External buffer replaces clear stale typing actions; op-undo registration happens after any buffer swap the mutation itself triggers.
- **Project-scope ops** (tasks on the synthetic `__project__` doc) register with the window where the action happened; a stale entry in a sibling window declines safely via the fire-time guard.
- Window close drops its actions with its undo manager (plus the existing detach-time clear).

## D4 — Rewind-undo

A Restore appends `checkpointRestore` text ops, D3-reopen `claudeAcceptRevert`s (status-only), and orphan-sweep archives — reported in `RewindRestoreResult`. Restore machinery only synthesizes *text* ops from a prefix, so undo needs the lifecycle side-effects reversed explicitly. At restore time the registrar captures a **rewind-undo bundle** from the result: (a) pre-restore tip op id, (b) accept ids D3 reopened, (c) annotation ids the sweep archived.

Undo fires as **one grouped NSUndoManager action**:
- restore text to the captured tip via the existing `restoreToOp` path, tagged with a new additive `SynthesisSource` case (`.undoRewind`) — tripwire 12 and the clean-.md do-not-remove constraint respected (adding only);
- append a status-only re-accept per D3-reopened accept (`claudeAccept` with empty `changes` — exact mirror of D3's empty-changes revert; the derive loop folds only `op.changes`, so no conditional classification, same argument as v0.17.0 D3);
- append `annotationReopen` per sweep-archived annotation (their paragraphs are back).

**Task dimension (2026-07-09 final-review fix):** `TaskDeriver` keys its rewind window on the latest `.rewind`-stamped restore; the compensating `.undoRewind` restore deliberately opens no new window, so when the original rewind's range contained task ops the undo additionally appends a `.rewind`-flavored, text-inert task marker whose `sourceCheckpoint` is the ORIGINAL rewind op's id — the deriver's window moves past the previously-excluded task ops and they fold back in (append-only; the marker-only rewind gets a real undo this way too).

Redo = re-perform `restoreToOp(original target)` from scratch, sweeps and all — never replay captured ops, so redo cannot disagree with a fresh rewind (its fresh `.rewind` marker re-excludes the task ops).

Fire-time guard, stricter than D3 because blast radius is whole-doc: decline (loud no-op) if manuscript-applying ops from **other sources** (cross-device merge, external edit) landed after the restore's own appended ops. Plain local typing after the rewind is fine — it stacks its own undo actions on top and ⌘Z unwinds through them first. Rewind's Snapshot action is read-only and registers nothing.

## D5 — Phone Reopen

In the Annotations drill-down's Resolved section (phone-v0.2.0), resolved annotations gain a **Reopen** action:
- Rejected / archived → append `annotationReopen`, built by the shared `AnnotationInverse` factory. Withdrawn annotations are absent from the phone's projection, so the phone Reopen covers rejected/archived only — withdraw-undo is Mac ⌘Z only.
- Accepted suggestion → **full revert**: `claudeAcceptRevert` with changes, identical to Mac's pane Revert, including the drift-confirm behavior (9c063c0): paragraph drifted since accept → confirm sheet before reverting.
- No undo stack on the phone; Reopen is a deliberate button. A reopened note is simply re-dispositioned — that is the phone's redo.
- Ships paired with the Mac release under schema v3.

## Non-goals

- No change to how native typing undo works; it remains AppKit's stack.
- No project-global undo stack spanning windows; per-window is the contract.
- No undo of MCP-originated or cross-device ops (provenance rule above).
- No undo for binder/research file operations — Trash & undo (⌘⌥Z, ADR 0006) already owns those.
- No op-log truncation, ever.
- No schema migration; additive op kind + version bump only.

## Test obligations

- **Per-inverse round-trips** in the owning target: do → undo → derived state equals pre-state; do → undo → redo → equals post-state with metadata preserved. One case per table row.
- **Interleaving harness** (extend `EditorIntegrationHarnessTests`): type → pane action → type → ⌘Z×3 walks back in order, no crash, no stale-stack fault (B3 class stays pinned).
- **Rewind-undo integration:** create → accept → type → restore-to-before-accept → ⌘Z → doc and annotation statuses identical to the pre-restore derive; plus the other-source drift-guard decline case.
- **Cross-surface round-trips:** Mac writes `annotationReopen` → phone derives `.open`; phone writes reopen and revert → Mac derives correctly. Both schemes green. (The originally-planned `TripwireGrepTests` / `TripwirePhoneGrepTest` extension for the new kind was consciously dropped: there is no greppable string to pin — the compile-time exhaustive switches plus the shared `AnnotationInverse` factory are the guard.)
- **User smoke:** accept, reject, archive, toggle an inline checkbox, reorder tasks, rewind-restore — then ⌘Z all the way back and ⇧⌘Z all the way forward.
- Tripwire 8 (4-char alphabet-restricted paragraph ids) in every test crossing the `.md` ↔ op-log boundary.

## Touched-area constraints (read each AREA.md first)

- `Maugham/Editor/` — tripwires 2, 3, 6, 7: no new observable state on EditorHost, no 4th `applyExternalText` caller, no heavy work in a binding setter.
- `Maugham/OpLog/` — no structural refactor; echo-guard and `_pendingSweep` patterns untouched; `RewindCursor`/`RewindRestoreResult`/`SynthesisSource` extended additively only.
- `Packages/MaughamCore` — Apple frameworks only; `AnnotationInverse` is a pure function; new OpKind case is `public`; UndoManager-free.
- `MaughamPhone/` — seam-injection pattern per its AREA.md; no AppKit; shares all inverse logic via MaughamCore.
