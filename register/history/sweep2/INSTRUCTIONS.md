# Sweep 2 — testing whether the SUB-rulings do real work

Read `/tmp/sweep2/RULINGS.md` first. It holds 3 ROOT rulings, 15 SUB-rulings and 4 PRINCIPLES,
derived from a long human interview about a Mac writing app (Maugham, for novelists and
screenwriters).

## The hypothesis under test

The roots may be too generic to be useful — "honour the writer's intent" can be stretched to
cover almost anything, which would make it explain everything and predict nothing. The sub-rulings
may be where the actual work happens.

**So the measurement is SPECIFICITY.** For every product decision you find, name the MOST SPECIFIC
ruling that reaches it. If only a ROOT reaches it, say so explicitly and plainly — that is a real
and useful signal, not a failure.

## What to produce

### PRODUCT DECISIONS
A question about behaviour where (a) a WRITER would notice the difference and (b) two reasonable
people could disagree. Be strict: traversal order, string handling and allocation are NOT product
decisions. Losing a writer's words, silently transforming them, refusing input, deciding what
survives a rename or a merge — those are.

For each, classify against the ruling set:
- `SETTLED_BY_SUB` — a sub-ruling reaches it. Name it and QUOTE THE CLAUSE that does the work.
- `SETTLED_BY_ROOT_ONLY` — no sub-ruling reaches it; only a root does. Say which, and say what a
  sub-ruling would have to state to settle it properly.
- `NOT_SETTLED` — nothing reaches it. Propose a ruling, phrased as a PRODUCT statement a
  non-programmer product owner could rule on (never an implementation choice).
- `CONTRADICTS` — the code does something a ruling forbids. Name the ruling and the clause.

## Four disciplines, learned the hard way. Violating these is the failure mode.

1. **SCOPE, NOT SYMPTOM.** A ruling reaches a case only if the case falls inside the ruling's
   stated scope — not merely because the same kind of thing happened. RULING-1's scope is ENTRY
   POINTS; a renderer emitting is not an entry point. RULING-11's scope is INVISIBLE BOOKKEEPING;
   a content-parsing rule is not bookkeeping. Show the case is in scope.
2. **SAME QUESTION.** Two code paths behaving differently is only an inconsistency if the WRITER is
   asking the same question. A retry guard and a deduplication policy look alike and are not.
3. **REACHABILITY MUST BE TRACED.** If you say a writer can hit something, name the call path from
   a UI action, an MCP tool or a file arriving. If you cannot trace it, say `reachability: UNTRACED`.
4. **YOUR PROPOSALS ARE HYPOTHESES.** A proposed ruling may be wrong, not merely unassigned. Mark
   confidence, and say what would falsify it.

## Output — ONE json file to the path in your task

```json
{"module":"<name>","loc":0,
 "product_decisions":[
   {"id":"<MOD>-D1","question":"...","current_behaviour":"...",
    "writer_visible_consequence":"...",
    "reachability":{"rating":"LIVE|LATENT|NEGLIGIBLE|UNTRACED","call_path":"..."},
    "classification":"SETTLED_BY_SUB|SETTLED_BY_ROOT_ONLY|NOT_SETTLED|CONTRADICTS",
    "ruling":"RULING-n or null","clause_that_does_the_work":"quote or null",
    "what_a_sub_ruling_would_need_to_say":"only for SETTLED_BY_ROOT_ONLY",
    "proposed_ruling":"only for NOT_SETTLED","confidence":"HIGH|MEDIUM|LOW",
    "what_would_falsify_it":"..."}],
 "notes":"anything that did not fit"}
```

Read the module and its tests. Do not modify any repository file. Write only your JSON output.
