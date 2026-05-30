# Maugham iPhone Companion — v1 plan

> ## 🚦 STATUS (2026-05-29) — read this first
>
> **Phases A, B0, B, C are SHIPPED and merged to `main`** (merge `98128d1`,
> "Milestone 2 — MaughamCore + inbox + WhisperKit"; ~1463 tests; smoke Tiers 1–3
> verified). See `memory/project_milestone_iphone_companion_mac.md`.
>
> **Phase D0 is SHIPPED on branch `feat/iphone-companion-ios`** (not yet merged;
> commits `66193b5`..`d9603ef`). The iOS storage substrate for iCloud-Drive
> eviction handling (§3.13) is done + green: a minimal `MaughamPhone` app target +
> `MaughamPhoneTests` (iOS 17, both on MaughamCore), `DownloadCoordinator` (actor;
> dedup + 50 MB budget + AsyncStream observation, behind the `UbiquitousDownloader`
> seam), `CoordinatedFileIO` + `UbiquitousFileSystem` (the production download/poll
> conformer behind a second seam), and `RecentsTracker`. 21 MaughamPhone tests
> green; Mac suite still 1464 green (no regression). Two-stage review done per task.
>
> **Phase D is SHIPPED on branch `feat/iphone-companion-ios`** (not yet merged;
> commits `92e6b1b`..`1212b46`). The iOS **capture app** is done + green:
> `BuildVariantPhone` (bundle-id/bookmark-key knobs), `ProjectsRoot` (security-scoped
> bookmark lifecycle behind a `BookmarkResolving` seam), `CoordinatedFileIO`
> NSFileCoordinator read/write/appendLine wrappers, `ProjectsBrowser` (id→manifest
> map), `InboxCaptureWriter` + `PhoneDeviceID` (phone→inbox writer; per-device JSONL,
> monotonic `writtenAt`, assets — verified Mac-reader-compatible by round-tripping
> through `JSONLAppendStore<InboxEntry>`), the **Capture tab** (text/photo/voice
> sheets + project pill/picker + permissions), `ColdLaunchDownloader`, the wired
> `MaughamPhoneApp` (shared stores + §3.13 cold-launch sequence), and the **Settings
> tab**. **56 MaughamPhone tests green; Mac suite still 1464 green** (no regression).
> Holistic final review: ready-with-notes, end-to-end capture path + on-disk format
> + @MainActor/shared-instance all confirmed. Read/Annotations tabs are placeholders.
>
> **Phase E is SHIPPED on branch `feat/iphone-companion-ios`** (not yet merged;
> commits `e8c60a5`..`ca6e965`). The iOS **Read tab** is done + green: pure helpers
> (`ParagraphAnchorStripper` matching the real `<!-- ¶id -->` format,
> `FountainStyler` §3.8 element→style mapping, `BinderRouting`), `DocumentReaderView`
> (download-gated: `ensureDownloaded` + `observe` progress + Cancel → `coordinatedRead`
> → anchor-stripped Markdown via `AttributedString` / Fountain parsed once in `.task`,
> tripwire 4), `FountainSemanticRenderer`, `ProjectsListView` (refresh-on-appear +
> pull-to-refresh — closes a D carry-forward) and `BinderView` (StructureItem tree +
> Research section; `recordOpen` wired — closes another). **92 MaughamPhone tests
> green; Mac suite still 1464 green** (no regression). Holistic final review:
> ready-with-notes; read-path trace + tripwire-4 + download-gate + @MainActor/shared
> instances all confirmed. Annotations tab is still a placeholder.
>
> **Phase F is SHIPPED on branch `feat/iphone-companion-ios`** (not yet merged;
> commits `a06c7da`..`d533834`). The iOS **Annotations tab** (the milestone's
> correctness-critical phase) is done + green: `Deriver` promoted to MaughamCore
> (shared op-replay) + `Op.Provenance.appVersion/osVersion`; `AnnotationWriter`
> (Accept/Reject/Archive ops, per-device coordinated append, **fail-loud** on a
> malformed suggestedChange); `AnnotationsListView` + `AnnotationDetailView`
> (cross-device race-collapse re-derive); `LaunchAuthGate` (opt-in Face ID, 5-min
> relock, fail-open); Settings "Security" + `NSFaceIDUsageDescription`. **120
> MaughamPhone tests green; Mac suite still 1467 green** (no regression). F.2 got
> the dual-reviewer treatment; the load-bearing `claudeAccept`-copies-`changes`
> round-trip is pinned, and an **integration test caught a real cross-device bug**
> (op-log filename `d_` double-prefix would have silently dropped every phone
> write — the unit round-trip missed it by bypassing the filename via Deriver).
>
> **The capture + read + annotation-review app is feature-complete.** The only
> remaining work is **Phase G** (CI/release: `phone-v0.X.Y` tag namespace,
> `phone-release.yml` GH Actions → TestFlight, signing secrets, `cut-phone-release.sh`).
> Phase G is a CI/signing/distribution phase, not app code.
>
> **Carry-forwards into Phase G / future (final-review-surfaced):**
> - **`AnnotationDetailView.rederive()` doesn't `ensureDownloaded`** before reloading
>   the op log — a freshly-evicted Mac resolution may be missed on first open (the
>   "Already resolved on another device" won't show). Double-resolve is non-catastrophic
>   (last-resolution-wins); pre-fault the doc's op-log URLs to close it.
> - **Sync `coordinatedAppendLine` runs on the main actor** in AnnotationWriter +
>   InboxCaptureWriter (~200-byte append; accepted prior art). A `nonisolated async`
>   overload on `CoordinatedFileIO` would move it off-main.
> - **Banner is computed-not-live** (recomputed on reload/pull-to-refresh, not a live
>   iCloud state subscription); **"Other projects" loads eagerly** (all bookmarked
>   projects, not lazy). Both acceptable for v1; note in G release notes.
> - **Query "Mark answered" routes through `claudeAccept`** (reply → `userResponse`) —
>   confirm the Mac AnnotationsPane renders `.accepted` on a `.query` correctly in the
>   G smoke.
> - **Manual smoke (spec §7.4 steps 7–14)** — the capture/read/annotation/race/auth/
>   eviction smokes — are the user's to run once a TestFlight build exists (Phase G).
>
> **Carry-forwards into Phase F (final-review-surfaced):**
> - **In-doc search is Fountain-only** (Markdown highlight is a TODO in
>   `DocumentReaderView`); not needed for annotations but note it.
> - **Cold-launch op-log prefetch is best-effort** — the Annotations tab MUST run
>   its own `ensureDownloaded` + §3.13 download banner per op-log file; don't assume
>   the prefetch made them local.
> - **`ProjectsBrowser.manifestFileName = "project.maugham.json"`** is a local literal
>   (drift risk) — Phase F will read more sidecar paths (`.maugham/ops/d_*.jsonl`);
>   resolve them through a shared constant / `MaughamSidecarPath` rather than new
>   literals. `OpReplay.buildState(ops:)` still needs adding to MaughamCore (spec
>   §3.9 / critical-files) — it does NOT exist yet.
> - **`"path:"`-fallback project ids** (for manifests the Mac hasn't re-opened since
>   the `id` field shipped) won't match a later Mac-minted `ProjectManifest.id` —
>   don't assume fallback ids are stable across Mac reopens when reconciling
>   annotation `projectId` references.
> - Research flattening drops group headers; `visibleLines` recomputes per body
>   pass (sub-ms; fine) — minor, revisit only if Phase F adds annotation overlays.
>
> **Carry-forwards into Phase E/F (final-review-surfaced):**
> - **`RecentsTracker.recordOpen` is never called yet** — Phase E's Read tab MUST
>   call it on project/doc open so cold-launch prefetch stays warm for reading,
>   not just capture.
> - **`ProjectsBrowser` only refreshes at cold launch** — a project added to iCloud
>   since launch won't appear. Phase E should call `refresh(root:)` on the Read
>   tab's (and the picker's) `.task`/appear.
> - **Cold-launch op-log prefetch is best-effort/fire-and-forget** — Phase F's
>   Annotations tab must render the §3.13 download/`.downloading` banner itself
>   (don't assume op logs are already local).
> - **`@AppStorage("currentProjectId")` uses an empty-string sentinel** (not nil) —
>   Phase E must guard `!isEmpty` like `CaptureView.selectedProject` does.
> - **`ProjectsRoot` never calls `stopAccessingSecurityScopedResource`** — fine for
>   a single lifetime-held folder grant; revisit when Phase E reads many docs across
>   background/foreground transitions.
> - **`ProjectsBrowser.refresh` enumerates child dirs un-coordinated** — a partial
>   listing is possible mid-iCloud-sync; low risk, note for Phase E.
> - Pre-existing (not Phase D): `InboxStore`/`InboxEntry` header comment says
>   "last-wins by createdAt" but the merge actually orders by `writtenAt` — a Mac-side
>   doc fix worth making when next touching that file.
>
> **Carry-forwards from D0 into Phase D (review-surfaced; none block D0):**
> - **`RecentsTracker.openedDates` is never pruned** — stale entries outside the
>   14-day window accumulate. Negligible for v1; prune on load/`recordOpen` when
>   convenient.
> - **`CoordinatedFileIO` file-deleted-mid-poll → infinite `0.0`** — if a file
>   vanishes between start and poll, `resourceValues` returns nil-status forever
>   (no `.current`, no error). Add a `fileExists`/max-retry guard when the
>   NSFileCoordinator read/write wrappers land here (noted in commit `d48a507`).
> - **`UbiquitousDownloader.fileSize` returns `Int64?`** — the cold-launch driver
>   must pick a `sizeHint` convention when size is nil (0 = always passes the
>   budget gate, vs. a conservative estimate). Document the choice in Phase D.
> - **`RecentsTracker.recents` is `@MainActor`** — the cold-launch Task must hop
>   `await MainActor.run { tracker.recents }` before walking op-log URLs off-main.
> - **`MaughamPhone/Info.plist` permission strings hardcode "Maugham"** — they read
>   "Maugham" even in dev builds (display name "Maugham Dev"). Fix via
>   `$(MAUGHAM_DISPLAY_NAME)` / a strings file when `BuildVariantPhone.swift` lands.
> - Phase D still owes `BuildVariantPhone.swift` (phone bundle ids + bookmark keys),
>   `ProjectsRoot`/`ProjectsBrowser`, and `CoordinatedFileIO`'s NSFileCoordinator
>   read/write wrappers (marker comment in place).
>
> **Settled facts for the iOS session — read the shipped types, don't re-derive:**
> - `Packages/MaughamCore` is the Foundation-only shared package; the new
>   `MaughamPhone` target (Phase D, doesn't exist yet) depends on it. WhisperKit
>   is a **Mac-target-only** dep — do **not** add it to MaughamPhone.
> - **`InboxEntry`** (`MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift`)
>   is the capture schema the phone writes. It gained two fields beyond this
>   plan's original §B bullet: **`writtenAt`** (row-write time; the phone MUST
>   stamp it — it orders the last-wins merge, and it must be **monotonic per id**
>   to survive phone/Mac clock skew, see the clock-skew fix) and
>   `transcriptionState.userEdited`. The phone writes rows + assets to
>   `.maugham/inbox/` (inline text; `images/`; `audio/`) and its **own**
>   `inbox.<deviceSlug>.jsonl`.
> - **Op log is per-device partitioned** (`d_<docId>.<deviceSlug>.jsonl`, ADR
>   0012 — implemented). The phone writes annotation-lifecycle ops to its **own**
>   per-device file (Phase F). Shared helpers in MaughamCore: `OpLogStore`
>   (`opLogFileURLs`/`loadSyncMerged`), `DeviceSlug.make`.
> - **`ProjectManifest.id`** (minted ULID) exists — key project selection on it.
> - Inbox MCP surface is read+promote (`list_inbox`/`read_inbox_entry`/
>   `promote_inbox_entry`); catalog is 43 tools.
> - Deferred Mac-side (won't block the phone): InboxPane attach-to-document;
>   WhisperKit proactive-download/HUD/offline-chip/auto-retry/long-audio-chunking.
> - The Phase D–G bullets below predate some implementation detail — when they
>   conflict with a shipped MaughamCore type, the **shipped type wins**.

## Context

> **Validation update (2026-05-29).** Re-checked against `main` after the tasks + publishing
> milestones shipped. Corrections folded in below: code-line citations refreshed
> (`Deriver` 121–132 / 25–32, `Document.acceptAnnotation` 1425–1473, `presenterDidChangeSubitem`
> 501–546); `MaughamSidecarPath` is now 18 cases (publishing added 7), `.inbox` is still a
> one-case add; per-device JSONL partitioning (Phase B0) is confirmed **not yet shipped**
> (ADR 0012 Accepted, unimplemented); detail-pane shortcuts are **⌘⌥1** inspector / **⌘⌥2**
> research / **⌘⌥3** outline / **⌘⌥4** history / **⌘⌥5** tasks / **⌘⌥A** annotations
> (history + tasks shortcuts live on the `DetailPaneToggle` picker images, not the
> `MaughamApp` menu — the first validation pass missed them) — inbox takes the next
> free **⌘⌥6**; iPhone tripwires renumber to **#17 + #18** (main is through #16); and
> `ProjectManifest` has **no `id` field** — Phase A adds an optional minted `id`
> (additive optional field, schema stays 1 per the `typography` precedent) so project selection can key on it.

Maugham is a Mac writing app whose primary use is at-the-desk focus work, but the writer wants a phone surface for the things a desk app can't reach:

- **Capture out-and-about** — quick text, photos, and voice notes that would otherwise be lost
- **Review on the go** — reading manuscripts and research from anywhere
- **Annotation triage** — accepting / rejecting / archiving Claude's open annotations away from the desk
- **Future** — when Mac-side human-authored annotations land, the phone is a natural primary surface for them

Maugham's architecture already supports this surprisingly well: the op log is plain JSONL with a documented snake-case schema, iCloud Drive is the existing sync substrate, and the annotation layer + `research/` are exactly the "Claude-shaped" non-manuscript surfaces a phone should write through. The manuscript itself stays Mac-only (Bootstrap / ¶id-anchor minting and the conflict-on-unanchored-edit contract make phone-side editing unsafe).

User decisions baked in:
- v1 covers all three capabilities (capture + read + annotation review) from day one
- Captures land in a new `.maugham/inbox/` triage sidecar; Mac surfaces a triage pane
- Voice: phone records `.m4a` + an immediate on-device `SFSpeechRecognizer` draft; **Mac re-transcribes with WhisperKit (local Apple Silicon, no API keys)** and replaces the draft
- Sync: iCloud Drive only — `UIDocumentPicker` + security-scoped bookmark + `NSFileCoordinator` on iOS; no shared iCloud container (preserves the "project folder anywhere" invariant)
- Fountain rendering: semantic tier (existing parser + SwiftUI styling), not pagination
- Distribution: TestFlight (personal/friends), App Store-eligible but not the immediate target

## Architecture at a glance

Four coordinated changes:

1. **Extract `Packages/MaughamCore`** — a Foundation-only SPM package the Mac and iOS apps share. Houses Op/OpKind/Provenance, JSONLAppendStore, AnnotationDeriver, Materializer, Bootstrap, ParagraphID, ULID, BuildVariant, ProjectManifest, ResearchItem, Slugifier, and the Fountain parser (`FountainTokenizer`, `FountainLine`, `FountainScript`, `ScreenplayElement`). AppKit-bound files (`Document`, `ScreenplayMode`, `ScreenplayLayoutManager`) stay in the Mac target.
2. **Per-device JSONL partitioning** — `OpLogStore` and the new `InboxStore` write to per-device files (`d_<docId>.<deviceSlug>.jsonl`, `inbox.<deviceSlug>.jsonl`) and merge on load. Prevents iCloud Drive conflict-twins from silently dropping ops when both phone and Mac write simultaneously. Spec §3.12 + ADR 0012.
3. **Mac additions** — new `.inbox` case on `MaughamSidecarPath`, `InboxStore`, `InboxPane` right-pane mode (⌘⌥6), WhisperKit-backed `InboxTranscriptionWorker`.
4. **iOS app** — new `MaughamPhone` target in the same `project.yml`, four-tab SwiftUI app (Capture / Read / Annotations / Settings), reads/writes the bookmarked project folder via `NSFileCoordinator`.

Verified prerequisites (confirmed during planning):
- Mac app has **no iCloud entitlement** today — projects live at writer-chosen paths. iOS uses `UIDocumentPicker` to bookmark any folder, including iCloud Drive ones. No Mac-side change needed.
- Fountain parser is Foundation-only (zero AppKit imports). Extractable as-is.
- `MaughamSidecarPath` is a single classify-site enum; adding `.inbox` is one case + one switch arm in `DocumentStore.presenterDidChangeSubitem`.
- `Deriver.appliesToManuscript` already includes `.claudeAccept` (`Deriver.swift:121-132`). Phone-written accept ops materialize on Mac restart with zero Mac code change — provided the phone copies the creation op's `changes` array verbatim. Resolved during planning; not a Phase F open question.

## Phased implementation

### Phase A — `MaughamCore` extraction (foundation, highest blast radius) — ✅ SHIPPED (@98128d1)

Create `Packages/MaughamCore/` SPM package. Move the Foundation-only files listed above out of `Maugham/OpLog/`, `Maugham/Editor/Fountain/`, `Maugham/Models/`, and `Maugham/BuildVariant.swift` into the package. Both Mac and iOS targets depend on it. Run `./gen.sh`, fix imports across `Maugham/`, run full `xcodebuild test` + the manual smoke from CLAUDE.md. Do this as one focused PR — don't combine with anything else.

**One non-mechanical addition** (the lone behavior change permitted in this phase, kept small): `ProjectManifest` has no stable identifier today — projects are addressed by folder path, and collection links (`CollectionLinkFile`) use a security-scoped bookmark + absolute path. The phone needs a logical id that survives rename/move within the bookmarked root (capture selection + recents key on it). Add `public var id: String?` (a minted ULID) to `ProjectManifest` and mint-on-load when nil in `ProjectStore.load` so both new projects (ProjectFactory writes id-less, load backfills) and existing projects acquire an id on next open. **Schema stays 1** — this follows the established convention (1d added the optional `typography` field without a version bump because older Maugham tolerates unknown fields). Additive and backward-compatible — old manifests decode with `id == nil`, no migration (CLAUDE.md tripwire 11). `ProjectManifestIdTests` asserts decode-nil-when-absent, Codable round-trip, and that the minted id persists to disk and is **stable across reloads** (not re-minted). Manifest `modified` is left untouched by the backfill (an id mint is not a content edit), preserving the milestone-1a ISO8601 whole-second round-trip.

### Phase B0 — Per-device JSONL partitioning (Mac only, prerequisite for any phone writes) — ✅ SHIPPED (@98128d1)

Foundational. Must land before Phase D so the phone never writes to a shared file. Spec §3.12 + ADR 0012.

- `Maugham/OpLog/OpLogStore.swift` — `load(docId:)` globs `.maugham/ops/d_<docId>*.jsonl` (matches legacy `d_<docId>.jsonl` + new `d_<docId>.<deviceSlug>.jsonl`), reads each via `JSONLAppendStore`, merges with opId dedupe + opId sort. `append(_:)` targets the writer's own per-device file.
- `Maugham/Stores/ProjectFolderPresenter.swift` — verify directory-level subscription on `.maugham/ops/` so new per-device sibling files trigger `presenterDidChangeSubitem` the first time they appear. If not, broaden.
- Backward compat — existing `d_<docId>.jsonl` files are included in the glob. No migration logic (CLAUDE.md tripwire 11).
- Manual test: write to a project from one device, then synthesize a "second device" file (`d_<docId>.fake.jsonl` with a few ops) by hand; confirm Mac merges both on next load, opIds sort correctly, derived state matches.

### Phase B — Inbox plumbing (Mac only) — ✅ SHIPPED (@98128d1)

- `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift` — Codable: `id` (ULID), `createdAt`, `deviceId`, `kind` (text/image/audio), `sourceFilename`, `inlineText`, `transcript`, `transcriptionState` (none / on_device_draft / whisper_final / failed), `title`, `status` (new / promoted / trashed), `resolvedAt`. snake_case keys to match Op convention.
- `Maugham/Stores/MaughamSidecarPath.swift` — add `case inbox(kind: InboxFileKind, relativePath: String)`; extend `classifySidecar` with `.maugham/inbox/` branches (matches `inbox.jsonl` + `inbox.<slug>.jsonl`).
- `Maugham/Stores/DocumentStore.swift` — add a `case .inbox` arm in `presenterDidChangeSubitem` (currently lines 501–546) that posts `Notification.Name.maughamInboxChanged`.
- `Maugham/Stores/InboxStore.swift` (new) — owned by `DocumentStore`. Globs `.maugham/inbox/inbox.*.jsonl` (per-device partitioning, same pattern as OpLogStore from Phase B0). Writes go to the Mac's own `inbox.<deviceSlug>.jsonl`. Two-layer merge: per-file via `JSONLAppendStore` first-wins, cross-file via InboxStore last-wins (newest createdAt per id). Methods: `refresh`, `promoteToResearch(_:)` (delegates to `ProjectStore.addResearchAsset`), `trash(_:)`, `attachToCurrentDoc(_:)`, `updateTranscript(id:text:state:)`.
- `Maugham/Views/InboxPane.swift` (new) — right-pane mode, rows show kind icon + title + transcript preview + timestamp + trailing menu (Promote / Attach / Edit transcript / Trash). Empty state with `ContentUnavailableView` pointing at the phone.
- Add `.inbox` to `DetailSegment` (`Maugham/Models/DetailSegment.swift`) + a picker image in `DetailPaneToggle.swift` with `.keyboardShortcut("6", modifiers: [.command, .option])`. Real current map: ⌘⌥1 inspector, ⌘⌥2 research, ⌘⌥3 outline, ⌘⌥4 history, ⌘⌥5 tasks, ⌘⌥A annotations. **Shortcuts for history/tasks/inbox live on the `DetailPaneToggle` picker images** (`.keyboardShortcut` modifiers), *not* the `MaughamApp` menu commands (which only cover inspector/research/outline/annotations) — so inbox follows the history/tasks pattern with a picker-image shortcut, no `MaughamApp` change. Inbox takes the next free **⌘⌥6**.

Manual test by dropping a file + JSONL line into `.maugham/inbox/` (either the per-device file or the legacy unsuffixed name) — no phone code yet.

### Phase C — WhisperKit on the Mac — ✅ SHIPPED (@98128d1; detailed plan in `2026-05-29-phone-phase-c-whisperkit.md`)

Refined in the 2026-05-29 brainstorm (spec §3.5): protocol seam + "Middle"
download UX + `.userEdited` edit protection. Built as **two commits** so the
external WhisperKit fetch is isolated from the testable worker logic.

**Commit 1 — worker logic, no external dependency (builds + tests in any environment):**
- `Packages/MaughamCore/.../Transcriber.swift` (new) — `protocol Transcriber { func transcribe(_ audio: URL, model: String) async throws -> String }`. Foundation-only.
- `Packages/MaughamCore/.../Inbox/InboxEntry.swift` — add `TranscriptionState.userEdited` (raw `user_edited`).
- `Maugham/Views/InboxPane.swift` — Edit Transcript now sets `.userEdited` (was: preserve state).
- `Maugham/Stores/InboxTranscriptionWorker.swift` (new) — serial `Task` queue subscribed to `maughamInboxChanged` (`kind == .audio`), injected with a `Transcriber`. Eligibility: `transcriptionState ∈ {.none, .onDeviceDraft}` (skips `.whisperFinal`/`.userEdited`; re-scan on each notification doubles as retry). Success → `InboxStore.updateTranscript(…, .whisperFinal)`; failure → `.failed`, draft preserved. Model default `base`; storage `~/Library/Application Support/<BuildVariant.supportFolderName>/WhisperModels/`. Intel → `.failed` + one-time `os_log`.
- `DocumentStore` owns/starts the worker (one per window), injecting the production transcriber (or, in commit 1, a stub) — wire so tests can inject a mock.
- `MaughamPhone`/Settings "Voice transcription" section: model picker (`base`/`small`/`large-v3`) + live download progress + status + "Download now". (Mac Settings; the worker exposes model state.)
- Tests (vs `MockTranscriber`): serial queueing, success→`.whisperFinal`, failure→`.failed`+draft kept, eligibility skips `.whisperFinal`/`.userEdited`, retry-on-next-change.

**Commit 2 — the real transcriber + dependency (isolated; the only step with external-fetch risk):**
- Add WhisperKit (`https://github.com/argmaxinc/WhisperKit`) as an SPM dependency on the **Mac target only**.
- `Maugham/Stores/WhisperKitTranscriber.swift` (new) — thin `Transcriber` conformer wrapping WhisperKit (lazy model download-then-transcribe in the job). Inject in production.

Deferred → future enhancement (spec §3.5): proactive-launch download, first-audio HUD alert, offline row chip, auto-retry of `.failed`, long-audio chunking, telemetry smoke.

Manual test: drop a `.m4a` into `.maugham/inbox/audio/`, watch the transcript replace the draft.

### Phase D0 — iCloud Drive eviction handling (iOS-only infrastructure, prerequisite for D/E/F reads)

Foundational on the iOS side. Spec §3.13. Without it, the Annotations tab silently shows "no annotations" when op-log files are evicted iCloud Drive placeholders.

- `MaughamPhone/Storage/DownloadCoordinator.swift` (new) — `@MainActor actor` tracking per-URL download state (`notDownloaded` / `downloading` / `downloaded` / `failed`), dedupes concurrent requests for the same URL, enforces a 50 MB cold-launch budget for proactive op-log downloads. Lazy `ensureDownloaded(_:)` ignores budget.
- `MaughamPhone/Storage/CoordinatedFileIO.swift` — gains `download(at:) async throws` helper wrapping `FileManager.startDownloadingUbiquitousItem` + `URLResourceKey.ubiquitousItemDownloadingStatusKey` polling. Cancellation-aware, exponential poll-interval backoff.
- `MaughamPhone/Storage/RecentsTracker.swift` (new) — `@Observable` owner of `@AppStorage("recentProjectIds")` (last 5 captured-into, FIFO) and `@AppStorage("lastOpenedDates")` (`[ProjectId: Date]`). Derives `recents: Set<ProjectId>` = captures ∪ projects opened within the last 14 days. `ProjectId` is the minted `ProjectManifest.id` added in Phase A (stable across rename/move), **not** a folder path.
- Manual test: install on phone, capture into a project, force "Offload App" via Settings → iPhone Storage, reinstall. On relaunch the cold-launch sequence (manifests then recents' op logs) runs; Annotations tab shows progress banner; never silently empty.

### Phase D — iOS app: capture

- New `MaughamPhone` target in `project.yml`. iOS 17 deployment. Privacy strings: mic, speech recognition, camera, photo library, Files.
- iOS-only `BuildVariantPhone.swift` extension — phone bundle ids (`com.maugham.MaughamPhone[.dev]`) and per-variant bookmark UserDefaults keys. Don't reintroduce hardcoded "maugham" strings (tripwire 13).
- `MaughamPhone/Storage/ProjectsRoot.swift` — wraps `UIDocumentPicker(forOpeningContentTypes: [.folder])`, persists security-scoped bookmark, checks `isStale` every launch and re-prompts if needed.
- `MaughamPhone/Storage/ProjectsBrowser.swift` — lists subdirectories containing `project.maugham.json`, decodes `ProjectManifest`. Manifest reads route through `DownloadCoordinator.ensureDownloaded` (Phase D0) so an evicted placeholder triggers a fetch instead of silently appearing as "no projects."
- `MaughamPhone/Capture/CaptureView.swift` — three buttons: text (TextEditor sheet), photo (`PhotosPicker` / camera), voice (`AVAudioRecorder` → `.m4a` with pre-commit playback/transcript-edit screen). On commit: write file + append `InboxEntry`; `RecentsTracker.recordCapture(into:)`. Voice path additionally runs `SFSpeechRecognizer` for an immediate `on_device_draft` transcript.
- Settings tab: choose-folder, permissions status, build variant indicator.

End-to-end test: capture on phone → file appears in `.maugham/inbox/` → Mac InboxPane shows it → WhisperKit transcribes audio within iCloud sync window + ~10s.

### Phase E — iOS app: read

- `MaughamPhone/Read/ProjectsListView.swift` → `BinderView.swift` (renders `ProjectManifest.structure: [StructureItem]`) → `DocumentReaderView.swift`.
- `DocumentReaderView.task` calls `DownloadCoordinator.ensureDownloaded` for the doc URL (Phase D0); shows full-screen "Downloading <docname>… <progress>" with Cancel button while it resolves. After: reads `.md` / `.fountain` directly. Strips `<!-- ¶id -->` anchors before rendering. Markdown via `AttributedString(markdown:)`.
- For `.fountain`: instantiate `FountainTokenizer` from `MaughamCore`, render each `FountainLine` with semantic SwiftUI styling — scene heading bold + uppercased, character bold + centered, dialogue indented, parenthetical italic + indented further, action plain, transition right-aligned. **Cache the parsed `FountainScript` in `@State`, populate via `.task`** — never re-parse in a row body (tripwire 4).
- Tapping into a project's binder fires `RecentsTracker.recordOpen(_:)` so the recents heuristic learns about read patterns, not just capture patterns.
- Cross-document search deferred to a later milestone; in-document `String.range(of:)` is fine for v1.

### Phase F — iOS app: annotation review

- `MaughamPhone/Annotations/AnnotationsListView.swift` — walks every bookmarked project's per-device op-log files (`.maugham/ops/d_*.jsonl` glob, §3.12), observes `DownloadCoordinator.states` to render the §3.13 progress banner, builds derived annotation list via `AnnotationDeriver.derive(ops:paragraphs:)`. To produce `paragraphs:`, share a small `OpReplay.buildState(ops:) -> (paragraphs, sequence)` helper in `MaughamCore` (Mac side already does the same logic inside `Document.load`). Filter to `.open` status, group by project. Recent projects (cold-launch downloaded) shown first; non-recent projects under "Other projects (tap to load)" trigger lazy download.
- `AnnotationDetailView.swift` — shows paragraph context (`priorText`, `suggestedText`), body, three buttons (Accept / Reject… / Archive); Reject shows a reason sheet, Query shows a Reply sheet. **Re-derive status on view appearance** to collapse the cross-device race window — if `status != .open`, hide buttons and show "Already resolved on another device." `.onAppear` fires `RecentsTracker.recordOpen(_:)` for the parent project.
- `MaughamPhone/Auth/LaunchAuthGate.swift` (new) — opt-in per-launch Face ID gate, default-off Settings toggle, 5-minute background re-lock, fail-open if device has no passcode. `AnnotationsListView` consults `LaunchAuthGate.state` on appear; when `.locked`, renders the unlock screen instead of the annotation list. Capture / Read / Settings are ungated. See spec §3.14.
- `Op.Provenance` extension in MaughamCore: two optional fields `appVersion` / `osVersion` (snake_case JSON keys `app_version` / `os_version`), populated only by phone-written ops. Purely additive — existing op logs decode unchanged, Mac-side deriver ignores them; no migration.
- Write path: append `claudeAccept` / `claudeReject` / `claudeArchive` ops via per-device `JSONLAppendStore<Op>` (`d_<docId>.<ownDeviceSlug>.jsonl`, §3.12) and coordinated write. Exact JSON shape mirrors `Op.swift` Codable: `op_id` (ULID), `doc_id`, `kind`, `at` (ISO8601 fractional seconds), `device`, `session`, `changes: []`, `provenance: {session_id, source_annotation_id, user_response?, app_version, os_version}`.
- **Critical:** `claudeAccept` on a `suggestedChange` must include the creation op's `changes` array verbatim in the accept op so Mac-side `Deriver.derive` re-materializes the manuscript on next load. For `comment` / `query` / `craftNote`, `changes: []` is correct. Mac-side replay already handles this (verified 2026-05-24, see spec §3.9) — no Mac code change needed.
- Settings tab grows a "Security" section: "Require Face ID on launch" toggle (default off; gray-disabled if `LAContext.canEvaluatePolicy(.deviceOwnerAuthentication)` returns false, with hint to set a passcode in iOS Settings).

End-to-end test: Claude adds a suggestion on the Mac → phone shows it → reject with reason → Mac AnnotationsPane shows rejected + user response within sync window.

### Phase G — CI & release flow

iOS releases use a separate tag namespace, workflow, and script — Mac releases keep working unchanged.

**Tag namespace.** Mac stays on `v0.X.Y`. Phone uses `phone-v0.X.Y`. Both workflows trigger only on their own pattern.

**`./scripts/cut-phone-release.sh 0.X.Y`** (mirrors `cut-release.sh`):
- Verifies `docs/release-notes/phone/v0.X.Y.md` exists (template at `docs/release-notes/phone/_template.md`)
- Verifies tree is clean
- Runs phone test target
- Creates `phone-v0.X.Y` tag and prints push command
- `--skip-tests` flag for emergencies

**`.github/workflows/phone-release.yml`** (new):
- Trigger: `phone-v[0-9]+.[0-9]+.[0-9]+` tags
- Runner: `macos-latest` (iOS builds require it; ~10× cost of linux but acceptable at release cadence)
- Steps: checkout → `./gen.sh` → import distribution cert + provisioning profile from secrets → rewrite `CFBundleShortVersionString` from tag, `CFBundleVersion` from `git rev-list --count HEAD` → `xcodebuild archive` → `xcodebuild -exportArchive` → upload to TestFlight via App Store Connect API → create GitHub Release with `docs/release-notes/phone/v0.X.Y.md` as body
- `project.yml` keeps placeholders: `CFBundleShortVersionString: "0.0.0-dev"`, `CFBundleVersion: "1"` — CI rewrites both at build time. Don't bump in `project.yml` (same rule as Mac).

**GH secrets** (one-time setup):
- `APPLE_DISTRIBUTION_CERT` (base64 `.p12`) + `APPLE_DISTRIBUTION_CERT_PASSWORD`
- `PROVISIONING_PROFILE` (base64 `.mobileprovision`)
- `APP_STORE_CONNECT_KEY_ID` + `APP_STORE_CONNECT_ISSUER_ID` + `APP_STORE_CONNECT_API_KEY` (base64 `.p8`)

**Build numbering.** Apple rejects uploads where `CFBundleVersion` ≤ any prior upload. `git rev-list --count HEAD` is monotonic, never resets, doesn't require coordinating with App Store Connect state. (Avoid GH Actions `run_number` — resets if workflow file is recreated.)

**TestFlight specifics.** Internal testing (≤100 testers on your dev team) skips Beta App Review — first build is usable immediately. External testers require Beta App Review on the first build of each version (1-2 day delay). Privacy disclosures (mic, speech recognition, camera, photo library, iCloud) are mandatory at upload time; missing strings reject the build.

**No in-app updater needed** — TestFlight handles updates via its own app. The Mac's `BuildVariant.dev` updater-disable trick has no iOS analogue.

**Lint guard.** Extend the existing tripwire-13 grep (`"maugham"|"Maugham"` outside `BuildVariant.swift` + tests) to cover the new iOS sources.

### Phase H — Future (not in v1)

- Human-authored annotations from the phone — when Mac-side human-annotation primitives land, the iOS Annotations tab gains a creation surface using the same op-log append mechanism.
- Cross-project search on the phone.
- iOS-side `NSFilePresenter` for live updates (requires background-mode rethink).
- WhisperKit audio chunking for >5min recordings.
- App Store submission (privacy policy URL, full review, App Store Connect metadata polish).

## Critical correctness risks

1. **iCloud Drive conflict-twins on multi-writer JSONL.** Without per-device partitioning (Phase B0), phone + Mac concurrent appends to `.maugham/ops/d_<docId>.jsonl` or `.maugham/inbox/inbox.jsonl` produce silent conflict-twin files (`d_<docId> 2.jsonl` etc.) that the loader never opens. Spec §3.12 + ADR 0012. Phase B0 lands before Phase D for exactly this reason.
2. **iOS iCloud Drive eviction silently emptying the Annotations tab.** iOS routinely evicts unused iCloud Drive files; without explicit `URLResourceKey.ubiquitousItemDownloadingStatusKey` handling, the Annotations tab shows "no annotations" when the truth is "op-log files are placeholders awaiting download." This is the scenario where the writer most needs the app to work (returning from offline). Phase D0 lands before Phase D for exactly this reason. Spec §3.13.
3. **Phone-side `AnnotationWriter.claudeAccept` must copy `changes` verbatim** from the creation op for suggestedChange acceptance. Mac-side replay already handles `claudeAccept.changes` (`Deriver.swift:121-132` + `Deriver.swift:25-32` verified 2026-05-24); the failure mode if the phone gets this wrong is "phone-accepted suggestedChanges silently fail to materialize after Mac restart." Regression net is `AnnotationWriterAcceptSuggestedChangeRoundTripTests` (spec §7.1).
3. **Security-scoped bookmark staleness.** Check `isStale` every launch; surface a clear "Re-pick folder" prompt, not a silent empty list. iCloud-Drive folders are especially prone to bookmark expiration after device restarts or app upgrades.
4. **InboxStore cross-file last-wins semantics.** Per-device partitioning means multiple manifest files contribute entries for the same id (status transitions). `JSONLAppendStore.dedupKey` keeps first within a file (correct for op log); InboxStore must override at the cross-file merge step so newest createdAt per id wins.
5. **Inbox file moves.** Promote-to-research must use coordinated writes (NSFileCoordinator); a plain `FileManager.removeItem` on the old inbox copy bypasses the Mac's presenter and risks conflict-bombing.
6. **Annotation race window.** If the Mac archives an annotation while the phone has the detail view open, phone-side action would overwrite. Mitigation: re-derive status on view appearance and hide buttons if already resolved. A `claudeAccept` op pointing at a swept paragraph is harmless to the manuscript (Materializer skips paragraphs not in `sequence`) but flips the deriver's lifecycle classification from `archived` back to `accepted` — documented in spec §5.3 Race 2 as acceptable for v1.
7. **Tripwire 13 (hardcoded "Maugham" strings).** Route all iOS bundle ids and bookmark keys through `BuildVariant`. Lint guard extension covers this.
8. **Tripwire 4 (per-row re-parse).** Fountain rendering on iOS must cache `FountainScript` per document, never re-parse inside a SwiftUI row body.
9. **Phase A blast radius.** Moving 16 files into a package is mechanical but pervasive. Run `./gen.sh` + full `xcodebuild test` after every batched move; don't combine with any other change in the same PR.
10. **Phone-side authorization is opt-in, not enforced.** A stolen unlocked phone can bulk-reject open annotations. The Mac-side rewind mechanism makes this recoverable but not invisible. v1 partially mitigates via the opt-in launch-Face-ID toggle (spec §3.14); writers who want stronger guarantees can enable it. Per-action prompts and HMAC-signed ops are explicitly Phase H; the current mitigation is "iOS device passcode + optional launch gate + small attacker population."

## Verification (manual smoke for v1)

1. **Bookmark** — install MaughamPhone dev build, tap "Choose Projects Folder", pick an iCloud Drive folder with existing projects. Read tab lists them.
2. **Text capture** — Capture → quick text → commit. Within ~30s, Mac InboxPane (⌘⌥6) shows the entry.
3. **Photo capture** — Capture → photo → take photo. Mac InboxPane shows image thumbnail.
4. **Voice capture** — Capture → voice → record 10s. Phone shows on-device draft instantly. Mac InboxPane initially shows the draft, then WhisperKit transcript replaces it within ~60s (first run includes one-time model download).
5. **Triage** — On Mac, "Promote to research" on a row → file moves into `research/`, Research pane shows it, InboxPane removes the row.
6. **Read** — phone opens a manuscript `.md` → Markdown rendering, paragraph anchors stripped. Opens a `.fountain` → semantic styling (scene heading bold + uppercased, character centered + bold, dialogue indented).
7. **Annotation review** — Claude adds a suggestion via MCP on the Mac → phone Annotations tab shows it → Reject with reason "test rejection" → Mac AnnotationsPane shows `rejected` with that user response within sync window.
8. **Race smoke** — open same annotation on both, archive on Mac while phone shows detail; phone on next view appearance shows "Already resolved on another device" and hides actions.
9. **Release dry run** — tag `phone-v0.0.1-dev`, trigger the workflow, confirm TestFlight upload succeeds and the build appears in App Store Connect within 10–15 minutes.

## Critical files

**Modified on the Mac:**
- `project.yml` — new iOS target + package dep
- `Maugham/OpLog/OpLogStore.swift` — per-device file partitioning (Phase B0): glob + merge on load, per-device write on append
- `Maugham/Stores/ProjectFolderPresenter.swift` — verify directory-level subscription scope (Phase B0)
- `Maugham/Stores/MaughamSidecarPath.swift` — new `.inbox` case
- `Maugham/Stores/DocumentStore.swift` — `.inbox` switch arm in `presenterDidChangeSubitem`
- `Maugham/Models/DetailSegment.swift`, `Maugham/Views/DetailPaneToggle.swift` — `.inbox` case + picker image at ⌘⌥6 + content routing; `DocumentStore` owns the `InboxStore`
- `scripts/cut-release.sh` referenced; new sibling created

**Unchanged on the Mac (explicit non-scope):**
- `Maugham/OpLog/Document.swift` — replay path already handles `claudeAccept.changes` (verified 2026-05-24); no change required.
- `Maugham/OpLog/Deriver.swift` — `.claudeAccept` already in `appliesToManuscript`; no change required.

**New on the Mac:**
- `Maugham/Stores/InboxStore.swift`
- `Maugham/Stores/InboxTranscriptionWorker.swift`
- `Maugham/Views/InboxPane.swift`
- `.github/workflows/phone-release.yml`
- `scripts/cut-phone-release.sh`
- `docs/release-notes/phone/_template.md`

**New shared:**
- `Packages/MaughamCore/Package.swift` + `Sources/MaughamCore/...` (moved files listed in Phase A)
- `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift`
- `Packages/MaughamCore/Sources/MaughamCore/OpReplay.swift` (shared paragraph-state builder)

**New iOS:**
- `MaughamPhone/MaughamPhoneApp.swift` — TabView root
- `MaughamPhone/BuildVariantPhone.swift` — iOS-only `BuildVariant` extension
- `MaughamPhone/Storage/ProjectsRoot.swift`, `ProjectsBrowser.swift`, `CoordinatedFileIO.swift`
- `MaughamPhone/Capture/CaptureView.swift` + capture subviews
- `MaughamPhone/Read/ProjectsListView.swift`, `BinderView.swift`, `DocumentReaderView.swift`, `FountainSemanticRenderer.swift`
- `MaughamPhone/Annotations/AnnotationsListView.swift`, `AnnotationDetailView.swift`
- `MaughamPhone/Settings/SettingsView.swift`
- `MaughamPhone/Info.plist` privacy strings
- `MaughamPhoneTests/...`

## Notes on chunking the work

This is a several-milestone bundle, not a single feature. Suggested commit/PR rhythm:

- **Milestone 1 — Phase A only.** `MaughamCore` extraction, no behavior change. Highest blast radius, smallest review surface. Tag `milestone-maugham-core`.
- **Milestone 2 — Phases B0 + B + C.** Per-device JSONL partitioning (foundational; must land before any phone writes), then Mac-side inbox + WhisperKit. Mac is fully usable without a phone yet; you can manually drop files for testing. Tag `milestone-inbox-and-whisper`.
- **Milestone 3 — Phases D0 + D + E + F.** iOS app: iCloud-eviction download infrastructure (D0) first, then all three tabs. Phone gains capture / read / annotation-review in one bundle. Tag `milestone-iphone-companion` (the iOS milestone — `phone-v0.1.0` below is the version tag).
- **Milestone 4 — Phase G.** First TestFlight cut. Tag `phone-v0.1.0`.

Each milestone is independently verifiable via the smoke steps above.

**Alternatives considered.** Splitting M3 into M3a (D0+D+E, capture-and-read) and M3b (F, annotations) was discussed and rejected. The split would have de-risked Phase F's correctness work by isolating it, but the user explicitly prefers ambitious bundling here — the "phone v1" story is capture + read + triage as one shippable thing, not staged half-products. Phase F's correctness still earns dual-reviewer treatment (fresh-implementer + spec-reviewer + code-quality-reviewer per CLAUDE.md workflow) inside the bundled milestone.
