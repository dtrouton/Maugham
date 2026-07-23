# Publish Pipeline Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the 2026-07-23 publish-pipeline spec (`docs/superpowers/specs/2026-07-23-publish-pipeline-improvements.md`): land the LaTeX-defects branch with an honest defect-4 ending (P0), per-section `include` flag (F1), edition-parity previews + `dry_run` (F2), `read_preview_page` (F3), EMISSION.md auto-refresh (F5), fountain title block through hooks (F6), translation audit polish (F8), and the doc/skill additions (F4 + the F7 `{language}` note — F7's code is already shipped; F8's `read_translation.verbatim` is already shipped).

**Architecture:** All section filtering happens at the `ProjectASTBuilder.Source` layer (the `FilteredASTSource` precedent in `PreviewCompiler.swift:76-85`), never in the emitters. The translation coverage gate walks the same filtered set. `dry_run` short-circuits `CompileOrchestrator.compile` after the gate, before any artifact/Publication/version mutation. `read_preview_page` reuses `ImageResponseBuilder`'s crop-on-demand envelope against the newest file in the deterministic preview dir. EMISSION.md becomes compile-time-refreshed app-owned content stamped with the app version.

**Tech Stack:** Swift / SwiftUI / XCTest; bundled tectonic for compile-probe tests; PDFKit for rasterization.

## Global Constraints

- Build/test: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`; narrow with `-only-testing:MaughamTests/<ClassName>` (class name, NEVER a folder path — folder paths silently run 0 tests). New test FILES require `./gen.sh` first. MaughamCore changes additionally need `swift test` in `Packages/MaughamCore` AND the phone scheme (`-scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17'`).
- **A new MCP tool (T5) or changed tool schema (T3/T4) breaks ≥3 tools-list/count tests** (`DocSyncTests`, `MCPProtocolHandlersTests` expected-tools literal, catalog tests) and requires same-commit count bumps in `CLAUDE.md` ("**51 tools**" → new count) and `Maugham/MCP/AREA.md` (`## Tool catalogue (NN)` + a catalogue line). Read `Maugham/MCP/AREA.md` before any MCP task.
- **EMISSION.md is generated**: any change to emitted LaTeX or contract prose edits `Maugham/Publish/EmissionContract.swift` and regenerates `Maugham/Resources/PublishStarter/EMISSION.md`; `EmissionContractTests.test_committedEmissionDoc_matchesGeneratedContract` is an exact-equality gate.
- Config schema changes follow ADR 0015: additive-optional, `decodeIfPresent ?? default` in `Section.init(from:)` (`PublishConfig.swift:194-200`) so RFC-7396 merge-patches survive; snake_case CodingKeys; no migration.
- Compile-probe tests invoke bundled tectonic (slow, real compiles) — keep them in `MaughamTests/Publish/` alongside `StarterTemplateDefectProbeTests` and verify they actually executed.
- Working branch: `feat/publish-pipeline-2026-07` off `main`. Commit per task, `feat(publish)`/`fix(publish)` style.
- The stale worktree `.claude/worktrees/hardening-2026-07/` mirrors some publish files — never read or edit anything under `.claude/worktrees/`.

---

### Task 1: P0a — cherry-pick the LaTeX-defects branch

`c91ffc8` (`fix/publishing-latex-defects`) applies to main with zero conflicts (verified via merge-tree; no target file changed since the merge-base; main's `\\` join sites at `LaTeXBodyEmitter.swift:121/:138/:212` are still unfixed, and `\MaughamLanguage` lives in `preamble.tex`, away from the ToC-dispatch fix region).

**Files:** brought in by the cherry-pick: `Maugham/Publish/LaTeXBodyEmitter.swift`, `Maugham/Publish/EmissionContract.swift`, `Maugham/Resources/PublishStarter/{prose.tex,screenplay.tex,EMISSION.md}`, `MaughamTests/LaTeXBodyEmitterTests.swift`, new `MaughamTests/Publish/StarterTemplateDefectProbeTests.swift`.

- [ ] **Step 1:** `git cherry-pick c91ffc8` — must apply with zero conflicts (if any conflict appears, STOP and report; the assessment says there are none).
- [ ] **Step 2:** `./gen.sh` (the cherry-pick adds a new test file).
- [ ] **Step 3:** Run the gates: `xcodebuild … -only-testing:MaughamTests/EmissionContractTests -only-testing:MaughamTests/LaTeXBodyEmitterTests -only-testing:MaughamTests/StarterTemplateDefectProbeTests -only-testing:MaughamTests/CompileLanguageThreadingTests -only-testing:MaughamTests/PublishingEndToEndTests` — all pass, nonzero counts, and confirm the four probe tests actually compiled (not skipped).
- [ ] **Step 4:** No further commit needed (the cherry-pick is the commit). Do NOT delete the source branch yet — that happens at merge time.

### Task 2: P0b — six-piece defect-4 reproduction, then fix or harden the contract

**Files:**
- Modify: `MaughamTests/Publish/StarterTemplateDefectProbeTests.swift` (reuse its `FixedSource`/harness at :50)
- Possibly modify: `Maugham/Publish/EmissionContract.swift` + regenerate `Maugham/Resources/PublishStarter/EMISSION.md` (the "document as required" ending)
- Possibly modify: `Maugham/Publish/LaTeXBodyEmitter.swift` (only if the repro reveals an emitter-side scoping bug)

**Interfaces:** none consumed by later tasks.

- [ ] **Step 1: Write the field-shaped repro test** — six pieces; piece 2 is prose with a style-file-scope `\renewcommand{\textbf}[1]{\marginpar{#1}}` (style file attached via `config.sections[pieceID].styleFile`); piece 4 is fountain WITH a title block (Title:/Credit:/Author:); pieces 5-6 prose using `\textbf`. Compile the six-piece book with the CURRENT starter templates and assert piece 4's title block and pieces 5-6's bold render un-restyled (no `\marginpar` leakage — assert the PDF text layer does not contain the marginpar'd content out of place, and/or grep the generated `body.tex` for the renewal reverting before piece 3's section start; follow the existing probe tests' assertion style).
- [ ] **Step 2: Run it.** Two honest outcomes:
  - **Reproduces** (restyling leaks): investigate the triggering shape (`\marginpar` body, fontspec lazy family setup, fountain `\providecommand` block interaction) and fix at the emitter/starter level; keep the repro as the regression pin. Report the mechanism in the task report.
  - **Does not reproduce:** keep the test as a permanent probe, and make the pieceheading-hook scoping pattern **required, not advisory** in the contract: strengthen the scoping paragraph added by `c91ffc8` in `EmissionContract.swift` (the string near :145-147's MAY/MAY-NOT block) to state that robust-command renewals in style files MUST go inside the `\pieceheading` hook, regenerate EMISSION.md via the byte-gate test, and note the field-vs-probe discrepancy remains unexplained.
- [ ] **Step 3:** Run `EmissionContractTests` + `StarterTemplateDefectProbeTests` — green, nonzero.
- [ ] **Step 4:** Commit: `fix(publish): six-piece defect-4 reproduction probe — <reproduced-and-fixed | not reproduced; hook pattern now required>`

### Task 3: F1 — per-section `include` flag

**Files:**
- Modify: `Maugham/Publish/PublishConfig.swift` (Section struct :160, custom decode :194-200, CodingKeys :202-207, encode)
- Modify: `Maugham/Publish/CompileOrchestrator.swift` (wrap astSource post-config-load ~:48; gate call :118-131)
- Modify: `Maugham/Publish/PreviewCompiler.swift` (default subset :48, `FilteredASTSource` :76-85)
- Modify: `Maugham/Publish/TranslationCoverage.swift` (`check` :45 gains an excluded-ids input)
- Modify: `Maugham/Publish/Republisher.swift` (same wrap, from the snapshot's config)
- Modify: `Maugham/MCP/Tools/PublishConfigTools.swift` + `Maugham/MCP/AREA.md` (document the field in `get/set_publish_config` descriptions)
- Tests: `MaughamTests/PublishConfigTests.swift`, `MaughamTests/Publish/TranslationCoverageGateTests.swift`, `MaughamTests/CompileOrchestratorTests.swift`, `MaughamTests/PreviewCompilerTests.swift`, `MaughamTests/RepublisherTests.swift`, plus a ToC compile probe in `MaughamTests/Publish/`

**Interfaces (produced, used by T4):**
- `PublishConfig.Section.include: Bool` (default `true`; snake key `include`)
- `PublishConfig.excludedSectionIDs: Set<String>` — computed: ids of sections with `include == false`
- `IncludeFilteredASTSource` (in `PreviewCompiler.swift` or a small new file beside it): wraps any `ProjectASTBuilder.Source`, drops pieces whose id is in the excluded set. Generalize/reuse the existing `FilteredASTSource` shape rather than duplicating it.
- `TranslationCoverage.check(projectStore:language:excludedSectionIDs:)` — excluded docs produce no gaps and don't feed the zero-layer guard denominator.

- [ ] **Step 1 (TDD):** Config tests: decode with `"include": false`; decode with the field ABSENT (⇒ `true`, merge-patch survival); encode round-trip; `excludedSectionIDs`.
- [ ] **Step 2:** Implement the config field (ADR 0015 shape: `decodeIfPresent(Bool.self, forKey: .include) ?? true`).
- [ ] **Step 3 (TDD):** Behavior tests: orchestrator compile with one excluded section → emitted body lacks it (both formats); coverage gate with an excluded untranslated stub → passes; preview with no `section_ids` → included-only; preview with explicit `section_ids` naming an excluded section → renders it (exploratory override); republish from a snapshot with exclusions reproduces the subset; ToC compile probe: 3 pieces, middle excluded, PDF ToC lists exactly the two included titles and the compile is clean (no dangling `\pageref`).
- [ ] **Step 4:** Implement: compute the excluded set from the EFFECTIVE config in `CompileOrchestrator.compile` (after :48/:64 so language overrides can't diverge the set), wrap `astSource`; pass `excludedSectionIDs` into `TranslationCoverage.check`; in `PreviewCompiler`, when `sectionIDs == nil` subset to included ids, when explicit leave as-is; `Republisher` wraps from the snapshot config. Snapshot round-trip is free (config already snapshotted) — pin it with an assertion in the republish test.
- [ ] **Step 5:** Full publish-area test pass (all classes named above), commit: `feat(publish): per-section include flag — subset editions as first-class Publications (F1)`

### Task 4: F2 — preview language/allow_stale + compile dry_run

**Files:**
- Modify: `Maugham/MCP/Tools/CompileTools.swift` (`CompileTool` params :84-99 + handler; `PreviewCompileTool` params :175-188 + handler :200)
- Modify: `Maugham/Publish/PreviewCompiler.swift` (init/`preview` gain `language:`/`allowStale:`; apply `config.effectiveMetadata(language:)` and `LanguageSuffixedFile.resolvingStyleFiles` exactly as `CompileOrchestrator.compile` does at :64-80; invoke `TranslationCoverage.check`/`applyGate` with T3's excluded set)
- Modify: `Maugham/Publish/CompileOrchestrator.swift` (`dry_run`: after the gate at :118-131, return a new `.dryRunPassed(warnings:)` outcome without compiling, snapshotting (:135), minting (:180-202), event-posting, or version-bumping (:214-217))
- Modify: `Maugham/MCP/AREA.md` (+ CLAUDE.md only if tool count changes — it does NOT in this task)
- Tests: `MaughamTests/PreviewCompilerTests.swift`, `MaughamTests/CompileOrchestratorTests.swift`, `MaughamTests/MCP/Tools/CompileToolsTests.swift`, `MaughamTests/Publish/CompileLanguageThreadingTests.swift`

**Interfaces:**
- Consumes T3's `IncludeFilteredASTSource` + gate signature.
- Produces: `preview_compile` params `language: String?`, `allow_stale: Bool?` (validated with `TranslationRecord.isValidLanguageTag` like compile :105-108; gate-failure response = same shape as compile's `.failed` encoding); `compile` param `dry_run: Bool?` → response `{"status":"dry_run_passed","warnings":[…]}` or the standard failed/gate-blocked shape; NO Publication, NO version churn, NO output files.

- [ ] **Step 1 (TDD):** preview-with-language resolves `.es` templates (LanguageSuffixedFile) and substitutes translated text; preview gate parity (blocked without `allow_stale` when stale, identical report shape to compile); `dry_run` leaves publications list, `nextVersion`, and the output dir untouched while returning the gate verdict; schema round-trip tests for the new params.
- [ ] **Step 2:** Implement (thread params; keep `PreviewCompiler`'s no-snapshot/no-Publication property).
- [ ] **Step 3:** Expect and fix the tools-list/schema test breakage class (Global Constraints) — schema changes only, count unchanged.
- [ ] **Step 4:** Commit: `feat(publish): preview_compile language/allow_stale + compile dry_run — edition parity for previews (F2)`

### Task 5: F3 — `read_preview_page` (tool count 51→52)

**Files:**
- Create: `Maugham/MCP/Tools/ReadPreviewPageTool.swift` (model on `ReadPublicationPageTool`, `PublicationTools.swift:53-156`)
- Modify: `Maugham/MCP/MCPTool.swift` catalog (+1), `Maugham/MCP/AREA.md` (catalogue 52 + line), `CLAUDE.md` (**52 tools**), the ≥3 tools-list tests
- Test: `MaughamTests/MCP/Tools/ReadPreviewPageToolTests.swift` (new file → `./gen.sh`)

**Interfaces:**
- Consumes: `ImageResponseBuilder.encodeEnvelope(nsImage:region:maxDimension:quality:)` (crop-on-demand, 720KB budget — tripwire 10); the deterministic preview dir `.maugham/publish/build/preview/` (`PreviewCompiler.swift:42-46`).
- Produces: `read_preview_page(project_id, page_number, max_dimension?, quality?, region?)` — resolves the NEWEST `.pdf` in the preview dir (mtime); fails loudly `"No preview output — run preview_compile first"` when none; PDF-only like the publication reader; response includes the resolved preview filename + its mtime so staleness is self-evident (a newer preview simply becomes the new resolution target — document that in the tool description).

- [ ] **Step 1 (TDD):** page render + region crop parity with `read_publication_page` on a preview-produced PDF; no-preview error; after a second preview overwrites, the tool reads the NEW file (freshness assertion via distinct content).
- [ ] **Step 2:** Implement tool + catalog + count bumps (same commit — DocSync enforces).
- [ ] **Step 3:** Run `ReadPreviewPageToolTests` + `DocSyncTests` + `MCPProtocolHandlersTests` + the catalog/tools-list tests; fix the expected-tools literals.
- [ ] **Step 4:** Commit: `feat(mcp): read_preview_page — closed visual loop for previews (F3, tools 52)`

### Task 6: F5 — EMISSION.md auto-refresh

**Files:**
- Modify: `Maugham/Publish/EmissionContract.swift` (add `static func renderProjectCopy(appVersion: String) -> String` = stamped header line + `renderMarkdown()`; `renderMarkdown()` itself byte-unchanged so the bundle gate is untouched)
- Modify: `Maugham/Publish/CompileOrchestrator.swift` (write the project copy to `.maugham/publish/EMISSION.md` after config load, BEFORE snapshot capture :135 so snapshots embed the fresh copy) and `Maugham/Publish/PreviewCompiler.swift` (same refresh — previews are where iteration lives)
- Tests: `MaughamTests/Publish/EmissionContractTests.swift`, `MaughamTests/CompileOrchestratorTests.swift`

**Interfaces:** none downstream. App version source: same mechanism the bundle already uses (`MaughamVersion`/Info.plist read — find the existing accessor; tests pass an explicit string).

- [ ] **Step 1 (TDD):** compile against a publish dir seeded with stale EMISSION.md → afterwards it equals `renderProjectCopy` for the current contract; every user-owned starter file (`template.tex`, `preamble.tex`, partials, `config.json`, style files) byte-identical before/after; header contains the version stamp; bundled-copy byte-gate still green.
- [ ] **Step 2:** Implement; commit: `feat(publish): EMISSION.md refreshes on compile/preview with app-version stamp (F5)`

### Task 7: F6 — fountain title block through a providecommand hook

**Files:**
- Modify: `Maugham/Publish/LaTeXBodyEmitter.swift` — `emitTitlePage` (:207-227) emits `\screenplaytitleblock{<title>}{<credit>}{<author>}{<notes>}`; add the macro to the emitted providecommands (pattern: `fountainProvidecommands` :167-171) with a default body reproducing today's bytes exactly (`\begin{center}\vspace*{1.5in}…{\Large\textbf{…}}\par…\end{center}\clearpage`). XHTML untouched.
- Modify: `Maugham/Publish/EmissionContract.swift` + regenerate `Maugham/Resources/PublishStarter/EMISSION.md` (the fountain example output changes — regenerate via the byte-gate).
- Tests: `MaughamTests/LaTeXBodyEmitterTests.swift` (macro emission unit), `MaughamTests/Publish/EmissionContractTests.swift`, plus a default-render equivalence compile probe (title block PDF text identical before/after) in `MaughamTests/Publish/StarterTemplateDefectProbeTests.swift` or a sibling.

**Interfaces:** the macro name `\screenplaytitleblock` (4 args: title, credit, author, notes — empty groups for absent fields) is now part of the emission contract; per-piece style files can `\RenewDocumentCommand` it inside the pieceheading hook per T2's scoping rule.

- [ ] **Step 1 (TDD):** emitter unit: fountain section with title block emits the providecommand declaration once + the macro call with escaped args; prose sections unaffected.
- [ ] **Step 2:** Implement; regenerate EMISSION.md; default-render equivalence probe green.
- [ ] **Step 3:** Commit: `feat(publish): fountain title block emits via \screenplaytitleblock hook (F6)`

### Task 8: F8 — translation audit polish (the unshipped remainder)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/TranslationDeriver.swift` (:39-41 — add `public var verbatimCount: Int { entries.lazy.filter { $0.verbatim }.count }`)
- Modify: `Maugham/MCP/Tools/TranslationTools.swift` (`translation_status` `Row` :247-255 + construction :324-331 gain `verbatim: Int`; tool description :265-272; `write_translation` warnings loop :118-136 gains the advisory: a non-verbatim entry whose `text` == current source text appends `"¶<id>: translated text equals source — mark verbatim: true if deliberate"` to `warnings`)
- Tests: `MaughamTests/MCP/Tools/TranslationStatusToolTests.swift`, `MaughamTests/MCP/Tools/WriteTranslationToolTests.swift`, `Packages/MaughamCore/Tests/MaughamCoreTests/TranslationDeriverTests.swift`

Note: `read_translation.verbatim` (F8a) already ships — do not re-add; cite it in the report.

- [ ] **Step 1 (TDD):** deriver `verbatimCount` unit (Core: `swift test --filter TranslationDeriverTests` in `Packages/MaughamCore`); status row carries the count; write advisory fires only for non-verbatim equal-text entries and never blocks the write.
- [ ] **Step 2:** Implement. MaughamCore changed → run Core package tests + Mac classes above + phone suite (Global Constraints).
- [ ] **Step 3:** Commit: `feat(translation): verbatim count on translation_status + equals-source advisory on write_translation (F8)`

### Task 9: F4 + F7 docs — template-variant pattern, {language} note, skill/topic updates

**Files:**
- Modify: `Maugham/Publish/EmissionContract.swift` (F4 prose: *"If your template inputs partials, the language edition needs a `template.<lang>.tex` whose `\input` lines point at language variants of those partials — the resolver picks the template variant and everything else follows from it."* Plus the spec's Documentation-section items not already landed by `c91ffc8`: xparse `\NewDocumentCommand` declarations are global across piece boundaries; active-catcode tricks destabilize hyperref) + regenerate EMISSION.md
- Modify: `Maugham/Resources/PublishStarter/template.tex` (two-line comment: language editions need a `template.<lang>.tex` re-pointing partial `\input`s)
- Modify: `docs/skills/translation-pass/SKILL.md` (template-variant pattern; literal-string style hooks are part of the piece's translation contract — the "Doctora:" stem-probe lesson) and the publishing guide topic in `docs/guide/` (the `{language}` filename placeholder note — F7's already-shipped feature — and a pointer that `sections.<id>.include` + `preview_compile language` are the edition-subset workflow)
- Tests: `EmissionContractTests` (regen gate), `PublishStarterTests` (template comment presence if it asserts content), the get_help/docs presence probe style test for the guide topic if one exists

- [ ] **Step 1:** Write all prose; regenerate EMISSION.md; run the gates above.
- [ ] **Step 2:** Commit: `docs(publish): template-variant pattern, {language} note, skill/guide updates (F4, F7)`

### Task 10: Final verification

- [ ] Full Mac suite green; phone suite green (T8 touched Core); Release-config build if any `ProjectWindow.body`-adjacent file changed (none expected).
- [ ] Whole-branch review (most capable model): emergent seams to interrogate — T3's excluded-set vs T4's preview gate (same set? computed once?), T3 exclusion vs T5 preview-page reading (preview of a subset), T6's F5-refresh vs T2/T7's EMISSION regenerations (project copy must match the FINAL contract), dry_run vs version-collision guard ordering.
- [ ] MCP dev-app smoke via `mcp__maugham-test__*`: init publish on a scratch collection, exclude a section, preview with language, read a preview page, dry_run compile (the commonmark-milestone lesson: dev-app smoke catches what green suites don't).
- [ ] PR to main. **User acceptance (from the spec):** reproduce both Playlist Volume One editions as versioned Publications v1.0/v1.0-es with MCP tools only — this needs Denver's real project and is the milestone's north star.

## Self-Review (plan time)

- Spec coverage: P0→T1/T2, F1→T3, F2→T4, F3→T5, F4→T9, F5→T6, F6→T7, F7→T9 (code shipped; docs only), F8→T8 (F8a shipped; remainder), docs section→T2/T9, acceptance→T10. Out-of-scope items untouched.
- Deviations from spec text, on evidence: F7 reduced to docs (feature exists at `OutputFilenameBuilder.swift:30-46`); F8a dropped (shipped at `TranslationTools.swift:166`); F5 refresh extended to preview (that's where the Playlist iteration pain lived); EMISSION "pinned deviation" language (F6) maps to contract-regeneration, the byte-gate's actual mechanism.
- Types consistent: `excludedSectionIDs` (T3) consumed by T4; `IncludeFilteredASTSource` naming consistent; `\screenplaytitleblock` arity fixed at 4.
- Known judgment points for implementers: exact `FilteredASTSource` generalization shape (T3), the app-version accessor for the stamp (T6), fountain title-block field list vs the 4-arg macro (T7 — verify against the parser's title-block model before fixing arity).
