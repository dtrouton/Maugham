# MaughamCore — area guide

Shared by the Mac app and the phone (tripwire 19: anything both surfaces touch is implemented here, once). Apple frameworks only; no UI imports. Cross-module API is `public`.

## Map

Every `.swift` file in this folder and in `Inbox/` appears once. `DocBudgetTests.test_everyCoreSourceFileIsOnTheCoreMap` fails when a file is missing.

### The op log (storage, chain, seals)
Rules for these files are in `Maugham/OpLog/AREA.md` → Rules ("Chain, identity and seals", "The load seam", "A foreign stream that got shorter", "Sealed segments and cost"); read them before editing here.
- `Op.swift` — the on-disk envelope of one operation, with its `Provenance` bag of optional fields.
- `OpKind.swift` — the closed set of op kinds; every permission and derivation switch is exhaustive over it.
- `SynthesisSource.swift` — typed cause of a synthesised op (rewind, pending recovery, anchor splice…); snake_case on disk (tripwire 12).
- `Deriver.swift` — ops → `DerivedState` (paragraph map plus `sequence`); owns `appliesToManuscript`, the one which-ops-become-words classifier.
- `Materializer.swift` — renders derived state back to anchored Markdown text.
- `Bootstrap.swift` — first-open migration of a plain `.md` into an op log, minting the `¶id` anchors; idempotent.
- `DerivedManuscript.swift` — the one sanctioned read of a CLOSED document's content, derived from the op log (tripwire 20).
- `DerivedManuscriptCache.swift` — per-project cache in front of `DerivedManuscript`, keyed by the doc's op-log file set.
- `JSONLAppendStore.swift` — generic append-only JSONL file; with a `ChainPolicy` it chains, verifies and seals.
- `PartitionedJSONLFile.swift` — `<stem>.<deviceSlug>.jsonl` naming for project-scope per-device sidecars (ADR 0012).
- `ParseDiagnostics.swift` — what a JSONL load skipped, as reportable data instead of a silent drop.
- `DeviceSlug.swift` — the filename-safe device slug; private init, built only by `make(from:)` (tripwire 24).
- `OpLogStore.swift` — the per-document op-log store and its door: append, sign, chain-seal, the write-permit question (tripwire 46), the loads that need its trust cache, and one-line forwarders to the six files below.
- `OpLogFiles.swift` — op-log file names and globs: doc id + `DeviceSlug` → filename and back (tripwire 24).
- `OpLogClassifier.swift` — load and classify one op-log file; `walk`, the one verify walk, holds the keyless arm (tripwire 39).
- `StreamPositions.swift` — revocation marks, permit applied/seen positions, the unsigned snapshot's positions and the placeholder refusal.
- `StreamCensus.swift` — truncated and absent streams and the lost-history derivation.
- `LocalWritePermitBuilder.swift` — builds `LocalWritePermit` behind `OpLogStore.localWritePermit`; `startedBy`, `unownedPiece` (tripwire 46).
- `SegmentSealer.swift` — rotates a device's own live tail into a signed `.mzseg`, and `SegmentSignature` (tripwire 17).
- `OpLogStore+Testing.swift` — the single-identity convenience init kept for suites that predate actors.
- `OpLogChain.swift` — the chained wire format and its pure verifier; the one recogniser of seal lines (tripwire 37).
- `OpLogSegment.swift` — the sealed, compressed, checksummed `.mzseg` container for a closed segment (ADR 0016).
- `OpLogDeviceState.swift` — the chain heads this device remembers, verified segments, acknowledged losses; also `ChainPolicy`.
- `OpLogProvenance.swift` — per-file line counts from a load: vouched for, history, held, refused.
- `OpLogQuarantine.swift` — set-aside `.lines` records and their return; also `RevocationSplit`, which cuts a revoked span.
- `IntegrityQuarantine.swift` — persists undecodable op-log lines under `.maugham/conflicts/quarantine/` for forensics.
- `ForeignStreamWatch.swift` — remembers where other devices' streams stood, so a stream that got shorter is noticed.
- `LoadBurstCensus.swift` — counts load-path bursts released builds signed with the wrong actor; provenance only, reaches no table.
- `Checkpoint.swift` — one ⌘S checkpoint: label, time, op pointer, and the document (if any) in view.
- `CheckpointStore.swift` — per-device checkpoint files; an unreadable file is reported beside the rows read.
- `RecoveredHistory.swift` — compares a recovered set-aside op-log file against the current draft.
- `SweepReason.swift` — why an orphan-annotation sweep is pending, carrying the removed paragraph ids.

### Trust and the register
Rules for these files are in `Maugham/OpLog/AREA.md` → Rules ("The register and trust", "Chain, identity and seals", "The unsigned door, scope and a piece of her own"); read them before editing here.
- `RegistryRecord.swift` — the signed registry records (device, person, claim, forgotten person key) and `RegistryDirectory`'s cases.
- `RegistryCanonical.swift` — the one definition of the bytes a registry signature covers (tripwire 42).
- `RegistryWriter.swift` — the one door that signs and writes registry records and spells their directories (tripwire 40).
- `RegistryWriter+Restore.swift` — writes already-signed bytes back without re-signing.
- `RegistryReader.swift` — verifies every record and lists the malformed ones; builds `Registry`.
- `RegistryCache.swift` — this device's byte-faithful memory of verified records; restores deleted or tampered ones.
- `RegistryPresence.swift` — what a device writes about itself at open, the root record, and the silent admissions.
- `RegistryAdmission.swift` — the root's acts: admit, revoke, retire, rename, claim, change permit, link or forget a person key.
- `AdmissionMemory.swift` — device-local memory of the label the writer gave a device on the admission sheet.
- `TrustTable.swift` — `TrustVerdict` and the pure table answering what one seal's key is to this device (tripwire 39).
- `TrustResolution.swift` — the impure half: reads the folder, reconciles the cache and builds the `TrustTable`.
- `TrustEvents.swift` — dated things that happened to the book's people, derived from the register.
- `TrustEventSentence.swift` — one `TrustEvent` in the writer's words, shared by History and the phone's Settings.
- `HeldLines.swift` — whose a held line is and the sentence for it; builds the three `Holder` arms (tripwire 49).
- `DeviceCode.swift` — the four-character key code a device shows, spelled once so two screens compare.
- `DeviceStanding.swift` — what this device is to one book, in one sentence, for the Mac and the phone.

### Permits and posture
Rules for these files are in `Maugham/OpLog/AREA.md` → Rules ("The permit", "The load seam", "The unsigned door, scope and a piece of her own"); read them before editing here.
- `Permit.swift` — the rungs, `Permit.allows` (the one table over `OpKind`), load-emission and judging-actor rules (tripwires 44, 48).
- `PermitEvent.swift` — the signed registry record of a permit change, with its mark and snapshot.
- `PermitMark.swift` — where a permit changed, as chain positions every device can check.
- `PermitTimeline.swift` — one person's permits in order; the check reads this, never the record's fields (tripwire 43).
- `PermitPartition.swift` — judges a file line by line against the timeline, before the parse (tripwire 45).
- `PermitWords.swift` — the writer-facing words for each rung, shared by both surfaces.
- `OpLogPermitContext.swift` — the document facts (class, starter, ownership) a reader needs before asking the permit table.
- `DocumentClass.swift` — maps a stream's document id to the kind of place a permit names.
- `UnsignedSnapshot.swift` — the photograph of unsigned streams taken at the first narrowing (tripwire 49).
- `LocalWritePermit.swift` — what this device's own hand may write into one stream; `mayMintOpening` lives here (tripwire 46).
- `Posture.swift` — what a surface may offer for the document shown: the verb list and its reasons.
- `PostureDoor.swift` — the one place a `LocalWritePermit` becomes a `Posture`, on Mac and phone (tripwire 51).

### The person key
Rules for these files are in `Maugham/OpLog/AREA.md` → Rules ("The person key", "The register and trust"); read them before editing here.
- `PersonKey.swift` — the per-person `P256` key kept in iCloud Keychain; the one production software key (tripwire 36).
- `PersonKeyStore.swift` — where the person key lives: the keychain store, the in-memory store, and `PersonKeyStoreChoice`.
- `RegistryPersonClaim.swift` — the claim inside a device record that it belongs to a person key, signed by that key.
- `TrustRecognition.swift` — `Recognition.recognise` (own device, known person, or ask) and the sheet's `ClaimHint`.
- `SavedByReader.swift` — the one reader of iCloud's most-recent-editor name for a file.

### Text model and parsing
- `ParagraphID.swift` — the four-character paragraph id, its alphabet and `mintUnique(excluding:)` (tripwires 8, 23).
- `ParagraphParser.swift` — splits anchored Markdown into paragraphs by blank lines; the per-keystroke hot path.
- `MarkdownBlockParser.swift` — `MarkdownBlock` and the one block-level Markdown parser every surface shares.
- `ManuscriptBlocks.swift` — the report block layer over that parser: labelled headings, captioned tables, figures, footnote definitions.
- `TableText.swift` — the one pipe-table formatter, and its cell lookups.
- `TableClipboard.swift` — spreadsheet cells pasted as tab-separated text, read by Excel's quoting.
- `ManuscriptLabel.swift` — `ManuscriptLabel` (`fig`/`tbl`/`sec`) and `ManuscriptAttributes.split`, the trailing `{#kind:name}` reader.
- `ManuscriptInlineScanner.swift` — finds footnote references, citations and cross-references inside sentences.
- `ManuscriptIndex.swift` — the project index: labels, cited keys and every diagnostic, line by line.
- `MarkdownDisplayFilter.swift` — strips the op-log anchors for display; the single anchor-stripping source.
- `InlineEmphasisScanner.swift` — flattens asterisk emphasis into runs and marker ranges for any renderer.
- `EmphasisTraits.swift` — the bold/italic option set an emphasis run carries.
- `TaskMarkup.swift` — the one test for whether text contains inline-task markup.
- `FountainTokenizer.swift` — parses Fountain source into a `FountainScript` with a line-based state machine.
- `FountainScript.swift` — a parsed Fountain document and its computed metrics.
- `FountainLine.swift` — one classified line of a parsed Fountain script.
- `ScreenplayElement.swift` — the Fountain element classification each line carries.
- `ScreenplayEmphasis.swift` — the cross-surface emphasis contract per screenplay element.
- `ScreenplayUppercase.swift` — which screenplay elements display force-uppercased.
- `TitlePageFieldStyle.swift` — per-key title-page display style, shared by the Mac editor and phone reader.
- `TypographySettings.swift` — font, size, spacing and smart-typography settings, global or per-project.

### Annotations and suggestions
- `Annotation.swift` — the annotation projection: kind, status, triage mark and filter.
- `AnnotationDeriver.swift` — ops plus paragraph map → annotations, honouring amendment rules.
- `AnnotationAggregation.swift` — the ops → annotations walk both surfaces read through.
- `AnnotationInverse.swift` — which compensating op undoes which annotation resolution.
- `AnnotationOwnership.swift` — whose annotation it is, and who may edit, withdraw, reopen or dispose of it.
- `SpanAnchor.swift` — a sub-paragraph anchor: quoted span, context and position hint.
- `SpanAnchorResolver.swift` — stateless re-find of a span anchor in a paragraph's display text.
- `SpanText.swift` — typography- and whitespace-insensitive canonical form for span matching.
- `ShingleMatcher.swift` — k-word shingle overlap used for orphan recovery.
- `SuggestionDisplay.swift` — the before/after of a suggested change, as both surfaces show it.
- `SuggestionSplice.swift` — applies a suggestion's replacement to a paragraph identically on both surfaces.

### Statements, passes and roles
- `Statement.swift` — a writer statement (intent, visual language, edition brief, lessons, first reader) and `Statement.Kind`.
- `StatementLookup.swift` — `StatementConvention`'s path table and pure lookups over the manifest's statements.
- `RulingsSection.swift` — parses and renders a statement's `## Rulings` list items.
- `RulingShapes.swift` — the directive and glossary shapes recognised over a ruling's text.
- `ReviewPass.swift` — a named review pass and its editor, with presets and effective brief and name.
- `PassState.swift` — where one piece stands on one review pass.
- `ReviewStatus.swift` — the one derived status dot a piece shows; no `default:` arm.
- `ProductionRole.swift` — a named translator, reader, collator or designer in the publish department.

### Project model
- `ProjectManifest.swift` — `project.maugham.json`: structure, research, statements, passes, roles; `currentSchemaVersion` and its gate; `encodeForDisk`, the one way a manifest becomes bytes for disk.
- `ProjectProfile.swift` — the Report profile and the four project switches; `effectiveSwitches` and `contentSchemaFloor`.
- `ProjectType.swift` — the four project forms plus decode-only `.unknown`.
- `ProjectType+Capabilities.swift` — what callers ask of a kind (`primaryFormat`, `holdsPieces`, `symbolName`, `forPromotedPiece`), answered once for Mac and phone (tripwire 55).
- `ProjectKindName.swift` — the one name for a project's kind: "Report" for a Report (or the Report choice, `of(profile)`), else the type's name; nothing else spells one (`TripwireGrepTests.test_kindNamesAreSpelledInProjectKindNameOnly`).
- `DocumentFormat.swift` — a manuscript's format from its extension: the extension, held blank lines, screenplay family, help resource, icon (tripwires 54, 55).
- `ProjectTargets.swift` — optional word, deadline and page targets.
- `StructureItem.swift` — a binder node (group or document), including `startedBy` and pass states.
- `TreeNode.swift` — the id-keyed tree protocol and the generic `TreeWalk` walkers.
- `ResearchItem.swift` — a research tree node and its identity-bearing `ResearchRole`.
- `CitationInfo.swift` — a research item's citation details and `CitationKey`, which validates and suggests `[@key]` keys.
- `CitationStyle.swift` — `CitationLibrary` (a research tree's citable sources) and `CitationStyle`, the author–date in-text label and References entry.
- `PieceKind.swift` — a Collection piece: loose document or reference to another project.
- `PaletteCard.swift` — the sensory-palette card model, its parser and canonical renderer.
- `PaletteConvention.swift` — palette and craft-intent paths and filenames shared by both surfaces.
- `FileNaming.swift` — `NN-slug` filenames for new structure items.
- `Slugifier.swift` — title → filesystem-safe slug.
- `DocIdShape.swift` — the shape a minted document id must have.
- `ManifestShadow.swift` — the verified shadow copy of the manifest, read when the live one fails to decode.
- `ShareMetadata.swift` — platform-neutral snapshot of a folder's iCloud share metadata; an indicator, never a role.
- `FileURLShareMetadataReader.swift` — fills `ShareMetadata` from the OS's share resource keys.
- `ProjectShareEligibility.swift` — whether a folder can be offered for iCloud sharing, and why not.

### Publishing and translation shared types
- `TranslationRecord.swift` — one translated paragraph for one language; append-only, `nil` text is a tombstone.
- `TranslationStore.swift` — per-device translation sidecar files: load, merge, append.
- `TranslationDeriver.swift` — source hash, fresh/stale/missing status and the translated document view.
- `TranslationConstructSkeleton.swift` — structural fingerprint that warns when a translation drops Markdown constructs.

### Tables and formulas
- `TableIDs.swift` — row and column ids, the cell key and the 8-character id minter.
- `CellValue.swift` — a cell's value, formula error codes and cell content.
- `CellFormat.swift` — number, date and negative formats and cell alignment.
- `FigureTable.swift` — a table's rows and columns as ordered id slots with tombstones, its cells, header/total rows; the model the op log derives.
- `Formula.swift` — a cell's formula syntax tree; refs stored by row and column id, research refs by position.
- `CellAddress.swift` — A1 notation: column letters, `$` absolute markers.
- `FormulaParser.swift` — parses formula text (Excel precedence), renders it as A1 by live position (a deleted range edge shrinks inward), shifts it for fill.

### Inbox and capture
- `InboxEntry.swift` — one capture row in the per-device inbox manifest.
- `InboxManifest.swift` — the per-device inbox manifest path builder.
- `InboxConvention.swift` — inbox asset subdirectory names and the (kind, filename) → URL mapping.
- `InboxFileKind.swift` — classifies a file under `.maugham/inbox/` by subtree.
- `Transcriber.swift` — the speech-to-text seam the transcription worker depends on.

### Build variant, identity and utilities
- `BuildVariant.swift` — stable vs. dev identity: names, support folder, socket path (tripwire 13).
- `DeviceActor.swift` — the four writers on one device, each with its own key (author, assistant, translator, maugham).
- `DeviceIdentity.swift` — one actor's Secure Enclave signing key and stable device id (tripwire 35).
- `DeviceIdentity+Testing.swift` — software test signers, quarantined by name (tripwire 36).
- `LocalIdentities.swift` — this device's actor identities, minted lazily on first naming.
- `DeviceState.swift` — the path of this device's own key material under Application Support.
- `ULID.swift` — monotonic sortable 26-character ids.
- `StableHash.swift` — launch-stable FNV-1a hashing for on-disk ids; never `hashValue`.
- `ISO8601Fast.swift` — hand parser for the two ISO 8601 shapes Maugham writes.
- `SafeRelativePath.swift` — resolves an untrusted project-relative path, refusing escapes from the root.
- `DotfileScan.swift` — name-based dotfile test for scans that must ignore the BSD hidden flag.
- `TestWorkspace.swift` — dev-only throwaway root that fences mutating test MCP tools.
- `IntegrityChecks.swift` — pure consistency checks over already-loaded ops, checkpoints and filenames.
- `ProjectIntegrity.swift` — the live project health report (parse skips, dangling checkpoints, conflict twins).
- `MerkleManifest.swift` — per-file SHA-256 plus root hash over a set of files.
- `BackupGeneration.swift` — one immutable backup snapshot: id plus manifest.
- `BackupSignature.swift` — content signature stable across checkpoint-only saves.
- `BackupWriter.swift` — writes, verifies and prunes full-copy backup generations.
- `BackupRunner.swift` — runs a backup against configured destinations when the signature changed.
- `BackupRestore.swift` — lists and restores backup generations.

## Rules
- **The op log, trust, permit and person-key files here are governed by `Maugham/OpLog/AREA.md` → Rules**, which owns their rules because the Mac is where they bind. Before editing a file under the Map headings "The op log", "Trust and the register", "Permits and posture" or "The person key", read the OpLog Rules sections that heading names. The bullets below name each census; the OpLog guide gives the why.
- Shared by both surfaces means implemented here once; the phone never re-implements the Mac (tripwire 19, `TripwirePhoneGrepTest`; `docs/superpowers/notes/cross-surface-contracts.md`).
- Imports are Foundation, CryptoKit, Security and `os` only. No AppKit, UIKit or SwiftUI; no third-party packages.
- Cross-module API is `public`; let the build say what needs it.
- Derivations are pure: ids, timestamps and the clock are arguments. A `Logger` line is the only side channel.
- No `UndoManager` here; undo is expressed as compensating ops (`AnnotationInverse`, ADR 0023).
- Persisted enums follow ADR 0015: an `.unknown` case and a tolerant decoder; an identity-bearing value keeps `.unknown(raw)` verbatim.
- Adding a `ProjectType` case bumps `ProjectManifest.currentSchemaVersion`.
- `ProjectType` is polymorphic; Collection references are Mac-local.
- Manifest `modified` must round-trip through ISO8601 with whole-second rounding.
- Switches over `OpKind`, `ReviewStatus`, `ProjectType` and `DocumentFormat` carry no `default:`, so a new case is a compile error. Ask kind and format by capability, never by `==` (tripwire 55, `TripwireGrepTests.test_projectKindAndFormatAreAskedByCapabilityNotByEquality`); the Fountain extension is spelled only in `DocumentFormat` (tripwire 54, `TripwireGrepTests.test_theFountainExtensionIsSpelledInDocumentFormatOnly`).
- Mint paragraph ids with `mintUnique(excluding:)`; test literals use the id alphabet (tripwires 23, 8: `TripwireGrepTests.test_noBareParagraphIDMintInProduction`, `test_paragraphIdLiteralsInTestsUseValidAlphabet`).
- `SynthesisSource` is a typed enum; adding a cause adds a case (tripwire 12; enforced by the compiler).
- Variant names and socket paths live only in `BuildVariant` (tripwire 13, `TripwireGrepTests.test_noHardcodedIdentityStringsInMacSources`).
- Every JSONL stream is partitioned per device; never one shared file (tripwire 17, `OpLogStoreSegmentTests.test_legacyFile_neverSealed`). Filenames take a `DeviceSlug` (tripwire 24: the compiler and `OpLogFilenameContractTests`).
- Closed manuscripts are read through `DerivedManuscript`, never the `.md` (tripwire 20, `TripwireGrepTests.test_noManuscriptFileReadsOutsideReconciler`). Anchors are stripped only by `MarkdownDisplayFilter`; don't add a target-local copy.
- Device ids come from `DeviceIdentity`/`LocalIdentities`; no host names (tripwire 35, `TripwireGrepTests.test_noHostnameIdentity`).
- No software private key outside `PersonKey.swift` and `DeviceIdentity+Testing.swift` (tripwire 36, `TripwireGrepTests.test_noSoftwarePrivateKeyInProduction`).
- Seal lines are recognised in `OpLogChain` only (tripwire 37, `TripwireGrepTests.test_sealLinesAreRecognisedInOpLogChainOnly`).
- An `async` function in the `OpLogStore` split's six files says `@MainActor`: isolation does not move with the text (tripwire 56, `OpLogClassifierIsolationTests`).
- A load names a `DeviceActor`, and the load's own emissions are the author's (tripwires 38, 48: `TripwireGrepTests.test_noDeviceStringAtAProductionDocumentLoad`, `test_theLoadEmissionRuleIsSpelledInThePermitLayerOnly`).
- Trust closures are built from `TrustTable` verdicts, never a Bool (tripwire 39, `TripwireGrepTests.test_everyTrustClosureIsBuiltFromTheTrustTable`).
- Registry records are written through `RegistryWriter`, by three caller files only, over `RegistryCanonical`'s bytes (tripwires 40, 41, 42: `TripwireGrepTests.test_registryRecordsAreWrittenThroughRegistryWriterOnly`, `test_theRegistrysWritersAreThreeFiles`, `RegistryCanonicalCensusTests`).
- The role check reads `PermitTimeline`; `Permit.allows` and `Deriver.appliesToManuscript` are the only tables (tripwires 43, 44: `TripwireGrepTests.test_theRoleCheckReadsTheTimelineAndNotTheRecordsField`, `test_thePermissionTableIsSpelledInThePermitLayerOnly`).
- Partition call sites, the write-side permit and rung comparisons stay in their named homes (tripwires 45, 46, 47: `TripwireGrepTests.test_thePartitionsCallSitesAreExactlyTheNamedList`, `test_theWriteSidePermitQuestionHasOneFunction`, `test_aPermitRungIsComparedOnlyInThePermitLayer`).
- The unsigned door's decisions each have one home (tripwire 49, `TripwireGrepTests.test_theNarrowingPredicateAndTheSnapshotAreInThePermitLayerOnly` and its siblings); a `Posture` is built only in `PostureDoor` (tripwire 51, `TripwireGrepTests.test_postureIsAskedOfThePermitInOnePlace`).
- The held-line and schema call sites in `OpLogDeviceState.swift` (`acknowledgedLosses`, `expectedStreams(`) and `StreamCensus` are counted per file (tripwire 50, `TripwireGrepTests.test_theP3bCountedListsAreExactlyTheNamedArrays`): a new call site updates `countedLists`.
- The person key's doors are counted in `PersonKeyCensusTests` (tripwire 53).
- Run `./scripts/test.sh core` after any change here, then both app schemes; tests build under `TestTemp`.
- Every manifest written to disk goes through `ProjectManifest.encodeForDisk`, which stamps the content floor so an older build refuses rather than strips v10 content; narrowing raises only to `narrowingSchemaVersion` (`TripwireGrepTests.test_manifestBytesForDiskComeFromOneFunction`).

## Recipes

### Add a manuscript element
1. Recognise it: a block in `ManuscriptBlocks.swift` (over `MarkdownBlockParser`), or an inline in `ManuscriptInlineScanner.swift`. A label it carries is read by `ManuscriptLabel.swift`.
2. Index and diagnose it in `ManuscriptIndex.swift`: record what it defines or cites, and report each way it can be wrong.
3. Publish it, reading the recognised element rather than re-parsing the text: map it into a node or inline of `Maugham/Publish/ProjectAST.swift` in `Maugham/Publish/ProjectASTBuilder.swift` (inlines via `Maugham/Publish/InlineParser.swift`); number, resolve and report it in `Maugham/Publish/PublishResolution.swift`, with any new problem kind in `Maugham/Publish/PublishProblem.swift` and its severity in `isError`; render it in `Maugham/Publish/LaTeXBodyEmitter.swift` and `Maugham/Publish/XHTMLBodyEmitter.swift`, guarded so an old template still compiles; add a report example to `Maugham/Publish/EmissionContract.swift` and regenerate `Maugham/Resources/PublishStarter/EMISSION.md`. The editor does not read the layer yet.

Checks: the manuscript grammar tests in `MaughamCoreTests`; `PublishResolutionTests` and the emitter tests in `MaughamTests`.

### Add a block kind to the text model
1. `MarkdownBlockParser.swift` — add the `MarkdownBlock` case and its rule in the precedence order the parser documents.
2. Fix every switch the compiler now flags. Today: `Maugham/Publish/ProjectASTBuilder.swift`, `Maugham/Views/GuideMarkdownView.swift`, `Maugham/Views/ResearchNotePreviewPane.swift`, `Maugham/Views/SyntaxHelpSheet.swift` and the phone reader `MaughamPhone/Read/MarkdownBlocks.swift`. Find them with `grep -rn 'case \.thematicBreak'`.
3. To publish it rather than degrade it to paragraph text: add a node to `Maugham/Publish/ProjectAST.swift`. `Maugham/Publish/ElementCensus.swift` switches over the AST with no `default:`, so its `Kind` must grow a matching case.
4. Add arms to `Maugham/Publish/LaTeXBodyEmitter.swift` and `Maugham/Publish/XHTMLBodyEmitter.swift`.
5. Add an example to `Maugham/Publish/EmissionContract.swift`. `EmissionContractTests` then fails until `Maugham/Resources/PublishStarter/EMISSION.md` is regenerated to match.
6. Manuscript grammar is governed by ADR 0022's ledger: a block kind manuscripts may carry needs a ruling first.

Checks: the compiler (exhaustive `MarkdownBlock` and AST switches), `ElementCensus`, `EmissionContractTests`.

### Add a Statement.Kind
1. `Statement.swift` — add the case, its raw string, and both arms of the hand-written `rawValue` and decoder. Older builds keep the new kind as `.unknown(raw)` verbatim, so no schema bump is needed.
2. `StatementLookup.swift` — add a `StatementConvention` path and a `newPath` row. That switch has a `default:`, so a missing row silently returns `nil`.
3. Exhaustive switches on `Maugham/` (from `grep -rn 'case \.lessons'`): `Maugham/Canvas/Promotion.swift` (`kindTitle`), `Maugham/Compiler/RulingPerformer.swift` (`noun`), `Maugham/Views/ProjectWindow.swift` (`statementPane(forMark:in:)`).
4. `if case` sites that default silently: `Maugham/Views/StatementPane.swift` (pane title) and `Maugham/Views/RulingsStratum.swift` (stratum title).
5. If the kind gets a pane: a `DetailSegment` case in `Maugham/Models/DetailSegment.swift`, its arm in `Maugham/Views/DetailPaneToggle.swift`, a shortcut in `Maugham/MaughamApp.swift`, a place in `PersonaPaneRegistryTests.canonicalPaneOrder`, and membership in each persona's `Persona.panes` (`Maugham/Models/Persona.swift`).
6. If Claude reads it: a read tool beside `Maugham/MCP/Tools/LessonsTools.swift`. `CompilerAllowlistTests.statementWriters` must still find no writer.
7. If the writer writes it: one production file names the kind to `RulingPerformer`, guarded by a census copied from `TripwireGrepTests.test_theLessonsLedgerIsWrittenFromOneFile` or `test_theFirstReadersStatementIsWrittenFromOneFile`.

Checks: the compiler, `StatementTests` and `StatementLookupTests` round-trips, `PersonaPaneRegistryTests` and the allowlist census.

### Add a ProjectType case
1. `ProjectType.swift` — add the case and its snake_case raw value, add it to `allCases`, and bump `ProjectManifest.currentSchemaVersion` (ADR 0015).
2. `ProjectType+Capabilities.swift` and `ProjectKindName.swift` — answer every capability for the new case (`primaryFormat`, `holdsPieces`, `symbolName`, `forPromotedPiece`) and its name. Each is an exhaustive switch, so the compiler flags them; the phone's icons read `symbolName` and need no change of their own.
3. The other exhaustive switches the compiler flags:
   - `Maugham/Stores/ResearchScope.swift` — `researchRouting` and `derivedResearchItems(forDocumentId:)`;
   - `Maugham/Models/TreePane.swift` — `init(for:)`;
   - `Maugham/Views/NewProjectSheet.swift` — `help(for:)` and `create()`.
4. A factory in `Maugham/Stores/ProjectFactory.swift` for `create()` to call.
5. If the new kind needs a question no capability answers, add a capability (or an exhaustive switch at the site); never an `==` on the case, which `TripwireGrepTests.test_projectKindAndFormatAreAskedByCapabilityNotByEquality` refuses (tripwire 55).

Checks: the compiler for steps 2 and 3, `SchemaEvolutionToleranceTests`, and the kind-equality census.

## Pointers
- `Maugham/OpLog/AREA.md` — the Rules for this package's op log, trust, permit and person-key files (see the first Rules bullet), and the op log's behaviour.
- ADR 0032 (signed op log), ADR 0015 (schema evolution), ADR 0019 (clean derived .md), ADR 0022 (grammar ledger)
- `docs/superpowers/notes/cross-surface-contracts.md` — what both surfaces share and why it lives here.
- `docs/tripwires.md` rows 8, 12, 13, 17, 19, 20, 23, 24, 35–51 and 53–56: the tripwires the Rules above cite.
- Tests: Core's own suite in `Packages/MaughamCore/Tests/MaughamCoreTests/` runs through `./scripts/test.sh core` (no scheme hosts it). Worth knowing: `DocBudgetTests` (this map's census), `SchemaEvolutionToleranceTests`, `FountainTokenizerDifferentialTests` (the parser against its frozen reference), `MarkdownBlockParserTests`, `OpLogChainTests`, `RegistryCanonicalCensusTests`, `OpLogClassifierIsolationTests`; the app-side censuses are in `MaughamTests/TripwireGrepTests.swift` and `MaughamTests/PersonKeyCensusTests.swift`.
- Neighbouring guides: `Maugham/Publish/AREA.md` (the publish side of a block kind), `MaughamPhone/AREA.md` (the phone's consumers).
- No history file: this guide was written in the template and nothing has been moved out of it.
