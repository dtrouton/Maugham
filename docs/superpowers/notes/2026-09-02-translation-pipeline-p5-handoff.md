# Translation pipeline — handoff after Plan 5 (2026-09-02)

Written for whoever next touches the translation pipeline or the statement panes. Plan 5 is built on branch `translation-pipeline-p5` (eight tasks, base `main@aa028ca6`, plan commit `e6260109`). The gate record is at the bottom; read the kept xcresult, never the pipe's exit code.

## Where things stand

- **Merge commit: pending** (filled in by the controller after the whole-branch review and the merge, alongside the gate record below).

- **Spec (binding):** `docs/superpowers/specs/2026-08-28-translation-pipeline-design.md` — §10 is Plan 5's whole scope. §13 lists the five plans; all five are now built.
- **Plan 1 — built** (handoff `2026-08-29-translation-pipeline-p1-handoff.md`, on main at `ef538475`). **Plan 2 — built** (handoff `…-p2-handoff.md`, merge `2498d90b`). **Plan 3 — built** (handoff `…-p3-handoff.md`, merge `2c2d28ec`). **Plan 4 — built** (handoff `2026-08-29-translation-pipeline-p4-handoff.md`, merge `bb74cef7`).
- **Plan 5 — built** (`docs/superpowers/plans/2026-09-02-translation-pipeline-p5-proposals.md`, this branch). It closes ADR 0030 §7: a brief or a visual language can now be proposed from outside the app and adopted, never written directly.

## What Plan 5 built, by file

**The store (Task 1).**

- `Maugham/Stores/StatementProposalStore.swift` — `ProposableStatement` (`.editionBrief(String)` / `.visualLanguage`; intent is unrepresentable — no case for it), one pending slot per key at `.maugham/statements/proposals/<key>.json` (`edition-brief-<tag>` / `visual-language`). `stage` supersedes whatever is pending and returns the proposal re-read from disk, so the in-memory value and the on-disk value can never drift (`.iso8601`, whole-second, matched to `DesignProposalStore`'s sibling shape); `discard` clears a slot; `validate`/`glossaryLines` enforce that a brief's `## Rulings` may hold only glossary-shaped lines and that a visual-language proposal carries none at all. Reads carry `adr-0018-ok`; `MaughamSidecarPath` routes it to `.unknownSidecar` deliberately. Posts `.maughamStatementProposalsChanged` (project scope) via `MaughamEvent.postStatementProposalsChanged`.

**The tools (Task 2).**

- `Maugham/MCP/Tools/StatementProposalTools.swift` — `propose_edition_brief` / `propose_visual_language`, mirroring `read_edition_brief`/`read_visual_language`'s shape. Catalogue moves for the first time this milestone: 56 → 58. Neither tool is in `CompilerAllowlist`; `CompilerAllowlistTests.statementWriters` widened to `edition_brief`/`visual_language` under the existing write verbs, plus a `propose_` predicate that catches `propose_craft_intent` and passes exactly the two new tools.

**The gate (Tasks 3–5).**

- `Maugham/Compiler/StatementProposalGate.swift` — `adopt` re-validates, then find-or-creates the statement, writes through `mutateStatementText` with `StatementEssay.recomposed` for a brief (whole text for visual language) so the `## Rulings` tail comes through byte-identical, then runs one `RulingPerformer.rule` per glossary line with `Ruling.Provenance.glossary`. It reads the statement back afterward and throws `.unreadable` **before** clearing the slot or registering undo if that read fails — the words are in the file and the slot stays pending rather than showing an adopted essay that might not be there. Clears the slot, posts the changed event, and registers one `OpUndoRegistrar` step ("Adopt Proposal") only on success. `discard` is the sibling verb. `StatementProposalCopy` holds every sentence the gate's view draws.
- `Maugham/Views/StatementProposalDiff.swift` — a line diff over the essay halves.
- `Maugham/Views/StatementProposalBanner.swift` — value-taking: title, when, rationale, a glossary-line count, a "creates the brief" line on a first Adopt, the diff, Adopt/Discard, and the notice.
- `Maugham/Views/StatementPane.swift` — `proposalSlot(kind:scope:)` says whether this statement can have one; the slot is read in a `.task` keyed on the slot plus `windowResolved` and re-read on the changed event (measured: `WindowAccessor` resolves ~20 ms after mount, and a project-scope post arriving before that is silently dropped without the key). Adopt writes into the pane's own bound `Document` when one exists, so the editor shows the words with no reload; a first Adopt that **created** the statement remounts the host once via `.id(hostGeneration)`, safe because there was no `Document` to close. `proposalBusy` disables the verbs for the width of one adopt/discard call.

**The desk and Visual Language marks (Task 6).**

- `Maugham/Views/Publish/DepartmentPane.swift` / `DepartmentPaneHost.swift` — a **Proposed** badge on a language row with a pending brief (`proposedBriefs`); a foot-of-section line, `proposedWithoutRow`, for a proposal whose language has no row yet, with its own Edition Brief door. `ReloadKey` gains `windowResolved`, the same fix as `StatementPane`'s, for every project event the desk receives.
- `Maugham/Views/DetailPaneToggle.swift` — a badge over the ⌘⌥V segment via `VisualLanguageProposalModifier`.

**The two skills (Task 7).**

- `docs/skills/edition-brief/SKILL.md`, `docs/skills/visual-language/SKILL.md` — new, served through the existing SEP-2640 extension; `docs/skills/maugham-bootstrap/SKILL.md` and `docs/skills/translation-pass/SKILL.md` gained pointers to them.

**Docs (Task 8, this one).** `docs/guide/right-pane.md`, `docs/guide/publish-department.md`, `docs/roadmap.md`, `docs/adr/0030-three-people-seven-legs-directives-as-rulings.md` (§7 retitled and rewritten, §8 unchanged), `docs/adr/README.md`, `Maugham/Views/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/Compiler/AREA.md`, `Maugham/MCP/AREA.md` (two extra fixes ruled in from Task 2's review: the "what this area owns" paragraph now names the staging tools, and the adopt sentence now reads "the desk's Edition Brief door presents `StatementPane`, where the gate draws"), `CLAUDE.md`.

**Tests.** `StatementProposalStoreTests`, `StatementProposalToolTests`, `StatementProposalGateTests`, `StatementProposalBannerTests`, additions to `StatementPaneTests` and `StatementPaneStrataTests` (three mounted gate cases: Adopt over a bound `Document`, Adopt creating a statement, Discard), `DepartmentPaneTests`, `DiagnosticsPaneTests` (the ⌘⌥V badge), `CompilerAllowlistTests`, `SkillIndexTests`.

## Carried forward

Decisions and small debts, not defects. Everything the ledger recorded as `minor (deferred)`, in task order, plus what P1–P4 left standing.

**From this plan's ledger:**

1. **T1** — a bare `## Rulings` heading with zero entries in a visual-language proposal passes `validate` (harmless; untested).
2. **T2** — the event test observes `object: nil` (scope not asserted).
3. **T2** — `statementWriters` widened to `internal` with no caller.
4. **T2** — `try?` swallows a typed refusal at `StatementProposalTools`' glossary count (unreachable; brief-mandated).
5. **T2** — the tool layer calls `TranslationReviewIndicator.displayLabel` (a view-layer symbol; brief-mandated).
6. **T2** — `glossaryEntries` is permanently 0 on the visual-language `Result`.
7. **T2** — RED evidence for the census widening was inferred, not observed.
8. **T3** — two concurrent `adopt` calls can both pass the pending guard (T5's `proposalBusy` disables the buttons, which narrows but does not close the window).
9. **T3** — the banner label carries the language tag ("Spanish (es) edition brief") — consistent with the desk row's own label, left as is.
10. **T3** — copy statics are partly unasserted.
11. **T3** — `glossaryEntries`'s `try?` is unreachable-safe.
12. **T3** — a type doc comment name-drops `rollbackUnusedStatement`, which `adopt` never calls.
13. **T4** — an unreachable terminal `break` in `StatementProposalDiff.lines`.
14. **T4** — a shadowed `model` local in the banner's body.
15. **T5** — `proposalNotice` interpolates a non-`Failure` error as a reflection dump rather than through `description`/`localizedDescription`.
16. **T5** — `Date()` read on the body path makes the banner's subtree compare unequal every pass.
17. **T5** — `proposalBusy` leaves the editor typeable in a sub-turn window before the disable lands.
18. **T5** — the notice stays sticky until the slot next changes.
19. **T5** — `reloadProposal()` after each verb duplicates the event-driven re-read (harmless).
20. **T6** — two language-naming vocabularies coexist on the desk: the row/help text uses `displayLabel` (with the tag) while the no-row line uses `languageName` (without) — a brief self-contradiction, disclosed rather than resolved.
21. **T6** — `VisualLanguageProposalModifier` is attached unconditionally with a `"/"` sentinel URL (functionally equivalent to a conditional attach).

**Still standing from P1–P4:** the declined "reply" lives in the query **body** under the translator's name (no reply primitive); leg 4 skips when leg 3 wrote nothing; a failed round stops a book queue; `languageQueries` reads the OPEN document only, so a closed chapter's prior queries are not briefed in a book queue; a cancel landing inside `mintDeclinedQueries` leaves minted queries absent from the record; a round-number collision is reachable only by starting a run in the instant after a `shutdown()` while the old round resolves a cold leg; `translation_status` decodes a per-language ledger once per row; `authorLanguage` re-reads `config.json` per gather; cross-object cancel is pinned per object rather than by one spanning test; a same-day directive re-directs its paragraph for the rest of the day.

## Rulings made during execution (for Denver to rework if wrong)

Verbatim from the ledger, in order.

1. **T1** — *keep `.iso8601` (human-readable sidecar, sibling parity with `DesignProposalStore`) and make `stage()` return the proposal RE-READ from disk so in-memory == on-disk; the file is the truth and whole-second `proposedAt` is fine — cost if wrong: sub-second precision on a timestamp nothing orders by within a second.*
2. **T2** — *⚠️ `adoptWhere` (desk → Edition Brief) vs the AREA phrasing ("`StatementPane`'s gate") — resolved by the controller: both true, the desk's Edition Brief door presents `StatementPane`; Task 8 phrases the AREA text to say so.* (This handoff and `Maugham/MCP/AREA.md` now both carry that phrasing.)
3. **T3** — *read `after` with `before`'s `do`/`catch`, throw `.unreadable` before discard/undo registration; the words are in the file, the slot stays pending — cost if wrong: a pending banner over an adopted essay on a near-impossible path.*
4. **T5** — *no mounted coverage of Adopt over a BOUND `Document` (plan-mandated gap) → fix round 1, closed the same round.*
5. **T5** — *`DepartmentPaneHost`'s `.task` key carries no `windowResolved`, so a project event in the desk's first frames is dropped — ruled into Task 6's scope (it wires the desk's proposal event); cost if wrong: one extra `.task` key field on the desk host.*

## The gate record

<!-- gate record: filled by the controller after the whole-branch review -->

## Smokes owed to Denver

- **P2:** the ⌘⌥C Translator's note manual smoke; the P3 unlocked re-gate.
- **P4:** click-through end to end in a real window (a report row → the paragraph in Translation Review); Run Whole Book over a real imprint; the Help topic's first table (the glossary table in the statement pane); ⌘⌥C Translator's note (still owed).
- **P5:** from Claude Desktop, run the `edition-brief` skill against a real project, see the Proposed mark on the desk row, open Edition Brief, read the diff, Adopt, ⌘Z; the same for `visual-language` and the ⌘⌥V badge.

## Process lessons from this run

- The pre-flight scan (task-pair consumer/producer check before any implementer started) caught nothing that needed a ruling before Task 1 — the plan's own API surface held all the way through, the payoff of writing Plan 5 against Plan 4's *built* code (CLAUDE.md rule 11) rather than against imagined API.
- Two `WindowAccessor`-timing defects (`StatementPane`'s `.task` and `DepartmentPaneHost`'s `.task`) were found independently by two different tasks' reviewers (T5, then T6) rather than once — the same 20 ms mount-to-resolve gap bit two call sites in one plan. A shared helper (`ReloadKey.windowResolved`, now used by both) is the fix; a future surface reading a project-scope event in a `.task` key should default to including it rather than rediscover the gap a third time.
- `CompilerAllowlistTests.statementWriters`' `propose_` predicate is itself a planted-offender test (`propose_craft_intent` must fail even though the tool does not exist) — worth keeping as the pattern for any future "one prefix, several real siblings" allowlist widening.
