# Shared agent output contract

Append this verbatim to every map+find agent brief (dimension agents, delta hunters, tracers). Probe agents use the probe template at the bottom instead.

---

You are a READ-ONLY reviewer. Do not edit, create, or delete any file. Your final message is data for a coordinating session, not prose for a human.

Return EXACTLY this structure:

## FINDINGS
One bullet per problem, most severe first:
- [Critical|High|Medium|Low] <one-line defect> — <file:line> — fix-shape: <one line describing the hardening task> — effort: S|M|L
If none in a severity band, omit the band. An empty FINDINGS section is acceptable; an empty map is not.

## TERRITORY MAP
### Seams & boundaries — the real module boundaries you observed (not the documented ones): what talks to what, through which types/functions.
### Data flows — where data enters, transforms, persists, exits, for the code you covered.
### Invariants assumed — conditions the code relies on but does not check or enforce; say WHERE each is relied on and WHERE (if anywhere) it is guaranteed.
### Duplication observed — logic/knowledge that exists in 2+ places, even if currently in sync.
### Surprises & tensions — MANDATORY, non-empty. Things that looked FINE but were odd, assumption-laden, or correct-only-because-something-else-happens-to-hold. Reporting a non-problem oddity here is success, not noise.

Cite file:line for every concrete claim. Read files directly; do not trust doc claims about the code.

When you are done, SEND your complete report to the coordinator via SendMessage with to: "main" — the full report text, not a summary. Do not end your turn without sending it.

---

# Probe template (for synthesis suspicions)

READ-ONLY probe. Investigate this specific hypothesis, nothing else:

HYPOTHESIS: <the cross-cutting hypothesis>
Context (the colliding facts, with file:line): <fact A from map X; fact B from map Y>
Read: <exact files>.

Return EXACTLY:
VERDICT: CONFIRMED or REFUTED
If CONFIRMED: failure scenario (concrete inputs/state → wrong outcome), file:line per step, fix-shape one line, effort S/M/L.
If REFUTED: the exact mechanism that prevents it, file:line.
No other findings. Send the result to "main" via SendMessage before finishing.
