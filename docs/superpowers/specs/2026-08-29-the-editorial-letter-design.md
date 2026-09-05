# The editorial letter — Le Guin, habits, lessons, and the writer's own process

**Date:** 2026-08-29 · **Status:** approved in brainstorm, plans unwritten · **2026-09-01:** §4 revised — the coach is a seat, not a rung; reader line; depth in Review; Exhaustive
**Session:** "coach"

> **2026-09-05:** §4.1 "The seat" — the coach as the reader of any piece with no active pass, and §4.2/§9's consequences of it (a stage editor signing Author's ⌘R) — is **superseded** by [`2026-09-05-two-loops-two-readers-design.md`](2026-09-05-two-loops-two-readers-design.md): the coach is Author's reader full stop, a check files no round, and one-loop §7.0 stands. Everything else here stands.

## 1. The problem

Every piece of feedback Maugham gives today is *corrective, per-instance, and on
demand*: ⌘R measures the delta against declared intent (holds/strains), asks
continuity questions, gives a first-reader's report, quietly fills the bible;
the four editor voices run rounds by pass; drift watches the statement; every
finding lands as an anchored note the writer disposes of. That shape serves a
writer who already knows what they are trying to do.

A new author has a different set of gaps, and none of them is "more notes in
the queue":

1. **Habits, not instances.** A beginner's defects are patterns — filter
   words, tags doing the emotion's work, every paragraph opening on a name,
   unvarying rhythm, explaining a feeling after showing it. Fifty anchored
   notes teach nothing; one line saying *you do this, here are six places,
   here is what it costs* teaches the habit. Nothing aggregates across a
   manuscript today.
2. **What's working, named.** New writers cannot tell their good sentences from
   their bad ones and revise the good ones away. `holds` is neutral; nothing
   points at a strength as something to repeat.
3. **Scene function.** Per scene: who wants what, what changes, where the
   turn is. A scene where nothing changes is the classic structural beginner
   defect and is invisible in a note, visible in a table.
4. **Process feedback from the op log** — the thing only Maugham can give.
   "You have rewritten the opening nine times and written nothing past chapter
   3 in three weeks." Session stats exist and are, per the problem map,
   "interesting more than useful."
5. **Questions instead of verdicts.** The `query` annotation kind exists;
   nothing mints it. A coaching voice whose only line-level output is a
   question respects the membrane better than any suggestion.
6. **The lesson, kept.** Problem map: "keep the lessons from feedback, not
   just the fixes" is at ~. The principle behind a note is nowhere the writer
   can read, curate, or be reminded of.

Real editors already split feedback in two: **line notes** in the margin and an
**editorial letter** about the manuscript as a whole. Maugham has the first
half. Items 1, 2, 3 and 5 are things a letter says; 4 is something the letter
can cite; 6 is what the letter leaves behind.

## 2. Decisions of record (Denver, this brainstorm)

- **Both**: the letter is a mechanism any round can produce (§3), **and** a
  new coaching voice makes it the main event (§4).
- The coach is **Le Guin** (id `workshop`, name Workshop).
- **Le Guin holds a seat, not a rung** (2026-09-01, revising this
  brainstorm's "first on the ladder"). Coaching is a standing relationship,
  not a stage of finishing: a piece never completes the workshop, so she has
  no pass state, takes no part in derived review status, and the board draws
  her apart from the ladder (§4). The ladder keeps one meaning.
- **An unassigned piece is the coach's.** A ⌘R on a piece with no active pass
  briefs whoever holds the seat; `CompilerOrchestrator.passlessEditorName`
  stops being a constant. "Claude" was only ever the absence of a voice; an
  unassigned piece *is* the beginner's piece. The continuity / bible / reader
  machinery still runs beneath any voice.
- **Scene function is three-position, not opt-in** (§3.4): the weak form
  ("what changes") is the prose default; McKee's strong form (value charge,
  conflict-driven turn) is the screenplay default and prose opt-in through
  intent; a lyric/essayistic intent opts out of the rows entirely.
- Letters are derived and age with the rounds ring; **Keep this letter**
  makes one durable (§3.6). Mirrors rulings: durable only when the writer acts.
- Process signals never appear unprompted (§5) — constitution must #2.
- Lessons are project-scoped only (§6). Habits belong to the writer, not the
  chapter.
- **Seven additions from the theory pass** (Lerman's Critical Response
  Process, Elbow, Hattie & Timperley, Stone & Heen, Le Guin's own exercises):
  the writer's ask (§3.7), exercises that file as tasks (§3.1), say-back and
  the one thing (§3.1), dosage by draft stage (§3.8), retired lessons and
  choices (§6), voice distinctness and time-away (§3.1, §5).
- **The passless rule follows the seat** (§4): Le Guin briefs an unassigned
  piece while she holds the seat; vacate it and a passless run is the M2
  all-altitudes reader signed "Claude". No experience-level switch exists —
  the seat is the writer's declaration.
- **Author shows who is in the seat** (§4.2): the Diagnostics header names
  the reader a ⌘R on this piece will brief, off the same resolution the run
  uses. Changing the reader stays a Review act.
- **Depth is chosen in Review too, and there are four depths** (§4.3): the
  cockpit gets the Diagnostics pane's gear menu, bound to the same project
  value, and a fourth choice maps to the `fable` alias.
- **The brief measures against the writer's own pinned work** when the shelf
  holds it (§4).
- **The book letter** — a whole-project Fresh Eyes with an arc table — is the
  named follow-on milestone (§10), not a plan here.
- **Design rule:** every surface is reached from the letter, and the letter is
  reached from ⌘R. Nothing here is required for the day-one loop (§9).

## 3. The letter (mechanism)

### 3.1 A sixth report section

The compiler's report is streamed as fixed-order sections
(`conformance, continuity, reader, facts, intent_drift` —
`CompilerPrompt.sectionSchemaDescription`). The letter is a sixth section,
`letter`, last, so the writer is reading line-level results while the letter
is still being written — the same tempo the guide already promises.

```
{"section":"letter",
 "answer":   <string|null>,                                           // the writer's ask, answered first (§3.7)
 "about":    <string>,                                                // say-back: what this seems to be about, as read
 "one_thing":<string|null>,                                           // if you fix one thing, this
 "working":  [{"refs":[¶id…], "what":<string>, "why":<string>}],      // ≤3
 "habits":   [{"name":<string>, "refs":[¶id…], "cost":<string>,
               "lesson":<string|null>,
               "exercise":<string|null>}],                            // ≤2, ≤4 refs each
 "questions":[{"refs":[¶id…], "question":<string>}],                  // ≤3
 "scenes":   [{"refs":[¶id…], "wants":<string|"">, "changes":<string|"">,
               "turn":<string|"">, "charge":"+"|"-"|null}] | null,
 "retired":  [<lesson heading>],                                      // §6
 "process":  <string|null>}
```

Part by part, in reading order:

- **`answer`** — the writer's ask (§3.7), answered before anything else.
  Absent when nothing was asked.
- **`about`** — Elbow's *say-back*: one sentence, what the piece seems to be
  about as read. Always present. The writer compares it to their own intent
  themselves; for a new author that is a better reader-side drift check than a
  holds/drifted verdict, and it costs one line.
- **`one_thing`** — Saunders's rule: if you fix one thing, this. One line, so
  a cap of 3+2+3 never reads as nine equal demands. May be null when the
  letter has nothing to fix (a legitimate answer).
- **`working`** — what works, with the repeatable principle. The brief names
  strengths before habits.
- **`habits`** — a pattern across what was read; `exercise` is Le Guin's
  feed-forward — a thing to *do*, never a rewrite (*rewrite the scene without
  a single "was"; read the dialogue aloud with the names removed*). **Accept
  as task** files it through `ProjectStore+Tasks` as a document-scoped task
  anchored at the habit's first ref, so the writer leaves a round with
  something to try. One named habit test the brief carries by name: **voice
  distinctness** — could each character be identified by their lines alone.
- **`questions`**, **`scenes`** — as below.
- **`retired`** — lessons the round looked for and did not find (§6).
- **`process`** — one sentence from Maugham's own numbers (§5).

- Every part optional; an empty part is an empty array, never omitted (the
  existing "a section with nothing to report still appears" rule).
- `refs` are paragraph ids from the delta, resolved at ingest against the
  **live** document exactly as diagnostics are; a ref that no longer resolves
  is dropped from the entry, and an entry with no surviving ref survives
  without jump links (a habit is still true when one of its instances was
  rewritten). `droppedDangling` is not incremented for letter refs — the
  letter is not a note.
- `habits[].lesson` is the model's one-line principle for the ledger (§6);
  `null` when the habit cites a lesson the ledger already holds, in which case
  `name` is that lesson's heading verbatim ("this is the one we talked about").
- The cross-section dedup rule extends to the letter: an issue raised as a
  strain, a continuity question or a reader report does **not** reappear as a
  habit or a question; a habit is by definition what no single note can carry.

### 3.2 Storage

`CompilerRun` gains `var letter: Letter?` beside `clauseStatuses`. `nil` marks
a record written before the section existed, on the `clauseStatuses == nil`
convention. The letter is superseded with its run and rides the existing
5-deep rounds ring (`DiagnosticsStore.roundHistoryDepth`); it lives in the
per-`(document, device)` diagnostics sidecar and is derived (tripwires 17/24).

`questions` are additionally minted as `query` annotations through
`Environment.mintAnnotations`, pass-stamped and signed by the voice, deduped by
the same fingerprint the other minted kinds use, so they are ordinary queue
rows thereafter. Two consequences of the existing machinery, stated so the
plan does not rediscover them: a `.query` **cannot** be minted without an
anchor (`Document.addAnnotation` refuses one, and a fingerprint needs an
anchor or a clause quote), so a letter question whose refs all failed to
resolve is **letter-only** — it renders in place, it never reaches the
queue, and the letter says nothing about that; and letter questions get their
own `DiagnosticKind` (`letterQuestion`), so a coach's question and a
continuity question about the same paragraph are two fingerprints, not one.
The letter keeps its own copy of the question text for reading in place;
disposition lives in the queue only (one home per finding, the one-loop spec
§8).

### 3.3 Who writes one

Any round can. The briefing tells the model what a letter is for, and each
preset brief says whether that pass writes one:

- **Le Guin** (§4): the letter is the main event; every part is hers.
- **Perkins**: `about`, `one_thing`, `working`, `habits` (structural habits),
  `scenes`; no `questions` beyond his existing continuity questions, no
  exercises.
- **Lish**: `about`, `one_thing`, `working`, `habits` (sentence habits); no
  `scenes`, no exercises.
- **Gould, Argus**: leave the letter empty. Their briefs say so.
- `answer` and `retired` are every voice's when there is an ask or a ledger:
  a direct question gets a direct answer whoever was asked, and a lesson
  looked for is reported by whoever looked.
- A **custom pass** with a writer-editable brief writes whatever its brief
  asks; with no brief, the general instruction applies and the model decides.

### 3.4 Scenes — the three-position default

`scenes` is computed only when the run's briefing says the piece moves by
scenes, and in which form:

| Project type | Intent says | Rows | `charge` |
|---|---|---|---|
| prose | nothing about form | yes — weak form: wants / changes / turn as observation | `null` |
| prose | moves by dramatic turns / "every scene must turn" (or the pass brief says so) | yes — strong form | `+`/`-`; a turn-less scene is also raised as a **conformance strain** when the writer's own intent carries the clause |
| prose | lyric / essayistic / meander / "not scene-driven" | none (`null`) | — |
| screenplay | nothing | yes — strong form | `+`/`-`; a turn-less scene is an **observation with an offer** (below) |
| screenplay | opts out explicitly | none | — |

**A strain needs a clause the writer wrote.** Conformance is keyed on a
`clause_quote` from the intent statement and ingest drops a strain with an
empty quote; the section's whole promise is *measured against what you
declared*, so nothing here synthesizes a clause. Under the strong form with
no such clause — a screenplay with a silent intent, or a prose piece opted
in by a pass brief rather than its own words — a turn-less scene stays an
observation in the table, and the table ends with one standing line: *Hold
every scene to a turn?* with an **Add to intent** button. The click files
that sentence as a dated ruling under the piece's intent through the
existing rulings path, so the words are the writer's from then on and the
next round strains against a clause they can find in their own statement.
The line appears on every strong-form round until a clause exists, then
never — the offer lives exactly where the gap is visible (2026-09-01,
Denver's discoverability concern). Same shape as Answer as ruling and §6's
Retire: Maugham notices, offers, and writes only by the writer's hand. The
plan verifies that a ruling's text is quotable as a `clause_quote` (the
rulings ride in the intent snapshot the run is measured against).

The prompt derives the position from `ProjectType` and the intent essay; the
model is told which position it is in and never asked to infer it. (⌘R has no
document-kind gate — `runRequested` takes any active document — so a
screenplay already runs today; the position is the only new thing.) In the weak
form a blank `changes` cell is an observation — Le Guin's letter may ask
"nothing shifts here that I can see; is that the point?" — and never a strain.
Weak-form rows carry no "conflict" field at all, on purpose: the doctrine the
default encodes is the near-consensus one (something should change), not the
disputed one (it must be a conflict-driven reversal).

### 3.5 Rendering

- **Author — Diagnostics pane (⌘⌥D):** a **Letter** section at the top,
  above This check and Conformance. The letter is what the writer reads
  first; the notes are the margin. Parts in the schema's reading order:
  answer (when asked), about, one thing, working, habits (each with its
  exercise and **Accept as task**), questions (each row a jump to its first
  ref, with "and N more" for the rest), scenes (a compact table, blank cells
  blank), retired (a line on a warm round, an offer on Fresh Eyes — §6),
  process (one line). Signed with the voice's name and the round's lane
  line. An empty letter draws no section.
- **Review — the round cockpit:** the letter's `one_thing` (else `about`)
  under the lane line, with a disclosure that opens the same section inline.
  Nothing about the cockpit's buttons changes.
- **Rounds ring:** the cockpit's "since round N−1" is unchanged. Only the
  standing run's letter is on screen: the ring records a superseded run's
  identity and lane, not its content, so a previous round's letter is gone
  once superseded — **Keep this letter** (§3.6) is how one outlives its run.
  (Plan-time correction; the draft said "reachable from the ring".)
- Wet-ink standing (M4 P2 §7.0) is unaffected: the letter is per-run, not
  per-note, so it has no `WetInk` state.

### 3.6 Keeping a letter

A **Keep this letter** control on the section (and in the cockpit's
disclosure) writes the whole letter, rendered as Markdown with the voice, date
and lane line as its heading, as a research note through the existing
promote-to-research path (`ResearchScope` decides containment vs link exactly
as it does for canvas promotion). The note is a copy; the run's own letter
still ages out. No other durability is offered — a letter the writer did not
keep was a letter the writer read and let go, which is what happens to a
letter.

### 3.7 The writer's ask

Lerman's step 2, and the largest gap the theory pass found: the writer says
what they want feedback *on* — "I'm worried the middle sags", "is her voice
distinct from his?", "just tell me whether the ending lands". Today the only
steering is the intent statement, which is about the piece, not this round.

**Ask about…** is a one-line field on the run: in Review, in the cockpit
between the lane line and the buttons; in Author, in the Diagnostics header.
Per document, persisted in the diagnostics sidecar (derived; losing it costs a
sentence), kept until the writer clears it — a worry usually outlasts one
round. The briefing carries it as its own section and the schema puts the
answer first. An ask that is an opinion request ("what do you think of the
ending?") is Lerman's step 4 — opinion with permission — and the brief says a
direct question gets a direct answer, in the voice's register, still never a
rewrite.

### 3.8 Dosage by draft stage

A first draft in motion should not be line-edited (Lamott, King). The stage is
**derived, never set**, from numbers the run already has: a delta that is
mostly *new* paragraphs at the document's frontier is **drafting**; a delta
that is mostly *revised* is **revising**. `CompilerOrchestrator.DeltaCounts`
plus the frontier (§5) decide it; the briefing names the stage.

- **Drafting:** a short letter — `about`, `working`, at most one question,
  habits only when a habit is everywhere in the delta, no exercise, no scenes
  table. Momentum protected.
- **Revising:** the full letter.
- **Fresh Eyes** is always the full letter.

The stage is shown in the lane line ("Le Guin · drafting") so a writer who
wants the full letter mid-draft knows to ask for Fresh Eyes, and the ask
field overrides dosage for its own answer — a worry asked about is answered
in full whatever the stage.

## 4. Le Guin (the voice)

### 4.1 The seat

The coach is a **preset that never enters the ladder's array**
(`ReviewPass.coachPreset`, id `workshop`, name Workshop, editor Le Guin, her
own brief) and the seat is a **manifest field**: `ProjectManifest.coachVacated:
Bool`, tolerated-missing and false by default, read through
`effectiveCoach: ReviewPass?` (nil when vacated). *(Plan-time revision of
this brainstorm's `ReviewPass.role`: Project Settings has no preset picker —
"Add Pass" appends a blank pass and the presets return only when the list is
emptied — so "fill the seat like any preset" was never true, and a role on
the pass would have made every reader of `effectiveReviewPasses` decide
whether it meant stages or stages-plus-coach.)*

Because the coach is not in `effectiveReviewPasses`, everything that reads
the ladder is unchanged **by construction**: `ReviewStatus.derived` walks
stages only (no finished piece flips to revising when she arrives), the
board's chips and Done / Skipped menus never see her, `ActivePassMemory.
validatedActivePass` refuses her id, the cockpit's lane picker never offers
her, and `get_outline`'s `review_passes` is the ladder as before. What she
*is*: a pass in every respect the compiler cares about — an id, a brief, an
editor name resolved through `effectiveBrief` / `effectiveEditorName`, a lane
in the diagnostics sidecar, numbered rounds, pass-stamped notes. A stage may
never carry her id (the pass editor refuses to save one).

A project that never customized its passes and one that did both have the
seat filled, with no migration (tripwire 11). **Vacating the seat** (a Coach
row in Project Settings, above the ladder, with Vacate / Restore) is the one
off switch: an unassigned piece goes back to the all-altitudes reader signed
"Claude", writing a letter under the general instruction only. Her rounds
stay in the sidecar as history. There is no experience-level switch — the
seat is the writer's declaration of what kind of writer they are.

**Where the seat is seen.** The board draws a **seat row above the ladder**
(*Le Guin reads any piece with no editor assigned*, or *The seat is vacant —
an unassigned piece gets the plain reader*); the board has no selected piece,
so it says nothing per piece. The **cockpit**, which is per piece, uses the
coach's name as its lane label when the piece is unassigned and the seat is
held (*Le Guin · round 3*, or *Le Guin reads this piece* before her first
round), where today it reads *Set a pass*. Author's spelling is §4.2.

**The resolution has one spelling.** `ProjectManifest.reader(forPiece:memory:)`
(a Mac-side extension, because `ActivePassMemory` is the Mac's) answers a
`PieceReader` — *stage pass* / *coach* / *nobody* — for a piece, and every
reader calls it: the orchestrator's `activePass` closure, the Author header
(§4.2), the empty-state sentence, the round lines, the annotation author
stamp. `passlessEditorName` survives only as the *nobody* arm's name. A
stored active-pass id that no longer names a pass already reads as
unassigned (`validatedActivePass`); under this rule that hands the piece to
the coach rather than to "Claude" — deleting a pass gives its pieces back to
Le Guin, which is the right default and is stated here so it is not a
surprise.

**Rounds.** Today the passless lane (`nil`) mints no round number. A run over
an unassigned piece with the seat held resolves to the coach as its active
pass, so it files into the **coach's** lane (`workshop`) and mints a round
through the machinery a stage run already uses — the since-line and "Le Guin
· round 3" exist with no orchestrator change. The `nil` lane keeps its M2
meaning for the seat-vacant case.

**What this means in Author.** The active pass is per piece, set in Review
and read by ⌘R everywhere; Author has never chosen a reader and still does
not. So: a writer who never opens Review has every piece unassigned and every
⌘R is Le Guin's (§9's day one, unchanged). A writer finishing chapter 1
through Lish while drafting chapter 5 gets Lish on chapter 1 and Le Guin on
chapter 5 without touching anything — the frontier is coached and the
finished work is edited. Getting the coach back on an assigned piece is a
trip to Review to set the chip back to untouched, exactly as changing editors
is today. Fresh Eyes (⌘⇧R) follows the same rule: on an unassigned piece it is
Le Guin's full letter over the whole piece, the classic shape; on an assigned
piece it is that editor's cold read, as today. A warm round's letter is about
the delta and says so in its lane line, as the header already does for counts.

### 4.2 The reader line (Author)

The Diagnostics pane header carries a **reader line** naming who a ⌘R on this
piece will brief — *Le Guin reads this piece* · *Lish · Line* · *Claude* —
read off `reader(forPiece:memory:)`. The empty state's promise ("Press ⌘R and
Le Guin reads what you've written"), the running line and the finished
round's lane line read the same resolution, so the header, the promise and
the result cannot name three different people. It is a label, not a picker;
a click travels to the board in Review with the piece selected. Author's rule
— the reader is chosen in Review — is kept, not weakened.

### 4.3 Depth, in both homes, four deep

The gear menu that picks the model (`CompilerModelChoice`, per project in UI
state, guide: "Choosing how hard it looks") lives only in the Diagnostics
header today, so a chip-run in Review uses whatever Author last set with no
way to see or change it there. The menu becomes one shared view, mounted in
the **cockpit** beside the lane picker and bound to the same project value
through the same change closure — one stored value, one "the next check
changes" rule. The board pane does not need it; runs start from the cockpit.

A fourth choice joins Fast / Standard / Deep: **Exhaustive**, mapping to the
`fable` alias (confirmed accepted by the installed CLI's `--model`, which
names `fable`, `opus` and `sonnet` as aliases). Same session mechanics; the
guide's paragraph gains a sentence on what it is for (a Fresh Eyes over a long
piece, a book letter later). `CompilerModelChoice` is a raw-string enum in a
derived, per-device UI-state file, so an older build reading `exhaustive`
back fails the field, not the file: the plan gives the field the ADR 0015
tolerant-decode shape (unknown → `.standard`) rather than letting a
preference cost the rest of UI state.

### 4.4 The brief

**The brief** (doctrine, first draft — the plan refines the prose): Le Guin
reads as a teacher, not an editor. She attends to the sound of the sentences
and their rhythm; to point of view and whether it holds; to what the reader is
made to feel and where that feeling is earned. She writes the letter as the
main event and names what works before what doesn't, because a writer who
cannot tell their good sentences from their bad ones will revise the good ones
away. Her line-level output is questions only — never a suggested change,
never a rewrite, never a correction; a misspelling is Gould's and a scene out
of order is Perkins's, and she says so rather than doing their work. She is
allowed to disagree with the piece's declared intent, but only by asking. When
the process signals (§5) say the frontier has not moved, she may say so in her
own words with the numbers behind her, once, and without scolding. The
writer decides.

**The writer's own bar.** The general letter instruction (every voice) says:
when the pinned shelf holds the writer's own pieces — a prior chapter, a
published story — measure against those by name, before any rule. *This
chapter is slacker than your chapter 4; the dialogue in the pinned story is
doing something this one isn't.* An experienced writer's "what's working" is a
comparison to their own best work, and the shelf already lets them pin it.

## 5. Process signals (Maugham's own observation)

Deterministic, computed off the op log alone, no model involved. A pure
`ProcessSignals` value over the document's ops (walking by `sequence` through
the existing rewind machinery, never raw paragraphs), where every op already
carries its `session` id and `at` date — that is the per-document session
evidence. `SessionLog`'s events are project-level (start, end, net words,
device) with no document id, so they are not an input here; they stay the
Statistics window's own.

- **frontier** — the last position in the document where *new* paragraphs
  were added, and the session in which that happened.
- **churn** — edits per paragraph over the last N sessions, so "the opening
  five paragraphs have been rewritten nine times" is a number.
- **forward motion** — sessions since the frontier last moved.
- **time away** — days since the document's last session; past a threshold
  (14 days) the briefing says this reads as a cold read, and Le Guin may say
  so — King's drawer, observed rather than prescribed.

Two surfaces, per the every-data-type-gets-a-surface rule:

1. **Statistics window — a Practice section** beside the existing daily
   heatmap / sessions / words-by-chapter: frontier, churn hotspots (top three
   paragraphs by rewrite count, as jumps), sessions since the frontier moved.
   Screenplay-shaped where the project is a screenplay (the existing stats
   render novel-shaped; the Practice section does not repeat that).
2. **The briefing** — a short `Process` section, only when a signal is
   noteworthy by a plain threshold (frontier unmoved for ≥ 3 sessions, or one
   paragraph rewritten ≥ 5 times in the last 5 sessions), so the letter's
   `process` line has real numbers behind it and a quiet session produces no
   line at all.

Nothing about the signals appears in the footer, the tree, the editor or as a
badge. They are read in the window the writer opened and the letter the writer
asked for. Constitution must #2 in full.

## 6. The lessons ledger

A fourth `Statement.Kind`, `.lessons` (raw `lessons`), **project scope only**,
hosted through the same `StatementPane` / `StatementEditorHost` as intent,
visual language and the edition brief — the writer's own prose, op-logged,
rendered clean on disk like any statement. The pane title is "What I've
learned". It is a `DetailSegment` case (`.lessons`) in **Author and Review**,
beside `.intent` in both — the two personas where a lesson is learned and
applied — with a place in `PersonaPaneRegistryTests.canonicalPaneOrder` and a
`⌘⌥` shortcut the plan assigns off `MaughamApp`'s live bindings. `.unknown`
tolerance means an older build (and the phone) retains and ignores it.

**Two doors in:**

- **Keep as lesson** on a letter's habit (the `lesson` line, or the writer's
  own edit of it), and on an accepted craft note in the queue. Files a dated,
  itemized entry through `RulingPerformer.rule` with `kind: .lessons` — the
  shape rulings already have, with provenance naming the voice and lane.
- Typing. It is a statement.

**One door out:** every briefing carries the ledger beside the intent essay
and the bible (`CompilerPrompt` gains a `lessonsSection`; the hash covers it so
a changed ledger is a changed briefing), and the schema tells the model that a
recurring habit the ledger already names is reported with that heading verbatim
and `lesson: null` — the letter says *this is the one we talked about* instead
of rediscovering it.

**Trajectory, both ways — proposed, never automatic** (2026-09-01, revising
this brainstorm's three-consecutive-rounds rule). The ledger is the writer's
prose and moves only by the writer's hand, the rule rulings already keep; the
model's job is to *notice*, the letter's job is to *offer*. The briefing
carries every open lesson; the schema asks the round to name, in `retired`,
any lesson it looked for and found no instance of. A **warm** round renders
that as a line (*I didn't find a filter word in what changed*) and nothing
more — a three-paragraph delta proves nothing about a habit. A **Fresh Eyes**
round, which read the whole piece cold, renders each as an offer: *I didn't
find a filter word anywhere in this chapter* with a **Retire** button that
files a dated retirement on that entry through `RulingPerformer` (in place —
never deleted; a retired habit can come back and the entry says when it
left). The offer carries the ledger heading verbatim, so what is retired is
exactly the entry the round was briefed on and never a near-miss the model
re-spelled. An offer the writer lets go is gone with the letter. No counter,
no ring dependency, and nothing that has to reconcile a project-scoped
ledger against document-scoped rounds — the whole-piece read is the
evidence, and the writer is the judge.

**Choices are the negative space of lessons.** A habit the writer treats as
deliberate becomes a **choice**, filed in the same ledger under its own
heading with the same `RulingPerformer` shape and provenance — and, again,
only by the writer's verb. Two doors: the queue's **This is a choice** verb on
a Le Guin question (a stet that also files), and a second stet on a question
carrying a ledger heading, which offers *Make "fragments" a choice?* rather
than filing on its own — the offer carries the heading, so identity is exact,
and a plain stet stays a plain stet. For the offer to be possible, a minted
question **carries the habit heading it was raised under** (`CompilerNote`
gains an optional `lessonHeading`, stamped at ingest from `habits[].name`
when the letter's question cites a habit; nothing else in the annotation
changes). The briefing carries choices as a list of things *not* to raise; a
round that raises one anyway is a defect the fingerprint dedupe backstops.
Voice is the sum of choices; a coach who keeps flagging your voice is a bad
coach — and for an experienced writer this list matters more than the
lessons. A Fresh Eyes over a finished piece followed by **These are all
choices** on its habits seeds the list in one act rather than six stets.

**MCP:** `read_lessons`, a fourth spine reader on `read_craft_intent`'s shape,
through the same `ProjectStore.statementText(of:)`; count moves by one.
`list_all_links` / `find_references` already scan statements.

## 7. Shape of the work

One milestone, three plans, written one at a time against built code (rule
11); each under ~10 tasks (rule 12).

- **P1 — the letter and Le Guin** (§3.1–3.6, §4): section schema + ingest,
  `CompilerRun.letter`, question minting, say-back / one thing / exercise
  (Accept as task), the five preset briefs revised incl. own-bar comparison
  and voice distinctness, the coach preset and `coachVacated`, the seat (board row,
  cockpit label, Project Settings row, `reader(forPiece:memory:)`,
  coach-lane rounds), the Author reader line, depth in the cockpit and the
  Exhaustive choice, the three-position scenes derivation, Diagnostics
  Letter section, cockpit disclosure, Keep this letter.
- **P2 — the ask and the ledger** (§3.7, §6): Ask about… in both homes;
  `.lessons` kind, pane, Keep as lesson / These are all choices / the stet
  route, retired lessons, briefing sections for lessons and choices, the
  cite-by-heading rule, `read_lessons`.
- **P3 — process and dosage** (§3.8, §5): `ProcessSignals` incl. time away,
  the Practice section, the briefing thresholds, the letter's `process` line,
  the derived draft stage and its dosage. Last because dosage needs the
  frontier and the `process` line needs the letter.

Schema: no manifest bump. `.lessons` is a new kind on the existing statement
op; `CompilerRun.letter` is an optional field on a derived sidecar. No paired
phone release is forced.

## 8. Constitution check

- **The words are safe:** nothing here writes manuscript text. A letter is a
  sidecar record; a kept letter and a lesson are research/statement prose the
  writer owns.
- **AI is never the author:** Le Guin mints questions only; the letter is
  read, never applied. Keep-as-lesson files the writer's own edit of a line.
- **No AI inside the editor:** the letter renders in Diagnostics and the
  cockpit; refs are jumps, not marks. ADR 0027's terms hold.
- **Get out of the way:** ⌘R/⌘⇧R remain the only triggers; process signals
  are never pushed; a quiet session produces no line.
- **Lenses, not gates:** the seat never blocks and never counts toward
  final; a beginner who never opens Review still meets Le Guin, because every
  piece they have is unassigned.
- **Nothing required up front:** the ask field, the ledger, exercises, the
  stage and the signals are all met by doing the thing before them. The
  day-one loop is *write, ⌘R, read a letter* — §9.

## 9. The author's experience — the loop this must stay

**Day 1.** New project → Novel → 800 words. The getting-started tour and the
empty Diagnostics pane say the same sentence: *Press ⌘R and Le Guin reads
what you've written.* ⌘R → "Checking 12 new paragraphs…" → the pane opens in
Author. No intent, so no conformance; a continuity question lands; the letter
arrives and renders at the top: say-back, the one thing, two things that work
and why, one habit with four jumps, one question (also in the queue), an
exercise. Click a jump; the editor goes there. Write, ⌘R, read a letter —
nothing else needs to exist yet.

**Week 1.** Drafting — the frontier moves every session — so letters stay
short. A worry typed into Ask about… is answered first next round. Keep as
lesson: a capsule confirms, nothing opens. The ledger is found later, through
the pane picker, holding three dated entries in the writer's own words.

**Week 3.** Chapter 1 rewritten for five sessions. Nothing nags. The next
⌘R's letter says, once: *the opening's been rewritten nine times and nothing
past chapter 3 has moved in three weeks — is that where the book is, or where
it's comfortable?* Statistics' Practice section has the same numbers for
anyone who goes looking.

**Week 6.** An exercise accepted as a task, done, ⌘R: *I didn't find a filter
word anywhere in this chapter* — retired. Fragments stetted twice → *Make "fragments" a choice?* → yes;
never raised again. The board in Review shows Le Guin's seat lit above the
ladder and Structural first on it; Perkins's chip gives a structural letter
with a scenes table, and the Author header now reads *Perkins · Structural*
for that chapter while the next one, unassigned, is still hers. The
graduation is clicking a different name, not learning a system.

**The experienced writer** touches different knobs on the same system:
vacates the seat (an unassigned piece goes back to "Claude"), pins their
own prior work so "what's working" is a comparison to their own bar, seeds
choices in one act, authors a custom pass brief for the hostile reader they
want, and uses the ask field for opinion on request. Their real letter — the
whole book — is §10.

## 10. Follow-on: the book letter

An experienced writer's problems live at 80,000 words — a subplot dropped in
the middle third, a motif that stops paying, an arc that flattens — and no
delta or single-piece Fresh Eyes can see them. **The book letter** is Fresh
Eyes at project scope: a chosen voice reads the whole project cold and writes
one letter with a whole-book scenes/arc table, whose natural home is the
altitude view. It is the milestone after this one, and gets its own brainstorm:
cost and cancellation of a cold read over a novel, what the table looks like at
that altitude, and whether Perkins's brief is the right default.

## 11. Out of scope

- Phone surfaces (statements and annotations are read through existing
  tolerance).
- A writer-editable brief for Le Guin beyond what custom passes already have.
- Sub-paragraph anchors for letter refs (problem map: still open).
- Any letter from the translator or designer orchestrators.
