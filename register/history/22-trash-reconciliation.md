# 22 — Reconciliation of the app layer: TrashStore + ProjectStore+Trash

**The hard half of `RECONCILE.md`.** First app-layer module characterised and reconciled.
Pinned against HEAD `db1bea2c` — the same HEAD the ledger records.

- **51 claims**, every one pinned by a passing test.
- **Coverage 47%** — 24 of 51 claims reached by a ruling.
- **13 COMPLIES / 11 VIOLATES**, 27 NO_RULING_REACHES.
- **Specificity 79%** — 19 of the 24 reached by a SUB-ruling, 5 by a root only.
- Full Mac suite green with the new tests in it: **3905 tests, 0 failures** (`-skip-testing:MaughamTests/MCPServerLifecycleTests`).

Artifacts:

| What | Where |
|---|---|
| Characterisation tests (39 test methods) | `experiment/app-layer-tests/TrashCharacterization.swift` |
| Probes (assert nothing, print observed behaviour) | `experiment/app-layer-tests/TrashProbe.swift`, `TrashProbe2.swift` |
| Claims | `experiment/reconciliation/Trash.claims.json` |
| Filings (6-field template) | `experiment/reconciliation/Trash.filings.json` |

## How this was run

Worked in a git worktree (`.claude/worktrees/trash-characterisation`, branch
`worktree-trash-characterisation`, reset to `db1bea2c`). Tests live at
`MaughamTests/Experiment/`. **The main checkout's production files are untouched — the 47-phase
invariant holds.** The only writes to the main checkout are inside the untracked `experiment/`
directory.

```
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamTests/TrashCharacterization
```

Method was probe-then-pin, per `Probe.swift`'s pattern: two probe passes printing observed output,
then assertions written from what was printed. **Three claims came out the opposite way from what
the code reads like**, which is the whole argument for probing first:

- `moveToTrash` returns a `TrashEntry` that DROPS the `originalParentId`/`originalIndex` it was
  just handed, while the `meta.json` it wrote keeps them (M3-TR-006).
- `restore` throws `malformedEntryId` *after* it has moved the file back and deleted the entry
  (M3-TR-032) — the throw reads like a precondition and is a postcondition.
- A restored **research** item lands in `manifest.structure` (M3-TR-041). See below.

## The finding

**M3-TR-041 — a restored research item is re-inserted into the manuscript binder, not the research
tree. LIVE. Every research restore, every time.**

`restoreTrashEntry` tries `StructureItem` first:

```swift
if var item = try? JSONDecoder().decode(StructureItem.self, from: entry.itemMetadata) {
    …insert into manifest.structure…
} else if var item = try? JSONDecoder().decode(ResearchItem.self, from: entry.itemMetadata) {
    …insert into manifest.research…
}
```

A `ResearchItem`'s JSON decodes cleanly as a `StructureItem`: `id`, `title`, `path` and `children`
line up, and `type: "asset"` forward-tolerates to `.document` under ADR 0015's schema-evolution
rule. So the first branch always wins and **the `ResearchItem` branch is unreachable for anything
the research tree produces.** Observed:

```
before-restore/research  = ["res-grp"]
after-restore/research   = ["res-grp:group"]                     ← the note never comes back
after-restore/structure  = ["res-note:A Note:document:research/note.md"]
```

A research folder does the same one level up, arriving in the binder as a manuscript group carrying
its children (M3-TR-041b). The file itself is restored correctly — it is only the row that goes to
the wrong tree, and the resulting manuscript row points at a path under `research/`, which is what
`RenamePlan` will reason about on the writer's next rename.

Filed **VIOLATES RULING-22** ("Controls are unambiguous and DO WHAT THEY SAY"). It is invisible to
the existing suite because `TrashRestoreNestingTests` only ever restores structure items.

The ADR-0015 forward-tolerance that causes this is *correct on its own terms* — it exists so an
unknown `type` from a newer build cannot make a manifest unopenable. It becomes a defect here only
because a second consumer started using `decode` as a type TEST. That is PRINCIPLE-1 verbatim: a
decision that was right when one thing depended on it is a bug when two do, without anyone changing
it.

## What the reconciliation says about the RULING SET

`RECONCILE.md` put the question directly: RULING-15 was made about trash, the sweep scored it at
**0% specificity**, and that is "either a gap in the rulings or a gap in my reading of them."

**It is neither. It is a gap in the sampling.**

`sweep2/Trash.json` surveyed 13 hand-picked *product decisions* — cases selected for being
arguable. Over those 13, RULING-15 is the tightest fit for none, and the module scores 0%
specificity. Over 51 *pinned claims* the same module scores **79%**, and RULING-15 is the tightest
fit for three of them (M3-TR-003, -004, -026: the file is moved not unlinked, a group moves
wholesale, restore returns it). RULING-15 settles trash's ordinary behaviour cleanly and completely.
It reaches none of the arguable cases because the survey *selected for* arguable — a decision survey
measures the residue a ruling set leaves, and a claim ledger measures the ruling set.

Two statistics, same module, same rulings, 79 points apart. **They are not the same measurement and
should not be compared.** The `sweep2` per-module specificity column should be read as "how much
argument is left over here", not "how well the rulings cover this".

The rest of the picture:

- **RULING-7 is the load-bearing ruling here**, reaching 6 claims — more than any other. Four of the
  six are the same shape: *an operation fails or half-succeeds and says nothing*. That is a real
  signature of this module and it agrees with the sweep.
- **Coverage discriminates as the ledger's headline predicted, and keeps going.** 0% on TreeWalk (a
  tree algorithm a writer never meets) → 34–40% on PaletteCard (a file format they edit) → **47% on
  trash** (a pane they click). The gradient tracks writer-proximity, which is what a scoped ruling
  set should do.
- **The comply/violate ratio inverts across the layers, and this is the more interesting number.**
  MaughamCore's pure modules ran 31 COMPLIES : 1 VIOLATES. The app layer runs 13 : 11. The rulings
  are not failing to bite in the app layer — they bite hard. The earlier "97% of what a ruling
  reaches is already right" headline is a fact about *pure, deterministic, writer-distant code*, and
  should not be restated about the codebase as a whole. This module is the first evidence of that.

### One gap CLOSED

`sweep2` D4 concluded: *"No sub-ruling reaches a stale undo target. RULING-8 is close but not in
scope."* **RULING-22 reaches it.** A menu item labelled "Restore Last Deleted Item" that restores an
item which is not the last deleted one is a control not doing what it says — RULING-22's stated
scope, no stretching required. Filed as M3-TR-036 VIOLATES RULING-22. D4 should be re-filed from
SETTLED_BY_ROOT_ONLY to a sub-ruling violation, and the register's root-only count drops by one.

### One quotation that does not check out

`sweep2` D11 files against RULING-19 quoting the clause *"lower layers protect the system and data
silently (but a lower-layer repair means a guard above did not fire — that is a bug)"*. **The
parenthesis is not in RULING-19 as recorded in `RULINGS.md`.** Without it, R19 does not convict the
silent prune — it licenses the silence. I have filed M3-TR-040 as NO_RULING_REACHES with the gap
stated instead. Either the parenthesis is a real clause missing from the ruling set, or D11's
conviction rests on a clause that does not exist. Denver should say which.

## Coverage

| | n |
|---|---|
| Claims | 51 |
| Reached by a ruling | 24 (47%) |
| — COMPLIES | 13 |
| — VIOLATES | 11 |
| NO_RULING_REACHES | 27 (53%) |
| Reached by a SUB-ruling | 19 (79% of reached) |
| Reached by a ROOT only | 5 |

By ruling:

| Ruling | Claims | Outcome |
|---|---|---|
| RULING-7 (report a failure as what it is) | 6 | 3 COMPLIES, 3 VIOLATES |
| RULING-15 (delete is normalised) | 3 | 3 COMPLIES |
| RULING-19 (layered duties) *root* | 3 | 3 COMPLIES |
| RULING-22 (never surprise) | 3 | 3 VIOLATES |
| RULING-23 (trash retention) | 3 | 3 COMPLIES |
| RULING-4 (loss is recoverable) | 3 | 3 VIOLATES |
| RULING-8 (one question, one answer) | 1 | 1 VIOLATES |
| RULING-9 (filesystem responsibility) *root* | 1 | 1 COMPLIES |
| RULING-20 (honour intent) *root* | 1 | 1 VIOLATES |

The 11 violations, worst first by reachability:

| Claim | What | Ruling | Reach |
|---|---|---|---|
| M3-TR-041 / 041b | a restored research item lands in the **manuscript** tree | R22 | LIVE, every time |
| M3-TR-035 | a research **link** deletes with no trash entry and no route back | R8 | LIVE |
| M3-TR-036 | ⌘⌥Z restores an **earlier, unrelated** item after a link delete | R22 | LIVE |
| M3-TR-046 | "Empty Trash" leaves entries it never looked at, and reports empty | R7 | LIVE, no I/O failure needed |
| M3-TR-027 | a restore blocked by an occupant fails identically **forever** | R20 *root* | LIVE |
| M3-TR-045 | "Empty Trash" cannot report a failure — its `catch` is dead code | R7 | LATENT |
| M3-TR-015 | a half-written entry is invisible: unreadable shown as empty | R7 | LATENT |
| M3-TR-032 | `restore` throws **after** destroying both routes back | R4 | UNTRACED |
| M3-TR-011 / 012 | same-second, same-id entries collapse; restore destroys one file | R4 | UNTRACED |

## The gaps

Each is stated as the sub-ruling that would be needed, phrased as a PRODUCT statement.

**GAP-1 — a restore that cannot complete.** *(M3-TR-027; sweep2 D1)*
> When a restore is blocked because something now stands in the deleted item's place, Maugham still
> hands the writer their item — restored beside the occupant under a distinguishing name, with both
> visible — rather than refusing in a way the writer has no way past.

RULING-15 stops one clause short: it says where a delete goes and that the destination is
restorable, and says nothing about a restore that cannot complete. Today the refusal is
non-destructive (RULING-20's first half honoured) but not recoverable-from (second half not).

**GAP-2 — what "permanently delete" and "expired" mean for the writer's words.** *(M3-TR-021,
M3-TR-049; sweep2 D10)*
> "Permanently delete" means the writer's words are no longer in the project — the derived file and
> the record it was rendered from both go. If Maugham keeps history anyway, it does not tell the
> writer the deletion cannot be undone; it says what it is keeping and offers a way to destroy that
> too. And Maugham never holds the writer's words in a place it can neither show them nor expire.

Two pinned facts sit under this. The op log at `.maugham/ops/<docId>.jsonl` survives the trash move,
"Permanently Delete", "Empty Trash" and the sweep alike (M3-TR-049) — every word, indefinitely,
travelling into every backup and zip of the project. And an entry whose `meta.json` never landed is
both invisible and immortal, because `sweep()` iterates `list()` (M3-TR-021; verified at 900 days).

**GAP-3 — one delete gesture is one undo.** *(M3-TR-037; sweep2 D3)*
> Whatever the writer removed in a single action — one item or fifty — "Restore Last Deleted Item"
> brings all of it back, or refuses and says why. It never returns part of a deletion and reports
> nothing about the rest.

Deliberately NOT convicted under RULING-22: the label is singular and literal and the command does
what those words say. What it does not match is the writer's model of ⌘⌥Z as an undo of their last
*action*, which is a genuinely unruled question. Convicting here would turn RULING-22 into a
catch-all and would blunt its real use at M3-TR-036 and M3-TR-041.

**GAP-4 — the binder and the disk after a restore that cannot go home.** *(M3-TR-039; sweep2 D12)*
> When a restored item cannot go back where it came from, Maugham puts it somewhere the writer can
> see AND leaves the folder layout matching what the binder shows — it does not re-create a folder
> the writer deleted in order to hold a file the binder says is elsewhere.

Not cosmetic: the resurrected folder is exactly what later blocks that group's own restore under
GAP-1.

**GAP-5 — a restore that returns less than was deleted.** *(M3-TR-040; sweep2 D11)*
> A restore that returns less than was deleted names what it could not return, at the moment of the
> restore.

RULING-4's "the drop must be reported" has the right shape and the wrong subject — it is scoped to
DERIVED material, and a binder row's order, nesting and title is arrangement the writer authored.
See the quotation note above before re-filing D11.

**GAP-6 — Maugham's own bookkeeping in the writer's Trash.** *(M3-TR-042; sweep2 D13)*
> The Trash pane shows the writer things the writer deleted. Maugham's own safety copies of its
> internal files either do not appear there, or appear labelled as what they are, with a Restore
> that puts the piece back the way it was — wiring included — not just the file.

The shape generalises past its one caller: `restoreTrashEntry` has no `else` branch, so any future
non-binder trash entry restores its file with no manifest consequence and reports success.

**GAP-7 — the retention contract.** *(M3-TR-019, -020, -050; sweep2 D9)*
> Maugham never destroys the writer's work on its own initiative without telling them first; the
> trash expires only after the writer has been shown that it is about to.

RULING-23 settles *that* trash may destroy and *why* — the writer's own standing intent, which is
honoured and not violated (M3-TR-019 and M3-TR-050 both COMPLY). It fixes no duration, does not say
whether the clock may run while the writer is absent, and does not say whether they are warned. The
30-day figure appears only in a code comment and a pane caption. Two reasonable people plainly
disagree here.

**GAP-8 — a control that is dangerous only for some rows.** *(M3-TR-035)*
> Where one Delete command over one tree cannot recover every row it acts on, the rows that cannot
> be recovered say so before the writer presses it.

M3-TR-035 is convicted under RULING-8 for answering one writer question two ways. The forward-facing
half — that nothing distinguishes a recoverable row from an unrecoverable one *beforehand* — is not
reached by any clause. RULING-22's confirmation-prompt sentence is close ("where an action is
complex or its consequences are confusing, that warrants an additional confirmation prompt") but is
about complexity, not about a uniform control with a non-uniform blast radius.

## UNTRACED — recorded, not guessed

- **M3-TR-011 / M3-TR-012** — the same-second, same-id collision. Pinned as a property of this
  module and reproduced in a test, but I could construct no writer gesture that reaches it:
  production ids are minted unique, and the `"x"` default needs metadata with no `id` field, which
  no current caller supplies. **The guard is the uniqueness of ids minted elsewhere, not anything
  this module does.** A future caller supplying id-less metadata opens it. `sweep2` note (5) reached
  the same conclusion by reading; this run reproduced the consequence, which is worse than the note
  supposed: restore does not merely restore the wrong content, it destroys the other file.
- **M3-TR-032** — an entry id with no parseable timestamp. Reachable only by renaming a `.trash`
  subfolder in Finder. Filed VIOLATES RULING-4 on its scope clause ("owed against ACCIDENTS and
  against MAUGHAM'S OWN ACTIONS"), and this is **the filing in this set most open to being
  overturned** — the counter-argument, that RULING-9 places an out-of-app rename at the writer's
  risk, is stated in the filing rather than hidden.
- **M3-TR-034** — a path-less `StructureItem` cannot be deleted, the row survives, and an empty
  entry folder is left in `.trash/`. I did **not** establish that any production path mints a
  path-less `StructureItem`; the test manufactures one. Filed COMPLIES under RULING-19 for the
  storage half only.
- **M3-TR-030** — the sidecar-path guard on the way out. Exists for a corrupted or hostile
  `meta.json`; no writer gesture reaches it.

## Out of scope, and therefore unpinned

Named so the omission is visible rather than silent. These are `sweep2` findings I could **not**
convert into claims with a store-level test, because they live in the view layer:

- **sweep2 D2** — `ProjectWindow.swift:574` is `try? await store?.restoreLastDeleted()`, discarding
  every real `TrashError` on the ⌘⌥Z path, while the Trash pane's context menu alerts on the same
  call. Recorded against M3-TR-044 as an open edge. The three `TrashError` cases carry hand-written
  `LocalizedError` strings that name a real cause; that path throws all of them away.
- **sweep2 D6** — `DocumentStore.trash` passes a single path to `closeFlushAndUnregister`, which
  does an exact-key lookup, so trashing a GROUP closes no descendant `Document`. Reaching it needs a
  live `EditorHost` and the 750 ms autosave, neither of which a store-level test drives. **Not
  disproved — untested.** It remains the sharpest unpinned claim in this territory, and the doc
  comment at `ProjectStore+Trash.swift:28-37` asserts the protection it relies on ("the trash path
  closed + unregistered it") in exactly the way `RECONCILE.md` warns about.
- The confirmation sheets' wording ("All N items will be permanently deleted", "This cannot be
  undone") — `TrashView`. It is what makes M3-TR-045, -046 and -049 writer-visible, and it is not
  pinned here.

## Two things this module gets right, since a register of violations reads unfairly

Restore is genuinely non-destructive by construction: `fm.moveItem` never overwrites, and the throw
lands *before* `removeItem(entryFolder)`, so a failed restore always leaves the trash entry whole
(M3-TR-027, M3-TR-030 both assert it). And both relative paths — the caller's on the way in and the
sidecar's on the way out — go through `SafeRelativePath` with a typed error, which is the lower-layer
duty RULING-19 assigns, done properly, twice (M3-TR-007, M3-TR-030).

M3-TR-045's defect is a failure to USE machinery that exists three lines away in M3-TR-047, not an
absence of it. That distinction is worth keeping in the register.
