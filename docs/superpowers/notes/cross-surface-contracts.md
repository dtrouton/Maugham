# Cross-Surface Contracts (phone ↔ Mac)

> You were likely sent here by a failing tripwire test. A tripwire fires when
> surface code reimplements something both surfaces share. Find the contract
> below, call its choke-point (Tier 1) or satisfy its contract type (Tier 2),
> and the tripwire passes. Spec: docs/superpowers/specs/2026-06-03-cross-surface-contracts-design.md

Tiers: **1** shared implementation (one MaughamCore impl; surfaces call it) ·
**2** contracted divergence (shared decision + contract test in both targets) ·
**3** free divergence (recorded as having no cross-surface invariant).

Status: ✅ done · 🔧 planned (this milestone) · 📋 recorded-no-action.
Full audit + execution order: `docs/superpowers/notes/2026-06-03-cross-surface-audit.md`.

| Contract | Tier | Choke-point / contract type | Test | Status |
|---|---|---|---|---|
| op-log filename ↔ docId (parse) | 1 | `OpLogStore.docId(fromOpLogFilename:)` / `docIds(…)` | `OpLogFilenameTests` + `OpLogFilenameContractTests` (both); tripwire `test_noReachAroundOpLogFilenameParsing` | ✅ |
| op-log filename (build) | 1 | `OpLogStore.opLogFileURL(forDocId:deviceSlug:in:)` | builder round-trip (both); tripwire on hand-rolled `.jsonl` | ✅ |
| inbox manifest filename | 1 | `InboxManifest.inboxManifestURL(forDeviceSlug:in:)` | builder round-trip (both) | ✅ |
| manifest filename literal | 1 | `ProjectManifest.fileName` | referenced, not literal | ✅ |
| manifest date strategy | 1 | `ProjectManifest.makeEncoder()` / `makeDecoder()` | round-trip (both) | ✅ |
| op/inbox Codable + dateEncoding | 1 | `JSONLAppendStore.dateEncoding` + shared types | existing round-trip tests | ✅ |
| ULID / ParagraphID / DeviceSlug / Deriver / AnnotationDeriver / merge | 1 | MaughamCore (single impl) | existing | ✅ |
| anchor stripping | 1 | `MarkdownDisplayFilter` | existing | ✅ |
| annotation task-anchor strip in diff cards | 1 | `MarkdownDisplayFilter.stripTaskAnchorsInline` (Mac must call) | both | ✅ |
| Fountain inline emphasis spans | 2A | consume `FountainLine.inlineSpans` on both surfaces | both | ✅ |
| Fountain bold/italic emphasis | 2A | `ScreenplayEmphasis.contract(for:)` | `ScreenplayEmphasisContractTests` (both) | ✅ |
| Fountain section underline | 2A | `ScreenplayEmphasis.underline` field | `ScreenplayEmphasisContractTests` (both) | ✅ |
| Fountain display-uppercase | 2A | `ScreenplayUppercase.shouldDisplayUppercase(_:)` | both | ✅ |
| title-page per-key style | 2B | `TitlePageFieldStyle.style(forKey:)` (display-IR) | both | ✅ |
| annotation kind → SF Symbol | 2A | `AnnotationKind.systemImageName` | both | ✅ |
| annotation kind → label | 2A | `AnnotationKind.displayName` | both | ✅ |
| write-rule pins (claudeAccept materialize, monotonic writtenAt, manifest date) | 2 | Mac-side contract tests | both | ✅ |
| intra-Mac dedup: device id, manifest filename lookups, id minting | 1 | `MacDeviceID.current`; `ProjectManifest.fileName`; `ProjectStore.newId` | Mac suite | ✅ |
| Bootstrap / Materializer / checkpoints / inbox merge / heading-scale / etc. | 3 | single-surface or agreed | — | 📋 |
| asterisk inline emphasis grammar (`*italic*`, `**bold**`, `***both***`, nesting) | 1+2A | `InlineEmphasisScanner` + `EmphasisTraits` (MaughamCore) is single source of truth; consumed by `MarkdownTokenizer` (prose) and `FountainTokenizer` (Fountain). iOS markdown reader keeps `AttributedString(markdown:)` but is pinned by `InlineEmphasisAppleParityTests` (MaughamCoreTests). Spec: `docs/superpowers/specs/2026-06-03-inline-emphasis-contract-design.md`. **Boundary:** asterisks only — underscore is each grammar's own concern. **Out-of-scope follow-ups:** (1) `_x_`/`__x__` unstyled on Mac prose editor (phone reader italicizes via Apple); (2) phone markdown reader strips emphasis markers (Apple) while Fountain reader fades them — strip-vs-fade inconsistency. | `InlineEmphasisAppleParityTests` | ✅ |
