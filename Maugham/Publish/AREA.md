# Publish — area guide

PDF and EPUB publishing through the bundled tectonic: the publish config and its imprints, the AST built from the op log, the LaTeX and XHTML body emitters, the compilers and their mint gate, the publication catalogue and republish, preview and sample compiles, and the translation coverage gate. The department desk's runs (translators, designer) are driven from `Maugham/Compiler/` and drawn in `Maugham/Views/`; their publish-side doors are here. What the body emitter produces is `Maugham/Resources/PublishStarter/EMISSION.md`, generated from `EmissionContract.swift`. The one rule from CLAUDE.md: **edit `EmissionContract.swift`, never `EMISSION.md`; keep `style_file` inside its `\begingroup`.** The area carries tripwires 13, 17, 20 and 54. The narrative and history behind the rules below are in `docs/history/publish.md`.

## Map

Every source file in `Maugham/Publish/` appears once, by family.

### The flow: source → AST → body
- `ProjectStoreASTSource.swift` — bridges a live `ProjectStore` to `ProjectASTBuilder.Source`: walks the structure in binder order, reads each piece from the op log, substitutes a language's translation. Tripwire 20.
- `ProjectAST.swift` — the target-agnostic model of a compilable project (pieces, prose and Fountain nodes, inlines).
- `ProjectASTBuilder.swift` — pieces → `ProjectAST`; maps `MarkdownBlock`s to AST nodes.
- `PublishContext.swift` — what a source knows beyond its text (live citations, profile, switches, the real project URL, piece paths); every filtering wrapper forwards it; the edition's filter (`IncludeFilteredASTSource`) is its own `resolutionScope`, a preview or sample narrowing (`FilteredASTSource`) answers its edition's and `isWholeBook` false, so a compile of the edition resolves the AST it built.
- `FigureImageResolver.swift` — a figure path → a file inside a research folder of the real project; refuses escapes before touching the disk. At staging both compilers sniff each image (`openingProblem`: header, real type, a PNG's chunks, a PDF's lock) and `contentHash` names it.
- `PublishResolution.swift` — the resolution pass over the edition's book's AST (`forCompile` resolves `resolutionScope`): numbers, cross-references, citations, References, the lists, figure files, problems. Emitters read it; they never number.
- `ElementWords.swift` — the words a body's report elements print ("Figure", "References", …): the built-in table by language, the config's `metadata.element_words` over it, English otherwise; `forBody` is the one resolution, carried as `PublishResolution.words`.
- `PublishProblem.swift` — one problem with its piece and `¶id`; `isError(profile:)` is the one severity table. `PublishProblemGate` judges them at the door.
- `InlineParser.swift` — prose inline runs over the shared `InlineEmphasisScanner`.
- `FountainInline.swift` — Fountain inline runs (`_x_` is underline).
- `EmphasisRunConverter.swift` — the shared converter both inline parsers use; masks protected spans.
- `FountainNodeMapper.swift` — the single bridge from the real `FountainTokenizer` to AST Fountain nodes, so publish classifies exactly as the editor does.
- `TranslatedFountainStructure.swift` — carries a source paragraph's Fountain structure to its translation (the source element wins).
- `LaTeXBodyEmitter.swift` — AST → `body.tex`: environments, per-piece `style_file` inside `\begingroup`, paragraph anchors, cross-links, the `\providecommand` fallbacks; with the book's `PublishResolution`, the report elements (tables, figures, footnotes, citations, cross-references, numbered headings, References, the lists), each degrading in a preamble without graphicx or longtable.
- `XHTMLBodyEmitter.swift` — AST → the EPUB body fragment, with `id` anchors and cross-links; with the book's `PublishResolution`, the report elements (tables, figures, pop-up footnote asides closing each section file, citations, cross-references by `labelHrefs`, numbered headings), References and the `lbl-`/`fig-`/`tbl-` ids the nav's lists link to.
- `DOCXBodyEmitter.swift` — one body's AST and resolution → WordprocessingML: Heading 1–3, runs, lists by `numbering.xml`, native tables with a repeating header, inline drawings fitted to the 6-inch column, native footnotes, `SEQ` captions and `REF` cross-references with their results precomputed, References, a bookmark per paragraph node. Pure: it names each image by content hash and returns the media list. `emit(bodies:config:)` joins a document's bodies, which share one set of counters (ids, Word's footnote numbers, the `SEQ` sequences).
- `DOCXNames.swift` — every Word bookmark name (R-4-3): `p_<¶id>`, `l_<kind>_<name>`, mapped to Word's rule and cut to 40 with a hash; the one home, pinned by a census.
- `LaTeXEscape.swift`, `XHTMLEscape.swift`, `OOXMLEscape.swift` — text escaping for each target; the OOXML one also drops the characters XML forbids.
- `LaTeXSafeFilename.swift` — the validated `\input{}` filename, closing TeX-argument injection.
- `EmissionContract.swift` — the source of `EMISSION.md`; its examples are generated by calling the real emitter.
- `ElementCensus.swift` — which element kinds a compiled book contains; exhaustive over the AST, so a design must account for every kind.

### Config, imprints and languages
- `PublishConfig.swift` — the per-project config (`<project>/.maugham/publish/config.json`): metadata, outputs, cover, sections, `Format` (with `.unknown(raw)`), `PublishFormatRefusal`, `encodeAlways`.
- `PublishConfig+Imprints.swift` — `resolved(imprint:pieceIDs:)`, the one imprint door. An imprint (`config.imprints`) declares its own template, rendered set, metadata, cover and version counter.
- `PublishConfigStore.swift` — reads and writes the config atomically; `applyPatch` for `set_publish_config`.
- `PublishConfigValidator.swift` — schema, paths, imprints, languages, template existence, `formatError`, `bumpedNextVersion`.
- `JSONMergePatch.swift` — RFC 7396, the one merger for `set_publish_config` and imprint fragments.
- `JSONValue.swift` — a JSON value that can hold an explicit `null` (merge-patch fragments).
- `LanguageSet.swift` — reconciles `language`, `languages` and the `"source"` sentinel into ordered bodies; `identity` (e.g. `"en+sr"`) and `singleTag`.
- `BodyPlan.swift` — one bound, folded `BodyPlan.Body` per rendered language; the language folds happen here once per body.
- `LanguageSuffixedFile.swift` — resolves `template.es.tex`-style per-language variants of templates, styles and piece style files.
- `TranslationCoverage.swift` — the blocking coverage gate for a translated compile, plus Fountain element-drift warnings.
- `EditionStatus.swift` — where a book's language editions stand; the one derivation behind `translation_status` and the desk's language rows.

### Compiling and the catalogue
- `CompileOrchestrator.swift` — the one compile path: refuse, resolve, gate, mint, compile, snapshot, record; `dry_run`; the durable-progress ledger a partial failure reports. Output lands under the project's `Exports/`.
- `PDFCompiler.swift` — the PDF compile through tectonic, under the `MaughamBody` wrapper per body; stages the bodies `PublishProblemGate.resolve` resolved (`prepare(resolution:…)`; a figure that won't open is a problem) into `build/figures/`, and adds graphicx/longtable to `build/metadata.tex` for a book that needs them.
- `EPUBCompiler.swift` — the EPUB compile, one sectioned XHTML per body; names the images of the bodies `PublishProblemGate.resolve` resolved (`prepare(resolution:)`), builds the label hrefs, a References file per citing body and the nav's lists.
- `DOCXCompiler.swift` — the Word compile, the third format: `resolve(bodies:)` for Word's images (png, jpeg, gif, pdf, svg); `prepare(resolution:publishDir:)` draws a PDF's first page (by `DOCXImageGeometry.pdfBox`, the box the emitter measures) or an SVG (AppKit) to a 200 dpi PNG in `build/docx-media/` before emission, and one it can't draw is a problem; the page is A4 unless the region is US or CA: the language tag's, or this Mac's when the tag names none. The export label goes into `docProps/custom.xml`.
- `DOCXPackage.swift` — the `.docx` parts around the emitter's (content types first, relationships, settings, core/app/custom properties, media) and the styles: built-in, or `.maugham/publish/reference.docx` merged over them, a style matching a built-in by id or by Word's name (a localised Word's ids are renamed, and what pointed at them follows); a malformed one is a warning.
- `EPUBPackage.swift`, `EPUBOPFWriter.swift`, `EPUBContainerWriter.swift`, `EPUBZipPackager.swift` — the EPUB model, its OPF, `container.xml` and the zip; figure images are copied into `OEBPS/images/` at packaging.
- `ZipArchive.swift` — a Swift zip writer (stored or raw DEFLATE, deterministic, no spawn) and reader (CRC-checked; refuses ZIP64, encryption and path-escaping names); the DOCX packager writes with it and reads a writer's `reference.docx`.
- `OutputFilenameBuilder.swift` — `{title}-v{version}{label_suffix}.{ext}` (a draft: `{title}-draft{N}`) and title sanitising, shared by the compilers.
- `WordDraft.swift` — a Word export's draft (R-4-1): the `draft-N` version, its filename token, the next number, the label "Draft N, sent <date>" in the book's language, and the file's custom properties.
- `PublishMintGate.swift` — refuses a second concurrent compile of the same edition key, per project.
- `PublishingStores.swift` — the per-project bundle: `CompileJobManager`, catalogue, snapshots, `mintGate`.
- `CompileJob.swift`, `CompileJobManager.swift` — in-memory job state and phases for `compile_status`/`compile_cancel`.
- `Publication.swift` — one catalogue row; four-part identity `(imprint, version, language, format)`.
- `PublicationStore.swift` — the catalogue, append-only JSONL partitioned per device. Tripwire 17.
- `PublicationSnapshot.swift`, `PublicationSnapshotStore.swift` — the frozen publish tree a publication was compiled from; snapshot ids are validated against path escape.
- `Republisher.swift` — recompiles a publication from its snapshot under a fresh `-r` suffix; refuses a Word file (R-S8).
- `PublishToolchain.swift` — the Maugham and tectonic versions every `Publication` is stamped with.
- `PreviewCompiler.swift` — the subset preview compile into `build/preview/`, never `Exports/`; the piece filters.
- `PublishPreviewResolver.swift` — what the Publish persona's centre shows, with its reason.
- `PublishStarter.swift` — copies the bundled starter (`Maugham/Resources/PublishStarter/`) into `.maugham/publish/`; a Report takes the `report/` overrides (template, frontmatter, prose, config), chosen from the manifest on disk. `PDFCompiler` decides a Report's paper (Word's page rule) at each compile, and every compiler asks `PublishContext.reportTitled` for its "Untitled" title fallback, never for another book (R-S7).

### Tectonic
- `TectonicLocator.swift` — finds the bundled binary in the app's `Resources/bin`.
- `TectonicInvoker.swift` — spawns tectonic for one `.tex`, with a combined log and cancellation.
- `TectonicLogParser.swift` — log → warnings and errors (`Diagnostic`).
- `TectonicCache.swift` — the package cache, per build variant through `BuildVariant`. Tripwire 13.

### The design gate
- `SamplePageSelection.swift` — the smallest set of pieces that shows every element kind, from an `ElementCensus`.
- `SampleCompiler.swift` — compiles a proposal's sample pages against a scratch copy of the publish tree.
- `ProposalPromotion.swift` — the gate's verbs (approve, revert, finalize); the only writer of `.maugham/publish/` on a proposal's behalf.

## Rules

### The emission contract and templates
- **`EMISSION.md` is generated**: edit `EmissionContract.swift` and run the tests. `EmissionContractTests.test_committedEmissionDoc_matchesGeneratedContract` fails on a stale doc; regenerate by deleting `Maugham/Resources/PublishStarter/EMISSION.md` and re-running it (ADR 0013).
- **A per-piece `style_file` stays inside a scoped `\begingroup…\endgroup` — don't hoist the `\input` out**, or one piece's style leaks into the next. The name passes through `LaTeXSafeFilename` first; an unsafe one emits a deliberate undefined command rather than the `\input`.
- **Every emitted paragraph is anchored**: `\hypertarget{p-<tag>-<¶id>}{}` in LaTeX and `id="p-<tag>-<¶id>"` in XHTML on every node a paragraph produced. A slugline cross-links to the same slugline in each other rendered body (`\MaughamCrossLink` / `<a href>`). Every body's prologue carries `\providecommand` fallbacks, so a hyperref-less preamble still compiles.
- **Aesthetics live in `template.tex` / `styles.css`, never in the config**: the config cannot drive the engine into generic output.
- **Manuscript text is read from the op log**, never the `.md` (tripwire 20): `ProjectStoreASTSource` derives each piece (`TripwireGrepTests.test_noManuscriptFileReadsOutsideReconciler`; a non-manuscript read carries `// adr-0018-ok:`).

### Report elements
- **Resolution runs over the edition's book, then the subset is emitted.** The edition's book is every publishable piece less what the edition excludes (`include: false`, an imprint's dropped sections): an excluded section never blocks, numbers or cites, and a reference into it is unresolved. `PublishResolution.forCompile` resolves the source's `resolutionScope` (the edition's book behind any preview or sample narrowing); the compiler emits the AST built from the narrowed source with that resolution. Every door, preview and sample included, resolves once through `PublishProblemGate.resolve` and hands the bodies down (`resolved:`). The emitters read numbers, citations and targets and never count, so a one-chapter preview still prints "Figure 7".
- **A wrapper that overrides `resolutionScope` must override `isWholeBook` (true exactly when its pieces are its scope's)**: the default `true` lets a compile resolve a narrowed subset as if it were the book. Every wrapper forwards `publishContext()` too (`PublishContextTests`' forwarding checks, with a planted non-forwarding wrapper and a planted base-scoped edition filter as controls).
- **Element words come from the body's resolution, never a literal.** `PublishProblemGate.resolve` picks each body's `ElementWords` from its folded config; the target texts, the PDF's caption names and References heading, and the EPUB's captions, References and nav lists all read `resolution.words`. A body in a book with a figure or a table sets `\figurename`, `\tablename`, `\listfigurename` and `\listtablename` inside its `MaughamBody` group, English included.
- **`PublishProblem.isError(profile:)` is the one severity table.** In a Report the error kinds block a versioned compile and a republish; in every other profile, and in every preview and sample compile, all problems are warnings. Nothing else decides severity.
- **`FigureImageResolver` is the one path door.** A figure path is accepted only inside a research folder of the real project (`PublishContext.projectURL`, never a compiler's scratch dir); escapes are refused from the string before the disk is touched. Neither compiler reads an image path any other way.
- **The gate resolves once and passes the result down.** The compile door resolves each body for the format's images, judges the problems, and hands those same bodies to the compiler's `resolved:` (`PublishProblemGate.resolve`); a compiler handed them stages from that resolution and never resolves again.
- **Old templates degrade, never fail.** Every report construct is guarded at its point of use (`\ifdefined\longtable`, `\ifdefined\includegraphics`, `\ifdefined\listoffigures`), and the packages reach the preamble only through `build/metadata.tex`'s `\IfFileExists` lines, written only for a book with a figure or a table. A book without the new syntax emits byte-identical bodies. `EMISSION.md`'s report sections are the contract (`ReportPDFCompileTests` compiles an old preamble for real).

### Formats
- **The Fountain extension is spelled in `DocumentFormat` only; ask it, never a `"fountain"` literal** (tripwire 54, `TripwireGrepTests.test_theFountainExtensionIsSpelledInDocumentFormatOnly`).
- **Every Word bookmark name is spelled in `DOCXNames`**, and every field the Word body writes carries its result, so nothing asks to be updated on open (`TripwireGrepTests.test_bookmarkNamesAreSpelledInDOCXNamesOnly`, with a planted control).
- **The `.docx` is zipped and read by `ZipArchive`, never a spawned `zip`/`unzip`**, so the package is deterministic and nothing is spawned. **A Word figure is rasterised in `DOCXCompiler.prepare`, before emission**: the emitter sees PNG pixels, and a PDF or SVG that won't draw is a problem. **A writer's `reference.docx` is merged over the built-in styles**, a style matching by id or by Word's name; it never replaces the document body.
- **A format this build cannot produce is refused at the door.** `PublishConfig.Format` decodes a name a newer build wrote as `.unknown(raw)`, kept verbatim so the config re-encodes unchanged (ADR 0015). `allCases` is only what this build produces, so `.unknown` never reaches a picker.
- **`allCases` is every format this build produces (PDF, EPUB, Word), and every format list derives from it**: the desk's picker, the Exports footer and the MCP `format` enums. The preview shows PDF and EPUB; `PreviewCompiler.previewRefusal` refuses Word at the preview's door in its own sentence (log excerpt `unpreviewable_format: docx`), and `preview_compile`'s enum leaves out what it refuses.
- **The refusal comes before anything format-dependent runs**: no job, no collision check, no version mint, no `EMISSION.md` refresh, no dry-run verdict. `CompileOrchestrator.compile` and `PreviewCompiler.preview` return `.failed` with `PublishConfigValidator.formatError`'s sentence (log excerpt `unproducible_format: <raw>`). `Republisher` throws `RepublishError.unproducibleFormat`, which MCP reports as an invalid argument. The words are `PublishFormatRefusal`'s (`PublishFormatToleranceTests`).

### Minting and identity
- **A Report's publish problems refuse its compile or republish before the mint; every other book and every preview gets warnings** (`PublishProblemGate`). The door resolves each body once for the format's images and hands those bodies to the compiler's `resolved:`, so the book shows what the gate judged. A figure that fails to stage afterwards refuses a Report too (`publish_problems:` excerpt). `dry_run` can't see that: a Word figure is rasterised after the gate, so a PDF or SVG that won't draw first shows up on the real compile.
- **Every compile mints its version up front**, whether a fresh version, a language edition or a republish (with its `-r<suffix>`), before the compile and through an effective config. A Word export mints a draft instead (`WordDraft`): never `next_version`; the book's sent copies plus one, reserved on the gate without a language and asked again once reserved; its sent copy is written after a successful export (`SentCopyStore`), at the export id the file carries as `MaughamExportID`. A Word file is never republished, and no draft's snapshot is republished in any format (`RepublishError.wordIsNotRepublished`, R-S8). A language edition renders a version and never a draft (`Publication.isVersionSource`). The filename, the artifact's internal stamp and the catalogue row all agree, and a republish can never wear the original's filename.
- **Same-edition concurrent compiles are refused fast by `PublishMintGate`, not raced**: a refusal, not a queue; nothing waits its turn. A `dry_run` is exempt because it mutates nothing. Every compiler construction passes the shared `PublishingStores.mintGate` rather than a default (`PublishMintGateTests.test_everyProductionCompilerConstructionPassesTheSharedGate`).
- **`PublishConfig.resolved(imprint:pieceIDs:)` is the one imprint door.** Everything downstream (compilers, the filename builder, the coverage gate, the snapshot) reads a plain resolved config off `config.template`/`config.imprint` and never takes imprint as an argument of its own (`TripwireGrepTests.test_noImprintDeclarationOutsideTheResolutionDoor`, over `filesAllowedToDeclareImprint`).
- **The mint key and `Publication` are four-part, `(imprint, version, language, format)`**, and every production `Publication(` passes `imprint:` (`TripwireGrepTests.test_everyProductionPublicationConstructionCarriesItsImprint`). `compile`, `preview_compile`, `list_publications` and `read_publication_page` all speak `imprint`; the sentinel `"book"` selects what no imprint compiled.
- **A multi-body compile carries the joined identity** (`LanguageSet.identity`, e.g. `"en+sr"`) in its `Publication`, filename and mint-gate reservation. A single-body compile resolves templates and metadata against `LanguageSet.singleTag`. The language folds happen once per body in `BodyPlan`, so a second body cannot inherit the first one's metadata or style files.
- **One composition names a compiled book**: `PublishPreviewCentre.parts(for:)`, read by the preview centre, the desk's status line and the Exports footer, so none of them can disagree.
- **`JSONMergePatch` is the one merger**: `set_publish_config` and imprint fragments (`metadata`, `outputs`, `cover`) share its null-deletes-a-key rules.
- **The config keeps its shape across writes**: optional fields encode through `encodeAlways` as explicit `null`.
- **The catalogue is partitioned per device** (tripwire 17): this device writes only its own `publications.<deviceSlug>.jsonl` (`CheckpointPartitioningTests.test_publications_appendWritesPerDevice_andLoadMergesChronologically`, `test_publications_legacyFileIsReadAndNeverWritten`).
- **The tectonic cache's folder name comes from `BuildVariant`** (tripwire 13), so dev and stable builds keep separate caches (`TripwireGrepTests.test_noHardcodedIdentityStringsInMacSources`).

### The desk, the gate and translation
- **The department's people run on the compiler's rails, not here**: the desk (`DetailSegment.department`, ⌘⌥K) runs a named translator per language (`ProductionRole`, with a blind reader and a collator beside each) and a named designer (Tschichold) as confined `claude -p` sessions through `TranslatorOrchestrator`/`DesignerOrchestrator`, conformers over `CompilerOrchestrator`'s shape (`Maugham/Compiler/AREA.md`). A translation Run drives a seven-leg round per piece or for the whole book in binder order; its report (`PublishCentre.translationRound`) and the design gate (`.designProposal`) are arms of the one `publishCentre` switch (`Maugham/Views/AREA.md`).
- **The round report is written to the author in their own language**, and every verb on it is pressable without reading the target language.
- **A design Run proposes a spec, complete templates and compiled sample pages**, staged as described below.
- **The desk's Compile… is the MCP `compile`**: the same orchestrator, mint gate and coverage gate.
- **A translated compile must not ship a translation that lags its source**: `TranslationCoverage.check` walks the same pieces as `ProjectStoreASTSource.orderedPieces()` and blocks.
- **`EditionStatus` is the one derivation of a book's editions**: a stored `.translator` role is a third source of its language union beside translation files and open queries, so `translation_status` reports a role-only edition too.
- **Everybody on a book is named through one sheet**: `DepartmentCastSheet` calls `translatorRole(for:)` and `renameProductionRole`; there is no other way to name a cast member.
- **A design proposal never touches the live publish tree until the writer judges it at the gate.** It is staged under `.maugham/design/proposals/`, and `SampleCompiler` compiles its samples against a scratch copy. `ProposalPromotion` is the only writer of `.maugham/publish/` on its behalf.
- **The gate's four verbs (Approve / Request Changes / Revert / Finalize) each refuse in their own words; Finalize is the one irreversible step** (no `NSUndoManager` at any depth).
- **A translation Run resolves against the open document only** and writes through the same `TranslationWritePipeline` as `write_translation`.
- **A directive is a ruling and reaches a statement only through `RulingPerformer.rule`**; the glossary is rulings of a recognised shape (ADR 0030). Answering a translator's query can file a dated entry under that edition's brief (`Statement.Kind.editionBrief`) in the same act.
- **Claude's statement proposals are staged, never written**: `propose_edition_brief`/`propose_visual_language` stage under `.maugham/statements/proposals/`, and `StatementProposalGate.adopt` is the one write, a click (ADR 0030 §7).
- **A test that performs a real tectonic compile calls `try await TectonicProbe.requireReady()`** (CLAUDE.md).

## Recipes

### Add a block kind to publish
Start at the Core guide's recipe "Add a block kind to the text model" (`Packages/MaughamCore/Sources/MaughamCore/AREA.md`): it covers `MarkdownBlockParser`, `ElementCensus`, the emitters, `EmissionContract`, the phone reader and ADR 0022's ruling step.

### Change what the body emits
1. `LaTeXBodyEmitter.swift` and `XHTMLBodyEmitter.swift` — the arm or the command.
2. A new LaTeX command: define it in the starter (`Maugham/Resources/PublishStarter/preamble.tex` or the mode file `prose.tex`/`screenplay.tex`), or emit a `\providecommand` fallback in the body prologue so existing templates still compile.
3. `EmissionContract.swift` — the contract text and an example; then regenerate `EMISSION.md` through `EmissionContractTests`.
4. Tests: `MaughamTests/Publish/` (`PublishingEndToEndTests`, `StarterTemplateDefectProbeTests`; a real compile calls `TectonicProbe.requireReady()`).

### Add a field to the publish config
1. `PublishConfig.swift` — the property on its block, a snake_case `CodingKeys` entry, `encodeAlways` for an optional, and a tolerant `decodeIfPresent … ?? default` so an older config still decodes. If it is aesthetic, it belongs in the templates instead.
2. `Maugham/Resources/PublishStarter/default-config.json` — the starter's value.
3. `PublishConfigValidator.swift` — refuse bad values at save time.
4. Imprints: a field in `metadata`, `outputs` or `cover` is overridable through the merge-patch fragments with no code; a top-level field an imprint may replace needs a line in `PublishConfig+Imprints.swift`'s `resolved`.
5. `set_publish_config` needs nothing (it merge-patches the encoded config). Tests: `PublishConfigTests`, `PublishConfigValidatorTests`, `PublishConfigImprintResolutionTests`.

## Pointers
- ADRs: 0013 (the publishing pipeline), 0015 (persisted schema evolution), 0022 (the grammar ledger), 0024 (the translation layer), 0030 (translator, reader, collator; directives as rulings).
- `docs/guide/publishing.md` (Tables, figures, footnotes, citations and cross-references; Imprints; Bilingual editions) and `docs/guide/publish-department.md`.
- `docs/tripwires.md` rows 13, 17, 20, 54.
- Tests: `MaughamTests/Publish/` (notably `EmissionContractTests`, `PublishResolutionTests`, `PublishProblemGateTests`, `FigureImageResolverTests`, `ReportPDFCompileTests`, `ReportEPUBTests`, `PublishMintGateTests`, `PublishConfigImprintResolutionTests`, `BilingualPDFTests`, `TranslationCoverageGateTests`, `PublishFormatToleranceTests`), `CompileOrchestratorTests`, `RepublisherTests`.
- Neighbouring guides: `Maugham/Compiler/AREA.md` (the translator and designer orchestrators, the round's state machine and briefings), `Maugham/Views/AREA.md` (the department desk, the gate, the round report), `Maugham/MCP/AREA.md` (the publishing tools), `Packages/MaughamCore/Sources/MaughamCore/AREA.md` (the block parser, `ProductionRole`).
- History: `docs/history/publish.md`.
