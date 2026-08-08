# The compiler's second draft — CLOSED, pending the full-loop smoke

*Final update 2026-08-08: Stage 3 is merged to local `main`. The second draft
is whole: the declared world, the run that briefs it, and now drift as the
promised pattern, converging bless/correct, streamed sections, the cold-start
offer, and a measured derivation deadline. The sixteenth consecutive
whole-branch Critical was the seam Stage 3 itself created — a preview you
could act on — shut at the store level with a byte-identical-sidecar test.
**78 commits ahead of origin. Nothing pushed, nothing tagged.***

## The full-loop smoke — what closes the milestone (all of it yours)

**The loop, warm:**
1. Type a chunk, ⌘R without pausing — "Checking N new paragraphs…", then the
   **conformance summary appears BEFORE the run ends** (streaming's only
   live proof; a CLI shape change fails silent, so this one matters).
2. Mid-run: notes are readable but carry **no Answer/Promote** — the
   affordances arrive when the run finishes. Answer one then; it lands as a
   ruling; the NEXT run briefs it as a clause.
3. Cancel a run mid-stream — nothing persists (the report returns to the
   last finished run).
4. Drift needs three straining runs to see live — long-horizon; watch for
   the line over days of real use rather than forcing it.

**The declared world:**
5. Bless a bible fact; a later run must NOT bring it back. Correct one, then
   rewrite the scene to re-establish Claude's original reading — the strain
   must surface as a **conformance note against your ruling** (the designed
   channel), not silence.
6. Revoke a ruling from the Intent pane; ⌘Z it back.

**Cold start:**
7. Open a piece you've never run — the offer ("I haven't read this piece.
   Read it whole and take notes?"). Refuse once — it never asks again.
   Read on another — the whole-piece run streams in.

**Standing items unchanged:** the M2-era smoke remainder and the pre-M2
subject-sweep list (2026-08-05 handoff); the two parked decisions (assistant
column in every persona; strip freshness mechanism). The streaming ruling
from Stage 2's list is CLOSED — streaming shipped in Stage 3.

**The backlog Stage 3 leaves, on the record:** ClaudeCLISession.send's
synchronous stdin write can block the main actor past ~64KB briefings at
whole-piece scale (pre-existing, measured territory); the reply-field
@State stays visually open across a run transition (the write is
store-guarded either way); the derivation deadline's 120s awaits real-use
calibration.

---

# Earlier handoff (Stages 1 and 2) follows

*Updated 2026-08-08: Stage 2 (the run rebuilt) is merged to local `main` —
the run now briefs your essay + derived clauses (never raw rulings), returns
the four-section report, the pane leads with your clauses quoted back with
holds/strains/silent, every paragraph reference is an excerpt chip (no ¶id
anywhere you read), answers land as rulings, the bible fills from runs, and
the old v1 loop is deleted. The fifteenth consecutive whole-branch Critical
was the eleventh's shape: Stage 1's bible caption showed bare ¶ids the moment
Stage 2 fed it — fixed, facts are captioned by excerpt.*

**Stage 2's smoke list:**
1. Type into Tribute, ⌘R — the wait now says "Checking N new paragraphs…";
   a second ⌘R mid-run flashes "Still checking…".
2. The pane leads with YOUR intent sentences, each holds/strains/silent;
   a strain expands to its note; every citation is a clickable excerpt chip.
3. Answer a continuity question — it lands as a ruling (Intent pane, dated,
   "answered a compiler note"); the next ⌘R briefs the new ruling as a
   clause (the atomic switch, live).
4. The bible stratum now fills — facts captioned by subject + excerpt.
   Bless one; correct one; dismiss one.
5. **A RULING IS OWED (final review I1):** streaming sections did not ship
   (whole-turn ingest; the upgrade is a named Stage 3 item). Decide at
   smoke whether the legible wait suffices for the ~2-minute cold window,
   or streaming gets pulled forward.

**Stage 3's inherited list:** cold start (read-it-whole offer) + drift-as-
pattern (spec §4/§8), the bless convergence trap (AREA.md names the door: a
blessed fact re-emitted returns, double-briefs, and can mint a duplicate
ruling — design wanted, plus a bible-loop-across-runs test), the streaming
upgrade, the derivation subprocess deadline (measured, not copied), and the
strip/pane one-spelling watch item.

---

# The original Stage 1 handoff follows

*Written 2026-08-07 evening. Stage 1 (the declared world) is merged to local
`main` at `349e7ec1` — **53 commits ahead of origin, NOT pushed, NOT tagged.**
The spec is `2026-08-07-compiler-second-draft-design.md`; this stage built its
§3 whole.*

## What ships in Stage 1

- **Rulings** as a stratum of the statement: plain markdown list under
  `## Rulings`, op-logged, dated, with provenance. ⌘Z on a revoke works and is
  proven from the mounted button through the window's real undo manager.
- **The Intent pane's three strata**: essay (edited as before — and the split
  quietly FIXED a shipped bug: an answered note used to wipe the pane's undo
  history via the whole-text replacement; the essay no longer changes when a
  ruling lands, so nothing wipes), rulings (edit/revoke per row), bible
  (visibly provisional; bless / correct / dismiss — **empty until Stage 2's
  runs feed it**).
- **The derivation layer**: clauses/rules derived from the writer's prose,
  hash-cached per device, spawned strictly more confined than the compiler
  (`--tools ""`, no MCP at all). Zero production callers yet — Stage 2's run
  is its first consumer, by design, recorded in AREA.md.
- **The membrane, tightened**: the only writes into the writer's layer are the
  writer's verbs; a census with a planted offender proves nothing derived can
  write itself. The old answer-append flow is a deprecation shim that lands as
  a proper ruling; the shim dies in Stage 2.
- ADR 0027 amended; guide corrected to what ships.

## The fourteenth consecutive whole-branch Critical

Three tasks correct in isolation, broken composed: hand-typing `## Rulings`
in the essay editor hit a parser that honored heading-only sections, a binding
that dropped them from the essay, and a guide instructing exactly that flow —
the heading vanished mid-keystroke, the undo stack cleared, and prose under a
hidden heading could be silently deleted. Fixed by making the empty section
unrepresentable (a heading with nothing under it is essay), with the append
path ADOPTING a dangling heading rather than doubling it. Also fixed: a
duplicate-id bible sidecar crashed at project open (`uniqueKeysWithValues`).

## Smoke — Stage 1's short list

1. Open the Tribute piece's Intent pane. Type into the essay — including,
   deliberately, a line reading `## Rulings` — nothing vanishes, undo works.
2. In Author, answer a compiler note ("that's deliberate…") — it lands as a
   **ruling row** in the Intent pane with date + provenance, not a loose
   paragraph. Revoke it from the row; ⌘Z brings it back.
3. Hand-edit the statement file offline (add `- Kelly never lies` under a
   `## Rulings` heading while the project is closed) — reopen: it parses as a
   ruling row.
4. The strip still quotes your essay's first line — never a ruling.

## Stage 2 is next, and two carries are load-bearing

Stage 2 (the run rebuilt: four-section contract, conformance against derived
clauses, fact-candidates feeding the bible) plans against this built code.
Two things the whole-branch review pinned for it:

1. **The compiler briefs on WHOLE statement text today and that is correct**
   — rulings are declarations and the old contract should see them. The
   switch to essay-half-plus-derived-clauses must land in the SAME change
   that makes the run consume clauses; landing it earlier double-counts
   nothing but landing the clause-consumption without the switch
   double-counts rulings.
2. `ClaudeWorldDeriver.derive` gets its first production caller in Stage 2 —
   fix the pipe-drain read-after-exit shape in the same commit.

Three more Stage 2 requirements from Denver's first live runs (2026-08-07):

3. **No bare ¶ids anywhere the writer reads.** The output contract forbids ids
   in note prose — paragraphs are referred to by short QUOTE, the way an
   editor would. Cross-references become a structured `refs` field, rendered
   in the pane as excerpt chips that click-to-jump (the anchor row's own
   machinery). Applies to conformance strains and drift citations too.
4. **The silent window must not stay silent.** A cold first run over a large
   delta takes ~2 minutes and reads as broken: stream the four sections as
   they arrive (conformance first — the spike's named mitigation), and give
   the in-flight ⌘R press an acknowledgment (a "Still checking…" flash
   variant — revisits Task 7's refused-press-doesn't-flash judgment call).
5. The first-run-after-a-gap case is when a writer most doubts the tool —
   the running state should say what it is reading ("checking 14 new
   paragraphs…") so a long wait is legible.

## Standing state

- M2 + the wet-ink fix + Stage 1 are all on local `main`, one push behind
  nothing — the paired-release gate and Denver's smokes are the only holds.
- Parked decisions unchanged: assistant column in every persona; strip
  freshness mechanism; the M2 smoke list's untouched remainder.
