# Hardening: the open issues of 2026-11-01

Branch `claude/hardening-2026-11-01` (from origin/main `b2ddb249`). One branch closes #128, #129, #130, #131, #132, #133, #134 and all of #113. #106 stays a standing ruling (split a big file only when a feature needs substantial work in it; none of these fixes do).

Sources: each issue's body (`gh issue view N`), `docs/superpowers/notes/2026-11-01-sweep.md` §3 (S1–S7), `docs/superpowers/notes/2026-10-25-maintainability-review.md` (E3, F5–F8, F14, F18). **Line numbers in those notes have drifted: find code by symbol, not by line.**

## Rules for every task

- Read the area guide CLAUDE.md names for each path before editing it.
- Test first: write the failing test, watch it fail for the stated reason, then fix.
- **Disable experiment on every negative assertion**: remove the guard, watch the test fail, restore it, put the output in your report.
- Run `./gen.sh` after adding any file. Gate with `./scripts/test.sh` (and `./scripts/test.sh core` when `Packages/MaughamCore` changes — both schemes then). Never raw `swift test`/`xcodebuild test`. Check other builds with `pgrep -x xcodebuild`.
- Tests: windowless where possible; no press-then-wait (tripwire 33). Paragraph-id literals use the valid alphabet (tripwire 8).
- Annotation/Rewind behaviour has register files (`register/reconciliation/Annotations.*`, `Rewind.*`): read the filings first; a fix updates the claim and flips any filing `VIOLATES→COMPLIES` in the same commit (`register/reconciliation/PROTOCOL.md`).
- One commit per task, message `hardening 11-01 task N — …`, ending with the attribution lines. Don't push.
- Report: what changed (files), the tests added and their disable-experiment output, the gate result, anything you judged that the coordinator should check.

## Tasks

### Task 1 — #131 (S1+S2): an external Research-table change refreshes the figures that pin it [opus]

Symptom: another device (or MCP writing into `research/`) changes a Research CSV; figures pinning it keep stale values and a stale "source-changed" badge until an unrelated fill. A local edit refreshes correctly. Also: an open grid reloaded from an outside change repaints but the figure on screen beside it stays stale.

Cause (verified by the sweep): the external-change arm `.otherProjectFile` in `DocumentStore` calls `researchFileMayHaveChanged(at:)` (`DocumentStore.swift`), which only pokes open grids (and returns early when none are open); `ResearchTableHost.reloadUnlessEdited()` invalidates no figure cards. `invalidateFigureCards()` lives in `DocumentStore+Figures.swift`. Card owners watch `manifest.research` by identity, which a content change doesn't touch.

Requirement: any external content change to a Research asset that some figure could pin invalidates figure cards — with and without a grid open on it — and a successful outside-change reload of an open grid does too. Don't invalidate on every unrelated project file (only Research assets). Tests: a synced/outside CSV change re-fills a pinning figure's card, grid closed and grid open; a non-Research file change does not invalidate (disable experiment on that).

### Task 2 — #132 (S3): CSV separator detection agrees with the row scanner [sonnet]

`Packages/MaughamCore/Sources/MaughamCore/Table/TableCSV.swift`: `rows()` opens a quoted field only when `"` is a field's first scalar; `detectSeparator` flips quote state on every `"`. A `;` file with `5"` in row 1 detects the wrong separator, parses as one column, and applies the wrong decimal locale, silently.

Requirement: both scanners agree on what a quoted field is — preferably one shared field-boundary scanner, not two copies of the rule. Tests: a `;`-separated file with `5"` mid-field in row 1 detects `;` and parses the right column count; existing quoted-separator cases still pass. Core change: `./scripts/test.sh core` plus both schemes (`./scripts/test.sh` and `./scripts/test.sh phone`).

### Task 3 — #133 (S4): a failed sidecar write doesn't silently drop a table's formats [sonnet]

`Maugham/Editor/ResearchTableHost.swift` `write`: sets `diskHash` after `performFileSave`, then writes the sidecar in a `do/catch` that only logs. On failure the sidecar keeps the old `contentHash` and the next open drops every format, width and header flag.

Requirement: a sidecar-write failure is not silent — surface it the way the CSV save-failure path does — and the next save retries the sidecar so the pair converges. Choose the mechanism against the real file; say which in the report. Test: inject a sidecar write failure (use an existing seam, or add the smallest one), then a successful save; the reopened table keeps its formats. Disable experiment on the retry.

### Task 4 — #128.1: undoing a Reject or Archive undoes one decision [opus]

`Maugham/OpLog/Document+Annotations.swift`: the reject and archive undo closures reopen the note straight to `.open`. If the note already had an answer (answering over an answer is allowed), one ⌘Z discards both. Stet was fixed for this (#41 A2, RULING-22); the figure verbs now do it right — read `FigureDocument+Annotations.swift` (`reacceptAnnotation` and the undo dispatch around it) and mirror its shape: the undo puts back the answer the decision displaced.

Tests: reject over an earlier accept, ⌘Z → accepted (not open); same for archive; and reject/archive over an open note, ⌘Z → open. Read RULING-22 and the Annotations filings first; update the claim.

### Task 5 — #128.2: partial restore handles and names the accepted suggestions it strands (RULING-28) [opus]

`Maugham/Views/PartialRestorePicker.swift`'s manuscript path does no stranded-accept handling and its sheet names no collateral. Restoring text to a checkpoint from before an accepted suggestion leaves the note "accepted" over text that no longer has the change. The figure restore reopens the note in the same op and names it in the sheet — find it and match it. The full rewind's step 8 in `Document+Rewind.swift` is the manuscript precedent for how a stranded accept resolves (revert to open if the paragraph survives, archive if it's gone).

Requirement: the decision of which notes are stranded lives in the op-log layer (not the view), is computed once and used by both the sheet's wording and the restore; the restore and its reopen are one undo step. Tests: windowless — the stranded set for a partial restore, the resulting statuses, the sheet's collateral text via its value type, and ⌘Z restoring both text and status. Read RULING-28 and the Rewind/Annotations filings first.

### Task 6 — #128.3: rewind's latest-lifecycle walk honours Stet and Reopen [opus]

`Maugham/OpLog/Document+Rewind.swift` step 8 builds `latestLifecycleBySource` from a hand-listed set `[.claudeAccept, .claudeReject, .claudeArchive, .claudeAcceptRevert]`. Stet and reopen are missing, so a Stet over an accept is judged a stranded accept and reverted over the writer's Stet. Step 9 in the same file already asks `AnnotationDeriver.isHonouredLifecycleOp` instead of restating the rule — do the same in step 8.

Tests: accept → Stet, rewind past the accept → the note stays stet (disable experiment: restore the old list, watch it fail); the existing stranded-accept tests still pass. Also check `RewindImpact.swift` (the preview) agrees. Update the Rewind claim.

### Task 7 — #113 F5, F6, F7, F14: block parser fixes [sonnet]

All in MaughamCore unless noted; detail in the 10-25 review note under each ID.
- **F5 (data loss):** a pipe-less-looking last row starting `Table: ` that has an unescaped column pipe (`Table: old totals | 5`) is taken as the caption and a grid Save drops it (`ManuscriptBlocks.swift`). Reclaim a caption only when the line has no unescaped column pipe.
- **F6:** CRLF defeats table/delimiter detection and leaves `\r` in headings and captions (`MarkdownBlockParser.swift`). Normalise once at the entry (`parseWithLineRanges`) — check that the line ranges it returns still map onto the caller's original string, and test that.
- **F7 (Denver ruled: warn):** a figure line with a malformed attribute block (`{#fig:}`) reports `.malformedLabel` as headings and table captions do, instead of silently becoming a paragraph.
- **F14:** drop or reword the "verbatim port of" comments in `MarkdownBlockParser.swift` that name deleted originals.

Tests for F5, F6, F7. Core gate + both schemes.

### Task 8 — #113 E3, F8, F18 [sonnet]

- **E3:** `ManuscriptIndex` (Core) has zero production callers and a weaker figure-path rule. Delete it and its tests (and any comment that points to it as a live thing). Confirm zero production callers first with a grep and paste it in the report.
- **F18:** `SynthesisSourceTests.test_aSchemaNineManifestIsRefusedByABuildThatStopsAtEight` never calls a decoder with a lower ceiling. Give `decodeGuardingSchema` an injectable ceiling (default = the current schema) and make the test real: a ceiling-9 build refuses a schema-10 manifest. Disable experiment.
- **F8 (Denver ruled: keep behaviour, fix the ADR):** reword ADR 0033 §1 so "is refused" is the Report profile's rule (outside it, a remote figure URL or a missing citation key is a warning); check §D8 still reads true.

Core gate + both schemes.

### Task 9 — #129 + #130: flakes and tooling [sonnet]

Flake policy (Denver): fix a flake only if the test guards a hard invariant (CLAUDE.md invariant, tripwire, constitution must, register claim) — wait on the real condition, isolate state. Otherwise **delete it outright** (no `XCTSkip`, no retries), and cull untested siblings of the same shape. For each test in #129, record the classification and what you did:
- `CanvasViewMountingEditingTests.test_returnInAScrapFinishesItAndTheCanvasHoldsTheKeyboard`
- `DiagnosticsPaneTests.test_keepThisLetterFilesAResearchNoteAndSaysWhatItCalledIt`
- `ProjectSubjectReachabilityTests` `test_everyWindowStateThatLetsAResearchSubjectStandCanAlsoClearIt`, `test_theFindOverlayIsNotATrapBecauseTheTreeComesBack`
- `UpdateInstallerTests.test_atomicSwap_crossVolume_kernelRejectsRenamexNp` — times out on most runs on this Mac. Find what it waits on. The updater's in-place swap is release-critical, so if it guards real install safety prefer a fix that doesn't depend on this machine's volumes; report your reasoning.
- `ClaudeCLISessionTests` — check whether origin's `fix/cli-liveness-flakes` work already landed on main before touching it.

#130: refresh `scripts/skip-baseline.txt` from a normal run (account for each line that changes); make `register/scripts/23-generate-rulings.py` run clean on RULING-6 by acknowledging the amendment in the ledger the way the script expects (read the script; don't just rewrite the stored hash unless the amendment is already acknowledged).

Gate: `./scripts/test.sh full`.

### Task 10 — #134 (S5–S7) and the closing doc sweep [haiku]

- `docs/roadmap.md`: reword the plan-5 line ("no writer-facing surface yet" is false); add a "Report figures & tables (plans 6–9)" ✓ entry — Format ▸ Table, the in-place grid, Research tables in the grid, Use in Document, the Figures binder section, Insert ▸ Existing Figure — released in v0.43.0 (check the release notes in `docs/release-notes/` for the exact list and wording).
- `docs/product.md` Reports paragraph: one sentence on the table grid and figures.
- `docs/problem-map.md` Word/export row: split into ✓ Word and • Shunn.
- Sweep the AREA guides touched by tasks 1–9 for now-false sentences (CLAUDE.md rule 10).

## After the tasks

Whole-branch review (opus) over `main..HEAD` with the task reports, then fix wave, `./scripts/test.sh full`, merge to local main. Close the issues with commit references when pushed.
