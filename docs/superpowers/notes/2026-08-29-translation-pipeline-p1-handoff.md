# Translation pipeline — handoff after Plan 1 (2026-08-29)

Written for a fresh session picking up Plan 2. Everything below is on `main` at `ef538475` (fast-forwarded; full gate 7313 tests / 0 failed on that exact commit).

## Where things stand

- **Spec (binding):** `docs/superpowers/specs/2026-08-28-translation-pipeline-design.md` — v2, "designed around the author's experience", re-derived against v0.33.0. Read §1–§13 once; §13 lists the five plans.
- **Plan 1 — BUILT and merged:** `docs/superpowers/plans/2026-08-28-translation-pipeline-p1-cast-rulings-wire.md`. What now exists:
  - `ProductionRole.Role.reader(language:)` / `.collator(language:)` with presets (es Ocampo/Borges, fr Colette/Yourcenar, de Bachmann/Schlegel, ja Enchi/Futabatei) and preset doctrines (`effectiveBrief` non-nil for both) — `Packages/MaughamCore/Sources/MaughamCore/ProductionRole.swift`.
  - `ProjectManifest.storedReader/storedCollator(for:)`; `ProjectStore.readerRole/collatorRole(for:)` (lazy mints, RUN-ONLY — read paths never mint) through one shared `mintedLanguageRole`; `EditionStatus.readerName/collatorName(for:in:)` read-only — `Maugham/Stores/ProjectStore+ProductionRoles.swift`, `Maugham/Publish/EditionStatus.swift`.
  - `Ruling.directive` / `.paragraphId` / `.glossary` computed over `text`, composers `Ruling.directiveText(paragraphId:_:)` and `Ruling.glossaryText(term:rendering:note:)` (both `lineSafe`: em-dash → hyphen, guillemets stripped, whitespace collapsed), `Ruling.Provenance.translatorsNote/.glossary` — `Packages/MaughamCore/Sources/MaughamCore/RulingShapes.swift`. `RulingsSection` untouched.
  - `ReportJSON` (shared helpers; `DiagnosticIngest` keeps its own copy on purpose), `ReaderReport`, `CollatorReport`, and `TranslatorReport` with `Mode` (`.translate` default / `.fix(briefedNoteIds:)`), `addressed`/`declined`/`summary`/`glossaryProposals`, `fixSchemaDescription` — all in `Maugham/Compiler/`.
- **Plans 2–5 — NOT written.** Per CLAUDE.md rule 11 each is written against the built code of the one before it.

## Plan 2 — briefings, cold calls, and the two verbs (next)

Scope from spec §13 item 2: `ReaderBriefing` / `CollatorBriefing` (pure, spec §2); `TranslatorBriefing.mode` (`.translate` gains directives per work item + the glossary table; `.fix(notes)` work-list = the noted paragraphs, repair sentence) and the *directed* work-list (`stale ∪ missing ∪ directed`, directed = a directive ruled after the paragraph's `TranslationRecord.at`); the sealed `ClaudeCLISession` confinement (`Confinement.bridged(URL) | .sealed` — sealed emits `--tools ""`, `--strict-mcp-config`, no `--mcp-config`, no `--allowedTools`) and `ColdCall` (fresh tool-less process per call, four callers later: reader, collator, gloss, ask-the-collator) with its spawn-args pin and grep tripwire; teardown census widened to a third sibling; `DepartmentCastSheet` grows to three name fields (translator, reader, collator) and **Rename …** offers all three; **Translator's note…** in the editor (a directive minted through `RulingPerformer.rule` — home craft intent `.document(id)` by default or the edition brief, provenance `Ruling.Provenance.translatorsNote`).

**Research already done — read the plan's appendix first** ("Appendix — facts gathered for Plan 2" at the end of the P1 plan): the editor has NO context menu (follow `SelectionToolbarView` + `ReviewAnnotationComposerView`, never `NSPopover`); selection→paragraph via `capturedSpanForSelection` (needs a selection) or `paragraphLocator` over `Document.paragraphId(at:)` (caret); `QueryRuling.commit` cannot be reused (hard-codes `.editionBrief` at `.project`); a new `⌘⌥` binding must also land in `KeyboardShortcuts.all` or `DocSyncTests` fails (free letters C G J M U X Y); cast-sheet call sites in `DepartmentPaneHost.swift` ~334–466; `ClaudeCLISession.arguments` ~378 emits the bridge unconditionally today; the teardown census is `TranslatorEnvironmentTests.test_everyWindowEndingPathShutsEverySessionDown`.

## Carried forward from P1's reviews (not defects, decisions for later plans)

- `TranslatorReport.Mode.fix` cannot express "summary required" (leg 7) — Plan 3 decides whether the pipeline enforces it after parse or `Mode` grows a flag.
- `CollatorReport.Departure` carries no id; leg 7 is briefed through `Mode.fix(briefedNoteIds:)` — Plan 3 mints annotation ids (spec §6) before briefing leg 7.
- Adopt on a glossary proposal (Plan 5) must refuse an empty term before composing — a guillemet-only term sanitizes to empty and composes an unparseable line.
- Plan 4's doc sweep owes: `Maugham/Compiler/AREA.md` entries for `ReportJSON`/`ReaderReport`/`CollatorReport`; a statements-guide sentence that composers hyphenate em-dashes and strip guillemets; `TranslatorReport.parseIdList` → `ReportJSON.parseStringList` only if a second string list appears.

## Process lessons from this run

- **`./gen.sh` after ADDING any source/test file** (now in CLAUDE.md's build flow). Two implementers' `-only-testing:` runs silently executed 0 tests on a stale project; the gate's test count exposed it (7177 → 7193).
- `./scripts/test.sh full | tail` reports `tail`'s exit code; read the kept xcresult (`xcrun xcresulttool get test-results summary --path …`) for the verdict.
- A subagent "waiting on a background gate" with no `xcodebuild`/`test.sh` in `ps` is not hung on the gate — its monitor never fired; message it to run in the foreground.
- Subagent-driven dispatch worked: haiku for transcription tasks with complete code in the brief, sonnet for multi-file/refactor tasks, opus for the whole-branch review (it found three real Important findings the seven task reviews could not see, one of them a plan defect).
