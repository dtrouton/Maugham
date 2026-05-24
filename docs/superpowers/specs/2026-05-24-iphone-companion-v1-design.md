# iPhone Companion — Capture, Read, Annotation Review

**Status:** Approved 2026-05-24 by user, ready for implementation planning.

**Goal:** Ship a Maugham iPhone companion app that complements (not replaces) the Mac. Three capabilities in one bundle: (1) **Capture inbox** — text, photo, and voice notes land in a new `.maugham/inbox/` sidecar synced via iCloud Drive; voice captures get an immediate on-device `SFSpeechRecognizer` draft transcript that the Mac later replaces with a higher-quality WhisperKit transcript. (2) **Read** — projects/binders/manuscripts/research browsable from the phone; Markdown rendered native, Fountain rendered semantically (line-type-aware styling, not pagination). (3) **Annotation review** — Claude's open annotations (`comment`/`query`/`suggestedChange`/`craftNote`) listed across all bookmarked projects; Accept / Reject / Archive append the exact same op-log entries the Mac writes. Distribution is TestFlight (personal/friends), not App Store; signing + a separate `phone-v0.X.Y` tag namespace + GH Actions release pipeline come with it.

**Why now:** Maugham's value proposition is "serious writing, undistracted, with Claude alongside." Two recurring gaps appear in actual use. First, capture: ideas, photo references, and dictated lines happen away from the desk and are routinely lost between "had it on the train" and "back at the Mac." Second, annotation triage: Claude leaves dozens of open annotations across a manuscript; reviewing them is currently a desk-only activity, which means they back up and lose context. A phone surface for both is a force-multiplier on the existing Mac flow rather than a second product to maintain — the op log, the iCloud-Drive sync substrate, and the annotation layer are already shaped for cross-device, cross-process participation.

**Working title:** `milestone-phone-v1`. Sub-milestones (`milestone-maugham-core`, `milestone-inbox-and-whisper`, `milestone-phone-v1`, `phone-v0.1.0`) cut between phases.

**Conformance contract.** Must not regress any test currently green. No editor binding contract changes; no op-log schema changes (only additions inside existing `OpKind` cases); no manuscript-load entry-point changes (Bootstrap stays the single anchor-minting funnel); no MCP tool surface changes. Phone never writes to manuscript `.md` files — the "manuscript is the writer's" invariant holds. The existing Mac app stays fully usable without the phone; phone is purely additive. Echo guard semantics (`Document.lastDiskEcho: EchoState`) untouched — phone writes target `.maugham/inbox/*` and `.maugham/ops/*.jsonl`, never `.md`, so they can never masquerade as Mac-side echoes.

---

## 1. Problems addressed

Five distinct problems, bundled because they share infrastructure (iCloud-Drive sync, op log, sidecar conventions).

### P1. Capture-away-from-desk has no home

Ideas, dictated lines, photo references (whiteboards, book pages, scene locations), and overheard fragments happen between writing sessions. Today they end up in iOS Notes / Voice Memos / Photos with no path back into the project they belong to, and the round-trip through "remember to copy that note over later" loses most of them.

### P2. Annotation triage is desk-locked

Claude routinely leaves dozens of open `comment` / `query` / `suggestedChange` / `craftNote` annotations on a manuscript. Reviewing them requires opening the Mac, opening the project, opening the AnnotationsPane, and working through them in front of the manuscript — high friction. They back up; older annotations lose context; the writer reaches the end of a session with the same pile they started with.

### P3. The manuscript is not portable for *reading*

The writer wants to re-read a scene on the bus, check a research note before a meeting, scan a screenplay's flow on a phone. The `.md` and `.fountain` files sync via iCloud Drive but iOS's built-in editors render them poorly (paragraph anchors visible as raw text; Fountain shown as unformatted markup).

### P4. Voice capture has a quality vs. immediacy tradeoff

A useful voice note needs a transcript fast enough that the writer can confirm it captured what they meant ("did it hear me?"), but the writer also wants a transcript good enough to act on later. Phone-only on-device transcription is fast but coarse; cloud APIs (OpenAI Whisper API, Deepgram, etc.) are higher quality but introduce a third-party network call, API keys, and a privacy posture the project hasn't taken. WhisperKit running on the Mac is the quality-equivalent option without the network/keys, but it can't run on the phone (model size, Apple-Silicon-only).

### P5. No iOS distribution path exists

The Mac release pipeline (`.github/workflows/release.yml`, `cut-release.sh`, `docs/release-notes/`) is established but iOS-shaped releases differ enough — TestFlight not `.dmg`, signing required not optional, monotonic build numbers, separate tag namespace — that they need their own pipeline, not a flag on the existing one.

---

## 2. Architecture overview

Three coordinated changes, deliberately ordered so each is independently verifiable: a foundation extraction (P3/P2 require shared parser + op-log types), a Mac-side surface (P1 inbox triage + WhisperKit re-transcription), and an iOS app (all five Ps for the phone surface). Plus a parallel CI/release pipeline.

The dependency direction is clear: `Packages/MaughamCore` is foundational and underlies everything else; the Mac inbox depends only on MaughamCore; the iOS app depends on MaughamCore and the Mac inbox's on-disk format (sidecar JSONL schema, file layout). The CI pipeline depends on the iOS app target existing.

### 2.1 New files

**Shared (in new `Packages/MaughamCore/` Swift Package):**

- `Packages/MaughamCore/Package.swift` — SPM manifest. Platforms: `.macOS(.v14)`, `.iOS(.v17)`. Foundation-only product `MaughamCore`.
- `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift` — Codable struct: `id` (ULID), `createdAt` (ISO8601), `deviceId` (per-install UUID), `kind` (text/image/audio), `sourceFilename` (nil for inline text), `inlineText` (nil unless kind == text), `transcript` (nil until transcription state advances), `transcriptionState` (none / on_device_draft / whisper_final / failed), `title` (optional user-set), `status` (new / promoted / trashed), `resolvedAt`. snake_case CodingKeys to match the project's JSON convention.
- `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxFileKind.swift` — `enum InboxFileKind: String, Codable { case manifest, text, image, audio }`. Used by both the iOS writer and the Mac sidecar classifier.
- `Packages/MaughamCore/Sources/MaughamCore/OpReplay.swift` — pure function `static func buildState(ops: [Op]) -> (paragraphs: [ParagraphID: String], sequence: [ParagraphID])`. Existing Mac-side `Document.load` does this inline; lifting it lets the phone's annotation list view derive paragraph state without instantiating a full `Document`.

**Mac-only:**

- `Maugham/Stores/InboxStore.swift` — `@Observable` class owned by `DocumentStore`, one per project window. Loads `.maugham/inbox/inbox.jsonl` via `JSONLAppendStore<InboxEntry>` but with a last-wins merge in its own load pass (the generic store's `dedupKey` keeps first occurrence — InboxStore needs newest to win for status transitions). Methods: `refresh()`, `promoteToResearch(_:)`, `trash(_:)`, `attachToCurrentDoc(_:)`, `updateTranscript(id:text:state:)`. Each mutating method appends a new InboxEntry with the same id and updated fields; the next `refresh()` collapses them through the last-wins merge.
- `Maugham/Stores/InboxTranscriptionWorker.swift` — serial-queue background worker subscribed to `Notification.Name.maughamInboxChanged` events with `kind == .audio`. Pulls the entry by id, loads the corresponding `.m4a` from `.maugham/inbox/audio/`, runs WhisperKit, calls `InboxStore.updateTranscript(id:text:state: .whisperFinal)`. One transcription in flight at a time (WhisperKit is compute-heavy; competing jobs would thrash). Models live in `~/Library/Application Support/<BuildVariant.supportFolderName>/WhisperModels/`, downloaded lazily on first use.
- `Maugham/Views/InboxPane.swift` — right-pane mode mounted into `ProjectWindow`'s detail-pane host. Rows: kind icon (SF Symbol: `square.and.pencil` / `photo` / `mic`), title (user-set or first ~40 chars of text/transcript), subtitle (transcript preview + relative timestamp), trailing menu (Promote to research / Attach to current doc / Edit transcript / Trash). Empty state via `ContentUnavailableView("Nothing in the inbox", systemImage: "tray", description: "Capture from MaughamPhone — text, photo, or voice — appears here.")`.
- `.github/workflows/phone-release.yml` — tag-triggered macOS-runner workflow for the iOS app. Trigger pattern `phone-v[0-9]+.[0-9]+.[0-9]+`. Steps: checkout → setup Xcode → install xcodegen → import distribution cert + provisioning profile from secrets → sync version from tag + build number from `git rev-list --count HEAD` → `./gen.sh` → build Release for iOS → run phone tests → archive + export `.ipa` → upload to TestFlight via App Store Connect API → create GitHub Release with `docs/release-notes/phone/v0.X.Y.md` as body.
- `scripts/cut-phone-release.sh` — mirror of `cut-release.sh` for the phone. Verifies `docs/release-notes/phone/v0.X.Y.md` exists, tree is clean, phone test target passes, creates `phone-v0.X.Y` tag, prints push command. `--skip-tests` flag for emergencies.
- `docs/release-notes/phone/_template.md` — copy-source for each phone release.

**iOS-only (in new `MaughamPhone/` directory at repo root):**

- `MaughamPhone/MaughamPhoneApp.swift` — `@main` `App` struct. Root view is a four-tab `TabView` (Capture / Read / Annotations / Settings). Owns the `ProjectsRoot` singleton.
- `MaughamPhone/BuildVariantPhone.swift` — iOS-only extension on `BuildVariant` (the type itself lives in MaughamCore): `phoneBundleId`, `bookmarkUserDefaultsKey`. Keeps `BuildVariant` itself platform-agnostic while letting iOS specialize.
- `MaughamPhone/Storage/ProjectsRoot.swift` — manages the security-scoped bookmark for the iCloud Drive folder containing projects. On first launch (or stale bookmark), presents `UIDocumentPicker(forOpeningContentTypes: [.folder])`. On resolved URL, calls `startAccessingSecurityScopedResource()` and persists the bookmark bytes under `BuildVariant.current.bookmarkUserDefaultsKey`.
- `MaughamPhone/Storage/ProjectsBrowser.swift` — given the resolved root URL, lists immediate subdirectories that contain `project.maugham.json`; decodes each into `ProjectManifest` (from MaughamCore). Manifest reads route through `DownloadCoordinator` so a not-downloaded placeholder triggers a fetch instead of silently appearing as "no projects" (§3.13).
- `MaughamPhone/Storage/CoordinatedFileIO.swift` — thin wrapper around `NSFileCoordinator` for every read (anywhere in a project) and every write (only into `.maugham/inbox/*` and `.maugham/ops/*.jsonl`). Same primitive the Mac uses. Plus a `download(at:)` helper for iCloud Drive eviction handling — see §3.13.
- `MaughamPhone/Storage/DownloadCoordinator.swift` — actor that tracks per-URL download state (`notDownloaded` / `downloading(progress:)` / `downloaded` / `failed`), deduplicates concurrent requests for the same URL, and enforces the 50 MB cold-launch budget for proactive op-log downloads. See §3.13.
- `MaughamPhone/Storage/RecentsTracker.swift` — observable owner of two `@AppStorage` signals: `recentProjectIds` (last 5 captured-into, FIFO) and `lastOpenedDates` (`[ProjectId: Date]`). Derives `recents: Set<ProjectId>` as the union of the captures plus any project opened within the last 14 days. Drives the cold-launch proactive-download list. See §3.13.
- `MaughamPhone/Capture/CaptureView.swift` — root view for the Capture tab; three large action buttons (text / photo / voice) routed to dedicated sheet views.
- `MaughamPhone/Capture/TextCaptureSheet.swift` — `TextEditor` in a sheet, "Save to inbox" / "Cancel" buttons.
- `MaughamPhone/Capture/PhotoCaptureSheet.swift` — `PhotosPicker` (library) + camera capture; on commit writes the image to `inbox/images/<ulid>.<ext>` and appends an `InboxEntry`.
- `MaughamPhone/Capture/VoiceCaptureSheet.swift` — `AVAudioRecorder` to a tmp `.m4a`, simultaneously feeds the audio buffer to `SFSpeechRecognizer` for the on-device draft. On Stop, moves the `.m4a` to `inbox/audio/<ulid>.m4a` and appends an `InboxEntry` with `transcript: <draft>` and `transcriptionState: .onDeviceDraft`.
- `MaughamPhone/Read/ProjectsListView.swift` — list of bookmarked-folder projects.
- `MaughamPhone/Read/BinderView.swift` — renders `ProjectManifest.structure: [StructureItem]` as a hierarchical list (folders, manuscripts, research entries). Tap routes to the appropriate reader.
- `MaughamPhone/Read/DocumentReaderView.swift` — reads `.md` / `.fountain` directly. For `.md`: strips `<!-- ¶id -->` anchors, renders via `AttributedString(markdown:)`. For `.fountain`: parses to `FountainScript` once in `.task`, hands off to `FountainSemanticRenderer`.
- `MaughamPhone/Read/FountainSemanticRenderer.swift` — iterates the cached `FountainScript.lines: [FountainLine]`, styles each by `ScreenplayElement`: scene heading (bold + uppercased), action (plain), character (bold + center-aligned), parenthetical (italic + indented further), dialogue (indented), transition (right-aligned + uppercased), notes (dimmed or hidden by toggle).
- `MaughamPhone/Annotations/AnnotationsListView.swift` — walks every bookmarked project's `.maugham/ops/*.jsonl`, replays via `OpReplay.buildState`, derives annotations via `AnnotationDeriver.derive`. Filters to `.open`; groups by project; sorts by paragraph order within doc.
- `MaughamPhone/Annotations/AnnotationDetailView.swift` — shows paragraph context (`priorText` if suggestedChange, otherwise current paragraph text), body, three buttons (Accept / Reject… / Archive). Re-derives status on `.onAppear` to collapse cross-device race window: if `status != .open`, hides buttons and shows "Already resolved on another device."
- `MaughamPhone/Annotations/AnnotationWriter.swift` — builds and appends the lifecycle ops via `JSONLAppendStore<Op>` and coordinated writes. Exact op shape covered in §3.9.
- `MaughamPhone/Settings/SettingsView.swift` — Choose Projects Folder button, current bookmark status, permissions status (mic / speech recognition / camera / photo library), build variant indicator.
- `MaughamPhone/Info.plist` — `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`.
- `MaughamPhoneTests/` — test target mirroring `MaughamTests/` shape. Bookmark resolution tests, coordinated-write tests, annotation op-shape round-trip tests.

### 2.2 Modified files

- `project.yml` — new `MaughamPhone` and `MaughamPhoneTests` targets; iOS 17 deployment; per-configuration bundle ids (`com.maugham.MaughamPhone[.dev]`); per-configuration `MAUGHAM_DEV_BUILD` flag; both `Maugham` and `MaughamPhone` declare `MaughamCore` as a local package dependency. `CFBundleShortVersionString` placeholder `"0.0.0-dev"` and `CFBundleVersion` placeholder `"1"` for phone — CI rewrites both at build time.
- `Maugham/Stores/MaughamSidecarPath.swift` — add `case inbox(kind: InboxFileKind, relativePath: String)`; extend `classifySidecar(url:projectURL:)` with branches for `.maugham/inbox/inbox.jsonl` → `.inbox(.manifest, …)`, `.maugham/inbox/text/*` → `.inbox(.text, …)`, `.maugham/inbox/images/*` → `.inbox(.image, …)`, `.maugham/inbox/audio/*` → `.inbox(.audio, …)`.
- `Maugham/Stores/DocumentStore.swift` — add a `case .inbox(let kind, _):` arm in `presenterDidChangeSubitem` (currently around line 477); posts `Notification.Name.maughamInboxChanged` with `kind` in userInfo. `InboxStore` and `InboxTranscriptionWorker` both subscribe.
- `Maugham/Views/DetailSegment.swift` — add `case inbox`; mirror in `Maugham/Views/DetailPaneToggle.swift` so the segment picker shows it.
- `Maugham/Views/ProjectWindow.swift` — bind ⌘⌥6 to `.inbox` (the existing slot mapping: 1 inspector, 2 annotations, 3 outline, 4 history, 5 research, 6 inbox). Mount `InboxPane()` in the detail-pane host when `currentSegment == .inbox`.
- `Maugham/OpLog/OpLogStore.swift` — `load(docId:)` globs all per-device op-log files (`d_<docId>.jsonl` + `d_<docId>.<deviceSlug>.jsonl`), merges via `JSONLAppendStore`'s existing opId-dedupe + opId-sort. `append(_:)` targets the writer's own per-device file. See §3.12 for the multi-writer partitioning rationale; the change is the only place that needs to know files are partitioned — every downstream consumer (`Deriver`, `Document.load`, `RewindWindow`) still sees a single `[Op]`.
- `Maugham/Stores/ProjectFolderPresenter.swift` — confirm directory-level subscription to `.maugham/ops/`. New per-device files appear at runtime; the presenter must fire `presenterDidChangeSubitem` for siblings it has never seen before. If today's implementation watches a fixed set of paths, broaden to directory-level. (Likely already directory-level; needs verification at Phase B0.)
- `CLAUDE.md` — new "iPhone companion" section between "Releases" and "Architectural tripwires"; three additions to "Questions you do not need to ask"; two new tripwires (#14 and #15, see §6). Per-area pointer for `MaughamPhone/`.
- Files moved (not deleted-and-recreated) into `Packages/MaughamCore/Sources/MaughamCore/`:
  - From `Maugham/OpLog/`: `Op.swift`, `OpKind.swift`, `Annotation.swift`, `AnnotationDeriver.swift`, `Bootstrap.swift`, `JSONLAppendStore.swift`, `Materializer.swift`, `OpLogStore.swift`, `ParagraphID.swift`, `ParagraphParser.swift`, `Reconciler.swift`, `ShingleMatcher.swift`, `SweepReason.swift`, `SynthesisSource.swift`, `ULID.swift`, `Checkpoint.swift`, `CheckpointStore.swift`. All confirmed Foundation-only.
  - From `Maugham/Editor/Fountain/`: `FountainTokenizer.swift`, `FountainLine.swift`, `FountainScript.swift`, `ScreenplayElement.swift`. All confirmed `import Foundation` only.
  - From `Maugham/`: `BuildVariant.swift`. Used by both targets; iOS-only knobs added via `BuildVariantPhone.swift` extension on the iOS side.
  - From `Maugham/Models/`: `ProjectManifest.swift`, `ResearchItem.swift`, `ProjectType.swift`, `PieceKind.swift`, `StructureItem.swift`, `Slugifier.swift`, `FileNaming.swift`. All Foundation-only.

### 2.3 Files explicitly not changed (non-scope)

- `Maugham/OpLog/Document.swift` — unchanged. The replay path already handles `claudeAccept.changes` (see §3.9). No changes to Bootstrap funnel, no changes to autosave debouncing, no changes to echo guard.
- `Maugham/OpLog/Deriver.swift` — unchanged. `Deriver.appliesToManuscript` already includes `.claudeAccept` (verified at `Deriver.swift:108-117`); `Deriver.derive(ops:)` already applies `change.next` for any op whose kind passes that gate. The phone-written accept op materializes on Mac restart with zero Mac code change.
- `Maugham/OpLog/Reconciler.swift` — phone writes append to per-device op-log files; existing external-edit ingestion picks them up as it would any other external append. No classifier changes.
- `Maugham/Editor/` — no editor changes. The phone does not edit manuscripts.
- Op log schema — no new `OpKind` cases. Phone writes `claudeAccept` / `claudeReject` / `claudeArchive` with the existing shape. `Provenance.synthesisSource` gets no new cases; phone-originated ops carry no synthesisSource (it's optional; phone ops are not synthesized, they're user-driven).
- MCP tool surface — no new MCP tools. Phone reads ops via direct JSONL read, writes ops via direct JSONL append. MCP and the iPhone companion are parallel surfaces, not nested.
- Existing iCloud handling — the Mac app has no iCloud entitlement today and won't get one. Project folders live at writer-chosen paths; iCloud Drive happens to sync them if they're inside it. iOS uses `UIDocumentPicker` for the same arbitrary-path access, no shared container.

---

## 3. Detailed design

### 3.1 The MaughamCore extraction

Most of the foundational Swift in `Maugham/OpLog/`, `Maugham/Editor/Fountain/`, and `Maugham/Models/` is already Foundation-only — grep across those directories shows no `import AppKit` / `import SwiftUI` / `import UIKit`. Moving them into a Swift Package is purely structural. The cut is along the AppKit boundary:

- **In MaughamCore:** types and pure-logic operations on those types. Op, OpKind, ULID, Bootstrap (paragraph-anchor minting on raw strings), Reconciler classifier, AnnotationDeriver, Materializer, ParagraphID, the Fountain tokenizer + line model.
- **Stays in `Maugham/`:** `Document.swift` (uses NSTextStorage + AppKit), `ScreenplayMode.swift` (NSTextStorage typography attributes), `ScreenplayLayoutManager.swift` (NSLayoutManager subclass), all of `Maugham/Editor/EditorCoordinator.swift` and friends (NSTextViewDelegate), all of `Maugham/Views/` (SwiftUI but AppKit-flavored).
- **Stays in `Maugham/` for now but could move later:** `Maugham/Editor/Fountain/ScreenplayCycle.swift` and `ScreenplayLineMutator.swift` — these manipulate NSAttributedString/NSTextStorage, so they're not iOS-portable. The renderer the iOS app needs uses only `FountainTokenizer` + `FountainLine` + `FountainScript`, which are pure.

**`Package.swift` shape:**

```swift
let package = Package(
    name: "MaughamCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "MaughamCore", targets: ["MaughamCore"])],
    targets: [
        .target(name: "MaughamCore"),
        .testTarget(name: "MaughamCoreTests", dependencies: ["MaughamCore"]),
    ]
)
```

**`project.yml` integration:**

```yaml
packages:
  MaughamCore:
    path: Packages/MaughamCore
targets:
  Maugham:
    dependencies:
      - package: MaughamCore
  MaughamPhone:
    dependencies:
      - package: MaughamCore
```

**Risk and mitigation.** The move itself is mechanical (`git mv`); the risk is import breakage across `Maugham/` — files that referenced `Op` or `JSONLAppendStore` now need `import MaughamCore`. Plan: do the extraction as one focused PR with no behavior change. Run `./gen.sh` + `xcodebuild test` after every batch of 4–5 files; commit at each green point so a regression can be bisected to a small set. The test suite (currently green at ~814 tests) is the gate: zero new failures, no skipped tests.

Tests in `MaughamTests/` that reference the moved types stay where they are — they `@testable import Maugham`, which transitively re-exports MaughamCore. A small number of tests purely about Op/AnnotationDeriver/etc. may make sense to move into `Packages/MaughamCore/Tests/MaughamCoreTests/` for cleaner ownership, but that's a follow-up, not part of this milestone.

### 3.2 Inbox sidecar format

A new directory `<projectRoot>/.maugham/inbox/` with three kind-scoped subdirs (`text/`, `images/`, `audio/`) and **one manifest stream per writer** (`inbox.<deviceSlug>.jsonl`). All four locations are owned by `InboxStore` on the Mac and `MaughamPhone`'s capture flow on the phone; no other code touches them.

**Per-writer file partitioning.** Each device writes to its own manifest file (`inbox.<deviceSlug>.jsonl`); on load, `InboxStore` globs all `inbox.*.jsonl` siblings (plus legacy `inbox.jsonl` if present) and merges. This is the inbox flavour of the op-log partitioning approach detailed in §3.12 — the rationale (iCloud Drive cannot reconcile multi-writer JSONL safely) is the same. Each device's manifest has exactly one writer, so iCloud never has to reconcile divergent versions of the same file and conflict-twins are impossible by construction.

**Why a separate manifest stream rather than per-file sidecars:** the manifest is append-only JSONL like the op log, so loading and merging are uniform across stores. Each status transition (e.g., new → promoted) appends a new `InboxEntry` row with the same `id` and updated fields; the load pass collapses through a **last-wins merge keyed by id** (newest wins for the same `id` across all merged files). This means a phone "create" and a Mac "promote" written within seconds of each other both survive — newest wins per `id`, but neither file's writes are silently lost.

**Filenames** use ULID-prefixed names so they sort chronologically and never collide across devices: `01HQR8YN…J9.m4a`. The InboxEntry's `sourceFilename` field carries the exact filename so the Mac can locate the asset deterministically.

**InboxEntry schema** (`.swift` shown in `InboxEntry.swift`, JSON shape here for clarity):

```json
{"id":"01HQR8YN3T6JYWBQ5VWZG2H8J9","created_at":"2026-05-24T14:32:01.123Z",
 "device_id":"D2A1F8B0-1234-5678-9ABC-DEF012345678","kind":"audio",
 "source_filename":"01HQR8YN3T6JYWBQ5VWZG2H8J9.m4a","inline_text":null,
 "transcript":"on the train tomorrow rewrite the opening","transcription_state":"on_device_draft",
 "title":null,"status":"new","resolved_at":null}
```

After Mac-side WhisperKit completes:

```json
{"id":"01HQR8YN3T6JYWBQ5VWZG2H8J9","created_at":"2026-05-24T14:32:01.123Z",
 "device_id":"D2A1F8B0-…","kind":"audio","source_filename":"01HQR…J9.m4a",
 "inline_text":null,"transcript":"On the train tomorrow, rewrite the opening.",
 "transcription_state":"whisper_final","title":null,"status":"new","resolved_at":null}
```

After Mac-side "Promote to research":

```json
{"id":"01HQR8YN3T6JYWBQ5VWZG2H8J9","created_at":"2026-05-24T14:32:01.123Z",
 "device_id":"D2A1F8B0-…","kind":"audio","source_filename":"01HQR…J9.m4a",
 "inline_text":null,"transcript":"On the train tomorrow, rewrite the opening.",
 "transcription_state":"whisper_final","title":null,"status":"promoted",
 "resolved_at":"2026-05-24T18:11:42.000Z"}
```

The audio file itself moves from `.maugham/inbox/audio/01HQR…J9.m4a` into `research/<promoted-title>.m4a` as part of promotion (via the existing `ProjectStore.addResearchAsset` flow). The inbox manifest row is updated to `status: "promoted"`. Both writes are coordinated.

### 3.3 Mac-side inbox plumbing

**`MaughamSidecarPath` extension.** The enum currently has 11 cases routed by a single `classifySidecar(url:projectURL:)` method. Adding `case inbox(kind: InboxFileKind, relativePath: String)` is a one-case addition; the classifier branches on `.maugham/inbox/` prefix and the second path component to determine kind. Per CLAUDE.md and ADR 0010, this enum is the canonical owner-classification for `.maugham/` subdirs — getting routing right here is what makes the rest of the pipeline ride for free.

**`DocumentStore.presenterDidChangeSubitem`.** The existing switch (currently around line 477) gains:

```swift
case .inbox(let kind, _):
    NotificationCenter.default.post(
        name: .maughamInboxChanged,
        object: self,
        userInfo: ["kind": kind])
```

`InboxStore` subscribes for all kinds (triggers `refresh()`); `InboxTranscriptionWorker` subscribes filtered to `kind == .audio`. The `object: self` carrier lets multiple project windows coexist without crosstalk.

**`InboxStore` shape (with per-device partitioning — see §3.12):**

```swift
@MainActor @Observable
final class InboxStore {
    var entries: [InboxEntry] = []
    private(set) var version: Int = 0
    private let inboxDir: URL
    private let deviceSlug: String  // this Mac's own slug; writes go here

    init(projectRoot: URL, deviceSlug: String) {
        self.inboxDir = projectRoot.appending(path: ".maugham/inbox")
        self.deviceSlug = deviceSlug
    }

    private var ownStore: JSONLAppendStore<InboxEntry> {
        JSONLAppendStore<InboxEntry>(
            fileURL: inboxDir.appending(path: "inbox.\(deviceSlug).jsonl"),
            dedupKey: \.id)
    }

    func refresh() async {
        // Glob all per-device manifests + the legacy unsuffixed file.
        let urls = (try? FileManager.default.contentsOfDirectory(at: inboxDir,
                       includingPropertiesForKeys: nil)) ?? []
        let manifestURLs = urls.filter {
            let n = $0.lastPathComponent
            return n == "inbox.jsonl" || (n.hasPrefix("inbox.") && n.hasSuffix(".jsonl"))
        }
        var raw: [InboxEntry] = []
        for url in manifestURLs {
            let store = JSONLAppendStore<InboxEntry>(fileURL: url, dedupKey: \.id)
            raw.append(contentsOf: (try? await store.load()) ?? [])
        }
        // Last-wins merge across all sources: walk in opId order, keep newest per id.
        // Because InboxEntry.id is a ULID and each transition appends a new row
        // with the same id, sorting by createdAt then taking the last writer
        // per id collapses correctly across files.
        raw.sort { $0.createdAt < $1.createdAt }
        var byId: [String: InboxEntry] = [:]
        for e in raw { byId[e.id] = e }
        entries = byId.values
            .filter { $0.status == "new" }  // promoted/trashed don't show in pane
            .sorted { $0.createdAt > $1.createdAt }
        version &+= 1
    }

    // All mutations target ownStore (this device's own file).
    // … promoteToResearch / trash / attachToCurrentDoc / updateTranscript
}
```

Two layered merge semantics are in play:

1. **Within a single file:** `JSONLAppendStore.dedupKey: \.id` keeps the **first** occurrence (the generic store's behavior, correct for the op log where ops are immutable).
2. **Across the union of files:** InboxStore overrides to **last** wins per id (newest createdAt across all merged sources). This is what makes status transitions work — a phone-written `new` entry plus a Mac-written `promoted` row for the same id end up with `promoted` winning.

Keeping the generic store's per-file behavior intact and overriding the cross-file merge in InboxStore is cheaper than parameterizing `JSONLAppendStore`.

### 3.4 Mac-side triage UI

The right-pane mode pattern is established (ADR 0005): the detail pane swaps content based on `currentSegment: DetailSegment`. Existing segments: `.inspector` (⌘⌥1), `.annotations` (⌘⌥2), `.outline` (⌘⌥3), `.history` (⌘⌥4), `.research` (⌘⌥5). New: `.inbox` (⌘⌥6).

**Segment unread badge.** The `.inbox` segment in `DetailPaneToggle` shows a numeric badge with `InboxStore.entries.count` (entries with `status == .new`). The badge is the discoverability signal for "captures came in while you were writing" — without it, ⌘⌥6 is buried six slots deep and the writer would never know to look. Badge cap at "99+" if count exceeds 99 (avoids layout reflow). Disappears at count 0.

This also addresses the broader carry-forward from `milestone-ui-polish-followups`: the three right-pane modes with different write semantics (Annotations action surface, History read-only forensic log, Inbox triage) gain segment-level tooltips so the writer can tell them apart from the picker. See §6 for the tooltip copy.

**Row layout.** Each row shows:

- Leading SF Symbol per kind: `square.and.pencil` (text), `photo` (image), `mic` (audio).
- Two-line title block: title (or first ~40 chars of inlineText/transcript) and dimmed subtitle (transcript preview if not in title + relative timestamp).
- **For audio entries:** an inline play/pause button between the icon and the title block. Tapping plays the `.m4a` via `AVAudioPlayer` with a slim progress bar replacing the subtitle during playback (transcript preview returns on stop/pause). Spacebar plays/pauses the focused row (matches Finder's Quick Look muscle memory). Only one row plays at a time — starting playback on a new row stops the previous. The writer can verify the transcript against the audio without leaving InboxPane.
- Trailing context menu: Promote to research…, Attach to current document, Edit transcript…, Trash. (Edit transcript is for the writer to correct on-device drafts that Whisper hasn't replaced yet.)

**Action wiring.**

- **Promote to research** → delegates to existing `ProjectStore.addResearchAsset(parentId: nil, fromURL: inboxAssetURL)`, then `InboxStore.updateStatus(id:to: .promoted)`, then a coordinated `FileManager.removeItem` on the original inbox path. (The existing addResearch flow copies, not moves; the explicit removeItem completes the move semantically.)
- **Attach to current document** for images: routes through existing `ImagePasteHandler` (the same code path that handles drag-and-drop images into the editor). For text: insert at cursor via the normal editor-typing path — explicitly *not* through `EditorSurface.applyExternalText`, which tripwire 7 reserves for cloud-conflict resolution only. For audio: no inline-audio in manuscripts; the menu item is hidden for audio entries.
- **Edit transcript** → modal sheet with the transcript text in a TextEditor; on save, append a new InboxEntry with updated transcript. The transcription_state stays as it was (`on_device_draft` or `whisper_final`) — manual edits don't claim Whisper-equivalent quality, but they don't downgrade either.
- **Trash** → `InboxStore.updateStatus(id:to: .trashed)`. The asset file moves into `.maugham/trash/inbox/<ulid>.<ext>` (using the existing trash conventions); the inbox manifest row is updated. Restore-from-trash is a follow-up; v1 is one-way.

**Empty state.** `ContentUnavailableView("Nothing in the inbox", systemImage: "tray", description: "Capture from MaughamPhone — text, photo, or voice — appears here.")`. The hint is intentionally pointed at the phone — until the phone ships, the inbox stays empty, and the empty state explains why.

### 3.5 WhisperKit transcription worker

**Dependency.** [WhisperKit](https://github.com/argmaxinc/WhisperKit) is the Apple-Silicon-optimized Swift package wrapper around whisper.cpp. SPM-friendly, MIT license, model download is lazy on first use, runs on CoreML. Chosen over: whisper.cpp Swift bindings directly (more setup, less polished), MLX-Whisper (still beta), cloud APIs (privacy + key management).

**Worker lifecycle.** `InboxTranscriptionWorker` is owned by `DocumentStore` (one per project window), started in `DocumentStore.init` after the inbox subdir exists, stopped when the project window closes. It owns a serial `Task` — one transcription at a time — to keep WhisperKit from thrashing under multi-audio bursts. Notifications enqueue; the queue drains in arrival order.

**Per-job flow.**

1. Receive `Notification.maughamInboxChanged` with `kind == .audio`.
2. Pull the entry by deriving id from the changed file's name (`01HQR…J9.m4a` → id `01HQR…J9`).
3. If `transcriptionState == .whisperFinal`, skip (already done, this is a status-only update).
4. Load the audio file path: `.maugham/inbox/audio/<id>.m4a`.
5. Ensure model is available — download on first use. Model identifier from a `@AppStorage("whisperModel")` setting; default `openai_whisper-base` (~150MB). Hint in Settings to upgrade to `openai_whisper-small` (~500MB) or `openai_whisper-large-v3` (~3GB) for higher quality.
6. Run transcription. On success, `InboxStore.updateTranscript(id:text:state: .whisperFinal)`.
7. On failure (model unavailable, audio corrupt, non-Apple-Silicon Mac), `InboxStore.updateTranscript(id:text:state: .failed)` — the on-device draft text from the phone is preserved.

**Model storage path.** `~/Library/Application Support/<BuildVariant.supportFolderName>/WhisperModels/` — variant-scoped so the dev install and stable install can have independent model state, in line with tripwire 13's spirit (every cross-install seam routes through BuildVariant).

**First-download UX.** "Download on first use" is the right default but the wrong UX without scaffolding — the first voice capture a writer makes shouldn't silently `.failed` because the 150MB model wasn't there yet.

1. **Proactive download on worker start.** When `InboxTranscriptionWorker` initializes and the configured model is not present in the model storage path, it kicks off a background download via `WhisperKit.download(variant:)` if network is `.reachable` (checked via `NWPathMonitor`). No alert, no progress bar — just runs. On networks-unavailable, the worker no-ops the proactive download; the explicit-action paths below handle eventually.
2. **Settings exposes explicit controls.** A "Voice transcription" section in Settings: "Currently using: base (149 MB) · Replace…" picker, "Download now" button (enabled when model not present), and a progress indicator (download bytes / total bytes) while a download is in flight. Replace ↔ download a different model and delete the previous to reclaim disk.
3. **First-audio-with-no-model alert.** If an audio entry arrives before the proactive download has completed (cold-launch + first capture within ~60s on a slow network), the worker triggers a one-time HUD alert: "Downloading Whisper model (~150 MB)…" with progress. Non-blocking — the writer can dismiss; the alert returns only on the first audio per session. On completion, queued audio drains.
4. **Offline-with-no-model row badge.** Audio entries that can't yet transcribe (model missing + no network) show a row-level "Awaiting transcription · Download required" subtitle plus a small Settings shortcut chip. Distinguishes the writer-actionable state ("go online or download model") from `.failed` (corrupt audio, unrecoverable).
5. **First-use telemetry sanity check.** Manual smoke step: cold-launch on a fresh install, capture a voice note before the proactive download completes. Confirm the HUD appears, model downloads, queue drains, transcript replaces the on-device draft within ~60s of network availability.

**Non-Apple-Silicon Macs.** WhisperKit requires Apple Silicon for CoreML acceleration. On Intel Macs, the worker emits a one-time `os_log` warning, sets state to `.failed` for new audio entries, and surfaces an "Apple Silicon required for local transcription" hint in Settings. The on-device draft from the phone is the only transcript these Macs will get. The proactive-download path no-ops on Intel.

**Long-audio chunking.** Not in v1. WhisperKit handles up to ~5 minutes well; longer recordings degrade. Document the limit in the worker's header. Chunking is a Phase H item.

### 3.6 iOS file access via `UIDocumentPicker`

The Mac has no iCloud entitlement (verified during planning) — projects live at writer-chosen paths and iCloud Drive happens to sync them. The iOS app preserves that posture: no shared iCloud container, no migration of existing project locations. Instead, the writer picks the projects folder once via `UIDocumentPicker(forOpeningContentTypes: [.folder])`, and the iOS app gets long-lived bookmarked access to it via the security-scoped bookmark API.

**ProjectsRoot lifecycle.**

```swift
@MainActor
final class ProjectsRoot: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published var picker: PickerState = .idle
    private let bookmarkKey = BuildVariant.current.bookmarkUserDefaultsKey

    func resolveOnLaunch() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { picker = .needed; return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [],
                              relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale { picker = .stale(previous: url); return }
            guard url.startAccessingSecurityScopedResource() else { picker = .accessDenied; return }
            rootURL = url
        } catch {
            picker = .resolveFailed(error)
        }
    }

    func pick(from picked: URL) throws {
        let data = try picked.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        _ = picked.startAccessingSecurityScopedResource()
        rootURL = picked
        picker = .idle
    }
}
```

**Coordinated I/O.** Every read inside the bookmarked folder uses `NSFileCoordinator.coordinate(readingItemAt:options:error:byAccessor:)`. Every write — only ever into `.maugham/inbox/*` and `.maugham/ops/*.jsonl` — uses `NSFileCoordinator.coordinate(writingItemAt:options:error:byAccessor:)`. This is the same primitive the Mac uses (`ProjectFolderPresenter`), which is what makes the two sides cooperate cleanly through iCloud Drive.

**Why no `NSFilePresenter` on iOS in v1.** A presenter would notify the iOS app when the Mac writes — useful for "annotations refresh while you're looking at the list." But it requires the app to be foregrounded (or to opt into background modes), and the listener lifecycle on iOS is much fussier than on macOS. v1 refreshes on `.task` (per-view-appearance) and pull-to-refresh, which is sufficient for the use cases. NSFilePresenter on iOS is a Phase H item.

**iCloud Drive file eviction.** Reading any file under the bookmarked folder requires explicit eviction-handling — iOS routinely removes local copies of unused files, leaving placeholders that look like the file but read as empty data with no error. Every read site routes through `CoordinatedFileIO.download(at:)` and `DownloadCoordinator` (§3.13) before reading, so a not-downloaded placeholder triggers a fetch + progress UI instead of silently rendering as "empty." Writes are unaffected — the phone's own writes are never evicted while the write is in flight.

### 3.7 iOS app: capture flow

**Text.** A `TextEditor` in a sheet. On "Save to inbox": generate ULID, write entry to `inbox.jsonl` with `kind: .text`, `inlineText: <body>`, no `sourceFilename`. Coordinated write.

**Photo.** Two sources: `PhotosPicker` for library, `UIImagePickerController(sourceType: .camera)` for fresh capture. On commit: generate ULID, write the image data to `.maugham/inbox/images/<ulid>.<ext>` (preserve original extension where possible; default to `.jpg`), then append `InboxEntry` with `kind: .image`, `sourceFilename: "<ulid>.<ext>"`, no `inlineText` or `transcript`. Coordinated writes for both the image file and the manifest append.

**Voice.**

1. Tap Record → `AVAudioRecorder` starts writing to a tmp `.m4a` (AAC, 64 kbps mono — good enough for speech, small file size). Simultaneously, `SFSpeechRecognizer` opens a streaming session against the same audio buffer (using `SFSpeechAudioBufferRecognitionRequest`) for the live draft.
2. Tap Stop → recorder stops, recognizer finalizes, draft transcript is available within ~500ms.
3. **Pre-commit confirmation screen.** Stop transitions the sheet to a confirmation view: play/pause button against the just-recorded `.m4a`, the draft transcript as editable text below, "Discard" and "Save to inbox" buttons. Playback uses `AVAudioPlayer` against the tmp file. The writer can hear what they just said before committing — closes the "did it hear me?" loop without waiting for Mac-side sync.
4. On "Save to inbox": generate ULID. Move the `.m4a` from tmp into `.maugham/inbox/audio/<ulid>.m4a` (coordinated write). Append `InboxEntry` with `kind: .audio`, `sourceFilename: "<ulid>.m4a"`, `transcript: <draft>` (with any pre-commit edits applied), `transcriptionState: .onDeviceDraft`.
5. On "Discard": delete the tmp file, close the sheet, no manifest entry. (No way to recover; the recording never existed.)

Permissions: requesting microphone (`AVAudioApplication.requestRecordPermission`) and speech recognition (`SFSpeechRecognizer.requestAuthorization`) on first tap of the Record button. If either is denied, surface a clear "Settings → MaughamPhone → permissions" CTA. Without speech recognition the voice flow still works — file is saved, transcript is empty until WhisperKit fills it.

**Project selection.**

A pill at the top of the Capture tab shows the currently-selected project name. Tapping the pill opens a project picker sheet — *not* navigation to the Read tab, which would lose the capture context (selected media, transcript-in-progress).

- **Picker sheet contents:** top section "Recent" with the last 5 projects the writer captured into (most-recent first), then "All projects" alphabetically, then a search field that filters across both. Each row shows the project name and (dimmed) project type icon.
- **Persistence.** Selection is keyed by `ProjectManifest.id` (stable across rename/move within the bookmarked folder), not by file path. `@AppStorage("currentProjectId")` for the active selection. The recents list (capped at 5, updated on every successful capture via `RecentsTracker.recordCapture`) is shared infrastructure — the same tracker feeds the cold-launch proactive-download path in §3.13.
- **Resolution on launch.** ProjectsBrowser builds the id → URL map by walking bookmarked-folder children and decoding each `project.maugham.json`. The pill resolves the persisted id against this map. If the id is missing (project deleted or moved outside the bookmarked root), the pill shows "Choose project…" and the capture buttons stay disabled until the writer picks again from the sheet.
- **Empty state.** If no project is currently selected (first launch, or after a deletion), the capture buttons are disabled with an inline hint pointing at the pill: "Tap above to choose a project."
- **Why not navigate to the Read tab.** Capture flows are time-sensitive — the writer is mid-thought. Forcing a tab switch + navigation + back-button loses the in-progress capture (e.g., a recording paused mid-sentence). The picker sheet keeps the capture context alive.

### 3.8 iOS app: read

**Markdown rendering.** `.md` files are read via coordinated I/O *after* `DownloadCoordinator.ensureDownloaded(url)` resolves (§3.13 — files may be evicted iCloud Drive placeholders). Stripped of `<!-- ¶id -->` HTML-comment anchors (simple regex: `<!--\s*[0-9a-z]{4}\s*-->`), then rendered via `AttributedString(markdown:)`. This is iOS's built-in Markdown renderer; it handles headings, bold/italic, links, lists, and code blocks well enough for read-only display. No custom theming in v1 — system fonts, system colors. Selectable text via `.textSelection(.enabled)`.

`DocumentReaderView.task` calls `DownloadCoordinator.ensureDownloaded` first; the view shows a full-screen "Downloading <docname>… <progress>" with a Cancel button while it resolves. After download the reader content appears. On failure, an inline retry. The view never shows a blank canvas without explanation. Tapping the same doc later (when it's cached) sees `.current` status and goes straight to rendering. Opening a doc also fires `RecentsTracker.recordOpen(_:)` for the parent project so the recents heuristic learns about read patterns, not just capture patterns.

**Fountain rendering.** Parsing uses `FountainTokenizer` from MaughamCore. The parsed `FountainScript` is cached in `@State` and populated via `.task` per document (after the download resolves) — explicitly *not* parsed inside a SwiftUI row body (tripwire 4: per-row re-parse killed Phase 3d performance).

Per-line styling, by `ScreenplayElement`:

| Element | Style |
|---|---|
| sceneHeading | `.font(.body.bold().monospaced())`, uppercased, top padding 12pt |
| action | `.font(.body)`, left-aligned, no indent |
| character | `.font(.body.bold())`, frame max-width center-aligned (or `.leading` with bold + uppercase if center reads weird at narrow widths) |
| parenthetical | `.font(.body.italic())`, leading indent 64pt |
| dialogue | `.font(.body)`, leading indent 48pt, trailing indent 48pt |
| transition | `.font(.body.bold())`, trailing alignment, uppercased |
| sectionHeading | hidden (markdown-like) or `.font(.headline)` toggle |
| synopsis | `.font(.callout.italic())`, dimmed |
| note (`[[ ]]`) | dimmed; hidden by toggle |
| centered (`> <`) | `.frame(maxWidth: .infinity, alignment: .center)` |

The styling is intentionally not pagination — that requires Courier, fixed letter-page width, and page breaks, none of which work on a phone screen. Semantic styling gives the unmistakable feel of a screenplay (where you can see immediately what's dialogue vs. action vs. scene heading) without faking a printed page.

**Search.** In-document only for v1: `String.range(of:options: .caseInsensitive)` highlights matches inline. Cross-project search is a Phase H follow-up — it needs an index strategy (the Mac uses `ProjectStore+Search.swift`'s incremental grep; the phone would need something equivalent).

### 3.9 iOS app: annotation review write path

**Read side.** `AnnotationsListView` walks every bookmarked project's `.maugham/ops/d_*.jsonl` (per-device partitioning, §3.12). Each op-log file is downloaded via `DownloadCoordinator` (§3.13) before being passed through `JSONLAppendStore<Op>` (shared from MaughamCore; same code the Mac runs), `OpReplay.buildState(ops:)` to produce the current `paragraphs` and `sequence`, then `AnnotationDeriver.derive(ops:paragraphs:)` to get the annotation list. Filter to `status == .open`, group by project, sort by paragraph order within doc.

The view observes `DownloadCoordinator.states` and renders a banner reflecting recents' download progress (§3.13 UI table). Recent projects' annotations stream in as their op logs become `.current`; non-recent projects appear as a separate "Other projects (tap to load)" section that triggers lazy download on tap. `AnnotationDetailView.onAppear` calls `RecentsTracker.recordOpen(_:)` for the parent project. The whole derivation pipeline reuses Mac code unchanged — no risk of derivation drift between the two surfaces.

**Write side.** Three lifecycle ops the phone needs to produce: `claudeAccept`, `claudeReject`, `claudeArchive`. The exact JSON shape mirrors the Mac's emit — sourced from `Op.swift` Codable conformance with snake_case CodingKeys.

**`claudeReject` example:**

```json
{"op_id":"01HQR9F8K2P7N3DJ8WMVQXY5T0",
 "doc_id":"d_01HQ7T3JKM2N4P5R6S8VWX0Y2Z",
 "kind":"claude_reject",
 "at":"2026-05-24T15:32:01.123Z",
 "device":"phone:D2A1F8B0-1234-5678-9ABC-DEF012345678",
 "session":"01HQR9F862QYZX3WBCDEFGH7J0",
 "changes":[],
 "provenance":{"session_id":"01HQR9F862QYZX3WBCDEFGH7J0",
               "source_annotation_id":"01HQ8K2M9N4P5R6S8T0V2W3X4Y",
               "user_response":"This sentence works better as-is."}}
```

**`claudeAccept` for non-suggestedChange (comment/query/craftNote):**

```json
{"op_id":"01HQR9F8K2P7N3DJ8WMVQXY5T1",
 "doc_id":"d_01HQ7T3JKM2N4P5R6S8VWX0Y2Z",
 "kind":"claude_accept","at":"2026-05-24T15:32:30.456Z",
 "device":"phone:D2A1F8B0-…","session":"01HQR9F862QYZX3WBCDEFGH7J0",
 "changes":[],
 "provenance":{"session_id":"01HQR9F862QYZX3WBCDEFGH7J0",
               "source_annotation_id":"01HQ8L7P9Q3R5S7T9V1W3X5Y7Z",
               "user_response":null}}
```

**`claudeAccept` for suggestedChange — the critical case:** the accept op must include the creation op's `changes` array verbatim. Mac-side replay reads this array and applies the changes to `paragraphs[paragraphId]`. Without it, the phone-accepted suggestion is a no-op after a Mac restart.

```json
{"op_id":"01HQR9F8K2P7N3DJ8WMVQXY5T2",
 "doc_id":"d_01HQ7T3JKM2N4P5R6S8VWX0Y2Z",
 "kind":"claude_accept","at":"2026-05-24T15:33:11.789Z",
 "device":"phone:D2A1F8B0-…","session":"01HQR9F862QYZX3WBCDEFGH7J0",
 "changes":[{"paragraph_id":"k7m3","prior":"The sun was setting.","next":"The sun was bleeding into the horizon."}],
 "provenance":{"session_id":"01HQR9F862QYZX3WBCDEFGH7J0",
               "source_annotation_id":"01HQ8M9N3P5Q7R9S1T3V5W7X9Y",
               "user_response":null}}
```

The phone's `AnnotationWriter` copies `changes` directly from the creation op (which it already has in its in-memory replay state) — no parsing, no transformation. **This is the only thing that has to be right for phone-accepted suggestedChanges to materialize on the Mac.**

**Mac-side: nothing to change.** `Deriver.appliesToManuscript` at `Deriver.swift:108-117` already includes `.claudeAccept`:

```swift
case .typingBurst, .bootstrap, .externalEdit,
     .checkpointRestore, .claudeAccept:   // ← already in the manuscript-apply set
    return true
```

And `Deriver.derive(ops:)` at `Deriver.swift:26-37` applies `change.next` for any op whose kind passes that gate. The Mac's synchronous `paragraphs` mutation inside `Document.acceptAnnotation` (`Document.swift:683-691`) is anticipation of what replay will do on next load — *not* a substitute for it. A phone-written `claudeAccept` op carrying the creation op's `changes` array verbatim re-materializes the manuscript on Mac restart through the existing replay path. Confirmed by reading the code, 2026-05-24.

The regression net for this is **phone-side**: `AnnotationWriterAcceptSuggestedChangeRoundTripTests` constructs a creation op, builds an accept op via AnnotationWriter, runs both through `Deriver.derive`, and asserts the post-replay paragraph text equals `change.next`. If the phone ever stops copying `changes` verbatim, this test catches it.

**Coordinated write.** Phone's `AnnotationWriter.append(op:)` opens an `NSFileCoordinator` writing-coordination on the phone's per-device op-log file (`.maugham/ops/d_<docId>.<deviceSlug>.jsonl`, see §3.12), calls `JSONLAppendStore<Op>.append(op)` from MaughamCore, releases coordination. Mac-side `ProjectFolderPresenter` notices the new sibling file, `OpLogStore.load(docId:)` picks it up on the next merge, and `Document.handleExternalLogChange` re-derives. Reconciler ingests it as it would any other external append.

### 3.10 BuildVariant on iOS

`BuildVariant` itself lives in MaughamCore (moved in Phase A) and is platform-agnostic — the enum, `current`, `supportFolderName`. iOS-only knobs hang off an extension in `MaughamPhone/BuildVariantPhone.swift`:

```swift
extension BuildVariant {
    var phoneBundleId: String {
        self == .dev ? "com.maugham.MaughamPhone.dev" : "com.maugham.MaughamPhone"
    }
    var bookmarkUserDefaultsKey: String {
        "projectsRootBookmark.\(self == .dev ? "dev" : "stable")"
    }
}
```

The dev/stable split mirrors the Mac's: separate bundle ids, separate `UserDefaults` keys (so a dev build's bookmarked folder doesn't leak into stable, useful when iterating on inbox semantics against a throwaway project folder). Mac-side `BuildVariant.updaterEnabled` is irrelevant on iOS — TestFlight handles updates via its own iOS app. No iOS-side updater code at all.

Per-target Debug/Release configuration in `project.yml`:

```yaml
MaughamPhone:
  type: application
  platform: iOS
  deploymentTarget: "17.0"
  settings:
    configs:
      Debug:
        PRODUCT_BUNDLE_IDENTIFIER: com.maugham.MaughamPhone.dev
        OTHER_SWIFT_FLAGS: $(inherited) -DMAUGHAM_DEV_BUILD
      Release:
        PRODUCT_BUNDLE_IDENTIFIER: com.maugham.MaughamPhone
```

Tripwire 13 extends to iOS sources: `grep -n '"maugham"\|"Maugham"' MaughamPhone/` must return zero matches outside `BuildVariantPhone.swift` and tests. The lint guard (which today greps `Maugham/`) gets a sibling pass.

### 3.11 CI / release pipeline

iOS releases use a separate tag namespace, workflow, and helper script. The Mac pipeline keeps working unchanged.

**Tag namespace.** Mac: `v[0-9]+.[0-9]+.[0-9]+`. Phone: `phone-v[0-9]+.[0-9]+.[0-9]+`. Both workflows trigger only on their own pattern. Milestone tags (`milestone-*`) trigger neither.

**`scripts/cut-phone-release.sh`:**

```bash
#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:?Usage: $0 <version> [--skip-tests]}"
SKIP_TESTS="${2:-}"
NOTES="docs/release-notes/phone/v${VERSION}.md"
[[ -f "$NOTES" ]] || { echo "ERROR: $NOTES missing"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "ERROR: tree dirty"; exit 1; }
[[ "$(git symbolic-ref --short HEAD)" == "main" ]] || { echo "ERROR: not on main"; exit 1; }
if [[ "$SKIP_TESTS" != "--skip-tests" ]]; then
    ./gen.sh
    xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 15' test
fi
git rev-parse "phone-v${VERSION}" >/dev/null 2>&1 && { echo "ERROR: tag exists"; exit 1; }
git tag -a "phone-v${VERSION}" -m "MaughamPhone ${VERSION}"
echo "Tag phone-v${VERSION} created. To trigger release: git push origin phone-v${VERSION}"
```

**`.github/workflows/phone-release.yml`** key shape:

```yaml
name: PhoneRelease
on:
  push:
    tags: ['phone-v[0-9]+.[0-9]+.[0-9]+']
jobs:
  release:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with: { xcode-version: '15.4' }
      - run: brew install xcodegen
      - name: Extract version
        id: ver
        run: |
          echo "version=${GITHUB_REF_NAME#phone-v}" >> "$GITHUB_OUTPUT"
          echo "build=$(git rev-list --count HEAD)" >> "$GITHUB_OUTPUT"
      - name: Verify release notes
        run: test -f docs/release-notes/phone/v${{ steps.ver.outputs.version }}.md
      - name: Import certs
        uses: apple-actions/import-codesign-certs@v3
        with:
          p12-file-base64: ${{ secrets.APPLE_DISTRIBUTION_CERT }}
          p12-password: ${{ secrets.APPLE_DISTRIBUTION_CERT_PASSWORD }}
      - name: Install provisioning profile
        run: |
          mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
          echo "${{ secrets.PROVISIONING_PROFILE }}" | base64 --decode > ~/Library/MobileDevice/Provisioning\ Profiles/maugham-phone.mobileprovision
      - name: Sync version + build into project.yml
        run: |
          # rewrite CFBundleShortVersionString and CFBundleVersion via yq or sed
      - run: ./gen.sh
      - name: Archive
        run: |
          xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
            -configuration Release -destination 'generic/platform=iOS' \
            archive -archivePath build/MaughamPhone.xcarchive
      - name: Export IPA
        run: |
          xcodebuild -exportArchive -archivePath build/MaughamPhone.xcarchive \
            -exportOptionsPlist scripts/ExportOptions.plist \
            -exportPath build/
      - name: Upload to TestFlight
        env:
          APP_STORE_CONNECT_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
          APP_STORE_CONNECT_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
          APP_STORE_CONNECT_API_KEY: ${{ secrets.APP_STORE_CONNECT_API_KEY }}
        run: |
          # decode .p8, configure, xcrun altool --upload-app or notarytool equivalent
      - name: GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          body_path: docs/release-notes/phone/v${{ steps.ver.outputs.version }}.md
          name: MaughamPhone ${{ steps.ver.outputs.version }}
```

**Key contracts.**

- **Tag is the version source of truth.** `project.yml`'s `CFBundleShortVersionString` stays at `"0.0.0-dev"`, `CFBundleVersion` at `"1"`. CI rewrites both at build time.
- **Build number from `git rev-list --count HEAD`.** Monotonic, never resets, doesn't require coordinating with App Store Connect state. Apple rejects uploads where `CFBundleVersion` ≤ any prior upload; commit-count satisfies this. GH Actions `run_number` is *not* used — it resets if the workflow file is recreated.
- **Release notes file is mandatory.** Workflow fails at step 5 if `docs/release-notes/phone/v${VERSION}.md` is missing.
- **Tests must pass.** Phone test target runs as part of `cut-phone-release.sh` pre-flight; CI does not re-run them in the release workflow (saves runner cost; pre-flight is the gate).
- **No partial releases.** TestFlight upload is the second-to-last step; GitHub Release creation is last. Earlier failures leave no public artifact.

**Secrets (one-time setup):** `APPLE_DISTRIBUTION_CERT`, `APPLE_DISTRIBUTION_CERT_PASSWORD`, `PROVISIONING_PROFILE`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY`. All loaded from GitHub repository secrets; documented in a follow-up `docs/release-notes/phone/SETUP.md` file generated during Phase G.

**TestFlight specifics.**

- Internal testing (≤100 testers on your dev team account) skips Beta App Review. First build is usable within ~15 minutes of upload.
- External testers (sharing with non-team friends) require Beta App Review on the first build of each version: 1-2 day delay. Subsequent builds of the same version go straight through.
- Privacy disclosures (mic, speech recognition, camera, photo library, iCloud) are mandatory at upload time; missing `Info.plist` strings or App Store Connect privacy nutrition label entries reject the build.

**App Store eligibility.** This pipeline is App-Store-shaped (signed Distribution build, archive, export, upload). Going from TestFlight to App Store later requires a privacy policy URL, App Store metadata (screenshots, description), and a normal App Review submission. The signing/build/upload code path is unchanged.

### 3.12 Per-device JSONL file partitioning

The problem this section addresses is the most load-bearing single decision in v1: how do multiple devices safely append to shared JSONL files when iCloud Drive is the sync substrate? Without it, the inbox manifest and the op log would silently lose writes under realistic phone/Mac concurrency.

**The problem.** `NSFileCoordinator` serializes writes within a single device — that's its scope. It does not coordinate across devices through iCloud Drive: iCloud's reconciler (`bird`/`cloudd`) runs at daemon level and is oblivious to NSFileCoordinator semantics on the other device. When two devices both append to the same file within an iCloud sync window:

1. iCloud detects divergence (both devices have a "newer than the last common version" file).
2. The reconciler resolves by *whole-file replace*, not line-merge.
3. The loser's copy lands as a conflict-named twin alongside the canonical file: `d_<docId> 2.jsonl`, `d_<docId> (iPhone).jsonl`, or similar (iCloud's exact naming convention varies).
4. Today's `OpLogStore.load(docId:)` opens exactly one path. Twin files are invisible. The loser's ops are silently lost.

This is also a **latent bug today** in Mac↔Mac sync — but rarely triggered because two Macs aren't usually edited by the same user at the same instant. Adding a phone makes simultaneous writes routine: voice capture on phone while paragraph-deletion sweep runs on Mac; reject on phone while accept on Mac; `claudeArchive` on Mac while phone tries to `claudeReject`.

Maugham already acknowledges iCloud conflict creation for `.md` files (`Document.swift:1030-1037`, `writeConflictBackup`). The JSONL story was never specced because there was only one writer per file. Adding a second writer requires fixing this.

**The decision.** Each device writes to its own file; readers glob and merge.

| Today | After |
|---|---|
| `.maugham/ops/d_<docId>.jsonl` (one file, all writers) | `.maugham/ops/d_<docId>.<deviceSlug>.jsonl` (one file per writer) + legacy `d_<docId>.jsonl` continues to load |
| `.maugham/inbox/inbox.jsonl` (one file, all writers) | `.maugham/inbox/inbox.<deviceSlug>.jsonl` (one file per writer) + legacy `inbox.jsonl` continues to load |

Two devices can never target the same file path, so iCloud never has to reconcile divergent versions and conflict-twins are impossible by construction. Files are only touched by their owning device; other devices see them as read-only siblings to fold into their merge.

**`deviceSlug` derivation.** `Document.device` already exists (`Document.swift:106`) as the canonical per-install identifier. The slug is a sanitized form suitable for filenames — UUID dashes stripped, lowercased, optionally truncated to keep filenames manageable. Exact form to be decided at implementation time but stable per install (so a device's files stay addressable to itself across launches).

**Source of truth — unchanged.** The logical op log remains "the merged, opId-sorted, opId-deduped set of all ops." It's just assembled from multiple files at load time instead of being identified with one file. Per the existing `OpLogStore.swift:5-7` comment: *"Dedupes by `op_id` and sorts by `op_id` (timestamp-prefixed ULID gives deterministic cross-device order)."* Cross-device order is already the contract — partitioning extends it from "across writes by the same Mac across sessions" to "across writes by all devices across sessions."

**Why this works without further design.** ULID does the heavy lifting:

- ULID = `[48 bits ms-since-epoch][80 bits cryptographic randomness]`. Lexically sortable, globally unique.
- Sort any set of ops by `opId` → same total order regardless of which file each came from.
- `Deriver.derive(ops:)` already folds in opId order and doesn't care where ops were stored.
- `RewindCursor.atOp(opId, at)` uses opId as identity; "fold up to opId X" works for any op regardless of source file.
- The deriver's paragraph-level last-writer-wins (where "writer order" = opId order) is the existing convergence semantics. CRDTs were *designed* for this — physical storage layout shouldn't affect convergence.

**ULID time semantics.** First 48 bits are UTC epoch-ms. Timezone-agnostic. Travel, DST, and OS-displayed-timezone changes do not affect ordering. Manual clock tampering (Settings → Date & Time → Set Automatically OFF, then set wrong) would, but is out of scope as a user-fault condition equivalent to manually corrupting an op log file. NTP corrections are sub-second and irrelevant at Maugham's human-paced op cadence.

**Late-arrival semantics.** Phone offline for a week → ops come back stamped from a week ago, fold into the past at their original ULID position when sync resumes. Rewind history can "grow backwards" when this happens — state at cursor X is deterministic *given the ops the load knew about*; it can become more-informed than yesterday but never inconsistent. This is the same behavior as today's Mac↔Mac late sync, just more frequent with a phone.

**Code changes (compact).**

```swift
// Maugham/OpLog/OpLogStore.swift
public func load(docId: String) async throws -> [Op] {
    let dir = projectURL.appendingPathComponent(".maugham/ops")
    let urls = (try? FileManager.default.contentsOfDirectory(at: dir,
                   includingPropertiesForKeys: nil)) ?? []
    let prefix = "\(docId)"   // matches d_<id>.jsonl + d_<id>.<deviceSlug>.jsonl
    let matches = urls.filter {
        let n = $0.lastPathComponent
        return n == "\(prefix).jsonl" ||
            (n.hasPrefix("\(prefix).") && n.hasSuffix(".jsonl"))
    }
    var merged: [Op] = []
    for url in matches {
        merged.append(contentsOf: try await JSONLAppendStore<Op>(
            fileURL: url, presenter: presenter,
            dedupKey: { $0.opId },
            sortedBy: { $0.opId < $1.opId }).load())
    }
    // Each file is already deduped + opId-sorted by JSONLAppendStore; merge
    // by re-sorting and re-deduping across the union.
    var seen = Set<String>()
    return merged.sorted { $0.opId < $1.opId }.filter { seen.insert($0.opId).inserted }
}

public func append(_ op: Op) async throws {
    try await store(forDocId: op.docId, deviceSlug: ownDeviceSlug).append(op)
}
```

`Document.handleExternalLogChange` is unchanged — it already re-runs `opStore.load`, which now globs. `RewindWindow` is unchanged — it reads ops via `doc.opLog()` and operates on `[Op]`, unaware of how the array was assembled. `Deriver` and `Materializer` are unchanged.

**Presenter scope.** `ProjectFolderPresenter` must subscribe at directory level so that new files (a phone's first-write creates a file the Mac has never seen) trigger `presenterDidChangeSubitem`. CLAUDE.md tripwire #7 implies the existing presenter is directory-scoped; verify during Phase B0 before committing to the spec contract. If the existing implementation watches a fixed file set, broaden it.

**Backward compat.** The legacy `d_<docId>.jsonl` (no device suffix) file is one of the files included in the glob. Existing op logs continue to load with zero migration. New writes go to per-device files. Per CLAUDE.md tripwire 11, no migration logic — the legacy file is left alone and continues to be one of the merge sources forever (or until it's empty and stable, at which point it could be deleted manually).

**File count growth.** One file per (device, doc) pair. For a writer using one Mac + one phone, that's two files per doc. For a writer with N devices over the project's lifetime (counting devices replaced/retired), N files per doc — bounded by realistic device count, not by op rate. No directory-blowup risk.

**Checkpoints are unchanged.** Per-project, live in `.maugham/checkpoints/`, single writer (the Mac that initiates the checkpoint). No partitioning needed; only the per-doc op log and per-project inbox need it.

**What this does NOT solve.** Annotation race semantics (§5.3 Races 1 and 2) are about deriver-level interpretation of overlapping lifecycle ops, not about file-level conflicts. Partitioning makes both ops survive the file system; the deriver still has to decide which lifecycle state wins. Races 1 and 2 remain as documented.

**ADR.** This decision is recorded in `docs/adr/0011-per-device-jsonl-partitioning.md` so future code reviewers have one document to point at rather than a section of an iPhone spec.

**CLAUDE.md.** A new tripwire (#15) lands with the implementation: *"Don't share a single JSONL file across writers via iCloud Drive. Per-device suffix, glob on load, dedupe on opId. Skipping this reintroduces the silent-data-loss path described in spec §3.12."*

### 3.13 iCloud Drive eviction handling (iOS)

iOS aggressively manages on-device iCloud Drive storage: files unused for ~7 days (heuristic), files when free space runs low, or any file when "Optimize iPhone Storage" is enabled (default ON for most devices) can be evicted. The URL still resolves; the file appears to exist; `Data(contentsOf:)` returns empty bytes with no error; `NSFileCoordinator` coordinated reads auto-download but block indefinitely with no progress UI. Without explicit handling, MaughamPhone's Annotations tab silently shows "no annotations" when the writer actually has 47 open — exactly the scenario where the writer most needs the app to work (returning from a weekend offline to triage).

**Detection.** Every read site must check `URLResourceKey.ubiquitousItemDownloadingStatusKey` *before* attempting to read:

| Status | Meaning | Read action |
|---|---|---|
| `.current` | Locally present, up-to-date | Read immediately |
| `.downloaded` | Locally present, may not be current | Read; iOS will catch up in background |
| `.notDownloaded` | Placeholder only | Trigger download + show "Downloading…" UI; complete read when status reaches `.current` |
| (download in progress) | `URLResourceKey.ubiquitousItemIsDownloadingKey == true` | Show progress; await completion |
| (download failed) | `URLResourceKey.ubiquitousItemDownloadingErrorKey` non-nil | Show error + retry affordance |

**The hybrid strategy.** Recent projects (5 most-recently-captured + any project opened in the last 14 days) get **proactive download on launch**, capped at a **50 MB cold-launch budget** for op-log files. Project manifests are always proactively downloaded (tiny, essential for the Read tab to populate). Everything else is **lazy on first access** — manuscripts, research files, op logs for non-recent projects — with explicit per-screen progress UI.

The principle: **never silently render "empty" when the truth is "not yet loaded."** Empty-state UI is for "you have no annotations." A separate "Loading…" state is for in-flight downloads. They must be visually unambiguous.

#### Three new components

**`MaughamPhone/Storage/DownloadCoordinator.swift`** — an actor that owns download state.

```swift
@MainActor
actor DownloadCoordinator {
    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(progress: Double)  // 0.0 ... 1.0
        case downloaded
        case failed(String)
    }

    private var inFlight: [URL: Task<Void, Error>] = [:]
    private(set) var states: [URL: DownloadState] = [:]
    private(set) var coldLaunchBudgetRemaining: Int64 = 50 * 1024 * 1024  // 50 MB

    /// Idempotent. Multiple callers for the same URL share one download.
    func ensureDownloaded(_ url: URL) async throws { … }

    /// Used only during the cold-launch proactive pass. Returns false
    /// (and does NOT start a download) when the budget is exhausted.
    func ensureDownloadedIfBudgetAllows(_ url: URL, sizeHint: Int64) async -> Bool { … }

    func cancel(_ url: URL) { … }
    func observe(_ url: URL) -> AsyncStream<DownloadState> { … }
}
```

In-flight deduplication is the key invariant. If three views all want the same op log, they share one download and observe the same progress; the coordinator counts only one budget hit.

**`MaughamPhone/Storage/CoordinatedFileIO.swift`** gains a `download(at:)` helper that wraps `FileManager.startDownloadingUbiquitousItem(at:)` + polls via `URLResourceKey.ubiquitousItemDownloadingStatusKey` until `.current`. Cancellation-aware (checks `Task.isCancelled` between polls). Default poll interval 100ms, exponential backoff to 1s for downloads longer than a few seconds. Throws on `ubiquitousItemDownloadingErrorKey` or task cancellation.

**`MaughamPhone/Storage/RecentsTracker.swift`** — derives the recents list from two persisted signals.

```swift
@MainActor @Observable
final class RecentsTracker {
    @AppStorage("recentProjectIds") private var capturedRaw: Data = .init()
    @AppStorage("lastOpenedDates")  private var openedRaw: Data = .init()

    private var captured: [ProjectId] { /* decode JSON; cap at 5 */ }
    private var openedDates: [ProjectId: Date] { /* decode JSON */ }

    /// Five most-recently-captured ∪ any project opened in the last 14 days.
    /// Deduped, no defined ordering across the two sets.
    var recents: Set<ProjectId> {
        let opened = openedDates
            .filter { $0.value > Date().addingTimeInterval(-14 * 24 * 3600) }
            .map(\.key)
        return Set(captured).union(opened)
    }

    func recordCapture(into projectId: ProjectId) { /* prepend, cap at 5 */ }
    func recordOpen(_ projectId: ProjectId) { /* upsert Date.now */ }
}
```

`recordOpen` fires when: writer taps a project in the Read tab (any doc/binder navigation) OR when AnnotationDetailView appears for any annotation in that project. `recordCapture` fires after a successful inbox-write in the capture flow.

#### Cold-launch sequence

Triggered once per app launch, after `ProjectsRoot` resolves the bookmark.

1. **Always: download every project manifest.** Walk bookmarked-folder children; for each candidate `<child>/project.maugham.json` with `.notDownloaded` status, call `DownloadCoordinator.ensureDownloaded`. Manifests are KB-scale; no budget needed. Sequential is fine; usually all-cached by step 2.
2. **Build the recents set.** `RecentsTracker.recents` resolved against the manifest map (recents pointing at deleted/moved projects are silently dropped).
3. **For each recent project, in capture-recency order:**
   - Enumerate `.maugham/ops/d_*.<*>.jsonl` in that project.
   - Sum byte size (from `URLResourceKey.fileSizeKey`).
   - Call `ensureDownloadedIfBudgetAllows`. If the budget can accommodate the full set, download all; if it would exceed, skip the rest of this project's op logs (don't partial-download a project's stream).
4. **Once recents are downloaded (or budget exhausted), the Annotations tab can populate.** The tab observes `DownloadCoordinator.states` and renders a header banner reflecting progress.

Non-recent projects' op logs and all manuscripts/research files are not touched on launch — they wait for explicit tap.

#### UI states per surface

**Read tab project list.** A project whose manifest is `.downloading` shows a row with a small spinner and "Downloading…" subtitle. A project whose manifest has `.failed` shows a row with an inline retry button. The writer can still see and tap rows; tapping a `.notDownloaded` row triggers the download and waits.

**Annotations tab header banner.**

| Coordinator state for recents' op logs | Banner copy | Behavior |
|---|---|---|
| All `.current` | (no banner) | Normal annotation list |
| Some `.downloading` | "Syncing 3 of 5 projects from iCloud…" + progress | Show annotations from already-loaded projects; new ones append as downloads complete |
| All `.notDownloaded`, none in-flight | "Recent projects need to download from iCloud" + "Sync now" button | Tap to start; otherwise sit and wait for network |
| All failed | "Couldn't reach iCloud. Try again." + retry | Banner with retry; list shows whatever loaded last session |

**Non-recent projects in the Annotations tab.** Listed below the "Recent" group under a "Other projects (tap to load)" header. Each row shows the project name, manifest-loaded open-annotation count (which is *not* available without the op log, so this is best-effort: shows a placeholder count once tapped, real count after download).

**Document reader.** Tap on a not-downloaded manuscript → full-screen "Downloading <docname>… <progress>" view with a Cancel button. On completion, the reader content appears. On failure, an inline retry. The reader never shows a blank canvas without explanation.

**Research browser.** Same as document reader — lazy download per file on tap.

#### Cancellation + backgrounding

Downloads in flight when the user backgrounds the app continue in iOS's normal "extended task" budget (a few minutes). On foregrounding, the coordinator polls status once for every URL it was tracking and resumes any that are now `.downloading` again. URLs that completed while backgrounded are simply observed as `.downloaded`.

Cancellation via "Cancel" in the document reader stops the polling Task and removes the in-flight entry. The OS may still complete the underlying download; the next view of the doc will see `.current` and skip the download UI.

#### Notes on `setUbiquitousItemDownloadRequestedKey`

There is no documented API for "tell iOS to never evict this file." Apps can request downloads but not retention. The closest is `FileManager.evictUbiquitousItem(at:)` for explicit eviction, which we don't use. Long-term retention of files locally is implicitly handled by frequent reads (recent files don't get evicted as quickly), which the proactive recents-download path already produces.

#### What this explicitly does NOT cover (v1)

- **Background refresh while suspended.** iOS doesn't run the app between launches; we don't subscribe to `NSFilePresenter` on iOS (§3.6). The writer must foreground the app to trigger fresh downloads. A "Background App Refresh" mode is Phase H.
- **Predictive download** based on time-of-day patterns or location. Recents heuristic + lazy fallback is enough for v1.
- **Custom budget per device class.** 50 MB is fixed for v1. iPhone Pro with 512 GB free vs iPhone SE 64 GB at 90% full get the same cap. Reasonable in practice; revisit if it shows up as a complaint.
- **Eviction-during-read recovery.** If iOS evicts a file *while* we're reading it (extremely rare; iOS waits for handles to close), reads may fail mid-stream. Same recovery as any read failure: surface error, retry available.

---

## 4. Data flow

### 4.1 Voice capture round-trip

```
PHONE
  User taps Record → AVAudioRecorder starts to tmp .m4a
                  → SFSpeechRecognizer attaches to same buffer
  User taps Stop  → recorder finalizes (e.g. 8s of audio)
                  → recognizer yields draft "rewrite the opening on the train"
  Generate ULID: 01HQR8YN3T6JYWBQ5VWZG2H8J9
  NSFileCoordinator.writing on
    <root>/MyNovel/.maugham/inbox/audio/01HQR…J9.m4a
    → move tmp .m4a into place
  NSFileCoordinator.writing on
    <root>/MyNovel/.maugham/inbox/inbox.jsonl
    → JSONLAppendStore.append(InboxEntry(id: "01HQR…J9",
        kind: .audio, sourceFilename: "01HQR…J9.m4a",
        transcript: "rewrite the opening on the train",
        transcriptionState: .onDeviceDraft, status: .new))

iCloud Drive propagates both files (typically 5–30s).

MAC
  ProjectFolderPresenter sees `.maugham/inbox/audio/01HQR…J9.m4a`
    → MaughamSidecarPath classifies as .inbox(.audio, …)
    → DocumentStore.presenterDidChangeSubitem posts maughamInboxChanged{kind: .audio}
  InboxStore subscribes, calls refresh() → entries: [entry01HQR…J9]
  InboxPane (⌘⌥6) row appears: "rewrite the opening on the train" with draft badge.
  InboxTranscriptionWorker subscribes, enqueues job for id 01HQR…J9.
    → WhisperKit transcribes the .m4a → "Rewrite the opening on the train."
    → InboxStore.updateTranscript(id: "01HQR…J9",
         text: "Rewrite the opening on the train.",
         state: .whisperFinal)
       → JSONLAppendStore.append(new InboxEntry with same id, updated transcript,
           transcriptionState: .whisperFinal)
  InboxPane row updates: draft badge becomes whisper badge; text gets capitalization/punctuation.

PHONE (next time Capture tab refreshes)
  Sees the .whisperFinal entry but doesn't surface it — the phone's capture history
  shows local-only state. (Future enhancement: a "Sent to Mac" badge on the capture row.)
```

### 4.2 Annotation reject round-trip

```
MAC
  Claude (via MCP add_note) emits claudeCreate op with kind suggestedChange:
    {op_id: "01HQ8M…", kind: "claude_create",
     creation: {kind: "suggested_change", paragraphId: "k7m3", body: "Punchier verb?"},
     changes: [{paragraphId: "k7m3", prior: "The sun was setting.",
                next: "The sun was bleeding into the horizon."}]}
  Op appended to <root>/MyNovel/.maugham/ops/d_01HQ7T….jsonl
  AnnotationDeriver classifies as status .open

iCloud Drive propagates the op-log append.

PHONE (user opens Annotations tab; .task fires)
  Walks <root>/MyNovel/.maugham/ops/*.jsonl
    → JSONLAppendStore<Op>.load
    → OpReplay.buildState
    → AnnotationDeriver.derive → annotation [a01HQ8M… status .open]
  AnnotationsListView shows: "MyNovel · Ch. 1 · ¶k7m3 · Punchier verb?"
  User taps row → AnnotationDetailView
    .onAppear: re-derive (cheap; one log read). Status still .open. Show buttons.
  User taps "Reject…" → sheet for reason → "This sentence works better as-is."
    → AnnotationWriter.append(claudeReject op):
      {op_id: "01HQR9F…", kind: "claude_reject",
       provenance: {source_annotation_id: "01HQ8M…",
                    user_response: "This sentence works better as-is."},
       changes: []}
    → NSFileCoordinator.writing on <root>/MyNovel/.maugham/ops/d_01HQ7T….jsonl
      → append the op
  Detail view dismisses; list view refreshes (annotation no longer .open, drops off).

iCloud Drive propagates the new op.

MAC
  ProjectFolderPresenter sees .maugham/ops/d_01HQ7T….jsonl modified
    → MaughamSidecarPath classifies as .opLog(docId: "d_01HQ7T…")
    → Document.handleExternalLogChange (existing path) loads the new ops via JSONLAppendStore
       (dedupKey on op_id collapses the new op as a clean append)
    → AnnotationDeriver re-runs; annotation [a01HQ8M…] now status .rejected
       with userResponse: "This sentence works better as-is."
  AnnotationsPane (⌘⌥2) shows the annotation as rejected with the user's response.
```

### 4.3 TestFlight build flow

```
DEVELOPER (locally)
  Drafts release notes at docs/release-notes/phone/v0.1.0.md.
  Commits on main.
  Runs ./scripts/cut-phone-release.sh 0.1.0:
    - Verifies notes file exists.
    - Verifies clean tree, on main.
    - Runs MaughamPhone tests on iPhone 15 simulator.
    - Creates tag phone-v0.1.0.
  Runs git push origin phone-v0.1.0.

GITHUB ACTIONS (.github/workflows/phone-release.yml)
  Tag push matches `phone-v[0-9]+.[0-9]+.[0-9]+`. Workflow runs.
  Checkout, setup Xcode, install xcodegen.
  Extract version "0.1.0" and build "47" (commit count).
  Verify release notes file (already verified by cut script, but defense in depth).
  Import distribution cert + provisioning profile from secrets.
  Rewrite project.yml: CFBundleShortVersionString=0.1.0, CFBundleVersion=47.
  ./gen.sh.
  xcodebuild archive → build/MaughamPhone.xcarchive.
  xcodebuild -exportArchive → build/MaughamPhone.ipa.
  Upload to App Store Connect via altool/notarytool + API key.
  Create GitHub Release tagged phone-v0.1.0 with release notes body.

APP STORE CONNECT
  Receives upload. Runs basic processing (~10 minutes).
  Build appears in TestFlight, marked "Processing" briefly, then "Ready to Test".
  Internal testers (the developer's account) see it within ~15 minutes total.

PHONE (tester device)
  TestFlight app shows "MaughamPhone 0.1.0 (47)".
  Tap Install → app downloads + installs.
```

---

## 5. Error handling

### 5.1 Bookmark staleness

`URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)` sets `isStale = true` when iOS believes the bookmark needs refreshing (device restart, iCloud Drive remount, app upgrade in some cases). Behavior:

| Outcome | UI |
|---|---|
| Bookmark resolves, `isStale == false` | Normal launch; Read tab shows projects |
| Bookmark resolves, `isStale == true` | Settings shows "Folder access expired — Re-pick" CTA; tabs disabled until re-picked |
| Bookmark missing (first launch / cleared data) | Initial onboarding: full-screen "Pick your Maugham projects folder" → opens picker |
| Bookmark resolves but `startAccessingSecurityScopedResource()` returns false | "Folder access denied — Re-pick" CTA (rare; happens if the folder was deleted) |
| Resolution throws | "Couldn't read your saved folder — Re-pick"; log details |

The Re-pick CTA opens the same `UIDocumentPicker` flow. Re-picking the same folder is the expected resolution for stale bookmarks.

### 5.2 WhisperKit failures

| Failure | Behavior |
|---|---|
| Non-Apple-Silicon Mac | Worker sets `transcriptionState: .failed` for new audio entries on creation; one-time `os_log` warning at startup; Settings shows "Apple Silicon required for local transcription" |
| Model not downloaded, network unreachable | First-job: state `.failed`; UI shows "Couldn't download Whisper model — try again later"; subsequent jobs retry on next inbox notification |
| Model download corrupted (SHA mismatch on WhisperKit's part) | State `.failed`; UI same; retry on next notification deletes and re-downloads |
| Audio file corrupt / zero-length | State `.failed`; transcript stays as on-device draft if present |
| Transcription times out (>5 min for short audio is unrecoverable) | Cancel the Task, state `.failed`; retry on next notification |
| Worker crashes mid-job | Job is lost; next inbox notification re-enqueues (the worker re-reads entries with `transcriptionState != .whisperFinal`) |

The on-device draft from the phone is preserved in all failure cases. The writer always has *something* — failure mode is "the Mac doesn't improve on it," not "you lose the transcript."

### 5.3 Cross-device annotation races

Three races to consider:

**Race 1 — Mac archives while phone holds detail view open.**
Mac appends `claudeArchive`; iCloud propagates. Phone's `AnnotationDetailView` is showing the annotation; its in-memory state still says `.open`. User taps Accept.

Mitigation: `AnnotationDetailView.onAppear` re-derives status. On view *appearance*, this catches the case where the user backgrounded the app and came back after a Mac action. For the case where the user is actively staring at the detail view when the Mac acts: not mitigated in v1. The phone-written accept op appends, deriver classifier (in `AnnotationDeriver.swift:14–20`) keeps the latest-ULID lifecycle op for that source — the accept (later ULID) wins. This is acceptable: the user's *most recent* explicit action wins. Document the behavior; revisit if it surfaces as a complaint.

**Race 2 — Phone accepts a suggestedChange against a swept paragraph.**
Mac sweeps a paragraph (deletion → `claudeArchive` with `provenance.synthesisSource: paragraph_deleted`); annotation is now archived with `paragraphId` no longer in `sequence`. Phone hasn't seen the sweep yet; user taps Accept on the suggestion. Phone appends `claudeAccept` with the creation op's changes (which target the now-missing paragraph).

Behavior on Mac replay: `paragraphs[change.paragraphId] = change.next` stores text under an id not in `sequence`. `Materializer.materialize` skips ids missing from `sequence`. Result: the change is harmless data in the `paragraphs` map but invisible in the rendered `.md`. AnnotationDeriver sees the (later) `claudeAccept` op and… actually, this is where it gets subtle. The deriver's `latestLifecycle[src]` collapses to the later op, so the annotation flips back from `archived` to `accepted` even though the paragraph is gone. Visually on the Mac, the annotation list shows "accepted" with no rendered effect.

Mitigation: not in v1; document in InboxStore and AnnotationDetailView headers. The harm is low (no data loss, no manuscript corruption); the user can re-trigger the sweep by re-deleting the paragraph (a no-op) which will append a fresh archive op. A more principled fix is a deriver rule: `claudeAccept` for suggestedChange against a paragraph not in `sequence` is treated as a no-op. Single-line rule in deriver, but it changes Mac-side derivation behavior and deserves its own ADR — leave for Phase H.

**Race 3 — Phone and Mac both act simultaneously.**
At the file system layer this can no longer cause data loss: per-device file partitioning (§3.12) ensures the phone and Mac write to different files. iCloud Drive never has to reconcile two writers of the same path; conflict-twins are impossible by construction. Both ops survive into the merged stream.

At the deriver layer, the same paragraph-level last-writer-wins semantics that already govern Mac↔Mac concurrency apply: both ops are folded in by opId order, and `AnnotationDeriver.derive` collapses lifecycle to the latest-ULID op for that `source_annotation_id`. The "winner" is the action with the later ULID, which approximates "the action the user took last" (modulo sub-second clock skew, which is below the granularity at which a human can perform two annotation actions). Behavior is consistent and recoverable; the only user-visible artifact is that the action with the later ULID prevails.

### 5.4 Coordinated file write failures

`NSFileCoordinator.coordinate(writingItemAt:...)` can fail (rare: file system permission, disk full, iCloud Drive temporarily unavailable). On failure: surface a toast ("Couldn't save — try again"), do not append to the manifest, do not move/create the asset file. The capture flow is idempotent at the ULID level — retrying generates a fresh ULID and starts over.

Partial-write failure (asset file written, manifest append fails) leaves an orphan file in `.maugham/inbox/<kind>/`. Mac-side `InboxStore.refresh()` will not surface it (it's not in the manifest); a future cleanup pass can grep `inbox/*/` for files whose id isn't in the manifest and either re-create entries or trash them. Not implemented in v1; orphans are low-cost.

### 5.5 TestFlight CI failures

| Failure | Workflow outcome | Effect on testers |
|---|---|---|
| Release notes file missing | Fails at verify step, no archive | None — pre-publish |
| Cert/profile decode fails | Fails at import step | None |
| Archive fails (Swift compile error) | Fails at archive step | None |
| Export fails (signing issue) | Fails at export step | None |
| TestFlight upload fails (network, ASC API error) | Fails at upload step; `.ipa` available as workflow artifact for manual upload | None — testers see no new build |
| Upload succeeds, ASC processing fails (rare: missing entitlements, missing privacy strings) | Workflow reports success; ASC email reports rejection | Testers don't see the build; developer fixes + re-cuts as next patch |
| GitHub Release creation fails (rare) | Workflow fails at release step; TestFlight already has the build | Testers see the build; release page is missing; developer creates the GH release manually |

The asymmetry (TestFlight upload before GH release) is intentional: TestFlight is the artifact users consume; the GH release is documentation. Having the testable build available without the release page is acceptable; the reverse (release page advertising a build that never made it to TestFlight) is not.

### 5.6 iCloud Drive download failures (iOS)

Three failure modes for the eviction-handling code in §3.13.

| Failure | Detection | UI |
|---|---|---|
| Network unreachable when read attempted | `NWPathMonitor` reports `.unsatisfied`; download never starts | Banner / row: "Offline — annotations will sync when you reconnect"; retry automatic on `.satisfied` transition |
| Download starts but fails | `URLResourceKey.ubiquitousItemDownloadingErrorKey` non-nil | Banner / row: "Couldn't download from iCloud. Tap to retry." Manual retry only |
| Download times out (no progress for >60s) | Polling sees no `progress` change for the window | Same as failure — surface and offer retry |

The principle restated: no surface ever renders an empty-state UI while the truth is "couldn't load yet." Empty state is only for "confirmed empty after successful read."

Cold-launch budget exhaustion is **not** a failure — it's expected. Projects skipped due to budget appear in the "Other projects (tap to load)" group with a normal lazy-download affordance, no error.

---

## 6. CLAUDE.md additions

Inserted between the existing "Releases" section and "Architectural tripwires":

```markdown
## iPhone companion

MaughamPhone is a TestFlight iOS app that complements (not replaces) the Mac:

- **Capture inbox** — text, photo, voice captures land in `.maugham/inbox/` per-project,
  synced via iCloud Drive. Voice gets an on-device `SFSpeechRecognizer` draft instantly;
  Mac re-transcribes via WhisperKit and replaces the draft.
- **Read** — projects/binders/manuscripts/research browsable on the phone. Markdown
  rendered native; Fountain rendered semantically (line-type-aware styling, not pagination).
- **Annotation review** — Accept / Reject / Archive Claude's open annotations from the
  phone. Lifecycle ops written directly to `.maugham/ops/<docId>.jsonl`.

**Hard invariant: phone never writes to manuscripts.** It writes only to `.maugham/inbox/*`
and `.maugham/ops/*.jsonl`. Manuscript `.md` files remain Mac-only.

**iOS file access** is via `UIDocumentPicker` + security-scoped bookmark — the user picks
their projects folder once, the phone retains long-lived access via `NSFileCoordinator`
(same primitive the Mac uses). No shared iCloud container; existing project locations
unchanged.

**Tag namespace.** Mac releases: `v0.X.Y`. Phone releases: `phone-v0.X.Y`. Separate
workflows triggered by separate tag patterns. Phone release script:
`./scripts/cut-phone-release.sh 0.X.Y`; release notes at `docs/release-notes/phone/v0.X.Y.md`;
workflow at `.github/workflows/phone-release.yml`. TestFlight distribution; build number
from `git rev-list --count HEAD` (monotonic, never resets).

**Shared code** lives in `Packages/MaughamCore/` — Foundation-only Swift Package with
Op types, JSONL store, AnnotationDeriver, Materializer, Bootstrap, ParagraphID, ULID,
BuildVariant, ProjectManifest models, and the Fountain parser. AppKit-bound files stay
in `Maugham/`; UIKit-bound files live in `MaughamPhone/`.
```

Additions to "Questions you do not need to ask":

- "Should the phone be able to edit manuscripts?" → No. Manuscript is the writer's, Mac-only. Phone writes annotation lifecycle ops and inbox sidecar entries.
- "Should we share an iCloud container between Mac and iOS?" → No. Mac uses arbitrary folder paths; iOS uses UIDocumentPicker for the same flexibility.
- "Should we cloud-transcribe voice notes?" → No. On-device draft (phone) + WhisperKit (Mac) cover the quality/latency tradeoff without third-party API calls.

New tripwires (#14 and #15) appended:

```markdown
14. **Don't write to manuscript `.md` files from the iOS app.** The phone writes only
    annotation lifecycle ops (to its own per-device `.maugham/ops/d_<docId>.<deviceSlug>.jsonl`)
    and inbox sidecar entries (to its own `.maugham/inbox/inbox.<deviceSlug>.jsonl`).
    Mac-side echo guard (`Document.lastDiskEcho: EchoState`) is byte-equality on `.md`
    writes only — phone writes can never masquerade as Mac echoes because they don't
    target `.md`. Manuscript content changes only via the user accepting a Claude-authored
    suggestedChange that already encoded the change in its `changes` array — the phone
    appends `claudeAccept` with `changes` copied verbatim from the creation op; Mac-side
    `Deriver.derive` applies them on next load. If you find yourself wanting to "just
    patch this paragraph from the phone" outside that path, that's a Bootstrap/¶id
    problem: the phone has no Bootstrap funnel, and the conflict-on-unanchored-edit
    contract makes phone-side manuscript edits unsafe. Route the intent through an
    annotation instead.

15. **Don't share a single JSONL file across writers via iCloud Drive.** The op log
    (`.maugham/ops/*.jsonl`) and inbox manifest (`.maugham/inbox/inbox.*.jsonl`) are
    per-device-partitioned: each device writes to its own `*.<deviceSlug>.jsonl` file,
    readers glob and merge by opId (op log) or id last-wins (inbox). NSFileCoordinator
    serializes only within one device — iCloud Drive's reconciler can't merge concurrent
    appends to the same path and produces silent conflict-twins (`d_x 2.jsonl`,
    `d_x (iPhone).jsonl`) that the loader never opens. If you add a new multi-writer
    JSONL surface, partition it the same way. See [ADR 0011](docs/adr/0011-per-device-jsonl-partitioning.md)
    and spec §3.12.
```

Segment-picker tooltips landed in `ProjectWindow` / `DetailPaneToggle`, closing the
`milestone-ui-polish-followups` carry-forward about Annotations vs History pane affordance:

```swift
// DetailPaneToggle row hints
.help("Annotations · Accept / Reject / Archive Claude's open notes")     // ⌘⌥2
.help("Outline · Document structure")                                     // ⌘⌥3
.help("History · Read-only forensic log of every op (rewind from here)")  // ⌘⌥4
.help("Research · Project research browser")                              // ⌘⌥5
.help("Inbox · Triage captures from MaughamPhone")                        // ⌘⌥6
```

The phrasing differentiates **action surfaces** (Annotations, Inbox) from the **read-only
log** (History) at the picker, before the writer has to click in and discover it.

Per-area pointer added to "Per-area pointers":

```markdown
### `MaughamPhone/` — iOS companion app
- Four-tab TabView (Capture / Read / Annotations / Settings). No NavigationStack at the
  root; per-tab navigation.
- `ProjectsRoot` owns the security-scoped bookmark; `.task`/pull-to-refresh is the v1
  refresh model (no `NSFilePresenter` on iOS — see §3.6 of the spec).
- Every write coordinated via `CoordinatedFileIO`. Every read coordinated.
- All shared types from `MaughamCore`. iOS-only knobs in `BuildVariantPhone.swift`.
- Project selection persisted by `ProjectManifest.id` (not relative path) — stable across
  rename/move within the bookmarked root. See §3.7.
- Tripwire 13 extends here: `grep -n '"maugham"\|"Maugham"' MaughamPhone/` must return
  zero matches outside `BuildVariantPhone.swift` and tests.
- Tripwire 4 extends here: cache `FountainScript` in `@State` populated by `.task`; do
  not re-parse inside SwiftUI row bodies.
```

---

## 7. Testing

### 7.1 New unit tests

**MaughamCore (Phase A):**

- `OpReplayTests` — replay an op sequence with create/append/changeApply/claudeAccept ops; assert resulting `paragraphs` and `sequence` match `Document.load`'s output on the same input.
- `InboxEntryCodableTests` — round-trip a known InboxEntry through JSON; assert snake_case keys; assert optional fields encode as `null` not omitted (matches existing project convention).

**Mac inbox + partitioning (Phase B / B0):**

- `MaughamSidecarPathInboxTests` — classify `.maugham/inbox/inbox.jsonl`, `.maugham/inbox/inbox.<slug>.jsonl`, `.maugham/inbox/text/01HQR….md`, `.maugham/inbox/images/01HQR….jpg`, `.maugham/inbox/audio/01HQR….m4a`. Each routes to the right `InboxFileKind`.
- `InboxStoreLastWinsTests` — append three entries with the same id (status: new → promoted → trashed) split across two per-device manifest files; assert `refresh()` collapses to the last (newest createdAt across both files wins) and filters from `entries` (only `new` shows).
- `InboxStoreNotificationTests` — write a manifest entry, post `maughamInboxChanged`, assert `InboxStore.refresh()` fires and `entries` updates.
- `OpLogStorePartitioningWriteTests` — append three ops via `OpLogStore.append`; assert the writes land in `d_<docId>.<ownDeviceSlug>.jsonl`, not in a shared `d_<docId>.jsonl`.
- `OpLogStorePartitioningLoadTests` — seed three files (`d_<docId>.jsonl` legacy, `d_<docId>.macA.jsonl`, `d_<docId>.phoneB.jsonl`) each with ops carrying distinct opIds; assert `OpLogStore.load(docId:)` returns the merged-sorted-deduped set in opId order, with no missing ops and no duplicates.
- `OpLogStoreBackwardCompatTests` — load a project that has only the legacy unsuffixed file (no per-device siblings); assert behavior is byte-identical to today's single-file loader.
- `OpLogStorePartitioningParityTests` — for a given input set of ops, assert `Deriver.derive(ops:)` over the merged-from-N-files result equals `Deriver.derive(ops:)` over the same ops in a single file. (Storage representation must not change derivation output.)

**WhisperKit worker (Phase C):**

- `InboxTranscriptionWorkerEnqueueTests` — post N audio notifications in rapid succession; assert the worker processes them serially (not concurrently). Use a mock WhisperKit wrapper.
- `InboxTranscriptionWorkerFailureTests` — mock WhisperKit to throw; assert `InboxStore.updateTranscript` is called with `.failed` state and the original on-device draft is preserved.

**iOS (Phase D/E/F):**

- `ProjectsRootBookmarkTests` — round-trip a known security-scoped bookmark; assert `isStale` detection triggers the re-pick state.
- `CoordinatedFileIOTests` — concurrent reads and writes through `NSFileCoordinator`; assert no data races.
- `FountainSemanticRendererTests` — parse a known `.fountain` fixture; assert each element type styles as expected (font weight, alignment, indent).
- `AnnotationWriterRejectShapeTests` — build a `claudeReject` op via AnnotationWriter; assert the JSON matches the expected snake_case shape with the right `provenance` keys.
- `AnnotationWriterAcceptSuggestedChangeRoundTripTests` — given a `claudeCreate` op with `changes`, build a `claudeAccept` op via AnnotationWriter; run both through `Deriver.derive` and assert post-replay paragraph text equals `change.next`. Regression net for §3.9.

**iOS download infrastructure (Phase D0):**

- `DownloadCoordinatorDedupTests` — three concurrent callers request the same URL; assert one underlying download is started, all callers complete when it resolves.
- `DownloadCoordinatorBudgetTests` — exhaust the 50 MB cold-launch budget partway through a recents pass; assert subsequent `ensureDownloadedIfBudgetAllows` calls return false without triggering download. Assert lazy `ensureDownloaded` still works (ignores budget).
- `DownloadCoordinatorFailurePropagationTests` — simulate `ubiquitousItemDownloadingErrorKey` non-nil; assert `.failed` state is published and observers see it.
- `RecentsTrackerComputeTests` — seed three captured (oldest first) + four opened (two within 14 days, two beyond); assert `recents` returns the right union, captures are FIFO-capped at 5, expired opened dates drop out.
- `RecentsTrackerPersistenceTests` — round-trip `recordCapture` / `recordOpen` through `@AppStorage`-backed JSON; assert state survives a fresh tracker init.
- `CoordinatedFileIODownloadTests` — point at a mock not-downloaded URL (test fixture exposes URLResource extension), call `download(at:)`; assert poll loop completes when status reaches `.current`, throws on simulated error, throws on `Task.cancel`.
- `AnnotationsListViewBannerTests` (snapshot or behavioral) — render the view with `DownloadCoordinator` in three states (all current / partial downloading / all failed); assert the banner copy matches the §3.13 UI table.

**Cross-cutting:**

- `BuildVariantPhoneTests` — `phoneBundleId` and `bookmarkUserDefaultsKey` differ between `.dev` and `.stable`.
- `TripwirePhoneGrepTest` — runs `grep -n '"maugham"\|"Maugham"' MaughamPhone/` excluding `BuildVariantPhone.swift` and tests; asserts zero hits. Mirrors the existing Mac-side tripwire 13 enforcement.

### 7.2 New integration tests

- `InboxPaneIntegrationTests` — drop an InboxEntry + audio file into a test project's `.maugham/inbox/`; assert `InboxPane` displays the row with correct icon, title, and timestamp.
- `AnnotationDetailRaceTests` — open `AnnotationDetailView` with status `.open`; simulate an external op append flipping status to `.archived`; assert next `.onAppear` shows "Already resolved" and hides buttons.
- `PhoneOpAppendIntegrationTests` — phone writes a `claudeReject` op to a test `.maugham/ops/d_….jsonl`; load via Mac-side `Document.load`; assert `AnnotationDeriver` sees status `.rejected` with the expected `userResponse`.

### 7.3 CI workflow self-test

The first end-to-end run of `phone-release.yml` is the integration test for the CI pipeline. The plan calls for cutting `phone-v0.1.0` as the final task in Phase G. If the workflow has bugs (missing secret, wrong export options plist, ASC API misuse), they surface there.

A pre-cut "dry run" tag (`phone-v0.0.1-dev`) is useful to test the workflow without committing to a real version number — push the tag, watch the workflow run end-to-end (including TestFlight upload), then delete both the tag and the TestFlight build before cutting `phone-v0.1.0`.

### 7.4 Manual smoke

After milestone 4 ships and `phone-v0.1.0` is live in TestFlight:

1. Install MaughamPhone on a real iPhone via TestFlight.
2. Settings → Choose Projects Folder → pick an iCloud Drive folder containing a real Maugham project.
3. Read tab → projects list populates → tap a project → binder appears → tap a manuscript → Markdown renders, paragraph anchors not visible. Open a `.fountain` → semantic styling correct (scene heading bold + uppercased, character centered + bold, dialogue indented, parenthetical italic + further indented).
4. Capture tab → quick text "Test from phone" → Save. Within ~30s, Mac (with the project open) shows the entry in InboxPane (⌘⌥6).
5. Capture → photo → take a photo. Mac InboxPane shows thumbnail.
6. Capture → voice → record 10s. On phone, draft transcript appears within ~1s of Stop. On Mac, draft appears in InboxPane immediately on sync; WhisperKit transcript replaces it within ~30s of first run (longer if model is downloading), ~5s of subsequent runs.
7. Mac: right-click row → Promote to research → file moves into `research/`, Research pane shows it, InboxPane removes the row.
8. Mac: invoke Claude via MCP to add a `suggestedChange` annotation on a paragraph.
9. Phone: Annotations tab refreshes (pull down or background/foreground) → annotation appears under the project name.
10. Phone: tap annotation → detail view shows paragraph context (prior text + suggested text) → tap "Reject…" → enter reason "Doesn't match the character's voice." → Save.
11. Mac: within sync window (~10–30s), AnnotationsPane (⌘⌥2) shows the annotation as rejected with the user response visible.
12. Race smoke: on Mac, open the same annotation in the AnnotationsPane. On phone, open its detail view. Mac: Archive the annotation. Wait ~30s. Phone: tap Accept. Refresh the list. Annotation should be classified as accepted (later ULID wins); document this in the spec's known-behavior list (Race 1 in §5.3).
13. Phone: airplane mode on. Tap capture → save text → assert UI shows a "queued" indicator (the file is written locally but iCloud hasn't synced). Disable airplane mode. Within ~30s, Mac sees the entry. (This validates the offline-write path.)
14. **Eviction smoke.** On the phone, Settings → General → iPhone Storage → "Offload App" the test build (or wait ~7 days unused, or fill the device near capacity to force eviction). Reinstall / relaunch. Open the Annotations tab. Assert: header banner shows "Syncing N of M projects from iCloud…", recents projects' annotations stream in as their op logs download (50 MB cap respected), non-recent projects appear under "Other projects (tap to load)" with no annotations shown until tapped. **The tab never silently shows an empty list while op logs are still downloading.** Then open a manuscript in the Read tab: assert "Downloading <docname>…" view appears, Cancel works, completion renders the doc.

---

## 8. Out of scope (deliberate)

- **Manuscript editing from the phone.** Phone is read-only for manuscripts. Editing requires Bootstrap funnel + ¶id anchors + conflict-on-unanchored-edit handling; building all of that on iOS is a separate milestone, possibly never. The annotation layer is the phone-shaped contribution to manuscripts.
- **Cross-project search on the phone.** In-document search via `String.range(of:)` is fine for v1. Cross-project requires an index strategy.
- **iOS `NSFilePresenter`.** Live updates to the phone when the Mac writes would require background-mode work or accepting that updates only fire while foregrounded. v1's `.task`/pull-to-refresh is sufficient.
- **WhisperKit chunking for >5min audio.** Long recordings degrade. Phase H if it becomes a real-world problem.
- **App Store submission.** TestFlight is the v1 target. App Store requires privacy policy URL, App Store metadata polish, and App Review.
- **Bundled iOS Claude Desktop / MCP integration.** Claude Desktop is desktop-only; the phone doesn't run MCP. The annotation layer is the cross-process surface that makes this irrelevant.
- **Fountain full theatrical pagination on iOS.** Doesn't fit a phone screen. Semantic styling is the right tier for mobile reading; full pagination is a third-party app concern (Highland, Slugline).
- **Inbox trash restore.** Trash is one-way in v1. Restore is a Phase H follow-up.
- **Custom Fountain themes / font controls on iOS.** System fonts, system colors. Polish later.
- **Migration of existing data formats.** Per CLAUDE.md tripwire 11, no migration logic. Existing projects without `.maugham/inbox/` just don't have one until the first capture creates it. Existing op logs are unchanged.
- **Beta channel / TestFlight external groups beyond the initial set.** Internal testing only at launch (≤100 testers, no Beta App Review delay). External groups can be added later additively.
- **Live activity / widget / Lock Screen surfaces on iOS.** Not in v1.
- **Watch app.** Not in v1, probably never.
- **Background App Refresh / background downloads.** iOS only downloads iCloud Drive files while the app is foregrounded (no NSFilePresenter on iOS in v1, no background-modes opt-in). Writers returning from offline see a brief sync wait on next launch instead of "everything was ready when I opened it." Phase H if it becomes a real complaint.
- **Per-device cold-launch budget tuning.** 50 MB is a fixed cap for all devices regardless of free space, plan, or device class. Adequate in practice; revisit if heavy-history projects hit it routinely.
- **`NSURLUbiquitousItemDownloadRequestedKey` pinning.** No documented API for "tell iOS never to evict this file." Recents-driven proactive downloads are the v1 substitute (frequent reads naturally avoid eviction).

---

## 9. Open questions for the implementation plan

None blocking. Items to confirm during planning:

- **`ProjectFolderPresenter` subscription scope.** §3.12 assumes directory-level subscription to `.maugham/ops/` and `.maugham/inbox/` so that brand-new per-device files trigger `presenterDidChangeSubitem`. CLAUDE.md tripwire #7 implies this is already the case, but verify in Phase B0 before committing the partitioning contract.
- **`deviceSlug` exact form.** `Document.device` already exists as a per-install identifier; the slug is a sanitized filename-safe form (likely lowercased UUID-no-dashes, optionally truncated). Decide exact form at implementation time. Constraint: stable per install across launches so a device's own files stay addressable.
- **WhisperKit model default.** Spec defaults to `openai_whisper-base` (~150MB) for first-run quality/size tradeoff. Worth a one-time A/B between `base` and `small` to confirm the default is right. Either is one-line in Settings.
- **TestFlight upload mechanism.** Spec uses `xcrun altool --upload-app`, but `altool` is being deprecated in favor of `notarytool` and direct App Store Connect API calls. Confirm during Phase G which is current in the chosen Xcode version on `macos-14`.
- **Coordinated-write deadline tuning.** `NSFileCoordinator` writes have an implicit timeout; iCloud Drive folders under heavy sync can occasionally be slow. Decide whether to set a custom `purposeIdentifier` to group coordinated operations. Default is fine for v1; revisit if writes time out in real use.
- **App Store Connect Beta App Information minimum.** Confirm the exact set of mandatory fields (privacy URL, demo account, beta description) before the first upload — fewer surprises at upload time. Document in `docs/release-notes/phone/SETUP.md`.
- **Whether to move `OpLog` and `Fountain` tests into `Packages/MaughamCore/Tests/MaughamCoreTests/`.** Defer. v1 keeps them in `MaughamTests/` via `@testable import Maugham`. Cleanup is a follow-up.
