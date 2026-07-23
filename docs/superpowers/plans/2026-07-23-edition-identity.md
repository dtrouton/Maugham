# Edition Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `docs/superpowers/specs/2026-07-23-edition-identity.md`: Publication identity `(version, language, format)`, edition compiles pinned to source versions, `next_version` bumps only on source compiles, list/read language addressing, and the `{language}` empty-expansion separator cleanup.

**Architecture:** All identity logic lives at the `CompileOrchestrator` entry (guard + version resolution + bump rule) so `compile`/`dry_run`/tools stay thin. Addressing changes are tool-local. Filename cleanup is one function in `OutputFilenameBuilder`.

**Tech Stack:** Swift/XCTest; no MaughamCore changes; Mac target only.

## Global Constraints

- Build/test: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/<ClassName>` (class names only; folder paths run 0 tests). New test files need `./gen.sh`.
- Tool schema changes may break tools-list/schema literal tests — fix same-commit; tool COUNT unchanged (52). Read `Maugham/MCP/AREA.md` before MCP edits; update its catalogue lines with the new params/filters in the same commit.
- Verified seam facts: collision guard `CompileOrchestrator.swift:110-136` (`existingPublications.contains { $0.version == config.nextVersion }`); Publication minted `:227` with `version: config.nextVersion`; `next_version` bump near the end of `compile` (`bumpedNextVersion` + `configStore.save`); `Publication.language: String?` already exists (nil = source); `list_publications` filter chain `PublicationTools.swift:36`, row struct nearby; `read_publication_page` version resolution `:88-118` (first-write-wins documented); `OutputFilenameBuilder.make` template replacement + no-token auto-suffix `:29-47`.
- Behavior change to state in tests + docs: a `language` compile without `version` now resolves to the latest source publication's version and ERRORS when none exists (v0.25.0 minted its own from `next_version`). Existing tests pinning the old behavior must be UPDATED deliberately, not deleted — each gets a comment citing this spec.
- Branch `feat/edition-identity-2026-07` off main. Commits `feat(publish): …`.

---

### Task 1: identity + pinned edition compiles (CompileOrchestrator + CompileTool)

**Files:** Modify `Maugham/Publish/CompileOrchestrator.swift`, `Maugham/MCP/Tools/CompileTools.swift` (CompileTool params/schema/description), `Maugham/MCP/AREA.md`; tests in `MaughamTests/CompileOrchestratorTests.swift`, `MaughamTests/MCP/Tools/CompileToolsTests.swift`, plus an edition-pair end-to-end (EPUB path is tectonic-free — use it for speed like existing orchestrator tests do).

**Interfaces produced:** `CompileOrchestrator.compile(format:label:language:allowStale:dryRun:version:)` — new `version: String?`; guard helper keyed on `(version, language, format)`; Task 2/4 depend on nothing from this task.

- [ ] **Step 1 (TDD, orchestrator):** failing tests — (a) source pdf@0.1 exists → `compile(language:"es")` (no version) mints `version "0.1"`, `language "es"`, and `next_version` still whatever it was (unbumped); (b) no source publication → language compile fails loudly, message contains "compile the source edition first"; (c) `compile(language:"es", version:"0.1")` after (a) with format epub → mints `0.1/es/epub`; repeating `0.1/es/pdf` → collision refusal naming version AND language; (d) source compile at a manually-set `next_version` colliding with an EXISTING source version+format still refuses (guard not weakened for the exact-triple match); (e) `version:` without `language:` → refused; (f) `dry_run` + `version` validates (passes/refuses) with zero mutation; (g) source compile still bumps `next_version`, language compile leaves it.
- [ ] **Step 2:** implement in the orchestrator: resolve `effectiveVersion` — source: `config.nextVersion` (unchanged); language+version: validate a `language == nil` publication exists at that version else `.failed` ("no source v\(version) to render in \(language)"); language w/o version: latest source pub by `compiledAt` else the loud error. Guard becomes exact-triple: `existing.contains { $0.version == effectiveVersion && $0.language == language && $0.format == format }` (republish path untouched). Mint with `version: effectiveVersion`; skip the `bumpedNextVersion`/save block when `language != nil`. `dry_run` runs the same resolution+guard before its short-circuit.
- [ ] **Step 3:** CompileTool: `version: String?` param (schema description: editions only; pins the source version being rendered), threaded through; tool-level tests for the refusal shapes; fix any tools-list literal breakage same-commit; AREA.md compile line updated.
- [ ] **Step 4:** run CompileOrchestratorTests, CompileToolsTests, RepublisherTests, PreviewCompilerTests (previews unaffected — assert one existing preview test still green), DocSyncTests. Commit: `feat(publish): edition identity (version, language, format) — pinned edition compiles, per-language collision guard, source-only next_version bump`

### Task 2: list/read language addressing

**Files:** Modify `Maugham/MCP/Tools/PublicationTools.swift` (both tools' params/schemas/descriptions/filters), `Maugham/MCP/AREA.md`; tests `MaughamTests/MCP/Tools/PublicationToolsTests.swift` (find the actual class name first — grep for existing list_publications tests).

- [ ] **Step 1 (TDD):** list rows carry `language` (null for source); `language:"es"` filter; `language:"source"` sentinel selects nil-language rows; read_publication_page `version` + `language` resolves the right family member, `publication_id` unaffected, version-only lookup keeps first-write-wins (documented).
- [ ] **Step 2:** implement; schema/description updates; AREA.md lines; fix literal-test breakage.
- [ ] **Step 3:** run the tool test classes + DocSyncTests. Commit: `feat(mcp): list_publications language filter + rows; read_publication_page language disambiguation`

### Task 3: `{language}` empty-expansion separator cleanup

**Files:** Modify `Maugham/Publish/OutputFilenameBuilder.swift`; tests `MaughamTests/Publish/OutputFilenameBuilderTests.swift`.

- [ ] **Step 1 (TDD):** template `{title}-v{version}-{language}.{ext}` with language nil → `T-v0.1.pdf` (separator dropped); with "es" → `T-v0.1-es.pdf` (separator kept); `_`/`.` separators behave the same; token with NO preceding separator unchanged; templates without the token keep the existing auto-suffix behavior (existing tests untouched).
- [ ] **Step 2:** implement — before the generic replacement, when `language == nil/empty`, strip one `[-_.]` immediately preceding each `{language}` occurrence (then replace token with ""); when present, plain token replacement as today. Commit: `fix(publish): {language} filename token drops its dangling separator for source editions (F7 completion)`

### Task 4: docs — edition workflow

**Files:** publishing guide topic in `docs/guide/` (replace any set-next_version-between-compiles guidance with the pinned-version family flow; extend the edition-subset workflow pointer), `docs/skills/translation-pass/SKILL.md` (edition-pair model note: an edition renders an existing source version; compile source first), `Maugham/MCP/AREA.md` sweep for stale claims. Gates: DocSyncTests, GuideDocsDriftTests, HelpTopicIndexTests. Commit: `docs(publish): edition-family workflow (pinned versions, language filters)`

### Task 5: Final verification

- [ ] Full Mac suite; phone suite (nothing shared touched — safety run).
- [ ] Whole-branch review (most capable model): seams — guard exactness vs republish exemption; latest-source resolution vs allow_stale editions; dry_run mutation-freedom; behavior-change test updates justified; filename cleanup vs auto-suffix interaction.
- [ ] Dev-app smoke over the raw socket (stale-schema lesson): source compile → es compile no-version → family listing → collision refusal → dry_run pinned.
- [ ] PR; acceptance = the spec's Acceptance paragraph, runnable on Denver's Playlist project post-merge.

## Self-Review (plan time)

Spec coverage: identity/guard→T1, version param + bump rule + dry_run→T1, list/read→T2, separator→T3, docs→T4, acceptance→T5. Behavior change (edition default version) explicitly flagged in constraints + T1(a,b) + T4. Judgment points left to implementers: exact failed-shape wording, PublicationTools test class name, whether `read_publication_page`'s language param interacts with its both-given consistency check (mirror the existing publication_id+version agreement rule).
