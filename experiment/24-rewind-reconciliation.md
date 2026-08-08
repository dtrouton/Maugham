# 24 — Reconciliation of the app layer: Document+Rewind

Second app-layer module. `Maugham/OpLog/Document+Rewind.swift` +
`Document+RewindUndo.swift` + `Deriver+Rewind.swift` (594 loc).
Pinned against HEAD `db1bea2c`. Reconciled against the **regenerated** `RULINGS.md` (24 rulings),
which is what makes this run different from the last one.

- **29 claims**, every one pinned by a passing test.
- **Coverage 52%** — 15 of 29 reached.
- **8 COMPLIES / 7 VIOLATES**, 14 NO_RULING_REACHES. The 7 violations are **6 distinct defects**.
- **Specificity 80%** against the current ruling set — **67% against the ruling set that scored 20%.**
- Full Mac suite green with the new tests in it: **3893 tests, 0 failures**.

| What | Where |
|---|---|
| Characterisation tests (22 methods) | `experiment/app-layer-tests/RewindCharacterization.swift` |
| Probes | `experiment/app-layer-tests/RewindProbe.swift`, `RewindProbe2.swift` |
| Claims | `experiment/reconciliation/Rewind.claims.json` |
| Filings | `experiment/reconciliation/Rewind.filings.json` |

Worktree `.claude/worktrees/rewind-characterisation` reset to `db1bea2c`; tests under
`MaughamTests/Experiment/`. **Main checkout production files untouched.**

## The prediction: it holds, and here is how much of it is the correction

The delta set the test: rewind scored **20% specificity** on the decision survey. *"If pinned claims
lift it the way they lifted trash (0% → 79%), the correction holds."*

They do. But the comparison is **confounded**, and reporting 80% against 20% would overstate it.
RULING-22 was authored *from rewind's survey findings* after the 20% was measured, and its
`settles IN SCOPE` list names four rewind cases explicitly. Five of my seven violations cite it. So
part of the lift is the sampling correction and part is the ruling set having grown to cover exactly
this module.

Separating them: recompute specificity against the ruling set **as it stood when the 20% was
measured** — no RULING-22, no RULING-24.

| Claim | Current filing | Old-set filing |
|---|---|---|
| M4-RW-010, -011, -012 | R24 (root) | **R4 — SUB** |
| M4-RW-017, -018, -031 | R8 (sub) | R8 — SUB |
| M4-RW-019 | R8 (sub) | R8 — SUB |
| M4-RW-026 | R7 (sub) | R7 — SUB |
| M4-RW-002 | R22 (sub) | R20 — root |
| M4-RW-003, -008 | R22 (sub) | R19 — root |
| M4-RW-022 | R22 (sub) | R19/R20 — root |
| M4-RW-021 | R22 (sub) | *unreached* |
| M4-RW-023, -024 | R22 (sub) | *unreached* |

**20% (decision survey, old set) → 67% (claim ledger, old set) → 80% (claim ledger, current set).**

The sampling correction accounts for **+47 points**; the new ruling accounts for **+13**. The
correction is by far the larger effect, and it holds on a second module. The counterfactual is
deliberately conservative — every disputable assignment is scored *against* my number (three claims
drop to unreached, four to roots).

### The artefact demonstrated in the survey's own words

The single biggest contributor is RULING-4, and the survey **said so in prose while scoring it
zero**:

> *"RULING-4 holds throughout, and holds well: the log is append-only … the pre-rewind tip stays
> scrubable, and no rewind path truncates. Every finding above is about what the writer is TOLD …
> That is the module's real shape and it is a credit to it."*
> — `sweep2/Rewind.json`, notes

Three claims (M4-RW-010/011/012) are reached by that ruling and comply. The survey's specificity
statistic counts them zero times, because a decision survey samples *problems* and a ruling holding
is not a problem. **A decision survey measures the residue a ruling set leaves; a claim ledger
measures the ruling set.** This is the same finding as the trash run, now demonstrated on a module
whose own author wrote the compliance down and could not count it.

## RULING-22 survives contact with the module it came from

The delta's second reason: R22 was authored from hand-picked rewind decisions, so reconciling rewind
against it tests whether such a ruling generalises.

**It does, and it discriminates in both directions** — which is the stronger result. R22 reaches 7
claims: **4 violations and 3 compliances.** A ruling derived from a defect list that then certifies
half its module correct is not a defect list with a ruling's name on it.

Its scope also held up under pressure at the two places I expected it to fail:

- I **declined** it at M4-RW-005 (`restoreToOp` lands after the target). The method does exactly what
  its doc comment says; the mismatch is with a label in another module and is filed once, at
  M4-RW-002. Filing it twice would count one defect as two.
- I **declined** it at M4-RW-026 (the silent undo decline) in favour of RULING-7, on R22's own
  stated relation: *"R7 governs FAILURES … R22 governs SUCCESSES."*

The discriminator I derived in the trash run — *R22 convicts a control that does the wrong thing, not
one that fails loudly* — held again without amendment.

## What the module gets right, and it is the important half

**RULING-24 tier 1 is rewind's job, and rewind does it.** Three claims, all COMPLIES:

- M4-RW-010 — the log is append-only across a rewind; every pre-rewind op survives, the log strictly
  grows, nothing is truncated or compacted.
- M4-RW-011 — deriving at the pre-rewind tip reproduces the pre-rewind paragraphs **exactly**.
- M4-RW-012 — rewinding forward returns the **live document** to those exact words.

Tier 1 says the work is *"protected AT ALL COSTS and is version-controlled: every change to it is
retained."* That is a description of this op log, and a rewind is the most destructive-looking thing
that happens to it. Every one of the six defects below is about what the writer is **told** or what
they can **reach** — not one is about a word being lost.

I cite RULING-24 rather than RULING-4 because R24 explicitly scopes R4 (*"R4's authored words are
always recoverable now has a tier attached"*), so the tier is the more specific statement of the same
duty.

**On the basis warning.** The delta flagged that RULING-24's basis clause *"we rely on ⌘S [and]
filesystem backups"* was verified FALSE for the ⌘S half, and that this matters for rewind because ⌘S
checkpoints are tier-1's mechanism. Two things follow, and they point opposite ways:

1. For **manuscripts**, tier 1 does not depend on checkpoints at all. The recovery route I pinned is
   the op log and the rewind modal itself (M4-RW-011/012) — no checkpoint is involved. So the false
   premise does not weaken tier 1 where tier 1 matters most.
2. `RewindWindow.snapshotHere` writes a checkpoint whose `docPointers` are the **scrubbed** op for
   the active doc and the **latest** op for every other doc — a checkpoint recording a project state
   that never existed at any single moment. That is in `RewindWindow`, outside these three files, and
   I did not test it. It is named in `sweep2/Rewind.json`'s closing note and it is the place where
   the corrected premise would bite. **Flagged, not claimed.**

## Two survey findings resolved

### REW-D9 is FALSIFIED — retire it

The survey asked whether a craft note should survive the disappearance of the paragraph it is
anchored to, and described the consequence as *"the annotations pane shows an open craft note whose
paragraph chip points at text that is not in the document."*

**There is no chip.** A craft note has no paragraph anchor, and cannot be given one. Three
independent sites enforce it:

1. `add_craft_note`'s MCP schema has **no `paragraph_id` property**, its description says
   *"Doc-scoped; no paragraph anchor"*, and it passes `paragraphId: nil` explicitly
   (`AnnotationCreationTools.swift:191`).
2. `Document.addAnnotation` writes `changes: []` for `.craftNote` (`Document+Annotations.swift:99`).
3. `AnnotationDeriver` forces `paragraphId = nil` for that kind regardless
   (`AnnotationDeriver.swift:65`).

Pinned at M4-RW-015: the craft note's `paragraphId` reads `nil` at creation while a comment on the
same paragraph reads the id. The `ann.kind != .craftNote` clause in `sweepOrphanedAnnotations` is
therefore **dead** — the `removed.contains` term is already false. REW-D9's own `what_would_falsify_it`
predicted precisely this ("if craft notes are in practice doc-scoped … there is nothing to see") and
was never checked.

### REW-D11's conviction is VINDICATED, and should be re-filed to a sub

The delta asked me to re-check my D11 flag against the repaired file. **My flag was right about the
file and D11 was right about the verdict.** REW-D11 convicted under RULING-19 quoting *"a
lower-layer repair means a guard above did not fire — that is a bug"*; that clause was missing from
the damaged file, which is why I could not find it. It is now restored at `RULINGS.md:35`, and it
does reach: the deriver's fallback is a lower-layer repair and the Restore button above it has no
guard.

But RULING-22 now reaches it too, by name and line number — *"stale cursor silent no-op … Restore
lands on 'now' and nothing happens, silently (Deriver+Rewind.swift:34-36)"*. R22 is a sub, so per the
root-is-decoration discipline **D11 should be re-filed from SETTLED_BY_ROOT_ONLY to a sub-ruling
violation**, and the register's root-only count drops by one — the second such correction in two
modules.

## The six defects

| Claims | What | Ruling | Reach |
|---|---|---|---|
| M4-RW-019 | rewinding forward brings the paragraph and the pane **task** back, and leaves the **comment** archived — permanently, silently | R8 | LIVE |
| M4-RW-002 | "Rewind to before this…" is an **inclusive** prefix, so it lands *after* the op | R22 | LIVE |
| M4-RW-021 | a rewind that changes **nothing** still destroys the writer's whole typing-undo stack | R22 | LIVE |
| M4-RW-026 | ⌘Z of a rewind **declines silently** after a cross-device merge — the menu says "Undo Restore from History" and nothing happens | R7 | LIVE |
| M4-RW-003 + -008 | a target op not in the log derives as **the present**, silently; the two results compare `==`, so no caller *could* tell | R22 | UNTRACED |
| M4-RW-022 | that same vanished target destroys the undo stack and reports success | R22 | UNTRACED |

Two notes on these.

**M4-RW-008 is sharper than the survey knew.** `RewindRestoreResult` is `Equatable`, and the
"your moment does not exist" result compares **equal** to the honest "there was nothing to do"
result. It is not that the caller fails to distinguish them — **no caller could**, because the API
carries no channel for the difference. That changes what a fix has to touch.

**M4-RW-021 is the filing most likely to be argued down.** If undo granularity is judged something
the writer is not owed, it retires to an enhancement under PRINCIPLE-2 and GAP-R3 stands in its
place. I filed it VIOLATES on R22's scope clause (*expectation formed from what Maugham showed;
outcome differing*) because the writer's expectation on a no-op restore is "nothing will change", and
what changes is two hours of ⌘Z. The module's own comment concedes the case: *"this clear already
discarded typing history for zero benefit."* The words are never at risk, which is what keeps it out
of RULING-24.

## The gaps

**GAP-R1 — which tier do annotations, tasks and suggestion status live in?**
> Notes, comments and suggestions the writer accumulated on their work are protected to the same
> standard as the work itself: anything Maugham closes on the writer's behalf when they travel
> through their history is reopened when they travel back.

RULING-24 is a ROOT that partitions protection into three named classes — the work, research,
ingested/derived. **An annotation is none of them.** It is not the prose, not research, and not
ingested. It is the class this module damages most (M4-RW-019), and R24's partition does not see it.
This is the sharpest gap in the set: a tiering root with a hole in the middle of its own domain.

**GAP-R2 — reopening what Maugham closed** *(survey REW-D3)*
> Anything Maugham closed on the writer's behalf can be reopened by the writer at any later time,
> from the surface that shows it. A single undo immediately afterwards is not a recovery route; it
> expires.

`Document.reopenAnnotation` exists and works. Its only production callers are undo closures —
verified by grep across `Maugham/`, **not by my tests**, so recorded as evidence-by-reading. The
annotations pane can display archived annotations but offers no Reopen action, and no MCP tool
writes annotation lifecycle. One keystroke after the rewind, the ⌘Z is gone and the annotation is
visible but dead.

**GAP-R3 — an action that changes nothing costs nothing** *(survey REW-D7)*
> An action that changes nothing costs the writer nothing. Where an operation must discard undo
> history to stay coherent, it discards it only once it is certain it will change something — and
> the control that starts it is not offered when there is nothing to do.

Stands only if M4-RW-021 is argued down from a violation to an enhancement. Stated so the question
survives either ruling.

**GAP-R4 — a moment that no longer exists**
> A moment the writer selected in their history either exists and is restorable, or the offer to
> restore it is withdrawn with its reason named. A missing moment is never quietly replaced by the
> present one.

R22 settles that the current silence is a defect. It does not say what should happen instead, and
the three options are not equivalent — refuse, restore to the nearest surviving moment, or restore to
now. The code picked the third, which is the only one that discards the writer's stated intent while
looking like success.

**GAP-R5 — the collateral report**
> An operation that changes more than the writer asked about states the full set of those changes
> before they commit AND confirms what it did afterwards. Naming one class of collateral change and
> omitting another is worse than naming none.

R22 settles the *pre-confirm* omission ("unmentioned auto-archive"). Nothing covers the *after*. The
data exists and is typed — M4-RW-029 pins that `RewindRestoreResult` carries every collateral effect,
and the type's own doc comment shows the toast it was designed for (*"Restored. 3 annotations
auto-archived."*). No production caller renders it: `ProjectWindow.swift:1726` discards the result
with `_ =`. **The module produces the truth and the caller throws it away** — which means this gap is
a rendering decision, not an architecture problem.

**GAP-R6 — RULING-13 needs a time-travel companion**
> When a paragraph is no longer present — whether its identity was lost, or the writer travelled to a
> time before it existed — its notes are marked, not silently closed.

RULING-13's scope is *"when a paragraph's IDENTITY is not recovered"*. In a rewind the identity is
not lost; the paragraph genuinely did not exist yet. Three survey findings and two of my claims
(M4-RW-013, M4-RW-019) bounce off R13 for that one reason. R13 already has the vocabulary — `isStale`
— and the ruling's own basis says staleness is *"a signal to the author, who decides whether each one
still applies"*, which is exactly what a rewound-away annotation needs and does not get.

## Three findings about the artifacts, not the code

**1. `RECONCILE.md`'s discipline 5 cites a RULING-8 clause that does not exist.** Discipline 5 quotes
*"two situations that merely look alike may legitimately differ"* as RULING-8's, load-bearing and
abusable. It is not in the regenerated `RULINGS.md`, and it is **not in the ledger either** —
`_meta.rulings["RULING-8"]` has `family`, `verdict`, `statement`, `consequence`, `ruled_by`, `date`
and nothing else. So this is *not* a generator drop: the Phase-22 audit **recommended** adding a
discriminator to R8 and the amendment was never made. The guidance is sound; the citation is to a
clause nobody wrote.

This mattered here. M4-RW-019 is exactly the case discipline 5 warns about, and I spent the filing
weighing an escape clause that turns out not to exist — which makes RULING-8 **unqualified** and the
violation cleaner than the survey supposed. Either write the clause or stop citing it.

**2. The delta says "two new rulings"; the file has one.** `RULINGS.md` reports 24 rulings and only
RULING-24 is new. The second appears to be RULING-4's tier scope-clause plus RULING-23's premise
correction — amendments to existing rulings, not new rulings. Cosmetic, but the register's own counts
are what everything else is measured against.

**3. `premise_verified` — yes, and scope it to proposed rulings.** The delta asked whether the
seventh field earns its place. It does, and REW-D9 is the case: the finding was well-argued, correctly
scoped, high-confidence — and rested entirely on the premise that a craft note carries a paragraph
anchor. **No scope argument could have caught it**, because the scope reasoning was correct; the
premise was false. Same shape as my own GAP-2 last round.

But require it only on a **proposed ruling**, not on every filing. A filing is already pinned by a
test, which is a premise check with teeth; adding a prose field beside a passing assertion is
ceremony. A proposed ruling has no test, propagates to every future case, and is the scarce resource.
One field, one place: **the ruling proposal, with the call path that verified it.**

## UNTRACED and out of scope

- **M4-RW-003 / -008 / -022** — the vanished-cursor family. `RewindWindow.load` reads `doc.opLog()`,
  which prefers `_opLogMirror`, the same array `restoreToOp` derives from, so the cursor is in the
  live log by construction. I found no compaction or truncation path that removes an op from the
  mirror (ADR 0016 sealing keeps sealed segments loadable; `handleExternalLogChange` replaces the
  mirror with a merged union). **The fallback may be defending a case that no longer exists** — which
  is itself worth knowing, because RULING-19's corollary says the honest move is then to delete the
  repair and let a missing target be a precondition failure.
- **Out of module, named so the omission is visible**: `ProjectWindow.swift:1726`'s
  `_ = try? await …restoreToOpUndoable(…)` (swallows every throw AND discards the result);
  `RewindWindow`'s modal-open snapshot and its `impactSummary`; `RewindWindow.snapshotHere`'s
  checkpoint pointers. All are view-layer facts I could not pin with a Document-level test. The
  survey's REW-D4 and REW-D8 live there and remain unpinned by me.
- **The `.claudeArchive` merge window** — `archivedAnnotationOpIds` is computed by diffing
  `_opLogMirror` across an `await`, filtering on `synthesisSource == .rewind`. A peer device's own
  rewind archives, merged in during that window, would match. Two Macs both rewinding inside one
  flush window; the effect is to reopen an annotation rather than lose one. Non-destructive, and I
  could not construct it in a single-device test. Recorded, not claimed.
