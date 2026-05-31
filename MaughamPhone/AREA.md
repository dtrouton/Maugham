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
  the capture UI + project pill/picker.
- **`Read/`** — `DocumentReaderView` (download-gated), `MarkdownBlocks` (block split
  so paragraphs/headings survive), `FountainStyler`/`FountainSemanticRenderer`,
  `BinderRouting`. (The anchor-strip itself is shared: `MarkdownDisplayFilter` in
  MaughamCore.)
- **`Annotations/`** — `AnnotationWriter` (lifecycle ops), `AnnotationsListView`
  (cross-project), `AnnotationDetailView`, pure `AnnotationLoading` + `AnnotationsBanner`.
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
3. **Op-log + inbox filenames: the `docId` already carries the `d_` prefix.** Write
   `<docId>.<deviceSlug>.jsonl` — NOT `d_<docId>...`. A double-prefix lands in a
   stream the Mac's `OpLogStore.load(docId:)` glob never reads, silently dropping
   every phone write. Match `OpLogStore.store(forDocId:deviceSlug:)`.
4. **`claudeAccept` on a `suggestedChange` must copy the creation op's `changes`
   array verbatim** (`AnnotationWriter.makeAccept`), or the Mac's `Deriver` replay
   materializes nothing on next load. Other kinds carry empty `changes`. A malformed
   suggestedChange **throws** (fail-loud) rather than emitting a no-op accept.
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

## Cross-surface contract

`MaughamPhone`'s `FountainStyler` and the Mac's `ScreenplayMode` are two independent
Fountain renderers; their bold/italic emphasis is pinned by `ScreenplayEmphasis`
(MaughamCore) + `ScreenplayEmphasisContractTests` in both targets. See CLAUDE.md →
Editor pointer.

## The smoke lesson

Manual smoke on a running build found **six** real bugs a green unit suite hid
(gotchas 1–5 above + a Markdown wall-of-text). They all lived at cross-process /
iCloud / OS-primitive seams the unit tests mocked away. **For anything touching
iCloud, the op log, or a system primitive: test through the real I/O path on a
running build, not the in-memory shortcut.** See `[[feedback_smoke_finds_seam_bugs]]`.
