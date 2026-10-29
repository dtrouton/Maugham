# Maugham/Compiler — history

Moved from `Maugham/Compiler/AREA.md` on 2026-10-18 by foundations plan 5. History and rationale; not required reading. The guide is the current truth.

This is the whole guide as it stood at `aadac856`, word for word under its original headings (its first heading is demoted one level beneath this one); only relative links were re-pointed so they resolve from `docs/history/`.

## Compiler — Area guide

Maugham's **author compiler** (M2, rewired to the review queue in M4 P1, split
into two verbs in two loops P1): the writer presses ⌘R and a warm `claude -p`
session reads the piece — **what** it reads is the persona's, not the
keystroke's (`RunKind`, ADR 0031). Author's ⌘R is a **check** over what has
changed since its own last one; Review's is a **round** over the piece whole.
Either way each finding lands where its NATURE says it belongs (ADR 0029;
spec `2026-08-17-one-loop-two-tempos-design.md` §2) — a conformance strain
stays report-side as a ¶-anchored diagnostic in the Diagnostics pane; a
continuity question or a reader's report mints as an annotation instead
(pass-stamped over a round, unstamped over a check), a margin card in Author
and a queue row in Review, with the full
disposition vocabulary every other note already has. Read this before editing
in `Maugham/Compiler/`. Also read the project root `CLAUDE.md` for
cross-cutting invariants, the design of record —
`docs/superpowers/specs/2026-08-04-m2-author-compiler-design.md` — its
supersession —
`docs/superpowers/specs/2026-08-07-compiler-second-draft-design.md`, which
keeps the run's mechanism unchanged (§5's opening line) but replaces the
workflow half: notes, fates, the answer flow and the pane's organization —
`docs/superpowers/specs/2026-08-17-one-loop-two-tempos-design.md`, which routes
findings by nature and personifies each pass as a named editor — and
`docs/superpowers/specs/2026-09-05-two-loops-two-readers-design.md`, which
parts the check from the round (all three plans built, 2026-09-05/06: P1's two
verbs, P2's first reader, P3's per-persona menu titles and skills).

**The run speaks the v2 contract** (spec §5), M3-P3 added a fifth line to it
and the editorial letter (P1 Task 2) a sixth: four line-delimited note sections
— conformance against the writer's derived clauses, continuity questions, a
reader's report (`DiagnosticIngest.readerKinds`: `dream_break`/`belief`, plus
`drag`/`lost`, which two loops P2 added to the schema for every run — only the
first reader's own `firstReaderInstruction` names the four, so in practice
they are hers), and fact-candidates that land silently in the bible — plus
`intent_drift`, a verdict on the reading as a whole rather than a thing found
in it, plus `letter`, an editorial letter about the manuscript as a whole
(`Letter`, on `CompilerRun.letter`). **The letter is asked LAST**, so the
writer reads line-level results while it is still being written, and it is the
one section whose parts are prose rather than findings — with one exception:
each of its questions that resolves a ref also mints a `.letterQuestion`
diagnostic, which reaches the queue as a `.query` and never the sidecar. Two
rules are the letter's alone (spec §3.1, global constraint 8): a dangling ref
costs a letter entry its jump links and not its prose (`letterRefs`, beside
`resolveRefs`, which drops such an entry for every other section), and neither
a dangling ref nor a cap moves `droppedDangling` — the letter is not a note.
The two scrubs are asked of different things (`letterProseLeaksAnId`): EVERY
prose field is scrubbed for a leaked paragraph id and the entry dropped
(`about`/`one_thing` are fields rather than entries, so they empty instead),
while the fix-shape scrub stops at `questions`, the one part that leaves the
letter and becomes a `.query` the writer must be able to answer — `exercise` is
exempt because a Le Guin feed-forward is a directive by nature. Neither scrub
moves `droppedDangling` either.
**The letter's scene table has a position, and the run decides it** (spec
§3.4, P1 Task 3). `ScenePosition.derive` reads three things the writer owns —
the project's type, their intent statement and the reading verb's own brief (a
round's stage doctrine; for a check, `AuthorReader.brief`, which only the coach
answers — a first reader's statement is who she is rather than an instruction
about form, so it is never read as one) — and
answers `none` (no table at all), `weak` (rows, charge always null, no conflict
field, a blank `changes` read as an observation) or one of the two strong
forms; `CompilerPrompt.scenePositionSection` states it in one sentence per run,
so the model is TOLD its position and never asked to infer one. **The
`strongDeclared`/`strongDefault` split is the doctrine**: a turn-less scene is
a conformance strain ONLY where the writer's own words carry the clause it
strains against, because conformance is keyed on a `clause_quote` from the
intent statement and nothing here may synthesize one on their behalf. Reached
any other way — a screenplay whose intent is silent, a prose piece opted in by
a pass brief — it stays an observation and the gap belongs to the
Add-to-intent offer (Task 9). Two rules are easy to get wrong: the derivation
reads the **WHOLE** statement rather than `StatementEssay.half(of:)`, because
that offer files its clause under `## Rulings`
(`CompilerRunCommandTests.test_theDerivationReadsTheRulingsHalfAndNotJustTheEssay`
is the call site's own guard), and the writer's explicit **opt-out beats
everything**, including a clause elsewhere in the same statement. The position
is derived at the keystroke, carried on `StreamingRun`, and stamped onto
`Letter.scenePosition` in the one `record(...)` spelling, so a preview and the
answer that supersedes it cannot disagree — its raw values are a disk format.

**The writer's ask lives beside the sidecar, never inside it** (spec §3.7, P2
Task 3), **and is keyed per document PER TEMPO, not just per document** (two
loops P1 Task 6). `DiagnosticsStore` keeps one per-device file for the whole
project, `.maugham/diagnostics/asks.<slug>.json`, keyed through the private
`askKey(docId:kind:)` = `"\(docId)#\(kind.rawValue)"` (`asksURL` — a filename
of its own, and one more place `.raw` is interpolated, tripwire 24). The check
and the round are different readers of the same document — Author's header
asks the reader who checks, Review's cockpit asks the editor who runs the
round — and the two sentences are independent for the same document: setting,
noting or committing one kind's ask never touches the other's. A **legacy
file** written before this task holds bare `docId` keys with no `#`; `loadAsks`
reads a bare key as `.check` (every ask on disk before this task was Author's —
the round cockpit had no field yet) and the in-memory dictionary is keyed in
the new shape from that point on, so the very next `persistAsks()` — any
`setAsk` call — rewrites the whole file under new keys only and the bare key
does not survive. It is NOT a field on `FileContent`, and the reason is that
the sidecar is written by a run: an ask is typed *before* one, so a writer can
ask something of a document the compiler has never read, and there would be no
`CompilerRun` to hang it off. The field itself commits on submit and on focus
loss and never per keystroke (`AskField`) — `setAsk` rewrites the file and
bumps `version` on every call — while every keystroke is *noted* into an
in-memory `pendingAsks` buffer, keyed the same way as `asks`, that writes
nothing. `CompilerOrchestrator.beginRun` calls `commitPendingAsk(docId:kind:)`
with its own `kind` and then reads `ask(docId:kind:)`, which is why a worry
typed and not submitted still reaches the round it was typed for: ⌘R is a menu
command that never touches the first responder, and `beginRun` is the one line
every trigger passes (both keystrokes, the cockpit's buttons, the cold-start
offer) — and why a check's pending draft can never be promoted by a round, or
the reverse. `setAsk` REFUSES over `DiagnosticsStore.askLimit` and answers
`false` rather than throwing — nothing failed, and the writer keeps their words
in the field to shorten. The ask is then carried on `StreamingRun.ask`, stamped
onto `Letter.asked` in the same `record(...)` spelling the position uses, and
briefed through `askSection` — **outside `briefingHashInput`**, because an ask
is expected to change every round and a hash covering it would re-embed the
essay, the declared world and the bible slice on every ⌘R a writer asked
anything on.

**The lessons ledger is a statement, and the briefing folds the SECTION rather
than the file** (spec §6, P2 Task 4). `LessonsLedger` is the grammar: a `##
Rulings` row of the `.lessons` statement reads as a live lesson, a settled
`Choice: `, or a `(retired <date>)` entry, over the ruling's TEXT and never the
whole line. `Environment.lessons` reads it whole, `CompilerPrompt.lessonsSection`
renders the preamble, the open lessons and the choices (a retired entry is
briefed to nobody), and that RENDERED section is what `briefingHashInput` folds
— not the ledger's markdown. Hashing the file would mean retiring one entry,
which only ever *removes* something from the briefing, re-embedding the essay,
the whole declared world and the bible slice to communicate a deletion. The
ledger sits inside the hashed unit beside the essay, the declared world and the
bible slice because it is something the writer DECLARED; the ask sits outside it with the per-run frame.
**Identity is the heading, decided app-side** (`LessonOffer.retirable` narrowing
the letter's own `retired` list to the ledger's live lessons through
`LessonsLedger.matches`, exact after trimming and case-sensitive), so a heading the model re-spelled draws no offer
rather than retiring a row the writer never named. **Every write goes through
one file**, `Maugham/Views/LessonLedgerVerbs.swift` — the only production file
that names `.lessons` to `RulingPerformer`, censused by
`TripwireGrepTests.test_theLessonsLedgerIsWrittenFromOneFile` with a planted
offender and a companion that catches a `revoke(` as well as a `rule(`.

**`ProcessSignals` is a pure value over `(ops, sequence, now)`, and the
draft stage it feeds is derived, never set** (spec §3.8/§5, P3 constraints
20–24). It reads no store and no clock of its own — the same `DocumentReading`
`DeltaBuilder` already takes — so `CompilerOrchestrator.beginRun` computes it
at the keystroke and the Statistics window's `ProjectPractice` computes the
identical thing per closed document off `OpLogStore.loadSyncMerged`, and the
two cannot disagree. A session is a run of manuscript ops (filtered through
`Deriver.appliesToManuscript`, never a local re-switch) split where `Op.session`
changes or where consecutive ops are at least `SessionTracker.idleThreshold`
apart — the one constant, hoisted out of `DocumentStore.sessionIdleThreshold`,
that keeps the op-derived session and the Statistics window's own session
agreeing on the number. `DraftStage.derive(counts:signals:)` reads the run's
own `DeltaCounts` plus the signals: `counts.new <= counts.revised` is always
`.revising`; past that, no signals taken (no reading, decided on counts alone)
is `.drafting`, and a reading is `.drafting` only when the frontier moved in
the latest session (`sessionsSinceFrontierMoved == 0`) — a document with no
frontier at all (nothing was ever typed new in Maugham) reads as `.revising`
whatever the counts say. **It is derived for a CHECK alone** (two loops P1 Task
4, spec §4.8): a round is always the full letter, so `beginRun`'s `stage` is a
`DraftStage?` that is `nil` for a round, and both its readers — the briefing's
`stageSection` and ingest's dose — fall back to `.full` off that one `nil`
rather than remembering the rule twice. Its only persisted trace is
`Letter.stage` (a rawValue, `ScenePosition`'s disk format), stamped in the same
`record(...)` spelling that stamps `scenePosition` and `asked` — where `nil`
leaves the field unset, which is the field's own tolerated-missing case; nothing
else remembers it.
**Dosage is enforced at both ends**
(constraint 24): `LetterDosage.short` caps `parseLetter`'s questions at 1,
drops the exercise and reads `scenes` as `nil` **at ingest**, whatever the
model wrote, and `CompilerPrompt.stageSection` states the identical doctrine
in the briefing; a cold read is always `.full` (the dose keys on `freshEyes`,
so Author's Reread and Review's Fresh Eyes are the same case here), a round is
always `.full`, and the ask's answer is never dosed. **`LetterDosage.reader`
(two loops P2 Task 3) is the one dose that is not a stage's**: the first
reader's letter keeps `answer`, `about`, `working` and one question, and drops
`one_thing`, every habit, the exercise that goes with one, the scene table, the
`retired` list and the `process` line at ingest whatever the model wrote —
`allowsOneThing`/`allowsHabits`/`allowsProcess` are the three flags that say so
(the first two are the P2 Task 3 pair; `allowsProcess` came out of that task's
review, ruling P2-6), and `CompilerPrompt.firstReaderInstruction` is the
briefing half. The four kinds she reports are `DiagnosticIngest.readerKinds` —
`dream_break`, `belief`, `drag`, `lost` — and the instruction names them in
that order, pinned by
`test_theReaderInstructionNamesTheFourKindsInTheSchemasOrder` so the two lists
cannot drift; `CompilerNote.readerKindLabel` is the other half of the pair
("Dream break"/"Belief"/"Drag"/"Lost").
Which dose a run gets when a first reader reads a drafting piece is the
orchestrator's answer, not this enum's. `stageSection` and the noteworthy-only
`processSection` are per-run frame, sitting between the scene position and the
prose **inside the prompt's `.check` arm** (Task 4 — the numbers describe the
writer's process, which is what a check is read against), and **neither
folds into `briefingHashInput`** (constraint 25) — the stage flips the moment a
writer stops adding and starts rewriting, and the process numbers move with
the writer's own week, so hashing either would re-embed the essay, the
declared world and the bible slice on an ordinary run. `letterInstruction`'s
`process` sentence is standing text rather than per-run frame — it tells the
model what the `Process` heading MEANS, once, the same way the rest of
`letterInstruction` explains every part — so it IS measured into the 715-word
budget (651 → 635 once tightened → 654 with the sentence back), unlike
`stageSection`/`processSection` themselves. The lane word has one
source, `DraftStage.laneWord`, read by exactly `LetterKeep.swift` and
`LetterSection.swift` (a `.laneWord` census with a planted offender).
**Review's cockpit was the first of those two until two loops P1 Task 8** and
is not any more: the draft stage is a CHECK's derivation and a round is always
read full, so the word on Review's lane line was the other loop's copy. The two
remaining readers do not share one rule: `LetterKeep.stageWord` appends it only
beside a NAMED round — never over the coach's un-rounded (legacy) introduction,
because that line names who read the piece, not a run's result — while
`LetterSection.signature` appends it whenever a stage was derived, round or
not, because the signature is built off the one run that wrote this letter
and that run's stage is its own fact (RULING-R14b; a passless run still signs
"— Claude · revising", `LetterSectionTests.test_theSignatureCarriesTheStageTheRunDerived`).
`LetterKeep.laneLine` reads the stage off the letter's own
stamp rather than re-deriving it, so a kept letter names the stage the run
that wrote it saw; `QueueLedgerVerbs.provenance` passes `stage: nil`, because
an annotation filed from the queue carries no run of its own to have derived
one. **Nothing about the signals reaches the footer, the tree or the editor**
(constraint 29, constitution must #2) — the Statistics window's `Practice`
section and the letter's `process` line are the only two surfaces, held by a
negative census with its own planted offender.

**A letter question can carry the habit it was raised under, and the stamp has
a wire** (P2 Tasks 2/4). `parseLetter` caps the habits FIRST and takes the
citable names off the capped list, so a habit the letter does not show cannot
stamp a question about it; the model's `habit` key is then matched against those
names through `LessonsLedger.matches`, and a near-miss stamps nothing. **The
citation is matched on the habit's `name` and the stamp is its `ledgerHeading`**
(`Letter.Habit.ledgerHeading`, the lesson sentence else the name) — the name is
what the schema asks the model to cite, and the heading is the one identity the
ledger knows a habit by, so the queue's *This is a choice* files exactly what
the letter's own *Keep as lesson* would. Stamping the name instead put one habit
in the writer's ledger under two identities, and every later round was then
briefed to work on it and to never raise it. The
heading rides `Letter.Question.lessonHeading` for the section to draw and
`Diagnostic.lessonHeading` for the mint, which puts it on
`Op.Provenance.compilerLessonHeading` and so onto `Annotation.lessonHeading` —
what the queue's *This is a choice* and the second-stet offer read. It never
reaches the sidecar: the sidecar keeps conformance strains alone.

`CompilerPrompt.sectionSchemaDescription` is what is asked for and
`DiagnosticIngest.parseSection`/`parseAll` is what reads it. **The v1 contract
is gone**: `runMessage`, `CompilerContext` and `DiagnosticIngest.parse` were
retired in Stage 2's own docs task once the atomic switch (below) proved they
had no production caller — a grep for `runMessage(` today finds nothing at
all, not even a test.

One thing v1 had that v2 still does not: a free-form category tag (the section
a note came from is its whole classification).

**The word "drift" now names two separate things, and they must never be
merged.** `DriftDetector`/`DriftFinding` are M2's clause-strain PATTERN across
run records — the same clause straining for `consecutiveRunsThreshold` runs,
surfaced as `DiagnosticsPane.driftNote`. `intent_drift` is M3-P3's per-round
JUDGEMENT, a `holds`/`drifted` verdict the model returns in the fifth section
and the run record carries on `CompilerRun.intentDriftVerdict`. They have
different inputs, different lifetimes and different surfaces; the wire word is
`intent_drift` and the app word for the pattern is `drift`.

Two sentences hold the whole design:

- **The keystroke is the only trigger.** Nothing here reaches for itself. A run
  on every pause is the background linter the constitution excludes (must-not
  #2), and every timer in this area exists to end a session, never to start one.
- **The compiler reads and never writes.** It reads the manuscript through an
  enumerated read-only MCP allowlist and answers with a structured message; the
  spawned model never calls a tool that mutates anything. **What puts words
  anywhere is Maugham itself, after the turn is over, materializing the parsed
  report into the layers the writer already governs** ([ADR
  0029](../adr/0029-the-compilers-report-is-materialized.md), amending
  [ADR 0028](../adr/0028-maugham-goes-outbound.md) §3's framing): a
  continuity question or a reader's report becomes a pass-stamped annotation
  (`Environment.mintAnnotations`, M4 P1 Task 3), a fact-candidate a bible entry,
  and a kept conformance strain a promoted task. The one route into a
  *statement* — the yardstick the compiler is judged against — is still only
  `RulingPerformer`, and its input is still a sentence the writer typed. (The M2
  answer shim that routed into it, `IntentAppendPerformer`, is gone: the pane's
  reply field calls the verb.)

**Each pass is a named editor, and the resolution has one spelling** (M4 P1
Task 1, `ReviewPass.swift`). The four presets ship as **Perkins** (Structural),
**Lish** (Line), **Gould** (Copyedit) and **Argus** (Proof), each carrying a
seeded `brief` — what its rounds attend to, and as sharply what they leave
alone — and an `editorName`. A pass's own `brief`/`editorName` field wins when
set; a customized manifest can store a preset-id pass that predates both
fields, so every reader resolves through `ReviewPass.effectiveBrief`/
`.effectiveEditorName` rather than the raw fields. `AuthorReader` and
`RoundEditor` (`Maugham/Models/`) are the COMPILER's two call sites — every
run's voice and brief resolve through one of them, and `AuthorReader`'s own
comment names why reading `pass.editorName` directly would sign a Copyedit
round's notes with nothing at all — while the surfaces that merely NAME a lane
(the cockpit, the board, the settings sheet, `get_outline`) resolve for
themselves at the point of display.
A custom pass with no brief of its own and no matching preset gets the honest
fallback: attend at the altitude the pass's name suggests.

The resolved name is read by the **annotation author** on every note that pass
mints (`CompilerMintContext.editorName`, so the queue's author filter becomes
"everything Gould flagged") and by the round briefing's **role frame**
(`CompilerPrompt.passSection`, "You are Gould, this manuscript's Copyedit
editor"); the pass's own brief rides the same briefing, so attention follows
the register the writer chose. Grep `effectiveEditorName` for the readers
rather than trusting a number here — the display surfaces resolve for
themselves and nothing censuses them.

**Who reads a piece has TWO resolutions, because there are two loops** (two
loops P1 Task 2, spec §2; ADR 0031 §2–§3, and CLAUDE.md's tripwire 34).
`PieceReader`, the single resolution these replaced, is deleted. Author's ⌘R is a **check**; Review's Run is a
**round**; `RunKind` says which, minted from the persona at the keystroke, and
since two loops P2 Task 4 the two loops have **two closures with two answer
types** rather than one taking the kind: `Environment.authorReader(docId)` →
`AuthorReader` and `Environment.roundEditor(docId)` → `ActivePass?`
(`CompilerEnvironment+Project.swift`). A verb asking the other loop's question
does not type-check, which is what a `switch kind` over one answer type could
never say — and it is what let the first reader out of the pass-shaped seam
that could only describe her as nobody.

A **check** is `ProjectManifest.authorReader(choice:statementText:)` →
`AuthorReader`: the roster's choice where its subject is still there, else the
default rule — the coach while her seat is held, else a named first reader,
else nobody. The choice is `UIState.authorReaderChoice`; the first reader's
description is read from her statement **at the keystroke**, per run, cached
nowhere, because it is prose the writer edits in a pane between one ⌘R and the
next. It is per PROJECT and takes no piece, and it
reads no `ActivePassMemory` at all — what lane a chapter is parked in on the
review board is the round loop's fact. So an unassigned piece is Le Guin's to
READ, and a piece parked in Gould's lane is *also* hers to read in Author. A
check files in **no lane whatever**: `beginRun` stamps `passId` only for a
round, so a check mints no round number, stamps nothing on what it writes, and
is briefed on no prior round. Her name still signs its notes, which is the
distinction the split turns on — *a reader is not a lane*. `nil` — a vacated
seat — is the passless lane: notes signed "Claude", M2's identity, unchanged.
`CompilerOrchestrator.passlessEditorName` has exactly one production use, in
`AuthorReader`'s *nobody* arm, and
`TripwireGrepTests.test_thePasslessEditorNameHasExactlyOneProductionUse` keeps
it that way.

A **round** is `ProjectManifest.roundEditor(forPiece:memory:)` → a `ReviewPass?`:
the stage the writer put this piece in, validated through
`ActivePassMemory.validatedActivePass` against `effectiveReviewPasses`. It is
**never the coach** — she is deliberately absent from that list, so a stored
`workshop` id resolves to nothing — and `nil` is a REFUSAL rather than a
fallback: `runRequested` flashes `Acknowledgment.noEditor` ("Set a pass to run
a round.") and starts nothing at all — no session spawned, no marker moved, no
record, `runState` still `.idle`. A **retired** pass id refuses the same way;
under the old single resolution it fell to the coach and quietly filed a round
in her lane. `beginRun` re-asks after the hops (#77 G1/F6): a stage cleared or
a pass retired while the settled posture or the burst flush was on its way
refuses the same way (a second `.noEditor` flash after `.started`), rather than
filing a passless "Claude" round.

**A round is also the piece-writer's** (signed op log P3c Task 6, plan ruling
R4). Below the `noEditor` refusal, a round asks `Environment.mayRunRound(docId)`
— production answers it with `DocumentStore.settledPosture(forDocId:)
.allows(.runRound)`, the ACTING door, so the closure is `async` — and a `false`
flashes `Acknowledgment.notYourPiece` and starts nothing, in `noEditor`'s exact
shape. While it asks, the press holds the in-flight gate (a second press is
"still checking") and the `.started` flash waits for the answer. A CHECK is
never asked: it writes unstamped notes, which is the reviewer row. The cockpit's
Run/Fresh Eyes, the board chip's *Run round*, and every pass-state ruling (both
inspectors' ladders, the chip menu, the pass-order nudge — one spelling,
`PassLadder.offersRulings(under:)`) are not drawn where the posture refuses;
the board's chips themselves always draw. `setPassState` stays unguarded at
storage — roles guard the words, not the binder.

Two censuses keep the two inputs apart, each with a planted offender:
`TripwireGrepTests.test_theCheckReaderNeverReadsTheBoardsMemory` (no
`activePassMemory` in `AuthorReader.swift`, and exactly one read in the
wiring's `roundEditor` closure — asserted structurally, since a read that
moved closures would keep the count) and
`test_theRoundEditorNeverReachesForTheCoachsSeat` (neither `effectiveCoach` nor
`firstReaderName` in `RoundEditor.swift` or the wiring, and the `roundEditor`
closure does not name `authorReader` either — reaching the roster's resolution
is the same fallback wearing one more hop).

**The delta marker is the CHECK's, and a round neither reads it nor moves it**
(two loops P1 Task 4, spec §4.5). `beginRun` builds a round's delta
`since: nil` — the same "everything is new" a cold read gets, for a different
reason: a round reads the piece WHOLE every time, and what changed since the
last round reaches it through the prior-round and dispositions sections rather
than through a diff. Three consequences, each pinned:

- the empty-delta arm advances the marker for a `.check` only, so ops that
  changed no prose are still passed for the writer's own next ⌘R and never
  consumed on a round's behalf (`test_anEmptyDeltaStillAdvancesTheMarker` is
  the check's pin, `test_anEmptyPieceMovesNoMarkerForARound` its twin);
- `lastOpId` on the record is `kind == .check ? (delta.newestOpId ?? marker) :
  marker`, so a round files the position it FOUND — writing its own
  `newestOpId` would jump the check's marker past prose nobody has read back
  to the writer, and nil-ing it would make the next check re-read the piece;
- a check's next delta therefore begins exactly where its own last run left it,
  however many rounds happened in between
  (`test_aCheckAfterARoundStillReadsWhatTheRoundDidNotConsume`).

**And the draft stage is the check's too, both ends of it** (spec §4.8):
`beginRun` derives a `DraftStage?` for a `.check` alone, so a round derives
none, states none in its briefing and stamps none on its letter — its dose is
`stage?.dosage(freshEyes:) ?? .full`, because a round is always the full letter
and its pass brief is what decides which parts. The `ProcessSignals` reading
that feeds the stage is taken for a check alone for the same reason: it is
Maugham's observation of the WRITER's drafting process, and spec §4.9's round
list omits it because an editor reads the manuscript rather than the working
month that produced it.

**A check's role frame is `CompilerPrompt.readerSection`'s, and a round's is
`passSection`'s** (two loops P2 Tasks 3–4). `readerSection` frames a CHECK by
its `AuthorReader` — the coach ("You are Le Guin, this writer's workshop
teacher."), the writer's own first reader, or nobody, whose section is nil.
`checkMessage` has **no `pass:` parameter at all**, so a lane cannot reach a
check even by a caller's mistake, and `passSection` has one frame again: every
`ActivePass` that reaches it is a rung of the ladder. `ActivePass.isCoach` is
**deleted** — the flag existed only so the coach could arrive at the briefing
dressed as a pass while one closure answered both loops — and
`TripwireGrepTests.test_isCoachIsGone` fails if it comes back anywhere under
`Maugham/`, with a planted offender for the control. A coach's check briefing
is byte-identical to what the pass route sent her, pinned at the message level
by `CompilerPromptTests
.test_aCoachCheckIsBriefedByteForByteAsThePassRouteBriefedHer`.

**The first reader is dosed, and briefed, as herself** (rulings P2-4/6/7).
`beginRun`'s dose is `reader.isFirstReader ? .reader : (stage?.dosage(freshEyes:)
?? .full)` — hers **outranks the draft stage and Fresh Eyes both**, because a
cold read is "always the full letter" for the stage's rule and applying that to
her would hand back the craft letter she exists not to write. She is briefed
with `signals: nil` (no process line: Maugham's observation of the writer's
month is not something a reader forbidden craft words can speak about),
`lessons: nil` (the craft ledger is not hers to read) and `stage: nil` (ruling
P2-4, fix round 1 — `stageSection` states the CRAFT dose the stage earns,
which contradicts `firstReaderInstruction`'s "the short reader form and nothing
else" in the same message). The stage is still derived for her — it is cheap,
and `Letter.stage` records it, so the RECORD stamps a stage she was never told
about — it simply does not decide her dose and never reaches her.

**And she judges nothing about the writer's intent** (ruling P2-10). The
`intent_drift` section is a verdict on the writer's DECLARED INTENT rather than
a finding in the prose, and it marks the intent strip until a later reading
holds — the same craft register the three gates above keep away from her. So
`CompilerPrompt.sectionSchema(judgesIntentDrift:)` omits the line, the
stabiliser instruction and the paragraph explaining the verdict from her schema
(routed at the one place the schema is assembled, off `reader.isFirstReader`),
and `LetterDosage.judgesIntentDrift` drops a verdict a model volunteers anyway,
so her run records none and the strip's mark is untouched by her check. The
substrate sections stay — conformance, continuity and facts are asked under
whichever reader or editor holds the seat (spec §2).

**Her statement is read at the keystroke and split in the section**
(`readerSection`'s `.firstReader` arm): the essay half is her description, the
`## Rulings` half is briefed under *Standing instructions from the writer:*,
and the arm ends with `firstReaderInstruction`. A statement of nothing but
rulings reads as the undescribed state (`undescribedFirstReader`), because a
blank line where the description goes would read as prose the writer wrote and
lost. What files those instructions is `Maugham/Views/FirstReaderRuling.swift`,
the one production file naming `.firstReader` to `RulingPerformer`
(`TripwireGrepTests.test_theFirstReadersStatementIsWrittenFromOneFile`).

**The record remembers who read**: `CompilerRun.readerName`, stamped at the
keystroke for a check and `nil` for a round, whose byline is its lane's. Every
Author surface drawing a STANDING run's letter reads `run.readerName ??
reader.editorName` — the signature, Keep's note heading, a filed lesson's
provenance, Add-to-intent's ruling — so a letter keeps the name it was written
under after the writer changes the roster (P1's Ruling 10). The pane's HEADER
line and its empty state stay on the LIVE reader, because they promise who
*will* read.

**The dispositions section is the warm path's duplicate guard, and its two
halves are asymmetric on purpose** (`CompilerPrompt.dispositionsSection`,
`CompilerAnnotationDisposition.gather`, M4 P1 Task 4). It briefs the model on
what the writer has already done about this piece's compiler-authored notes,
split into two headed lists:

- **Standing** — notes still open, in the writer's queue as the round begins.
  **Uncapped and unsorted, by design**: truncating this half is what would
  mint duplicates, since a standing note left out of the budget is a finding
  the model has no way to know is already raised. Its order is
  `gather`'s own — the deriver's order, not a sort applied here.
- **Settled** — the writer's answer (accepted, rejected with a reason,
  stetted). **Capped at `settledDispositionLimit` (12)**, with the elided
  count spelled out ("…and N more the writer has already settled") rather
  than pretending the history is shorter than it is — settled notes
  accumulate for the life of the piece and would eventually dominate the
  prompt, while what is actually this section's job is telling the model
  about the writer's *live* queue. **Sorted by `resolvedAt` DESCENDING**, not
  by when the model originally raised the finding (`Document.annotations`'
  own order, `createdAt` descending) — a question raised in round 1 and
  answered this morning is the one the writer is still near, and under the
  cap it is the one worth the words; sorting on arrival order would brief the
  twelve most recently RAISED, which after a catch-up session is close to the
  twelve LEAST recently thought about. **Ties, and the undated, fall back to
  arrival order** (`gather`'s `enumerated()` index) rather than to nothing —
  `sorted(by:)` is not stable, and an unstable order here would reshuffle the
  briefing between two runs where nothing changed. A `.declined` note has no
  `resolvedAt` (a triage mark is not a resolution), so declines sort after
  every dated verdict.

**A standing fingerprint silences its settled twin.** The mint's own dedupe
stops it WRITING a second open note while one already stands. That is not a
guarantee that only one ever stands: a note settled, re-raised in another lane
and then reopened leaves two open under one fingerprint, which the cross-lane
paragraph below owns. And nothing stops an open note sharing a fingerprint
with a note settled earlier and since re-raised — briefing both would tell the
model to confirm a finding in one line and forget it two lines later. The
live note wins: `dispositionsSection` drops a settled entry whose
fingerprint is also standing. A note with no fingerprint (the anchorless
kind — a doc-scoped craft note, which has no discriminator to make one from)
is listed on its own rather than folded into anything, since a nil
fingerprint is the absence of identity, not an identity shared with anything
else — **and being fingerprintless it is neither deduped nor counted
cross-lane**: the dedupe branch it never enters is the same branch the
cross-lane count is taken in. **A sibling residual, same class:** a continuity
note's fingerprint leans on the model re-quoting `cites` byte-identically
(`RoundFingerprint`'s "clause quote" for that kind), so a re-punctuated quote
on a Fresh Eyes
reread — same question, one comma moved — can mint a duplicate the dedupe
can't see. Neither residual gets machinery; the writer disposes the
duplicate the way they dispose any other settled note.

**A refusal in ANOTHER lane is counted and said aloud** (#42 F-H). The mint
refuses a finding already open whichever pass raised it — one finding is one
note, and the lane it was first raised in does not make it two — but the
since-line's three counts are lane-local by construction
(`SinceLastRound.compute` filters on `reviewPassId == passId`), so a Line
round that re-raised a question standing in the Structural lane used to read
"0 resolved · 0 persisting · 0 new": a check that engaged the piece, reported
as one that found nothing in it. The mint now answers a
`CompilerOrchestrator.MintOutcome` — `minted` beside `openInOtherLanes`, the
count of DISTINCT findings the dedupe refused where **no lane holding them is
the round's own** (own-lane presence wins; the paragraph below is why that is a
set of lanes and not one) — and **three surfaces say it**:
`RoundNarrative.sinceLastRoundLine` appends "· 1 was already open in another
lane" / "· N were already open in other lanes"; `RoundNarrative.freshEyesHeader`
appends the same clause, because a cold read is one of the states the since-line
is silent in; and the Diagnostics pane's header and empty state say "Nothing new
to flag." rather than sealing over a round that raised something the writer is
holding out of sight. The wording lives in ONE place —
`RoundNarrative.openInOtherLanes(_:)`, which hands back the bare clause and the
pane's whole sentence together, so the three cannot drift about when one becomes
many — and it is deliberately **past** tense: the three counts beside it are
recomputed off the writer's live queue every time the line is drawn, while this
one is a snapshot taken at the mint and stored, so present tense would go false
the moment the writer settled the other lane's note. **The residual, since the
count is recorded whether or not anything draws it:** a passless run that also
raised a conformance strain draws a report rather than an empty state, so its
count is stored and shown nowhere. **A match in the round's
OWN lane is deliberately not counted**: that is the *persisting* case, already
on the line, and counting it twice would tell the writer one finding is two.
The number is produced at the one place fingerprints are already compared
(`CompilerEnvironment+Project`'s mint loop, whose `taken` set became a
fingerprint→**set of lanes** map for exactly this) rather than by a second scan
that could disagree with the mint about what it refused; it rides `CompilerRun`
additive-optional, so an older sidecar decodes to nil and the sentence is
byte-for-byte what it was.

**A set of lanes and not one lane, because ONE FINGERPRINT CAN BE HELD BY TWO
OPEN NOTES**, and the shape is reachable through nothing but the writer's own
verbs: only open notes block, so a Structural note that is rejected stops
blocking, a Line round re-raises the finding and mints a second note under the
same fingerprint, and Reopen on the first leaves both open in different lanes.
`reopenAnnotation` has no fingerprint-collision guard and should not grow one —
reopening is the writer taking a note back, not a claim about any other note.
A single-valued map keeps whichever of the two the annotation order happened to
leave last, so the round in the OTHER lane reads a foreign lane back and reports
its own persisting note as "was already open in another lane" — the same finding
counted twice in one sentence ("1 persisting · 1 was already open in another lane"),
which is the exact string the review fix's test produces when falsified.
**Own-lane presence wins**: cross-lane means NO note holding the fingerprint is
in this round's lane. And the count stays per FINDING, not per matched note —
two notes holding one fingerprint are one thing the writer is holding, which is
what the sentence says. **Scope, stated honestly: this counts NOTES.** The
mint only ever sees `SectionedOutcome.mintable` — continuity questions, reader
reports and, since the editorial letter, the letter's own questions — so a
conformance strain re-raised across lanes stays report-side and takes no part
in the number.

**Fresh Eyes briefs NO dispositions at all**
(`CompilerOrchestrator.beginRun`, the private continuation `runRequested`
hands off to after the burst-flush hop: `let dispositions = freshEyes ? [] :
environment.annotationContext(docId)`) — cold means cold, deliberately, so a
reread is not steered by what a warm round already said. That is what makes
the ingest-side fingerprint dedupe (`Environment.mintAnnotations`, described
above) the cold path's ONLY guard against re-minting an open finding: on a
warm round this section is the primary defence and the dedupe is a backstop;
on ⌘⇧R the dedupe is the whole of it.

## What this area owns

- The run: delta → prompt → session → parse → mint → store (`CompilerOrchestrator`) — the mint (M4 P1 Task 3) writes note-natured findings into the annotation layer between the parse and the sidecar write, and `finish` waits on it (see "The turn coming back" doc comment on `CompilerOrchestrator.finish`).
- The subprocess and its lifetime (`ClaudeCLISession`, behind `CompilerRunner`).
- What the compiler may reach (`CompilerAllowlist`).
- The diagnostics themselves: shape, per-device sidecar, staleness
  (`Diagnostic`, `DiagnosticsStore`, `DiagnosticIngest`).
- Where a note goes when the writer keeps it (`DiagnosticPromotion`) or answers
  it (`RulingPerformer.rule`, called by `DiagnosticsPane.commitAnswer`).
- What a LETTER says once the writer keeps it (`LetterMarkdown`, spec §3.6).
  Where it lands is not this area's — `LetterKeep` (`Maugham/Views/`) names the
  scope and `ResearchScope.route` decides the destination.
- **The one door into the writer-owned layer** (`RulingPerformer`) — count the
  verbs in the census rather than reading a number here; today they are rule,
  revoke, edit and `restore`, each taking the writer's words as a `String` or a
  `Ruling` those verbs produced, and never a reading. Spec §3.4's membrane;
  `RulingPerformerTests.test_nothingDerivedCanWriteItself` is its census.
  **More than one destination since the publish department's Task 6**: every
  verb takes a `kind: Statement.Kind` before its scope, undefaulted for the
  reason `world` is — count the kinds a caller actually names rather than
  reading a number here. Today they are the piece's **intent** statement
  (`RulingsStratum`, `DiagnosticsPane.commitAnswer`), an **edition brief**
  (`editions/<lang>.md`, `QueryRuling`), the project's **lessons ledger**
  (`lessons.md`, `LessonLedgerVerbs` — the one file allowed to name it) and,
  since two loops P2 Task 5, the **first reader's statement**
  (`first-reader.md`, `FirstReaderRuling` — likewise the one file allowed to
  name it, `TripwireGrepTests.test_theFirstReadersStatementIsWrittenFromOneFile`).
  One performer, several addresses, because each is the writer's own declared
  prose carrying a `## Rulings` stratum. Visual language still has none:
  nothing mints one for a kind no caller names. The parameter is undefaulted
  because a default would be how an edition's decision landed in the book's
  intent in silence, and
  `RulingPerformerTests.test_everyVerbTakesTheDestinationKindExplicitly`
  is the census.
  **`restore` exists for ⌘Z alone**: the Intent pane's rows register the
  opposite verb on the window's `UndoManager`, and `rule` could not have served
  as revoke's inverse — it stamps today's date and appends at the end, so
  undoing the revocation of a March decision would hand it back re-dated. An
  undo that rewrites the record is worse than no undo.
  **Every verb asks WHO before it writes** (signed op log P3c Task 7):
  `RulingPerformer.refuseUnlessTheStatementIsYours` throws
  `RulingRefusal.notYours(statement:)` before any mint or op unless this
  device may `.editStatement` the statement — asked of
  `DocumentStore.settledPosture` at `StatementEditorHost.postureDocId`, or,
  for a `ProjectStore` no window holds, of MaughamCore's `PostureDoor` over the
  one builder (P3c plan 2 Task 1; the file is admitted no posture-census
  spelling). A project statement is
  the book author's alone; a piece statement follows its piece. The door is in
  the verbs so the number of callers stops mattering
  (`RulingPerformerTests.test_everyVerbAsksTheDoorBeforeItWrites`), and
  `StatementProposalGate.adopt` asks it FIRST, since its essay write precedes
  its glossary rulings. Surfaces hide what the door would refuse, asking
  `DocumentStore.posture(ofStatement:scope:statements:)`.
  `StatementProposalGate` (P5) is the second and last writer-facing door into
  a statement's ESSAY: Adopt, a click on a staged proposal, through
  `mutateStatementText`; its glossary lines still go through
  `RulingPerformer.rule`.
- **The declared world** (spec §3.1/§3.4): Claude's disposable reading of a
  statement into checkable `DerivedClause`/`DerivedRule` values
  (`DeclaredWorld.swift`), the one-shot `claude -p` that produces one
  (`DeclaredWorldDeriver.swift`), and the per-device cache keyed on the exact
  source text's hash (`DeclaredWorldStore`, same file). Never truth, never
  drawn — see "The derivation trigger" below.
- **The bible** (spec §3.3): facts Claude reads off the manuscript while
  checking it, each carrying its establishing ¶ when one exists
  (`BibleFact`), and the per-device, project-scoped ledger of them
  (`BibleStore.swift`). Nothing here is truth either — the writer's three
  actions on a fact (bless / correct / dismiss, `Maugham/Views/BibleStratum.swift`)
  are what promote or discard a reading, never this store.
- **What a document is pinned to** (`PinnedReferences`, `PinnedReferenceResolver`)
  — the research the writer linked, the research their project type derives for
  the piece, and the cards they clustered on the canvas, grouped into a
  `PinnedShelf`: one pure function with two production callers, the run's own
  context and the Author surfaces below. Neither may re-derive it.

The pane is not here — `Maugham/Views/DiagnosticsPane.swift` — and neither is
the run key's delivery, `Maugham/Views/CompilerRunModifier.swift`, nor the
Author surfaces that read the pinned set (`Maugham/Views/IntentStrip.swift`,
`ReferencesPane.swift`, `AssistantColumn.swift`). All are across the seam on
purpose: this area holds no view state and no editor binding (tripwires 3, 6).

## The seam map

One run walks left to right. Each arrow is a value, never a shared object.

| File | What it is |
|---|---|
| `CompilerRunModifier.swift` (in Views) | The run keys' delivery path (⌘R's delta, ⌘⇧R's cold read), and three of the four ways the session dies |
| `CompilerOrchestrator.swift` | **The run.** Owned by `ProjectWindow`; one orchestrator per window, one session per orchestrator |
| `CompilerEnvironment+Project.swift` | The production wiring — the window's stores, as the closures the orchestrator runs on. Every capture is weak. `pinnedListing` carries the resolved `PinnedShelf`'s own grouping into the briefing through `pinnedListingLines`: one `pinnedListingLine` per pin, with a `## <title>` line ahead of each TITLED section and no header over an untitled one, so a run reads the same arrangement the References pane draws |
| `DeltaBuilder.swift` | What changed since the last run's marker, in the writer's order (`sequence`, never raw `paragraphs`) — a CHECK's marker: a round is built `since: nil` and reads the piece whole (two loops P1 Task 4) |
| `Letter.swift` | The sixth section's own shape: `Working`/`Habit`/`Question`/`Scene`, the ledger's own two fields (a `Question`'s `lessonHeading` — the habit it was raised under, matched app-side on the habit's `name`, stamped with its `ledgerHeading` and `nil` on a near-miss — and the letter-wide `retired`, read through `retiredHeadings`); `Habit.ledgerHeading` is the ONE rule for what a habit is called in the ledger, and both the parse and `LessonOffer.lessonHeading(for:)` read it rather than spelling it. Two things a part can be missing are distinct (`scenes == nil` is a piece that does not move by scenes; `[]` is a table with no rows). Codable is synthesized — every part but `about` is optional, so a P2/P3 addition falls out through `decodeIfPresent` — and `isEmpty` is what every surface asks rather than `letter != nil`, because `about` is always present |
| `ProcessSignals.swift` | The writer's own process, pure over `(ops, sequence, now)` (spec §5, P3 constraint 20): sessions, the frontier (latest `.typingBurst` mint still in `sequence`, ties within one op by position rather than change order — R15), churn hotspots (rewrites over the last `churnWindowSessions` sessions, counted on a wider allowlist than the frontier's — `.typingBurst` OR `.claudeAccept`, since taking Claude's suggested change is still the writer revising), `sessionsSinceFrontierMoved`, `daysAway`, and `noteworthy` — a plain threshold over these, and the whole of the judgement |
| `DraftStage.swift` | `.drafting`/`.revising`, derived from `DeltaCounts` and the signals, never set or stored anywhere but `Letter.stage`; `LetterDosage` (`.short` caps questions, drops the exercise, reads scenes as `nil`; Fresh Eyes is always `.full`; `.reader` also drops the one thing, the habits and `retired` — the first reader's short form, two loops P2) |
| `LetterMarkdown.swift` | **The letter as prose the writer keeps** (spec §3.6). One render, two hosts, one note: the heading carries the voice, the day and the lane line; the parts are `##` sections in the schema's reading order under `LetterSection`'s own copy constants; a ref is the paragraph's words in italics and never a join key. `scrubbed` is the one gate every emitted string passes, so a model's leaked anchor cannot ride into a research note |
| `ScenePosition.swift` | What form the letter's scene table takes, derived app-side from the project type, the writer's whole intent statement and the pass brief (spec §3.4). Two closed phrase lists — the opt-out and the turn clause — and one rule about which wins. Its raw values reach disk through `Letter.scenePosition` |
| `CompilerPrompt.swift` | The message. Asks different questions of new and revised prose; v2 carries the essay + derived clauses + the bible slice + the lessons ledger + the delta, diffed in as ONE unit (`briefingHash`). **What the writer has DECLARED is inside that unit; what belongs to this one run is outside it.** The ledger (`lessonsSection`, P2 Task 4) is a declaration and folds in — as the SECTION rather than the ledger's markdown, so retiring an entry, which removes it from the briefing, does not re-embed everything else to say so. M4 P1 and the editorial letter add per-run sections between the listings and the delta, and **none of those is folded into `briefingHash`** (each changes with the writer, not with what they declared) — count the appends in `runMessageV2`, not a number here: the active pass's **role frame + brief** (`passSection`, "You are Gould, this manuscript's copyeditor"), the **scene position** (`scenePositionSection`, the letter's own; see the scene-position paragraph above) and the **dispositions** section (`dispositionsSection`/`CompilerAnnotationDisposition.gather` — standing notes uncapped, settled notes capped at 12 and sorted by `resolvedAt` descending; see the dispositions paragraph above) and the **ask** (`askSection`, P2 Task 3 — last of the frame and closest to the prose, and the one most expected to change every round). **Two loops P2 Task 3 adds `readerSection`** — the CHECK's own role frame, emitted in the `.check` arm above `passSection` and never on a round (spec §4.9). **Two loops P1 Tasks 3–4 scope four of the sections by `RunKind`**, through two thin named doors over the one builder — `checkMessage` (no `previousRound` parameter to pass) and `roundMessage` (no `stage`, no `freshEyes`, no `signals`): the prose is `deltaSection` for a check and `wholePieceSection` for a round (heading `The piece, whole:`, one `[¶id]` line plus its prose per paragraph in the order `DeltaBuilder` gave them, no `(new)`/`(revised)` label and no before/after — over a whole read every paragraph is new and none has a prior), the draft stage and the `processSection` numbers behind it reach a check alone (a round is always the full letter, spec §4.8, and §4.9's round list omits the process), and the prior round in this lane briefs a round alone. **The kind changes what is briefed and never the hashed unit** — a check and a round over an unchanged intent hash identically |
| `CompilerAllowlist.swift` | The enumerated read-only MCP tool list, as `--allowedTools` |
| `CompilerRunner.swift` | The seam: `send(message:systemPreamble:) -> CompilerRunEvent`, plus every way a run can fail |
| `ClaudeCLISession.swift` | The warm subprocess behind that seam |
| `RunTiming.swift` | `RunTiming` (elapsed, first line, API duration, turns, output and thinking tokens, cost, model, effort — read off the CLI's `result` event plus Maugham's own clock; stored on `CompilerRun.timing`) and `RunProgress` (the live thinking-token estimate the panes draw) |
| `DiagnosticIngest.swift` | The structured message → notes, clause statuses, fact-candidates and the letter, anchored against the LIVE document. One section is one unit, so arrival can become incremental without the fold changing. `SectionedOutcome.sidecarDiagnostics` keeps conformance strains only; `.mintable` is the other half, built from the same accepted diagnostics rather than re-parsed. `parseLetter` is the sixth section and carries the two exemptions described above |
| `CompilerNote.swift` | **The value that crosses from parse to mint** (M4 P1 Task 3) — what `Environment.mintAnnotations` writes as a pass-stamped `Annotation`. Neither a `Diagnostic` (no run id, no staleness anchor, no sidecar identity) nor an `Annotation` (derived from ops, not caller-constructed); `CompilerMintContext` is what one mint needs off the run that produced it (lane, round, editor name, cold-or-warm), minted once at the keystroke and carried rather than re-asked at mint time |
| `DeclaredWorldDeriver.swift` | Also the one-shot's pipe discipline: stdout is drained WHILE the process runs. Reading it from `terminationHandler` deadlocked on any answer past ~64 KB — the child blocks on its own write, so it never exits, so the handler never fires. **120s deadline** (Stage 3), four times the spike's measured 30s sonnet cost: an overrunning process is `terminate()`d and the derivation returns its ordinary honest `nil` — ordinarily through the SAME EOF-and-exit resolution every other unreadable answer already goes through, and by force (`OneShotOutput.deadlineExpired`, after a 2s `terminationGrace`) when a group member escapes the group SIGTERM and withholds EOF by holding the inherited pipe: CI run 31595012981 hit exactly that (the killpg/fork race), and a real CLI grandchild that setsids has the same shape. Both doors are the deadline's own; `derive` never hangs on a stranger's file descriptor |
| `Diagnostic.swift` | `Diagnostic` + `CompilerRun` — the wire and sidecar shapes |
| `DiagnosticsStore.swift` | The per-device, per-document sidecar, and the staleness rule |
| `RoundHistory.swift` | `RoundFingerprint` (the one join-key for round-over-round identity — section + clause quote + anchor + the reader's category, never prose; its `stringValue` is the mint's dedupe key, a persisted synced format) + `RoundRecord` (that a round finished: its lane, its number and **when** — `fingerprints` is legacy and written empty since M4 P1 Task 5) + `SinceLastRound` (the pure resolved/persisting/new count, taken off the writer's QUEUE, on `DriftDetector`'s mould — no store, no I/O) |
| `DiagnosticPromotion.swift` | What a kept note says once it is an op-logged task |
| `RulingPerformer.swift` | rule / revoke / edit / restore — the only writes into a statement's `## Rulings` stratum |
| `StatementEssay.swift` | Where the essay ends and the strata begin — the byte-exact split the Intent pane's editor binds through |
| `LessonsLedger.swift` | The lessons ledger's grammar (editorial letter P2): reads a `## Rulings` row of the `.lessons` statement as a lesson, a settled `Choice: `, or a `(retired <date>)` entry. Pure, over the ruling's **TEXT** and never the whole line — the writer types these by hand, so nothing may require the canonical `— ruled …` suffix, and a provenance that spells a marker is a name, not a marker. Retirement wins over the choice prefix, and a retired suffix whose date does not parse is still retired. Dates go through `RulingsSection.formatted`/`date(from:)` rather than a second formatter. Ids move when a text does, so an entry is addressed by index-at-the-moment (`RulingsStratum.currentRows`) or by heading through `matches` (exact after trimming, case-sensitive), never by a remembered id |
| `DeclaredWorld.swift` | `DerivedClause`/`DerivedRule`/`DerivedWorld` (the reading) + `DeclaredWorldStore` (its per-device, hash-gated cache) |
| `DeclaredWorldDeriver.swift` | `ClaudeWorldDeriver` — the one-shot, no-MCP `claude -p` that turns a statement's prose into a `DerivedWorld` |
| `BibleStore.swift` | `BibleFact` (a reading with its establishing ¶) + `BibleStore` (per-device, project-scoped ledger) |
| `PinnedReferences.swift` | The pure projection: linked research + the research the project type derives + clustered canvas cards, resolved to renderable pins and grouped into a `PinnedShelf` — one untitled run of research, a titled section per bound region (a promoted region contributing the note it became), then `Cards` |
| `PinnedReferenceResolver.swift` | The caller-side assembly against a live project — the five inputs `PinnedReferences.pinned` takes, gathered in one place |

**A run's first act is to close the writer's burst, and only then read.**
`Environment.prepareForRun` is awaited at the top of `runRequested`, before
`reading` is asked for anything — because freshly typed prose lives in the
`PendingBuffer` until a pause closes the burst, so a snapshot taken at the
keystroke is a document that predates the ⌘R asking about it. Smoke-found and
measured: a 14-paragraph chunk reported as "0 new, 1 revised", the burst
closing two seconds after the delta was built. ⌘S's checkpoint path does the
same thing for the same reason (`ProjectWindow`), and this is the one place in
the area that is not a pure read of a value. It cannot throw: the pending
buffer survives a failed append intact, so a flush that fails costs this run
its newest paragraphs and costs the writer's words nothing — the run proceeds
on the snapshot as it stands rather than refusing. The hop it introduces is
covered by `isRunning` (so a double ⌘R is still one run) and abandoned by
`shutdown()` by generation, so a run acknowledged a moment before the AI toggle
went off does not spawn the session that toggle was meant to prevent.

**The `Environment` struct is the reason this area is testable.** The
orchestrator names no store: it takes closures, so a run is driven end to end
with no project on disk. A factory that reached for `ProjectStore` from inside
`CompilerOrchestrator.swift` would quietly re-couple the two — which is why
the production wiring is a peer file.

## The session's lifetime — the rules, and who enforces each

Spec §3.4, verbatim, with the enforcing site beside it:

| Rule | Enforced by |
|---|---|
| Entering Author never starts it; only the first run does | `CompilerOrchestrator.ensureRunner`, called from `runRequested` and nowhere else |
| It dies on the AI toggle going off | `CompilerRunModifier`'s `.onChange(of: mcpEnabled)` — **and** `ClaudeCLISession` re-reads the toggle before every spawn, so a session already warm cannot answer one more run |
| It dies on app quit | `CompilerRunModifier`'s `.maughamAppWillTerminate` |
| It dies on window/project close | `ProjectWindow`'s own `.onDisappear` → `detach()`, because that path must also drop the orchestrator's hold on the window's stores |
| It dies quietly after ~10 min idle | `ClaudeCLISession.idleTimeout` (600 s); the per-turn budget is a SILENCE budget, `ClaudeCLISession.defaultSilenceTimeout` (180 s, reset by every line the child writes — thinking deltas and the CLI's `system/thinking_tokens` progress events included) behind a ceiling, `defaultRunTimeout` (1,200 s), one constant for every session type since 2026-09-09 (the reader's-own-session spec §2); `translationRunTimeout` is gone. A stall carries `CompilerRunFailure.Stall` — which budget, after how long, how many thinking tokens — and `RoundNarrative.stallCopy` says it. Safe above the idle budget because `idleDidExpire` refuses while a turn is in flight |
| Death mid-run fails that run once; the next keystroke starts fresh | `CompilerOrchestrator.finish`'s `.failed` arm — the marker and the intent hash are both left where they were |
| **It dies on ⌘⇧R, and is replaced in the same act** | `CompilerOrchestrator.beginRun`'s `if freshEyes { retireSession() }` — the one teardown that is a *run* rather than an ending, so it is the orchestrator's rather than a fourth arm of `CompilerRunModifier`. Placed below the in-flight refusal, the generation check and the empty-delta guard: a fresh-eyes press that is refused or abandoned must not cost the writer their warm session |

**The shutdown contract is the sharp edge of this area, and the type cannot
defend itself.** `ClaudeCLISession.deinit` is nonisolated and cannot touch
main-actor state, and deallocating a `Process` neither signals nor reaps its
child — so a session merely *released* leaves a live, billing, API-calling
`claude` running for as long as it survives its closed stdin. Every teardown
path has to reach `shutdown()` explicitly.

**Today the services live in one place: `AgentRoster`** (`AgentRoster.swift`).
It holds the compiler, the translator, the designer, `ColdCall`, the
pipeline and the translation-run log, and spells the teardown order once:
`shutdownAll()` (app quit, the AI toggle going off; pipeline first) and
`detachAll()` (the last window on a project going away). The roster belongs
to the project's `ProjectSession`, not to a window, so two windows on one
project share it (`Maugham/Stores/AREA.md`). A new service joins the roster;
`TranslatorEnvironmentTests.test_everyWindowEndingPathShutsEverySessionDown`
and its controls check that every production class holding a session runner
is a member and that every ending path reaches the roster. The paragraphs
below that name `ProjectWindow`'s `.onDisappear` or a paired call per
service are history: those arms are now `roster.shutdownAll()`/`detachAll()`.

`shutdown()` and `detach()` are not interchangeable: `shutdown()` ends the
session and leaves the orchestrator usable, because a writer who turns Claude
off and on again must still have a working ⌘R; `detach()` additionally drops
the environment and the store references.

**The same contract owns a FILE, and that half leaked for months
(2026-09-06).** Every session is spawned against a per-session
`--mcp-config` written by `ClaudeCLISession.writeMCPConfig` into one shared
directory under the machine's temp root (`sessionConfigDirectory`), and
`retireSession()` — reached from `shutdown()`/`detach()` and from a model or
pair change, and nowhere else — is what removes it. So the same nonisolated
`deinit` that cannot reap a child cannot reap its config either: an
orchestrator merely released leaves a `compiler-mcp-<UUID>.json` behind for the
life of the machine. 235 of them had accumulated in Denver's temp root, in
clusters whose timestamps matched test gates rather than the writer's own use.

The origin was a TEST, and it is worth knowing which shape: `DepartmentRunTests`'
translator fixture builds the real `TranslatorOrchestrator.Environment.production`
and substitutes only `makeRunner`, so `writeMCPConfig` was still production's —
writing into the shared directory — while no test in the suite ever shuts the
orchestrator down. **A fixture over a `production` environment inherits every
closure it does not replace, including the ones that touch machine-global
state.** It now writes inside its own project
(`test_theFixtureWritesItsBridgeConfigInsideItsOwnProject` pins the location,
not the shared directory's contents — seven gate workers share that directory
and a count of it is a test another worker decides).

Beside that, `writeMCPConfig` sweeps its own directory of `compiler-mcp-*.json`
older than a day (`StaleFileSweep`), for the orphans no fix at a call site can
reach: a crashed `claude`, an app macOS killed. **The day's floor is the
load-bearing decision rather than the deletion** — a warm session lives as long
as the writer keeps typing, so anything shorter deletes the config a running
process was spawned against.

**Generations, not booleans.** Every teardown bumps `ClaudeCLISession`'s
`generation`, and a callback from a retired process carries the generation it
was installed with. Without it, a kill-and-respawn lets the dead process's EOF
resolve the new run's continuation — the shape tripwire 2 warns about
(flag-based loop guards leak) arriving in a subprocess.

**The death verdict is a JOIN of two independent deliveries.** stdout's EOF
(the anchor — every byte read) and the process's exit (the status, and the
proof the stderr drain cannot block) must both arrive, bounded by
`defaultDeathReapGrace` (2s, injectable), with timeout falling back to the
honest "the CLI closed its output". Either event can precede the other: EOF
leads a clean close, but an inherited pipe held by a spawned grandchild
outlives SIGTERM, so the process exits first and `waitpid` proves it is gone.
Before this join, an EOF-only verdict collapsed the writer's diagnostic to a
sentence with no body and no essence (issue #36). The generation guard is what
makes the wait safe: a verdict returned to a retired generation is ignored, so
a send inside the grace spawns fresh rather than reusing the process that is
dying. The orchestrator has its own guard on the far side: `finish`'s failure
and unusable-output arms ignore a turn whose run generation has been retired
(#63 item 1), so a dying session's late failure cannot end a newer run, stop
its clock or discard its stream preview. A Cancel of a sent run does not bump the
generation, so a cancelled run's own failure still lands.

## The `--resume` fallback — pre-authorized, and NOT built

Spec §3.4 pre-authorizes a swap: if the warm process proves brittle in the
field, per-run `claude -p --resume <session-id>` gives the same context-reuse
semantics with simpler process management. **It is not implemented** — nothing
in this directory passes `--resume`, and `ClaudeCLISession.arguments` is the one
place to check rather than this sentence.

What makes it a swap rather than a rewrite is the `CompilerRunner` seam: the
orchestrator holds a protocol, mints its runner through
`Environment.makeRunner`, and reads only `send(...)` and `sessionEpoch`. A
`--resume` runner is a second conformer plus one line in
`CompilerEnvironment+Project`. Note what would have to move with it:
`sessionEpoch` is what lets an unchanged intent be elided from a message
(`CompilerOrchestrator.previousHash`), so a per-run process must still answer
"is this the same context that read the intent last time" — for `--resume` that
is the resumed session id, not the process.

## The translator — the area's second orchestrator

Publish department P2 (2026-08-20) gave this area a second run, for a
different job: not reading the manuscript and reporting on it, but producing
words the writer will publish. `TranslatorOrchestrator.swift` /
`TranslatorBriefing.swift` / `TranslatorReport.swift` /
`TranslatorEnvironment+Project.swift` are its files, alongside the compiler's
rather than in a directory of their own — the design is explicitly "every
piece follows a verified precedent" from this area's own machinery, and
splitting it out would have made that harder to see, not easier.

**The rails are `CompilerOrchestrator`'s, reused rather than re-derived.**
Same closure-`Environment` shape (a run drives end to end with no project on
disk, `TranslatorEnvironmentTests` proves it the way `CompilerOrchestrator`'s
own tests do), the same warm-session-with-lazy-spawn shape over
`CompilerRunner`/`ClaudeCLISession`, the same generation discipline across
every suspension (a teardown between the click and the send *abandons* the
run rather than letting it spawn a session the writer has just closed the
window on — `TranslatorOrchestrator.runGeneration`, `ClaudeCLISession
.generation`'s own reasoning in a second currency), and the same vocabulary
for what a run can be (`RunState`, deliberately shaped like `CompilerOrchestrator
.RunState` with `nothingToTranslate` playing `nothingNew`'s part). What
differs is what a run is FOR, and two things follow from that:

- **Warm per `(docId, language)`, not per window.** A compiler session reads
  many documents and re-briefs each under a hash that says what it has
  already been told; a translator session holds one edition's voice in its
  context with no such discipline, so crossing documents or languages inside
  one process would carry another edition's register into a round that never
  asked for it. `TranslatorOrchestrator.ensureRunner` retires the session on
  a pair change exactly as it does on a model change.
- **A failure writes nothing at all, and atomicity is structural rather than
  careful.** `Environment.ingest` is reachable from exactly one place in
  `TranslatorOrchestrator.finish` — the arm holding a `TranslatorReport` a
  successful parse produced — so a session that died, timed out, was
  cancelled or answered gibberish has no path to the writer's words
  (`TranslatorOrchestratorTests.test_aFailedRunIngestsNothing`). The
  compiler's own version of this rule is the "compiler reads and never
  writes" sentence at the top of this file; the translator's is the same
  shape wearing the fact that it DOES write, just never from inside the
  spawned session.

**The report is one JSON object, not a sectioned stream.** `DiagnosticIngest`
reads six line-delimited sections because six different kinds of answer
can arrive independently; a translator turn answers one question — "here is
this round's work" — so `TranslatorReport.parse` reads a single fenced
object naming `entries` (a `¶id` plus exactly one of `text` or
`verbatim: true`) and `queries` (a question, optionally paragraph-scoped).
**All-or-nothing starts at parse, not at ingest**: an entry supplying both
forms or neither is a model that has lost the contract, and there is no way
to know which of its OTHER entries to trust either, so the whole report is
refused rather than salvaged around the bad entry — the compiler's
per-section tolerance does not carry over. **An empty `text` counts as
neither form** (P2's final wave): entry text and query text both run through
`nonEmptyString`, the discipline the paragraph id always had, so `"text": ""`
reads as absent and lands in that same refusal. Taken at face value it would
have blanked the paragraph in the published edition through a path that never
touches the manuscript, and the record would have carried the CURRENT
source's hash — reading fresh, so no later derivation would ever raise it.
Text is stored trimmed, deliberately: whitespace around an answer is an
artifact of how the model wrote its JSON, not of the prose. **`delete` is deliberately absent
from this contract**: a translation disappearing is the writer's own act (or
an orphan-purge outside any run), never something a run decides on its own.

**The briefing is a pure function, `CompilerPrompt`'s own discipline.**
`TranslatorBriefing.compose(inputs:)` takes no I/O, no clock, no store lookup
— `TranslatorOrchestrator` is the one production caller and owns gathering
`Inputs` from the store, the deriver and the annotation layer; the briefing
type does not know any of those exist. Section order: role frame ("You are
Cortázar, translating this manuscript into es" plus the role's own `brief`
when the writer or a preset has set one — no briefless fallback sentence,
because an unbriefed translator genuinely has no doctrine of their own),
declared intent, the edition brief (embedded whole, `## Rulings` included,
with an explicit instruction to honor a standing ruling exactly as it reads
rather than treat it as a suggestion), **the established facts about this
round's people** (`BibleStore.slice(matching:)` over the work-list's prose —
the same ledger and the same subject-occurrence rule the compiler slices its
delta with, extracted onto the store in P2's final wave so the two runs
cannot disagree about which facts a run is entitled to; the heading says what
a TRANSLATOR does with a fact, which is not what the compiler does with the
same list: honor it in grammatical choices the source language never had to
make — a doctor's gender is `la doctora` or an edition-wide error — and raise
a query rather than pick a side where a fact and the source disagree; an
empty ledger composes as silence, not as an announced absence), this round's
work-list (`TranslationDeriver`'s
stale-and-missing set — **no rounds ring**, freshness IS the memory, so an
empty work-list is `nothingToTranslate` and spends no session at all, the
compiler's empty-delta mistake avoided in a second currency), neighbour
context (the paragraph immediately before/after a work item, deduped against
the work-list itself, for continuity only), queries (open ones uncapped and
never re-asked, answered ones capped at `answeredQueryLimit` (12) and sorted
most-recently-settled-first — `CompilerPrompt.settledDispositionLimit`'s
asymmetry, borrowed shape rather than shared constant), and last,
`TranslatorReport.schemaDescription` — the output-shape instruction, always
last, `CompilerPrompt`'s own ordering rule.

**Ingest writes through the writer's own doors, and through exactly one of
each.** `TranslatorEnvironment+Project.swift` is `CompilerEnvironment
+Project.swift`'s peer in every respect that matters — a `production(...)`
factory building `TranslatorOrchestrator.Environment` from one window's
stores, **every capture weak**, because SwiftUI never dismantles a closed
window's view graph and an orchestrator holding a `ProjectStore` strongly
would keep the whole project in memory with nothing on screen. What the
closures do is different from the compiler's, because this loop writes:

- **The words** go through `TranslationWritePipeline.perform` (`Maugham/MCP
  /Tools/TranslationWritePipeline.swift`) — the SAME door `write_translation`
  uses (see `Maugham/MCP/AREA.md`'s `write_translation` entry), so the tool
  and the ingest path cannot drift about which batches are legal or which
  source hash is trustworthy. It re-validates every `¶id` against the state
  resolved at ingest time, never against the sequence the round was briefed
  on, so a paragraph the writer deleted mid-round rejects the whole batch
  loudly, naming the ids — the words are still there to be re-run. **And a
  paragraph the writer EDITED mid-round rejects the same way** (P2's final
  wave), which the pipeline cannot see for itself: the id still resolves and
  every one of its checks passes, so the record would be appended carrying
  `TranslationHash.hash(CURRENT source)` against a translation of text the
  model was never shown — an entry that reads fresh forever and is silently
  wrong. The round therefore carries what it was BRIEFED with: `briefRound`
  answers a `BriefedRound` (the pure `Inputs` plus a paragraphId→hash map read
  off the RAW source, the same string the pipeline stamps from — not the
  anchor-stripped display text, or the comparison would be between two
  normalizations and fire on nothing), and `IngestContext.briefedSourceHashes`
  carries it to `midRunEdits`, the one place it can be spent. Undefaulted on
  the initializer, so a new call site cannot arrive at an unguarded run
  quietly. Compared BEFORE the pipeline call, which is also what makes a
  rejection mint no queries.
- **The questions** go through `Document.addAnnotation`, signed with the
  translator's own name (`AnnotationAuthor(sourceKind: .claude, displayName:
  translatorName)`) and language-tagged via `toolArgs`, so a query is a note
  the writer disposes of in the queue exactly like any other. A query whose
  paragraph anchor vanished mid-run, or one that asks about the whole
  document, mints doc-scoped as a `.craftNote` rather than being dropped —
  `Document.addAnnotation` refuses a `.query` with no anchor, the same call
  `CompilerNote`'s own anchorless arm makes. **That note is re-briefed and
  counted like any other question** (P2's final wave): `AnnotationDeriver`
  projects the translation language tag for `.craftNote` as well as `.query`,
  off the same `toolArgs` the mint writes, and both readers widened the same
  one way — the briefing's query-history gather here and
  `translation_status.open_queries`. While the tag stopped at `.query`, "tú or
  usted throughout?" — the question a translator is most likely to ask and
  least able to guess at — was invisible to every later round, so a fresh
  session asked it again forever with the writer's answer sitting unread in
  the queue. The tag is the discriminator, not the kind: `add_craft_note`'s
  Params carry no `language` and the compiler's mint writes no `toolArgs` at
  all, so an ordinary craft note stays untagged. The body keeps its
  `Translation query (<lang>) — ` prefix as well, because a craft note wears
  no language chip in the queue. **A rejected word batch mints no
  queries either**: the order in `TranslatorEnvironment+Project.ingest` is
  words first, and a pipeline refusal ends the ingest there, because a
  translator query has no fingerprint to dedupe on the way the compiler's
  notes do — minting the questions of a round the writer will simply run
  again would double-ask every one of them.
- **The translator** is `ProjectStore.translatorRole(for:)`, find-or-create —
  this loop is that verb's first production caller, and a run is the write
  act that makes the mint legitimate (`ProjectStore+ProductionRoles`'s own
  rule: read paths never mint a role). **The identity is resolved before the
  briefing, and that order is load-bearing**: the briefing's role frame reads
  the stored row back rather than resolving a name of its own, so the first
  run for a language does not brief a translator who does not exist yet
  while the queries it produces are signed by one who does.

**The confined session can read what it is briefed on, not only trust it.**
`CompilerAllowlist.tools` gained `mcp__maugham__read_edition_brief` (publish
department P2 Task 6): the briefing already embeds the edition brief's text
verbatim, but the translator is also a compiler-rails spawned session with
its own MCP bridge, and it should be able to read its own doctrine through
that bridge the same way it reads craft intent — through the enumerated
read-only allowlist, not only what one briefing happened to carry.
`CompilerAllowlistTests.test_theCompilerCanReachItsDeclaredContext`'s pinned
minimum-required set names it alongside `read_craft_intent` and
`read_visual_language`; the no-write census and its planted offenders are
untouched, because a read joining the allowlist is not the shape either
census exists to catch.

**The shutdown contract gained a second owner, and every teardown arm now
carries a paired call.** `TranslatorOrchestrator` inherits `ClaudeCLISession`'s
contract whole — `deinit` is nonisolated and cannot touch main-actor state,
and deallocating a `Process` neither signals nor reaps its child, so an
orchestrator merely released leaves a real, billing, API-calling `claude`
running for as long as it survives its closed stdin. `CompilerRunModifier`'s
own doc comment now says it plainly: "there are TWO session owners now."
Every arm that used to call `orchestrator.shutdown()` alone now calls
`translator.shutdown()` beside it — the `.maughamAppWillTerminate` handler
and the `mcpEnabled` toggle's `.onChange` — and `ProjectWindow`'s own
`.onDisappear` calls `translator.detach()` beside `compiler.detach()` before
dropping the window's stores. `TranslatorEnvironmentTests`' teardown census
pairs the two COUNTS (`orchestrator.shutdown()` occurrences ==
`translator.shutdown()` occurrences) rather than asserting a fixed number, so
a third compiler-shaped teardown arm cannot land without its translator
sibling — the same shape tripwire 32's census takes for the canvas undo
bracket. The translator has no run keys of its own (⌘R and ⌘⇧R are still the
compiler's alone) and no fourth teardown arm: entering a persona never starts
it, and nothing here reaches for itself.

**The loop shipped headless through P2 and P3; P4 (2026-08-20) wired the
click.** `TranslatorOrchestrator.runTranslation` had no caller in production
through P3 — proven by the environment wiring's own test suite and by the
teardown census, not by a keystroke. The spec's trigger, "a 'Run translation'
act per language, from the department desk"
(`docs/superpowers/specs/2026-08-19-publish-department-design.md` §2, §5), is
now `DepartmentPaneHost.run(language:)` (`Maugham/Views/Publish/`) — the
department desk's per-language Run, ⌘⌥K — which pre-flights against
`TranslationWritePipeline.validate` (the SAME gate the briefing itself calls,
so the desk was not widened to answer a question it can already ask) and then
calls this orchestrator. **Global Constraint 1 survives structurally, not by
a new refusal**: Run resolves against the OPEN document only
(`DepartmentRunTarget.resolve`), because `currentParagraphState` — the read
the briefing gather already goes through — answers an open document straight
off the registry and has no way to refuse one; the desk's own test names that
closure `test_theBriefingAbandonIsClosedByTheOpenDocumentGate` rather than
asserting it as a comment, so a future change to that registry read would
turn it red first. Only one translation round runs at a time, across every
language — one warm `TranslatorOrchestrator` session, `DepartmentRunSession
.busy` naming the edition already holding it. An unlisted language's first
Run opens the cast sheet (`DepartmentCastSheet.swift`, **Name & Run**) rather
than silently minting a translator with no chosen name. That sheet asks the
same question at three moments as of cast-management (2026-08-21) — name the
translator a Run is waiting on, **Add Language…**, and **Rename …** on any
row of the desk — so one composition (`translatorRole(for:)` +
`renameProductionRole`) is the only way anybody on this book is named.

## The designer — the area's third orchestrator

Publish department P3 (2026-08-20) gave this area a third run, for a third
job: not reporting on the manuscript and not translating it, but proposing
the BYTES the book is typeset from — a spec plus template/style/partial
files — and a compiled spread of sample pages so the writer can judge the
proposal without reading LaTeX. `ElementCensus.swift`, `SamplePageSelection
.swift` and `SampleCompiler.swift` live in `Maugham/Publish/` rather than
here (there is no `Maugham/Publish/AREA.md` — this section is where all four
of the designer's files are documented, wherever they physically sit);
`DesignerReport.swift`, `DesignerBriefing.swift`, `DesignerOrchestrator.swift`
and `DesignerEnvironment+Project.swift` are peers of the compiler's and the
translator's own files, same reasoning as the translator section above.
`ProposalPromotion.swift` is also in `Maugham/Publish/` — the one thing in
this whole loop that writes the LIVE publish tree, and its own file rather
than a `DesignerOrchestrator` verb because approval and revert are things the
writer does to a STAGED proposal, reachable independently of any run.

**The rails are `CompilerOrchestrator`'s and `TranslatorOrchestrator`'s, a
third conformer over the same shape.** Same closure-`Environment` discipline
(a run drives end to end with no project on disk —
`DesignerOrchestratorTests`/`DesignerEnvironmentTests` prove it the way the
other two orchestrators' suites do), the same warm-session-with-lazy-spawn
shape over `CompilerRunner`/`ClaudeCLISession`, the same generation discipline
across every suspension, and the same `RunState` vocabulary shape
(`.idle`/`.running(round:language:)`/`.failed(failure:at:)`). What differs,
same as the translator, is what a run is FOR — and here that difference cuts
deeper than the translator's did:

- **Warm per PROJECT, not per document-and-language.** A design proposal is
  never about one document; it is about the whole book's typesetting, so
  there is nothing narrower to key a session on than the project itself. This
  is also why `requestChanges` (a follow-up send on the SAME warm session,
  the gate's "iterate" arm) is safe here in a way it could not be for a
  process keyed more narrowly: the session that made round N's proposal is
  the only process that can sensibly be asked to revise it, and nothing about
  a design round narrows further than "the book" the way a translator's
  register narrows to one edition. Retired only by a model change or
  `shutdown()`.
- **A round stays OPEN after it ends**, the same shape the translator never
  needed and the compiler doesn't have — `hasOpenProposalRound` answers
  whether `requestChanges` has anywhere to land. It closes three ways, all in
  `DesignerOrchestrator`'s own doc comment: a fresh `runDesign` send (closed
  unconditionally, before the answer is known — a second `runDesign` that
  comes back unparseable must not leave `requestChanges` talking to the
  session about the FIRST proposal, the fix round 1 finding), `retireSession`,
  and the epoch moving under it (`sessionEpoch`, `ClaudeCLISession`'s own
  silent-respawn guard — a `requestChanges` sent to a respawned process would
  be asking a process that never saw the proposal to revise it).
- **`stage` does two things behind one closure, and both are awaited.** A
  parsed `DesignerReport` becomes a `DesignProposalStore.Proposal`
  (`Maugham/Stores/DesignProposalStore.swift`, staging) **and** a compiled
  sample (`SampleCompiler`, `Maugham/Publish/`), handed back together as one
  `StageOutcome`. A disk refusal during staging is `StageOutcome.rejection`
  and ends the run as `.failed(.stagingRejected(_))`; a tectonic failure
  during the sample is `StageOutcome.sample = .failed(...)` and ends the run
  **clean** — spec §6's rule, that a sample compile failing is advisory
  information ON the proposal, never a reason to fail the round that made it.
- **No `nothingToTranslate` analogue.** There is always a book to design, so a
  round that starts always has something to propose; success returns to
  `.idle` and the pending-proposal badge P4's desk will show is the store's
  own state, not the orchestrator's.

**The census is recomputed at staging, never carried from the briefing.** A
whole model turn separates `briefRound` from `stage`, and the writer keeps
writing through it — `SamplePageSelection.choose` is re-run against a fresh
`ProjectStoreASTSource` build at staging time, against the book as it stands
NOW, so a page selection computed against the older AST never demonstrates
text that has since moved. Both derivations are pure over the same source, so
an unchanged book still answers identically.

**One AST, one edition — a language round samples in that language, against
base templates.** The census, the selection and the sample all come from
`ProjectStoreASTSource` at the round's own `language`, so a Spanish round's
sample pages carry Spanish prose (`SamplePageSelection`'s own text, not a
translated afterthought) with the ordinary per-paragraph stale-source
fallback a preview that mutates nothing is allowed to make. **What does NOT
follow the language is the TEMPLATE**: `SampleCompiler` takes no `language:`
parameter, so `LanguageSuffixedFile` resolution never runs and a proposal
staging `template.es.tex` is sampled through the base `template.tex` — the
prose is the edition's, the typesetting is not. **P4's gate says so rather
than fixing it**: the caveat sentence and `Proposal.language` are plumbed
through to the gate view (`Maugham/Views/AREA.md`'s "The department desk"),
but `SampleCompiler`'s signature was deliberately not widened — Denver's
ruling keeps a design round scoped to the whole book (`runDesign(language:
nil)`, no per-edition picker on the desk), so no proposal a writer can create
today actually carries a language, and the caveat arm is real but
unreachable from the shipping UI until a per-edition design round exists.

**`config.json` is refused twice, at two different layers, for two different
reasons.** `DesignerReport.parse` (parse time) refuses it so a hand-crafted
report can never propose rewriting what "the trim" or "the format" mean — the
one file this whole loop is structurally forbidden to touch. Everything else
that touches config only READS it: `DesignerBriefing` embeds a *summary* of
the trim/format facts a design needs (never the whole JSON), and
`SampleCompiler` constructs its own `PublishConfigStore(projectURL: scratch)`
rather than accepting a caller-supplied store, precisely because a
caller-supplied store could only ever be pointed at the live directory — the
one thing a sample compile exists to avoid reading. **`EMISSION.md` is the
one honest gap in that discipline**: it is briefed to the designer as an
ordinary template file (genuinely the most useful file in the tree for
understanding what a LaTeX template must satisfy) even though it is
GENERATED, from `EmissionContract.swift` — and nothing at parse time stops a
proposal from rewriting it. Harm is small and self-healing today (the test
suite regenerates it, so a stale proposal only costs a confusing diff), but
if a future promotion-side refusal is wanted, that is a parse-time guard on
`DesignerReport`, not a briefing-time one.

**`ProposalPromotion` reads the live tree and never writes it except on the
writer's own three verbs — `SampleCompiler`'s mirror image.** `approve`
refuses while a compile is running, refuses with no live `.maugham/publish`
tree, and (the guard the brief did not name, added because a retry needs it)
refuses over a STANDING backup — without that third guard a second `approve`
(a retry after a mid-write failure, or a double-click on whatever P4's button
turns out to be) would rebuild the backup from the tree its own first attempt
just promoted, capturing the proposal's own bytes as "the originals" and
destroying the only way back to what the writer actually had. **That third
guard is project-wide, not per-proposal** (`proposalHoldingTheBackupSlot`,
widened in P3's final review): there is ONE set of original templates, so
there is one backup slot, and layering two promotions loses those originals
just as surely by a longer route — approve(A) → approve(B) makes B's backup a
copy of A's promoted bytes, so revert(A) → revert(B) walks the tree back to
A's design and stops there, with every step reporting success and the
writer's own templates in no file, no backup and no proposal. The refusal
names who holds the slot and both ways out. Order inside
`approve`: resolve every staged path to completion first (an escape check
behind `DesignerReport`'s own parse-time guard, defence in depth — a
`proposal.json` is a file on disk and a hand-edited one is the one path by
which a staged file could still name `../../../../publish/…`); back up every
live file a staged path replaces, whole, before any live write; write; mark
`approved` LAST, so a proposal is never `approved` over a promotion that did
not finish. `revert` reads the BACKUP MANIFEST, not the proposal's status —
which is what makes it double as the recovery path for a promotion that died
halfway, not only the writer's "take this back": it restores every replaced
file byte-for-byte, deletes every file the proposal introduced (pruning only
the directories the round itself created, never one holding anything else),
marks the proposal `rejected` with a note, then discards the spent backup.
**This is a stored reversal the writer asks for by name, never an
`NSUndoManager` registration** — the ruling stated on `ProposalPromotion`'s
own doc comment, because a ⌘Z aimed at a sentence must never, at any depth of
an undo stack it happens to share, un-ship a book's templates. `approve` does
not gate on the proposal's own status beyond those three guards — a
`superseded` proposal can still be promoted, which reads as legitimate ("the
writer preferred round 2 to round 3") but is a product call a later milestone
may want to narrow.

**`finalize` is the third verb and the other way out of the slot**: accept
this promotion permanently — discard its backup, keep its `approved` status,
free the slot for the next round. It is deliberately separate from `approve`
rather than something `approve` does for itself when it wants the slot, because
it is the destructive half: after it, the templates that round replaced exist
nowhere, and that must be a thing the writer asks for by name rather than a
side effect of clicking "approve" on a later round. It refuses with no backup
to discard, and refuses over a proposal that is not `approved` — a backup
standing over a `pending` proposal is the signature of a promotion that died
mid-write, and its backup is the only way out of the half-swapped tree, so
the answer there is `revert`. It reads the STORE's status rather than the
caller's copy (`approve` marks `approved` last, so a caller holding the value
it passed in still reads `.pending`), and it is NOT gated on a running
compile: it removes a directory under `.maugham/design/` and moves no live
byte. `DesignProposalStore.delete(id:)` guards the same window from the other
side — see `Maugham/Stores/AREA.md`.

**The loop shipped headless through P3; P4 (2026-08-20) wired every verb.**
`DesignerOrchestrator.runDesign`/`.requestChanges` and
`ProposalPromotion.approve`/`.revert`/`.finalize` had no caller in production
through P3 — proven by `DesignerEnvironmentTests` and by the teardown census,
not by a keystroke. All five are now reachable: `runDesign`/`requestChanges`
from `DepartmentPaneHost` (the Design row's Run and its direction field,
`runDesign(direction:language:)` called with `language: nil` always — no
picker, no per-edition round, Denver's ruling spelled once at that call
site), and `approve`/`revert`/`finalize` from `DesignGatePromotion.perform`
(`Maugham/Views/Publish/DesignGateVerbs.swift`) behind the gate's own four
verb buttons — see `Maugham/Views/AREA.md`'s "The department desk" for the
surface. **The verb's result is written back into the caller's proposal, not
carried from the request**: `approve` marks the store `approved` as its LAST
step, so `DesignGatePromotion` re-reads the proposal after every verb and
hands the CALLER that, never the value it was given — `onProposalChanged`
then hands it to `PublishCentreModel.adoptVerbAnswer(_:)`, which is what makes the
footer that drew Approve draw Revert/Finalize on the very next frame with no
stale snapshot in between. A successful verb also posts
`.maughamDesignProposalsChanged` (ADR 0021, no payload) so the OTHER column —
the desk, whose `ReloadKey` watches only the designer's RUN state and would
not otherwise notice a promotion — re-derives too; a refused verb posts
nothing, because nothing on disk moved. `ProjectWindow.designRunRecord(_:)` —
`static`, pure, built in P3 ahead of having anywhere to render it — is now
that render site, the log line beside the desk's row. **Every window-ending
path owes `designer
.shutdown()`/`.detach()` beside the compiler's and the translator's** — three
session owners now, `CompilerRunModifier`'s teardown arms and `ProjectWindow`
's `.onDisappear` each carrying all three, weak captures throughout so a
closure cannot keep a closed window's stores alive.

**Where a proposal lives, for the reader who only wants the filesystem
answer.** `.maugham/design/proposals/<proposalId>/` holds `spec.md`, `files/
<relative path>` per proposed file, `proposal.json` (id, designer name,
round, created stamp, status, the recorded sample outcome), and — once a
sample has compiled — `scratch/`, the assembled copy-plus-overlay the compile
ran against, kept under the proposal's own folder rather than a temp dir so
the pages outlive the session that made them and a promotion's own backup
lands at `backup/` beside it. Every byte under `.maugham/design/` is derived
and safely deletable — `DesignProposalStore`'s own contract test proves
deleting the whole directory costs nothing else on disk — and a `stage` call
supersedes every still-`pending` proposal project-wide rather than by
language or by document, because the spec gives Design exactly one desk row
and one pending-proposal badge per project, never one per language the way
the translator's rows are. See `Maugham/Stores/AREA.md`'s own
`DesignProposalStore` entry for the store's shape.

## Cold calls — the sealed sessions (translation pipeline P2)

`ColdCall.swift` is the one runner every **cold** session shares: a reader, a
collator, a gloss and an Ask-the-collator (spec §5, §9 — the reader and the
collator arrived in P3, as `TranslationPipeline`'s two cold legs below; gloss
and Ask the collator in P4 Task 6, as `SpotCheck`; P2 built the runner and
wired its teardown). One call = one fresh process, one briefing sent, one
report returned, the process ended. There is no `ReaderOrchestrator`: warmth
would buy nothing (the whole briefing is re-sent every leg) and would cost
blindness.

- **Confinement is an enum on the session, not a setting** —
  `ClaudeCLISession.Confinement.bridged(mcpConfigPath:)` for the compiler,
  translator and designer (the two-flag membrane above, unchanged), `.sealed`
  for a cold call: **no `--mcp-config`, no `--allowedTools`**, `--tools ""` and
  `--strict-mcp-config` as before. Pinned by `ClaudeCLISessionTests
  .test_aSealedSessionSpawnsWithNoBridgeAndNoAllowlist` beside the bridged
  spike pin, and by two `TripwireGrepTests` censuses: `ColdCall.swift` never
  contains `writeMCPConfig`/`.bridged(`/`CompilerAllowlist`, and `.sealed` is
  spelled in production nowhere but `ColdCall.swift` and the session type.
- **One call at a time** (`runInFlight` refusal); no queue — leg order is the
  pipeline's (Plan 3).
- **Teardown: the census's fourth sibling.** `AgentRoster` holds the `ColdCall`
  beside the three orchestrators, and its `shutdownAll()`/`detachAll()` reach
  `coldCall.shutdown()`/`coldCall.detach()`;
  `TranslatorEnvironmentTests.test_everyWindowEndingPathShutsEverySessionDown`
  counts it.
- **The two spot-checks are `SpotCheck.swift`** (P4 Task 6), the other tempo
  beside a round: the caret is in a paragraph and the author asks *what does
  this now say?* (**Gloss**) or *does it still say what I wrote?* (**Ask the
  Collator**, `SpotCheck.askTitle`'s own capital), each a `Button` in the
  Translation pane — ⌘⌥L opens the pane,
  and **no shortcut is bound to either verb**. Spec §9 calls them
  "keystroke-triggered", which is ADR 0028's tempo contrast read correctly: the
  trigger must be a writer's own act rather than a timer or an event, and a
  button press is that act (P4 Task 6's ruling; a menu item for each is a later
  decision, not an omission). Gloss is briefed by `GlossBriefing`, whose
  `Inputs` **have no source field** — a model shown the original renders the
  original it can read rather than the translation it was asked about, so the
  property is the type's, not a caller's — and reads its paragraph off the
  **badge entries the pane already holds**, never the disk. Ask the collator
  is the collator's own briefing narrowed to
  one pair ± a neighbour (`SpotCheck.narrow`), with the writer's craft intent,
  edition brief, glossary and directives kept **whole**: a doctrine narrowed
  with the text would judge the paragraph against rules the author never
  relaxed. **Neither mints anything** (spec §12) — the answer is drawn, and
  *Keep mine* / *Make it a rule* are separate verbs the author presses,
  provenance `spot-check, keep mine` / `spot-check, make it a rule`.
  `TripwireGrepTests.test_aSpotCheckMintsNothing` scans `SpotCheck.swift` for
  the four write doors by name, which is why the file's own prose never names
  one.
- **The briefings it will be handed are pure**: `ReaderBriefing` and
  `CollatorBriefing` (this directory) follow `TranslatorBriefing`'s discipline
  — no I/O, no clock. `BriefingDoctrine.swift` is where directives and the
  glossary are read off statement markdown (`Ruling.directive`/`.glossary`,
  MaughamCore) into the plain values all three briefings take.

## The translation files — the wire, the briefings, the desk's own figure

Everything the pipeline and the two spot-checks are built out of lives in this
directory, on `TranslatorBriefing`'s discipline: pure, no I/O, no clock, testable
without a subprocess. The pipeline (below) is what strings them together.

| File | What it is |
|---|---|
| `ReportJSON.swift` | **The helpers every report parser shares** (P1): `lastObject(in:shapedBy:)` (the answer object in a turn's text, found by shape rather than position), `parseList` (all-or-nothing — one malformed item fails the whole list), `nonEmptyString` (trimmed, because whitespace around a model's answer is an artifact of how it wrote its JSON) and `enumValue`. `TranslatorReport` and `DesignerReport` were migrated onto it, and `ReaderReport`/`CollatorReport`/`GlossReport` were written on it. **`DiagnosticIngest` keeps its own copy on purpose** — the compiler's contract is sectioned and line-delimited rather than one JSON object, so folding it in would mean widening these helpers into a shape only one caller has |
| `ReaderReport.swift` / `CollatorReport.swift` | The two cold reports (spec §4). One JSON object, **all-or-nothing**, closed enums (`kind`/`severity`/`verdict`), empty `text` refused, zero notes valid, and a `paragraph_id` outside the briefed set failing the whole report rather than being dropped. `CollatorReport.Departure.gloss` is **required on every departure**: the gloss is the only part of a departure an author who cannot read the language can rule on, so a departure without one is not one this app can show. Only `drifted` departures are briefed to leg 7; both verdicts reach the round report |
| `ReaderBriefing.swift` | **`Inputs` has no source field**, which is the whole point of a blind reader — the property is the type's rather than a caller's discipline. A paragraph with no current translation reaches the reader as `gapMarker(_:)` (`[<id> — not yet translated]`) and never as source text; `briefedParagraphIds` is the translated ids alone, which is what the parser validates against |
| `CollatorBriefing.swift` | The pairs in `sequence` order, source then translation, each paragraph's directives beneath it, the glossary as a table, craft intent and the edition brief verbatim. Not briefed: reader notes, translator queries, the bible |
| `BriefingDoctrine.swift` | Where directives and the glossary are read off statement markdown into the plain values all three briefings take — `Directives.gather`/`.byParagraph`/`.isDirected` (UTC calendar days; a same-day directive counts, an undated one never directs) and `GlossaryTable.gather`/`.render` |
| `GlossBriefing.swift` / `GlossReport.swift` | The gloss's briefing and its one-field parser (`{"gloss": …}`, over `ReportJSON`). `Inputs` carries the paragraph, its two neighbours marked as context, the edition brief's texture line (`textureLine(in:)`), and — again — **no source**; a model shown the original renders the original it can read instead of the translation it was asked about |
| `SpotCheck.swift` | The two verbs the author presses (see "Cold calls" above): `gloss`, `askTheCollator`, `neighbours(of:in:)`, `narrow(_:to:)`, and one private `read(_:parse:)` that words a dead turn in `TranslationPipeline.coldLeg`'s own vocabulary, so the pane and the desk cannot describe the same death differently |
| `TranslationPreflight.swift` | **The desk's "7 legs · ~N words briefed" figure** (P4). `budgets(documentIds:languages:…)` opens each document ONCE and folds every language off that one `currentParagraphState`, because the desk was otherwise walking the whole book per language on every `maughamTranslationDidUpdate`; `budget(documentIds:language:…)` is a one-line wrapper over it, so there is one implementation. An empty answer means nothing in the set could be READ — distinct from a language whose figure is genuinely `0`, which is present and zero. `wordCount` splits on the same predicate `Bootstrap` does, so the figure agrees with the checkpoint's own count |

## The pipeline — seven legs (translation pipeline P3)

`TranslationPipeline.swift` is what spec §5 calls a Run: **a state machine
over closures, and nothing else** — it owns no session, gathers no briefing,
parses no translator report. It sequences the translator's two verbs
(`runTranslation`, `runFix`) and `ColdCall`'s one by awaiting the summary the
window feeds back (`onRunEnded`/`onRunAbandoned`) or the text `ColdCall`
returns, and it is the pipeline — not `ColdCall` — that turns a cold leg's raw
text into a `ReaderReport`/`CollatorReport`, because `ColdCall` returns text
and the report contract is the caller's (`TranslationPipelineTests`).

| Leg | Who | Input | Output |
|---|---|---|---|
| 1 translate | translator | stale ∪ missing ∪ directed | entries, queries |
| 2 read | reader | translated text, blind | notes + overall |
| 3 fix | translator | leg 2's notes | addressed/declined |
| 4 re-read | reader | the text again | notes + overall |
| 5 fix | translator | leg 4's notes | addressed/declined |
| 6 collate | collator | source + translation | departures + overall |
| 7 fix | translator | leg 6's `drifted` | addressed/declined, summary, proposals |

**Skips are recorded, never silent**, one static reason string per cause
(`TranslationPipeline`'s own constants): `nothingToTranslateReason` /
`nothingToReadReason` / `nothingToCollateReason` for a leg whose gather
answers an empty work-list, `noCurrentTranslationReason` for a fix leg whose
noted paragraphs lost their translation between the note and the fix,
`readerFoundNothingReason` / `collatorFoundNoDriftReason` for a fix leg with
no notes to act on, and `nothingWrittenReason` for a collate leg reached over
a round that wrote nothing at all. **Leg 4 has its own rule, and it is not
"nothing to read"**: it skips on `nothingChangedReason` whenever leg 3 wrote
nothing (`leg3Wrote`, set from leg 3's own `entriesWritten > 0`) — the text a
re-read would see is exactly the text leg 2 already read, so a second cold
call over it would ask the reader to re-judge its own unchanged verdict
(`TranslationPipelineTests.test_aFixWithNoNotesIsASkipAndTheRereadSkipsBecauseNothingChanged`).

**A failing, rejected or cancelled leg ends the round there; earlier legs'
writes stand.** `runRound`'s local `record(_:_:)` returns `false` for
`.failed`/`.cancelled` and the `legs:` loop breaks on it — `round.stoppedAt`
names the leg it broke on — while any entry a translator leg already wrote or
query it already minted is left exactly as it landed
(`TranslationPipelineTests.test_aFailedLegEndsThePipelineThereAndKeepsEarlierLegs`).
**Cancel reaches whichever leg is live** through one of two calls
(`environment.cancelTranslator()` / `cancelColdCall()`, chosen by the private
`live: LiveKind`), and **a cancel landing in the gap between two legs** — after
one leg's `setLive(.gap, …)` and before the next leg's own `setLive` — is
caught by the loop's own `guard generation == gen`, which records `.cancelled`
for the leg that never got to start rather than doing nothing
(`TranslationPipelineCancelTests.test_cancelInTheGapStopsThePipelineWithoutStartingTheNextLeg`).
**A cancel landing during a fix leg's `mintDeclinedQueries` is that same gap
case, not a cancel of the fix leg** (#77 F8): by then the leg has written its
entries and the mint has queued its queries, so there is deliberately no
generation check after the mint — the leg's addressed rewrites, its declined →
annotation links and (leg 7) the summary and glossary proposals are applied,
the leg is recorded as `.ran`, and the loop's top guard records the NEXT leg as
`.cancelled`. Checking there orphaned minted queries from the round record and
called a finished leg cancelled
(`TranslationPipelineCancelTests.test_aCancelLandingAfterTheMintKeepsWhatItMinted`,
`test_aCancelLandingAfterTheFinalMintKeepsTheSummary`).
`generation` is bumped by `start`, `cancel()` and `shutdown()` alike; `runToken`
is bumped only by `start` — which is what lets a cancelled run still put
`status` back to `.idle` in `execute`'s tail while a run that was shut down and
then replaced does not stomp the replacement's own `.running`
(`TranslationPipelineCancelTests.test_aBookStartedTheInstantAfterShutdownIsNotEmptiedByTheOldRun`).
A cold call that outlives its own run would otherwise resolve under the WRONG
run's `live` slot; `setLive` takes the caller's `token:` and no-ops once
`runToken` has moved past it
(`test_aStaleColdLegDoesNotBlindCancelForTheRunThatReplacedIt`).

**Note ids are minted before the fix leg is briefed, and the `.fix` work-list
is built FROM the notes, not the other way round.** A reader's note or a
collator's `drifted` departure becomes a `TranslatorBriefing.FixNote` carrying
the pipeline's own id (`ULID.generate()`, at `runRound`'s note-mapping sites)
before `TranslatorEnvironment+Project.fixBriefing` ever sees it, so
`addressed`/`declined` on the translator's report name a row of the record
directly rather than something matched by text afterwards. `fixBriefing` then
walks the notes and keeps only the ones whose paragraph is still `.fresh` with
a current translation, dropping the rest rather than briefing them blind
(`TranslatorEnvironmentTests.test_theFixGatherBuildsTheWorkListFromTheNotesItBriefs`,
`test_aFixGatherWithNoBriefableNoteAnswersAnEmptyWorkList`).

**`runFix`/`briefFix` are the orchestrator's second verb, `runTranslation`'s
peer over a `.fix` briefing built from the pipeline's notes** — the same
`start`/`begin` machinery, the same identity-then-briefing order, the same
warm session; what differs is only which gather closure `Environment` is
asked for. **`onRunAbandoned` is not a summary and must not be read as one**:
it fires when the briefing itself answers `nil` — a click on a pair with
nothing to act on, never sent to a session — and the pipeline's
`translatorRunAbandoned` resumes the waiting leg as `.abandoned`, which
`translatorLeg`'s own switch turns into `.failed(unbriefableSentence(role:))`
rather than into `nothingToTranslate`. Abandoned means "this pair could not
even be briefed" (`roundContext` found no readable current paragraphs, or the
language tag itself is malformed) — the same gate for `runTranslation` and
`runFix` alike — a different fact from "there was a work-list and it came back
empty", and the pipeline's `pending` continuation is what lets the two be told
apart:
`translatorRunEnded` resumes it `.ended`, `translatorRunAbandoned` resumes it
`.abandoned`, both landing on the same `CheckedContinuation`.

**Minting a declined note follows spec §6, and the translator's "reply" lives
in the query BODY because the annotation layer has no reply primitive.**
`TranslationPipelineEnvironment+Project.declinedBody` composes one string —
the note's kind and severity, its text, then "\<translator name\> declined:
\<reason\>" — and `mintDeclined` writes it as a `.query` (or a doc-scoped
`.craftNote` when the note's paragraph is gone, `Document.addAnnotation`'s own
anchorless rule) authored by the READER or COLLATOR who raised the note, never
the translator: the translator did not ask the question, it answered one, and
the answer is prose under its own name inside a note somebody else owns. No
new `OpKind` or `AnnotationKind` was added for a reply — that would have been
a bigger membrane change than a milestone about legs and rounds should make,
and the prose does the job
(`TranslationPipelineEnvironmentTests.test_aDeclinedNoteMintsAQueryCarryingTheTranslatorsReason`).

**`TranslationRound` is the pipeline's whole product — a plain `Codable`
value with no store behind it** — and `TranslationRoundStore` is its ring:
`.maugham/translations/rounds/<lang>.json`, the newest 10 rounds per language
(`TranslationRoundStore.ringSize`) plus a `nextNumber` that outlives the ring
so a trimmed-out round's number is never re-minted
(`TranslationRoundStoreTests.test_theRingKeepsTheNewestTenAndNumberingRunsPastIt`).
Numbering is **per language, across every document that language has ever run
a round on** — a book queue's several chapters share one counter, not one
each (`test_numberingIsPerLanguageAcrossDocuments`). See `Maugham/Stores
/AREA.md`'s own entry for the file's derived-state contract.

**The book queue stops on a failed round; it does not skip the chapter and
move on.** `execute`'s `while` loop breaks the instant `runRound` answers a
round with `stoppedAt != nil` — the next chapter would meet the same broken
session or the same rejected batch, and the author needs to see THIS one
before another is attempted blind
(`TranslationPipelineCancelTests.test_aFailedRoundStopsTheBookQueue`;
`test_theBookQueueRunsEveryChapterInOrderWithConsecutiveNumbers` for the
un-failed case; `test_cancelStopsTheBookQueueAfterTheLiveLeg` for the writer's
own Cancel).

**The desk's busy gate now reads `TranslationPipeline.Status`, and it
outranks the orchestrator's own `RunState`.** A round's cold legs — the
reader's, the collator's — hold no warm translator session at all, so
`TranslatorOrchestrator.isRunning` answers `false` while a reader is out, and
every row on the desk would offer Run mid-round with nothing stopping the
click. `DepartmentRunSession.read(runState:isRunning:pipeline:)` checks the
pipeline first and falls back to the orchestrator's own state only when no
pipeline round is up — a bare `runTranslation` reached some other way, or a
probe that mounts with no pipeline at all.

**The teardown census's fifth sibling.** `AgentRoster` holds the pipeline
beside the compiler, the translator, the designer and `ColdCall`; its
`shutdownAll()`/`detachAll()` reach `pipeline.shutdown()`/`pipeline.detach()`
FIRST, before the other four, and
`TranslatorEnvironmentTests.test_everyWindowEndingPathShutsEverySessionDown`
counts it — not for a process, the pipeline holds none, but for a leg
awaiting a translator summary that a shut-down orchestrator will never send:
`shutdown()` resumes `pending` as `.abandoned` so the round is at least
recorded rather than left `.running` forever on a desk nobody can close.

**What Plan 4 drew, and where the pipeline is now read from**:
`TranslationRound.Leg.verb` (the present participle — "translating", "fixing",
"collating") is read off `Status.leg` by `DepartmentRunState.legLine`, and
`TranslationRoundStore.trend(language:)` (notes-per-round over the last five
rounds, oldest first) by `DepartmentRunState.trendLine`; both draw on the desk
row, and `TranslationRoundStoreTests.test_theTrendReadsNotesPerRoundForTheLastFive`
is still `trend`'s own pin. **The pipeline's status is read on the body path,
never through `ReloadKey`** — `ReloadKey` carries `pipeline?.status.language`
alone (P3's ruling 7), because a leg-keyed re-derive re-walked the whole book
once per leg. The round's own product is drawn by the round report
(`Maugham/Views/Publish/TranslationRoundReport.swift` and its peers — see
`Maugham/Views/AREA.md`), which is also where the verbs that write BACK into a
round live: `TranslationRoundStore.update(_:)` rewrites one round in place and
refuses in words when the ring has aged it out, and this area's own writes
(`append`) never touch it.

## Tripwires this area sits on

- **17 / 24 — the sidecar.** `.maugham/diagnostics/<docId>.<slug>.json` is
  per-`(document, device)`: two Macs running the compiler against one document
  must not race each other's file. **It holds TWO standing runs, one per
  `RunKind`** (two loops P1 Task 5): `FileContent.check` and `FileContent.round`,
  each replaced only by its own kind (`CompilerRun.effectiveKind`), with the
  drift ring and the round ring beside them belonging to the document rather
  than to either verb. The readers are split to match — `lastCheck` is
  Author's pane, `lastRound` is the Review cockpit, `lastOpId` and `live`/
  `dismiss` are the check's, `standingRound`/`latestRound` and the round ring
  are the round's, and `lastRun` (the NEWER of the two by `at`) is kept for
  exactly ONE question that is about the document rather than either loop:
  `IntentDrift.mayTrailDraft`'s mark. **The unread badge is the CHECK's**
  (whole-branch review, finding 2 — Ruling 9): `unreadCount(docId:)` reads the
  check slot alone, because the pane the badge sits over draws the check alone,
  and `markRead(docId:kind:)` clears one verb's count for the same reason — a
  round's notes are open rows in Review's queue and are counted there. The
  round's own per-slot count is still recorded by `replace` and no P1 surface
  reads it. The on-disk keys are `check` and `round`; the legacy top-level
  `run`/`diagnostics` pair is READ and never written again, landing in the slot
  its own `effectiveKind` names (tripwire 11 — no migration, the old file
  simply loads) — **and `effectiveKind` is a two-clause rule, because the
  coach's lane never named a round**: a legacy record carrying
  `passId: "workshop"` was an Author ⌘R under the build where the coach read
  every unassigned piece, so it loads as a CHECK. Read as a round it emptied
  Author's pane, handed the cockpit her letter as a standing round and dropped
  the delta marker (`RunKindTests`' legacy pins; `DiagnosticsStoreTests`' two
  real-sidecar fixtures under `MaughamTests/Fixtures/`). **A round's
  conformance strains are stored in the round slot and drawn nowhere in P1**
  — a deliberate carry, not an omission: the round's findings reach the writer
  as annotations in the queue. `DeviceSlug.raw` is interpolated in
  `DiagnosticsStore.sidecarURL` and in `DiagnosticsStore.refusedColdStartURL`
  — the cold-start offer's refusal memory, `.maugham/diagnostics/
  cold-start-refused.<slug>.json`, ONE small per-device file for the whole
  project rather than per-document (a refusal is a single bit with no run
  beside it, and can be recorded before a document has ever been run at all,
  before its own `FileContent` exists) — and nowhere else in this file: the
  slug lives only in filenames and is never serialised into content. Two more
  per-device sidecars joined Stage 2, both on the same discipline:
  `.maugham/derived/<scopeKey>.<slug>.json` (`DeclaredWorldStore.sidecarURL`,
  one per statement scope) and `.maugham/bible.<slug>.json`
  (`BibleStore.sidecarURL`, one per project). `.raw` is interpolated only at
  each of those two call sites.
- **The round ring is the DOCUMENT's, not any one pass's — and it is ROUNDS
  only.** `FileContent.rounds` is one array per `docId`, capped at
  `roundHistoryDepth` (5) — every pass files into the same ring. The document
  actually remembers six finished rounds — the ring plus the standing round,
  which is filed into the ring only when superseded — so a Structural round is
  pushed out once six later rounds (in any lane) stack up behind it. A CHECK
  contributes nothing to it (two loops P1 Task 5): it was a ring of "whatever
  finished last" while the two verbs shared one slot, so an Author ⌘R between
  two rounds became the round the next one said it was measured since. It is
  written only by `replace`, and only for the run being SUPERSEDED —
  `RoundRecord(run:)` is built from `finishedStanding(docId:kind:)`, which
  reads the in-memory `byDoc` entry's own slot directly except while a preview
  is standing in for that slot, when it reads the shadow
  `finishedBeforePreview` captured the moment the preview began (keyed by
  `SlotKey` in the `previewing` Set, never on the shadow's
  nil-ness — a cold document's first preview captures nothing, and a `??`
  fallthrough there would read the run's own half-report as the previous
  round). `latestRound(forPass:docId:)` reads the ROUND slot of `byDoc` directly, never that
  shadow (R1, #42) — its two readers are `beginRun`'s round mint, reached only
  when `runRequested` finds `!isRunning`, and the Review cockpit strip
  (`AnnotationsPane.cockpitRound`), both of which need "which round is this
  lane on, the one in flight included" rather than the round before it —
  `sinceLastRoundLine` (`RoundNarrative.swift`) never calls it; it reads the
  run's own `round` and the ring directly. It checks the standing
  run first (newest of all, and not yet in the ring) and only then walks the
  ring newest-first for a record matching that `passId`; a lane
  whose records have all aged out of the shared ring answers `nil`, same as a
  lane that has never run, so the next round in it mints round 1. **The round
  number, and which pass it belongs to, are minted in `beginRun`'s synchronous
  prefix — before the request is sent, before a single byte of preview
  arrives.** They cannot wait: from the first closed section onward the
  standing content IS this run's own preview, so a mint at record time would
  read the run's half-report back and file the answer as the round after
  itself. Minted once, the pair rides `StreamingRun` and threads through the
  one `record(...)` spelling, so the preview and the final answer describe one
  round rather than two checks that happen to disagree.
- **Neither round sentence draws in Author's pane any more** (two loops P1
  Tasks 5 and 7). The since-last-round line went first: Author reads the CHECK
  slot, and a check carries no lane and no round number (Task 2), so
  `RoundNarrative.sinceLastRoundLine` refuses it. The Fresh Eyes header went
  with it in Task 7 — Author's ⌘⇧R IS a check, so a cold reread was drawing
  the round cockpit's vocabulary over a run that has no round to be fresh
  about. Both sentences' home is the round cockpit
  (`AnnotationsPane.cockpitReportLine`, off the round slot); the narration
  itself still has one owner (`RoundNarrative`) and its tests moved with it to
  `RoundNarrativeTests`. `DiagnosticsPaneTests`'
  `test_neitherRoundSentenceIsDrawnOverAColdCheck` mounts the sharpest case — a standing round in the ring
  beside a standing fresh-eyes check — and refuses both strings; the
  `content`-arm census
  (`test_theLetterLeadsBothArmsAndPrecedesThisCheck`) refuses their
  return at the source. **The hoist-above-the-fork note they used to carry
  still applies to what took their slot**: `content` forks on `hasReport`, and
  a round in a pass over a piece with no declared intent raises no clause and
  no strain, so `hasReport` is `false` and that run's whole output is queued
  notes. Anything that must be seen in THAT state has to render in both arms,
  not only inside the `else`. **`DiagnosticsPane.thisCheckSection` (M4 P2
  Task 1, spec §7.0) is the second resident of both arms and is there for the
  same case**: Author's live view of the notes the latest CHECK minted, filtered
  out of the annotation layer by `lastRun.id` (the pane's own private name for
  `DiagnosticsStore.lastCheck` since two loops P1 Task 5), whose whole point is
  the intentless check whose entire output is queued notes. Anything that dedups
  the fork has to keep both arms drawing it.
- **3 / 6 — the arrival.** Nothing here holds an editor binding or a
  `Document`. What a run needs off the live document arrives as a
  `DocumentReading` value captured at the keystroke, and paragraph text is
  re-read at ingest through a closure. An orchestrator that held the `Document`
  across a subprocess turn is exactly the shape those two tripwires are about.
- **20 — derive, never read the `.md`.** The delta is built from ops and the
  live paragraphs; the intent is read through `ProjectStore.statementText(of:)`,
  the one spelling of ADR 0018's two branches. Every raw read in this directory
  carries an `// adr-0018-ok:` annotation naming why it is not manuscript.
- **21 — events.** `MaughamEvent` only; the pane's Open Intent posts a scoped
  detail-segment event rather than a bare notification.
- **The allowlist census** (`MaughamTests/CompilerAllowlistTests.swift`) is the
  membrane in test form: every entry resolves to a catalog tool, no entry is a
  write, no statement-writing tool exists in the allowlist **or the catalog**,
  and each of those has a planted-offender companion so none of them can be
  quietly unfalsifiable.
- **The membrane is TWO flags, and the census guards only the stronger half.**
  `--allowedTools` removes nothing — it pre-approves what it names so those
  tools skip the permission prompt. Under `-p` that does leave Bash/Edit/Write
  unreachable, because they would prompt, but the built-in Read/Glob/Grep never
  prompt inside the working directory, so an enumerated list on its own leaves
  the spawned model free to read any file it can reach. `--tools ""` is what
  empties the built-in set; `currentDirectoryURL` is set to the session's own
  config directory behind it so an inherited cwd is not the writer's project
  either. The whole-branch review proved the gap live before the flag landed —
  a perfect allowlist and a model reading an arbitrary file off disk in the
  same invocation. `ClaudeCLISessionTests.test_spawnArgumentsMatchTheSpike`
  asserts both, and it parses argv with `components` rather than `split`
  because the flag's value is the empty string.
- **The session is the reader's own, not the writer's** (2026-09-09,
  reader's-own-session spec §3). The preamble rides on `--system-prompt`
  rather than `--append-system-prompt`, so it is the whole system prompt and
  not appended to the CLI's own coding-agent one —
  `TripwireGrepTests.test_noProductionSpawnAppendsToTheCodingAgentPrompt`
  forbids the append flag in every production spawn. `--setting-sources ""`
  keeps the writer's hooks, plugins, CLAUDE.md and global effort out of the
  session entirely (`test_everyProductionSpawnIgnoresTheWritersSettingsFiles`).
  `--effort` is passed explicitly (`ClaudeCLISession.Effort`, `defaultEffort
  = .high` for every kind until the evals milestone decides otherwise) because
  `--setting-sources ""` drops the effort level the writer's own runs would
  otherwise have inherited. `--bare` is forbidden — it never reads OAuth.
  `DeclaredWorldDeriver.arguments` passes the same three flags.

## The intent loop, both directions

This is what the milestone exists for, and the two halves are asymmetric:

- **Drift — never a note again, and now two readings of the same worry.** v1
  raised it as an anchorless diagnostic from an `intent_drift` field. What
  replaced that is the PATTERN: read back from the run records the sidecar
  already keeps — a clause straining the same way across
  `DriftDetector.consecutiveRunsThreshold` (3) consecutive runs (spec §3.4) —
  and surfaced as one line above the pane's conformance summary
  (`DiagnosticsPane.driftNote`), not a `Diagnostic`: no id, no dismissal, no
  reply field. Pressing it opens Intent; the pattern breaking on the next run
  is what takes the line away, not a tap. **M3-P3 then asked the question
  directly again**, as a fifth schema section and a per-round verdict
  (`DiagnosticIngest.parseIntentDrift` → `SectionedOutcome.intentDriftVerdict`
  → `CompilerRun.intentDriftVerdict`) — and it is still not a `Diagnostic`, for
  the same reason: a judgement about the whole reading has nothing to anchor to
  and nothing to answer. Two rules keep it honest. `holds`/`drifted` and
  nothing else, with an unrecognised word reading as no verdict rather than an
  `unknown` case, because the verdict is a projection this build never
  re-encodes. And the one sentence the schema asks for alongside it is read at
  ingest and **dropped** (ADR 0027: nothing model-produced renders in the
  editor's chrome) — the mark the verdict raises is app-authored.
- **Accretion** — an anchored note offers **Answer**, and the writer's sentence
  becomes a **ruling** on the **piece's** intent statement (never the
  project's), minting it if absent: an itemized, dated line under `## Rulings`
  carrying where it came from. Spec §3.4 names the old shape — a chat reply
  appended verbatim to the essay — as the membrane's loosest point, and this is
  the tightening. The answered note dismisses. The next run reads the enriched
  intent.

`RulingPerformer` is `PromotionPerformer`'s shape with two deliberate
differences — no autosave flush, no project-scope fallback — both argued at
length in its own doc comment. Read that before adding either back.

**Claude has no route into a statement, and that is enforced rather than
intended.** The compiler reads the intent it is judged against; a model that
could also write it can move the standard until nothing it produced is ever
flagged again. The census above is what keeps that true as the catalogue grows.

## The derivation trigger — decided here, because Stage 2 needs the answer

**Lazy, on-demand only: the first consumer that finds
`DeclaredWorldStore.cached(forScopeKey:sourceHash:) == nil` for the current
statement's hash is the one that calls `WorldDeriver.derive(statementText:)`
and stores the result.** No background derivation, no derive-on-save — the
same constitutional rule ADR 0027 §3 states for the run itself ("on demand,
never continuous") applies to the reading a run is checked against. A
statement mints or edits for reasons that have nothing to do with a check
being imminent; deriving on every keystroke would spawn a subprocess for
prose nobody is about to compile against.

**The run is that consumer, and it is the only one.**
`CompilerOrchestrator.resolveWorld` is the single production call site of
`WorldDeriver.derive` — it asks `Environment.cachedWorld` first and reaches
for `deriveWorld` only on a miss, both of them closures the production wiring
points at `DeclaredWorldStore` (`CompilerEnvironment+Project`). A derivation
that succeeds is cached by the closure that made it, or the next keystroke
pays for it again
(`CompilerRunCommandTests.test_productionCachesWhatItDerives`); a derivation
that fails caches nothing, because there is no such thing as a cached "could
not read this".

The other consumer the spec names — **the pane's own conformance preview** —
is still not built, and deliberately: the Rulings and Bible strata
(`RulingsStratum.swift`, `BibleStratum.swift`) read `RulingsSection.parse`
and `BibleStore.allFacts()` only; neither reads `DeclaredWorldStore.cached`
or draws a clause or a rule. That is the "never shown as mechanics" rule
(spec §3.1) held all the way to "never even asked for", and
`StatementPaneStrataTests`'s "no derivation is ever drawn" census is what
keeps it true.

Two things the trigger's shape buys, both worth keeping when you touch it:

- **A derivation is the run's second suspension**, after the burst flush and
  before the send, and it is the long one — a whole subprocess. It carries
  `CompilerOrchestrator.runGeneration`, so the AI toggle going off while a
  derivation runs abandons the run instead of spawning the session the toggle
  was meant to prevent.
- **The statement is derived WHOLE and briefed by halves.** `derive` reads
  essay + rulings (the rulings are half of what there is to derive); the
  message carries the essay as prose and everything below it as clauses. See
  "the atomic switch" below.

`RulingPerformer` invalidates the cache on every write (`rule`/`revoke`/
`edit`, each taking `world` as an explicit, undefaulted parameter — see that
file's own doc), which is what makes a revoked ruling stop being checked
immediately rather than at the next statement edit. **The cache key stays the
scope alone** even now that a verb can be aimed at an edition brief: nothing
derives a world from a brief, every brief-side caller passes `world: nil`, and
a second key shape would be the two-spellings defect `scopeKey` exists to
prevent — the day a brief is derived, `DeclaredWorldStore` grows the kind once,
for both readers.

## The atomic switch — why the essay and the clauses landed together

Until Stage 2 the run briefed the statement WHOLE, and that was correct:
rulings are declarations, and a contract with no notion of a derived clause
had to see them as prose. The moment the run consumes clauses, briefing the
prose as well puts the same declaration in front of the model twice — and a
model told a clause twice weights it over the rest of the writer's intent,
which quietly stops the run being about the essay. So the two halves had to
ship in one commit, and they did.

The guard is `CompilerRunCommandTests.test_rulingsAreBriefedAsClausesNotProse`
— the essay present, the derived reading present, the `## Rulings` heading and
the row's date/provenance absent, and the writer's ruled sentence appearing
**exactly once**. Count the occurrence, not the presence: presence alone
passes on a message that carries the sentence twice.
`test_aRulingBetweenRunsReachesTheNextBriefing` is the same guard over the
whole chain — a real `RulingPerformer.rule` between two real runs — and it is
the one that says the ruling *arrives*, not merely that the prose does not.

**The door this does NOT close, and the shape of the risk if you change the
contract.** `ClaudeWorldDeriver.derivationSchemaDescription` asks for a
`quote` copied verbatim from **the statement**, essay included — not only from
the Rulings stratum. So a real derivation can return a clause whose quote is a
sentence of the essay, and that sentence is then in the message twice: once as
the essay's own prose, once as the clause's citation. It is the identical
over-weighting the switch above exists to prevent, arriving through a
different door, and nothing today measures it — the guard counts the RULED
sentence, and the fixture's essay-sourced clause is deliberately not counted.

Left open rather than closed, on purpose: the honest fixes are all contract
changes (quote essay clauses by reference, or drop the essay's prose once every
sentence of it is a clause), each of which trades one kind of loss for another
and belongs to a milestone that can measure the result. **What must not happen
is closing it by accident** — if you widen the derivation schema, or make the
briefing embed clause quotes some other way, this is the paragraph to re-read
first. A watch item for Stage 3, recorded here because a reader of
`worldSection` cannot see it.

## The third door: bless converges, and graduated is not dismissed

**Closed in Stage 3.** `BibleStore` remembers the `(subject, fact)` keys the
writer has GRADUATED — blessed or corrected into a ruling — and `record` drops
a candidate whose key is one of them. `BibleStratum.graduate` marks the key
after `RulingPerformer.rule` succeeds and before `bible.dismiss`, so a refused
ruling leaves both the fact and the door exactly as it found them. The keys ride
in the per-device sidecar beside the ledger (one envelope, because a graduated
key that outlived its facts would put the blessed reading back on the pane the
launch after somebody deleted the wrong half; a bare-array sidecar from a
previous build still loads and simply has nothing graduated).

It is deliberately NOT a memory of **dismissal** — spec §3.3 is unchanged, a
plain dismiss keeps no memory, and a manuscript that re-establishes a dismissed
fact is a reading returning rather than a record surviving
(`BibleStoreTests.test_dismissedFactCanReturn_thisIsIntended` sits adjacent to
`test_aBlessedFactDoesNotComeBack`, each naming the other).

**A correction marks two keys, and the second one is the half that reopened the
door.** It rules "Kelly is a paramedic" over a reading of "Kelly is a nurse",
and the manuscript can establish either afterwards — the reading, because the
prose that produced it is still there, and the ruling, because the writer has
since written toward what they decided. Marking only Claude's reading left the
writer's own sentence free to come back as a fresh candidate, which is door 3's
step 4 (a duplicate ruling row) reached through correction instead of bless;
measured against the shipped code in fix round 1's review. Both are declared or
superseded now, so a candidate matching either is not news. A bless has one
sentence in both roles and marks one key.
`StatementPaneStrataTests.test_correctingGraduatesClaudesReading` and
`test_correctingAlsoGraduatesTheWritersOwnRuling` are adjacent, each naming the
other, because neither is the whole rule.

**Revoking the ruling does not reopen the door**, by decision rather than
oversight — a revoke is the writer unmaking a decision, not asking to be
re-offered the reading days later about prose they have since rewritten, and
resurrection would have to guess which of a correction's two sentences was ever
a fact. The reasoning lives on `BibleStore.markGraduated`; if a smoke says
otherwise the fix is one `graduatedKeys.remove` at the revoke site.

The walk below is what the design answers, kept because it is the rationale and
because every step of it is what the tests assert against:

1. Run N reads a fact; the writer blesses it. `BibleStratum.graduate` mints a
   ruling through `RulingPerformer.rule` and then calls `bible.dismiss` —
   correct so far, the fact leaves the ledger as the clause enters the world.
2. The writer later revises the establishing scene. Run N+1's delta contains
   that prose again, the model re-emits the same fact, and `record` re-adds it:
   **the blessed fact is back in the stratum, indistinguishable from new**.
3. From then on the same declaration is briefed **twice** — as a bible fact and
   as the ruling's derived clause. That is the over-weighting the atomic switch
   above exists to prevent, arriving through a **third door** (door 2 is the
   essay-sourced clause quote, the section above).
4. A writer who blesses the returned fact again mints a **duplicate ruling
   row**: `RulingsSection.appending` does not dedupe, and the duplicate then
   renders as duplicate conformance rows, which `conformanceRows` embraces by
   design.

Of the two candidate fixes, the shipped one is the tombstone: it is
derived-state-shaped and does not touch the membrane. String-matching `record`
against ruling texts was rejected — it is fragile, and it misses corrections
entirely, where the ruled sentence and the re-emitted reading are different
strings by construction.

**The loop is walked end to end by one test.**
`CompilerRunCommandTests.test_theBibleLoopConvergesAcrossRunsWithABlessInTheMiddle`
drives three runs over a real project with a real mounted `StatementPane`: run 1
reads the fact and the stratum shows it, the writer presses the real `Bless`
button through the accessibility tree, run 2 re-emits the identical candidate,
and run 3 is where a returned fact would have been briefed. Three runs and not
two because **the ledger is read at the start of a run (`bibleSlice`) and
written at its end (`recordFacts`)** — the run that re-emits a blessed fact is
never the run that would brief it. Falsified by deleting `record`'s graduated
guard: the fact returns to the register and to the pane, and run 3's message
carries the same declaration twice, once as a bible fact and once as the
ruling's derived clause.

## The four fates of a note — narrowed to the sidecar's own kind, M4 P1

**As of M4 P1, a `Diagnostic` in the sidecar is a conformance strain, and
nothing else** (`SectionedOutcome.sidecarDiagnostics` filters to
`.conformanceStrain`; the paragraph below the numbered list is where a
continuity question and a reader's report actually go instead — they never
reach this section's four fates at all). What follows described every kind of
finding through M3-P3; it now
describes a strain's own lifecycle, and a strain ends one of four ways, only
one of which is a button:

1. **Superseded** — the next run's diagnostics wholly replace the previous
   run's for that document, and its `clauseStatuses` replace the previous
   summary in the same act. Un-promoted strains are dropped, not merged.
2. **Stale** — its paragraph's text no longer matches the text it was anchored
   to, so `DiagnosticsStore.live` stops returning it. A strain that names no
   paragraph at all never goes stale this way; it has nothing to track. A v2
   note's anchor is its FIRST resolving ref, so the staleness rule needs no
   per-kind variant and `refs` stay display-only.
3. **Promoted** — kept as an op-logged task, which syncs and survives
   (`DiagnosticPromotion`, whose doc comment now names its own narrowed
   scope: a strain, never a continuity question or a reader's report, which
   are already op-logged the moment they mint and would gain nothing from a
   second copy in the task list. The promotion function's `sectionLabel` still
   answers "continuity"/"the reader" for a task promoted *before* this
   milestone — an old record's provenance line must not lose its section
   just because the pane stopped drawing it).
4. **Answered** — became a ruling on the piece's intent (`RulingPerformer`),
   and (M4 P1 Task 6) the ruling now carries the answered strain's own
   `clauseQuote`, sanitized and trimmed to `driftQuoteMaxLength` (60,
   `DiagnosticsPane.answeredNoteProvenance`), so a later reader of the Intent
   pane sees what was ruled *on* rather than a bare "answered a compiler
   note" with nothing beside it.

**A continuity question and a reader's report have no fates here at all —
they leave the sidecar for the annotation layer the instant a run finishes**
(`Environment.mintAnnotations`, described in the seam map's `CompilerNote.swift`
row above). From that moment they are ordinary
`Annotation`s and follow that layer's own lifecycle: open in the queue and the
margin, then accept/reject/stet/discussed/promoted-to-a-task through the same
verbs and the same undo conventions (ADR 0023) as any note Claude Desktop
wrote by hand. `RulingPerformer` never sees one — a continuity question is
disposed of in the queue, not answered into a ruling, which is the one place
this milestone actually narrowed what `RulingPerformer` reaches rather than
widening it.

The sidecar is derived state: a missing or corrupt file reads as empty rather
than throwing, and losing it costs nothing because the next run repopulates it.
There is no repair path, only "start from nothing" — `CanvasStore.load`'s
contract, one directory over.

## Streaming — the report arrives in sections, and a preview is not a run

Built third stage (Task 4). Stage 2 named it a follow-on and left the ingest
ready for it: `parseAll` is `parseSection` folded over the turn and nothing
else, so sections could always be read one at a time. Four things carry it, and
three of them are about what a half-arrived report may NOT do.

**Six sections arrive, and the letter is the last of them** (editorial letter
P1). It is asked last on purpose, so the writer reads line-level results while
it is still being written — which is exactly the shape streaming was built for,
and the reason the letter needed no streaming work of its own: a section is a
section.

- **The stream is asked for, and only one delta kind is the answer.**
  `ClaudeCLISession.arguments` adds `--include-partial-messages`; `classify`
  gained `.partialText`, keyed on `stream_event → event.content_block_delta →
  delta.text_delta`. **All three delta kinds arrive as `content_block_delta`**
  — `thinking_delta` carries the model's private reasoning, `signature_delta`
  an opaque blob — so a classifier keyed one level too high feeds the
  orchestrator a report made of the model thinking out loud, and nothing
  downstream can tell. Captured from a real turn rather than guessed;
  `ClaudeCLISessionTests`' `captured…` constants are that turn's lines
  verbatim, and the falsification (accept `thinking` too) fails two tests.
- **Deltas ride `receive`, behind the SAME two guards as the result** — live
  generation, turn in flight. A retired process's enqueued deltas would
  otherwise be spliced into the run that replaced it, and that run would still
  resolve normally, so nothing would look wrong
  (`test_aRetiredProcessesDeltasNeverReachTheHandler`, planted).
- **A chunk is not a line.** `CompilerOrchestrator.receivePartial` accumulates
  and reads only what a newline closed. The transport cuts wherever it likes,
  and a truncated object can look complete.
- **The result REPLACES the preview; it never folds into it.** `finish` runs
  `parseAll` over the whole turn and calls `replace`. Accumulating instead
  shows a model's restated section twice, persisted
  (`test_theFinalResultReconcilesTheStream`, falsified).

`DiagnosticsStore.preview` is the storage verb and is deliberately weaker than
`replace` in three ways, each a defect if a preview did it: **no persistence**
(a half-report on disk reads back as the standing answer), **no drift ring**
(`DriftDetector` counts consecutive RUNS — one check's sections, folded in one
at a time, would fabricate a pattern), **no unread badge** (a badge for notes
the cancel removed is a badge nothing can clear). `discardPreview` is a re-read of the
untouched sidecar, which is why a cancelled preview puts the previous *finished*
run back rather than clearing the document. Every path where a run ends without
an answer discards: `finish`'s failure arm, the unusable-output arm, `cancel()`
(also directly — the continuation resumes a tick later, and the writer watches
the half-report until it does) and `shutdown()`.

The pane needed no new state to DRAW a preview. The version counter already
draws whatever is stored, and `headerState` prefers the run state for this
document, so the wait copy keeps saying "Checking…" while the report grows
under it.

**A preview's rows carry no fates, and that took two guards** (the whole-branch
Critical, fixed in the fix wave). `preview` weakened three of `replace`'s
verbs, but `dismiss` — this store's third writer, and the only one older than
streaming — still persisted, and BOTH fates end in it: `DiagnosticsPane.promote`
and `commitAnswer` each call `dismiss` last. So answering a streamed note wrote
the half-report to the sidecar as the standing answer, **with the marker
`beginRun` mints before the send on it**, and a cancel then read it back — the
prose the aborted run stopped reading would never be checked again. A run that
completed instead resurrected the answered note through `parseAll`-replace (the
turn's own text still contains it, with a fresh id) and a second answer minted a
duplicate ruling. Neither task's suite composed the two: the streaming tests
only ever *watch* a preview, and the fates' tests never stream.

The fix is one bit and one precondition, no new run-state reading:

- `DiagnosticsPane.offersDurableActions(state:)` — pure, taking `HeaderState`
  so it inherits `headerState`'s per-document scoping. Only `.running`
  withholds Answer and Promote; a run on ANOTHER document reaches it as
  `.idle`/`.clean` and that pane keeps its fates — and so, since #77 F7, does
  a ROUND on this one: `RunState`'s three run cases carry a `RunKind`,
  `headerState` matches `.check` alone and `ReviewRoundCockpit.phase` `.round`
  alone, and each surface names the other loop's run in one pure line
  (`DiagnosticsPane.otherLoopLine`, `ReviewRoundCockpit.otherLoopLine`) —
  WINDOW-wide, because the session is the window's — while its Run/Reread
  stays refused and Cancel is offered beside the line. That makes a check
  note answerable mid-ROUND, which is safe only because `DiagnosticsStore`'s
  one `persist` writes every previewing slot's FINISHED answer
  (`finishedBeforePreview`) rather than its half-report, whoever is writing. `.failed`/`.nothingNew`
  describe runs that are over and their rows are the last finished report's.
- `DiagnosticsStore.dismiss` refuses outright while `previewing.contains(docId)`
  — in memory as well as on disk, so the door is shut rather than the handle
  hidden, and any future per-note mutator inherits the rule.

Falsified both ways: force the gate true and the mounted preview test goes red;
drop the precondition and the byte-identical sidecar test does
(`test_aDismissalCannotReachAPreview_soTheSidecarSurvivesACancelByteIdentical`,
which asserts the file did not change *at all* — the only assertion a write
that merely round-trips cannot satisfy).

**`CompilerRun.mintedNotes: Int?` exists so the pane can never claim a clean
check over a run that queued notes** (M4 P1 Task 3 review, Important). A run
raising three continuity questions and no conformance strain leaves the
sidecar empty — before this field, every surface keyed on "were there
diagnostics?" answered yes to "nothing to flag," including the header, the
empty state's seal, and the unread badge, which cleared itself on the one run
it exists to announce. `finish` mints BEFORE it records
(`CompilerOrchestrator.record`'s `mintedNotes:` parameter), so the count
exists to be written down. `DiagnosticsPane.headerCopy`'s `.clean` arm opens
with `queuedNotesSentence(run.mintedNotes)`, falling back to "Nothing to
flag" when that is `nil` — **as it stood before M4 P2's Task 1 added
`WetInk`**. Now that opening is gated on `wetInk == .none`: when `wetInk` is
`.showing` or `.settled`, This check is drawing those same notes directly
below this line, so the header says "Nothing to flag" regardless of
`mintedNotes` rather than pointing the writer at a queue the notes are
already visible under — `wetInk`'s own doc comment on `headerCopy` carries
the current rule. `emptyState` gets its own **"Notes in your
queue"** arm (reached only when `wetInk == .none` too), ordered ABOVE the
discarded-notes arm because it is the stronger claim — a run can both queue
notes and lose some, and the queued ones are the news the writer needs
first. **The legacy trap, named so the
next empty-state simplifier does not re-open it:** before this fix the pane's
note count came from `rows.count`; since the M4 P1 slimming, `rows` can hold
notes this pane refuses to draw (a sidecar written by an older build, still
carrying continuity/reader-kind `Diagnostic`s), so a legacy sidecar of stale
continuity rows reached the `.idle` header state and called itself clean —
the header cannot be simplified back to counting `rows` without resurrecting
that false "Nothing to flag." `headerState` is fed `strains.count` instead,
which is what makes `.idle` genuinely unreachable from `emptyState` rather
than merely re-commented as such.

**A Cancel mid-mint can leave notes stamped with a run id the diagnostics store
never records, and that is honest rather than a bug** (M4 P1 Task 3). `finish`
awaits `mintAnnotations` before checking `runGeneration == generation`
(`CompilerOrchestrator`'s own doc comment on `finish` names the ordering); a
Cancel arriving inside that await bumps the generation and returns early,
so `Self.record(...)`/`diagnostics?.replace(...)` never run for this `runId` —
the sidecar simply has no `CompilerRun` by that id. The op-log appends
`mintAnnotations` already made are not rolled back (the mint cannot throw and
was never asked to be transactional — spec §3.2 calls the compiler a
background convenience, not a source of truth to keep consistent at the cost
of the writer's words), so a handful of annotations can carry a
`compilerRunId` the pane can never look up. The dedupe backstop is unaffected
either way — it keys on `compilerFingerprint`, not on whether the run that
minted a note is still resolvable — and the writer sees the notes in their
queue regardless of which side of the race the cancel landed on. Nothing
reads a minted annotation's `compilerRunId` back against the sidecar today, so
the gap is inert; it is recorded here because the type cannot defend itself
and a future reader that DOES join the two should know the join can miss.

## The cold-start offer — refusable once, per document, forever

Built Stage 3. Spec §4's "one refusable offer... never re-asked as a nag" for
a document this build has never run. Almost all of it is `DiagnosticsPane`'s
(the pure decision `showsColdStartOffer(state:liveParagraphCount:hasRefused:)`
and the two-button view) and therefore across the seam like the rest of the
pane — this area's only piece is the memory the "Not now" side writes into.

`DiagnosticsStore.refuseColdStart`/`hasRefusedColdStart` are a fourth,
deliberately different sidecar shape: every other record in this store is
keyed by `docId` and requires a `CompilerRun` to exist first (`FileContent`'s
`run` field is non-optional), but a refusal can happen before a document has
ever been checked at all — before `FileContent` for it exists. Rather than
fabricate a run to hang a boolean off, the refusal set lives in its own tiny
per-device file, `.maugham/diagnostics/cold-start-refused.<slug>.json`, on the
same derived-state contract as everything else here: a missing or corrupt
file reads as empty, and losing it costs nothing worse than the offer asking
once more. **Reading is not a new run kind** — the offer's `Read` button
calls `CompilerOrchestrator.runRequested` exactly as ⌘R does, which already
treats a document with no marker as "everything is new"; nothing in this area
special-cases a first run reached through the offer versus the keystroke.

## Tests worth knowing about

**Count the tests, not this file.** The list below says what each suite is
*for*; the suites themselves are the specification, and a claim here that has
drifted from them is a defect in this file.

- `CompilerAllowlistTests` — the membrane census and its planted offenders.
- `DeltaBuilderTests` — what "changed since the marker" means, in the writer's
  order.
- `CompilerPromptTests` — the section schema's fixed order and register
  enforcement (no severity, no suggestion field), the v2 briefing (essay +
  derived world + bible facts diffed in as one unit), and the session
  preamble.
- `ClaudeCLISessionTests` — the process, its arguments, and every path it has to
  die on.
- `DiagnosticIngestTests` — live anchoring, a bad note never failing a run, and
  the `intent_drift` verdict: its two recognised words, an unrecognised one
  reading as none, a four-section answer still ingesting whole, the fold
  keeping the latest non-nil, and the model's sentence reaching nothing the
  writer reads.
- `DiagnosticsStoreTests` — the sidecar, the staleness rule, the marker.
- `DiagnosticsPaneTests` / `DiagnosticPromoteToTaskTests` — the pane's states
  and the promotion, pressed through the real accessibility tree.
- `RulingPerformerTests` — the verbs, their four refusals that must write
  nothing, the one-op edit, the derivation invalidation, and the membrane census
  with its planted offender.
- `StatementPaneStrataTests` — the essay/rulings split (including the identity
  property `render` cannot promise), the ruling that lands mid-edit, the rows'
  two verbs and their one ⌘Z each, the bible's three actions, and the census
  that no derivation is ever drawn.
- `DeclaredWorldStoreTests` — the hash-gated cache: a reading served only
  against the exact text it was made from, invalidation on write, the one
  `scopeKey` spelling, and the missing-or-corrupt-sidecar-reads-empty contract.
- `DeclaredWorldDeriverTests` — the one-shot subprocess: its stricter
  confinement than `ClaudeCLISession` (no `--mcp-config` at all, `--tools ""`),
  the prompt/parser wire-shape agreement, honest `nil` on every failure mode,
  and (Stage 3) the 120s deadline against a fixture that never answers and
  never exits on its own, with an injected short deadline so the test does
  not wait the real budget out. One live probe against the real CLI is
  recorded in the task-3 report, not run here.
- `BibleStoreTests` — the ledger: `(subject, fact)` dedupe (and that a
  dismissed fact can return), the per-device sidecar, and the subject-slice
  `facts(subjects:)` the run calls.
- `DiagnosticsPaneTests` — the report the pane draws (the conformance summary
  first, the excerpt chips, the legible wait) and the answer flow end to end,
  including that it lands as a ruling and drops the derivation it outdated;
  also the drift line above the summary — its register, that it names no
  count beyond "three runs", and that it is not a `Diagnostic`; and (Stage 3)
  the cold-start offer's pure decision (`showsColdStartOffer`) plus its
  refusal — the offer for a never-run, non-stub document, gone once refused,
  gone for good once any run happens.
- `LetterMarkdownTests` — the kept letter's prose: the heading's three facts,
  the parts in reading order with an empty part drawing no heading, the scene
  table (blank cells blank, the charge column only when the form has one, a
  pipe or newline that cannot break a row), and the negative that matters —
  no paragraph id in the output, asserted with the tripwire's own regex and
  controlled by a planted anchor.
- `LetterKeepTests` — where a kept letter lands, over a REAL `ProjectStore`:
  the router's two arms (a novel chapter's shared note plus a link, a loose
  collection piece's own folder), the body on disk equalling the render, the
  run's own letter untouched (Keep is a copy), a second Keep making a second
  note, the lane line's stage/coach/passless split, and an unwritable folder
  refusing the keep with nothing filed.
- `CompilerRunCommandTests` — ⌘R's real delivery path.
- `PinnedReferencesTests` — the projection, its sections and its resolution,
  including the dedup/dangling/order rules; its census keeps `linkedResearchIds` (not
  `StructureItem.links`) the only field a caller may name. `ReferencesPaneTests`
  and `AssistantColumnTests`, across the seam in `Maugham/Views/`, are the
  shelf's and the column's own suites, and pin that both surfaces and the run's
  `pinnedListing` share this one projection.

**One known gap, on the record:** SwiftUI exposes no way to deliver a Return
keystroke into a hosted `TextField`'s editor, so the reply field's *commit on
return* and *escape cancels* are asserted at the source rather than pressed
(`DiagnosticsPaneTests.test_theReplyFieldCommitsOnReturnAndCancelsOnEscape`).
Everything the commit then does is driven for real against live stores through
`DiagnosticsPane.commitAnswer`, which is why that function is a `static` taking
everything it touches.

## What's intentionally NOT here

- **The Author surfaces' views.** The intent strip above the prose
  (`IntentStrip.swift`) and the references shelf / assistant column
  (`ReferencesPane.swift`, `AssistantColumn.swift`, spec §6) shipped in Plan 2
  — but they live in `Maugham/Views/`, not here, on the same principle as the
  pane: this directory holds no view state. What lives here is what feeds them
  — `PinnedReferences`/`PinnedReferenceResolver` — and the run's own
  `Environment.pinnedListing`/`paletteListing` closures
  (`CompilerOrchestrator.runRequested`, wired to `runMessageV2`'s
  `pinnedListing`/`paletteListing` parameters) read the identical projection.
  Both still ship empty-capable, but the reason changed: the
  prompt omits an empty section by design, and today a document with nothing
  linked or clustered is the only thing that produces one — not an unbuilt
  surface.
- **An Author posture object.** Spec §6.3's finding: answering a diagnostic
  changes nothing structural — the editor stays the editor — so a policy object
  with nothing to produce would be ceremony. **Built as designed, 2026-08-05**:
  Plan 2 shipped Author with none, and nothing since has argued otherwise.
- **A new MCP tool, in either direction.** The compiler is an MCP *client*. The
  catalogue did not move for M2.

## From CLAUDE.md's area table (2026-10-17)

- Notes are anchored at ingest against the **live** paragraph, never against text the model echoed back, which is what makes the exact-match staleness rule right and the mid-run edit a non-case.
- **The assistant column studies in Review too, as of M3-P3** (`Persona.studiesPinnedReferences`) — Plan and Publish keep the inert shelf.
- **The depth menu has a fourth rung**, `CompilerModelChoice.exhaustive` (`fable`), last in the enum and last in the menu — count `allCases`, not this line.

## CompilerOrchestrator.swift's comments, as they stood at 1810a794

Moved out of `Maugham/Compiler/CompilerOrchestrator.swift` on 2026-10-29 by #116 F12, when its comments were cut to contracts (1,999 lines to about 1,050; no code changed). Every comment in the file at `1810a794` is below, word for word, grouped by the type or function it documented and labelled with the code line it sat above; only the `///`/`//` markers were stripped. The code is the current truth, and a `// History:` line in it points at the matching subsection here. Claims tied to a moment (task numbers, review rounds, "used to", "nothing reads it yet") describe the code as it stood then.

### Orchestrator class and its small types

**Above `@Observable @MainActor`:**

> **The run.** One keystroke arrives here, and everything Tasks 1–6 built is
> called in order: the delta against the last-run marker, the prompt, the warm
> session, the parse, the store.
>
> Owned by `ProjectWindow` — the `CanvasModel` pattern — because the pane that
> shows the notes lives in the right-hand column and must read the same run
> state the centre column's keystroke started. One orchestrator per window;
> one session per orchestrator.
>
> **It reads the editor and never writes to it.** What a run needs off the
> live `Document` arrives as a `DocumentReading` value captured at the
> keystroke, and the ingest reads paragraph text back through a closure.
> Nothing here holds an editor binding or a `Document` (tripwires 3, 6).

**Above `struct DeltaCounts: Equatable, Sendable {`:**

> **What a run is reading, in counts** — the running state's payload, and
> the whole of requirement 5 on this side of the seam.
>
> A cold first run over a long delta takes about two minutes, and a bare
> "Checking…" for that long reads as a hung app. The delta is known before
> the send (`beginRun` builds it, then sets the state, then spawns), so the
> header can say what is being read without waiting for anything — the
> counts travel with the state rather than being fetched from the
> orchestrator by a pane that would have no way to know when they arrived.
>
> Counts rather than the sentence: the copy is the pane's
> (`RoundNarrative.checkingCopy`), the way every other line it says is.

**Above `struct DocumentReading: Equatable {`:**

> What one run reads off the live `Document`, captured at the keystroke.
>
> A value rather than the `Document` itself: the run is asynchronous, and
> holding the editor's own state across a subprocess turn is the shape
> tripwires 3 and 6 exist about. `sequence` is authoritative for order.

**Above `struct IntentBriefing: Equatable, Sendable {`:**

> What a run is checked against, resolved at the keystroke.
>
> **The statement WHOLE, and the key its reading is cached under.** Two
> fields because the two halves are read by different things and must not
> be re-derived apart: the derivation reads all of it (the rulings are
> half of what there is to derive), the briefing embeds only its essay,
> and the cache is keyed by the scope — spelled by `DeclaredWorldStore`
> itself rather than rebuilt here, because two spellings are two caches
> and one of them is never hit.

### Orchestrator RunState

**Above `enum RunState: Equatable {`:**

> What the surface says about the last thing the run key did.
>
> `nothingNew` is an idle state, not a failure: the key worked, the delta
> was empty, and there is nothing to report. It is separate from `idle` so
> the pane can say which of the two it is — a writer who presses ⌘R and
> sees the previous run's notes unchanged has no way to tell "checked,
> nothing new" from "the key did nothing".
>
> **Every state that describes a run names the document it ran on.** The
> surface is per-document and this state is per-window, so a case without
> a `docId` is a claim with nowhere to check it against: ⌘R on chapter 1
> reports "nothing new", the writer clicks chapter 2, and chapter 2's
> header says the compiler found nothing new in a document it never read —
> indefinitely, since the state only moves on the next run. A failure is
> the same defect with a red line painted over another document's
> perfectly good notes. `.idle` carries none because it claims nothing.
>
> **And every one names which LOOP's run it was** (#77 F7). One session
> per window serves both loops, so this one state is read by Author's
> Diagnostics header and by Review's round cockpit; without the kind, ⌘R
> in Author made the cockpit read "running" with a check's counts, and a
> check's death painted the cockpit red as a round failure (and the
> reverse). Each surface now matches its own kind and names the other's
> in one line, and its own kind's run on another piece by that piece's
> title (#83) (`DiagnosticsPane.otherLoopLine`,
> `ReviewRoundCockpit.otherLoopLine`).

### Orchestrator Acknowledgment

**Above `enum Acknowledgment: Equatable, Sendable {`:**

> **What the run key flashed about** — the capsule at the top of the
> window, `SaveFlashOverlay`'s ⌘S register borrowed by ⌘R.
>
> Two cases because a press that starts a run and a press that finds one
> already in flight are different promises, and the difference is the
> whole reason the second one may flash at all (see `runRequested`).
> A typed pair rather than a `String` label handed across the seam:
> adding a third acknowledgment is adding a case, and every emit site is
> then the compiler's problem rather than a reviewer's.

**Above `case started`:**

> A run just started on this document.

**Above `case alreadyChecking`:**

> One was already running, and this press started nothing.

**Above `case freshEyes`:**

> A **cold** run just started on this document (⌘⇧R): the warm
> session retired, the piece read whole. Its own case because the two
> presses promise different things — a delta comes back in seconds
> and a whole piece in minutes — and "Checking…" over the second is
> the wrong promise, not merely a duller one.

**Above `case pieceWouldNotOpen`:**

> A round asked for from the review board never started, because the
> piece its chip names did not open inside `RunWhenDocumentOpens`'
> bound. Denver's 2026-08-18 ruling: the drop used to be a log line
> and nothing else, so a chip press produced no round, no error and
> no word — indistinguishable from a control that does nothing. The
> only acknowledgment here that reports a FAILURE rather than a
> start, which is why it says what to do next.

**Above `case noEditor`:**

> A round was asked for on a piece with no STAGE — unassigned, or
> parked in a pass the writer has since retired. The seat does not
> enter into it: the coach reads checks, and a round with no lane is
> a numbered entry in nothing (`RoundEditor`). The second
> acknowledgment that reports a FAILURE rather than a start, and it
> says what to do next for the same reason `pieceWouldNotOpen` does.

**Above `case notYourPiece`:**

> **A round asked for on a piece this Mac may not write** (P3c Task 6,
> plan ruling R4). A round moves the piece's lane and stamps a pass —
> writes a reviewer's posture does not offer — so it is refused
> before anything starts, in the `noEditor` refusal's exact shape.
> Never asked of a check: Author's ⌘R writes unstamped notes, which is
> the reviewer row and every rung's. Nor is it a fallback to another
> reader — the press simply does nothing but say why.

**Above `var flashLabel: String {`:**

> The capsule's word. Kept beside the case rather than in the window
> that draws it, so all five sentences are assertable without a
> mount — and so the difference between them cannot be lost in a
> view's `switch`.

### Orchestrator ActivePass

**Above `struct ActivePass: Equatable, Sendable {`:**

> **The review pass a run belongs to, resolved ONCE** — at the keystroke,
> in `beginRun`'s synchronous prefix, beside the round number it is minted
> with (M4 P1 Task 3).
>
> Three things travel together because they are three readings of one
> answer and a second resolution site is how they come to disagree: the
> lane a round is filed in, the editor whose name its notes are written
> under, and the doctrine the round is briefed on. `ReviewPass`'s own
> `effectiveEditorName`/`effectiveBrief` are the one resolution spelling
> (preset-by-id fallback); nothing downstream re-derives either.
>
> `nil` — no `ActivePass` at all — is the passless lane: an ordinary M2
> ⌘R, which mints no round number, stamps no pass on what it writes, and
> signs its notes "Claude".

**Above `let name: String`:**

> `ReviewPass.name` — the pass as the writer named it, which is the
> second half of the briefing's role frame ("this manuscript's
> Copyedit editor") and the whole content of the fallback when the
> pass has no brief. Carried with the rest for `editorName`'s reason:
> a rename between the keystroke and the send would otherwise frame
> the round as a pass the round is not.

**Above `let editorName: String`:**

> `ReviewPass.effectiveEditorName` — never nil, because every pass has
> a name to fall back to.

**Above `let brief: String?`:**

> `ReviewPass.effectiveBrief`. **Threaded in Task 3 and read in Task
> 4**: the briefing is the next task's, and resolving it in a second
> place then would be the drift this type exists to prevent.

**Above `init(id: String, name: String, editorName: String, brief: String?) {`:**

> **There is no `isCoach` here any more** (two loops P2 Task 4). The
> seat was carried on this type while one closure answered both
> loops and the coach had to arrive dressed as a pass; a CHECK is now
> read by an `AuthorReader`, whose `.coach` arm is a case rather than
> a flag, and `CompilerPrompt.readerSection` frames her as a teacher
> where `passSection` frames a stage as an editor. So this type is
> Review's alone: every value of it is a rung of the ladder, and
> `TripwireGrepTests.test_isCoachIsGone` fails if the flag comes back
> anywhere under `Maugham/`.

### Orchestrator MintOutcome

**Above `struct MintOutcome: Equatable, Sendable {`:**

> What one round's mint actually did — beside `Environment.mintAnnotations`
> below, because it is that closure's answer and nothing else's.
>
> **Two numbers rather than one, because the dedupe has two outcomes and
> only one of them used to be reportable** (#42 F-H). A finding the mint
> refused is not nothing happening: it is a finding the writer is already
> holding. When they are holding it in the lane the round was run in, the
> since-line already accounts for it as *persisting*. When they are
> holding it in ANOTHER pass's lane, every count on that line is zero and
> the report used to say so over a round that engaged the question.

**Above `let minted: Int`:**

> Notes really appended to the document — after the dedupe dropped
> what was already open, and after any that could not be placed
> failed their own append.

**Above `let openInOtherLanes: Int`:**

> Distinct findings this round raised that the dedupe refused and
> **no lane holding them is this round's own** — own-lane presence
> wins, because one fingerprint can be held by two open notes at once
> (`CompilerEnvironment+Project`'s mint loop spells the shape). A
> finding standing in the round's own lane is the *persisting* case,
> already on the since-line, and counting it here as well would tell
> the writer one finding is two.
>
> Per FINDING, not per matched note: two notes holding one fingerprint
> are one thing the writer is holding elsewhere.

**Above `var openInOtherLanesNoteIds: [String] = []`:**

> **The notes behind that count** (#53): every open note in another
> lane holding one of those findings, by id. Recorded so the clause
> can be filtered live at render (`RoundNarrative.openElsewhere`)
> rather than stand as a snapshot. Defaulted so a double that only
> answers the counts still builds.

**Above `static let nothing = MintOutcome(minted: 0, openInOtherLanes: 0)`:**

> A mint that did not happen: no document to write to, or no note
> worth writing.
>
> **Zero, and indistinguishable on the wire from a run that minted
> nothing** — `finish` records whatever it gets, so both store `0`.
> The `nil` that `CompilerRun.mintedNotes`/`openInOtherLanes` document
> comes from the PREVIEW path alone (and from records written before
> those fields existed); it is never this value.

### Orchestrator Environment

**Above `struct Environment {`:**

> Everything the orchestrator needs from the window it belongs to. Closures
> rather than stores, so a test drives a run without a project on disk and
> so `detach()` can drop the window's whole object graph in one line.
> Every closure is `@MainActor`: the stores they read are, the run itself
> is, and an isolation hop between the keystroke and the delta would let
> the writer type in the gap.

**Above `var model: String`:**

> The model each run is spawned against.

**Above `var prepareForRun: @MainActor (String) async -> Void`:**

> **Bring the document up to date before `reading` is asked.** Awaited
> at the top of every run: freshly typed prose lives in the
> `PendingBuffer` until a pause closes the burst, so a snapshot taken
> at the keystroke omits the very sentences the writer pressed ⌘R
> about. Production closes the burst here.
>
> Not throwing, deliberately. Whatever it could not do, the run still
> happens on the snapshot as it stands — the words themselves are the
> op log's problem, not the compiler's, and a stale delta checks real
> prose where a refused run checks none.

**Above `var reading: @MainActor (String) -> DocumentReading?`:**

> The live document for a docId, or `nil` when the window's subject is
> not a manuscript document. Read AFTER `prepareForRun`.

**Above `var liveParagraphText: @MainActor (String, String) -> String?`:**

> `(docId, paragraphId)` → the paragraph's text **now**. Read at
> ingest, which is what makes `DiagnosticsStore.live`'s exact-match
> staleness rule correct.

**Above `var intent: @MainActor (String) -> IntentBriefing?`:**

> The intent this document answers to, piece-first. `nil` is a valid
> answer and mints nothing (M1A's rule): the run proceeds with nothing
> declared, and the conformance section simply has nothing to check.

**Above `var lessons: @MainActor () -> String? = { nil }`:**

> **The lessons ledger, whole** (`Statement.Kind.lessons`, editorial
> letter P2 Task 4) — the writer's own record of what they are
> working on, what they have settled, and what they have retired.
> `nil` is a project with no ledger, which is every project until the
> writer keeps their first lesson; the briefing simply carries none.
>
> **It takes nothing, and it is the one closure here that does.** The
> ledger has project scope by construction — `StatementConvention`
> answers no path for a document-scoped one — so a docId parameter
> would be an argument this closure could only ignore, and a seam
> suggesting a per-piece ledger that cannot exist.
>
> Defaulted to nothing, on `roundEditor`/`projectType`'s rule, so
> every `Environment` built before the ledger existed still compiles
> and still runs.

**Above `var authorReader: @MainActor (String) -> AuthorReader = { _ in .nobody }`:**

> **Who reads a CHECK** — asked once per run at the keystroke (two
> loops P2 Task 4).
>
> **Two closures rather than one taking the kind**, and that is the
> whole of this milestone's shape. The two loops have two resolutions
> with two ANSWER TYPES: a check is read by an `AuthorReader` — the
> coach, the writer's own first reader, or nobody — and a round by a
> stage's `ActivePass`. While one closure answered both, the first
> reader had to be squeezed through a pass-shaped seam that could
> only describe her as nobody; now a verb asking the other loop's
> question does not type-check.
>
> Never nil: an unread piece is `.nobody`, which is M2's
> all-altitudes ⌘R — no frame in the briefing, no lane, notes signed
> "Claude".
>
> **It reads no review-board memory.** What lane a chapter is parked
> in is a fact about the ROUND loop, and a check that read it signed
> Author's notes with an editor the writer never chose
> (`AuthorReader`'s own doc, and `TripwireGrepTests`' census).
>
> Defaulted so that every `Environment` built before the roster
> existed still compiles: the answer it gives is the passless lane,
> which is exactly what those runs were.

**Above `var roundEditor: @MainActor (String) -> ActivePass? = { _ in nil }`:**

> **Who reads a ROUND** — the stage the writer put this piece in,
> asked once per run at the keystroke (two loops P1 Task 2).
>
> Already validated against the project's live pass list: a lane is a
> pass that exists, and a run filed against a retired id would be a
> round nothing can ever compare.
>
> `nil` is a REFUSAL rather than a fallback — `runRequested` flashes
> `.noEditor` and starts nothing. The coach is not a substitute: she
> reads checks, and filing her a round is how an unassigned piece
> came to have a lane at all.
>
> **It answers with the whole pass, not its id** (M4 P1 Task 3): the
> lane, the editor's name and the brief are resolved together here and
> nowhere else, so the round's filing, the notes' authorship and the
> briefing cannot describe different passes.

**Above `var mayRunRound: @MainActor (String) async -> Bool? = { _ in true }`:**

> **May this Mac run a ROUND on this piece?** (P3c Task 6, plan
> ruling R4) — asked once per round press, after `roundEditor` and
> before anything starts; `false` flashes `.notYourPiece` and the
> press does nothing else; `nil` — no window's door behind the run
> any more (the window closed while the press was in flight) —
> starts nothing and SAYS nothing, because *not your piece* would be
> the wrong sentence (whole-branch fix wave, Minor 3). **Never asked
> of a check.**
>
> **Async on purpose, because it is an ACTING door** (controller
> ruling I): production answers it with `DocumentStore
> .settledPosture(forDocId:)`, which waits out a trust refresh in
> flight. A synchronous closure could only be answered by the
> DRAWING door, whose answer in the frames after a demotion is the
> last one it gave — a round would start on a piece this Mac had
> just stopped being allowed to write.
>
> Defaulted to yes, on `roundEditor`'s rule, so every `Environment`
> built before the permit reached this loop still compiles and still
> runs; the production wiring (`CompilerEnvironment+Project`) always
> supplies it, and `PostureSurfaceTests` pins that it does.

**Above `var projectType: @MainActor (String) -> ProjectType? = { _ in nil }`:**

> **The project's own type**, for the letter's scene position (spec
> §3.4, editorial letter P1 Task 3). A screenplay moves by scenes in
> the strong sense by its form; everything else reads as prose until
> the writer's own intent says otherwise.
>
> Keyed by docId like every other closure here even though the answer
> is project-wide: the caller has a document in hand, and a
> project-wide signature would be the one closure on this type that
> takes nothing, which is a seam a Collection's per-piece answer would
> later have to break.
>
> Defaulted to `nil` — read as prose — so every `Environment` built
> before the scene position existed still compiles and still runs.
> Those runs get the weak form, which is what a run with nothing
> declared about form should get.

**Above `var cachedWorld: @MainActor (IntentBriefing) -> DerivedWorld?`:**

> The reading already held for this statement's EXACT text, or `nil`
> for a miss. Pure — it never derives and never spawns, which is what
> lets the run tell a hit from a miss before deciding to spend a
> subprocess.

**Above `var deriveWorld: @MainActor (IntentBriefing, String) async -> Derived...`:**

> Derive a reading of this statement and cache it, on the model given
> — passed rather than captured, for `makeRunner`'s reason: `model`
> above is the one place it is decided.
>
> **The lazy trigger's other half** (`AREA.md`, "the derivation
> trigger"): called only on a miss, only from here, and never on a
> timer. `nil` is honest and non-fatal — a missing CLI, the toggle
> off, unreadable output — and costs the run its clauses, not the run.

**Above `var bibleSlice: @MainActor (String) -> [BibleFact]`:**

> What the ledger already believes about the subjects this delta's
> prose names (spec §5: "a run about Kelly's scene carries Kelly's
> facts, not the ledger"). The matching rule lives at the production
> call site, which is the only thing that knows the ledger.

**Above `var annotationContext: @MainActor (String) -> [CompilerAnnotationDisp...`:**

> **What the annotation layer already holds about this piece** (M4 P1
> Task 4) — the compiler-authored notes on it and what the writer has
> done about each, as the briefing's dispositions section.
>
> Asked once, in `beginRun`'s synchronous prefix, for
> `previousRound`'s reason: this is the last instant at which the
> answer describes the round that is starting rather than the round
> that is under way. A value rather than the `Document` — nothing here
> holds one across a subprocess turn (tripwires 3, 6).
>
> Its counterpart below writes what this run adds. The two are the
> same layer read and written a turn apart, which is what makes the
> dispositions briefing the warm path's duplicate guard and
> `mintAnnotations`' own dedupe the cold one.
>
> Defaulted to nothing so every `Environment` built before the
> briefing existed still compiles and still runs — those runs simply
> brief no dispositions, which is what they did.

**Above `var mintAnnotations: @MainActor ([CompilerNote], CompilerMintContext)...`:**

> **Where a continuity question and a reader's report actually go**
> (M4 P1 Task 3) — the annotation layer, not the sidecar.
>
> Called once per finished run, after `replace`, with everything the
> run raised that is not a conformance strain. Answers how many notes
> it really minted, which is not the count it was handed: the dedupe
> backstop drops a finding already open on the document, and a note
> whose paragraph the writer deleted between parse and mint fails its
> own append — and, beside it, how many of those refusals were
> findings open in ANOTHER pass's lane (`MintOutcome`, #42 F-H).
>
> **It cannot fail the run**, and its signature says so: no `throws`,
> a plain value rather than a result. The compiler is a background
> convenience (spec §3.2) and a note that could not be written is not
> a reason to tell the writer their check failed.
>
> Defaulted to a no-op returning `.nothing` so every `Environment`
> built before the mint existed still compiles and still runs — those
> runs simply write no annotations, which is what they did.

**Above `var recordFacts: @MainActor ([BibleFact]) -> Void`:**

> What this run established, on its way into the bible. Never a note:
> a fact-candidate lands silently and surfaces in the Intent pane's
> bible stratum, where the writer's three actions reach it.

**Above `var pinnedListing: @MainActor (String) -> [String]`:**

> What the writer pinned beside this document — linked research
> unioned with the canvas cluster (`PinnedReferences`, §7.2) — as
> "title (id) — tool" lines, grouped exactly as the `PinnedShelf`
> arranges them: a `## <title>` line ahead of each titled section,
> no header over an untitled one (`pinnedListingLines`). Empty is a
> valid answer (nothing pinned, or the Plan side never opened);
> `CompilerPrompt` omits the whole section rather than showing
> nothing.

**Above `var paletteListing: @MainActor () -> [String]`:**

> Every card in the project's palette, "title (id)" — independent
> of the document, because the palette is project-wide vocabulary
> rather than something pinned per-piece.

**Above `var writeMCPConfig: @MainActor () throws -> URL`:**

> Writes the per-session `--mcp-config` file and returns its path. The
> orchestrator owns the file's life from here (see `ensureRunner`).

**Above `var makeRunner: @MainActor (URL, String) -> CompilerRunner`:**

> `(configPath, model)` → the session. The model is passed rather than
> captured so `model` above is the only place it is decided; a second
> spelling inside this closure is what the run record and the
> subprocess would disagree about.

**Above `var onRunAcknowledged: @MainActor (Acknowledgment) -> Void`:**

> The acknowledgment flash. Called synchronously with the keystroke —
> for the press that starts a run AND for the one that finds a run
> already in flight, which say different things (`Acknowledgment`).

### Orchestrator defaultModel

**Above `nonisolated static let defaultModel = "sonnet"`:**

> The model a run uses before the Diagnostics pane's gear-menu setting
> has ever been read — a fresh project, or a `UIState` written before
> `compilerModel` existed. Sonnet is the spec's default (§3.5).
>
> `nonisolated` because `Environment.production` uses it as a **default
> argument**, which is evaluated in the caller's context rather than this
> type's: main-actor isolation on a constant string bought nothing and was
> a Swift 6 error waiting at that call site. The diagnostic had been there
> since the gear menu landed and was invisible in every warm build that
> did not recompile that file (docs/testing/TROUBLESHOOTING.md, "A warning
> census reads clean on an incremental build", met in the wild).

**Above `nonisolated static let passlessEditorName = "Claude"`:**

> Who signs a passless run's notes (M4 P1 Task 3). "Claude" is M2's own
> identity and the label `AnnotationAuthorPresentation` already gives an
> author-less note, so a ⌘R outside every pass writes into the filter
> bucket the writer already has rather than opening a new one.

### Orchestrator stored state

**Above `private(set) var runStartedAt: Date?`:**

> **When the run in flight was sent, and what the CLI has thought so
> far** — the two facts the panes draw while "Checking…" is on
> screen (spec 2026-09-09 §5). Both `nil` between runs, which is
> what makes "is a run live" answerable from either of them.
>
> `runProgress` is a preview on the partial text's terms: it belongs to
> the turn that reported it and nothing may be concluded from it that
> outlives that turn, which is why it is cleared everywhere the run ends
> rather than left standing as the last thing known.

**Above `private var runnerModel: String?`:**

> The model `runner` was **spawned** against. Kept beside the session
> because `--model` is a spawn argument (`ClaudeCLISession.arguments`) —
> a warm process cannot be retuned, so this is what `ensureRunner` compares
> the current setting to.

**Above `private var sentBriefing: [String: (hash: String, epoch: Int)] = [:]`:**

> Per document: the briefing hash the last successful run sent, and the
> session epoch it was sent into. Both halves matter — see `previousHash`.
>
> The hash covers essay + derived world + bible slice as one unit
> (`CompilerPrompt.runMessageV2`), widened from v1's intent-only hash: a
> briefing that came apart — the essay elided while the facts re-embedded
> — would describe a world the session was never told half of.

**Above `private var isPreparingRun = false`:**

> True between the keystroke and the delta, while `prepareForRun` closes
> the writer's burst. `isRunning` counts it, so the second ⌘R of a
> double-press is refused there exactly as it is mid-turn — the window is
> short, but two runs on one document are two sessions' worth of work and
> one of them would be reading a delta the other has already claimed.

**Above `private var runGeneration = 0`:**

> The generation a run's suspensions belong to. A teardown between the
> keystroke and the send **abandons** the run rather than letting it spawn
> a session the writer has just switched off; a boolean cleared and re-set
> by the next keystroke could not tell the two apart. Same reasoning as
> `ClaudeCLISession.generation` (AREA.md, "generations, not booleans").
>
> **Two hops carry it, not one.** The burst flush was the first; the
> declared world's derivation is the second, and it is the longer of the
> two by orders of magnitude — a whole `claude -p` process. A run that
> checked its generation before deriving and not after would spawn the
> session a toggle-off was there to prevent, seconds later.

### Orchestrator StreamingRun

**Above `private struct StreamingRun {`:**

> **The turn as it arrives**, or `nil` between runs.
>
> Everything a preview needs to build a `CompilerRun` before the turn has
> produced one, plus the two things the stream itself accumulates. The
> record fields are read at the keystroke and carried rather than
> re-derived at the end, so the run the pane shows mid-check and the run
> it shows afterwards cannot describe the same check differently.

**Above `let readerName: String?`:**

> **Who read this CHECK, by name** — minted at the keystroke
> (`beginRun`) and carried so the preview cannot describe a different
> reader from the answer that supersedes it. The writer can vacate
> the seat, or name a first reader, while the run is in flight, and
> the run was read by whoever held it when they pressed.
>
> `nil` for a round, whose byline is its lane's — the same rule
> `CompilerRun.readerName` states, because this is the value that
> becomes it.

**Above `let passId: String?`:**

> **The LANE, which is not the reader's name** (two loops P1 Task 2).
> A check has a reader — who signs what it writes — and no lane at
> all, so this is `nil` for every check and the name beside it is
> not.

**Above `let scenePosition: ScenePosition`:**

> **The letter's scene position, derived at the keystroke and
> carried** (spec §3.4). Carried for the lane's own reason: the
> writer can switch passes — and edit their intent — while the check
> runs, and the run was briefed on the position it started in. The
> preview stamps it on the letter and so does `finish`, so a preview
> and the answer that supersedes it can never disagree about what
> form the model was told this piece takes.

**Above `let stage: DraftStage?`:**

> **The draft stage this run's delta reads as, derived at the
> keystroke and carried** (spec §3.8). Carried on the scene
> position's own terms — the writer keeps typing while the check
> runs, and the stage is a fact about the delta the run was READ on,
> not about the document by the time the answer lands. The preview
> stamps it and so does `finish`, so the two cannot disagree about
> what the model was asked for.
>
> **`nil` for a round** (two loops P1 Task 4): the stage is derived
> for a check alone, so a round has none to carry rather than one it
> carries and never uses.

**Above `let dosage: LetterDosage`:**

> **How much letter that stage earned** (global constraint 24), the
> same value the briefing stated, carried so ingest can enforce it.
> Derived rather than re-asked at `finish`: `dosage(freshEyes:)`
> takes the run's own fresh-eyes flag, and a second derivation is a
> second place the ask and the enforcement could drift apart.

**Above `let ask: String?`:**

> **What the writer asked of this run, read at the keystroke and
> carried** (P2 Task 3). Carried for the lane's and the position's
> reason, plus one of its own: the field is expected to be cleared
> or rewritten the moment the check ends — a writer asks, reads the
> answer, asks something else — so the run must stamp what it was
> actually briefed on rather than whatever the field says by then.

**Above `let freshEyes: Bool`:**

> Whether this round was read cold (⌘⇧R) — carried for the same
> reason the lane is: the preview and the answer must describe one
> round, and the pane draws its header off this stamp.

**Above `let kind: RunKind`:**

> **Which loop asked for this run**, minted from the persona at the
> keystroke and carried for the lane's own reason: the writer can
> switch personas while the check runs, and the run belongs to the
> loop that started it. The preview stamps it and so does `finish`,
> so the two cannot disagree about which verb this was.

**Above `var buffer = ""`:**

> Text delivered that has not closed a line yet. A chunk is cut by
> the transport, not by the contract — a section's JSON object
> routinely arrives in three pieces — so nothing is read until a
> newline says the line is whole.

**Above `var outcome = DiagnosticIngest.SectionedOutcome.empty`:**

> Every section that HAS closed, folded exactly the way `parseAll`
> folds a whole turn (`DiagnosticIngest.combining`).

**Above `var isShowing = false`:**

> Whether anything reached the pane, so a discard knows whether it
> has something to take back.

### Orchestrator wiring

**Above `func configure(environment: Environment, diagnostics: DiagnosticsStor...`:**

> Wire the orchestrator to its window. Called from `ProjectWindow.load()`,
> where the stores exist — never from a `body`.

**Above `func updateModel(_ model: String) {`:**

> Change the model runs are spawned against — the Diagnostics pane's gear
> menu (Task 8).
>
> **Setting this is not enough on its own, and that is why the retirement
> lives in `ensureRunner` rather than here.** The model is a spawn
> argument, so the warm session already running was built with the old one
> and will keep answering in it however many times the setting is changed.
> The stale session is retired lazily, at the next run, so choosing Deep
> mid-check never kills the check in flight — the writer gets the answer
> they are waiting for, and the run after it is the one that changes.

**Above `var configuredModel: String? { environment?.model }`:**

> The model the next spawn will use, or nil while unwired — the read
> `AgentRosterTests` asserts the depth-menu fan-out through.

### Orchestrator runRequested

**Above `func runRequested(docId: String, kind: RunKind, freshEyes: Bool = fal...`:**

> The run key. Builds the delta, assembles the prompt, sends it, ingests
> the answer — and refuses, quietly, in the two cases where the honest
> thing to do is nothing.
>
> **`freshEyes` is the same run read cold** (⌘⇧R, M3-P3 §6): the warm
> session is retired so the process that answers has read nothing, the
> marker is not consulted so the delta is the whole standing manuscript,
> and the round is briefed on no prior round. Everything else is
> identical — the pass and the round number are minted normally, the
> marker advances normally, and the run records what it was
> (`CompilerRun.freshEyes`), so the NEXT plain ⌘R is warm again and back
> on the marker.
>
> Defaulted `false` so the ordinary key and every caller predating it —
> the cold-start offer's Read button among them — say what they always
> said.
> - Parameter kind: **which loop asked** (two loops P1). Required and
>   undefaulted, on `record`'s rule: a default would let a call site
>   quietly file a round as a check, and nothing about the run would look
>   wrong. It is minted from the key window's persona in exactly one
>   place — `CompilerRunModifier`, the only site holding a persona — and
>   every other caller is a surface that belongs to one loop by
>   construction and says so literally. **Nothing reads it yet**: P1 Task
>   1 carries and stamps it, and the two verbs part company in Task 2.

**Above `guard !isRunning else {`:**

> A run already in flight. Nothing is queued — there is one session per
> window, and a second turn is something the next keystroke can do —
> but the press is answered.
>
> **This is M2 Task 7's judgment revisited, and the copy is what
> answers it.** That task refused to flash here on the grounds that
> ⌘S's capsule promises work was done, so flashing over a run already
> under way would be the key claiming something it did not do. The
> promise lives in the wording, not the capsule: "Still checking…"
> claims nothing started. What the silence cost is requirement 4b — a
> cold run takes ~2 minutes, and a writer whose second press produced
> no reaction at all cannot tell a busy compiler from a dead keystroke.

**Above `guard environment.reading(docId) != nil else { return }`:**

> No document under the window's subject — the project row, or nothing
> selected. Not an error, not a run, and nothing to acknowledge: the
> key had nothing to act on. Asked here only for that answer; the
> reading the delta is built from is taken below, after the burst.

**Above `if kind == .round, environment.roundEditor(docId) == nil {`:**

> **A round needs an editor, and there is no substitute for one** (two
> loops P1 Task 2). A round is a numbered entry in a named lane; with
> no stage on this piece there is no lane, so there is nothing to
> number and nothing a later round could be measured against. The
> coach is not a fallback here — she reads checks (`AuthorReader`),
> and filing her a round is how an unassigned piece came to have a
> lane at all.
>
> **Above the flash, so the refusal is the ONLY thing the press
> does.** Nothing is spawned, no marker moves, no `runState` changes:
> the writer gets one sentence telling them what to set, and the
> window is exactly as they left it. It sits below the `isRunning`
> guard on purpose — a press arriving mid-run is still "still
> checking", whatever the piece's lane says.

**Above `if kind == .round {`:**

> **A round is the piece-writer's, and the permit says whose that is**
> (P3c Task 6, plan ruling R4). Asked of the SETTLED posture, which is
> asynchronous — so the round holds the in-flight gate while it asks
> (a second press meanwhile is "still checking", never a second run)
> and the flash waits for the answer: a refusal is still the ONLY
> thing the press does — no `.started`, no session, no marker, no
> `runState` change. A check never reaches this: it is anyone's.

**Above `guard let self, self.runGeneration == generation,`:**

> Re-asked after the hop, as the burst's hop below re-asks: a
> window that closed, or a cancel, while the answer was on its
> way takes the press with it.

### Orchestrator acknowledgeAndPrepare

**Above `private func acknowledgeAndPrepare(`:**

> The press, past every refusal: the flash, then the burst, then the run.

**Above `environment.onRunAcknowledged(freshEyes ? .freshEyes : .started)`:**

> Synchronous with the keystroke, and deliberately ahead of the hop
> below: the flash is ⌘S's muscle-memory acknowledgment, not a progress
> indicator, and one that waited on a disk write would be neither.
> (A ROUND's flash waits for one thing only — the settled answer to
> whether this Mac may run it — because flashing "Checking…" and then
> "not your piece" would be the key claiming a start it never made.)
>
> **Below the refusals on purpose, both of them.** A fresh-eyes press
> that arrives mid-run must be answered "still checking" like any
> other, and must not have retired the session on its way past — the
> retirement lives in `beginRun`, downstream of everything here, so
> the turn the writer is waiting on cannot be killed by the keystroke
> that was refused.

**Above `runGeneration &+= 1`:**

> **The burst first, the delta second.** The writer's last sentences
> are in the `PendingBuffer` until a pause closes the burst, so a
> reading taken now is a document that predates the keystroke that
> asked about it — measured in the field as a 14-paragraph chunk
> reported as "0 new, 1 revised". The wet ink is what the compiler is
> for (spec §3.2). Nothing here touches the editor's binding: the
> document closes its own burst and we take a value afterwards
> (tripwires 3, 6).

**Above `guard let environment = self.environment,`:**

> Re-asked after the hop: the window can have closed, Claude can
> have been switched off, and the writer can have moved the
> selection off a document entirely while the burst was landing.

### Orchestrator beginRun

**Above `private func beginRun(`:**

> The run proper, from the delta on — everything that was `runRequested`'s
> body before the burst-flush hop moved in above it.

**Above `let roundPass: ActivePass? = kind == .round ? environment.roundEditor...`:**

> **The stage is re-read on this side of the hop, and a round that
> lost it is refused as `runRequested` refuses one** (#77 G1/F6). The
> writer can clear the piece's stage or retire its pass — or a synced
> manifest can — while the settled posture or the burst flush is on
> its way, and a round resolved to nobody here used to be filed as a
> passless "Claude" round. Above the empty-delta guard, so an empty
> piece with no editor is refused rather than `nothingNew`, and above
> every `runState`, marker and session write. `.started` has already
> flashed; a second flash saying what is missing is the honest answer.

**Above `let delta = DeltaBuilder.delta(`:**

> **A cold read does not consult the marker** (M3-P3 §6). `since: nil`
> is `DeltaBuilder`'s "everything is new", which is what makes ⌘⇧R
> over untouched prose a real read where ⌘R is honestly `nothingNew`.
> The marker is still READ above and still advances below — a fresh
> run leaves the document exactly as any run does, or the ⌘R after it
> would re-read the piece a second time.
>
> **And a ROUND does not consult it either — ever** (two loops P1 Task
> 4, spec §4.5). The marker is the CHECK's: it records what the writer
> has read of their own prose, and a round is somebody else's read of
> the piece entire. `since: nil` is the same "everything is new" a
> cold read gets, for a different reason — a round has no history of
> its own to diff against, and what changed since the last round
> reaches it through the prior-round and dispositions sections rather
> than through a diff.

**Above `if kind == .check, let newest = delta.newestOpId {`:**

> Ops may still have landed that changed no prose. Passing them
> costs nothing and saves every later run from re-reading them.
>
> **The CHECK's alone** (Task 4). A round is here only over a
> piece with nothing in it, and moving the marker for it would
> consume, on the round loop's behalf, ops the writer's own next
> ⌘R is owed — the check would open on a document whose opening
> paragraphs it has never read and nothing on screen would say so.

**Above `let reader: AuthorReader = kind == .check ? environment.authorReader(...`:**

> **Who reads this run, asked at the keystroke and for THIS verb**
> (two loops P2 Task 4). Two closures, because the two loops have two
> answers of two different types: a check is the roster's choice — the
> coach, the writer's own first reader, or nobody — and a round is the
> stage's lane. Each verb asks its own and never the other's, which is
> what the two types make impossible to get wrong.
>
> **Asked here, above the dose**, because a first reader's dose is
> hers rather than the draft stage's. Everything else it decides — the
> brief the scene position reads, the byline, the sections she is not
> given — is read further down, at the site that needs it.
>
> A round that reached here has an editor: `runRequested` refused the
> press without one, and the top of this method re-asked after the
> hop (`roundPass`, resolved there). `.nobody` on the round arm is the honest reading
> of "a round is read by no `AuthorReader` at all"; asking the roster
> for one would be the fusion this milestone split apart.

**Above `let signals = kind == .check`:**

> **Maugham's own observation of the writer's process, at the
> keystroke** (spec §5). Computed off `reading` and nothing else —
> `ProcessSignals` takes the ops, the sequence and a `now`, which is
> exactly what `DeltaBuilder` was already given a line above, so this
> needs no `Environment` closure of its own and cannot disagree with
> the delta about which instant of the document it describes.
>
> Below the empty-delta guard with the lane and the round, and for the
> same reason: a ⌘R with nothing new is not a round, and observing the
> writer's practice for a check that never happened would put numbers
> behind a letter nobody is going to read.
>
> `DeltaBuilder.ordered` therefore runs TWICE per ⌘R — once inside
> `DeltaBuilder.delta` above and once inside this initializer — and
> that is accepted rather than overlooked: it measured 1 ms, and the
> two readers are independent pure values over the same ops. Handing
> both a pre-sorted array would couple the delta's shape to the
> signals' and give a later change to one a way to move the other
> silently. Revisit only if it stops being 1 ms.
>
> **The CHECK's, both of its readers** (two loops P1 Task 4): the
> signals brief the check and the stage they feed doses it, and a
> round wants neither, so a round takes no reading at all rather than
> computing one nothing downstream would look at.

**Above `let stage: DraftStage? = kind == .check`:**

> **The stage is derived, never set** (global constraint 23, spec
> §3.8). Two inputs, both already in hand: what this delta is made of,
> and whether the frontier moved in the latest sitting. The writer is
> never asked, no manifest field records it, and the only persisted
> trace is the stamp `record` puts on the letter.
>
> **And it is derived for a CHECK alone** (spec §4.8). The stage says
> how far along the writer's own draft is; a round is always the full
> letter, because its pass brief is what decides which parts an editor
> writes. So a round derives none, states none and stamps none —
> `nil` here rather than a stage the dose below then has to ignore,
> which would leave two places to remember the rule.

**Above `let dosage: LetterDosage = reader.isFirstReader`:**

> **Stated in the briefing AND enforced at ingest** (global constraint
> 24) — derived once, here, so the two ends cannot ask for different
> amounts of letter. Fresh Eyes is always the full letter, which is why
> the flag is an argument rather than something `parseLetter` re-reads.
> No stage — a round — is `.full` for that rule's own reason: the dose
> is a stage's to shorten, and nothing else may.
>
> **A first reader's dose is hers, and it OUTRANKS both the stage and
> Fresh Eyes** (two loops P2, ruling P2-4). The stage shortens the
> letter an editor writes; the reader's form is a different letter
> altogether — answer, about, working, one question — and a drafting
> delta cannot make it shorter, nor a cold read make it longer. Fresh
> Eyes is the sharp case: it is "always the full letter" for the
> stage's rule, and applying that to her would hand back the craft
> letter she exists not to write.
>
> The stage is still derived above for her: it is two pure values over
> ops already in hand, and `Letter.stage` records it, so a first
> reader's letter still says which half of the draft it was written
> over even though nothing about the dose turns on it.

**Above `let briefedSignals = reader.isFirstReader ? nil : signals`:**

> **A first reader is briefed on no process line** (ruling P2-6).
> `ProcessSignals` is Maugham's observation of the WRITER — sessions
> since the frontier moved, a paragraph rewritten seven times — and a
> reader who reported it would be talking about the writing rather
> than about the reading, which is the one thing her whole section
> forbids. `LetterDosage.allowsProcess` refuses the line at ingest;
> this is the same rule at the other end, so she is never asked for
> something that would then be thrown away.
>
> The stage above still reads the signals: they are its input, and the
> stamp on her letter is honest whether or not she was told.

**Above `let briefedStage = reader.isFirstReader ? nil : stage`:**

> **And she is told no draft stage either** (ruling P2-4, fix round 1).
> `stageSection` states the CRAFT dose the stage earns — "write the
> full letter, every part your pass brief allows", "no exercise" —
> which contradicts `firstReaderInstruction`'s "the short reader form
> and nothing else" in the same message. The dose above already
> refuses hers to the stage; briefing it anyway would ask her for two
> different letters and let the model pick.
>
> **The RECORD still stamps it**: `Letter.stage` is a fact about the
> delta the run was read over, true whoever read it, and the pane
> draws it. This nils what the model is TOLD, not what the run knows —
> which is why it is a separate value from `stage` rather than a
> narrower derivation above.

**Above `let passId = roundPass?.id`:**

> **The lane and the round, minted HERE — at the keystroke, before a
> single byte of the answer can arrive** (M3-P3 §6).
>
> Two reasons it cannot wait for the record:
>
> - `latestRound` reads the store, and in production every run
>   streams, so from the first closed section onward the standing
>   content for this document is THIS run's own preview. A mint at
>   record time would read its own round back and file the answer as
>   the round after itself.
> - The writer can click another pass chip while the check runs. The
>   run was read for the lane it started in; a switch mid-check
>   belongs to the next ⌘R.
>
> So it is minted once, carried on `StreamingRun`, and threaded
> through the one `record(...)` spelling — the preview and the final
> answer describe one round or they describe two checks.
>
> Below the empty-delta guard on purpose: a ⌘R with nothing new is not
> a round, and numbering it would leave a gap in the lane the writer
> never saw a report for.
>
> **A CHECK is filed in no lane, whoever read it.** A reader is not a
> lane: their frame briefs the run and signs its notes, and stamping
> an id here would enter an Author ⌘R into a numbered lane the writer
> was never standing in — the exact defect the two resolutions split
> apart. Only a round has a lane, and by the guard above a round
> always has one. Spelled off `roundPass`, which is `nil` for a check
> by construction, so the rule is stated by the type as well as by
> this line.

**Above `let editorName = kind == .check`:**

> **Who signs what this run mints** — the check's reader by name, or
> the round's stage. Never nil: an unread check signs "Claude"
> (`AuthorReader.nobody`), and a round without an editor was refused
> at the press.

**Above `let readerName = kind == .check ? reader.editorName : nil`:**

> **What the RECORD remembers about who read** (two loops P2 Task 4,
> P1's Ruling 10). A check's byline is stamped here so a standing
> letter keeps the name it was written under after the writer changes
> who reads their checks. A round stamps none: its byline is its
> lane's, resolved from `passId` wherever the round is drawn, and a
> second copy is a second answer a rename could put out of step.

**Above `let round = passId == nil`:**

> A passless run mints no number at all rather than round 1 of
> nothing (decision 1: the passless lane is a lane, and an ordinary M2
> run is what it holds). Every check is now such a run.

**Above `let previousRound = (freshEyes || kind == .check) ? nil : Self.previo...`:**

> **The previous round, read HERE for the same reason the round number
> is minted here** (M3-P3 §6). At this instant the standing sidecar
> content IS the previous round — `replace` happens at finish — so
> this is the last moment it can be asked for. From the first closed
> section onward the standing content is this run's own preview, and
> a briefing assembled then would hand the model its own half-report
> as "what the last round found".
>
> **A cold read is briefed on none of it.** The round section hands
> the model what the last round raised and asks it to say what became
> of each — the opposite of reading the piece as if for the first
> time. So fresh eyes skips the gather entirely rather than passing a
> flag downward: nothing is asked of the store, and the pane's
> since-last-round line refuses the same round from the other end
> (`RoundNarrative.sinceLastRoundLine`), so the briefing and the
> report agree about what this round was measured against — nothing.
>
> **And a CHECK is briefed on none of it either** (two loops P1 Task
> 2). "What the last round raised, and what became of each" is the
> round loop's question; a check is the writer's own read of what they
> have just written, and handing it a lane's history would make ⌘R
> answer for a loop it does not belong to. Asked on the kind rather
> than on `passId == nil`, which is the same answer today by
> arithmetic and would stop being one the moment a check acquires a
> lane of its own.

**Above `let dispositions = freshEyes ? [] : environment.annotationContext(docId)`:**

> **What the writer has already done about this piece's notes**, read
> at the same instant and omitted on the same terms (M4 P1 §5.5).
>
> Two reasons it is here rather than beside the send. It is a read of
> the live annotation layer, and this run is about to WRITE into that
> layer at `finish` — asked later, it would hand the model this round's
> own notes as notes it had already seen. And the writer disposes of a
> note whenever they like, including while a check runs; the round was
> begun against the queue as it stood, and a mid-run answer belongs to
> the next ⌘R.
>
> **A cold read is briefed on none of it, exactly as it is briefed on
> no previous round.** Fresh eyes means a reader who has not seen this
> piece, and a list of everything they supposedly raised and the
> writer answered is the opposite of that. The duplicate guard on that
> path is `mintAnnotations`' own fingerprint dedupe, which is why it
> is load-bearing rather than a backstop there.

**Above `diagnostics.commitPendingAsk(docId: docId, kind: kind)`:**

> **What the writer asked of this run**, read at the same instant as
> the lane and the dispositions and carried for the same reason: they
> can clear the field while the check runs, and the run was briefed on
> what stood when they pressed ⌘R.
>
> **Asked of the store rather than through an `Environment` closure.**
> The orchestrator already holds `DiagnosticsStore` — it is the
> parameter this method is given — and the ask lives there beside the
> refusal memory, so a closure would be a second route to a store
> already in hand.
>
> **A cold read is briefed on it, where it is briefed on no round and
> no dispositions.** Fresh eyes means a reader who has not seen the
> piece, not a reader who has not met the writer: the ask is the
> writer's own question about the prose, and refusing to hear it on
> ⌘⇧R would answer a question nobody asked while ignoring the one
> they did.
> **Whatever is still in the ask field counts as asked** (P2 Task 7,
> fix round 1). ⌘R is a menu command and never touches the first
> responder, so without this a worry typed and not submitted would
> watch its own round go out briefed on the previous ask. Here rather
> than in the key handler because every trigger passes through this
> one line — the two keystrokes, the cockpit's buttons and the
> cold-start offer — and because a pending draft equal to the stored
> ask writes nothing.

**Above `let lessons = reader.isFirstReader ? nil : environment.lessons()`:**

> **The ledger, read beside the intent** and hashed with it (Task 4):
> both are declarations the writer has made rather than per-run
> context, so both diff in as one unit and a round that changed
> neither is told so in one line.
> **A first reader is briefed on no ledger** (ruling P2-7). The
> lessons ledger is the writer's own craft vocabulary — habits named,
> choices settled — and handing it to a reader who is forbidden craft
> words would be handing her the register her whole section refuses.
> Not read at all rather than read and dropped: there is no reason to
> touch the file for a run that may not know what is in it.

**Above `let essay = briefing.map { StatementEssay.half(of: $0.statementText) }`:**

> The essay half alone (spec §3.2). **This is the atomic switch**: the
> strata below the essay reach the run as the derived clauses resolved
> below, and briefing them as prose as well would put the same
> declaration in front of the model twice — see
> `CompilerRunCommandTests.test_rulingsAreBriefedAsClausesNotProse`.

**Above `let scenePosition = ScenePosition.derive(`:**

> **The letter's scene position, resolved here with the lane** (spec
> §3.4). Three things the writer owns decide it, and all three are
> read at the keystroke for the lane's own reason — the writer can
> switch passes or edit their intent while the check runs, and the
> run was briefed on the position it started in.
>
> **The WHOLE statement, not `essay` above.** Task 9's Add-to-intent
> offer files "Every scene turns." as a dated ruling under
> `## Rulings`; derived over the essay half, the clause would land
> where the derivation never looks, the offer would return every round
> forever, and no strain would ever be raised. The prompt's own essay
> section keeps the half — the strata below it reach the run as
> derived clauses, and briefing them as prose too would declare the
> same thing twice.
>
> **The brief is this verb's reader's** (two loops P2 Task 4): a
> round's stage doctrine, or — for a check — the coach's, since she is
> the one reader who has doctrine at all. A first reader answers `nil`
> here on purpose (`AuthorReader.brief`): her description is who she
> is, not an instruction about form, and reading it as a pass brief
> would let a sentence about what she loves flip the whole book into
> scene form.

**Above `let pinnedListing = environment.pinnedListing(docId)`:**

> Empty is a real answer (nothing pinned, no palette cards); the prompt
> omits an empty section by design, so this is a smaller prompt rather
> than a broken one. Read here, at the keystroke's own moment, so the
> context and the delta describe one instant of the project.

**Above `if freshEyes { retireSession() }`:**

> **The warm process dies HERE, and the read happens on its
> replacement.** Fresh eyes is a cold read in the literal sense: a
> session that has already read this piece carries every earlier turn
> in its context, so re-sending the whole manuscript to it would be
> the same tired reader given the same pages again. `retireSession`
> is `shutdown()`'s body minus the surface — the process is signalled
> and reaped, the config file goes with it, and `sentBriefing` clears
> so the replacement is told the essay, the declared world, the
> bible and the pinned references in full rather than "Declared
> world, bible and pinned references: unchanged since last run."
>
> Late on purpose: below the in-flight refusal (`runRequested`), below
> the burst-flush hop's generation check, and below the empty-delta
> guard — a keystroke that is refused, abandoned or has nothing to
> read must not have cost the writer their warm session on the way.

**Above `runState = .running(docId: docId, kind: kind, checking: DeltaCounts(o...`:**

> Set before the derivation, not after it: deriving is a subprocess,
> and a window that said `idle` for the seconds it takes would take a
> second ⌘R and run the same delta twice.
>
> It carries the delta's counts because they are known HERE and nowhere
> later — the pane's header says what is being read from this moment on
> rather than from the moment the answer comes back (requirement 5).

**Above `runStartedAt = Date()`:**

> Beside the state and not after the send: the elapsed figure the pane
> draws is the writer's own wait, which starts at the keystroke — the
> burst flush and the declared world's derivation are seconds the
> writer spends looking at "Checking…" like any other.

**Above `let runId = ULID.generate()`:**

> Minted here rather than when the answer lands, because the stream
> stores notes against it before there is an answer — and a note whose
> run id changed at the end would be a different run's note as far as
> every record downstream is concerned.

**Above `let lastOpId = kind == .check ? (delta.newestOpId ?? marker) : marker`:**

> `?? marker` rather than a bare `newestOpId`: a delta built with
> nothing after the marker still checked the prose it was given, and
> nil-ing the marker would make the next run re-read the whole
> document.
>
> **A round records the marker it FOUND** (two loops P1 Task 4). Its
> own delta was built `since: nil`, so `newestOpId` is the newest op
> in the document — writing that would advance the check's position
> past prose the writer has never had read back to them. Carrying the
> marker forward unchanged is what makes a round invisible to the
> check loop while the two still share one standing record (Task 5
> gives them a slot each; until then this is what keeps the check's
> position from regressing OR jumping).

**Above `guard let self, self.runGeneration == generation else { return }`:**

> The derivation is the run's second suspension, and everything the
> burst-flush hop can lose in its own window can be lost in this
> one — only over seconds rather than milliseconds.

**Above `let previousHash = self.sentBriefing[docId].flatMap {`:**

> Elided only while the SAME process is still reading — see
> `CompilerRunner.sessionEpoch`. Asked after the derivation because
> the session can have been retired while it ran, and a fresh
> process has read nothing.

**Above `let (message, briefingHash): (String, String?)`:**

> **Which loop asked, said by WHICH DOOR is used** (two loops P1
> Task 4). The two builders are `runMessageV2` with their kind
> fixed and the other loop's inputs absent from the signature —
> there is no `previousRound` to hand a check and no `stage`,
> `freshEyes` or `signals` to hand a round — so a round briefed as
> a check is a compile error here rather than a diff arriving with
> a stage's dose on it.

**Above `reader: reader,`:**

> **A check's frame is its reader's, and nothing else's**
> (two loops P2 Task 4). `checkMessage` has no `pass:` to
> give any more: the coach reached the briefing dressed as
> a pass while one closure answered both loops, and the
> door that could still take one is a door a lane could
> still come through.

**Above `freshEyes: freshEyes,`:**

> The one thing the prompt needs the flag for: a cold read
> is always the full letter, so the stage section must not
> ask for the short one over a run ingest will let through
> whole.

**Above `self.streaming = StreamingRun(`:**

> **Armed immediately before the send, and never earlier.** A run
> abandoned while its declared world derived — a subprocess, and
> the longer of the two suspensions — must leave nothing for a
> stream to land in.

**Above `runner.setProgressHandler { [weak self] progress in`:**

> The generation guard is the partial handler's, for its reason: a
> retired session's late report must not be attributed to the run
> that replaced it. `receivePartial` makes the same check inside
> itself; there is nothing to delegate to here.

### Orchestrator receivePartial

**Above `private func receivePartial(_ chunk: String, generation: Int) {`:**

> **One chunk of the answer, mid-turn** — accumulate, and read whatever
> lines it closed.
>
> The sections are the contract's unit (`DiagnosticIngest.parseSection`'s
> own doc: "one section is one unit ... so sections can be ingested as
> they arrive"), and a section is one line, so a closed line is the
> smallest thing worth showing. A line that is not a section — a fence
> marker, a sentence of narration, the last section still missing its
> newline — reads as nothing and simply waits for the result.
>
> **What lands here is a PREVIEW and never the answer.** It is stored
> through `DiagnosticsStore.preview`, which does not persist, does not
> enter the drift ring and does not raise the unread badge; `finish`
> reconciles the whole turn with `parseAll` and REPLACES all of it. A
> stream can be cut short, can double a section a model restates, and is
> absent entirely from a runner that does not stream — so nothing may be
> concluded from it that outlives the turn.

**Above `dosage: run.dosage)`:**

> **The dose the run was READ on, not one asked for again
> here** (global constraint 24). The preview shows what the
> report will show, so a question the short letter drops must
> never appear on the pane mid-check and vanish when the
> answer lands.

**Above `kind: run.kind,`:**

> The verb the run was started as, stamped on the
> preview exactly as `finish` stamps it on the
> answer — a preview that disagreed would change
> which loop the report belonged to as the check
> ended.

**Above `readerName: run.readerName,`:**

> The name the run was read under, stamped on the
> preview exactly as `finish` stamps it on the
> answer — a letter that changed hands as the
> check ended would be two readers' letter.

**Above `scenePosition: run.scenePosition,`:**

> The position the run was briefed on, stamped on
> the preview's letter exactly as `finish` stamps
> it on the answer's — a preview that disagreed
> with the run superseding it would flip the
> letter's scene section under the writer as the
> check ended.

**Above `stage: run.stage,`:**

> The stage the run was read on, stamped on the
> preview exactly as `finish` stamps it on the
> answer — the preview and the answer describe one
> check or they describe two.

**Above `ask: run.ask,`:**

> The ask the run was briefed on, stamped on the
> preview exactly as `finish` stamps it on the
> answer — a preview that disagreed would change
> what the letter says it was asked as the check
> ended.

**Above `mintedNotes: nil, openInOtherLanes: nil,`:**

> A preview has minted nothing: the notes it would
> mint are minted at `finish` or not at all, so
> `nil` here is "no mint has happened" rather than
> a claim that this run queued none — and the
> cross-lane count is the same fact seen from the
> other side, so it is nil for the same reason.

**Above `timing: nil),`:**

> A turn still arriving has resolved nothing, so
> there is nothing yet to say it cost — nil for
> the two counts' own reason, one line up.

**Above `diagnostics: run.outcome.sidecarDiagnostics, docId: docId)`:**

> **A preview shows what the report shows, and nothing else**
> (M4 P1 Task 3). Continuity and reader sections still accumulate
> on `run.outcome` — the run's own record reads its counts off it
> — but they are no longer the sidecar's, so they must not be
> previewed into it either. They mint at `finish` or not at all.

### Orchestrator endings and helpers

**Above `private func endLiveRun() {`:**

> **The two live-run facts, cleared together** (spec 2026-09-09 §5).
>
> Called from every place a run stops being live and in lockstep with
> `runState`, never ahead of it: a start time left standing draws a
> duration that goes on counting over a check that ended, and a progress
> figure left standing is one turn's thinking attributed to the next.
> They clear together because "a run is live" must have one answer —
> a start with no progress is an ordinary early turn, but a progress
> figure with no start is nothing at all.

**Above `private func discardStreamPreview() {`:**

> Throw away whatever the stream put on the pane, and forget the stream.
>
> Called wherever a run ends without an answer — cancel, toggle-off,
> project close, a death, output that could not be read. **No half-report
> survives a run**: the notes on the pane came from a check that did not
> finish, and leaving them would be the compiler reporting on prose it
> stopped reading half way through.

**Above `diagnostics?.discardPreview(docId: run.docId, kind: run.kind)`:**

> The run's own kind, so a cancelled check leaves the standing round
> on the cockpit and a cancelled round leaves Author's notes alone
> (two loops P1 Task 5).

**Above `private static func previousRound(`:**

> **What the last round in this run's lane raised**, or `nil` when there
> is nothing this round can honestly be measured against.
>
> The lane rule, in one place (`SinceLastRound`'s decision 1): only a
> prior round with the SAME `passId` briefs the next one. A passless ⌘R
> is an ordinary M2 run and is briefed on nothing; a run that opens a new
> lane starts clean, because the Line pass's findings are not what a
> Proof round is measured against.
>
> The standing run is the ONLY candidate, and that is not a shortcut: a
> round's notes are gone the moment the next round replaces them, so a
> round older than the standing one has fingerprints in the ring and no
> prose anywhere. If the standing run belongs to another lane, this
> lane's last round left nothing to say.

**Above `guard let kind = note.kind else { return nil }`:**

> A note with no section is a v1 record, which has no identity
> under this contract — `RoundFingerprint.make` refuses one for
> the same reason, so counting it and briefing it stay in step.

**Above `sinceEdited: note.anchor.map {`:**

> `DiagnosticsStore.live`'s rule, asked directly: the
> paragraph's text now against the text the note was anchored
> to. A paragraph that is gone answers `nil`, which is not the
> anchor text either — the writer edited it away.

**Above `private static func resolveWorld(`:**

> The declared world for this run: the cached reading if one was made from
> exactly this text, else one derived now and cached by the closure that
> derived it.
>
> **The lazy trigger, and its only production site** (`AREA.md`, "the
> derivation trigger"): nothing here runs on a timer or on a save. A
> statement is edited for reasons that have nothing to do with a check
> being imminent, and a derivation per edit would spawn `claude` for prose
> nobody is about to compile against.
>
> `nil` at either step is honest and non-fatal — no statement at all, a
> missing CLI, the toggle switched off, output that could not be read. The
> run proceeds on the essay alone and the conformance section has nothing
> to check, which the schema tolerates (an empty `checks` array). A run
> that refused over a missing convenience would be the compiler holding
> the writer's ⌘R hostage to a subprocess.

**Above `static func prose(of delta: CompilerDelta) -> String {`:**

> The delta's own words, as one string — what the bible slice is matched
> against.
>
> A revision's BEFORE text counts as well as its after: the message shows
> the model both, so a subject named in either is one the run is about,
> and a fact about a character the writer has just written out of a
> paragraph is exactly the kind of thing a continuity question is for.

**Above `func cancel() {`:**

> End the turn in flight. The session stays warm.
>
> **A run can be under way without a turn to end**, and that window is
> now seconds rather than an instant: between the keystroke and the send
> the run closes the writer's burst and then derives their declared
> world, a whole subprocess. `cancelCurrentRun` guards on the session
> having a turn, so it no-ops against exactly that run — Cancel would
> mean "carry on", and the run it did not stop would go on to spend a
> full turn. So the unsent case is abandoned here by generation, the way
> `shutdown()` abandons it, and the session is left alone because there
> is nothing of ours in it.

**Above `discardStreamPreview()`:**

> Here as well as in `finish`'s failure arm, and not instead of it.
> The turn's continuation resumes on a later tick, so a report left
> standing until then is a half-report the writer watches for as long
> as the runloop takes — and a runner that answers a cancel with
> something other than a failure would never reach `finish` at all.

**Above `endLiveRun()`:**

> In lockstep with the state, and so only on the path that ends the
> run here. A cancel of a run already SENT leaves both standing until
> its failure reaches `finish`, which is the same tick `runState`
> stops saying "running" — one answer to "is a run live", not two.

**Above `func shutdown() {`:**

> End the session: the AI toggle going off, project close, app quit.
>
> **Not optional on any of those paths.** `ClaudeCLISession` cannot reap
> its own child from `deinit`, so a session merely released outlives the
> window as a live, billing process.

**Above `runGeneration &+= 1`:**

> A run acknowledged a moment ago but still closing its burst — or
> waiting on a derivation — has no session yet, so `retireSession`
> cannot reach it. Abandon it here, or the toggle going off is followed
> by the run it was meant to prevent.

**Above `discardStreamPreview()`:**

> The toggle going off takes the half-report with it, for the same
> reason it abandons the run: nothing on the pane may outlive the check
> that produced it.

**Above `if isRunning {`:**

> A turn cut short leaves the surface saying "running" forever
> otherwise. A REPORTED failure is left alone: the toggle going off
> must not erase the banner explaining why the last run failed.

**Above `func detach() {`:**

> Shut down and release the window's object graph. The close-the-window
> verb, distinct from `shutdown()` because a writer who turns Claude off
> and on again must still have a working ⌘R.

**Above `private func ensureRunner(model: String) -> CompilerRunner? {`:**

> The warm session, spawned lazily on the first run — and its
> `--mcp-config` file, written once per session and deleted with it.
> One config per RUN would leave a JSON file per keystroke in the temp
> directory for the life of the machine.

**Above `guard runnerModel != model else { return runner }`:**

> The gear menu moved since this session was spawned. Retire it
> here rather than at the setting's own call site: this runs only
> between turns (`runRequested` guards `!isRunning`), so the change
> costs nothing in flight.

**Above `private func retireSession() {`:**

> End the current session and drop everything scoped to it, without
> touching `runState` — `shutdown()`'s body minus the surface, so the
> model swap above is invisible to a writer who only sees the answer.

**Above `sentBriefing.removeAll()`:**

> A new process has read nothing, so nothing may be elided from its
> first message.

**Above `static func summary(of delta: CompilerDelta) -> String {`:**

> The run record's one-line description of what was checked.

### Orchestrator record

**Above `private static func record(`:**

> The run record — **one spelling, read by the preview and by the final
> answer**, so what the pane says mid-check and what it says afterwards
> cannot describe the same check differently.
>
> `passId`/`round`/`freshEyes` are required rather than defaulted: they
> are minted at the keystroke and carried, and a third call site that
> could quietly omit them would file an unnumbered round nothing
> downstream could notice — the preview and the answer would simply
> disagree. `stage` is undefaulted on that rule (P3 Task 4): a default
> would let a call site stamp `revising` over a drafting run's letter,
> and nothing about the record would look wrong. It is OPTIONAL as of two
> loops P1 Task 4 — a round derives no stage — and `nil` leaves
> `Letter.stage` unset, which is the field's own tolerated-missing case
> (`Letter.draftStage` reads an absent or unknown raw value as `nil`, and
> every surface that draws the word already handles it).
> `mintedNotes` and `openInOtherLanes` are `nil` for a preview — nothing
> is minted until the turn ends — and the finished run's real counts
> otherwise. Undefaulted for `passId`/`round`/`freshEyes`'s reason: a
> third call site that quietly omitted either would record a run claiming
> it queued nothing and engaged nothing.
> `kind` is undefaulted on the same rule, and its own case is sharper
> than the rest: the two loops are about to diverge on it, so a call site
> that could omit it would file a round as a check with nothing to
> notice.

**Above `var letter = outcome.letter`:**

> **The letter's one mutable field, stamped here** (spec §3.4). The
> position is the run's, not the model's: it is derived app-side at
> the keystroke and the model is only told about it, so the record
> must carry what the run decided rather than anything the answer
> echoed back. Stamped in the one `record` spelling for the reason
> every other field is — the preview and the final answer must
> describe one check.
>
> A turn that answered no letter has nothing to stamp, and `nil` stays
> `nil`: the position is a fact about a letter, not about a run.

**Above `letter?.asked = ask`:**

> **The letter's second stamp, beside the position and for the same
> reason** (P2 Task 3): what the writer asked is the run's own fact,
> read at the keystroke, and the record must carry it rather than
> anything the answer echoed back. It is also what lets the section
> say what was asked after the writer has cleared the field — which
> they do the moment they have read the answer.

**Above `return CompilerRun(`:**

> **The letter's third stamp, and it is deliberately on the line
> touching the second** (spec §3.8, global constraint 23). The stage is
> the same kind of fact as the position and the ask — the run's own,
> derived at the keystroke, never echoed back by the model — so it is
> stamped in the same place, and `CompilerRunCommandTests`'
> `test_theStageIsStampedBesideTheAskInTheOneRecordSpelling` reads the
> adjacency off this file. `rawValue` rather than the case, because
> `Letter.stage` is a disk format: a rename reads back as `nil` on
> every letter already written, which `Letter.draftStage` tolerates.
>
> A turn that answered no letter has nothing to stamp, exactly as with
> its two siblings: the stage is a fact about a letter, not a claim
> every run makes.

**Above `droppedDangling: outcome.droppedDangling,`:**

> Carried, not swallowed. A run whose every note named a paragraph
> the writer has since changed accepts nothing, and without this
> the pane would wear the seal over it.

**Above `clauseStatuses: outcome.conformance,`:**

> The clauses that produced no note are most of the summary:
> stored with the run, superseded with the run.

**Above `truncatedReader: outcome.truncatedReader,`:**

> How many reader reports were over the schema's cap of three,
> stored with the run so the pane can report the truncation.

**Above `passId: passId, round: round,`:**

> The lane and its number. Both nil on a passless run, which is an
> ordinary M2 run rather than a degenerate round.

**Above `freshEyes: freshEyes ? true : nil,`:**

> **An ordinary run stamps NOTHING, not `false`** (M3-P3 Task 6).
> The field is what the pane's header and the since-last-round
> line both read, and both ask `== true`, so `false` and absent
> are the same answer to every reader — which makes the absent one
> strictly better: a ⌘R's sidecar stays byte-for-byte what it was
> before this task existed, and "read cold" stays a thing a record
> says rather than a thing every record carries an opinion about.

**Above `intentDriftVerdict: intentSnapshot == nil ? nil : outcome.intentDrift...`:**

> The round's judgement of the draft against the declared intent
> (M3-P3 Task 4). Read straight off the outcome, so the preview
> and the finished answer say the same thing about the same turn
> — and nil for a turn that answered only the four sections it
> knew, which is the additive contract working.
>
> It reaches DISK only through `DiagnosticsStore.replace`: a
> preview carries it in memory, where the strip can draw it as it
> arrives, and a cancel puts the last finished run's verdict back
> by re-reading the untouched sidecar.
>
> **A run with nothing declared records NO verdict, whatever the
> model answered** (M3-P3 Task 5). The schema instructs `holds`
> where there is no intent, which is the obliging answer and not a
> true one: nothing was checked against anything, so nothing was
> judged. The guard is here rather than at ingest because this is
> where the two halves meet — the snapshot is what the round was
> briefed on, and a verdict without one is a judgement with no
> subject. Downstream is unaffected either way (the strip's mark
> fires on `drifted` alone); what this protects is what the RECORD
> is allowed to claim, since the sidecar is where a later build
> looks to tell "never judged" from "judged and held".

**Above `mintedNotes: mintedNotes,`:**

> **What this run put in the queue.** The pane's own report holds
> conformance strains alone now, so without this a run that raised
> three questions and no strain would be indistinguishable from a
> run that found nothing — and the surface would say so.

**Above `openInOtherLanes: openInOtherLanes,`:**

> **What this run engaged but could not queue, because the writer
> is already holding it in another pass** (#42 F-H). The same
> argument one field along: without it a round that re-raised a
> question open in the Structural lane reads as three zeroes on
> the since-line, which is a check that did engage the piece
> reported as one that found nothing in it.

**Above `openInOtherLanesNoteIds: openInOtherLanesNoteIds,`:**

> Which notes, so the clause reads the queue live (#53).

**Above `kind: kind,`:**

> **Which loop asked** (two loops P1). Stamped in the one `record`
> spelling for every other field's reason — the preview and the
> answer must describe one verb, and a run whose kind changed at
> the end would be a different verb's run as far as every record
> downstream is concerned.
>
> **Stamped ALWAYS, and deliberately not on `freshEyes`'
> absent-means-false terms.** There is no value here that means
> the same as absent: `nil` is a record written before this field
> existed, and `CompilerRun.effectiveKind` is the one place that
> legacy is read.

**Above `readerName: readerName,`:**

> **Who read it** (two loops P2 Task 4, P1's Ruling 10). Minted at
> the keystroke with the lane and carried for the lane's own
> reason — the writer can change who reads their checks while one
> runs — and stamped in the one `record` spelling so the preview
> and the answer are signed by the same person. `nil` for a round,
> whose byline is its lane's.

**Above `letter: letter,`:**

> **The sixth section, P1.** Read straight off the outcome, the
> same way `intentDriftVerdict` is — the preview and the finished
> answer describe the same turn's letter, and `nil` where no
> section has answered it yet (Task 2 wires the parse).

**Above `timing: timing)`:**

> **What the turn cost** (spec 2026-09-09 §5), read off the
> session that ran it. `nil` on a preview, which has no resolved
> turn to have cost anything, and on a runner that measures
> nothing — undefaulted for `passId`/`round`'s reason, so a third
> call site cannot quietly file a run claiming it cost nothing.

### Orchestrator finish

**Above `private func finish(`:**

> **`async` because the run is not over until its notes are written**
> (M4 P1 Task 3). The mint appends to the op log, and a `runState` that
> went `.idle` before those appends landed would tell the writer the check
> was finished while its findings were still arriving in the pane beside
> it. Nothing else about the arm changed: the mint cannot throw, cannot
> fail the run, and is reached only on `.resultText`.
>
> **`generation` is the run's own, and it is re-checked after the mint** —
> the third suspension this class carries a generation across, after the
> burst flush and the derivation, and the only one that resumes with
> writes still to do. A Cancel inside the mint window bumps the
> generation and sets `.idle`; the very next ⌘R is then a live run, and a
> finish resuming afterwards would write `sentBriefing` and `runState`
> over it — telling the new run's session it had already been briefed,
> and calling a check that is still going idle. Everything before the
> mint is synchronous with the turn's own resumption and needs no guard.

**Above `return`:**

> Unreachable through `send`, which resolves with a terminal event
> (`CompilerRunner`'s own contract). Streaming does NOT arrive
> here: a chunk reaches `receivePartial` through the runner's
> partial handler, because a turn has many chunks and exactly one
> terminal event. Named rather than silently ignored.

**Above `guard runGeneration == generation else { return }`:**

> **A retired session's failure is not this run's** (#63 item 1).
> `shutdown()` bumps the generation and kills the process, but the
> old `send` resolves only once that process has died — a bounded
> grace, not a tick (#36) — and a writer quick enough to toggle
> Claude back on and press ⌘R has a newer run live by then. Ending
> it here would call that run idle, stop its clock and throw away
> what it is streaming. A Cancel of a sent run does not bump the generation, so
> its own failure still lands.

**Above `discardStreamPreview()`:**

> The marker and the briefing hash are both left exactly where they
> were. A run that produced nothing checked nothing — advance
> either and the next run describes a session that never read it.
> The stream goes with them: what it showed was a check that did
> not finish.

**Above `guard let outcome = DiagnosticIngest.parseAll(`:**

> **The whole turn at once, and it REPLACES whatever streamed.**
> `parseAll` is `parseSection` folded over the turn's objects and
> nothing else (`DiagnosticIngest`'s own contract), so this is the
> same reading of the same sections — but of ALL of them, including
> a last one whose newline never came and a first one the model
> restated. Reconciliation rather than accumulation is what leaves
> one source of truth at the end of a turn: fold the preview into
> this and a section the model wrote twice would be shown twice.

**Above `dosage: dosage)`:**

> **Where the short letter is MADE short** (global constraint
> 24). The briefing asked for it; this is what makes it true
> whatever the model wrote — and it runs above the mint, so a
> question the dose drops cannot reach the queue as a `.query`
> either.

**Above `guard runGeneration == generation else { return }`:**

> The failure arm's guard, for the same reason (#63 item 1): a
> retired session's unreadable turn is not the newer run's.

**Above `endLiveRun()`:**

> The arm's own early return, and the third place a run stops
> being live: a turn Maugham could not read has ended exactly
> as a failed one has, and a clock left ticking here would
> outlive every later run.

**Above `let notes = outcome.mintable`:**

> **The split, and it is the whole point of M4 P1's first plan.**
> A conformance strain is read beside the clause it strains
> against, so it stays in the report; a continuity question and a
> reader's report are about the words and outlive the check, so
> they leave for the annotation layer. One finding, one home — and
> the two halves land in the same commit, because a build in which
> a note appears in both is a build that asks the writer to answer
> it twice.
>
> **The mint runs BEFORE the record is built, and the order is
> load-bearing.** How many notes went to the queue is not knowable
> until the mint has run — the dedupe drops what is already open,
> and a note whose paragraph has gone fails its own append — and a
> record written without that number leaves the pane free to say
> "Nothing to flag" over a run that flagged three things. The
> report waits out N op-log appends to be able to say what
> happened, which is the right trade: a header that lies is worse
> than one that is a few milliseconds late, and the writer is
> watching "Checking…" the whole time either way.

**Above `editorName: editorName))`:**

> **Resolved at the keystroke, carried here** (two
> loops P2 Task 4). A check signs with its reader's
> name — the coach's, the first reader's, or "Claude"
> for nobody, which `AuthorReader.nobody.editorName`
> answers so that `passlessEditorName` keeps the one
> production use `TripwireGrepTests`' census pins — and
> a round with its stage's. Asked once, above, rather
> than re-derived here: the writer can change who reads
> their checks while one is in flight.

**Above `guard runGeneration == generation else { return }`:**

> The one suspension in this method, and the writes below are what
> make it worth guarding. See the doc comment.

**Above `passId: passId, round: round, freshEyes: freshEyes,`:**

> The pair minted at the keystroke, not re-asked here: the
> store's own standing content is this run's preview by now,
> and the writer may have moved the piece to another pass
> while it ran.

**Above `kind: kind, readerName: readerName,`:**

> Minted at the keystroke beside them, and carried for their
> reason: the writer can switch personas while the check runs.

**Above `timing: runner?.lastTurnTiming)`:**

> **Read off the session that ran the turn** (spec 2026-09-09
> §5), here rather than at the keystroke because it is the one
> thing on the record that is not known until the answer
> lands. `nil` from a runner that measures nothing, which is
> every suite's double.

**Above `streaming = nil`:**

> Dropped rather than discarded: `replace` below supersedes the
> preview wholesale, so taking it off the pane first would blink
> the report out and back.

**Above `if !outcome.facts.isEmpty {`:**

> Silently, and never as notes: the bible is a ledger the writer
> acts on in the Intent pane, not a thing the compiler reports.

