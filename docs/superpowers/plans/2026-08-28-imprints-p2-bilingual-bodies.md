# Imprints P2 — bilingual bodies

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `compile`/`preview_compile` take `languages: ["en","sr"]` and produce ONE document holding one complete single-language body per language, in order — each body exactly today's single-language emission, each under its own language's metadata, the coverage gate run per translated language — recorded as `(imprint, version, "en+sr", format)`.

**Architecture:** a `LanguageSet` value normalizes the request (legacy `language`, new `languages`, the `"source"` sentinel) into an ordered list of body tags plus one joined identity string. A `BodyPlan` binds each tag to its own AST source and its own effective config (per-language metadata + style files) — built once at the orchestrator's door. The two compilers gain a bodies-taking entry that the existing single-body path delegates to, so a single-language compile is byte-identical to today except for the `MaughamBody` wrapper. Anchors, cross-links, the desk and naming surfaces are plan 3.

**Tech Stack:** Swift; tectonic (real compiles behind `TectonicProbe.requireReady()`); XCTest via `./scripts/test.sh`.

**Spec:** `docs/superpowers/specs/2026-08-27-imprints-and-bilingual-editions-design.md` §2 (settled layout), §4 (joined language), §5 minus anchors/cross-links, §6 (tools' `languages`), §7 (snapshot `languages`, `MaughamBody` contract). Built on P1 (`docs/superpowers/plans/2026-08-27-imprints-p1-resolution-and-identity.md`, merged `a13c7d4a`). **Not in this plan:** `¶id` anchors, `\MaughamCrossLink`, the desk picker/Compile…, `PublishPreviewCentre.label`, the Exports footer.

**Branch:** `claude/imprints-p2-2026-08-28` off main.

## Global constraints

1. **One contract, not two.** Every PDF compile — single- or multi-language — emits `build/body.tex` as the `MaughamBody` wrapper sequence (spec §5), with the `\ifdefined\MaughamBody\else\newenvironment{MaughamBody}[1]{\clearpage}{}\fi` guard FIRST in the file, so a template that defines the environment wins and one that does not still compiles. Existing projects never receive starter-template updates (`PublishStarter.installIfMissing` returns when initialized, `PublishStarter.swift:142-146`), which is why the guard lives in the emitted file.
2. **A single-language compile is unchanged except the wrapper.** Its body text, its `build/metadata.tex`, its filename, its record and its snapshot are byte-identical to P1's; its PDF page count is equal (measured, Task 3). The identity-equivalence tests (`ASTTranslationSubstitutionTests`) are untouched — they compare ASTs, which do not change.
3. **A body is today's single-language emission.** Body(tag) is `LaTeXBodyEmitter.emit(ProjectASTBuilder.build(from: source(tag)), config: config(tag))` where `source(tag)` is `ProjectStoreASTSource(projectStore:, language: tag-or-nil)` and `config(tag)` is the resolved config with `effectiveMetadata(language:)` and `LanguageSuffixedFile.resolvingStyleFiles(language:)` applied for THAT tag. Nothing in an emitter learns the word "languages".
4. **The source is named by `metadata.language`**; the `"source"` sentinel is accepted in a `languages` list and means the same. `languages: []`/absent ≡ source; `["sr"]` ≡ `language: "sr"`; both given must agree or `invalid_argument`. Duplicates and invalid tags refuse. The joined identity is the tags in listed order, source spelled by `metadata.language`, `+`-joined — `"en+sr"` — and is a plain string everywhere (`Publication.language`, `PublishMintGate.Key.language`, `{language}` token, `list_publications` exact match). A single translated tag keeps today's spelling (`"sr"`), a source-only set keeps `nil`.
5. **A source compile is one whose set is empty or contains the source** (spec §4): it mints at the counter and bumps it; a set without the source is an edition of an existing version (pinned by `version`, else latest original source under that imprint) — today's rule. `version` with a set containing the source is refused as today's "version requires a language".
6. **The gate runs once per translated tag** over the rendered set; any block refuses the whole compile with EVERY blocked language's errors (not the first); `allow_stale` applies to all; each warning and error is prefixed with its tag (`[sr] …`). `TranslationCoverage.applyGate` is not reimplemented (its doc contract, `TranslationCoverage.swift:120-126`).
7. **The document-level metadata is the first listed body's.** `build/metadata.tex` stays exactly what it is today, written for the FIRST body (so the preamble's `\InputIfFileExists{build/metadata}` and every `\Title`… macro keep working, and `CompileLanguageThreadingTests.metadataTexContents()` keeps reading it); each body additionally gets `build/metadata.<tag>.tex` and `build/body.<tag>.tex`. The template used is `LanguageSuffixedFile.resolve(config.template, language:)` with the SINGLE tag when the set has one translated tag (today), and the unsuffixed `config.template` when the set has two or more bodies.
8. **No `imprint` parameter anywhere P1 forbade it** (P1's censuses stay green). `language`-shaped parameters are allowed where they exist today; the new bodies-taking entries take a `[BodyPlan.Body]`, never a `languages`/`imprint`.
9. Every refusal has a control; disable experiment on every negative assertion, failure line quoted in the report. Tripwires 8, 13, 20.
10. **Run `./scripts/test.sh` as a blocking foreground command** (never `run_in_background`) after each task; name the covering classes in the report. `./scripts/test.sh full` once before merge; whole-branch review before merge.
11. CLAUDE.md rule 10: a doc sentence a task falsifies is corrected in that task's commit; Task 8 sweeps the rest.

## Task 1 — `LanguageSet`

**Files:** new `Maugham/Publish/LanguageSet.swift`; tests new `MaughamTests/Publish/LanguageSetTests.swift`.

**Contract.**

```swift
/// The languages a compile renders, in order — the one place the legacy
/// `language`, the new `languages` list and the "source" sentinel are reconciled.
public struct LanguageSet: Equatable, Sendable {
    public struct Invalid: Error, LocalizedError, Equatable { public let message: String }

    /// Ordered body tags; the source body is `nil`. Never empty.
    public let bodies: [String?]
    /// `metadata.language` — how the source is spelled in a joined identity.
    public let sourceTag: String

    /// - `language` (legacy) and `languages` both nil/empty → `[nil]`.
    /// - both given → must agree (`languages == [language]`) else Invalid.
    /// - "source" in the list → nil body; a tag equal to `sourceTag` → nil body.
    /// - duplicates (after that mapping) → Invalid; a tag failing
    ///   `TranslationRecord.isValidLanguageTag` → Invalid.
    public init(language: String?, languages: [String]?, sourceTag: String) throws

    public var isSourceCompile: Bool          // bodies contains nil
    public var translatedTags: [String]        // non-nil bodies, in order
    /// nil for `[nil]`; the tag for a single translated body; else the
    /// `+`-joined list in order with nil spelled as sourceTag.
    public var identity: String?
    /// The tag `LanguageSuffixedFile.resolve` should see for the template and
    /// for single-body filename/metadata decisions: the sole translated tag
    /// when `bodies.count == 1`, else nil.
    public var singleTag: String?
}
```

**Tests:** every bullet above as its own case, plus: `["sr"]` → `identity == "sr"`, `isSourceCompile == false`; `["en","sr"]` with `sourceTag "en"` → `bodies == [nil, "sr"]`, `identity == "en+sr"`, `isSourceCompile == true`, `singleTag == nil`; `["source","sr"]` ≡ the same; `["sr","en"]` → `"sr+en"` (order kept); `["sr","sr"]` refused; `["xx-!"]` refused; `language: "sr", languages: ["es"]` refused; `language: "sr", languages: ["sr"]` accepted. Controls for each refusal.

Commit: `feat(publish): LanguageSet — one reconciliation of language, languages and "source"`.

## Task 2 — `BodyPlan` and the rebindable source

**Files:** new `Maugham/Publish/BodyPlan.swift`; `Maugham/Publish/ProjectStoreASTSource.swift` (conformance); tests new `MaughamTests/Publish/BodyPlanTests.swift`.

**Contract.**

```swift
/// A `ProjectASTBuilder.Source` that can produce itself bound to another language.
public protocol LanguageRebindableSource: ProjectASTBuilder.Source {
    func rebound(toLanguage tag: String?) -> ProjectASTBuilder.Source
}
extension ProjectStoreASTSource: LanguageRebindableSource { … }   // ProjectStoreASTSource(projectStore:, language: tag)

public struct BodyPlan: Sendable {
    public struct Body: Sendable {
        public let tag: String?                     // nil = source
        public let displayTag: String               // tag ?? sourceTag — the tag written into the wrapper
        public let source: ProjectASTBuilder.Source // already wrapped by the caller's include filter
        public let config: PublishConfig            // effectiveMetadata(language:) + resolvingStyleFiles applied
    }
    public let bodies: [Body]                       // never empty; same order as LanguageSet.bodies
    public var first: Body { bodies[0] }

    /// Builds one body per tag. `resolved` is the door's already-resolved config
    /// (imprint applied, nextVersion threaded). `wrap` is how the caller wraps a
    /// bound source (the include filter); the plan applies it to every body.
    /// Throws `LanguageSet.Invalid`-shaped error when `set.bodies.count > 1` and
    /// `source` is not `LanguageRebindableSource`.
    public static func make(
        set: LanguageSet, resolved: PublishConfig, source: ProjectASTBuilder.Source,
        publishDir: URL, wrap: (ProjectASTBuilder.Source) -> ProjectASTBuilder.Source
    ) throws -> BodyPlan
}
```

Requirements: for one body, `source` is used AS GIVEN (never rebound — a test source that is not rebindable must keep working, constraint 2); for `n > 1`, each body's source is `rebindable.rebound(toLanguage: tag)`; each body's `config` is `resolved` with `metadata = resolved.effectiveMetadata(language: tag)` and `LanguageSuffixedFile.resolvingStyleFiles(in:language:publishDir:)` (`LanguageSuffixedFile.swift:43-45`) — exactly the two folds `CompileOrchestrator.swift:211-224` performs today, moved here.

**Tests:** single body keeps identity of the given source (`===`-style check via a marker source); two bodies rebind (a fake `LanguageRebindableSource` records the tags it was asked for, in order); a non-rebindable source with two tags throws, with one tag passes; per-body config: `bodies[1].config.metadata.title` reflects `languageOverrides["sr"]` while `bodies[0].config.metadata` is the source's; `wrap` applied to every body (count the calls).

Commit: `feat(publish): BodyPlan — one body per language, each bound and folded once`.

## Task 3 — the PDF's bodies and the wrapper

**Files:** `Maugham/Publish/PDFCompiler.swift` (body/metadata write :61-81; template resolve :99-107); `Maugham/Publish/EmissionContract.swift` (new `MaughamBody` entry beside `languageEditionContract` :266-284); `Maugham/Resources/PublishStarter/EMISSION.md` (regenerated); `Maugham/Resources/PublishStarter/template.tex` and `preamble.tex` (a guarded `MaughamBody` definition — `\clearpage` in the starter; a comment showing how a template gives each half its own title page by moving the frontmatter `\input` inside the environment); tests `MaughamTests/Publish/CompileLanguageThreadingTests.swift` (`metadataTexContents()` :240 must keep reading `build/metadata.tex`), `MaughamTests/Publish/EmissionContractTests.swift` (byte gate :17 moves once), new `MaughamTests/Publish/BilingualPDFTests.swift` (real compiles, `TectonicProbe.requireReady()`).

**Contract.** `PDFCompiler` gains `public init(projectURL:bodies: [BodyPlan.Body], config:jobManager:maughamVersion:jobID:language:replacesExistingOutput:)`; the existing init (`:29-47`) builds a one-body plan from its `astSource`/`config` and delegates, so every current caller compiles unchanged. `compile(label:)` writes, in order:
- for each body: `build/body.<displayTag>.tex` = `LaTeXBodyEmitter.emit(ast, config: body.config)`; `build/metadata.<displayTag>.tex` = the SAME `\renewcommand` block written today (:68-80) rendered from `body.config.metadata`;
- `build/metadata.tex` = the first body's block (constraint 7), unchanged bytes for a single body;
- `build/body.tex` =
  ```latex
  \ifdefined\MaughamBody\else\newenvironment{MaughamBody}[1]{\clearpage}{}\fi
  \begin{MaughamBody}{en}\input{build/metadata.en}\input{build/body.en}\end{MaughamBody}
  \begin{MaughamBody}{sr}\input{build/metadata.sr}\input{build/body.sr}\end{MaughamBody}
  ```
  (one line per body). `\input{build/…}` paths are relative to the publish dir — the template already does `\input{build/body}` from there (`template.tex:31`), so the same base holds; Task 5's note on subdirectory templates (P1: `\input` resolves relative to the TEMPLATE's directory) means an imprint template in `templates/` must be tested here with a real compile.
- template: `LanguageSuffixedFile.resolve(config.template, language: language, under: publish)` unchanged — the orchestrator passes `set.singleTag` as `language` (Task 5), so a multi-body compile uses the unsuffixed template (constraint 7).
`EmissionContract` gains the entry text for `MaughamBody` (one argument, the tag; guarded; each body inputs its own metadata then its body; document-level metadata is the first body's) and `EMISSION.md` regenerates; the byte gate moves once.

**Tests:** single-body: `build/body.tex` is exactly the guard line plus one wrapper line, `build/body.en.tex` equals what `LaTeXBodyEmitter.emit` returns for the same AST, `build/metadata.tex` byte-equal to the old block (pin against a literal), and **the starter novel fixture's PDF page count is equal to a compile at `a13c7d4a`'s behaviour** — measure by compiling the fixture once WITHOUT the wrapper (temporarily emit the old `body.tex`, record the count in the test as the expected value with the measurement quoted in the report) and once with; two bodies: both `body.<tag>.tex` present with the translated text in the second, both `metadata.<tag>.tex` present with `\MaughamLanguage{sr}` in the second and the override title, and the PDF's plain text contains the source paragraph before the translated one (`pdfPlainText(at:)` helper, `PublishingEndToEndTests.swift:211`); a template that defines `MaughamBody` itself (write one in the fixture that emits a marker word in the environment's begin code) shows the marker exactly `bodies.count` times in the plain text.

Commit: `feat(publish): the PDF is a sequence of bodies, each under its own language`.

## Task 4 — the EPUB's bodies

**Files:** `Maugham/Publish/EPUBCompiler.swift` (sections :53-60; package :98-108); `Maugham/Publish/EPUBPackage.swift` (`Section` :60-65 gains `language: String`; `Metadata.language` stays the first body's; a `languages: [String]` on the package for `<dc:language>` per body); `Maugham/Publish/EPUBOPFWriter.swift` (`opfXML` :5 emits one `<dc:language>` per language; `navXHTML` :68 groups per body when there is more than one; `sectionXHTML` :88 stamps `xml:lang`/`lang` on `<html>`); tests `MaughamTests/Publish/EPUBBodyArtifactTests.swift`, new `MaughamTests/Publish/BilingualEPUBTests.swift` (reuse `pieceIDs(inEPUBAt:)` from `RepublisherTests.swift:1300-1316` — move it to a shared test helper file under `MaughamTests/Publish/` and cite the move).

**Contract.** `EPUBCompiler` gains the same bodies-taking init; the existing init delegates with one body. Sections: for one body the filenames stay `section-%03d.xhtml` (constraint 2); for `n > 1` they are `section-<displayTag>-%03d.xhtml`, ids `s-<displayTag>-<i>`, each carrying its body's `displayTag` as `language`. Each section XHTML's `<html>` carries `xml:lang="<tag>" lang="<tag>"`. `nav.xhtml`: one flat list for one body (unchanged bytes); for more, one `<h2>` per body labelled with its `displayTag` followed by its sections. OPF: `<dc:language>` for each body's tag in order (EPUB 3 permits several; the first is primary). Spine: bodies in order.

**Tests:** single-body EPUB's `content.opf`, `nav.xhtml` and section filenames are byte-identical to before (pin literals from a fixture compiled at the start of the task); two-body EPUB: `unzip -l` lists `section-en-001.xhtml` and `section-sr-001.xhtml`, the `sr` section's text is the translation, both `<dc:language>` present in order, `xml:lang` on each, nav has two headings; `pieceIDs(inEPUBAt:)` sees the piece once per body (assert count of `data-piece-id` occurrences == bodies × pieces).

Commit: `feat(publish): the EPUB is a sequence of bodies, each in its own language`.

## Task 5 — the orchestrator: `languages`, the gate loop, joined identity

**Files:** `Maugham/Publish/CompileOrchestrator.swift` (signature :81-89; folds :211-224 → replaced by `BodyPlan.make`; version branches :266-367; collision :390-405; key :434-436; gate :543-557; snapshot :575-577; compilers :586-603; record :636-650; bump :687-701); `Maugham/Publish/PublicationSnapshot.swift` (new `languages: [String]?`, tolerated-missing, coding key `languages`); `Maugham/Publish/PublicationSnapshotStore.swift` (`capture` gains `languages: [String]? = nil`); tests `MaughamTests/CompileOrchestratorTests.swift` (helpers `seedSourcePublication` :403, `makeOrch` :420), `MaughamTests/Publish/TranslationCoverageGateTests.swift` (`makeTwoDocFixture` :544, `writeTranslation` :125), `MaughamTests/Publish/CompileLanguageThreadingTests.swift`.

**Contract.** `compile(format:label:language:allowStale:dryRun:version:imprint:)` gains `languages: [String]? = nil`. At the door, after `resolved`: `let set = try LanguageSet(language: language, languages: languages, sourceTag: config.metadata.language)` — `Invalid` → `.failed` with the sentence, `logExcerpt: "invalid_languages: …"`, before the job registers (the unknown-imprint precedent :112-122). Then:
- `let plan = try BodyPlan.make(set:, resolved: config, source: astSource, publishDir:, wrap: { IncludeFilteredASTSource(base: $0, excludedSectionIDs:) })` replaces the two folds; `effective` becomes `plan.first.config` with `nextVersion` threaded as today.
- Every `language == nil` test of the version branches (:266, :283, :296, :346) becomes `set.isSourceCompile` / `!set.isSourceCompile`; every `language` written into a predicate, the collision guard, the mint key, `Publication(language:)` and `OutputFilenameBuilder` (via the compilers' `language:` argument) becomes `set.identity`; `langLabel` (:396) becomes `set.identity ?? "source"`. The compilers receive `language: set.singleTag` for template/style suffixing (constraint 7) — NOTE the two uses split: identity strings use `set.identity`, suffix resolution uses `set.singleTag`. Write both in one comment at the door so a reader sees the split.
- Gate (:543-557): `for tag in set.translatedTags` — `check` + `applyGate` per tag; collect blocked errors from ALL tags (prefix each diagnostic's message with `[<tag>] `), fail once with them all; warnings likewise prefixed; the existing single-tag behaviour is the `count == 1` case of the loop (assert message equality for that case against the current text, prefix included — the prefix is new for single-language compiles too; one contract).
- `snapshotStore.capture(config: effective, maughamVersion:, tectonicVersion:, languages: set.bodies.map { $0 ?? set.sourceTag })`; a single-body snapshot records `["en"]`/`["sr"]` (always present from now; old snapshots decode `nil`).
- Bump: `if set.isSourceCompile`.
- `compileReserved` (:501-516) takes the `BodyPlan` in place of `emitSource`/`language`.

**Tests:** acceptance 2's compile half — `compile(imprint: "special", languages: ["en","sr"], format: .epub)` mints `(special, "0.1", "en+sr", epub)`, bumps only the imprint's counter, the EPUB holds both bodies in order (unzip); `["sr","en"]` mints `"sr+en"`; `["sr"]` is byte-identical in record and filename to `language: "sr"` (pin by running both and comparing); `version` with a source-containing set refused (control: `["sr"]` + version accepted); the gate loop: two translated tags where one is blocked reports BOTH tags' errors and the passing tag's warnings appear nowhere (fail is whole); `dryRun` with `["en","sr"]` reports without minting; the snapshot's `languages == ["en","sr"]`; an old snapshot JSON without `languages` decodes `nil`; `CompileLanguageThreadingTests` rules 1–5 still green untouched; `PublishMintGate` keys differ between `"sr"` and `"en+sr"`.

Commit: `feat(publish): compile many languages — one document, one gate per tongue, one identity`.

## Task 6 — preview and republish loop too

**Files:** `Maugham/Publish/PreviewCompiler.swift` (init :44-58 gains `languages: [String]? = nil`; `preview` :71-76; `run` :94-100; folds :211-215; gate :237-255; compilers :259-277); `Maugham/Publish/Republisher.swift` (`republish` :60; identity :96-125; `republishReserved` :207-222; gate :233-247; compilers :256-272; record :340-342); tests `MaughamTests/Publish/PreviewCompilerTests.swift` (or the class Task 7 of P1 used — grep `PreviewCompiler(` in MaughamTests), `MaughamTests/RepublisherTests.swift`.

**Contract.** Preview: `LanguageSet(language: self.language, languages: self.languages, sourceTag:)` after `resolved`; `BodyPlan.make` with `wrap` = the preview's `FilteredASTSource`/`IncludeFilteredASTSource` choice; the gate block loops exactly as Task 5 (the preview's `excludedFromGate` derivation stays); compilers get bodies and `language: set.singleTag`; the preview filename carries `set.identity` through the compilers' `language:` — assert `preview-0.1-pdf-en+sr.pdf` lands (the `{language}` guard). Republish: `let set = try LanguageSet(language: prior?.language, languages: snap.languages, sourceTag: snap.config.metadata.language)` — a snapshot with `languages` wins; an old snapshot falls back to the prior row's single language; `republishReserved` builds a `BodyPlan` from the staged snapshot config and loops the gate; the new row carries `set.identity`.

**Tests:** preview `["en","sr"]` under an imprint renders only the allowlist, both bodies, file named with `en+sr`; preview refuses an invalid set before any file is written (control: valid previews); republish of a bilingual record reproduces two bodies (EPUB, unzip) and mints `language == "en+sr"`; republish of a pre-branch snapshot (no `languages`) still reproduces a single body with the prior's language; `read_preview_page` finds the `en+sr` preview (its scan is by extension — assert through `ReadPreviewPageTool` directly).

Commit: `feat(publish): previews and republishes render every body the record names`.

## Task 7 — the tools speak `languages`

**Files:** `Maugham/MCP/Tools/CompileTools.swift` (`Params` :98-115 and :194-212; schemas :94-96 and :190-192; validation :120-123/:217-220; threading :129-131/:151-156/:226-241); `Maugham/MCP/Tools/PublicationTools.swift` (no logic change expected — `languageMatches` is exact; description sentences mention the joined spelling); tests `MaughamTests/MCP/Tools/CompileToolsTests.swift`, `MaughamTests/MCP/Tools/PublicationToolsTests.swift`.

**Contract.** Both `Params` gain `languages: [String]?` (`CodingKeys` `languages`); schema: `"languages":{"type":"array","items":{"type":"string"},"description":"Languages to render, in order, one complete body each in ONE document — e.g. [\"en\",\"sr\"]. \"source\" or the book's own metadata.language names the untranslated body. A set that includes the source is a source compile (mints at next_version); one without it is an edition of an existing version. Equivalent to `language` for a single tag; if both are given they must agree."`; the `language` descriptions gain one sentence pointing at `languages`. Validation: each element must pass `TranslationRecord.isValidLanguageTag` or be `"source"` → else `invalid_argument`; agreement and duplicates are `LanguageSet`'s job — its `Invalid` surfaces as `invalid_argument` on the tool (the orchestrator refuses before the job; confirm which surface carries the sentence, as P1 Task 7 did). The tool keeps constructing `ProjectStoreASTSource(projectStore:, language: params.language)` exactly as today; the orchestrator rebinds per body through `LanguageRebindableSource` (Task 2) — the tool never builds a second source. `list_publications`/`read_publication_page`: `language: "en+sr"` matches the joined row exactly; `"source"` still selects `nil` rows only; descriptions say so.

**Tests:** `languages` decodes and threads to `orch.compile(languages:)` (spy or fixture); `["en","sr"]` end-to-end through the tool mints a `"en+sr"` row that `list_publications(language: "en+sr")` returns and `language: "source"` does not; `["sr"]` via the tool ≡ `language: "sr"`; `language: "sr", languages: ["es"]` → `invalid_argument` naming both; `["sr","sr"]` refused; an element `"nope!"` refused before any orchestrator call; schema JSON parses and declares `languages` on both tools; `MCPToolCatalog.all` count unchanged (existing test).

Commit: `feat(mcp): compile and preview_compile take languages`.

## Task 8 — docs, contract text, the sweep

**Files:** `docs/guide/publishing.md` (a `### Bilingual editions` section after `### Imprints`: what a multi-language file is — sequential, unrotated, each body a film in its own right (spec §2 in the writer's words); the `languages` list and `"source"`; `en+sr` as the identity everywhere; the `MaughamBody` environment and how a template gives each half its own title page; per-body metadata via `language_overrides`; the gate per language; what is NOT here yet — anchors and cross-links are plan 3); `Maugham/Publish/EmissionContract.swift` (the `MaughamBody` entry Task 3 added — re-read it against the built code and correct if it drifted; `EMISSION.md` regenerates); `docs/skills/maugham-bootstrap/SKILL.md` (template-authoring: define `MaughamBody` to control the seam between bodies); `CLAUDE.md` `Maugham/Publish/` row (one sentence: bodies, `LanguageSet`, `BodyPlan`, the joined identity); `docs/roadmap.md` (dated entry, P2 of 3, `•` until merge → flipped at merge by the controller); `Maugham/MCP/AREA.md:98` (the stale "55-tool" sentence — correct to the heading's count; rule 10 adjacency); `Maugham/Publish/` has no AREA.md — do not create one.

**Sweep:** grep `docs/`, `Maugham/**/AREA.md`, `README.md`, `CLAUDE.md` for "one body", "single-language", "`language` (singular) is the only", and `(version, language, format)` survivors; correct each in this commit; list every hit and what it became in the report.

**Tests:** `DocSyncTests` green; `EmissionContractTests` byte gate green (Task 3 moved it; this task must not move it again unless the entry text changed — say which); `TripwireGrepTests` (P1's two censuses) green.

Commit: `docs(publish): bilingual editions — the guide, the contract, the sweep`.

## Before merge

`./scripts/test.sh full` green (known skips only); whole-branch review with the ledger and these named seams: the single-body byte-identity claims (Tasks 3, 4), the identity/suffix split (`set.identity` vs `set.singleTag`, Task 5), the gate loop's whole-compile refusal, the snapshot `languages` fallback in republish, the `{language}` filename with `+`, and `CompileLanguageThreadingTests` unchanged. Merge `--no-ff` to main; do not tag — the milestone releases whole after plan 3.
