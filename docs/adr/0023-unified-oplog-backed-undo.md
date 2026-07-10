# ADR 0023 — Unified op-log-backed ⌘Z undo: compensating ops on one native stack

**Date:** 2026-07-10 · **Status:** Accepted · **Milestone:** unified-undo (Mac v0.18.0 / phone-v0.5.0, schema v3)

## Context

Through v0.17.0, ⌘Z covered typing (AppKit's native `NSTextView` undo) plus exactly one
op-log mutation: undoing a suggestion accept (`claudeAcceptRevert`). Every other
writer-initiated mutation made outside the keystroke stream — annotation reject/archive/
edit/withdraw, all six task ops, inline checkbox flips, History Rewind restores — was not
undoable with ⌘Z. History Rewind could recover, but it is a deliberate forensic modal,
not muscle memory. The op log already records every mutation with prior/next state, so
the material for a general undo existed; what was missing was a decided shape.

## Decision

### 1. Undo appends compensating ops. The log is never truncated.

Undoing any op-log mutation appends a **new op that reverses its effect** — the same
append-only discipline History Rewind established. Undo ops are part of the document's
history: they appear in the History pane and in later rewind timelines. There is no
"remove the last op" anywhere, and never will be (checkpoint pointers, pre-horizon
rewind, Merkle signatures, and cross-device merge all depend on immutability — ADR 0016's
argument applies to undo verbatim).

One new op kind carries the milestone: **`annotationReopen`** (`"annotation_reopen"`),
the inverse of reject / archive / withdraw — empty `changes`, lifecycle-derives to
`.open`, and a reopen newer than a withdraw cancels the withdrawal. Everything else
inverts with existing kinds: task ops are self-inverse (the inverse op carries the prior
value), create ↔ archive, and accepted-suggestion reversal stays `claudeAcceptRevert`
(with changes). A rewind-undo is itself a restore (`SynthesisSource.undoRewind`, also
new). Schema bumped 2 → 3; Mac and phone release paired (ADR 0015 discipline).

### 2. One undo stack per window; op-undo actions interleave with typing.

Op-log undo registers on the window's native `NSUndoManager` — no parallel stack, no
arbitration. The v0.17.0 accept-undo choreography is now the general contract, encoded
once in `OpUndoRegistrar` (Mac target; MaughamCore stays UndoManager-free):

- nested synchronous registration routes redo; the mutation itself hops to an async task;
- redo closures forward the **live** (weakly captured) undo manager so the forward
  re-invocation re-registers — ⌘Z/⇧⌘Z cycles indefinitely; passing nil kills the cycle
  after one redo (a caught review defect, now test-pinned at every site);
- hop tasks weak-capture their target so a closed document is never kept alive for a
  post-teardown append;
- every undo/redo closure re-checks derived state at fire time and declines as a **loud
  no-op** (log + return) when the world moved on — a cross-device merge landing between
  action and ⌘Z can never cause a wrong-target apply.

**The D1 rule is unconditional.** Any registration whose mutation replaces the editor
buffer (accept, inline toggle, inline archive, rewind restore) first clears stale native
typing actions (`removeAllActions`, guarded `!isUndoing && !isRedoing`), then arms the
undo-coherent apply flag, then mutates, then registers — contiguously. Replacing the
buffer invalidates AppKit's typing-undo entries (the v0.16.0 ⌘Z SIGSEGV class); no
"safe-seeming" exception is entertained — a length-preserving exception was proposed and
rejected during review, and converting its test to the canonical shape surfaced a real
NSUndoManager corruption. Consequence, accepted deliberately: **text-touching undo
actions start a fresh undo baseline** (older typing history is unreachable behind them);
non-text actions stack arbitrarily deep. Corollary: `removeAllActions` must never run
inside an open manual undo group (it corrupts grouping state) — batch operations
(Archive All Done) clear once *before* opening their group and suppress per-item clears.

### 3. Inverse decisions live in typed factories, not at call sites.

- **`AnnotationInverse`** (MaughamCore): the single home of "which compensating op undoes
  which resolution, and what current status it requires." Consumed by Mac ⌘Z **and** the
  phone's Reopen action (tripwire 19 — the phone adds only write-path stamping).
- **`TaskInverse`** (Mac, beside `TaskDeriver`): task types are Mac-only. Task ops carry
  only new values, so the inverse is built from the pre-mutation derived snapshot,
  captured before the forward append.

Both are compiler-exhaustive over their op kinds: a future kind cannot compile without an
explicit inverse decision (which may be "not undoable").

### 4. Rewind-undo reverses the whole rewind, including the task dimension.

`restoreToOpUndoable` registers one grouped action: a compensating restore to the
pre-rewind tip (`.undoRewind` — deliberately invisible to `TaskDeriver`'s `.rewind`-keyed
window), status-only re-accepts for what the rewind's sweep reopened (empty-changes
`claudeAccept`, preserving each original `userResponse`), reopens for what it archived,
and — when the rewound range contained task ops — a **task-window closer**: a
`.rewind`-stamped, text-inert marker whose `sourceCheckpoint` is the original rewind op,
which moves the deriver's window past the excluded task ops so they fold back in.
Redo re-runs `restoreToOp` from scratch (never replays captured ops), so redo cannot
disagree with a fresh rewind; the D3 stranded-accept detector recognizes status-only
re-accepts so a redo or a second manual restore reopens accepts exactly like a fresh one.

### 5. Scope boundaries.

MCP- and cross-device-originated ops never register on any undo stack — ⌘Z undoes only
what the writer did in this window. Rewind's reopen sweep is **accepts-only** by design:
a reject/archive has no text footprint, so rewinding text does not un-decide editorial
verdicts. Binder/research file operations keep their own Trash & undo (⌘⌥Z, ADR 0006).
The phone gets a deliberate **Reopen** button (rejected/archived → `annotationReopen`;
accepted → full `claudeAcceptRevert` revert with drift confirm), not an undo stack.

## Consequences

- Every writer-initiated mutation is ⌘Z-undoable; the Edit menu names each action.
- The op log grows by one op per undo — bounded by keyframing/sealing (ADR 0016).
- Adding an op kind now forces an inverse decision at compile time.
- New registrations must use `OpUndoRegistrar` and its conventions; the D1/D2
  choreography and the batch-clear rule are tripwire material, pinned by
  `AnnotationLifecycleUndoTests`, `TaskUndoTests`, `InlineTaskToggleUndoTests`,
  `InlineArchiveUndoTests`, `ArchiveAllDoneUndoTests`, and `RewindUndoTests`.

## References

- Spec: `docs/superpowers/specs/2026-07-09-unified-undo-design.md`
- v0.17.0 precedent: `docs/superpowers/specs/2026-07-08-annotation-undo-and-suggestion-grain.md`
- ADR 0015 (schema evolution), ADR 0016 (op-log growth without compaction), ADR 0006
  (Trash & undo), cross-surface registry row in
  `docs/superpowers/notes/cross-surface-contracts.md`
