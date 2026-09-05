# ADR 0031 — The persona is an input to the run: two verbs over one substrate

**Date:** 2026-09-05 · **Status:** Accepted · **Milestone:** two-loops-p1-the-two-verbs (branch `claude/two-loops-p1-2026-09-05`)

## Context

M4 read M2's wet-ink check and M3's review round as *one loop at two tempos* with
an accidental wall between them, and unified the run. The unification was right
about the **data** — a finding is homed by its nature, a note on the prose is an
annotation ([ADR 0029](0029-the-compilers-report-is-materialized.md)) — and wrong
about the **trigger**. Read end to end, the code had one act,
`CompilerOrchestrator.runRequested`, serving two intentions, and the persona the
writer was standing in was not an input to it anywhere. Author's ⌘R and Review's
*Run round* built the same delta, sent the same six-section prompt, resolved the
same reader off the same Review-side memory (`ActivePassMemory`, written only by
the board chip and the cockpit picker), filed into the same lane, minted the same
pass-stamped notes, and differed only in which pane drew the answer.

**This had been ruled the other way and the reversal was never recorded.** The
one-loop spec's §7.0 (Denver, 2026-08-17) says: *"the byline in Author stays
'Claude' — the named editors belong to Review's pass lanes; wet-ink feedback is
not a pass."* The editorial letter spec's §4.1 (2026-08-29) says the opposite,
and calls it a feature: *"a writer finishing chapter 1 through Lish while
drafting chapter 5 gets Lish on chapter 1."* `PieceReader` built §4.1. So as
shipped in v0.35.0: ⌘R in Author on a chapter moved into Copyedit last week ran
Gould's round 4, signed its questions Gould, filed them in his lane, and put
*"Since round 3: 1 resolved · 2 persisting"* in Author's Diagnostics header. The
wet-ink check **was** a review round. Five checks while drafting inflated a
lane's round count by five before the reviewer sat down; the M2 "ordinary check,
no round, signed Claude" lane still existed in the orchestrator as
`ActivePass == nil`, but the coach's seat made it unreachable unless the writer
vacated her.

Two consequences followed from the same fusion. The round inherited the compile
loop's **mechanism** — "the delta since the marker", because that is what ⌘R had
always been — so a copyedit round read *3 new, 2 revised ¶*, which is not a
copyedit pass; editors read manuscripts, not diffs. And `DraftStage`, derived
from op-log statistics to dose the letter, was the compiler reconstructing a
tempo the writer had already declared one field away.

This is a textbook **mode error** in Norman's sense: one action produces
different results depending on state set elsewhere, with the mode indicator (the
reader line in Author's header) added afterward as a patch. His answer to a mode
error is never a better indicator; it is to stop making one control do two jobs.

**The step carrying more weight than it could hold** was binding the coach to
*assignment state*. The letter spec's own §2 calls coaching *a standing
relationship, not a stage of finishing*; its §4.1 then made her the reader of
"any piece with no active pass", which ends the relationship the moment a piece
enters Copyedit. A standing relationship that ends when the ladder starts is a
rung with a different name.

Design of record: `docs/superpowers/specs/2026-09-05-two-loops-two-readers-design.md`.

## Decision

### 1. Two verbs over one substrate, and the persona is what says which.

`RunKind` (`Maugham/Compiler/RunKind.swift`) is a two-case enum, `check` and
`round`. `RunKind.of(persona:)` is exhaustive over `Persona` — Review is the
round loop, every other persona that can reach a run is checking — so a fifth
persona is a compile error here rather than a silently defaulted ternary.

**It is minted at the keystroke, in exactly one place.**
`Maugham/Views/CompilerRunModifier.swift` is the only production file that calls
`RunKind.of(persona:)`, because it is the only site with a persona to mint from;
`TripwireGrepTests.test_theRunKindIsMintedFromThePersonaInOneFile` is the census
and `test_theRunKindMintCensusFiresOnAPlantedOffender` its planted offender. The
kind then travels: `runRequested(docId:kind:freshEyes:)` takes it as a **required**
parameter (a default would let a caller quietly file a round as a check, and
nothing about the run would look wrong), `StreamingRun` carries it, and
`CompilerRun.kind` stamps it into the per-document sidecar. A persona switch
mid-run belongs to the next keystroke.

### 2. A check's rules.

- **Who reads it is `AuthorReader`** (`Maugham/Models/AuthorReader.swift`,
  answered by `ProjectManifest.authorReader`): the coach while her seat is held,
  else nobody. **Per project, not per piece** — the seat is held over a book —
  and it reads no `ActivePassMemory` at all, so a chapter parked in Gould's lane
  is still read in Author by the seat.
- **It is filed in no lane.** No round number, nothing stamped on what it writes,
  no prior-round section in its briefing. The reader's name still signs its
  notes — a reader is not a lane — so a check's annotations are authored
  "Le Guin", or "Claude" over a vacated seat, and being unstamped they show under
  every pass in the queue, which is where a note about the prose belongs.
- **It owns the delta marker.** A check builds its delta `since:` the marker and
  advances the marker on success, including over an empty delta.
- **`DraftStage` doses it, and only it.** `beginRun` derives a stage for a check
  alone; `ProcessSignals` reaches a check's briefing alone.
- **Its cold variant is Reread** (⌘⇧R in Author, and the **Reread** button in the
  Diagnostics header): the same verb, the same reader, over the whole piece,
  with the warm session retired.

### 3. A round's rules.

- **Who reads it is `RoundEditor`** (`Maugham/Models/RoundEditor.swift`,
  `ProjectManifest.roundEditor(forPiece:memory:)`): the stage pass off
  `ActivePassMemory.validatedActivePass`, **never the coach** — she is
  deliberately absent from `effectiveReviewPasses`, so a stored `workshop` id
  reads as no pass at all.
- **`nil` is a refusal, not a fallback.** No stage, no round:
  `runRequested` flashes `Acknowledgment.noEditor` — *"Set a pass to run a
  round."* — and starts nothing. No session spawned, no marker moved, no record
  written, `runState` still `.idle`. A retired pass id refuses the same way,
  where under the single resolution it fell to the coach and quietly filed a
  round in her lane.
- **It reads the piece whole, every time.** Its delta is built `since: nil` and
  briefed under a `The piece, whole:` section. What changed since the last round
  reaches it through the prior-round and dispositions sections, not through a
  diff.
- **It neither reads nor moves the marker.** A round records the marker it
  *found*, so a check's next ⌘R begins exactly where its own last run left it,
  however many rounds happened in between.
- **It is always the full letter**, its brief deciding which parts. Fresh Eyes
  (⌘⇧R in Review) stays its cold variant.

### 4. What the two verbs still share, unchanged.

The warm `claude -p` session and its shutdown contract; confinement, which is
still [ADR 0028](0028-maugham-goes-outbound.md) §2's two flags (`--allowedTools`
pre-approves, `--tools ""` empties the built-in set, `--strict-mcp-config` scopes
the MCP surface); ingest-by-nature and the materialization
([ADR 0029](0029-the-compilers-report-is-materialized.md)); the fingerprint
dedupe; the dispositions briefing; the bible; the annotation layer and its whole
disposition vocabulary; conformance and continuity, which are the substrate's and
are not spoken in a voice. `CompilerPrompt`'s section schema is one schema:
`checkMessage` and `roundMessage` are two thin named doors over one builder, and
a check and a round over an unchanged intent hash identically.

### 5. Amending ADR 0029's framing by one sentence.

ADR 0029 said: *the compiler reads and never writes; its parsed report is
materialized by Maugham into the layers the writer already governs.* That still
holds exactly. What it did not say, because there was one loop when it was
written, is which loop asked. The amended sentence:

**The report is materialized by the app into the layers the writer governs, and
which loop asked for it is a fact the run carries.**

Nothing ADR 0029 §3 or ADR 0028 §2 decided moves: no tool was added to the
allowlist, no statement-writing tool exists in the allowlist or the catalogue,
`RulingPerformer` is still the one door into the writer-owned layer, and both
verbs run under the same two flags.

### 6. Re-affirmations and supersessions.

- **The one-loop spec's §7.0 is re-affirmed**: wet-ink feedback is not a pass,
  and an Author check's notes are never signed by a pass editor.
- **The editorial letter spec's §4.1 ("The seat") is superseded**, along with the
  parts of its §4.2/§9 that follow from it. Everything else in both specs stands.
  `PieceReader` is deleted.

### 7. The falsifiable clause.

**If a run ever resolves its reader from the other loop's memory, this decision is
violated.** `AuthorReader` reading `ActivePassMemory` would make an Author check
a stage editor's again; `RoundEditor` reaching for `effectiveCoach` would file a
numbered round in a lane that is not on the ladder. Both are asserted structurally
rather than intended:
`TripwireGrepTests.test_theCheckReaderNeverReadsTheBoardsMemory` fails if
`AuthorReader.swift` so much as names the memory,
`test_theRoundEditorNeverReachesForTheCoachsSeat` fails if `RoundEditor.swift`
names the seat, and `test_theTwoReaderCensusesFireOnPlantedOffenders` plants one
of each. `CompilerRunCommandTests.test_aCheckStampsNoLaneAndNoRoundEvenUnderTheCoach`
and `test_productionChecksAreTheCoachsWhateverTheBoardSays` pin the behaviour the
censuses guard the shape of. This is CLAUDE.md's tripwire 34.

## Consequences

- **The sidecar holds two standing runs, one per kind.** `DiagnosticsStore`'s
  `FileContent` gains `check` and `round` slots, each replaced only by its own
  kind, so a ⌘R no longer lands on the round the cockpit is showing and a round
  no longer takes Author's notes and delta marker. `lastCheck` is Author's pane,
  `lastRound` the cockpit; `lastRun` is the newer of the two, kept for the two
  questions that are about the document rather than either loop (the intent-drift
  mark and the unread badge, which is counted per kind and summed). The clause
  history and drift ring are fed by both — a clause strains across the writer's
  runs, not across one verb's — and the rounds ring, `standingRound` and
  `latestRound` are fed by rounds alone. A sidecar written before the split reads
  its single run into whichever slot its own `passId` says (`effectiveKind`), and
  the legacy keys are never written again.
- **The ask belongs to the loop it was typed in.** `DiagnosticsStore.asks` is
  keyed `(docId, RunKind)`: an ask to Le Guin and an ask to Gould are different
  sentences. A legacy asks file's bare-docId keys read as the check's.
- **The coach leaves the review board.** The board's seat row, the cockpit's
  coach arm and its `coachLine` are gone; the board is the ladder and only the
  ladder, and Project Settings keeps Vacate / Restore. Historical `workshop`-lane
  rounds in existing sidecars and op logs stay readable — a stamp says who wrote
  a note and vacating cannot unsay that — and are simply never counted again.
- **"A round needs an editor" is a precondition of a VERB, not a gate on a
  piece**, and that is the reconciliation with [ADR 0025](0025-persona-shell.md)
  §1's *lenses, not gates*. Nothing is withheld from a piece: every persona stays
  reachable on every project in every state, every pass stays available on every
  piece, and Author's check is never refused for any reason of assignment. What
  is refused is one verb whose output has nowhere to go — a numbered entry in a
  lane that does not exist. The remedy is a single click on the line saying so.
- **Two triggers keep their menu titles for now.** The File menu still reads
  *Check Writing* and *Fresh Eyes* in both personas; the per-persona rename is
  P3's. Author's ⌘⇧R already runs the check verb cold, and the Diagnostics
  header's **Reread** button is that verb under its own name.
- **A round's conformance strains are recorded and drawn nowhere.** They land in
  the round slot; Author's report is the check's and narrates no rounds, and
  Review has no conformance surface yet. That is a named carry, not an oversight.
- **The first reader is P2's.** `AuthorReader` ships with two arms, `coach` and
  `nobody`; `firstReader` is one more case, and `readerSection`,
  `read_first_reader` and the reader picker arrive with it. P1 keeps
  `CompilerPrompt.passSection` as the coach's frame on both kinds, read through
  `ActivePass.isCoach`.

## References

- `docs/superpowers/specs/2026-09-05-two-loops-two-readers-design.md` — §1 (the
  defect), §3 (Denver's decisions of record), §4 (the model), §4.11 (the
  constitutional accounting this ADR formalizes), §7 (the three plans)
- `docs/superpowers/specs/2026-08-17-one-loop-two-tempos-design.md` §7.0 — the
  ruling re-affirmed here
- `docs/superpowers/specs/2026-08-29-the-editorial-letter-design.md` §4.1 — the
  section superseded
- [ADR 0029](0029-the-compilers-report-is-materialized.md) — the framing amended
  by §5; §3's censuses unchanged
- [ADR 0028](0028-maugham-goes-outbound.md) §2 — the two-flag confinement table,
  unchanged
- [ADR 0025](0025-persona-shell.md) §1 — lenses, not gates; reconciled above
- `Maugham/Compiler/RunKind.swift`, `Maugham/Models/AuthorReader.swift`,
  `Maugham/Models/RoundEditor.swift` — the three types
- `Maugham/Compiler/CompilerOrchestrator.swift` — `runRequested(docId:kind:freshEyes:)`,
  `Environment.reader(_:_:)`, `Acknowledgment.noEditor`
- `MaughamTests/TripwireGrepTests.swift` — the three censuses cited in §7

## Constitutional accounting

- **Keystroke-only** (must-not #2, *no AI inside the editor*, whose invocation
  clause permits a run the writer starts with one keystroke while writing —
  "nothing ever runs unasked"; [ADR 0027](0027-the-compiler-and-the-editor-boundary.md)
  holds that as a position). ⌘R and ⌘⇧R remain the only triggers, and each persona's
  key does that persona's own act. The mode is not hidden: it is the persona the
  whole window already declares, chosen by ⌘1–⌘4 and visible in every column.
  **Violated if** any run starts without a keystroke — a check on save, a round
  on a pass-state write, a timer of any kind. Every timer in this area still ends
  a session; none starts one.
- **Nothing pushed** (must #2: *metrics are available when sought and never
  pushed — no streaks, no badges, no nagging*). This milestone adds no badge, no
  timer and no nag. The unread badge is counted per kind and summed, which is a
  narrowing of what one count can claim, not a new one. `Acknowledgment.noEditor`
  is a flash in answer to a press the writer made. **Violated if** a surface ever
  proposes a run the writer did not ask for, or counts one loop's work at the
  writer as a standing they must maintain.
- **AI is never the author** (must-not #1, unchanged). Both verbs read;
  Maugham writes, after the parse, from typed values. The statement layer still
  admits only writer-typed prose through `RulingPerformer`.
