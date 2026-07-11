---
name: maintenance-audit
description: Use when running Maugham's recurring codebase health check — the weekly delta sweep or the monthly full audit — or when the user asks for a cleanup pass, doc-drift check, "is the repo still healthy", or maintainability review.
---

# Maintenance Audit (weekly sweep / monthly full)

## Overview

Emergent defects live in fact×fact connections across areas — no single agent's scope contains them. So: agents return **territory maps** (neutral facts), the coordinator synthesizes **over the maps** (not over findings), suspicions become **probes**, and surviving findings get **verified then binary-triaged**. Provenance: the 2026-07-11 review, whose two worst bugs came from map collisions, not any agent's findings list.

Mode: `monthly` (or >4 weeks since the last full audit) → Full audit. Otherwise → Weekly sweep.

## Invariants (both modes)

1. **Continuity first.** Read the most recent `docs/superpowers/notes/*maintainability*` and `*-sweep.md` notes: the trend table, the refuted/resolved-suspicions section (NEVER re-chase those), and open shortlist items.
2. **Every subagent gets the output contract** in [references/agent-contract.md](references/agent-contract.md) appended verbatim — findings + territory map with mandatory Surprises & tensions, and the send-report-to-main instruction. Thin map ⇒ one re-dispatch. Read-only agents; no fixes during the audit.
3. **Every High/Critical is coordinator-verified against source** before it ships. No exceptions.
4. **Binary triage** (user rule, `feedback_no_defer_bucket`): each finding → scheduled task, or dropped on merit with the reason recorded. No "defer until touching that code" bucket. Fuzzy checks (heuristic greps, perf-budget tests) are merit-drops: false-positiving tripwires teach sessions to ignore tripwires.
5. **Always end with a dated note** in `docs/superpowers/notes/` — trend-metrics row appended (longitudinal), findings with `file:line` + fix-shape + effort, triage verdicts incl. merit-drops, refuted suspicions — then commit it. A verbal report is a process failure: the next sweep needs the artifact.

## Weekly sweep (delta-focused, ~3 agents)

1. Window = commits since the last sweep/audit note date. `git log --name-only` over the window → touched areas, mini-hotspots.
2. Doc-truth check (coordinator, cheap): roadmap •→✓ flips in the window → grep sibling docs (CLAUDE.md, touched `AREA.md`s, `docs/guide/`) for now-false claims; verify any prose counts not yet covered by generation tests.
3. Dispatch 2–3 agents with the contract: **delta bug-hunt** (opus) over the window's diffs, prioritized by mini-hotspots; **doc/test-truth checker** (sonnet) for touched areas; if one seam dominated the window, **one tracer** (opus) end-to-end through it.
4. Synthesize over the maps: collide this week's invariants-assumed/data-flows against the *prior audit's maps* (scratchpad mirrors or the note's map summaries), hunting the four classes below. Probe only if a suspicion is concrete.
5. Verify → triage → write + commit the sweep note.

## Monthly full audit

Follow the canonical procedure: spec `docs/superpowers/specs/2026-07-11-maintainability-review-design.md`, execution plan `docs/superpowers/plans/2026-07-11-maintainability-review.md` (Phase 0 script → 6 dimension agents + 3 tracers → synthesis → probes → findings doc). Reuse the plan's briefs, updating "newest areas" to whatever shipped since the last audit. The findings-doc skeleton is §-structured in the plan's Task 7.

## Synthesis: the four emergent-bug classes (hunt across map boundaries)

| Class | Historical instance |
|---|---|
| Two-correct-features-interacting | unified-undo T5×T6; task-op fire-and-forget × quit |
| Cross-surface contract drift | phone doc-id parser; inbox subdir literals |
| Silently-unwired-after-refactor | recordWordCount |
| Output-read-back-as-input | ADR 0018's origin |

Plus: temporal-coupling pairs (co-change ≥8 without a declared seam) → suspicion.

## Common mistakes (each observed in baseline testing)

| Mistake | Fix |
|---|---|
| Agents briefed to return findings only | Contract file appended verbatim — the map is the primary deliverable |
| "Synthesis" = deduping findings | Synthesis reads MAPS; findings-only synthesis can't see what nobody flagged |
| Verbal report, no artifact | Dated committed note, always — trend row + refuted list are the audit's memory |
| Re-investigating refuted suspicions | Read the prior note's §6 first |
| Findings parked as "do when touching that area" | Binary triage; record merit-drops |
| Background agent idles without delivering | Contract ends with the SendMessage-to-main instruction; nudge once if it still idles |
