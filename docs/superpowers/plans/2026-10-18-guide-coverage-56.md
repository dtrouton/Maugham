# #56: help guide coverage (Backups & History, working a batch, doc truth, enforcement) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The in-app guide (`docs/guide/`, served by Help → Maugham Help and over MCP `get_help`) covers backups, history and batch work, and says nothing false. Two small product changes (Denver's rulings) ship with it. New tests keep the guide's links and keyboard rows honest.

**Architecture:** This branch is mostly writing. **Read `docs/superpowers/notes/2026-10-18-issue-56-research.md` first.** It has, for every item, the current file:line and the exact UI strings the guide must quote verbatim. This plan carries only the decisions.

**Tech Stack:** Markdown, JSON, Swift (two small code changes and tests), XCTest.

**Spec:** issue #56 as re-verified on main c40ea9f3 in the research note, plus Denver's rulings.

## Rulings

- **Denver:** File → "Share for Review…" is renamed **"Share Project via iCloud…"**. Sharing no longer grants a review role, because permissions live in People & Devices. The guide's paragraph (L5) lives in `people-and-devices.md`.
- **Denver:** a named save point (⌘⇧S) also makes a backup, exactly as ⌘S does.
- **Controller:** M6 is dropped; PR #89 (merged) already documents the read-only canvas and Claude's refusal there. E1 test 1 (index census) already exists as `GuideDocsDriftTests`, so this branch only adds its planted-offender check.
- **Controller:** an "Updates" section is in scope. #67 shipped the next-launch notice, the twice-refused wording and the old-update cleanup, and no topic covers updates. Add a short section to `reference.md` (or `getting-started.md`, wherever the research finds the best fit), with strings quoted from `Maugham/Updates/InstallStatus.swift` and `UpdateBannerView.swift`.

## Global Constraints

- The guide describes what SHIPS, capability-first (it never names MCP tools), and in plain language for a writer. Quote UI strings verbatim from source.
- Coordination: the "oplog" session's unmerged plans don't touch `docs/guide/*`. Its plan 7 touches `Maugham/Views`, `Maugham/Stores`, `MaughamPhone` and `MaughamCore`. Keep the code changes here minimal, and keep `DocSyncTests` additions self-contained.
- Tripwire 33 for any test (no clicks, no press-then-wait).
- `./gen.sh` after adding a file. Iterate with `./scripts/test.sh`, and run `./scripts/test.sh full` before the PR. Never `pgrep -f xcodebuild`. If Core fails with only a `started.` line, re-run.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage by path.

## Review Focus

1. **Every quoted UI string matches the source verbatim.** The guide is read against the app.
2. **Every new link and anchor resolves.** Task 6's test proves it.
3. **Nothing in the guide contradicts what PR #89 and #67 shipped** (the canvas read-only section, the update notices).
4. **The rename leaves no stale "Share for Review"** in code, comments, the guide or tests (release notes are history, so leave them).
5. **⌘⇧S backs up through the same path as ⌘S**, with the same integrity check and the same skip-if-unchanged rule.

---

### Task 1: Two product changes (Denver's rulings)
- Rename the menu item to "Share Project via iCloud…" (`MaughamApp.swift:627`, its doc comment, `MaughamNotifications.swift:103`'s comment, and any test or guide reference).
- Make ⌘⇧S (named checkpoint) trigger the same backup ⌘S does. Find where ⌘S triggers the backup, and route ⌘⇧S through the same call, not a copy.
- Tests: the backup trigger fires for a named checkpoint (windowless, at the seam ⌘S's backup test uses; find it). If a test pins the menu title, update it.
- Commit: `feat: a named save point backs up too; Share for Review is Share Project via iCloud (#56 rulings)`

### Task 2: New topic, Backups & History (H1, H3)
Research §A H1/H3, Recommended task 1. Write `docs/guide/backups-and-history.md`. It tells one story: checkpoint (⌘S auto-labelled, ⌘⇧S named, both now back up) → History (filter chips, Revert with its scope picker, unreadable-checkpoint notice) → backups (Settings tab, what's copied, skipped when unchanged, integrity-checked) → Restore from Backup… (Verified/Corrupt, Restore a Copy… never in place) → the paused banner. For signing, held and set-aside rows, point to the existing sections rather than repeating them. Add it to `index.json` (renumber `order`), and link it from `getting-started.md` and `right-pane.md` where the research says.
- Commit: `docs(guide): a Backups & History topic (#56 H1, H3)`

### Task 3: reference.md, getting-started and Updates (L1, L2, L3, trash path, updates)
Research §A L1–L3 and the trash-path finding. Cover:
- the on-disk layout tree, corrected (including the `.trash/` location in `reference.md` and `research.md`);
- two Troubleshooting entries ("my project won't open", "how do I get an older version back");
- permissions-first advice in `getting-started.md`, matching `DocumentRecoveryPane`;
- the ⌘S row;
- the Updates section from the Rulings.
- Commit: `docs(guide): reference layout, troubleshooting, trash path and updates (#56 L1–L3)`

### Task 4: Working a batch, and undo declines (H2)
Research §B. Add a "Working a batch" section after "Working the queue — triage and order" in `annotations-and-suggestions.md`: the three verbs, the count strings, what a bulk verb reaches, the one summary notice, one ⌘Z for the batch, and the undo-decline sentences (#41/#51/#79) quoted from `UndoDecline`. Point `review-passes.md`'s cross-reference at the new anchor.
- Commit: `docs(guide): working a batch, and when an undo can't (#56 H2)`

### Task 5: Doc-truth smalls and the cheatsheet (M1–M5, L4, L5)
Research §C:
- **M1:** ⌘⌥I/⌘⌥0 in `right-pane.md`.
- **M2:** relabel the three deleted-pane entries in `Maugham/Resources/KeyboardShortcuts.swift`.
- **M3:** add ⌘? to `reference.md` and to the cheatsheet.
- **M4:** the Claude Desktop "Write:" list.
- **M5:** the `read_edition_brief` sentence, in capability language.
- **L4:** the publish desk's withheld "No translations yet."
- **L5:** a "Sharing a draft" paragraph in `people-and-devices.md` using the NEW menu name.
- **⌘\:** fix the row that shows two backslashes.
- Commit: `docs(guide): doc-truth fixes and the cheatsheet (#56 M1–M5, L4, L5)`

### Task 6: Enforcement (E1)
Research §D. Follow `DocSyncTests`' existing shape (parser + `XCTAssertNotNil` self-check + planted-offender test). Add:
- (a) a relative-link and `#anchor` resolver over `docs/guide` (GitHub-style slugs);
- (b) a check that every `.keyboardShortcut(` binding in `MaughamApp.swift` has a `reference.md` row, extending the existing ⌘⌥ extractor to every modifier set, with planted offenders for bare `.command`, `.return` and `"\\"`;
- (c) a planted-offender check for `GuideDocsDriftTests`' index census.
- Commit: `test(docs): the guide's links resolve and every shortcut has a reference row (#56 E1)`

### Finish
- [ ] `./scripts/test.sh full`, green.
- [ ] Whole-branch review (opus), told not to build. It reads every quoted string against source.
- [ ] Message the oplog session before merging.
- [ ] PR closing #56. Smoke for Denver: open Help → Maugham Help → Backups & History and follow its links; File menu shows "Share Project via iCloud…"; ⌘⇧S with a backup folder set adds a backup generation.
