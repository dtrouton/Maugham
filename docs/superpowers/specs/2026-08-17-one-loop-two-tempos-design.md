# M4 — One loop, two tempos: the compiler and the review passes meet

*Brainstormed with Denver 2026-08-16/17, out of his first real M3 smoke on
Playlist. Supersedes nothing wholesale; amends ADR 0028's framing (§3) and
corrects one M3 design decision Denver has ruled against (§2). The prompt
half is empirically grounded: six briefing variants were run over
`Playlist/pieces/02-tribute` on 2026-08-17 and every mechanism this spec
ships was validated there — the assessment is the spike record
(`prompt-spike-assessment.md`, session scratchpad; its findings are inlined
where they bind).*

## 1. The problem

M2 built the **compile** loop: drafting-tempo, minutes-scale, ⌘R checks wet
ink against the writer's declared standard, report beside the prose. M3
built the **review** loop: revision-tempo, pass altitudes, a queue with the
full disposition vocabulary, a board, rounds. They shipped as two products
with a wall between them, and Denver's first real smoke hit every seam:

- **Output and input never meet.** Compile produces diagnostics (ephemeral,
  per-device, pane-only); Review consumes annotations (durable, op-logged,
  queue). ⌘R in Review runs a round whose findings land in a pane Review
  does not offer; the queue only fills if the writer goes to Claude Desktop
  and asks. The board's symbols promise a workflow the app cannot start.
- **The verbs live on the wrong side of the wall.** The queue has
  do/decline/discuss, accept/reject/stet, bulk, undo. The pane has promote
  and answer — and reader reports withhold answer, so a reader note the
  writer disagrees with has exactly one button: promote it into a task they
  don't want.
- **Memory is asymmetric.** Diagnostics are superseded wholesale, so a
  declined-in-spirit note can recur forever and the model is never told the
  writer already said no.
- **Trigger, progress, and guidance are asymmetric.** Author: one
  keystroke, visible progress, results in place. Review: chips that set
  state but run nothing the writer can see; a flash and then silence.

Underneath: these are one loop at two tempos, and the wall is accidental.

## 2. The principle — findings routed by nature (Denver's correction)

**A finding that is a note on the prose is an annotation. A finding that is
a verdict about the draft-vs-standard relationship is a report.** One
finding, one home, one disposition — nothing is ever mirrored across the
two (the lifetimes are incompatible: annotations are durable and synced,
diagnostics are per-device scratch the next run replaces).

| Finding | Nature | Home |
|---|---|---|
| Continuity question | note on the prose | **annotation** (op log, queue, margin) |
| Reader report | note on the prose | **annotation** |
| Conformance clause summary (holds/strains/silent) | verdict about the standard | report (diagnostics sidecar) |
| Conformance strain detail | verdict — its disposition is a **ruling**, not a triage | report |
| Intent-drift verdict | verdict | report (+ the strip mark) |
| Since-last-round comparison | verdict | report |
| Bible fact candidates | silent accretion | bible (unchanged) |

- Compiler-minted annotations are **pass-stamped** with the piece's active
  pass, carry run provenance (`runId`, `round`, `freshEyes`) on the op, and
  arrive through Maugham's own ingest — **the spawned model's tools remain
  read-only; nothing about ADR 0028 §2's two-flag confinement moves** (§3).
- They are ordinary annotations thereafter: margin cards in Author, queue
  rows in Review, triage/stet/decline/bulk/undo everywhere, synced, ADR
  0023 undo conventions. The writer disposes; the compiler never does.
- **Strains stay report-side by decision**: a strain's disposition is
  answering it (→ a ruling) or letting it stand; putting it in the queue
  would give it triage verbs that cannot answer it. The diagnostics pane
  slims to the report: clause summary + strains (answer/promote), drift,
  since-last-round, run state, cold-start offer. Continuity and reader rows
  leave it entirely — which also dissolves the reader-can't-be-dismissed
  defect: *decline with a reason* is the queue's native verb.
- `DiagnosticPromotion`'s remaining scope is strains only.

**One issue, one open annotation, across rounds.** A round never re-mints an
issue that is already an open compiler annotation on the piece — open notes
are briefed as standing (§5), so the model confirms rather than duplicates.
The since-last-round header then means: **resolved** = compiler annotations
closed since the previous round (any resolution), **persisting** = still
open, **new** = minted this round. Clause-level comparison keeps its
existing fingerprint machinery on the report side.

## 3. The constitutional accounting (ADR 0028 amendment)

The compiler's Claude still cannot write anything: `--tools ""`,
read-only allowlist, no statement writes — all censuses unchanged. What
changes is what **Maugham** does with the parsed report: the app
materializes note-natured findings into the annotation layer, exactly as it
already materializes fact candidates into the bible and kept notes into
tasks. The annotation layer is Claude's designated channel (`add_comment`
et al. already write it from Desktop); every annotation remains the
writer's to accept, reject, or stet. "AI is never the author" holds: the
manuscript is reachable from none of this, and the yardstick (statements)
still admits only `RulingPerformer` with a writer-typed sentence. An ADR
records this as an amendment to 0028 §3's framing: *the compiler reads and
never writes — and its report is materialized by the app into the layers
the writer already governs.*

## 4. Pass briefs — one editorial doctrine, two readers

- `ReviewPass` gains `brief: String?` (Core, additive, tolerant decode).
  Presets ship seeded briefs adapted from the editing-pass skill's
  registers — Structural (structure, pacing, stakes, POV, whether scenes
  earn their place; no sentence notes), Line (rhythm, diction, echoes,
  filtering words, imagery), Copyedit (grammar, punctuation, continuity of
  name/timeline/fact; **diegetic-error rule**: in an unconventional form,
  apparent errors may be the piece's own — query, don't correct), Proof
  (typos, layout artifacts, nothing else). A writer edits a pass's brief in
  the pass editor; custom passes with no brief get the honest fallback:
  *attend at the altitude the pass's name suggests*.
- **The compiler embeds the active pass's brief** in the round briefing
  (spike-validated: attention follows the register; a copyedit round
  queried `AGNETS.MD` instead of correcting it).
- **The Desktop reader reads the same doctrine**: `get_outline`'s
  `review_passes` entries gain `brief`, and `docs/skills/editing-pass/
  SKILL.md` is rewritten to read the ladder, the pass states, and the
  briefs instead of carrying its own register copy and inferring the pass
  from the derived status. Vocabulary yields to the app's: the skill's
  "developmental" register becomes the Structural brief's content.
- A passless ⌘R (no active pass) briefs no register — the M2 all-altitudes
  check, unchanged.

## 5. The briefing — five spike-validated additions

1. **The pass brief** (§4), when a pass is active.
2. **Reader bar**: most checks report zero reader entries — an empty array
   is the expected common case; raise one only on quotable words whose
   effect survives a second reading; judge an unconventional form by the
   rules it sets for itself.
3. **Cross-section dedup**: one issue gets one entry, in the section where
   it cuts sharpest (the spike's single biggest quality lever — it
   collapsed a five-entry fan-out and the freed attention found new,
   real questions).
4. **Drift stabilizer**: drift judges direction, not success; a straining
   clause is conformance's finding and must not flip the verdict
   (spike-observed: the structural framing alone flipped it).
5. **Dispositions and standing notes**: the round is briefed with the
   piece's open compiler annotations ("standing — confirm or let resolve,
   never re-raise as new") and its settled ones with the writer's reasons
   ("DECLINED: <reason>" / "STETTED" / rejected with `userResponse`).
   Spike-validated verbatim: a declined note with a reason was not
   re-raised in any section. Fresh Eyes omits this section along with the
   round section — cold means cold — so the one-open-annotation rule is
   enforced for every run by an **ingest-side dedupe backstop**: a parsed
   note whose fingerprint matches an open compiler annotation on the piece
   folds into it (confirms it) rather than minting a duplicate. On warm
   rounds the briefing makes this rare; on the fresh path it is the
   mechanism.

Total cost ≈ 180 words per briefing. The section schema itself is
unchanged — same five lines, same parser.

## 6. Rulings carry their context

A ruling minted by answering a note currently records provenance but not
the note — Tribute's intent now reads "The reader is supposed to read this
as it covering up" with nothing saying what *this* is. `RulingPerformer.
rule` gains the answered note's short quote/anchor excerpt, and the ruling
renders as *ruled on «excerpt»: <writer's sentence>*. Existing rulings stay
as written (tripwire 11 — no migration); the fix is for every ruling minted
from now on. The derivation and briefing read the enriched line as prose,
as today.

## 7. Review's cockpit — trigger, progress, results in place

- **The queue header becomes the round cockpit**: the active pass by name,
  its round number, and the affordance that teaches the loop — *"Run
  round N of <pass> (⌘R)"* — plus, while a run is in flight, the same
  progress the pane shows ("Checking N paragraphs…"), and afterwards the
  report header: since-last-round counts and the drift line. Compact,
  report-natured, above the notes.
- **⌘R keeps its meaning everywhere**; the cockpit is a second delivery
  site for the same event, exactly like the cold-start offer's Read
  button. ⌘⇧R (Fresh Eyes) appears beside it.
- **The board teaches too**: a chip's context menu gains "Run round
  (⌘R)" alongside set-state; empty states say what fills the queue (a
  round, or Claude Desktop) instead of showing a beautiful dashboard of
  nothing.
- Author is untouched in feel: same keystroke, same pane tempo — the pane
  simply stops showing rows that now arrive as margin cards, and the
  compiler's notes gain the full disposition verbs there via the cards and
  ⌘⌥A pane like any other annotation.

## 8. Denver's decisions of record (this brainstorm)

- Findings-as-annotations is the corrected design; the M3 spec's
  diagnostics-only routing "was not as designed." (§2)
- One home per finding; nothing mirrored; dispositions never sync across
  surfaces because nothing exists twice. (his sync question, 2026-08-16)
- Strains stay report-side; custom passes get writer-editable briefs with
  a name-based fallback. (accepted with "Go", 2026-08-17)
- The prompts were to be tested before being baked in — done, six-variant
  spike over Tribute, all five mechanisms validated. (2026-08-17)

## 9. Constitution check

- **The words are safe**: nothing writes manuscript text; annotations are
  ops with undo; the sidecar stays derived.
- **AI is never the author**: the model's tools stay read-only; the app
  materializes notes into the layer the writer governs; statements still
  admit only writer-typed sentences.
- **Keystroke-only**: ⌘R/⌘⇧R remain the only triggers; the cockpit posts
  the same events; no timers start anything.
- **Lenses, not gates**: passes still never block; briefs steer attention,
  never availability.
- **Get out of the way / nothing pushed**: the cockpit shows state the
  writer made; costs stay unsurfaced; the drift mark stays quiet.

## 10. Out of scope

- Phone surfaces (reads everything via existing tolerance; no new UI).
- Any new MCP tool; `review_passes.brief` is a widening of an existing
  read.
- Model-tier changes (opus default, per-pass models).
- Auto-resolving compiler annotations when a round stops raising them —
  the writer closes notes; the model only stops confirming.
- Compiler-initiated runs of any kind; inline gutter marks.

## 11. Sequencing — two plans (rule 11: P1 built before P2 is written)

- **P1 — the wire and the briefing**: `ReviewPass.brief` + preset briefs;
  compiler-annotation minting (op provenance: runId/round/freshEyes, pass
  stamp, one-open-annotation rule) + the pane slimming that must land with
  it (one commit — a finding must never appear in both homes); the five
  briefing additions incl. dispositions/standing notes; ruling context
  (§6); ADR amendment.
- **P2 — the surfaces and the doctrine served**: the Review cockpit
  (header, progress, report line, affordances), board chip run + empty
  states, `review_passes.brief` in `get_outline`, the editing-pass skill
  rewrite, guide/docs sweep (review-passes.md, compiler.md, right-pane.md,
  annotations-and-suggestions.md all move).
