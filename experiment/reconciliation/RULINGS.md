# The ruling set (as of 2026-08-02)

## ROOTS — general. If a finding maps ONLY to one of these, say so explicitly; that is a signal, not a success.

- **RULING-20** — honour the writer's intent; where intent is unclear default SAFE; where it cannot be parsed, be NON-DESTRUCTIVE and easy to recover from
- **RULING-9** — what a writer does outside Maugham is their risk; what Maugham does on their behalf is Maugham's
- **RULING-19** — LAYERED: entry-point guards must FAIL AND TELL THE WRITER; lower layers protect the system and data silently (but a lower-layer repair means a guard above did not fire — that is a bug)

## SUB-RULINGS — specific. Prefer these. Name the MOST SPECIFIC one that reaches a finding.

- **RULING-1** — MUST NOT accept, at Maugham's own ENTRY POINTS, content it cannot read back faithfully; refusal visible at entry
- **RULING-2** — a FILE on disk may contain content Maugham drops when reading it
- **RULING-4** — words the writer AUTHORED are always recoverable; DERIVED material may be dropped but the drop must be reported
- **RULING-5** — an AI suggestion whose quoted phrase can no longer be found MUST NOT be applied — refused, never guessed
- **RULING-6** — stored text is never changed by a formatting convention; EDITING surfaces render as-typed (a caret indexes the source); READING surfaces may show the form's conventions; EXPORT offers the choice
- **RULING-7** — never misrepresent a failure — unreadable is never shown as empty; a refusal names its real cause. Scope: WRITER-FACING surfaces
- **RULING-8** — where the SAME writer question is answered in more than one place, it has ONE answer. Two situations that merely look alike may legitimately differ
- **RULING-11** — Maugham's own invisible bookkeeping (anchors, structural framing) must never alter the writer's intent — not what they see, not what is stored, not what Claude is served
- **RULING-13** — when a paragraph's identity is not recovered, its annotations MOVE WITH THE TEXT marked STALE — never silently detached; the author adjudicates
- **RULING-14** — promotion is an INGESTION boundary; once inside, the result is an ordinary artifact moved/renamed/deleted by ordinary rules. No reverse-promote
- **RULING-15** — delete is normalised — Maugham never unlinks a file, it moves it to trash, restorable
- **RULING-16** — a DEFERRAL is a hold, not a licence — nothing closeable independently of the deferred decision may shelter under it
- **RULING-18** — a transformation the writer OPTED INTO (smart quotes, configured auto-format) is the WRITER'S edit, not Maugham's
- **RULING-3** — DEFERRED: filename legibility for non-Latin scripts, pending a cross-app multilingual review
- **RULING-17** — a failed transcription is NOT auto-retried — correct as-is

## PRINCIPLES — how to judge, not what to decide

- **PRINCIPLE-1** — A decision's correctness is a function of how much depends on it. A ruling that was right when three things depended on it can be a bug when thirty do — without anyone changing it.
- **PRINCIPLE-2** — An enhancement is not a defect. A behaviour that violates no ruling is CORRECT, even where a better experience is imaginable. The register records ruling violations; it must not accumulate wishes.
- **PRINCIPLE-3** — Every finding is answered on TWO INDEPENDENT AXES, in order, and an earlier answer never substitutes for a later one.
  1. VIOLATION — does it violate a stated ruling? The ruling must reach it BY SCOPE, not by symptom. Name the ruling AND show the case falls i
- **PRINCIPLE-4** — A ruling violation is a DEFECT regardless of how few writers can reach it. Reachability is recorded separately and governs PRIORITY. A defect may rationally never be fixed on ROI grounds — and that is NOT the same as an accepted limit: an accepted limit is cor

## Added since the last sweep

- **RULING-21** — What Maugham serves to Claude IS a writer-facing surface for the purposes of RULING-7. A surface is writer-facing if what it returns reaches the writer without an independent check — including anything served to Claude. An ANSWER about the writer's content must be true; only a REPAIR may be silent.
- **RULING-22** — Maugham should never surprise the writer. Controls are unambiguous and DO WHAT THEY SAY. Where an action is complex or its consequences are confusing, that warrants an additional confirmation prompt.
- **RULING-23** — Trash destroying its contents is Maugham HONOURING the writer's intent — they chose to delete. The retention window is leeway to change their mind, not a promise of permanence. Losing trash is not a defect.
