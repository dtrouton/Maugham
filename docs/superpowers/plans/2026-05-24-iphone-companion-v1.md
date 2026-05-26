# Maugham iPhone Companion — v1 plan

## Context

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
- `Deriver.appliesToManuscript` already includes `.claudeAccept` (`Deriver.swift:108-117`). Phone-written accept ops materialize on Mac restart with zero Mac code change — provided the phone copies the creation op's `changes` array verbatim. Resolved during planning; not a Phase F open question.

## Phased implementation

### Phase A — `MaughamCore` extraction (foundation, highest blast radius)

Create `Packages/MaughamCore/` SPM package. Move the Foundation-only files listed above out of `Maugham/OpLog/`, `Maugham/Editor/Fountain/`, `Maugham/Models/`, and `Maugham/BuildVariant.swift` into the package. Both Mac and iOS targets depend on it. Run `./gen.sh`, fix imports across `Maugham/`, run full `xcodebuild test` + the manual smoke from CLAUDE.md. Do this as one focused PR — don't combine with anything else.

### Phase B0 — Per-device JSONL partitioning (Mac only, prerequisite for any phone writes)

Foundational. Must land before Phase D so the phone never writes to a shared file. Spec §3.12 + ADR 0012.

- `Maugham/OpLog/OpLogStore.swift` — `load(docId:)` globs `.maugham/ops/d_<docId>*.jsonl` (matches legacy `d_<docId>.jsonl` + new `d_<docId>.<deviceSlug>.jsonl`), reads each via `JSONLAppendStore`, merges with opId dedupe + opId sort. `append(_:)` targets the writer's own per-device file.
- `Maugham/Stores/ProjectFolderPresenter.swift` — verify directory-level subscription on `.maugham/ops/` so new per-device sibling files trigger `presenterDidChangeSubitem` the first time they appear. If not, broaden.
- Backward compat — existing `d_<docId>.jsonl` files are included in the glob. No migration logic (CLAUDE.md tripwire 11).
- Manual test: write to a project from one device, then synthesize a "second device" file (`d_<docId>.fake.jsonl` with a few ops) by hand; confirm Mac merges both on next load, opIds sort correctly, derived state matches.

### Phase B — Inbox plumbing (Mac only)

- `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift` — Codable: `id` (ULID), `createdAt`, `deviceId`, `kind` (text/image/audio), `sourceFilename`, `inlineText`, `transcript`, `transcriptionState` (none / on_device_draft / whisper_final / failed), `title`, `status` (new / promoted / trashed), `resolvedAt`. snake_case keys to match Op convention.
- `Maugham/Stores/MaughamSidecarPath.swift` — add `case inbox(kind: InboxFileKind, relativePath: String)`; extend `classifySidecar` with `.maugham/inbox/` branches (matches `inbox.jsonl` + `inbox.<slug>.jsonl`).
- `Maugham/Stores/DocumentStore.swift` — add a `case .inbox` arm in `presenterDidChangeSubitem` (line 477) that posts `Notification.Name.maughamInboxChanged`.
- `Maugham/Stores/InboxStore.swift` (new) — owned by `DocumentStore`. Globs `.maugham/inbox/inbox.*.jsonl` (per-device partitioning, same pattern as OpLogStore from Phase B0). Writes go to the Mac's own `inbox.<deviceSlug>.jsonl`. Two-layer merge: per-file via `JSONLAppendStore` first-wins, cross-file via InboxStore last-wins (newest createdAt per id). Methods: `refresh`, `promoteToResearch(_:)` (delegates to `ProjectStore.addResearchAsset`), `trash(_:)`, `attachToCurrentDoc(_:)`, `updateTranscript(id:text:state:)`.
- `Maugham/Views/InboxPane.swift` (new) — right-pane mode, rows show kind icon + title + transcript preview + timestamp + trailing menu (Promote / Attach / Edit transcript / Trash). Empty state with `ContentUnavailableView` pointing at the phone.
- Wire ⌘⌥6 in `ProjectWindow.swift` and add `.inbox` to `DetailSegment.swift` + `DetailPaneToggle.swift`.

Manual test by dropping a file + JSONL line into `.maugham/inbox/` (either the per-device file or the legacy unsuffixed name) — no phone code yet.

### Phase C — WhisperKit on the Mac

- Add WhisperKit (`https://github.com/argmaxinc/WhisperKit`) as an SPM dependency on the Mac target only.
- `Maugham/Stores/InboxTranscriptionWorker.swift` (new) — serial `Task` queue subscribed to `maughamInboxChanged`. On audio entries: run WhisperKit, call `InboxStore.updateTranscript`. Default model `base` (~150MB), settings hook for `small` / `large-v3`. Models live in `~/Library/Application Support/<BuildVariant.supportFolderName>/WhisperModels/`. Failure mode: keep on-device draft, mark `transcriptionState: failed`.
- Apple Silicon-only; surface a settings hint on Intel.

Manual test: drop a `.m4a` into `.maugham/inbox/audio/`, watch transcript appear.

### Phase D0 — iCloud Drive eviction handling (iOS-only infrastructure, prerequisite for D/E/F reads)

Foundational on the iOS side. Spec §3.13. Without it, the Annotations tab silently shows "no annotations" when op-log files are evicted iCloud Drive placeholders.

- `MaughamPhone/Storage/DownloadCoordinator.swift` (new) — `@MainActor actor` tracking per-URL download state (`notDownloaded` / `downloading` / `downloaded` / `failed`), dedupes concurrent requests for the same URL, enforces a 50 MB cold-launch budget for proactive op-log downloads. Lazy `ensureDownloaded(_:)` ignores budget.
- `MaughamPhone/Storage/CoordinatedFileIO.swift` — gains `download(at:) async throws` helper wrapping `FileManager.startDownloadingUbiquitousItem` + `URLResourceKey.ubiquitousItemDownloadingStatusKey` polling. Cancellation-aware, exponential poll-interval backoff.
- `MaughamPhone/Storage/RecentsTracker.swift` (new) — `@Observable` owner of `@AppStorage("recentProjectIds")` (last 5 captured-into, FIFO) and `@AppStorage("lastOpenedDates")` (`[ProjectId: Date]`). Derives `recents: Set<ProjectId>` = captures ∪ projects opened within the last 14 days.
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
3. **Phone-side `AnnotationWriter.claudeAccept` must copy `changes` verbatim** from the creation op for suggestedChange acceptance. Mac-side replay already handles `claudeAccept.changes` (`Deriver.swift:108-117` + `Deriver.swift:26-37` verified 2026-05-24); the failure mode if the phone gets this wrong is "phone-accepted suggestedChanges silently fail to materialize after Mac restart." Regression net is `AnnotationWriterAcceptSuggestedChangeRoundTripTests` (spec §7.1).
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
- `Maugham/Views/ProjectWindow.swift`, `DetailSegment.swift`, `DetailPaneToggle.swift` — ⌘⌥6 + new pane wiring
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
