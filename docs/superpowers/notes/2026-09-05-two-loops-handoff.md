# Session handoff — "compiler / author / review split", 2026-09-05: spec + P1 plan written, nothing built

## State

- **Branch `claude/compiler-author-review-split-x5tv61`** (pushed to origin) carries docs only: the spec, the P1 plan, this note, supersession notes on two prior specs, and a roadmap line. **No code has changed.** The branch was cut from `origin/main` at `189e73e` (the tripwire-33 flake work). It was written in a cloud session with no Xcode; the laptop with the dev environment is where P1 gets built.
- Origin's `main` is `189e73e`. Local `main` on the laptop may be ahead (the editorial-letter handoff said the milestone shipped unpushed, then v0.35.0 was released — check `git log origin/main..main` before assuming anything).

## First ten minutes on the laptop

```
git fetch origin claude/compiler-author-review-split-x5tv61
git checkout main && git merge --ff-only origin/claude/compiler-author-review-split-x5tv61   # docs only; if not FF, rebase the four doc commits — nothing else is on it
git checkout -b claude/two-loops-p1-2026-09-05
./gen.sh && ./scripts/test.sh          # green baseline before a line moves
```

Then read, in this order:

1. `docs/superpowers/specs/2026-09-05-two-loops-two-readers-design.md` — the spec. §1 is the finding (read it even if you think you know it: the one-loop §7.0 → letter §4.1 reversal is the whole story), §3 the decisions, §4 the model, §7 the sequencing.
2. `docs/superpowers/plans/2026-09-05-two-loops-p1-the-two-verbs.md` — P1, ten tasks, subagent-driven. **Its `file:line` references were taken from `189e73e` and are already approximate** — every task says so; re-derive by grep before editing.
3. `Maugham/Compiler/AREA.md` §"who reads a piece" (`:227-263`) and `Maugham/Compiler/CompilerOrchestrator.swift` `beginRun` — the two places P1 cuts.
4. `docs/superpowers/notes/2026-09-02-editorial-letter-handoff.md` — the previous milestone's table of where things live; still accurate for everything P1 does not move.
5. This note's "Decisions made on Denver's behalf" and "Carries".

Add a memory entry at `~/.claude/projects/-Users-denver-src-Maugham/memory/` for this milestone (the cloud session cannot write there): the finding, the spec path, the three-plan shape, and that P1 is the first plan.

## The finding, in one paragraph (so a fresh session does not re-derive it)

`CompilerOrchestrator.runRequested` is one act serving two intentions and the persona is not an input to it. Author's ⌘R and Review's Run round build the same delta, send the same six-section prompt, resolve the same reader off `ActivePassMemory` (written only by Review's board chip and cockpit picker), file into the same lane, mint the same pass-stamped notes, and differ only in which pane draws the answer. The one-loop spec's §7.0 (Denver, 2026-08-17) ruled *wet-ink feedback is not a pass; the byline in Author stays "Claude"*; the letter spec's §4.1 (2026-08-29) bound the coach to "any piece with no active pass" and thereby let a stage editor sign Author's checks and number them as rounds — a reversal never recorded as one. Norman's name for the result is a mode error. The fix is two verbs over one substrate, with the coach as Author's reader full stop.

## Decisions made on Denver's behalf (in the spec and plan; rework any he disagrees with)

1. **The sidecar gets two standing slots** (check and round) rather than one, so neither loop's standing run overwrites the other's. Legacy sidecars load by `passId` (nil → check). This is P1's one storage-shape change and it is per-device, derived, and needs no migration.
2. **The ask is per tempo** — keyed `(docId, kind)`. Existing asks migrate to the check slot. The guide's "both homes show the same field over the same sentence" is rewritten in Task 6.
3. **Author's ⌘⇧R is *Reread*** (same reader, whole piece, cold, no round) rather than being withdrawn from Author. The alternative — Author has one key and a whole-piece verdict is Review's business — was considered and rejected because a writer returning after two weeks away wants exactly that from Le Guin, and the cold-start offer already promises a whole read on first contact. Denver did not rule on this explicitly; he agreed the spec as a whole.
4. **A round needs an editor**: no stage set → the cockpit's buttons are disabled with a reason and ⌘R in Review flashes *Set a pass to run a round.* and starts nothing. The chip menu is unaffected (a chip always names a pass).
5. **In P1 the Author reader line is a plain label** ("Le Guin reads this piece" / "Claude reads this piece"), not yet a picker — with only coach/nobody there is nothing to pick between. P2 turns it into the picker when the first reader gives it a second arm. The travel-to-Review click is removed in P1 because it IS the mode-error patch.
6. **The File menu keeps "Check Writing" and "Fresh Eyes" for both personas in P1.** A per-persona menu title is awkward under SwiftUI `Commands` (the key window's persona is not in scope there); P3 decides whether to rename to "Check / Reread" and "Run Round / Fresh Eyes" via a focused-value, or leave it.
7. **A round's conformance strains are recorded in the round slot and drawn nowhere in P1.** Today the Diagnostics pane in Author draws whatever the single standing run's strains are, which after P1 is the check's. Review has no strain surface. See carry #1.
8. **The rounds ring is rounds-only.** A superseded check never enters it. `latestRound` and the since-line are unaffected by checks — that is the point.
9. **`DraftStage` survives, doses checks only.** The spec is honest that persona (which loop) and stage (how far along the draft is) are two axes; a round is always the full letter.

## Carries (open, deliberate, not P1's)

1. **A round's strains have no Review surface.** Conformance is the substrate's under both verbs, but only Author draws strains. Options for P2/P3: the cockpit's letter disclosure grows a Conformance part; or a round's strains mint as annotations (contradicts one-loop §2's "strains stay report-side"). Denver to rule. Until then a round records them and nobody sees them.
2. **The menu titles** (#6 above).
3. **The first reader is P2** — spec §4.3 in full: `firstReaderName`, `Statement.Kind.firstReader`, the Project Settings row, the picker's arm, the four reader kinds (`belief`/`dream_break`/`drag`/`lost`), the short reader-form letter, `readerSection`, `read_first_reader`. P2 is written AFTER P1 is built (rule 11) and against the built `AuthorReader`.
4. **The editing-pass skill** (`docs/skills/editing-pass/SKILL.md`) and the register's rulings that cite the coach seat — P3's sweep.
5. **The book letter** (letter spec §10) is now clearly a *round* at project altitude; its brainstorm should start from `RunKind.round` with a project-scoped whole-piece section.
6. **Warm session across kinds.** One session per window still serves both verbs; a round after a check re-sends the pass section (already per-run). If Denver finds a round after a long check session reads "tired", the fix is `retireSession()` on a kind change — one line in `ensureRunner`, deliberately not done in P1.

## What P1 must leave true (the smoke, in Denver's hands)

Open Playlist → Author → a chapter with a stage set in Review → ⌘R → header *Le Guin reads this piece*, no since-line; Review's cockpit still shows the round number it showed before → Review → Run round → *Reading the whole piece…* → round N+1, notes signed by the editor, since-line present → Author → ⌘R → still Le Guin, no round → board: clear the piece's pass → cockpit says *Set a pass to run a round*, buttons dead with a reason → ⌘R in Review → capsule *Set a pass to run a round.*, nothing runs → Project Settings → Vacate → Author ⌘R → *Claude reads this piece*, notes signed Claude → Restore.

## P1 built — (appended by the implementing session; Task 10)

*(empty until P1 lands)*
