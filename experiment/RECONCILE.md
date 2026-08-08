# Reconciliation — the standing brief

**Read this whole file before doing anything.** It is self-contained: it tells you what the
activity is, what already exists, what to produce, the disciplines, and the traps that have
already caught someone.

## What this is

Maugham's behavioural specification is being built as two layers:

- **Claims** — verified facts about what the code does. Machine-generable, cheap, and *pinned by a
  passing test against HEAD*. An unpinned claim is an assertion, not a claim.
- **Rulings** — human product decisions about what *should* be true. Expensive, scarce, authored by
  Denver. In `experiment/RULINGS.md`: 3 roots, 20 subs, 4 principles.

**Reconciliation** is running the rulings over the claims. The mismatches are the output: places the
code violates a stated decision, and places no decision exists yet.

The ledger is `experiment/01-claims-ledger.json`. 169 claims, all reconciled. `_meta` carries the
rulings, the method findings and the audit history.

## What has been done, and what has not

**Done — the easy half.** `MaughamCore.PaletteCard` and `MaughamCore.TreeWalk`: pure, deterministic,
no I/O. 103 characterisation + property tests in `experiment/ExperimentTests` (standalone SPM
package, `swift test --package-path experiment/ExperimentTests`). Reconciliation result: **21%
coverage — 0% on TreeWalk, 34-40% on PaletteCard — with 30 COMPLIES against 2 VIOLATES.**

**Not done — the hard half.** The app layer: `Maugham/Stores/TrashStore.swift`,
`Maugham/OpLog/Document+Annotations.swift`, `Maugham/OpLog/Document+Rewind.swift`,
`Maugham/Canvas/Promotion*.swift`, `Maugham/MCP/Tools/`. A survey of these
(`experiment/sweep2/*.json`) produced **product decisions**, but no claims — **nothing there is
pinned by a test.** That is the work.

## The blocker you will hit in the first ten minutes

`experiment/ExperimentTests` depends on `MaughamCore` only. It **cannot** reach app-layer code,
which needs `@testable import Maugham` from the `MaughamTests` target.

So characterising the app layer means writing tests inside `MaughamTests/`. Options, in order of
preference:

1. **A git worktree** (`git worktree add /tmp/<name> HEAD --detach`), tests under
   `MaughamTests/Experiment/`, run with
   `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/<YourTests>`.
   Run `./gen.sh` after adding files. Discard the worktree afterwards. **This keeps the main
   checkout clean, which has been an invariant of this whole experiment — 0 production files
   changed across 47 phases.**
2. If you must work in the main checkout, put everything under `MaughamTests/Experiment/` and say
   so plainly in your report.

The app layer is impure: actors, `NSFileCoordinator`, 750ms debounce timers, `@MainActor`. Existing
tests show the idioms — `MaughamTests/DocumentStoreRelocateRollbackTests.swift` is a good model
(`TempDirectory`, `ProjectFactory.createShortStoryProject`, `DocumentStore.open`).

## The activity

1. **Pick one app-layer module.** One, not several. `TrashStore` + `ProjectStore+Trash` is the
   suggested start: 217 lines, writer-facing, and reconciliation there scored **0% specificity** —
   RULING-15 was made about trash and reaches none of its decisions, which is either a gap in the
   rulings or a gap in my reading of them.
2. **Write characterisation tests** pinning what it actually does. Probe first and write assertions
   from observed output — never from what you expect. `experiment/ExperimentTests/.../Probe.swift`
   is the pattern. **They must pass against HEAD.** A failing test means you mis-read the code, not
   that you found a bug.
3. **Extract a claim per pinned behaviour**, in the ledger's schema.
4. **Reconcile** each claim against `experiment/RULINGS.md`, using the template below.
5. **Report** coverage, comply/violate, and the gaps.

## The filing template — a verdict cannot be filed without all six fields

```json
{"claim_id":"...","outcome":"COMPLIES|VIOLATES",
 "ruling":"RULING-n",
 "clause_that_reaches_it":"<quote the exact clause, not the ruling's title>",
 "why_in_scope":"<argue why this case falls inside that clause's STATED scope>",
 "intent_expressed_when":"<contemporaneous | earlier | not at all>",
 "call_path":"<how a writer reaches this, or UNTRACED>",
 "violation_or_enhancement":"violation|enhancement|neither"}
```
Otherwise: `{"claim_id":"...","outcome":"NO_RULING_REACHES","reason":"<one line>"}`

`why_in_scope` is the field that does the work. When the existing verdicts were re-filed through
this template it caught two errors — both times because the sentence was hard to write honestly,
not because the ruling name looked wrong.

## Five disciplines. Each is a mistake someone already made here.

1. **SCOPE, NOT SYMPTOM.** A ruling reaches a case only if it falls inside the ruling's *stated*
   scope. RULING-1's scope is ENTRY POINTS — a renderer emitting is not one. RULING-11's scope is
   INVISIBLE BOOKKEEPING (anchors, structural framing) — a field visible in a file is not that.
   ~30% of resolutions failed this test on audit.
2. **INTENT HAS DURATION.** A writer's instruction persists until withdrawn. Deleting is intent;
   trash destroying it 30 days later is that intent honoured, not a violation. Ask *when* the
   writer expressed the relevant intent, not whether they expressed it just now.
3. **NO_RULING_REACHES IS THE EXPECTED OUTCOME.** Most behaviour is not a product decision. 116 of
   169 claims are reached by nothing, correctly. Do not stretch to find matches — a high match rate
   is evidence *against* the rulings, not evidence of thoroughness.
4. **AN ENHANCEMENT IS NOT A DEFECT.** If you cannot name the clause it breaks, it is not a
   violation. "Could be better" belongs in a different list.
5. **SAMENESS IS JUDGED FROM THE WRITER'S QUESTION.** RULING-8's clause "two situations that merely
   look alike may legitimately differ" is load-bearing *and* abusable — it has already been used
   once to excuse two syntaxes answering one writer question differently. The test is whether the
   **writer** is asking the same thing, never whether the code paths differ.

## Traps specific to this territory

- **The comment may assert a protection the code does not provide.** `deleteStructureItem`'s comment
  says the mover "closes+unregisters the open Document" — true for a document, false for a group,
  and that gap is a live data-loss path (`M1-C-057`).
- **`.maugham/` is documented as derived and disposable, but `inbox/` holds the only copy of a
  dictated capture.** Three promote paths hard-delete an inbox asset partly because the surrounding
  directory says it is safe to.
- **Research notes have no op log and no checkpoint coverage.** Anything that overwrites one is
  unrecoverable, which makes `performFileSave` sharper than it looks.

## What to hand back

- The tests (passing), the claims, the filings.
- Coverage: reached / complies / violates / no-ruling.
- **Every gap, stated as the sub-ruling that would be needed** — phrased as a PRODUCT statement a
  non-programmer could rule on, never an implementation choice. Denver rules on product, not on
  `init?` versus a validating initialiser; a question in implementation terms cannot be answered and
  wastes the scarce resource.
- Anything you could not trace, marked `UNTRACED` rather than guessed.
