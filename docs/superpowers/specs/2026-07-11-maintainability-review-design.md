# Maintainability Review — Design

**Date:** 2026-07-11
**Status:** Approved pending user review
**Type:** Process spec (review/audit, not a feature)

## Goal

Full fresh-eyes review of the repo after ~1,120 commits since the last state-of-the-code audit (2026-05-19) and five major milestones since the last quality audit (2026-06-09). Dimensions: tests, architecture, docs/context files, memory→tripwire promotion, security, bug hunt. Output: a prioritized findings doc in `docs/superpowers/notes/`, from which a hardening milestone is scoped.

## Scope decisions (made with user)

- **Full fresh-eyes**, whole repo. Prior audit findings are re-checked, not assumed fixed.
- **Deliverable:** findings doc → hardening milestone. No fixes applied during the review, including doc fixes.
- **Security:** all four surfaces — MCP Unix-socket bridge; release/CI pipeline (signing, notarization, updater trust chain, action pinning); file-system handling in stores (symlinks, project-root escapes); phone↔Mac iCloud JSONL data flow (tampered inbox/oplog input).

## The central design problem

Narrow-focus agents find local problems but miss emergent issues — things that only look like problems when connected across scopes. This repo's own history proves the class: the T5×T6 Critical in unified-undo (invisible to per-task review, caught only whole-branch), the recordWordCount silent break (two individually-correct changes interacting), the phone doc-id contract drift. The design below exists to catch that class, not just the local findings.

## Architecture of the review

```
Phase 0: Mechanical pre-pass (scripts, no agents)
   ↓ feeds every agent
Phase 1: Map + find (parallel agents: 6 dimensions + 3 vertical tracers)
   ↓ maps + findings
Phase 2: Synthesis over MAPS, not just findings (main context)
   ↓ suspicions
Phase 3: Targeted hypothesis probes (parallel agents)
   ↓ verified evidence
Phase 4: Findings doc (severity-ranked, fix-shapes, emergent items sectioned separately)
```

### Phase 0 — Mechanical pre-pass

Git-history-derived data, computed by script before any agent runs (Tornhill hotspot method):

- **Hotspots:** files ranked by commit-count × current size. Hotspots get priority in the bug hunt and are the objective refactor candidates.
- **Temporal coupling:** file pairs that repeatedly co-change but live in different areas with no declared seam. Hidden coupling made visible mechanically — this directly targets the emergent-issue class.
- **Trend metrics** (Lehman: complexity grows unless work reduces it): file-size distribution, MCP tool count, tripwire count, test-file/source-file ratio, ADR count, LOC by target. Recorded in the findings doc so future audits are longitudinal, not snapshot-only.

### Phase 1 — Map + find agents

**Every agent returns two artifacts:**

1. **Findings** — problems, each with severity, `file:line` evidence, one-line fix-shape, effort guess.
2. **Territory map** — neutral facts: seams present, data flows, invariants the code assumes, duplication observed, plus a mandatory **"surprises and tensions"** section — things that looked fine but were odd, assumption-laden, or correct-only-because-X-holds-elsewhere. Agents are told explicitly: reporting a non-problem oddity is success, not noise.

Rationale: emergent issues live in fact×fact connections. If synthesis receives only problems, the facts needed to make the connection were discarded at the agent boundary.

**Horizontal dimension agents (6):**

| # | Dimension | Rubric / method |
|---|---|---|
| 1 | Architecture & code health | ISO 25010 sub-characteristics (modularity, reusability, analysability, modifiability, testability); seam-pattern adherence in new areas (palette, tasks, craft intent, undo); dead code; ADR compliance; hotspot files from Phase 0. Context-window economics counts as a maintainability metric: a file too big to hold alongside its AREA.md and call sites is a risk because the maintainer is an LLM. |
| 2 | Test suite | Feathers' lens: which *seams* are untested (an untested seam is where the next regression enters), not just raw coverage. Behavior-coupled vs implementation-coupled tests. Coverage of the newest seams: undo compensating ops, block parser, palette store. Flaky/slow spots. |
| 3 | Docs & context files | The **fresh-session onboarding test** (Parnas ignorant-surgery defense): for a sample of historical failures in the memory files, could a fresh session reading only CLAUDE.md + relevant AREA.md have avoided it? Plus: CLAUDE.md accuracy (palette area missing from per-area table; tool counts), AREA.md drift, help docs vs shipped reality. Every factual doc claim gets the **generated-or-tested** question: could this be derived or asserted instead of hand-maintained (EMISSION.md pattern)? |
| 4 | Memory→tripwire promotion | Classify all 21 CLAUDE.md tripwires + 58 memories on the enforcement ladder: prose → checklist → grep/CI test → type constraint → impossible-by-construction. Finding = gap between current rung and highest achievable rung. Retirement is Chesterton-fenced: no memory marked stale without tracing the incident that created it. |
| 5 | Security | The four surfaces above. For contracts: Hyrum's-law coverage check — behaviors multiple surfaces depend on that are NOT in `docs/superpowers/notes/cross-surface-contracts.md`. The registry's coverage is the question, not its correctness. |
| 6 | Bug hunt | Fresh adversarial eyes on the least-soaked code (unified undo, palette editor, shared block parser edges) prioritized by Phase 0 hotspots. |

**Vertical tracer agents (3)** — lifecycles traced end-to-end, deliberately crossing every seam, so intersections are seen twice from different angles:

- **T-A:** one paragraph edit: keystroke → op log → render → autosave → iCloud sync → phone read → annotation → undo of all of it.
- **T-B:** one MCP call's full trust path: socket → tool arg parsing → store → disk → response.
- **T-C:** one release: tag → CI → signing → notarization → updater → installed app.

**Models:** opus-class for architecture, security, bug hunt, and all three tracers; sonnet-class acceptable for tests/docs/memory dimensions. Per project policy: opus when in doubt.

### Phase 2 — Synthesis (main context, over maps)

Done by the coordinating session with all territory maps loaded — not an agent, and not over findings alone. Method: deliberately hunt each historical emergent-bug **class** across dimension boundaries:

- (a) two-correct-features-interacting (T5×T6 pattern)
- (b) cross-surface contract drift (phone doc-id pattern)
- (c) silently-unwired-after-refactor (recordWordCount pattern)
- (d) output-read-back-as-input (ADR 0018's origin)

Plus: reconcile temporal-coupling pairs from Phase 0 against the declared seams in the maps. Output: a list of *suspicions* — cross-cutting hypotheses, not conclusions.

### Phase 3 — Hypothesis probes

Each suspicion gets a targeted verification agent with the specific cross-cutting question and pointers to the exact files. This is where depth budget goes: focused digging where connections smell wrong, not more breadth.

**Verification rule (from project memory: "verify review claims against source"):** every High/Critical finding — from any phase — is re-verified against actual source by the coordinating session before it enters the report. No unverified High/Critical ships.

### Phase 4 — Findings doc

`docs/superpowers/notes/2026-07-11-maintainability-review.md` containing:

1. Trend metrics table (Phase 0) — the longitudinal baseline.
2. Per-dimension findings: severity (Critical/High/Medium/Low) · evidence (`file:line`) · fix-shape · effort guess.
3. **Emergent/cross-cutting findings, sectioned separately** so milestone prioritization can see which is which.
4. Tripwire/memory promotion table: item · current rung · achievable rung · recommended action (keep / promote-to-test / promote-to-structure / retire-with-fence-check).
5. Proposed hardening-milestone shortlist, prioritized.

## Theory the design draws on (for the record)

Tornhill hotspots & temporal coupling; Lehman's laws (trend metrics); Vaughan normalization-of-deviance + poka-yoke (enforcement ladder); Parnas software aging / ignorant surgery (fresh-session onboarding test — every Claude session is a new engineer on day one, so context files are the primary defense); ISO 25010 (architecture rubric); Hyrum's law (registry coverage); docs-decay → generated-or-tested docs; Feathers (untested seams). Considered and excluded: mutation testing (cost/benefit at 66k LOC), formal coupling metrics beyond temporal coupling, Conway's law (single-author).

## Error handling / failure modes of the review itself

- An agent that returns findings but a thin map gets re-dispatched with the map requirement emphasized — the map is the point.
- Suspicions that probes refute are recorded as refuted (one line) so the next audit doesn't re-chase them.
- If Phase 0 scripts and an agent disagree on a fact, source wins; the script gets fixed and re-run.

## Out of scope

- Applying any fix, including doc fixes (deferred to the hardening milestone).
- Test-data migration questions (project policy: delete and recreate).
- Re-litigating decided ADRs; the review checks *compliance* with them, not their merit — unless evidence shows an ADR is actively harmful, which is reported as a finding.
