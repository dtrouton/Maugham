# Sweep task — claims and product decisions for one module

You are analysing ONE module of a Swift codebase (Maugham, a Mac writing app for novelists
and screenwriters). Two artifacts already exist and you must use them.

## The existing RULINGS (product decisions already made by the product owner)

**RULING-1** — Maugham MUST NOT accept, through any of its own entry points, content it cannot
read back faithfully. The refusal must be visible at the point of entry rather than discovered
later.
  *Scope:* every entry point Maugham itself offers — the editor, MCP writes, canvas promotion,
  inbox promote.
  *Rationale:* from the product constitution's "the words are safe". The writer must never be
  able to create, from inside the app, content that will later be eaten.

**RULING-2** — A file on disk MAY contain content Maugham drops when reading it. That is
acceptable. The fidelity obligation is on the ENTRY POINTS, not on the file.
  *Scope:* the parse path, for files arriving from outside — hand-edits, imports, sync.
  *Rationale:* the model owns the file. Deliberately NOT symmetric with RULING-1: strictness
  where a person acts, tolerance where a file arrives.

Note the SHAPE of that pair: strict where a person acts, tolerant where a file arrives.

## What to produce

### 1. CLAIMS — behavioural facts about the module

A claim is one testable statement of what the code does. Extract them from the source AND its
tests. Kinds: PRECONDITION, POSTCONDITION, INVARIANT.

Be accurate rather than generous. A known failure mode of this task is OVER-GENERALISING: a test
asserting `f("#GGGGGG") == nil` supports "rejects that input", NOT "rejects all non-hex input".
State the weaker claim the evidence actually supports.

### 2. PRODUCT DECISIONS — the decision surface

A product decision is a question about behaviour where:
  (a) a WRITER would notice the difference, and
  (b) two reasonable people could disagree about what should happen.

Be strict. Pre-order traversal, string-trimming semantics and allocation choices are NOT product
decisions. Losing a writer's words, silently transforming them, refusing input, choosing what
survives a rename or a merge — those are.

For each, classify:
  - `COVERED_BY_RULING_1` — the existing ruling already answers it. Say how.
  - `COVERED_BY_RULING_2` — likewise.
  - `NOVEL` — neither ruling answers it. Propose the ruling that would, phrased as a PRODUCT
    statement a non-programmer product owner could rule on (not an implementation choice).

Also flag `INCONSISTENT` if the module answers the SAME question two different ways in different
places — that pattern has already produced two real defects in this codebase.

## Output

Write ONE json file to the path given in your task. Schema:

```json
{
  "module": "<name>",
  "loc": <int>,
  "claims": [
    {"id": "<MODULE>-1", "scope": "Type.member", "kind": "POSTCONDITION",
     "statement": "...", "evidenced_by": "source|test:<TestName>", "confidence": "HIGH|MEDIUM|LOW"}
  ],
  "product_decisions": [
    {"id": "<MODULE>-D1", "question": "the question a product owner would answer",
     "current_behaviour": "what the code does today",
     "writer_visible_consequence": "what a writer would see",
     "classification": "COVERED_BY_RULING_1|COVERED_BY_RULING_2|NOVEL|INCONSISTENT",
     "reasoning": "...",
     "proposed_ruling": "only when NOVEL or INCONSISTENT; else null"}
  ],
  "notes": "anything that did not fit"
}
```

Read the module source and any test files that reference it. Do not modify any file in the
repository. Write only your one JSON output file.
