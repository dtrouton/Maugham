# The editorial letter — Le Guin, habits, lessons, and the writer's own process

**Date:** 2026-08-29 · **Status:** approved in brainstorm, plans unwritten
**Session:** "coach"

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
- The coach is **Le Guin** (pass id `workshop`, name Workshop).
- **A passless ⌘R briefs Le Guin.** `CompilerOrchestrator.passlessEditorName`
  changes from "Claude" to "Le Guin". "Claude" was only ever the absence of a
  voice; a passless run *is* the beginner's run. The continuity / bible /
  reader machinery still runs beneath any voice.
- **Scene function is three-position, not opt-in** (§3.4): the weak form
  ("what changes") is the prose default; McKee's strong form (value charge,
  conflict-driven turn) is the screenplay default and prose opt-in through
  intent; a lyric/essayistic intent opts out of the rows entirely.
- Letters are derived and age with the rounds ring; **Keep this letter**
  makes one durable (§3.6). Mirrors rulings: durable only when the writer acts.
- Process signals never appear unprompted (§5) — constitution must #2.
- Lessons are project-scoped only (§6). Habits belong to the writer, not the
  chapter.

## 3. The letter (mechanism)

### 3.1 A sixth report section

The compiler's report is streamed as fixed-order sections
(`conformance, continuity, reader, facts, intent_drift` —
`CompilerPrompt.sectionSchemaDescription`). The letter is a sixth section,
`letter`, last, so the writer is reading line-level results while the letter
is still being written — the same tempo the guide already promises.

```
{"section":"letter",
 "working":  [{"refs":[¶id…], "what":<string>, "why":<string>}],      // ≤3
 "habits":   [{"name":<string>, "refs":[¶id…], "cost":<string>,
               "lesson":<string|null>}],                              // ≤2, ≤4 refs each
 "questions":[{"refs":[¶id…], "question":<string>}],                  // ≤3
 "scenes":   [{"refs":[¶id…], "wants":<string|"">, "changes":<string|"">,
               "turn":<string|"">, "charge":"+"|"-"|null}] | null,
 "process":  <string|null>}
```

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
rows thereafter. The letter keeps its own copy of the question text for
reading in place; disposition lives in the queue only (one home per finding,
the one-loop spec §8).

### 3.3 Who writes one

Any round can. The briefing tells the model what a letter is for, and each
preset brief says whether that pass writes one:

- **Le Guin** (§4): the letter is the main event; every part is hers.
- **Perkins**: `working`, `habits` (structural habits), `scenes`; no questions
  beyond his existing continuity questions.
- **Lish**: `working`, `habits` (sentence habits); no `scenes`.
- **Gould, Argus**: leave the letter empty. Their briefs say so.
- A **custom pass** with a writer-editable brief writes whatever its brief
  asks; with no brief, the general instruction applies and the model decides.

### 3.4 Scenes — the three-position default

`scenes` is computed only when the run's briefing says the piece moves by
scenes, and in which form:

| Project type | Intent says | Rows | `charge` |
|---|---|---|---|
| prose | nothing about form | yes — weak form: wants / changes / turn as observation | `null` |
| prose | moves by dramatic turns / conflict / "every scene must turn" (or the pass brief says so) | yes — strong form | `+`/`-`; a turn-less scene is also raised as a **conformance strain** against that clause |
| prose | lyric / essayistic / meander / "not scene-driven" | none (`null`) | — |
| screenplay | nothing | yes — strong form | `+`/`-`; turn-less scene is a strain |
| screenplay | opts out explicitly | none | — |

The prompt derives the position from `ProjectType` and the intent essay; the
model is told which position it is in and never asked to infer it. In the weak
form a blank `changes` cell is an observation — Le Guin's letter may ask
"nothing shifts here that I can see; is that the point?" — and never a strain.
Weak-form rows carry no "conflict" field at all, on purpose: the doctrine the
default encodes is the near-consensus one (something should change), not the
disputed one (it must be a conflict-driven reversal).

### 3.5 Rendering

- **Author — Diagnostics pane (⌘⌥D):** a **Letter** section at the top,
  above This check and Conformance. The letter is what the writer reads
  first; the notes are the margin. Parts in order: working, habits, questions
  (each row a jump to its first ref, with "and N more" for the rest),
  scenes (a compact table, blank cells blank), process (one line). Signed with
  the voice's name and the round's lane line. An empty letter draws no section.
- **Review — the round cockpit:** the letter's first `working` or `habits`
  line under the lane line, with a disclosure that opens the same section
  inline. Nothing about the cockpit's buttons changes.
- **Rounds ring:** the cockpit's "since round N−1" is unchanged; a previous
  round's letter is reachable from the ring the way its counts are.
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

## 4. Le Guin (the voice)

A fifth preset in `ReviewPass.presets`, **first** on the ladder:

```swift
ReviewPass(id: "workshop", name: "Workshop", brief: workshopBrief, editorName: "Le Guin")
```

Because presets resolve through `effectiveBrief` / `effectiveEditorName` and
`ProjectManifest.effectiveReviewPasses` returns the presets whenever the stored
array is absent, a project that never customized its passes gains the pass on
load with no migration (tripwire 11). A project that **did** customize keeps
its stored array as-is — the Workshop pass is available to add from Project
Settings like any preset, and the passless run briefs Le Guin regardless, so no
writer is without her.

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

**Passless runs:** `passlessEditorName = "Le Guin"`; the passless briefing
carries the Workshop brief the way a Workshop round does. The one-loop spec
§4's line "a passless ⌘R briefs no register — the M2 all-altitudes reader" is
superseded by this document. Existing notes signed "Claude" are untouched;
they are history.

**Fresh Eyes (⌘⇧R)** with Le Guin is the full editorial letter over the whole
piece — the classic shape. A warm round's letter is about the delta and says
so in its lane line, as the header already does for counts.

## 5. Process signals (Maugham's own observation)

Deterministic, computed off the op log and the session log, no model involved.
A pure `ProcessSignals` value over the document's ops (walking by `sequence`
through the existing rewind machinery, never raw paragraphs) and
`SessionTracker`'s sessions:

- **frontier** — the last position in the document where *new* paragraphs
  were added, and the session in which that happened.
- **churn** — edits per paragraph over the last N sessions, so "the opening
  five paragraphs have been rewritten nine times" is a number.
- **forward motion** — sessions since the frontier last moved.

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
learned". `.unknown` tolerance means an older build (and the phone) retains and
ignores it.

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

**MCP:** `read_lessons`, a fourth spine reader on `read_craft_intent`'s shape,
through the same `ProjectStore.statementText(of:)`; count moves by one.
`list_all_links` / `find_references` already scan statements.

## 7. Shape of the work

One milestone, three plans, written one at a time against built code (rule
11); each under ~10 tasks (rule 12).

- **P1 — the letter and Le Guin** (§3, §4): section schema + ingest, `CompilerRun.letter`,
  question minting, the five preset briefs revised, the Workshop preset,
  passless = Le Guin, the three-position scenes derivation, Diagnostics
  Letter section, cockpit disclosure, Keep this letter.
- **P2 — the lessons ledger** (§6): the kind, the pane, the two doors,
  the briefing section, the schema's cite-by-heading rule, `read_lessons`.
- **P3 — process signals** (§5): `ProcessSignals`, the Practice section, the
  briefing threshold, the letter's `process` line. Last because its letter
  line is why it exists and the letter must exist first.

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
- **Lenses, not gates:** the Workshop pass never blocks; a beginner who never
  opens Project Settings still meets Le Guin through a passless ⌘R.

## 9. Out of scope

- Phone surfaces (statements and annotations are read through existing
  tolerance).
- A writer-editable brief for Le Guin beyond what custom passes already have.
- Sub-paragraph anchors for letter refs (problem map: still open).
- Any letter from the translator or designer orchestrators.
