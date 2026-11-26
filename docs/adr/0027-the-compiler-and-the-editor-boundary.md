# ADR 0027 — The compiler and the editor boundary: output location is identity, invocation locality is a position

**Date:** 2026-08-05 · **Status:** Accepted · **Milestone:** m2-author-compiler (branch `feat/m2-compiler-2026-08-04`)

## Context

`docs/constitution.md` must-not #2, **"No AI inside the editor"**, is marked *identity*:
"Claude lives in another window. No chat panel, no inline copilot, no ghost-text
completions from a language model, no AI margin whispering in the writing surface. The
friction of switching windows is a feature."

Its own falsification note already conceded one neighbour: *"a read-only companion pane
for Claude responses keeps feedback out of the editor while shortening the walk — that's
the permitted form of this pressure, not an erosion of the rule."* That concession is
about **where the answer appears**. It says nothing about **where the question is
asked**, because until M2 the question was always asked somewhere else — the writer
switched to Claude Desktop and typed it.

M2's compiler asks it from inside the writing surface. The design of record
(`docs/superpowers/specs/2026-08-04-m2-author-compiler-design.md`) opens with the
writer's own words — *"as near as live editor quality feedback on my writing while I'm
still in the mode, still writing"* — and the mechanism is one key, ⌘R, pressed with the
caret in the paragraph. The walk is now zero. Nothing about that is covered by the
concession above, and "AI feedback, one keystroke from the prose" is close enough to the
thing must-not #2 forbids that leaving the line to be re-derived by the next reader is
how it eventually gets crossed.

The rule was carrying two claims at once, and they are not equally firm. This ADR takes
them apart and says so on the record, which is what `docs/constitution.md`'s own closing
instruction requires: *"When a shipped feature and this document disagree, one of them is
wrong — decide which, on the record."*

## Decision

### 1. Output location is the identity invariant. Nothing AI-produced renders in the editor or its chrome.

This half of must-not #2 does not move, and no measurement would move it. The test is
literal and checkable at any commit: **if a string that came out of a language model is
drawn inside the editor surface or its immediate chrome, this decision was violated.**

What M2 shipped against that test:

- Diagnostics land in `DiagnosticsPane` (`DetailSegment.diagnostics`, ⌘⌥D) — the
  right-hand column, the constitution's own read-only companion pane, the same place
  annotations have always lived. No overlay, no margin note, no gutter mark, no
  ghost text, no decoration on the paragraph a note is about.
- A note's **click-to-jump** moves the *caret*. It reuses `AnnotationsPane`'s scoped
  reveal event rather than a copy (`Maugham/Views/DiagnosticsPane.swift`); the editor
  receives a position, never a payload.
- The **answer** flow (spec §5.2) sends the writer's own sentence — typed by the writer,
  in the pane — into the piece's intent statement through `IntentAppendPerformer`, as an
  ordinary op-logged edit performed by Maugham on the writer's action. No model output is
  anywhere in that path. *\[Correction, 2026-08-08: the performer is now
  `RulingPerformer.rule` — see the amendment below; the finding this bullet records is
  unchanged.\]*
- The **intent strip** (spec §6.1; built 2026-08-05, `Maugham/Views/IntentStrip.swift`)
  is the one AI-adjacent surface that sits physically above the prose, and it is not a
  counterexample: it shows the *writer's own* intent statement — the first line, headings
  skipped — an op-logged artifact the writer authored in the Intent pane. It keeps showing
  the writer's words and nothing else — structurally, not by convention: the view stores a
  single `String`, and the one producer of it is `ProjectStore.statementText(of:)`. A
  future version of that strip that displayed a diagnostic, a summary, or any
  model-produced line would violate this ADR and must-not #2 together, and no argument
  about convenience reaches it.

The reason this half is identity rather than taste is the one the constitution already
gives: an AI presence *in* the editor changes what the editor is — every pause becomes an
invitation to consult rather than to think. A pane the writer turns to is a place they
went; a line in the writing surface is a thing that arrived.

### 2. Invocation locality is a position: one keystroke while writing.

The trigger now lives in the writing context. ⌘R in the Author persona, with a real menu
item, delivered through `Maugham/Views/CompilerRunModifier.swift`. This is the
constitution's *"permitted form of this pressure"* taken one step further than the
sentence that permits it: the pane keeps the output out of the editor, and the keystroke
takes the walk to zero.

The argument that this does not erode the rule:

- **The mental-state boundary must-not #2 protects survives, and is still physical.**
  Writing-mode and feedback-mode remain different states, separated by a deliberate act
  (a key the writer chooses to press) and by a physical destination (a different column,
  which may be closed). What M2 removes is *window management*, which was never the thing
  worth protecting — it was the proxy available in 2026-05.
- **Nothing arrives unasked.** See §3. The friction that mattered was the friction of
  being interrupted, not the friction of navigating.
- **The output rule does the real work.** With §1 held absolutely, a nearer trigger
  cannot produce the failure must-not #2 describes: there is no margin to whisper in and
  no completion to accept.

**This is a position, and here is its bar.** We would know it was wrong if the mere
availability of ⌘R changed how writers draft — pausing mid-paragraph to compile instead
of finishing the thought, or writing *toward* the compiler's approval. That is a
behavioural symptom with an observable shape (runs clustering inside paragraphs rather
than at their ends; a writer reporting they can't leave it alone), and the response is
graded rather than binary: move the trigger out of the writing context — to the pane's
own header, or behind the persona switch — before touching §1, which is not available to
trade.

### 3. On demand, never continuous — and that is constitutional, not stylistic.

**The keystroke is the only trigger.** No run on a pause, on a save, on a paragraph
boundary, on a timer, on open. This is frequently mistaken for a performance decision or
a first-version simplification, and it is neither. It is
`docs/constitution.md` must #2, **"Get out of the way"** — *"Metrics… are available when
sought and never pushed: no streaks, no badges, no nagging"* — applied to the most
naggable surface Maugham has ever had. A background linter for prose is a metric that
pushes, arriving with an opinion about a sentence the writer has not finished. It also
runs straight into must-not #2's *"every pause becomes an invitation to consult rather
than to think"*, which is precisely what a pause-triggered run would make literal.

The code carries this rather than merely intending it: every timer in
`Maugham/Compiler/` exists to *end* a session, never to start one, and
`CompilerOrchestrator.ensureRunner` is reachable from `runRequested` and nowhere else.
Entering the Author persona does not start a session; only a run does.

Consequently, continuous or background compilation is **excluded, not deferred** (spec
§11). A future proposal for it does not get to cite latency improvements or model quality
as new evidence, because neither is the reason for the rule. It would have to win against
must #2 and must-not #2 directly, and this ADR is on the record as having chosen the
opposite deliberately.

## Consequences

- The constitution's boundary note is amended (see the edit landed with this ADR) so the
  in-context trigger is covered by the document itself and not only here. That is the
  resolution path the constitution specifies for a position under pressure: an edit, on
  the record, not a silent exception.
- Any future Author surface — the intent strip, the References shelf, the assistant
  column — inherits §1 as a hard test at design time, not a review comment. "Does a
  string from a model render here?" has a yes/no answer, and yes stops the design.
- The diagnostics pane's four fates (fix / ignore / promote / answer) are all *writer*
  acts, and the two that write anything durable write the writer's words: a promoted note
  becomes an op-logged task, an answered one becomes a paragraph of the writer's intent.
  Neither is a channel for model text into a durable artifact, which keeps must-not #1
  ("AI is never the author") untouched by this milestone.
- A named, falsifiable trigger-locality bar exists (§2), so if the pressure is real it
  will be argued against a symptom rather than a preference.

## Amendment, 2026-08-07 — the declared world and the derived bible

*Appended, not rewritten. What this ADR decided on 2026-08-05 stands as the record of
that decision; the paragraphs above are left exactly as they were, including the
sentence the second bullet below supersedes. Binding position:
`docs/superpowers/specs/2026-08-07-compiler-second-draft-design.md` §3.4.*

The second-draft spec tightens §1's membrane rather than crossing it, and gives
Claude's readings a new home this ADR did not describe: a persistent, subordinate
stratum of the writer's own statement document.

- **The answer flow moved, and Consequences' third bullet is superseded by the
  move.** *"An answered [note] becomes a paragraph of the writer's intent"* is no
  longer how it lands: `IntentAppendPerformer` is now a shim over
  `RulingPerformer.rule` *\[Correction, 2026-08-08: the shim was deleted on
  `feat/run-rebuilt-2026-08-07`; `RulingPerformer.rule` is the only performer, and the
  membrane's one door\]*, which writes an itemized, dated line into the statement's
  `## Rulings` stratum rather than appending a bare paragraph to the essay (spec
  §3.4 names the old shape as *"the membrane's loosest point"* and this is the
  tightening). §1's finding is unchanged by the move — the string that lands is
  still the writer's own words, typed by the writer, in the pane, and no model
  output is anywhere in that path — but the destination now visibly marks itself
  as a decision (dated, carrying provenance) rather than reading as ordinary prose
  a later self could mistake for their own unprompted sentence.
- **The derived bible is a new kind of Claude-produced artifact, and it does not
  weaken §1.** Two caches now live under `.maugham/`: a per-scope reading of a
  statement into checkable clauses and rules (`DeclaredWorld`), and a project-wide
  ledger of facts read off the manuscript while checking it (`BibleFact`/
  `BibleStore`). Both are, by construction: **a persistent cache of readings**
  (they survive relaunch, unlike a diagnostic, which the sidecar drops the moment
  the next run supersedes it); **a subordinate stratum**, drawn so it cannot be
  mistaken for the writer's own — the Bible stratum's paper, ink, and
  `CanvasAccessibility.claudeTerm` accessibility label exist for exactly the reason
  the canvas's "straight means Claude" tilt does, so a reader or a listener can
  tell a reading apart from a ruling at a glance rather than by re-deriving it each
  time; and **never truth until blessed** — nothing in either cache is checked
  against as if it were the writer's declaration, and the only route out of the
  cache is the same membrane §1 already named, `bless`/`correct`/`rule`, each
  crossing as the writer's own act on visible text.
- **§1's literal test is unmoved.** Neither cache renders in the editor or its
  chrome; both live in the same pane a diagnostic already does, a place the writer
  turns to. A future surface that read `DeclaredWorld`'s clauses or `BibleFact`s
  as if they were the writer's declared standard — rather than context a *check*
  reads, or a reading the writer has not yet blessed — would be must-not #1
  arriving through a new door, and would fail this ADR exactly as a diagnostic
  drawn in the gutter would.

## Amendment, 2026-11-22 — the margin beside the text

The shell milestone (plan 5, Task 2) gives the margin beside the text a setting,
View ▸ Margin ▸ **Off** (the default) / **My Notes** / **Everything Flagged**, and
this amendment says where it stands against §1. §1's text above is left as written;
what follows narrows how its test is read, in three positions Denver approved on
2026-11-16.

- **A wordless, opt-in position mark derived from a check's or a round's item is
  permitted.** Everything Flagged draws one grey tick beside a paragraph carrying
  such an item, among those To resolve's selection shows: the same glyph whatever
  the item says, whatever its source, however many there are. It says *something
  here was raised* and nothing about what; what was raised is read in To resolve,
  where it always was. The writer turns it on; Off draws nothing.
- **A mark on a person's own note is permitted.** A person's words are not a
  model's. My Notes draws a dot beside a note a person wrote and a faint tint on its
  words. "A person" is read off the note's seal (`NoteOwner.isAPersons`, the one
  predicate): any person's author key, this writer's Macs or an admitted reviewer's;
  where no seal covers the line, the note's own human stamp, so a book older than
  the signed op log keeps its writer's notes. The assistant's, translator's and
  Maugham's keys are never a person's, whatever a note's stamp says.
- **Anything carrying model content is not.** A string, a count, or a colour that
  encodes what an item says stays out of the editor and its chrome. The overlay
  file draws no text (`MarginOverlayCensusTests.test_theMarginOverlayDrawsNoString`);
  a click on a mark moves nothing in the editor and shows the paragraph in To
  resolve.

**Precedents.** The line above the prose says "intent may trail the draft"
(`IntentStrip.mayTrailDraftMark`): a fixed app string set off by a check, never the
check's words. Brief's clause marks ([ADR 0037](0037-brief-and-the-pulled-up-thing.md))
are wordless underlines drawn from a mark's kind, ruled within must-not #2 on
2026-11-16. The tick is the same kind of thing, one surface nearer the text.

**The review render, as it stood, and the owner's answer.** Until this amendment
the review render (manual review mode, then read-through, [ADR 0039](0039-read-through.md))
drew every open note's text as a margin card beside the text, Claude's included,
in Claude's own colour (`EditorCoordinator+ReviewRender.swift`, `recomputeReviewMarks`;
`ReviewPalette.color(for:)`). §1 as written forbids that. Asked whether it should
stay (plan 5, Question 2), **Denver answered no (2026-11-22)**: the review render
draws a person's notes only, by the same predicate as the dots, and Claude's notes
stay in To resolve. Built in `EditorHost.reviewRenderSet`, which every push and pull
of the render's set reads (`MarginOverlayCensusTests.test_whatIsDrawnBesideTheTextAsksOnePredicate`).
Denver's answer was given for read-through. **The build's own ruling, kept by him
"for now" (2026-11-25)**, is that it holds wherever the review render draws, a reviewer's copy
(a posture that refuses the text) included: §1 does not ask which switch put the
render on, and narrowing it would draw Claude's words beside the text for a reviewer
and not for the writer. The task's reviewer recommended keeping it; a reviewer's
answer to Claude's notes stays in To resolve, where their posture allows it. If
Denver rules otherwise, `EditorHost.reviewRenderSet` takes the posture-forced case
as one argument.

## References

- `docs/constitution.md` must-not #2 ("No AI inside the editor" — the rule this ADR
  decomposes and whose boundary note it amends), must #2 ("Get out of the way" — §3's
  principle), must-not #1 ("AI is never the author" — untouched, see Consequences)
- Spec: `docs/superpowers/specs/2026-08-04-m2-author-compiler-design.md` §1, §3.1, §4.4,
  §6.1, §9.1, §11
- Spec: `docs/superpowers/specs/2026-08-07-compiler-second-draft-design.md` §3.4 (the
  amendment above), §7 (its own constitution check)
- [ADR 0028](0028-maugham-goes-outbound.md) — the other half of this milestone's
  constitutional accounting: what leaves the machine when ⌘R is pressed
- [ADR 0025](0025-persona-shell.md) — the Author persona and the pane registry the
  Diagnostics pane joins
- `Maugham/Compiler/AREA.md` — the enforcing sites for "the keystroke is the only
  trigger" (now Rules → "The two sentences, and the membrane" and "The session's lifetime")
