# Reconciliation protocol

You are RECONCILING mechanically-produced claims against a human-authored ruling set.

Read `/tmp/recon/RULINGS.md` first — 3 ROOT rulings, ~18 SUB-rulings, 4 PRINCIPLES, authored by
the product owner of Maugham (a Mac writing app for novelists and screenwriters).

Then read your claims file. Each claim is a VERIFIED behavioural fact — it is pinned by a passing
test against the shipped code. You are not checking whether claims are true. You are asking, for
each one: **does any ruling reach it, and if so does the behaviour comply or violate?**

## The expected result

**Most claims will be reached by NOTHING, and that is correct.** Most behaviour is not a product
decision — traversal order, string handling, path arithmetic. A ruling set that reaches everything
would be too generic to be useful. Do not stretch to find a match. `NO_RULING_REACHES` is the
normal outcome and requires no justification beyond a one-line reason.

## The filing template — a verdict cannot be filed without all six fields

Only when a ruling DOES reach a claim:

```json
{"claim_id":"...","outcome":"COMPLIES|VIOLATES",
 "ruling":"RULING-n",
 "clause_that_reaches_it":"<quote the exact clause, not the ruling's title>",
 "why_in_scope":"<argue why this case falls inside that clause's stated scope>",
 "intent_expressed_when":"<when did the writer express the relevant intent? contemporaneous, earlier, or not at all>",
 "call_path":"<how a writer reaches this, or UNTRACED>",
 "violation_or_enhancement":"violation|enhancement|neither"}
```

For everything else:
```json
{"claim_id":"...","outcome":"NO_RULING_REACHES","reason":"<one line>"}
```

## Four disciplines. Each corresponds to a real error made earlier in this work.

1. **SCOPE, NOT SYMPTOM.** A ruling reaches a case only if the case falls inside its STATED scope.
   RULING-1's scope is ENTRY POINTS — a renderer emitting is not one. RULING-11's scope is
   INVISIBLE BOOKKEEPING (anchors, structural framing) — a visible field in a file is not that.
   Writing `why_in_scope` out is the check; if the sentence is hard to write honestly, the ruling
   does not reach.
2. **INTENT HAS DURATION.** A writer's instruction persists until withdrawn. Maugham acting on an
   earlier instruction is not acting unprompted. Deleting is intent; trash later destroying it is
   that intent honoured, not a violation.
3. **A ROOT BESIDE A SUB IS DECORATION.** If a sub-ruling reaches the case, do not also cite a
   root. Cite the most specific ruling that reaches it, and only that one.
4. **AN ENHANCEMENT IS NOT A VIOLATION.** "Could be better" is not "breaks a rule". If you cannot
   name the clause it breaks, the outcome is COMPLIES or NO_RULING_REACHES.

## Output

One JSON array of filings, one per claim, to the path in your task. Then a short `_summary` object
at the end of the array with counts: `{"reached":n,"complies":n,"violates":n,"no_ruling":n}`.

Do not modify any repository file. You may read the module source to judge scope.
