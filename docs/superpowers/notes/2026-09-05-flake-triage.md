# Flake triage — 2026-09-05

A fixed-budget session (four hours) over the recent test flakes, run under
three rules Denver set at the start: **fix only a test that pins a hard
invariant** (CLAUDE.md's invariants, a tripwire, a constitution must, a
register claim) and **delete every other flake outright** — no skip, no
`XCTSkip`, no hardening; **cull the whole SHAPE** a flake belongs to, not the
one test that happened to go red; land each iteration on local main behind a
green full gate, push nothing.

## The evidence

CI, the sixty runs before the session: 49 green, 8 cancelled (superseded
pushes), 3 red — all three in the Mac scheme, all three one test:

| Run | Test | What the xcresult says |
|---|---|---|
| 33892227434 (main, 09-04), 33937471328 (dependabot, 09-05) | `TranslationRoundReportTests.test_theVerbsReachTheActionsWithTheirRowsIds` | `[] != ["ann-2"]` — the second press landed on a container the first press's `Task` still had disabled |
| 33115733566 (main, 08-27) | `StatementEditorMountTests.test_aMintAndAReturningPaneDoNotBothBindTheSameStatement` | its own precondition arm: the barging open gate granted `[mint, wedge, pane]` out of park order three attempts running, so the interleaving under test never happened |

CI keeps a `TestResults-Mac` xcresult per run (~130 MB); `gh run download
<id> -n TestResults-Mac` from inside the repo is the way to the assertion
text, since parallel-mode stdout carries only names and durations.

Local, the eighteen `maugham-full-*.xcresult` bundles since 09-02: 15 green,
3 red — `AnnotationChangeEventTests`' two echo tests (third sighting on the
line; the collector heard a `stmt-…` announcement from a document another
suite in the same worker left open), the Keep end-to-end press in
`AnnotationsPaneChoiceTests` (hardened once on 09-02, red again 23:03), and
`test_toolsList_returnsAllExpectedTools` — which was not a flake: the census
commit for the two propose tools landed five minutes after that gate.

Every CI red and two of the three local reds are one shape: **a mounted
SwiftUI view, a synthesised accessibility press, then a wait — a deadline
poll or a fixed run-loop sleep — for an asynchronous effect.**

## What was done

**Fixed (invariant guards):**

- `AnnotationChangeEventTests` — both announcement collectors take the doc
  under test and drop everything else. The echo rule is tripwire 21's class.
- `StatementEditorMountTests.test_aMintAndAReturningPaneDoNotBothBindTheSameStatement`
  — rewritten order-agnostic. It parks the mint and the returning pane's load
  on the production gate, releases, captures the first `Document` seen bound,
  lets the other drain, and asserts one live `Document`, never closed, with
  the writer's character in it. The words-never-lost invariant holds whichever
  load the gate grants first, so there is no arrangement to retry for and no
  precondition to fail on. 4/4 green, ~2.1 s each.
- `ScreenplaySingleParseTests` — `FontWarmup.ensure()` in `class setUp`
  (fontd cold-start shape, two 0.000 s sightings in August).
- `AnnotationChangeEventTests`' source census walks the PATH enumerator: the
  URL enumerator returns resolved paths, so a checkout behind a symlink
  (`/tmp` → `/private/tmp`, which is where this session's gate worktree lived)
  made every entry `/privateCompiler/…`. `resolvingSymlinksInPath()` is no
  fix — Foundation strips `/private` on purpose. Not a flake, but it would
  have been reported as one the next time a gate ran from a worktree.

**Cut — 81 tests, none pinning a hard invariant, every decision they guarded
already asserted without a window:**

| File | Before → after | Kept representative |
|---|---|---|
| `DepartmentRunTests` | 94 → 73 | none needed (other press tests remain) |
| `DiagnosticsPaneTests` | 180 → 170 | `test_readerLineButton_callsOnOpenBoard` |
| `AnnotationsPaneChoiceTests` | 33 → 22 | the sheet's Commit→`onCommit` press and its blank-heading refusal |
| `LetterSectionTests` | 48 → 39 | `test_addToIntentCallsTheHostsHandler` |
| `ReviewRoundCockpitTests` | 84 → 76 | `test_clearingTheAskReachesTheHostAndStartsNoRun` (carries the no-spawn billing guard) |
| `DesignGateTests` | 60 → 55 | — |
| `TranslationRoundReportTests` | 16 → 13 | — |
| `DepartmentPaneTests` | 53 → 50 | `test_theSheetOffersTheBooksOwnLanguageCheckedAndCompilesIt` |
| `AnnotationsPassOrderNudgeVerbsTests` | 5 → 2 | — (every effect async) |
| `DiagnosticPromoteToTaskTests` | 15 → 13 | — (its hosting block went too) |
| `PaletteWallDoorTests` | 29 → 27 | — (the AX route self-skipped in every process it ever ran in) |
| `PracticeSectionTests` | 19 → 18 | `test_pressingAHotspotRowOpensThatRowsOwnChapter` |
| `ReferencesPaneTests` | 20 → 19 | `test_theShelfDrawsARowPerPinAndAClickPromotesIt` |
| `TreeFindOverlayTests` | 11 → 10 | — |
| `StatementPaneStrataTests` | 51 → 50 | — |

Dead helpers, spies, probes and hosting blocks went with them (≈3,000 lines).

**Kept deliberately:**

- `StatementDraftHandoffTests` — the words-typed-before-the-file-existed
  invariant (issue #21). Excluded from the cull; two of its tests press a
  keystroke and wait, and they are on the tripwire's allow-list by name.
- The synthetic-click family (`TreeTravelTests` and the seven files sharing
  `click(at:)`) — self-skips without a key window, one sighting since
  08-12, and the only detector of the shipped click-on-the-name regression
  (2026-08-12). A judgment call Denver can overrule.
- `AssistantColumnTests`' close-press and `IntentStripTests`,
  `PlanTreeStructureCreationTests`, `ReviewRoundCockpitLetterScrollTests`,
  `DesignGateTests.test_theDeskListensForTheGatesVerdict`,
  `DiagnosticsPaneTests.test_bothHostsTakeTheLedgerVerbsFromTheOneBuilder` —
  the first-pass awk matched the word "press" in prose; none of them presses
  and waits.

**Guarded going forward — tripwire 33.**
`TripwireGrepTests.test_noNewTestPressesAControlAndThenWaitsForItsEffect`
scans every test function under `MaughamTests/` for a press call followed by
`pumpUntil(`/`waitUntil(`/`pump(`, comment lines ignored, and fails on any
not named in `pressThenWaitRepresentatives`; a second assertion fails when
the allow-list names a test that no longer presses and waits, so the list
stays a census. A planted-offender self-check covers the three press forms
and four innocents.

## Residual risks the agents named

Wirings whose only guard was a deleted press, in case one is worth a
windowless pin later (a source census in the shape
`AnnotationScopeTests.test_everyVerbBumpsTheRefreshTokenSoProjectScopeReReads`
already uses):

- A two-language desk's second row carrying the second row's tag on Run,
  Rename and the edition-brief door (wrong-row capture).
- The design gate's verb write-back reaching the window; the desk's Design
  Run from press through the real orchestrator to the drawn round.
- The nudge's Mark done / Skip reaching `onSetPassState`; the row's This is a
  choice reaching `QueueLedgerVerbs.makeChoice`; the diagnostics pane's
  Promote to Task button; the cockpit's Cancel reaching `onCancel`; the
  cockpit's letter disclosure opening the section; the orphan row's Remove
  reaching `RulingsStratum.revoke`.
- The mint sheet trimming a padded name and the Add Language sheet lowering a
  typed tag before sending.

## Gates

| Iteration | Tree | Result |
|---|---|---|
| 1 | d77b695f | 8147 / 1 / 10 — the red was the census symlink artefact above |
| 2 | d47ed7af | 8105 / 1 / 10 — same artefact |
| 3 | 4fc1fe5e | 8075 / 0 / 10 |
| 4 | tripwire 33 + the last four Stet presses | 8074 / 0 / 9 |

Burn-in on 4fc1fe5e, two consecutive full gates back to back:
8076 / 0 / 9 and 8076 / 0 / 9.
