# Imprints P1 — resolution and identity

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a named *imprint* in `config.json` — its own template, rendered set, metadata, cover, filename and version counter — chosen at compile time, with the publication catalog, the mint gate, the filename and the snapshot all carrying it; usable alone as "the special cut in one language".

**Architecture:** one pure resolver turns `(config, imprint name)` into an ordinary `PublishConfig` — `template` and `imprint` become first-class fields, the allowlist is *materialized* into `include: false` entries — so every downstream reader (compilers, filename builder, gate, snapshot, mint gate) keeps reading a plain config and never learns the word. Identity gains one optional field with `language`'s exact Codable pattern.

**Tech Stack:** Swift, `Codable`, the existing RFC-7396 `JSONMergePatch`, XCTest via `./scripts/test.sh`.

**Spec:** `docs/superpowers/specs/2026-08-27-imprints-and-bilingual-editions-design.md` §3, §4, §7 (snapshot half), §6 (the two tools' `imprint` argument and `list_publications`/`read_publication_page`). Plans 2 (bilingual bodies) and 3 (anchors, links, desk, naming surfaces) are written after this one is built (CLAUDE.md rule 11). **Not in this plan:** `languages`, per-body emission, anchors, `MaughamBody`, the desk picker/Compile…, `PublishPreviewCentre.label(for:)`, the Exports footer (which scans `Exports/` rather than the catalog — `ExportsListView.swift:48` — and is plan 3's rewiring).

**Branch:** `claude/imprints-p1-2026-08-27` off main.

## Global constraints

1. **Resolve once, at the door.** Imprint-awareness lives in `PublishConfig.resolved(...)`, the two orchestrators' entry (`CompileOrchestrator.compile`, `PreviewCompiler.run`), the two tools' arguments, `Publication`/`PublishMintGate.Key`/`OutputFilenameBuilder`'s one field each, and the validator. **No compiler, emitter, gate or snapshot may take an `imprint` parameter** — they read `config.template` / `config.imprint`. Task 8's census enforces it.
2. **`resolved(imprint: nil, …)` returns `self`, byte-for-byte**, and a config with no `imprints` key re-encodes byte-identical to how it decoded (spec §3). The existing encoder always emits `language_overrides` (`PublishConfig.swift:343`) — `imprints`, `template` and `imprint` must NOT follow that: omit when empty / default / nil.
3. **Nothing writes the empty string.** `Publication.imprint`, `PublishMintGate.Key.imprint`, `PublishConfig.imprint` are `String?`; `nil` is the book. A test asserts a decoded imprint of `""` is refused by the validator.
4. **A source compile of an imprint bumps only that imprint's counter**, writing into `config.imprints[name].nextVersion` of the *original* config (the bump site at `CompileOrchestrator.swift:548-554` saves `config`, not `effective`). The book's `next_version` is unchanged by it; the imprint's is unchanged by a book compile. Spec acceptance 2.
5. **The pin, the collision guard and the mint key are all scoped per imprint** — every `existingPublications` predicate in `CompileOrchestrator` that today reads `$0.language`/`$0.version` also reads `$0.imprint == imprint`.
6. **Every refusal has a control.** Each test that asserts a refusal (unknown imprint, empty allowlist, escaping template, wrong-imprint pin, same-key collision) has a sibling asserting the same operation succeeds under the imprint that owns it.
7. **Disable experiment on every negative assertion:** remove the guard, watch the test go red, restore it, quote the failure line in the task report.
8. Tripwires 8 (4-char paragraph/piece-id literals from `[0-9a-hjkmnp-tv-z]` in fixtures that cross the `.md`↔op-log boundary), 13 (no hardcoded identity strings), 20 (no raw manuscript reads). `DotfileScan` for any new directory scan.
9. Run `./scripts/test.sh` after each task and name the covering classes in the report. `./scripts/test.sh full` once before merge. Whole-branch review before merge (rule 9).
10. CLAUDE.md rule 10: a doc sentence a task falsifies is corrected in that task's commit; Task 8 sweeps the rest.

## Task 1 — the `Imprint` type and the three fields on `PublishConfig`

**Files:** `Maugham/Publish/PublishConfig.swift`; tests `MaughamTests/PublishConfigTests.swift`, `MaughamTests/PublishConfigLanguageTests.swift` (the tolerated-missing precedent lives here: `testOldConfig_withoutLanguageOverrides_decodesToEmpty` :13).

**Contract.** Add to `PublishConfig` (stored properties at `PublishConfig.swift:28-40`, init :275-295, `init(from:)` :352-364, `encode(to:)` :333-344, `CodingKeys` :366-374):

```swift
public var imprints: [String: Imprint]      // key: imprint name; [:] when absent
public var template: String                  // top-level template filename; "template.tex" by default
public var imprint: String?                  // set ONLY by resolved(...); nil = the book

public struct Imprint: Codable, Equatable, Sendable {
    public var template: String?
    public var sections: [String: Section]?  // nil = inherit; present = ALLOWLIST (Task 2)
    public var metadata: [String: JSONValue]?   // see below
    public var outputs: [String: JSONValue]?
    public var cover: [String: JSONValue]?
    public var nextVersion: String?
}
```

`metadata`/`outputs`/`cover` are **merge-patch fragments**, not typed structs: RFC 7396 needs `null` to mean *delete* (`"subtitle": null`), and a typed `Metadata` cannot hold that distinction. Store them as a small `JSONValue` enum (`null/bool/number/string/array/object`, `Codable`, `Equatable`) — if one already exists in the target, use it (grep `enum JSONValue` first; `JSONMergePatch.swift` works on `Any`, so it likely does not). `Section` inside an imprint's allowlist is the existing `Section` (`PublishConfig.swift:160-218`, all fields defaulted by its custom decoder, so `{}` is a valid entry).

Coding keys: `imprints`, `template`, `imprint`, and inside `Imprint`: `template`, `sections`, `metadata`, `outputs`, `cover`, `next_version`. Decode: `imprints` → `decodeIfPresent ?? [:]`; `template` → `decodeIfPresent ?? "template.tex"`; `imprint` → `decodeIfPresent`. Encode: `imprints` only when non-empty; `template` only when `!= "template.tex"`; `imprint` via `encodeIfPresent`. Init gains the three with defaults, after `languageOverrides`.

**Tests (write first, watch them fail, then implement):**
- `testOldConfig_withoutImprints_decodesToEmptyAndReencodesIdentically`: decode `testRoundTrips_minimalConfig`'s JSON (`PublishConfigTests.swift:6`), re-encode, assert the encoded bytes contain none of `"imprints"`, `"template"`, `"imprint"` — and that decode→encode→decode equals the first decode.
- `testImprints_roundTrip`: a config with the spec §3 example imprint round-trips; `metadata.subtitle` decodes as `.null` and survives.
- `testImprint_partialEntry_decodesWithNilsNotDefaults`: `{"imprints":{"x":{"template":"t.tex"}}}` → `sections == nil`, `nextVersion == nil`.
- `testResolvedFields_encodeOnlyWhenSet`: `PublishConfig(template: "special.tex", imprint: "x")` encodes both; the default encodes neither.

Commit: `feat(publish): PublishConfig carries imprints, template and imprint`.

## Task 2 — `resolved(imprint:pieceIDs:)`

**Files:** new `Maugham/Publish/PublishConfig+Imprints.swift`; tests new `MaughamTests/Publish/PublishConfigImprintResolutionTests.swift`.

**Contract.**

```swift
extension PublishConfig {
    public struct UnknownImprint: Error, Equatable {
        public let requested: String
        public let known: [String]      // sorted
        public var errorDescription: String? // "unknown imprint 'x'; known: a, b" — or "…; this project defines no imprints"
    }

    /// Spec §3. `nil` → self, untouched. Throws `UnknownImprint`.
    public func resolved(imprint: String?, pieceIDs: [String]) throws -> PublishConfig
}
```

Requirements, in this order:
1. `imprint == nil` → `return self`. (Test: `XCTAssertEqual(config.resolved(imprint: nil, pieceIDs: ids), config)` on the full-config fixture — and on one that *has* imprints, so resolution to the book leaves `imprints` in place.)
2. Unknown name → throw with the sorted known names.
3. `template` replaces when present.
4. `sections`: when the imprint's map is present, the result's `sections` is **materialized**: every id in the imprint's map keeps its entry (with `include` forced `true` — an allowlist entry that says `include: false` is a contradiction and the validator refuses it, Task 3), and every id in `pieceIDs` *not* in the map gets `Section(include: false)`. When absent, `sections` is inherited unchanged. This is what makes `excludedSectionIDs` (`PublishConfig.swift:301`), `IncludeFilteredASTSource` (`CompileOrchestrator.swift:131`) and the coverage gate's excluded set all correct without change.
5. `metadata`, `outputs`, `cover`: deep-merge through `JSONMergePatch.apply(patch:to:)` (`JSONMergePatch.swift:14`, `Data`→`Data`) — encode the current block, apply the fragment, decode. Do not write a second merger. `null` deletes → the decoded optional is `nil` (`Metadata.subtitle`, `Cover.path`).
6. `nextVersion` replaces when present; else inherited (the book's).
7. The result carries `imprint = name` and its `template`. `imprints` itself is carried through unchanged (a snapshot of the resolved config must still decode).
8. `languageOverrides` untouched — they apply after, in the orchestrator as today.

**Tests** (fixture: two pieces `"p1"`, `"p2"`; imprint `"special"` with `sections: ["p2": {}]`, `metadata: {"title":"Special","subtitle":null}`, `template: "templates/special.tex"`, `next_version: "1.0"`; book `next_version: "0.3"`, `subtitle: "A Book"`):
- identity for `nil` (both fixtures); unknown name throws naming `["special"]`; allowlist: `excludedSectionIDs == ["p1"]` and `sections["p2"]?.include == true`; absent `sections` inherits; title replaced and subtitle deleted while `author` inherited; `outputs.filenameTemplate` inherited when the imprint has no `outputs`; `nextVersion == "1.0"`; `template` and `imprint` set; `imprints` still present on the result.

Commit: `feat(publish): resolved(imprint:) — one door, an allowlist materialized`.

## Task 3 — validation, at save and at compile

**Files:** `Maugham/Publish/PublishConfigValidator.swift` (`validate(_:)` :15, `ValidationError` :10 — pure, no filesystem); `Maugham/Publish/PublishConfigStore.swift` (`applyPatch` :44 — validates then saves); `Maugham/MCP/Tools/PublishConfigTools.swift` (the `set_publish_config` handler); tests `MaughamTests/PublishConfigValidatorTests.swift`, `MaughamTests/PublishConfigStoreTests.swift` (`testApplyPatch_reportsValidationErrors_andDoesNotSave` :80 is the model).

**Contract.** Two entry points, one rule set:

```swift
// pure — extends the existing validate(_:)
public static func validate(_ cfg: PublishConfig) -> [ValidationError]
// project-aware — pure rules PLUS existence; the only place a filesystem is read
public static func validate(_ cfg: PublishConfig, publishDir: URL, pieceIDs: [String]) -> [ValidationError]
```

Pure rules (field names in `ValidationError.field` as `imprints.<name>.<field>`): name matches `^[a-z0-9-]+$` and is non-empty; `template`, when present, is a relative path with no `..` component and no leading `/`; `sections`, when present, is non-empty and no entry has `include == false`; `next_version` when present passes whatever `validate(_:)` already applies to the top-level `next_version` (read the existing rule at its line and cite it). `cfg.imprint == ""` is refused (constraint 3). Project-aware: `template` (imprint's, and the top-level `cfg.template`) exists under `publishDir` — compare canonical paths so a symlink out of the tree is caught; every allowlist id is in `pieceIDs`.

`applyPatch` gains `additionalValidation: ((PublishConfig) -> [ValidationError])? = nil`, run after the pure pass and before `save`; a non-empty result means no save (same shape as today's `errors`). `set_publish_config` passes `{ validate($0, publishDir:, pieceIDs:) }` with `pieceIDs` from `ProjectStore.collectDocuments(in: store.manifest.structure).filter { $0.pieceKind != .reference && $0.path != nil }.map(\.id)` — the same predicate `ProjectStoreASTSource.publishablePieces()` uses (`ProjectStoreASTSource.swift`); call that if it is reachable from the tool, otherwise spell it once and cite it.

**Tests:** each pure rule refused with the field named + a control that the well-formed example passes; escaping template (`../x.tex`) refused; missing template file refused by the project-aware pass and accepted once the file is written; non-piece id refused; `applyPatch` with the extra validator does not save on failure (assert the file bytes unchanged) and does on success.

Commit: `feat(publish): imprints are validated at save and at compile`.

## Task 4 — identity: `Publication.imprint`, the mint key, the filename token

**Files:** `Maugham/Publish/Publication.swift` (fields :3-27, init :29-43, `init(from:)` :73-88, `encode(to:)` :90-105); `Maugham/Publish/PublishMintGate.swift` (`Key` :25-35); `Maugham/Publish/OutputFilenameBuilder.swift` (`make` :38-86); tests `MaughamTests/PublicationTests.swift`, `MaughamTests/Publish/PublishMintGateTests.swift` (helper `key(version:language:format:)` :10), `MaughamTests/Publish/PublishConfigLanguageTests.swift` (`testFilename_*` :113-137 — the `{imprint}` twins go beside them).

**Contract.**
- `Publication.imprint: String?`, defaulted `nil` in the init **after** `allowStale` (every existing construction site keeps compiling — dossier item 17 lists them); decoded `decodeIfPresent`, encoded `encodeIfPresent`, exactly `language`'s pattern. Snake-case key `imprint`.
- `PublishMintGate.Key.imprint: String?`, init parameter defaulted `nil` (seven call sites, `CompileOrchestrator.swift:311`, `Republisher.swift:138`, five in tests). Hashable by all four.
- `OutputFilenameBuilder.make(config:format:label:language:)` reads the imprint **from `config.imprint`** (constraint 1 — no new parameter). `{imprint}` token: substituted with the name; when `config.imprint == nil`, exactly one dangling `-`/`_`/`.` before the token is stripped (`stripOneSeparatorBefore` :91, already token-parameterized). Collision guard: when `config.imprint != nil` and the template lacks `{imprint}`, insert `-<imprint>` before the extension **before** the language guard runs, so a doubly-guarded name reads `Title-v0.1-special-sr.pdf` — imprint then language. Cite the two guards' order in a comment.

**Tests:** Publication round-trips with and without `imprint` and the on-disk key is `imprint`; an old JSON row without it decodes `nil`; two keys differing only by imprint reserve independently and the same key refuses (extend `PublishMintGateTests` with an `imprint:` on the helper); filename: token substituted, dangling separator stripped for the book, guard inserted for an imprint whose template lacks the token, guard order with a language present, and — control — the book's filename is byte-identical to before for every existing case in `OutputFilenameBuilderTests`.

Commit: `feat(publish): a publication, a mint key and a filename know their imprint`.

## Task 5 — the template comes from the config; republish carries the imprint

**Files:** `Maugham/Publish/PDFCompiler.swift` (`"template.tex"` literal at :94-96; `generatedName` :128); `Maugham/Publish/Republisher.swift` (`republish` :60; `let language = prior?.language` :114; `Publication(` :316-329); tests `MaughamTests/Publish/LanguageSuffixedFileTests.swift` (`test_pdfTemplatePick` :78), `MaughamTests/RepublisherTests.swift`.

**Contract.** `PDFCompiler` resolves `LanguageSuffixedFile.resolve(config.template, language: language, under: publish)` — the literal goes away; `generatedName` follows from the resolved name as it does now (a template at `templates/special.tex` yields `templates/special.pdf` under `build/` — verify tectonic's output location for a template in a subdirectory by running one real compile behind `TectonicProbe.requireReady()`, and if it lands elsewhere, say where in the task report and move it from there). `EPUBCompiler` has no template; unchanged. `Republisher` reads `prior?.imprint` beside `prior?.language`, passes it into the mint key and the new `Publication`; the staged snapshot tree already contains the imprint template because the snapshot captures every publish file (`PublicationSnapshotStore.swift:145`, by name).

**Tests:** `PDFCompiler` picks `special.tex` when `config.template` says so, and `special.sr.tex` when that exists beside it (extend `LanguageSuffixedFileTests`); a republish of an imprint record mints a record with the same `imprint` and reproduces the imprint template's output (a `RepublisherTests` case seeded through a real orchestrator compile with an imprint, Task 6's API — write this test in Task 6's commit if ordering demands, and say so).

Commit: `feat(publish): the template is the config's; republish keeps the imprint`.

## Task 6 — `CompileOrchestrator.compile(imprint:)`

**Files:** `Maugham/Publish/CompileOrchestrator.swift`; tests `MaughamTests/CompileOrchestratorTests.swift` (helpers `seedSourcePublication` :399, `makeOrch` :415; models `testEdition_sourceCompile_exactTripleCollision_refuses` :595, `testEdition_languageWithoutVersion_mintsAtLatestSourceVersion_noBump` :432).

**Contract.** `compile(format:label:language:allowStale:dryRun:version:)` (:81-88) gains `imprint: String? = nil`. Requirements:
1. Before `var effective = config` (:107): `let config = try loaded.resolved(imprint: imprint, pieceIDs: pieceIDs)` where `pieceIDs` come from `astSource.orderedPieces().map(\.pieceID)` (throws per RULING-54 — let it propagate as it does for the AST build). `UnknownImprint` → the same `.failed` shape with the error's sentence, `logExcerpt: "unknown_imprint: <name>"`, **before** any job is registered as running. Keep the *original* loaded config in a separate binding for the bump (constraint 4).
2. Validation at compile: `PublishConfigValidator.validate(resolved, publishDir:, pieceIDs:)` errors → `.failed` (mirror wherever the existing compile-time validation runs; cite the line).
3. Pin (:190-221) and latest-source (:222-247) predicates add `&& $0.imprint == imprint`. A pinned version present only under a different imprint fails with a message naming that imprint ("version '1.0' exists under imprint 'special', not the book").
4. Collision guard (:268-292) adds `$0.imprint == imprint`; mint key (:311) passes `imprint:`.
5. `Publication(` (:509-522) passes `imprint:`.
6. Bump (:548-554): when `language == nil`, if `imprint == nil` bump `nextConfig.nextVersion` as today, else `nextConfig.imprints[imprint]!.nextVersion = bumpedNextVersion(from: resolved.nextVersion)` — the resolved counter, which is the imprint's own or the inherited book's; either way the bump lands on the imprint entry, never the top level.
7. The snapshot at :448-450 already captures `effective` — now carrying `template` and `imprint` (Task 1's encoding).

**Tests:** acceptance 2 as a test — compile imprint `special` (source) mints `(special, "1.0", nil, pdf)`, `imprints["special"].nextVersion == "1.1"`, top-level `nextVersion` unchanged; then a book compile leaves the imprint's counter alone; unknown imprint fails before the job manager sees a job; wrong-imprint pin refused naming the imprint + control (right imprint accepted); collision is per imprint (same version/format under book and imprint both succeed); the snapshot's config decodes with `imprint == "special"` and `template` set; `dryRun` under an imprint reports without minting.

Commit: `feat(publish): compile under an imprint — scoped pin, guard, key, counter`.

## Task 7 — previews and the tools

**Files:** `Maugham/Publish/PreviewCompiler.swift` (`preview` :71-75, `run` :92, the language fold :130-135, the outputs override :122-126); `Maugham/MCP/Tools/CompileTools.swift` (`CompileTool.Params` :98-114 + schema :95; `PreviewCompileTool.Params` :192-209 + schema :189); `Maugham/MCP/Tools/PublicationTools.swift` (`languageMatches` :11-14, list filter :47-52, null-fill :68-69, read-page resolution :119-160); tests `MaughamTests/MCP/Tools/CompileToolsTests.swift`, `MaughamTests/MCP/Tools/PublicationToolsTests.swift` (`seedLanguageFamily` :471), `MaughamTests/Publish/PreviewCompilerTests.swift` (or wherever `preview(` is exercised — grep).

**Contract.**
- `PreviewCompiler.preview(format:sectionIDs:maxPages:)` gains `imprint: String? = nil`; `run` resolves exactly as Task 6 step 1 (a twin, two lines, cited to Task 6 — not a shared helper, the two entry points differ in what they do on failure). The outputs override at :122-126 stays (previews have their own naming); because `OutputFilenameBuilder` reads `config.imprint`, an imprint preview lands as `preview-0.1-pdf-special.pdf` through the collision guard — say so in a comment, since the preview dir is last-write-wins and this is what keeps an imprint preview from replacing the book's.
- `compile` and `preview_compile` gain `imprint` (string, optional) in `Params`, `CodingKeys` and the schema, with a description sentence: "Name of an imprint from config.json's `imprints` — its own template, rendered set, metadata and version counter. Omit for the book." Unknown name → `MCPError.invalidArgument` with the resolver's sentence (the orchestrator's `.failed` is rendered by the tool's existing failed-shape path; confirm which of the two surfaces the sentence and write the test against that).
- `list_publications`: rows carry `imprint` (null-filled like `language`, :68-69); new `imprint` filter with `"book"` as the sentinel for `nil` rows — a sibling of `languageMatches`. Schema + description updated; the tool description sentence about the key becomes `(imprint, version, language, format)`.
- `read_publication_page`: `imprint` param joins the resolution — with `publication_id` it must agree (mirror the language agreement rule at :120-141); with `version` it narrows the family the way `language` does. Version-only addressing unchanged (first-write-wins).

**Tests:** a preview under an imprint renders only the allowlist and names its file with the imprint; `compile` tool threads `imprint` to the orchestrator (a spy source or the real fixture, whichever `CompileToolsTests` already uses) and refuses an unknown name with the known list in the message; `list_publications` rows carry `imprint`, `imprint: "book"` selects nil rows, `imprint: "special"` selects that family; `read_publication_page` disagreement throws and agreement resolves; the tool descriptions/schemas compile and `MCPToolCatalog.all` count is unchanged (the existing catalog-count test).

Commit: `feat(mcp): compile, preview_compile, list_publications and read_publication_page speak imprint`.

## Task 8 — the census, the docs, the sweep

**Files:** `MaughamTests/TripwireGrepTests.swift`; `MaughamTests/Publish/PublishMintGateTests.swift` (`test_everyProductionCompilerConstructionPassesTheSharedGate` :92); `docs/guide/publishing.md` (a `### Imprints` after `### Language editions and version families` :33); `Maugham/Publish/EmissionContract.swift` (the per-piece style section :406-430 gains one sentence: an imprint's template is a full template and these prohibitions do not apply to it; regenerate `EMISSION.md` through the existing test); `docs/skills/maugham-bootstrap/SKILL.md` (template-authoring section, one line); `CLAUDE.md` `Maugham/Publish/` row (one sentence: imprints resolve at the door, `config.template`/`config.imprint`, key is four-part); `docs/roadmap.md` (a dated entry for P1, marked as the first of three plans); `docs/product.md`/`docs/problem-map.md` only if they state the key or the single-template rule (grep `template.tex` and `(version, language, format)`).

**Census** (constraint 1, made enforceable): a grep over `Maugham/Publish` and `Maugham/MCP/Tools` asserting no function signature outside `PublishConfig+Imprints.swift`, `CompileOrchestrator.swift`, `PreviewCompiler.swift`, `CompileTools.swift`, `PublicationTools.swift`, `PublishConfigValidator.swift` and `PublishConfigTools.swift` declares a parameter named `imprint` — with a planted-offender control in a temp dir, in the shape of `test_opLogFilenameTripwireFiresOnPlantedOffender` (:337). A second census: every production `Publication(` construction (`CompileOrchestrator.swift`, `Republisher.swift`) passes `imprint:` — the "reach every sink" lesson; planted offender likewise.

**Sweep:** grep `docs/`, `Maugham/**/AREA.md`, `README.md` for `(version, language, format)` and for any sentence saying `template.tex` is the template; correct each in this commit.

Commit: `docs(publish): imprints — the census, the guide, the sweep`.

## Before merge

`./scripts/test.sh full` green with no skips beyond the lock/display skips already on record; whole-branch review with the ledger of the eight commits and these named seams: the bump site (constraint 4), the three scoped predicates (constraint 5), the encoder's omit-when-empty (constraint 2), the two-guard filename order (Task 4), and the preview's filename (Task 7). Then merge to main with `--no-ff`; do not tag — the milestone releases whole after plan 3.
