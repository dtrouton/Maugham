# Pre-registered predictions — annotation lifecycle vs spliced text

*Written 2026-08-01 **before** `AnnotationRace.tla` was modelled or run, and committed in its own commit so the ordering is checkable in git rather than asserted afterwards.*

**Why this file exists.** The open question is whether the model *discovers* or merely *confirms*. That is only answerable if the prediction is on the record first. The spike's spec §7 did this and it is the reason §3 could tell the two apart. Same discipline here.

## What I already established by reading

- `Document+Annotations.swift:377` — **"two effects, one op."** The `claudeAccept` op itself carries the manuscript `changes` payload produced by `SuggestionSplice.apply`.
- `Deriver.swift:63,74` — the manuscript is a fold of **every** op's `changes` in opId order. `claude_accept` "DOES KEEP its changes." The fold never consults the annotation lifecycle.
- `AnnotationDeriver.swift:11` — status is the **single latest lifecycle op by opId**, `latest wins`.
- ADR 0012 names *"reject on phone while accept on Mac"* as a **routine** overlap, and states that partitioning does not settle lifecycle semantics — "the deriver still has to decide which lifecycle state wins." It decided. Nobody asked what happens to the **text**.

## The property

For a `suggestedChange` annotation: **its resolved status agrees with whether the manuscript holds the suggested text.** Status `accepted` ⟺ text spliced.

## Predictions

**P1 — the headline. Expected VIOLATED.** Concurrent `claudeAccept` (device A) and `claudeReject` (device B) on one open `suggestedChange`, with the reject carrying the higher opId. Status resolves to `rejected`; the accept's `changes` still fold into the manuscript. The writer sees an annotation marked rejected and their manuscript silently contains the change they rejected.

**P2 — no violation.** The same pair with the accept holding the higher opId. Status `accepted`, text spliced. Consistent.

**P3 — the divergence is permanent, not transient.** `claudeAcceptRevert` is the only op carrying inverse changes. A plain `claudeReject` cannot undo a splice, so P1's divergence never self-heals — unlike every window found in the op-log spike, which converged once propagation completed.

**P4 — no violation for `comment` / `query` / `craftNote`.** They carry no `changes`, so there is nothing for the status to disagree with. Only `suggestedChange` is exposed.

**P5 — clock skew is not required.** P1 needs only that the two ops interleave; it does not depend on ULID order disagreeing with real time. Skew widens which device "wins" but is not the cause.

## What would count as DISCOVERY

Any counterexample whose shape is **not** P1. Specifically:

- a divergence reachable on a **single device** (no concurrency at all)
- one involving `claudeAcceptRevert`, `claudeArchive`, `annotationReopen` or `annotationWithdraw` rather than the plain accept/reject pair
- one where the text is reverted but the status says `accepted` — the mirror of P1, which I am **not** predicting
- a divergence for a non-`suggestedChange` kind, contradicting P4
- any interleaving that produces a status no single user action could have produced

## What would count as CONFIRMATION ONLY

TLC returns P1 and nothing else. That is a fourth confirmation for the method, and per the stopping rule agreed with Denver it counts against (b) rather than for it.
