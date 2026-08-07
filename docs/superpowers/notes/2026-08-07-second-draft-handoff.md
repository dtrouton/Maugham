# The compiler's second draft — handoff after Stage 1

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

## Standing state

- M2 + the wet-ink fix + Stage 1 are all on local `main`, one push behind
  nothing — the paired-release gate and Denver's smokes are the only holds.
- Parked decisions unchanged: assistant column in every persona; strip
  freshness mechanism; the M2 smoke list's untouched remainder.
