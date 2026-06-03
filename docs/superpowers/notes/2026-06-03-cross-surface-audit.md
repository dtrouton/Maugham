# Cross-Surface Contract Audit — Findings & Worklist

_Date: 2026-06-03. Produced by Task 7 of the cross-surface-contracts plan
(`docs/superpowers/plans/2026-06-03-cross-surface-contracts.md`), via four parallel
read-only axis sweeps + an adversarial Tier-3 review. Drives the Phase-C execution order._

## Already correct — SHARED, no action (recorded for completeness)

These are Tier-1 contracts already implemented once in MaughamCore and called by both
surfaces; the audit confirmed no surface reimplements them:

- ULID generation (`ULID.generate`); ParagraphID parse/format; `DeviceSlug.make`.
- Op-log merge (`OpLogStore.mergeSortedDedup`); op-log filename→docId
  (`OpLogStore.docId(fromOpLogFilename:)` — done in Phase A, tripwire-enforced).
- `Deriver.derive`; `AnnotationDeriver.derive`; annotation status; `Materializer` (Mac-only write).
- `MarkdownDisplayFilter.stripAnchors`/`stripTaskAnchorsInline` (the strip itself).
- `Op` / `InboxEntry` Codable + `JSONLAppendStore.dateEncoding`.
- `ScreenplayEmphasis.contract(for:)` bold/italic (Tier 2, contract test in both targets).

## Worklist (execution order)

### Bugs first (user-facing; each lands with its contract)
- **B1 — phone drops Fountain inline emphasis.** `FountainSemanticRenderer.styledText`
  ignores `FountainLine.inlineSpans`, so `*italic*`/`**bold**`/`_underline_` inside
  action/dialogue render plain on the phone (the Mac renders them via
  `ScreenplayMode.applyInlineSpan`). Decision data already shared (`FountainInlineSpan`
  in MaughamCore); the phone just doesn't consume it. Tier 2, depth A. Add a contract
  test asserting the phone applies the same spans the parser produces.
- **B2 — Mac annotation diff cards show raw task anchors.** `AnnotationsPane`
  `AnnotationRow.diffCard` renders `priorText`/`suggestedText` without
  `MarkdownDisplayFilter.stripTaskAnchorsInline`; the phone's `AnnotationDetailView`
  strips them. Tier 1 (shared fn exists) — Mac just needs to call it. Add/extend a test.

### Tier 1 — collapse reimplemented builders (producer-side twins of the doc-id bug)
- **T1a — op-log filename builder.** `AnnotationWriter.opLogURL` hand-rolls
  `"\(docId).\(slug).jsonl"`; the Mac builds it in the private
  `OpLogStore.store(forDocId:deviceSlug:)`. Promote a `public static func
  opLogFileURL(forDocId:deviceSlug:in:)` to `OpLogStore`; both writer sites call it.
  Add a reach-around tripwire pattern for hand-rolled `".jsonl"` filename construction.
- **T1b — inbox manifest filename builder.** `InboxCaptureWriter.manifestURL` (phone)
  and `InboxStore.ownManifestURL` (Mac) duplicate `"inbox.\(slug).jsonl"`. Add a shared
  builder in MaughamCore (alongside the inbox types); both call it.
- **T1c — manifest filename literal.** `"project.maugham.json"` is a literal in
  `ProjectStore`, `ProjectFactory` (Mac ×2) and `ProjectsBrowser` (phone). Add
  `public static let manifestFilename` to `ProjectManifest`; all three reference it.
- **T1d — manifest date strategy.** `.iso8601` is hardcoded in the Mac encoder/decoder
  and the phone decoder. Add a shared `ProjectManifest.encoder`/`decoder` (or a static
  strategy) in MaughamCore; both surfaces use it.

### Tier 2 — contract the decision (drawing diverges); depth A unless noted
- **T2a — annotation kind → SF Symbol.** Differs (`suggestedChange`, `craftNote`). Add
  `AnnotationKind.systemImageName` in MaughamCore; both surfaces consume; contract test
  in both targets.
- **T2b — annotation kind → display label.** "Suggestion" (Mac) vs "Suggested change"
  (phone). Add `AnnotationKind.displayName`; both consume; contract test both targets.
- **T2c — section underline.** Mac underlines `.section`; phone doesn't. Extend
  `ScreenplayEmphasis` with an `underline: Bool`; `.section → underlined`; both renderers
  honor it (the existing `ScreenplayEmphasisContractTests` extends to cover it).
- **T2d — display-uppercase rule.** Phone uppercases `.sceneHeading`/`.transition`; the
  Mac uses the option-A as-typed fallback. Add `ScreenplayUppercase.shouldUppercase(...)`
  decision in MaughamCore; contract it (Mac may still defer execution, but the decision
  is shared). Contract test both targets.
- **T2e — title-page per-key styling (DEPTH B).** Mac styles each key (Title big/bold,
  Credit italic, …); phone renders all keys as flat callout. Extract a
  `TitlePageFieldStyle` value type + `style(forKey:)` factory in MaughamCore returning
  `(scale, bold, italic, align)`. Mac maps it to `NSFont`; phone to `.font()` modifiers.
  Contract test both targets. The single depth-B case.
- **T2f — missing Mac-side contract tests for already-correct write rules** (pin them so
  they can't drift): `Deriver.appliesToManuscript(.claudeAccept)==true` &
  `.claudeSuggestion==false`; Mac inbox monotonic `writtenAt` stamp; manifest date
  round-trip. Tests only, no production change.

### Intra-Mac cleanups (same drift smell; folded in per user)
- **M1 — Mac device id.** Four sites duplicate `ProcessInfo.processInfo.hostName` +
  `"unknown-host"` fallback (`EditorHost`, `InboxStore`, `ProjectStore`, `ProjectWindow`).
  Consolidate into one `MacDeviceID.current`.
- **M2 — ProjectFactory id minting.** `ProjectFactory` hand-rolls
  `"doc-\(UUID().uuidString.prefix(8).lowercased())"` instead of calling
  `ProjectStore.newId(prefix:)`. Route it through `newId`.

### Tier 3 — recorded, no enforcement
Bootstrap, Materializer, checkpoints, inbox last-wins merge + transition stamping
(Mac-only); InboxEntry fresh-creation (phone-only); section-level differentiation,
markdown heading-scale hierarchy, markdown inline-emphasis mechanism (agreed/where
mechanism legitimately differs); `.character`/`.pageBreak` (already nil-contracted in
`ScreenplayEmphasis`); `ProjectId` typealias; `__project__` constant; `.pending.jsonl`.

## Tripwire allowlist (finalized)
- Phone (`TripwirePhoneGrepTest`): after T1a/T1b, the sanctioned filename *builders* that
  legitimately interpolate `.jsonl` are gone from surface code (they call shared builders),
  so the forbidden-construction pattern needs no phone allowlist entry. Re-verify after T1a/T1b.
- Mac (`TripwireGrepTests`): `MaughamSidecarPath.swift` retained as the sole sanctioned
  owner; OpLogStore lives in MaughamCore (not scanned).
