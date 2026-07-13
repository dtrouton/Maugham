# `MaughamPhone/` — the iOS companion app

Read this before editing anything under `MaughamPhone/`. The iOS app (Phases D0–F
of `docs/superpowers/plans/2026-05-24-iphone-companion-v1.md`, merged `3fff8b5`)
is a four-tab SwiftUI app — **Capture / Read / Annotations / Settings** — that
reads/writes a security-scoped-bookmarked iCloud-Drive projects folder. It shares
`Packages/MaughamCore` with the Mac; **AppKit-bound code never reaches here.**

## Build & test

```
./gen.sh                                                                       # after project.yml / asset-catalog changes
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

- Tests `@testable import MaughamPhone` + `import MaughamCore`. `MaughamPhoneTests`
  hosts into the app target (like `MaughamTests` into Maugham).
- **Transient simulator "Busy / failed preflight checks" on a test run is a flake**
  — just re-run the command. Do **NOT** `simctl shutdown all` right before a launch;
  that *causes* the Busy state.
- Dev/stable variants: `com.Maugham.MaughamPhone[.dev]` (capital "M" — matches the
  registered App ID; diverges from the Mac's `com.maugham.Maugham` on purpose, see
  CLAUDE.md → phone bundle-id note); iOS knobs live on
  `BuildVariantPhone.swift` (the one sanctioned home for the bundle-id literals —
  tripwire 13; `TripwirePhoneGrepTest` enforces zero `"maugham"`/`"Maugham"`
  literals elsewhere). **WhisperKit is a Mac-target-only dep — never add it here.**

## Layout

- **`Storage/`** — the substrate. `DownloadCoordinator` (actor: per-URL state +
  dedup + 50 MB cold-launch budget + `observe` AsyncStream), `CoordinatedFileIO`
  (`UbiquitousDownloader` conformer: download/poll + NSFileCoordinator read/write/
  appendLine) over the `UbiquitousFileSystem` seam, `ProjectsRoot` (bookmark
  lifecycle), `ProjectsBrowser` (id→manifest), `RecentsTracker`, `PhoneDeviceID`,
  `ColdLaunchDownloader`.
- **`Capture/`** — `InboxCaptureWriter` (text/photo/voice → `.maugham/inbox/`) +
  the capture UI + project pill/picker + `PaletteAimPicker` (optional palette
  aim row, see below).
- **`Read/`** — `DocumentReaderView` (download-gated), `MarkdownBlocks` (block split
  so paragraphs/headings survive), `FountainStyler`/`FountainSemanticRenderer`,
  `BinderRouting`, `PaletteCardView`/`PaletteLoading` (read-only palette section,
  see below), `PhoneImageLoader` (eviction-safe image seam). (The anchor-strip
  itself is shared: `MarkdownDisplayFilter` in MaughamCore.)
  Read tab displays the on-disk clean `.md` — a contracted Tier-2 divergence from
  ADR 0018 (registry row: cross-surface-contracts.md); annotations derive from the
  op log, so the two can briefly disagree while iCloud syncs. This is designed
  behavior.
- **`Annotations/`** — a project → chapter → notes **drill-down** (phone-v0.2.0):
  `AnnotationsStore` (`@Observable` load + grouped tree, the one source of truth) →
  `AnnotationsListView` (Projects root + Open/All toggle + single-doc skip) →
  `ProjectChaptersView` (chapters, binder-order, group-header sections) →
  `ChapterAnnotationsView` (a chapter's OPEN + dimmed RESOLVED notes) →
  `AnnotationDetailView`. Pure/testable core in `AnnotationLoading`
  (`groupByChapter`/`allAnnotations`/`AnnotationsMode`+visibility filters, all
  table-tested), `AnnotationStatusChip`, and `ResolvedEntryDecision` (the
  race-vs-review decision — see tripwire below). `AnnotationWriter` (lifecycle
  ops) + `AnnotationsBanner` unchanged. **`store.projects` holds ALL statuses**
  (mode-filtering is a pure view-layer step); the leaf/middle **re-slice from the
  store by id** so mid-stack counts stay fresh after a resolve.
  **Resolved-note review is read-only:** `AnnotationDetailView` gates on the
  note's status *at open time* (`openedResolved`) — an already-resolved note shows
  its recorded outcome and calls neither the Race-2 collapse nor `onResolved()`;
  only a note that was OPEN at load and became resolved triggers the cross-device
  race guard (`ResolvedEntryDecision`, spec §5.3). Don't collapse those two cases
  back together. Reopen / Reopen & Revert shipped phone-v0.5.0 (ADR 0023, schema
  v3): rejected/archived → `annotationReopen`; accepted → full `claudeAcceptRevert`
  with drift-confirm.
- **`Auth/`** — `LaunchAuthGate` (opt-in Face ID).
- `MaughamPhoneApp.swift` owns the shared stores (`ProjectsRoot`/`RecentsTracker`/
  one `DownloadCoordinator`/`ProjectsBrowser`/`LaunchAuthGate`) and runs the §3.13
  cold-launch sequence. All four tabs get the SAME instances.

## The testability pattern (why everything has a seam)

UI / OS primitives can't run in a unit test, so the logic sits behind injected
seams and the views are build-verified:

- **Two download seams, two layers:** `DownloadCoordinator` is tested against a fake
  `UbiquitousDownloader`; `CoordinatedFileIO`'s poll loop against a fake
  `UbiquitousFileSystem`. Neither test touches real iCloud.
- **`@Observable` + injected deps, NOT `@AppStorage`** — `@AppStorage` is a SwiftUI
  `DynamicProperty` whose change-tracking only fires in a `View` and can't be
  retargeted to a test `UserDefaults` suite. `RecentsTracker` / `ProjectsRoot` /
  `LaunchAuthGate` are plain `@Observable` classes with an injected `UserDefaults`
  (+ a `now: () -> Date` clock where time matters, + a `BookmarkResolving` /
  `BiometricEvaluating` seam). Copy this shape for any new store.

## Palette: capture aim + read (2026-07-11)

The phone can now feed and read the Mac's sensory-palette wall (`docs/superpowers/specs/2026-07-10-palette-phone-and-role-identity-design.md`), built entirely on the already-decoded manifest plus one new eviction-safe image seam — no new download infrastructure.

- **Capture aim row (`Capture/PaletteAimPicker.swift`).** An optional target on any capture: a palette subject (an existing card's title, or free text naming a new one) plus an optional sense chip (`sight`/`sound`/`smell`/`touch`/`taste`, plain strings — the phone carries them raw, the Mac maps to `PaletteCard.Sense` at promote time). **Aiming is never required** — the default is exactly today's plain inbox capture. `PaletteAimPicker.cardTitles(in:)` reads card titles straight off `manifest.research` via `PaletteLookup.paletteGroup` — **no file I/O**, since titles are already in the decoded tree. The aim threads through `InboxCaptureWriter` into `InboxEntry.paletteSubject`/`sense`.
- **Read-tab Palette section (`Read/PaletteCardView.swift`, `Read/PaletteLoading.swift`).** `BinderView` gains a `Section("Palette")` (only shown when non-empty) listing the palette group's cards plus a project-scope Craft Intent row (per-piece intent display is deferred — the drill's per-piece context isn't uniform across project types yet). `PaletteLoading` is the pure logic half: `paletteCards(in:)` mirrors the Mac's `ProjectStore.paletteCardItems()`; `excludingPalette(_:research:)` strips palette-group descendants and the craft-intent asset out of the ordinary Research section so they don't show twice (the bug this task fixed — palette cards used to flatten into Research); `groupedNotes(_:)` is the phone-local twin of the Mac's `PalettePane.groupedNotes` — same grouping rule (one bucket per `PaletteCard.Sense.allCases` member, non-empty only, untagged last), reimplemented rather than shared because the logic sits in each platform's app target (`Maugham`/`MaughamPhone`), not MaughamCore, and those two targets never compile into the same test binary (macOS+AppKit vs iOS Simulator destinations) — tripwire 19 discipline: shared shape, separately-owned code. **Correction (2026-07-13): this is not actually parity-tested.** What exists is `PalettePaneTests.test_groupedNotes_ordersTaggedBySenseThenUntagged` (MaughamTests) and `PaletteLoadingTests.test_groupedNotes_*` (MaughamPhoneTests), each hand-typing its own input/expected-output pairs and asserting independently — both surfaces are tested against the same *intended* ordering, but no test proves the two implementations agree, so a drift in one side's rule would not fail the other side's suite. A genuine parity test would need `groupedNotes` promoted into MaughamCore as a real Tier-1 choke-point (a `PaletteLookup`-shaped fix, not a test-only one) — that's a production-code change, filed as a known gap rather than done here. Card detail renders swatches, sense-grouped notes, freeform body, and images. Row icons stay generic (`ReadIcons.paletteRowSymbol`) because a card's `kind` lives inside the file, not the manifest — a per-row kind icon would force a per-row parse (tripwire 4); kind-specific icons only appear in card detail, where the file is already parsed.
- **`PhoneImageLoader` (`Read/PhoneImageLoader.swift`).** The phone's first image-rendering path — the Read tab rendered zero images before this. `PhoneImageLoader.load(_:downloads:io:)` is `downloads.ensureDownloaded(url)` then `io.coordinatedRead(at:)` then `UIImage(data:)`: the same two-step iOS tripwire-6 sequence every phone read follows, just with a decode step on the end. Eviction-tolerant by contract — a thrown error or nil image means the caller shows a placeholder, never an error screen, because a card's text must render even when an image can't.
- **Strictly read-only.** No card editing on the phone: cards are plain files, not op-logged, and concurrent phone/Mac writes through iCloud would be conflict-twin territory (tripwire 17's cousin). Phone card editing is a future op-logging bet.

## iOS tripwires / gotchas (most from the 2026-05-30 smoke; each broke something)

1. **The download gate must treat already-local + non-ubiquitous files as ready —
   only an evicted placeholder (`.notDownloaded`) fetches.** `CoordinatedFileIO`'s
   `isLocallyReady`: `.current`/`.downloaded`, or a nil-status file that *exists*,
   is readable now. Assuming every file is an evicted iCloud placeholder made
   `startDownloadingUbiquitousItem` throw on local files and broke browsing entirely.
2. **`startAccessingSecurityScopedResource() == false` is NOT a denial.** It means
   "no security scope needed" (already-accessible URL, e.g. the app's own container).
   `ProjectsRoot` adopts the folder regardless; only a thrown resolve / stale bookmark
   re-prompts.
3. **Op-log filenames: the `docId` already carries its own prefix — `doc-<hex>` /
   `scene-<hex>` (ADR 0008), NOT `d_<ULID>`.** Write `<docId>.<deviceSlug>.jsonl`
   and never prepend another prefix; the docId is just the filename component
   before the first `.` (it contains no dot), and the only non-doc stream in
   `.maugham/ops/` is the synthetic `__project__` (tasks/checkpoints, no
   annotations). Match `OpLogStore.store(forDocId:deviceSlug:)` — which, like the
   Mac reader, never format-validates the id. **Do not invent a stricter id
   predicate** (e.g. `hasPrefix("d_")` or a 26-char-ULID check): it matches zero
   real files and silently shows "No open annotations" / prefetches nothing. This
   bit both `AnnotationLoading.isDocId` and `ColdLaunchDownloader.liveEnumerateOpLogs`.
4. **`claudeAccept` on a `suggestedChange` must carry the FULL resulting paragraph
   as `next`** (`AnnotationWriter.makeAccept`), or the Mac's `Deriver` replay
   materializes nothing on next load. The op stores the BARE suggested text (so the
   review UI shows just the replacement); `makeAccept` produces the full paragraph
   via the shared `SuggestionSplice.apply` — splicing the bare text into
   `annotation.span` against the live `currentParagraph` (passed by the detail view)
   so a one-word span suggestion replaces one word, not the paragraph. A
   paragraph-level suggestion (no span) replaces the whole paragraph. SAME
   `SuggestionSplice` the Mac's `Document.acceptAnnotation` uses (cross-surface
   contract). Other kinds carry empty `changes`. A malformed suggestedChange
   **throws** (fail-loud) rather than emitting a no-op accept.
5. **No live cross-device updates in v1 (no `NSFilePresenter`).** Lists reflect
   remote (Mac) changes only on appear / pull-to-refresh / after a phone-side resolve
   / when a detail's re-derive discovers a remote resolution. Don't assume a list
   auto-updates for Mac writes; the detail's re-derive-on-appear is the guard that
   stops a phone clobbering a resolution another device made.
6. **Every read inside the bookmarked folder routes through `ensureDownloaded` then
   `coordinatedRead`** (iCloud eviction); every write is coordinated and only ever
   into `.maugham/inbox/*` or `.maugham/ops/*.jsonl`. The phone never writes a `.md`.
7. **Phone-written ops/inbox rows must be byte-compatible with the Mac reader** —
   encode with `JSONLAppendStore.dateEncoding`; inbox `writtenAt` is monotonic
   `max(now, createdAt+1ms)` (tripwire 17). Prove it by round-tripping through the
   Mac's `JSONLAppendStore`/`OpLogStore` in a test, not by eyeballing JSON.
8. Mac tripwires that recur on iOS: **4** (no per-row Fountain parse — cache the
   `FountainScript` in `.task`), **13** (no hardcoded identity strings), **15**
   (empty-state needs both `.frame(maxWidth:.infinity,maxHeight:.infinity[,alignment:.top])`).
- **Cross-surface contracts:** if you touch op-log/inbox filenames, ids, formats, or Fountain rendering, you may be in shared phone↔Mac territory — the reach-around tripwires will tell you. Registry: `docs/superpowers/notes/cross-surface-contracts.md`.

## Cross-surface contract

`MaughamPhone`'s `FountainStyler` and the Mac's `ScreenplayMode` are two independent
Fountain renderers; their bold/italic emphasis is pinned by `ScreenplayEmphasis`
(MaughamCore) + `ScreenplayEmphasisContractTests` in both targets. See CLAUDE.md →
Editor pointer.

## Releasing to TestFlight / App Store

See `docs/RELEASING.md` → "Phone releases" for the full pipeline. Key facts here for quick reference:

- Cut script: `scripts/cut-phone-release.sh` (mirrors Mac; `phone-v*` tags).
- **Dry run = integration test.** Five on-device bugs surfaced that were invisible to `xcodebuild test` and debug builds. Cut throwaway `phone-v0.0.x` tags to prove a fix on device.
- **Bundle id is `com.Maugham.MaughamPhone` — capital "M".** The App ID was registered with a capital M; Apple namespaces IDs case-insensitively so the lowercase form can't be re-registered without deleting the App ID. Codesign is case-sensitive, so `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` and `provisioningProfiles` in `ExportOptions.plist` MUST stay capital-M and in sync.
- App icon: editable SVG sources + `render.sh` in `scripts/phone-icon/`.
- Phase-G forensics: `docs/superpowers/notes/2026-05-31-phone-testflight-status.md` + `memory/project_milestone_iphone_companion_phase_g.md`.

## The smoke lesson

Manual smoke on a running build found **six** real bugs a green unit suite hid
(gotchas 1–5 above + a Markdown wall-of-text). They all lived at cross-process /
iCloud / OS-primitive seams the unit tests mocked away. **For anything touching
iCloud, the op log, or a system primitive: test through the real I/O path on a
running build, not the in-memory shortcut.** See `[[feedback_smoke_finds_seam_bugs]]`.
