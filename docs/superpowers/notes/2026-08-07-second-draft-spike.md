# The second draft's spike — derivation quality and the four-section contract, measured

*2026-08-07, against the real Tribute piece and Denver's real intent prose
(the 14-¶ wet-ink chunk from the 2026-08-06 diagnosis as the delta). Spec:
`2026-08-07-compiler-second-draft-design.md` §8. Sonnet, `--tools ""`.*

**Verdict: both claims hold.**

1. **Derivation quality** — 8 clauses + rules derived from six paragraphs of
   freeform intent, each a verbatim quote of the writer's words plus a
   genuinely checkable one-sentence check (including the structural one —
   "near the end, a spam of approvals slips a change through" — and the
   ambiguity clause, derived as a thing to HOLD rather than resolve). Cost
   $0.09 / 30 s, paid once per statement change (hash-cached).
2. **The four-section contract** — parsed cleanly on every attempt (two full
   runs). Conformance: 12 entries, holds/strains/silent citing real ¶ids;
   the strains are the kind a writer can use (*"the discovery reads as the
   agent recalling the prior agent's setup rather than finding a trace"* —
   a true conformance note against the breadcrumbs clause, not an opinion).
   Continuity: 4 entries, incl. a real cross-¶ question. Reader report:
   capped at 3 as instructed. Fact-candidates: 6.

**The honest number:** the four-section run over the full 14-¶ chunk cost
**$0.18 / 105 s cold** — far over the 2–4 s first-note budget. Three
mitigations, in force by design: typical deltas are a fraction of this
chunk; the warm session removes spawn+context cost; and the pane can render
sections as they stream (conformance first). The plan must carry a latency
task: measure a warm small-delta run and, if it misses the feel budget,
stream sections rather than batch the turn.

**Prompt-shape findings for the plan:** fenced-JSON tolerance still needed;
`what_pulls: null` on holds (schema should make it optional-on-strains);
the derivation prompt's "do not invent standards" held (nothing derived
beyond the writer's sentences).
