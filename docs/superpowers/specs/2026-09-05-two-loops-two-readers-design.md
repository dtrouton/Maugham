# Two loops, two readers — the check and the round part ways

**Date:** 2026-09-05 · **Status:** approved 2026-09-05; P1 built 2026-09-05 (branch `claude/two-loops-p1-2026-09-05`, [ADR 0031](../../adr/0031-the-persona-is-an-input-to-the-run.md)); P2 built 2026-09-06 (branch `claude/two-loops-p2-2026-09-05`); P3 built 2026-09-06 (branch `claude/two-loops-p3-2026-09-06`); **milestone COMPLETE**. Open carries: a Review surface for a round's conformance strains (they are recorded in the round slot and drawn nowhere — Denver rules between a Conformance part in the cockpit's letter disclosure, which the recommendation favours, and minting them into the queue); `retireSession()` on a kind change, one line in `CompilerOrchestrator.ensureRunner` if a round after a long check ever reads tired; and §8's exclusions, unchanged
**Session:** "compiler / author / review split"

*Brainstormed with Denver 2026-09-05, out of a code reading of the seam between
Author's ⌘R and Review's rounds. Supersedes the editorial letter spec's §4.1
("The seat") and the parts of §4.2/§9 that follow from it; re-affirms the
one-loop spec's §7.0, which §4.1 had silently reversed. Everything else in
both specs stands. Denver's answers of record are inlined at each decision.*

## 1. The problem

M4 diagnosed M2 and M3 as *one loop at two tempos* with an accidental wall
between them, and unified the run. The unification was right about the
**data** — a finding is homed by its nature, a note on the prose is an
annotation — and wrong about the **trigger**. Read end to end, the code has
one act, `CompilerOrchestrator.runRequested`, serving two intentions, and the
persona is not an input to it anywhere:

- Author's ⌘R and Review's *Run round* build the same delta, send the same
  six-section prompt, resolve the same reader off the same Review-side memory
  (`ActivePassMemory`, written only by the board chip and the cockpit
  picker), file into the same lane, mint the same pass-stamped notes, and
  differ only in which pane draws the answer.
- **This was ruled the other way and the reversal was never recorded.** The
  one-loop spec's §7.0 (Denver, 2026-08-17): *"the byline in Author stays
  'Claude' — the named editors belong to Review's pass lanes; wet-ink
  feedback is not a pass."* The letter spec's §4.1 (2026-08-29): *"a writer
  finishing chapter 1 through Lish while drafting chapter 5 gets Lish on
  chapter 1"*, called a feature. `PieceReader` built §4.1. So today: ⌘R in
  Author on a chapter moved into Copyedit last week runs Gould's round 4,
  signs its questions Gould, files them in his lane, and puts *"Since round
  3: 1 resolved · 2 persisting"* in Author's Diagnostics header. The wet-ink
  check IS a review round.
- **Every ⌘R is a numbered round.** The M2 "ordinary check, no round, signed
  Claude" lane still exists in the orchestrator as `ActivePass == nil`, but
  the coach seat made it unreachable unless the seat is vacated. Five wet-ink
  checks in Author inflate a lane's round count by five before the reviewer
  sits down.
- **The round inherited the compile loop's mechanism.** A round is "the
  delta since the marker" because that is what ⌘R always was, so a copyedit
  round reads *3 new, 2 revised ¶*. A copyedit pass over a diff is not a
  copyedit pass; an editor reads the manuscript. The since-line no longer
  needs delta continuity — M4 P1 moved it onto the queue's own state.
- **`DraftStage` is the compiler reconstructing the tempo the app already
  knows.** It infers drafting-vs-revising from op-log statistics to dose the
  letter while the writer's own declaration of tempo — the persona — is one
  field away and never consulted.
- **The surfaces have been importing each other's controls** one smoke at a
  time under "one spelling, both homes": the cockpit gained the gear menu,
  the ask, Cancel and the letter disclosure; Diagnostics gained the reader
  line, the round line, the fresh-eyes line and queue rows with annotation
  verbs. Neither has a shape of its own. The one Review-only surface left is
  the queue's triage/stet/board, and it is fed by the same run.

**The step carrying more weight than it could hold** was binding the coach
to *assignment state*. The letter spec's own §2 says coaching is *a standing
relationship, not a stage of finishing*; §4.1 then made her the reader of
"any piece with no active pass", which ends the relationship the moment a
piece enters Copyedit. A standing relationship that ends when the ladder
starts is a rung with a different name. What she is in every other sentence
of that spec is the wet-ink reader. That one modelling choice fused the loops.

## 2. The frames this is designed against

**Norman.** The defect above is a textbook *mode error*: one action, ⌘R,
produces different results depending on state set elsewhere, with the mode
indicator (the reader line) added afterward as a patch. Norman's answer to a
mode error is never a better indicator; it is to stop making one control do
two jobs. Two more of his tests bite: the conceptual model must let the
writer predict what a control does before pressing it (today "Check
Writing", "Run Gould's round" and "Fresh Eyes" are three signifiers over one
mechanism with a hidden variable), and feedback must be proportionate to the
action — too much is worse than too little, because it stops being read. A
six-section report plus a letter in answer to "did that paragraph land" is
the wet-ink loop wearing the review loop's output.

**Composing as a cognitive process** (Flower & Hayes; King's door-closed /
door-open). Planning, translating and reviewing compete for the same working
memory, and premature reviewing is the classic way a draft stalls. So Author
does not merely want *lighter* feedback; it wants feedback that does not
switch the writer into reviewing. That is the principled reason a first
reader responds and never corrects.

**What holds up in the domain.** Three practices survive scrutiny:

1. **Reader response** (Elbow's "movies of the reader's mind", Gardner's
   fictional dream, Gaiman's rule that readers are almost always right about
   *that* something is wrong and almost always wrong about *what*): the
   reader reports what happened in them — where belief broke, where they got
   bored, what they now think is true. The `reader` section already encodes
   this. It lacks a *who*.
2. **The writer sets the agenda** (Lerman's Critical Response Process, peer
   response research): feedback is most usable when the writer names what
   they want it on and the responder answers that first. The ask field is
   this; it is currently one sentence shared across both tempos.
3. **Whole-manuscript rounds by altitude** (Perkins onward): a letter after
   a whole read, then line, then copy, in that order because a line edit on
   a chapter that gets cut is wasted. Editors read drafts, not diffs.

And one piece of folklore to resist: **there is no average reader.** King's
Ideal Reader is Tabitha, one person; Cooper's personas argument is the same
finding from software — an average user is nobody, and a design for nobody
fails everyone. A target reader defined as a demographic produces
demographic notes. Define **one** reader with a name, what they read, what
they will not tolerate, and pin the work they love.

## 3. Decisions of record (Denver, 2026-09-05)

- **Two verbs, one substrate.** Author's ⌘R is a *check*; Review's Run round
  is a *round*. They share the session, confinement, ingest-by-nature, the
  fingerprint dedupe, the dispositions briefing, the bible and the
  annotation layer. They do not share a reader, a lane, a round number, a
  delta rule or an output shape.
- **The persona is the tempo, and it is an input to the run.** Nothing is
  inferred that the writer has already declared.
- **Author has readers; Review has editors.** Author's readers are a small
  roster the writer asks: **the coach** (Le Guin, as built) and **one first
  reader** the writer defines by name. Review's editors are the ladder's
  passes (Perkins/Lish/Gould/Argus and custom), as built.
- **The coach is Author's reader, full stop.** She keeps reading a piece in
  Author after it enters a pass. Review never briefs her; she never files a
  round.
- **A round reads the piece whole.** No marker, every time. Cost is the depth
  menu's problem.
- **A round needs an editor.** No active pass, no round; the cockpit says so.
- **Fresh Eyes is Review's cold variant.** Author's ⌘⇧R is *Reread*: the same
  check, the same reader, over the whole piece, cold.
- **One first reader per project**, named, stable. Per-round steering is the
  ask's job. (King: one reader you learn to predict beats a flexible one.)
- **Continuity questions and conformance are the substrate's**, under
  whichever reader or editor is asked; they are not spoken in a voice.
- §7.0 of the one-loop spec is re-affirmed: wet-ink feedback is not a pass,
  and an Author check's notes are never signed by a pass editor.

## 4. The model

### 4.1 Two verbs

`CompilerOrchestrator` grows a second entry beside `runRequested`, and the
two are distinguished by a typed `RunKind` carried on `StreamingRun` and on
`CompilerRun`:

| | **check** (Author) | **round** (Review) |
|---|---|---|
| trigger | ⌘R in Author; ⌘⇧R = Reread (cold, whole) | Run round / ⌘R in Review; chip menu; ⌘⇧R = Fresh Eyes (cold) |
| who reads | the Author reader picker's choice: coach, first reader, or plain Claude | the piece's active stage pass (`validatedActivePass`), never the coach |
| what is read | the delta since the marker (Reread: whole) | the whole piece, every time; the marker is neither read nor advanced |
| session | warm; Reread retires it | warm across rounds in one lane; Fresh Eyes retires it |
| lane / round | none — `passId == nil`, no number | the pass's lane, numbered as today |
| briefed on | reader frame + description, dispositions, ask (Author's), lessons, intent essay/world/bible, delta | pass brief, prior round in this lane, dispositions, ask (Review's), lessons, intent/world/bible, the whole piece |
| letter | the coach's, dosed by `DraftStage`; the first reader's short form (§4.3); none for plain Claude beyond `about` | per pass brief, always full, as today |
| notes minted | continuity questions and reader reports as annotations, **unstamped**, author = the reader's name (coach or first reader) or "Claude" | as today: pass-stamped, signed by the editor, `runId`/`round`/`freshEyes` provenance |
| since-line | never | off the queue, as today |
| shows in | Diagnostics (⌘⌥D) | the cockpit + queue; the round's letter in the cockpit's disclosure |

**A check's notes are unstamped on purpose**: they show under every pass in
the queue, exactly as Le Guin's already do (guide: "her notes show under
every pass"), because a first reader's "I stopped believing here" belongs to
whoever edits the piece next.

**Persona is read at the keystroke and carried**, like the lane is today. A
persona switch mid-run belongs to the next keystroke.

### 4.2 Who reads, resolved once — but per tempo

`PieceReader` is replaced by two resolutions, each with one spelling:

- **`AuthorReader`** — `coach(ReviewPass)` / `firstReader(FirstReader)` /
  `nobody`. Chosen by the Author reader picker (§5.1), remembered per
  project in `UIState.authorReader`, defaulting to the coach while the seat
  is held, else the first reader if defined, else nobody. `coachVacated` and
  `effectiveCoach` keep their meaning; vacating with no first reader defined
  is the M2 all-altitudes "Claude".
- **`RoundEditor`** — the stage pass off `validatedActivePass`, or nil. Nil
  is not a lane; it is *no round possible*.

`ActivePassMemory` stays what it is: Review's memory of which pass a piece is
being read through. Author no longer reads it.

### 4.3 The first reader

**One per project.** King's Ideal Reader: a specific person the writer
writes toward, not a demographic. Two pieces of state, both writer-owned:

- `ProjectManifest.firstReaderName: String?` — nil means undefined. The
  byline, the picker label and the briefing's role frame read it.
- `Statement.Kind.firstReader` (raw `first_reader` — **amended 2026-09-06**,
  whole-branch review ruling P2-11: the spec said `first-reader`, but every
  sibling raw is snake (`visual_language`, `edition_brief:`, `lessons`) and
  the string goes on disk at first ship; the FILE stays kebab, file
  `first-reader.md`, **project scope only**, hosted by `StatementPane` like
  every statement). The essay is the writer's own description: who this
  reader is, what they read last, what they love, what they will not sit
  through. `## Rulings` under it are standing instructions to that reader
  ("always tell me where you got bored"; "she has read the first two books,
  so nothing about Marnie is new to her") — dated, itemized, through
  `RulingPerformer` like every ruling, and *Answer as ruling…* on one of her
  notes files there. Absent statement + present name = a reader with a name
  and no description; the briefing says so and the general reader
  instruction carries her.

**Defining one** is a Project Settings row (*First reader*, beside the coach's
seat row) that names her and opens the statement; the Author picker's
"Define a first reader…" item opens the same row. Renaming is a manifest
write. There is no delete beyond clearing the name; the statement stays as
prose.

**Her output is reader response and nothing else.** The `reader` section's
vocabulary widens from two kinds to four, still capped at the sharpest three
per check, still with the empty array as the ordinary answer:

| kind | what it reports |
|---|---|
| `belief` | what I now take to be true at this point |
| `dream_break` | where the fiction stopped holding me |
| `drag` | where I got bored, and would have skimmed or put it down |
| `lost` | where I no longer knew what was happening or who was speaking |

Her **letter** is the short reader form and the brief says so: `answer`,
`about`, `working` (as a reader: what I loved and why), and at most one
`question`. No `one_thing`, no `habits`, no `exercise`, no `scenes` — those
are a craft verdict, which is the coach's or an editor's. The same mechanism
pass briefs already use ("write only the parts your brief allows").

She **never uses craft vocabulary and never proposes a fix** — the reader
instruction says so in as many words. A first reader who says "the pacing
sags" has become an editor; she says "I started skimming around the
dinner." Her notes are signed with her name and unstamped.

**The pinned shelf is her taste.** The letter spec's own-bar rule ("measure
against the pinned work by name before any rule") is read for her as *this
is what she reads and loves* — pin the three books she would compare it to.

### 4.4 The coach, decoupled

Le Guin's brief, seat, letter, dosage and ledger verbs are unchanged. What
changes is *where she is bound*: she is an `AuthorReader`, not a function of
the board. Consequences, all removals:

- The board's seat row goes. The board is the ladder and only the ladder.
- The cockpit's coach arm goes (`coachLine`, the "Le Guin reads this piece"
  label, `coach:` parameter). With no stage set the cockpit reads *Set a pass
  to run a round* and Run round / Fresh Eyes are disabled with that reason.
- Her lane in the diagnostics sidecar mints no rounds; a check has no round.
  Historical `workshop`-lane rounds stay in existing sidecars and are simply
  never counted again (tripwire 11).
- Project Settings keeps Vacate / Restore where it is.

### 4.5 The round, whole

`beginRun` for a round passes `since: nil` to `DeltaBuilder` and does not
advance the marker (the marker is the check's). The prompt's delta section
becomes a whole-piece section; what changed since the last round is
communicated the way M4 P1 already does — through the dispositions section
and the prior-round section — not through a diff. The warm session across
rounds in one lane stays (cost), and Fresh Eyes retires it as today.

The queue-derived since-line, the rounds ring, `latestRound`, round
provenance on ops and the cross-lane count are untouched.

### 4.6 The sidecar holds one standing check and one standing round

`DiagnosticsStore` keeps one standing run per document today, and Author's
pane and Review's cockpit both read it. Under two verbs that would let a
check overwrite the round the cockpit is showing, or a round overwrite the
check the writer is reading. The file gains a second standing slot: `check`
and `round`, each replaced only by its own kind. `lastRun(docId:)` is split
into `lastCheck`/`lastRound`; `standingRound` reads the round slot; the
rounds ring and `latestRound` are fed by rounds only; clause history and the
drift ring are fed by both (conformance is the substrate's). A sidecar written
before the split reads its single run into whichever slot its `passId` says.

### 4.7 The ask, per tempo

An ask to your first reader and an ask to Gould are different sentences.
`DiagnosticsStore.asks` is keyed `(docId, RunKind)`; Author's field and the
cockpit's field read their own. Commit rules, limit, pending-buffer promotion
at `beginRun` unchanged. An existing ask migrates to the check slot (it was
typed in whichever home; the check is the safer owner).

### 4.8 Draft stage and dosage

`DraftStage` stays, and stays derived, but it now doses only the **coach's
letter on a check**. A round is always the full letter (its brief decides
which parts); Reread and Fresh Eyes are always full. The overlap is stated
rather than hidden: the persona says which loop, the stage says how far
along the draft is. The lane word ("· drafting") leaves the cockpit's lane
line; it stays on the check's signature in Author.

### 4.9 The briefing

Two message builders over `CompilerPrompt`'s existing sections rather than
one with more optionals:

- **`checkMessage`**: intent essay / world / bible / lessons (hashed unit),
  `readerSection` (role frame + the first-reader statement's essay + her
  rulings, or the coach's brief), scene position, stage, process, the
  dispositions, Author's ask, the delta, the schema. **No pass section, no
  prior-round section.**
- **`roundMessage`**: the hashed unit, `passSection`, scene position, the
  prior round in this lane, the dispositions, Review's ask, the whole piece,
  the schema. **No reader section, no stage section.**

The section schema is shared; a check under the first reader is told the
letter's short reader form the way a pass brief tells Gould to leave it
empty. `sectionSchemaDescription` gains the two reader kinds.

*P1 note (controller ruling, 2026-09-05):* P1 built `checkMessage`/`roundMessage`
as two named doors over the one builder, and kept `passSection` as the coach's
frame on **both** kinds — `ActivePass.isCoach` already frames her as a teacher
rather than an editor. `readerSection` arrives with P2, alongside the first
reader it exists to describe.

### 4.10 MCP

- `read_first_reader` — a fifth spine reader on `read_lessons`' exact shape:
  the first reader's name and statement, project scope, through the one
  `ProjectStore.statementText(of:)`. Claude reads it and never writes it;
  `CompilerAllowlistTests.statementWriters` stays as it is. Count moves by
  one.
- `get_outline` is unchanged. `list_annotations`' `author` already carries
  the reader's name.

### 4.11 Constitution and ADR accounting

- **AI is never the author / the compiler reads and never writes**: nothing
  moves. Both verbs run under ADR 0028 §2's two flags; ingest still
  materializes (ADR 0029). The first reader's statement admits only writer
  prose and `RulingPerformer`.
- **Lenses, not gates** (ADR 0025): "a round needs an editor" is a
  precondition of a verb, not a gate on a piece — every pass stays available
  on every piece, and Author's check is never withheld.
- **Keystroke-only**: ⌘R/⌘⇧R remain the only triggers; each persona's key
  does that persona's own act, which is an explicit mode the whole window
  already declares, not a hidden one.
- **Nothing pushed**: no new badge, timer or nag; the reader picker shows
  state the writer set.
- An ADR records *the persona is an input to the run* and the re-affirmation
  of one-loop §7.0.

## 5. Surfaces

### 5.1 Author — the Diagnostics pane

The header becomes: the **reader picker** (a menu whose label is the reader's
name — *Le Guin* · *Tabitha* · *Claude* — with "Define a first reader…" when
none is), the ask field addressed to that reader, the depth menu, the run
state line. Gone from the pane: the round line, the fresh-eyes line, the
since-line, the travel-to-Review click, the "Notes in your queue" wording
that named Review. The body is: the reader's letter or report, **This
check**, Conformance, drift. The empty state says *Press ⌘R and Tabitha
reads what you've written.* Reread (⌘⇧R) is offered beside the cold-start
offer's Read, in the same register.

### 5.2 Review — the cockpit and the board

The cockpit's lane picker offers stages only; the coach arm and the lane
word go; *Set a pass to run a round* replaces *Set a pass* and disables the
two buttons with that reason. The status line under it keeps the since-line
and the fresh-eyes header. The letter disclosure stays (it is the round's
letter). The ask field is Review's own. The board loses its seat row.

### 5.3 Project Settings

The coach's row (Vacate / Restore) stays; a **First reader** row joins it:
name, and *Edit description…* opening the statement in the right column.

### 5.4 Help

`docs/guide/compiler.md` becomes the check's guide (readers, Reread);
`docs/guide/review-passes.md` becomes the round's (editors, whole reads,
Fresh Eyes); the two stop cross-describing each other's controls.

## 6. The writer's experience — the loop this becomes

**Day 1.** New project → Novel → 800 words. *Press ⌘R and Le Guin reads what
you've written.* Same as today.

**Week 1.** Project Settings → First reader → "Tabitha — reads two crime
novels a month, hates a prologue, put down the last book at the dream
sequence." Pin the three books she loves. The Author header's picker now
offers her. ⌘R with Tabitha: *about*, one thing she loved and why, and
"I started skimming when the second detective arrived" as a note, jump chip,
Got it / Not this. No letter about habits. Switch back to Le Guin for the
craft read. No round numbers anywhere in Author.

**Week 6.** Chapter 1 to Review, chip → Structural. *Run Perkins's round*:
the whole chapter, a letter with a scenes table, questions in the queue
signed Perkins, round 1 in his lane. Back in Author, the next day's ⌘R on the
same chapter is still Le Guin's or Tabitha's, delta-scoped, no round, no
since-line. The reviewer's count is the reviewer's.

**The experienced writer** vacates the coach, defines a first reader who is
their actual first reader, writes a hostile custom pass brief for Review, and
uses each home's ask for what that home is for.

## 7. Sequencing — three plans (rule 11: each built before the next is written)

- **P1 — the two verbs.** `RunKind`; the persona threaded to the run; the
  check's reader resolved off `AuthorReader` (coach / nobody only — the first
  reader's arm lands in P2 as one more case) and the round's off
  `validatedActivePass`; a round reads whole and leaves the marker alone; the
  sidecar's two standing slots (§4.6); the ask keyed per tempo (§4.7);
  `DraftStage` doses checks only; Author's pane and the cockpit slimmed to
  their own controls (§5.1/§5.2, coach arm and seat row removed); "a round
  needs an editor"; Reread; the ADR; guide sweep for what P1 changed.
- **P2 — the first reader.** `firstReaderName`, `Statement.Kind.firstReader`,
  the Project Settings row and statement hosting, the Author picker's arm,
  the four reader kinds, the reader's short letter form, `readerSection`,
  the reader instruction, `read_first_reader`, guide.
- **P3 — the polish and the docs.** Per-tempo help copy, the supersession
  notes in the two prior specs, the roadmap flip, the problem map's
  "first reader" row, `docs/skills/editing-pass/SKILL.md` re-read against
  the split, the register/rulings sweep for anything that cited §4.1.

## 8. Out of scope

- More than one first reader per project; a first reader per piece.
- Personality dials on any reader or editor (still additive, still later).
- The book letter (whole-project Fresh Eyes) — it is a round at project
  altitude and gets its own brainstorm as the letter spec §10 says.
- A writer-editable brief for the coach.
- Any phone surface; the phone reads statements and annotations through
  existing tolerance.
- Auto-selecting a reader from the draft stage or the process signals; the
  writer picks.
