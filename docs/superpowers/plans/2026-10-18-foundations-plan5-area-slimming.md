# Foundations plan 5: area guides an agent can afford

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Every `AREA.md` fits in one sitting (at most 8,000 words) and has the same four sections, and nothing it used to know is lost: history moves verbatim to `docs/history/<area>.md`.

**Architecture:** Docs only, plus `DocBudgetTests` ceilings. Each area guide is rewritten to the template that Core's guide already uses. Narrative, provenance and "why the alternative lost" text moves word for word to a history file the guide points at. A one-shot coverage check (below) proves that every backticked identifier and every rule sentence in the old guide landed somewhere.

**Spec:** `docs/superpowers/notes/2026-10-17-foundations-audit.md`, finding D2 ("a template per AREA (Map / Rules / Recipes / Pointers), history moved to `docs/history/<area>.md`, at most 8k words each") and D7 (recipes for extension points). Sizes on main at `aadac856`: Canvas 47,971; OpLog 30,405; Views 28,289; Compiler 23,782; Stores 16,389; MCP 8,687; Phone 5,007; Updates 4,089; Editor 3,673; Core 3,085; Publish 1,073.

## Global Constraints

- **The template**, in this order, with these exact headings:
  1. `# <Area> — area guide`, then one paragraph: what the area owns and the one rule from CLAUDE.md's area table.
  2. `## Map`: every source file (or file family) in the folder, one line each: name, what it is for, and the tripwire numbers it carries. Core's guide (`Packages/MaughamCore/Sources/MaughamCore/AREA.md`) is the model.
  3. `## Rules`: the invariants, each one a bullet that states the rule, why in one clause, and its enforcing test or tripwire number. Every "never / always / must / refuse / do not" in the old guide that is still true lands here, or in Recipes.
  4. `## Recipes`: numbered steps for this area's extension points (e.g. "add a canvas item kind", "add an MCP tool", "add a compiler role"), each step naming the file. Write a recipe only where the old guide or the code shows a real, repeated extension path.
  5. `## Pointers`: the ADRs, specs, `docs/tripwires.md` rows, the tests worth knowing, and `docs/history/<area>.md`.
- **Nothing is deleted except what is false.** Text that leaves the guide goes to `docs/history/<area>.md` verbatim, under its original headings, with a one-line header: "Moved from `<path>` on 2026-10-18 by foundations plan 5. History and rationale; not required reading. The guide is the current truth." Relative links inside moved text are re-pointed so they still resolve from `docs/history/`. A claim found FALSE against the code is corrected (in the guide) or dropped, and listed in the task report with its evidence.
- **The guide is the present tense.** No milestone tags, task numbers, dates or "(1C-d Task 7)" provenance in the guide; those go to history. `DocBudgetTests.test_untaggedDocsCarryNoMilestoneTag` already covers some docs: add every AREA.md to its list once that guide is re-templated.
- **Ceilings:** after each task, set that guide's ceiling in `DocBudgetTests.wordCeilings` to its new actual size with a reason, ("plan 5: re-templated"). Hard cap 8,000 words per guide. `docs/history/*.md` are not budgeted.
- **Phrases code comments cite must still resolve.** Before rewriting a guide, `grep -rn "<area>/AREA.md\|AREA.md" Maugham MaughamTests MaughamPhone Packages` for comments citing a named section ("the third door", "the derivation trigger", "Typed user-content mover", "Two editors in one window", "the lifetime row"…). Each cited phrase stays findable in the guide (preferred) or in its history file; if it moves to history, update the comment's path.
- **Don't touch Swift code** except `DocBudgetTests.swift` and comment paths per the previous bullet.
- **Coordinate with maugham-issues:** its batch (`fix/batch-f-88-92`) will add small sentences to Canvas AREA (a third read-only reason, `.unreadable`) and Stores AREA (backup facts). Whoever lands second re-places them. Plan 5 fixes the Stores trash line itself (#91): the trash is `<project>/.trash/`, not `.maugham/trash/` — verify against the code before writing.
- **Gates:** `./scripts/test.sh core` after each task (DocBudgetTests live in Core). Never raw `swift test`. Final task: `./scripts/test.sh full`.

### The coverage check (run by implementer AND reviewer, every area task)

```bash
# usage: area-coverage OLD_GUIDE NEW_GUIDE HISTORY_FILE
python3 - "$@" <<'EOF'
import re,sys
old,new,hist=(open(p).read() for p in sys.argv[1:4])
ids=lambda t:set(re.findall(r'`([^`\n]{2,80})`',t))
missing=sorted(ids(old)-ids(new)-ids(hist))
print("identifiers missing:",len(missing)); [print("  ",m) for m in missing]
rules=[s.strip() for s in re.split(r'(?<=[.!])\s+|\n',old) if re.search(r"\b(never|always|must|do not|don't|refuse[sd]?)\b",s,re.I)]
lost=[r for r in rules if r[:60] not in new and r[:60] not in hist]
print("rule sentences not found verbatim in either file:",len(lost))
for r in lost: print("  -",r[:160])
EOF
```

Take OLD_GUIDE from `git show aadac856:<path>`. Every missing identifier must be justified in the report (renamed, deleted from the code, or false). Rule sentences that were reworded into the Rules section are expected to show as "not found verbatim"; the report lists each one with the Rules bullet that now carries it, or why it is obsolete. The reviewer re-runs the check and samples at least ten of those pairings.

## Review Focus

1. A rule that was only stated in narrative (deep in a "why" section) and is dropped, so the next agent re-breaks it. The coverage check plus the reviewer's ten-pair sample catch this.
2. A Map entry that names a file that no longer exists, or misses one that does. `test_everyBacktickedFileInACheckedDocExists` catches the first if the guide is in its checked list; the reviewer runs `ls` against the second.
3. A recipe that invents steps the code does not need. Each recipe step names a file the reviewer opens.
4. Broken relative links in moved history text.
5. A guide that still cites milestone/task provenance, so it re-grows as history.

---

### Task 1: The template, the history folder, and the budget hooks

**Files:** `Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`; `docs/history/README.md` (new); `docs/INDEX.md`; `Maugham/OpLog/AREA.md` (its stale "plan 5 schedules OpLogStore's split" sentence).

- [ ] Add a test `test_everyAreaGuideFollowsTheTemplate`: for each guide in a list `templatedGuides` (starts with just Core's guide), assert the headings `## Map`, `## Rules`, `## Recipes`, `## Pointers` appear in that order. Core's guide gains `## Rules` / `## Recipes` / `## Pointers` sections if it lacks them (move its existing content under them; no new prose beyond what's there). Planted-offender control: the helper fails on a string with Rules before Map, and on one missing Recipes.
- [ ] Add `test_noAreaGuideExceedsTheHardCap`: every `AREA.md` in the repo (found by walking, not listed) is at most 8,000 words, EXCEPT those in an explicit `notYetTemplated` set that shrinks to empty by task 9. A guide in that set that is already under 8,000 fails the test ("remove it from notYetTemplated"), so the set can't go stale.
- [ ] Create `docs/history/README.md`: two sentences on what the folder is. Add it to `docs/INDEX.md`.
- [ ] Fix OpLog AREA's sentence that says plan 5 schedules the OpLogStore split (it shipped in plan 6).
- [ ] `./scripts/test.sh core` green; commit.

### Task 2: Canvas (47,971 → ≤ 8,000)

**Files:** `Maugham/Canvas/AREA.md`; `docs/history/canvas.md` (new); `DocBudgetTests.swift`; comment paths if any phrase moves.

- [ ] Run the comment-citation grep; list the phrases.
- [ ] Rewrite to the template. Map covers every file in `Maugham/Canvas/`. Rules include tripwires 25–33 in the form above. Recipes at least: add a canvas item kind; add a canvas MCP verb; add a region/line behaviour (only if the code shows each path).
- [ ] Move the rest verbatim to `docs/history/canvas.md`.
- [ ] Coverage check; ceilings; add the guide to `templatedGuides` and the untagged-docs list; remove it from `notYetTemplated`.
- [ ] `./scripts/test.sh core`; commit.

### Task 3: OpLog (30,405 → ≤ 8,000)

Same steps as Task 2 for `Maugham/OpLog/AREA.md` → `docs/history/oplog.md`. Rules carry tripwires 17, 20, 23, 24, 35–53 that live here and the two CLAUDE.md invariants (`Document.load`, external edits discarded). The Map points at Core's guide for the 42 Core files rather than re-listing them. Recipes at least: add an `OpKind`; add a trust-table verdict consumer; add a permit-checked writer (tripwire 52).

### Task 4: Views (28,289 → ≤ 8,000)

Same steps for `Maugham/Views/AREA.md` → `docs/history/views.md`. Map covers the window family (ProjectWindow, CentreColumn, CentreRoute, RightColumn, ProjectSession pointer) and `Maugham/Models/` files the CLAUDE.md table routes here. Recipes at least: add a persona pane; add a centre route; add a right-column inspector.

### Task 5: Compiler (23,782 → ≤ 8,000)

Same steps for `Maugham/Compiler/AREA.md` → `docs/history/compiler.md`. Keep "the third door", "the derivation trigger", "the lifetime row" findable (tests cite them). Recipes at least: add a compiler role (joins `AgentRoster`); add a statement kind (point at Core's recipe, don't restate it).

### Task 6: Stores (16,389 → ≤ 8,000) and the trash line

Same steps for `Maugham/Stores/AREA.md` → `docs/history/stores.md`. Keep "Typed user-content mover" findable. Correct the trash location after checking the code (#91). Recipes at least: add a project-scope sidecar under `.maugham/`.

### Task 7: MCP, Phone, Updates

Re-template `Maugham/MCP/AREA.md` (keep the `## Tool catalogue (NN)` heading byte-compatible: `DocSyncTests` parses it), `MaughamPhone/AREA.md`, `Maugham/Updates/AREA.md`, each with its own `docs/history/<area>.md` only if text moves. Recipe for MCP: add a tool (catalogue, heading count, help skill).

### Task 8: Editor, Publish, Core

Re-template `Maugham/Editor/AREA.md` and `Maugham/Publish/AREA.md`; finish Core's sections from Task 1 if thin. These are small; the work is shape, not cuts. After this task `notYetTemplated` is empty and every guide is in `templatedGuides`.

### Task 9: Cross-references and the sweep

- [ ] CLAUDE.md's per-area table still names the right guide and "one rule" per row (no wording drift from the guides' opening paragraphs). Don't grow CLAUDE.md.
- [ ] `docs/tripwires.md`, `docs/INDEX.md`, ADRs and `register/` links into AREA sections still resolve: grep for `AREA.md#` and `AREA.md §` and named-section citations; fix or re-point to history.
- [ ] Regenerate AGENTS.md if CLAUDE.md changed (`DocBudgetTests.test_agentsMdIsCLAUDEmdWithItsGeneratedHeader` names the command).
- [ ] `./scripts/test.sh full` green; commit.
