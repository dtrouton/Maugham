# Publish & MCP hardening (#73, #46, #47) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `metadata.language` from writing a compile outside `Exports/` (#73 F1). Make republish use the same imprint-resolved source tag as compile (#73 F2). Store language-role tags lowercased (#46). Make `MCPError.localizedDescription` the tool author's own message (#47).

**Architecture:** Each fix sits at its existing door. `PublishConfigValidator.validate` refuses a bad tag when the config is written, and `OutputFilenameBuilder` sanitises the `{language}` value as a backstop. `Republisher` derives `sourceTag` from the staged config resolved against the snapshot's imprint, which is the same resolution `foldingBase` already does. `ProjectStore.mintedLanguageRole` lowercases what it mints. `MCPError` conforms to `LocalizedError`.

**Tech Stack:** Swift, XCTest.

**Spec:** issues #73, #46 and #47, as re-verified against `main` at 69758ef8 (research below).

## Research (verified on main 69758ef8)

- **#73 F1:** `PublishConfigValidator.validate` (`Maugham/Publish/PublishConfigValidator.swift:15`) has no rule for `metadata.language` (default `"en"`, `PublishConfig.swift:72`). `LanguageSet.identity` joins `sourceTag` unsanitised (`LanguageSet.swift:84`, fed from `CompileOrchestrator.swift:227`). `OutputFilenameBuilder.make` sanitises only `title` and `label`, so the `{language}` replacement and `insertBeforeExtension` take the raw value (`OutputFilenameBuilder.swift:~44-95`).
- **#73 F2:** `Republisher.swift:170` takes `sourceTag` from `stagedConfig`, the snapshot's UNFOLDED `config.json`. The compile door uses the imprint-RESOLVED config (`CompileOrchestrator.swift:~205-227`, whose comment says so). `foldingBase` (`Republisher.swift:533`) already resolves `stagedConfig` against `snapshotConfig.imprint`, but only after `LanguageSet` has been built from the wrong tag.
- **#46:** `mintedLanguageRole` (`Maugham/Stores/ProjectStore+ProductionRoles.swift:~121-136`) validates `tag.lowercased()` but mints `role(tag)` and `presetName(tag)` verbatim. It is shared by `translatorRole`, `readerRole` and `collatorRole`, so the fix covers all three.
- **#47:** `MCPError` (`Maugham/MCP/MCPError.swift`) has `message` but no `LocalizedError`. Hand-written workarounds sit at `Maugham/Publish/EditionStatus.swift:258` and `Maugham/Compiler/TranslatorEnvironment+Project.swift:772`.

## Global Constraints

- **Lowercase-then-validate** is the house rule for language tags (#43 F-F precedent): `TranslationRecord.isValidLanguageTag(tag.lowercased())`. A tag like `en-US` is legal and is not rewritten in the config. No migration (tripwire 11).
- Shipped contracts that must stay green: `ProductionRoleStoreTests.test_theTagsCaseDoesNotMintASecondTranslator` and `test_aRegionalTagIsItsOwnTranslator`.
- A republish of a snapshot from before this fix must keep working. When resolution fails, fall back to today's `stagedConfig.metadata.language`.
- `./gen.sh` after adding a file. Iterate with `./scripts/test.sh`, and run `./scripts/test.sh full` before the PR. Never use `pgrep -f xcodebuild`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage by path.

## Review Focus

1. **`en-US` and `pt-BR` still compile,** and their filenames are unchanged from today's.
2. **A config already on disk with a bad `metadata.language`** (written before this fix) is refused at compile with the validator's sentence, never written outside `Exports/`. The backstop sanitiser makes the filename safe even if a path skips validation.
3. **Republish of a plain (non-imprint) book is byte-identical** in identity and filename to before.
4. **A role stored as `ES` before this fix** still resolves (the case-insensitive lookup) and is not duplicated.
5. **MCP wire responses don't change:** the JSON-RPC error text comes from `message`/`code`, not `localizedDescription`. Check that no handler serialises `localizedDescription` of an `MCPError` in a way a pinned test reads.

---

### Task 1: `metadata.language` can't escape `Exports/` (#73 F1)

**Files:**
- Modify: `Maugham/Publish/PublishConfigValidator.swift` (`validate`)
- Modify: `Maugham/Publish/OutputFilenameBuilder.swift` (`make`)
- Test: `MaughamTests/PublishConfigValidatorTests.swift`, `MaughamTests/Publish/OutputFilenameBuilderTests.swift`

**Interfaces:**
- Produces: a validation error with `field: "metadata.language"` and message `"'<value>' is not a valid language tag (BCP-47, e.g. 'en', 'en-US', 'pt-br')"` whenever `!TranslationRecord.isValidLanguageTag(cfg.metadata.language.lowercased())`.
- `OutputFilenameBuilder.make` passes `language` through `sanitizeForFilesystem` before both the `{language}` replacement and `insertBeforeExtension`. `+` is unaffected (the sanitiser removes only `/`, NUL, leading dots and control characters).

- [ ] **Step 1: Failing tests**

```swift
// PublishConfigValidatorTests
func test_aMetadataLanguageThatIsAPathIsRefused() {
    var cfg = PublishConfig.default   // or the file's existing fixture
    cfg.metadata.language = "../../evil"
    XCTAssertTrue(PublishConfigValidator.validate(cfg).contains { $0.field == "metadata.language" })
}
func test_aRegionalMetadataLanguageInEitherCaseIsAccepted() {
    for tag in ["en", "en-US", "pt-br", "sr-Latn"] {   // sr-Latn: 4-char subtag, legal
        var cfg = PublishConfig.default; cfg.metadata.language = tag
        XCTAssertFalse(PublishConfigValidator.validate(cfg).contains { $0.field == "metadata.language" }, tag)
    }
}
// OutputFilenameBuilderTests
func test_aLanguageCarryingASlashNeverBecomesAPath() {
    let name = OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil, language: "../../evil+sr")
    XCTAssertFalse(name.contains("/"))
}
func test_aJoinedIdentityKeepsItsPlus() {
    XCTAssertTrue(OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil, language: "en+sr").contains("en+sr"))
}
```

- [ ] **Step 2: Run and see them fail.** `./scripts/test.sh` (the first and third fail).
- [ ] **Step 3: Implement.** Add the validator rule next to the `language_overrides` key rule, and sanitise `language` once at the top of `make`. Then grep for every other place `validate(`'s callers or `validateForCompile` should see it (`grep -n 'validate' Maugham/Publish/PublishConfigValidator.swift`). Make sure the compile door runs the rule, so a config written before this fix is refused at compile (Review Focus 2), and add a test for that if `validateForCompile` is a separate path.
- [ ] **Step 4: Run and see them pass.** `./scripts/test.sh`
- [ ] **Step 5: Commit.** `fix(publish): metadata.language is validated and can never become a path (#73)`

### Task 2: Republish uses the imprint-resolved source tag (#73 F2)

**Files:**
- Modify: `Maugham/Publish/Republisher.swift` (~:150-230, and `foldingBase` if shared)
- Test: `MaughamTests/RepublisherTests.swift`

**Interfaces:**
- Produces: `sourceTag` = the `metadata.language` of `stagedConfig.resolved(imprint: snap.config.imprint, pieceIDs: <the same ids foldingBase uses>)`. If that resolution throws, fall back to `stagedConfig.metadata.language` (pre-fix snapshots). Prefer computing the resolved config once and handing it to `foldingBase`, rather than resolving twice, while keeping `foldingBase`'s existing single-body fallback behaviour.

- [ ] **Step 1: Failing test.** Using RepublisherTests' existing imprint fixtures:

```swift
func test_anImprintThatRespellsTheSourceLanguageRepublishesAsTheSource() async throws {
    // book metadata.language "en"; an imprint whose metadata sets language "es"
    // compile that imprint's source edition (identity "es"), then republish it:
    // the republish succeeds with the same identity and filename as the original,
    // and the coverage gate is not run (it's the source body, not a translation)
}
```

- [ ] **Step 2: Run and see it fail.** `./scripts/test.sh` (expect a coverage-gate refusal or an identity mismatch).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and see it pass,** with every existing `RepublisherTests` test still green (Review Focus 3).
- [ ] **Step 5: Commit.** `fix(publish): republish reads the source language the compile read — the imprint's (#73)`

### Task 3: Lowercase role tags (#46) and a localized `MCPError` (#47)

**Files:**
- Modify: `Maugham/Stores/ProjectStore+ProductionRoles.swift` (`mintedLanguageRole`)
- Modify: `Maugham/MCP/MCPError.swift`, `Maugham/Publish/EditionStatus.swift:258`, `Maugham/Compiler/TranslatorEnvironment+Project.swift:772`
- Test: `MaughamTests/ProductionRoleStoreTests.swift`, plus an `MCPError` test in an existing MCP test file or a new `MaughamTests/MCP/MCPErrorTests.swift`

**Interfaces:**
- `mintedLanguageRole` mints `role(tag.lowercased())` and `presetName(tag.lowercased())`. The stored lookup is unchanged. Update `EditionStatus.storedTranslatorLanguages`' comment to call its lowercase-on-read a legacy tolerance.
- `extension MCPError: LocalizedError { public var errorDescription: String? { message } }`. Retire both `(error as? MCPError)?.message ?? error.localizedDescription` spellings in favour of `error.localizedDescription`.

- [ ] **Step 1: Failing tests**

```swift
func test_aTranslatorMintedFromAnUppercaseTagIsStoredLowercase() async throws {
    let role = try await store.translatorRole(for: "ES")
    guard case .translator(let lang) = role.role else { return XCTFail() }
    XCTAssertEqual(lang, "es")
}
func test_aReaderAndACollatorAreStoredLowercaseToo() async throws { /* readerRole(for: "FR"), collatorRole(for: "FR") → "fr" */ }
func test_anMCPErrorsLocalizedDescriptionIsItsMessage() {
    XCTAssertEqual(MCPError.invalidArgument("x").localizedDescription, MCPError.invalidArgument("x").message)
    XCTAssertEqual(MCPError.projectNotOpen.localizedDescription, "That project isn't open in Maugham.")
}
```

- [ ] **Step 2: Run and see them fail.** `./scripts/test.sh`
- [ ] **Step 3: Implement.** Then `grep -rn 'localizedDescription' Maugham/MCP` to check Review Focus 5. If a handler already formats MCPError through `localizedDescription` into a wire response, note the changed text in the report. Correct text is the intent, but say so.
- [ ] **Step 4: Run and see them pass,** including the two shipped role contracts named in Global Constraints.
- [ ] **Step 5: Commit.** `fix(roles,mcp): language roles are stored lowercase; MCPError says its own message (#46, #47)`

### Finish

- [ ] `./scripts/test.sh full`, green (if Core fails with only a `started.` line, re-run it; that's another session's build).
- [ ] Whole-branch review (opus), told not to run builds.
- [ ] Open a PR closing #73, #46 and #47, with the smoke steps: in a Publish project set `metadata.language` to `../x` via Project Settings or MCP and expect a refusal; compile a bilingual `en-US`+`sr` edition and expect the file in `Exports/`; add a language `ES` in the desk and expect the row to read `es`.
