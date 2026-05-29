# Phase C — WhisperKit Transcription Worker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-transcribe inbox voice captures on the Mac with WhisperKit, replacing the phone's on-device draft with a higher-quality transcript — behind a protocol seam so the worker logic is fully testable without the external dependency.

**Architecture:** A `Transcriber` protocol (MaughamCore) decouples `InboxTranscriptionWorker` from WhisperKit. The worker is a `@MainActor` serial executor owned by `DocumentStore`; it transcribes only eligible entries (`.none`/`.onDeviceDraft`), so it never clobbers a `.whisperFinal` or `.userEdited` transcript. WhisperKit itself is added in an isolated final commit (Tasks 5–6) so its GitHub/CoreML fetch can't break the rest of the build.

**Tech Stack:** Swift 5.10, MaughamCore SPM package, AppKit/SwiftUI app target, WhisperKit (added last), XCTest. Spec: `docs/superpowers/specs/2026-05-24-iphone-companion-v1-design.md` §3.5.

---

## File Structure

**Commit 1 — worker logic, no external dependency (builds + tests in any environment):**
- Create `Packages/MaughamCore/Sources/MaughamCore/Transcriber.swift` — the protocol seam.
- Modify `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift` — add `TranscriptionState.userEdited`.
- Modify `Maugham/Views/InboxPane.swift` — Edit Transcript sets `.userEdited`.
- Create `Maugham/Stores/InboxTranscriptionWorker.swift` — the worker.
- Modify `Maugham/Stores/DocumentStore.swift` — own/start the worker; poke it from the `.inbox` presenter arm.
- Create `MaughamTests/InboxTranscriptionWorkerTests.swift` — worker tests + `MockTranscriber`.

**Commit 2 — the real transcriber + dependency (isolated; only step with external-fetch risk):**
- Modify `project.yml` — add WhisperKit SPM package to the Mac target.
- Create `Maugham/Stores/WhisperKitTranscriber.swift` — production `Transcriber`.
- Modify `Maugham/Stores/DocumentStore.swift` — inject `WhisperKitTranscriber` (was nil).
- Create `Maugham/Views/SettingsTabs/VoiceSettingsTab.swift` + modify `Maugham/Views/SettingsView.swift` — model picker + status + Download now + progress.

Build/test command throughout: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -quiet` (run `./gen.sh` only after adding/removing files).

---

## Task 1: `.userEdited` transcription state + Edit Transcript wiring

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift`
- Modify: `Maugham/Views/InboxPane.swift`
- Test: `MaughamTests/InboxStoreLastWinsTests.swift` (add one case)

- [ ] **Step 1: Write the failing test** — add to `InboxStoreLastWinsTests`:

```swift
func test_userEdited_decodesAndRoundTrips() throws {
    let json = #"{"id":"e","created_at":"2026-05-29T00:00:00Z","device_id":"d","kind":"audio","transcription_state":"user_edited","status":"new"}"#
        .data(using: .utf8)!
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let entry = try dec.decode(InboxEntry.self, from: json)
    XCTAssertEqual(entry.transcriptionState, .userEdited)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -a userEdited`
Expected: compile failure — `.userEdited` is not a member of `TranscriptionState`.

- [ ] **Step 3: Add the enum case** in `InboxEntry.swift`, inside `enum TranscriptionState`:

```swift
public enum TranscriptionState: String, Codable, Equatable, Sendable {
    case none
    case onDeviceDraft = "on_device_draft"
    case whisperFinal = "whisper_final"
    case userEdited = "user_edited"   // the writer owns this transcript; the worker leaves it alone
    case failed
}
```

- [ ] **Step 4: Wire Edit Transcript to set it** in `InboxPane.swift`. Replace the Save action's state preservation:

```swift
Button("Save") {
    let id = entry.id
    let text = draftTranscript
    // A manual edit makes the writer the owner: mark .userEdited so the
    // transcription worker never overwrites it with a later Whisper result.
    Task { await store.updateTranscript(id: id, text: text, state: .userEdited) }
    editing = nil
}
.keyboardShortcut(.defaultAction)
```

(Also update the InboxPane header comment that currently says Edit Transcript "preserves transcription state".)

- [ ] **Step 5: Run the test and the suite to verify green**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -aE "Executed|TEST (SUCCEEDED|FAILED)"`
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(inbox): add .userEdited transcription state; Edit Transcript claims ownership"
```

---

## Task 2: `Transcriber` protocol + `MockTranscriber`

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/Transcriber.swift`
- Test helper lives in: `MaughamTests/InboxTranscriptionWorkerTests.swift` (created in Task 3)

- [ ] **Step 1: Create the protocol**

```swift
// Packages/MaughamCore/Sources/MaughamCore/Transcriber.swift
import Foundation

/// The seam between InboxTranscriptionWorker and a concrete speech-to-text
/// engine. The worker depends only on this; WhisperKit is wired behind it
/// (WhisperKitTranscriber) in an isolated commit so its CoreML fetch can't
/// break the rest of the build. `model` is the engine's model identifier
/// (e.g. "openai_whisper-base"). See spec §3.5.
public protocol Transcriber: Sendable {
    func transcribe(_ audio: URL, model: String) async throws -> String
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -aE "error:|BUILD"`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(core): Transcriber protocol seam for inbox transcription"
```

---

## Task 3: `InboxTranscriptionWorker`

**Files:**
- Create: `Maugham/Stores/InboxTranscriptionWorker.swift`
- Test: `MaughamTests/InboxTranscriptionWorkerTests.swift`

- [ ] **Step 1: Write the failing tests + MockTranscriber**

```swift
// MaughamTests/InboxTranscriptionWorkerTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// Tracks max concurrency and records calls; result is configurable.
final class MockTranscriber: Transcriber, @unchecked Sendable {
    enum Mode { case success(String), failure }
    var mode: Mode = .success("WHISPER")
    private(set) var calls: [URL] = []
    private(set) var maxConcurrent = 0
    private var current = 0
    private let lock = NSLock()
    func transcribe(_ audio: URL, model: String) async throws -> String {
        lock.lock(); calls.append(audio); current += 1
        maxConcurrent = max(maxConcurrent, current); lock.unlock()
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms to expose overlap
        lock.lock(); current -= 1; lock.unlock()
        switch mode {
        case .success(let s): return s
        case .failure: throw NSError(domain: "mock", code: 1)
        }
    }
}

@MainActor
final class InboxTranscriptionWorkerTests: XCTestCase {

    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".maugham/inbox/audio"),
            withIntermediateDirectories: true)
        return root
    }

    private func seedAudio(_ root: URL, id: String,
                           state: InboxEntry.TranscriptionState) async throws {
        let asset = root.appendingPathComponent(".maugham/inbox/audio/\(id).m4a")
        try Data("audio".utf8).write(to: asset)
        let file = root.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        let s = JSONLAppendStore<InboxEntry>(fileURL: file)
        try await s.append(InboxEntry(
            id: id, createdAt: Date(timeIntervalSince1970: 100), deviceId: "phone",
            kind: .audio, sourceFilename: "\(id).m4a",
            transcript: "draft", transcriptionState: state))
    }

    func test_transcribesEligibleAudio_setsWhisperFinal() async throws {
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber()
        let worker = InboxTranscriptionWorker(
            inboxStore: inbox, transcriber: mock, model: "m")
        await worker.processForTest()
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.first?.transcript, "WHISPER")
        XCTAssertEqual(inbox.entries.first?.transcriptionState, .whisperFinal)
    }

    func test_failure_marksFailed_keepsDraft() async throws {
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber(); mock.mode = .failure
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock, model: "m")
        await worker.processForTest()
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.first?.transcriptionState, .failed)
        XCTAssertEqual(inbox.entries.first?.transcript, "draft", "draft preserved on failure")
    }

    func test_skipsIneligible_whisperFinalAndUserEdited() async throws {
        let root = try project()
        try await seedAudio(root, id: "done", state: .whisperFinal)
        try await seedAudio(root, id: "mine", state: .userEdited)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber()
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock, model: "m")
        await worker.processForTest()
        XCTAssertTrue(mock.calls.isEmpty, "worker must not touch whisperFinal/userEdited")
    }

    func test_serial_oneTranscriptionAtATime() async throws {
        let root = try project()
        for i in 0..<4 { try await seedAudio(root, id: "a\(i)", state: .onDeviceDraft) }
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber()
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock, model: "m")
        await worker.processForTest()
        XCTAssertEqual(mock.calls.count, 4)
        XCTAssertEqual(mock.maxConcurrent, 1, "transcriptions run serially")
    }

    func test_nilTranscriber_isInert() async throws {
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: nil, model: "m")
        await worker.processForTest()
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.first?.transcriptionState, .onDeviceDraft,
                       "no transcriber → worker leaves entries untouched")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build-for-testing CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -aE "error:" | head`
Expected: `cannot find 'InboxTranscriptionWorker' in scope`.

- [ ] **Step 3: Implement the worker**

```swift
// Maugham/Stores/InboxTranscriptionWorker.swift
import Foundation
import MaughamCore
import os

/// Serial-queue worker that re-transcribes inbox voice captures with an injected
/// `Transcriber` (WhisperKitTranscriber in production), replacing the phone's
/// on-device draft. Owned by DocumentStore (one per window). Eligibility is
/// `.none`/`.onDeviceDraft` only, so it never overwrites a `.whisperFinal` or
/// `.userEdited` transcript. One transcription at a time. On failure the draft
/// is preserved (worst case: the Mac didn't improve on it). See spec §3.5.
///
/// `.failed` entries are not auto-retried (avoids hammering a corrupt file);
/// re-dropping audio or the Settings "Download now" path cover recovery.
/// Long audio (>5 min) is not chunked in v1 — WhisperKit degrades past ~5 min.
@MainActor
final class InboxTranscriptionWorker {
    private let inboxStore: InboxStore
    private let transcriber: Transcriber?
    private let model: String
    private let log = Logger(subsystem: "com.maugham", category: "transcription")

    private var running = false
    private var queued = false

    init(inboxStore: InboxStore, transcriber: Transcriber?, model: String) {
        self.inboxStore = inboxStore
        self.transcriber = transcriber
        self.model = model
    }

    /// Convenience for production wiring: read the configured model from defaults.
    static var configuredModel: String {
        UserDefaults.standard.string(forKey: "whisperModel") ?? "openai_whisper-base"
    }

    /// Called by DocumentStore's `.inbox` presenter arm for `kind == .audio`.
    /// Coalesces bursts: if a scan is already running, marks a re-scan instead
    /// of starting a second (keeps transcriptions strictly serial).
    func onInboxChanged() {
        guard transcriber != nil else { return }
        if running { queued = true; return }
        running = true
        Task { @MainActor in
            repeat { queued = false; await processEligible() } while queued
            running = false
        }
    }

    /// Test entry point — runs one drain synchronously.
    func processForTest() async { await processEligible() }

    private func processEligible() async {
        guard let transcriber else { return }
        await inboxStore.refresh()
        let eligible = inboxStore.entries.filter {
            $0.kind == .audio
                && ($0.transcriptionState == .none || $0.transcriptionState == .onDeviceDraft)
        }
        for entry in eligible {
            guard let url = inboxStore.assetURL(for: entry) else { continue }
            do {
                let text = try await transcriber.transcribe(url, model: model)
                await inboxStore.updateTranscript(id: entry.id, text: text, state: .whisperFinal)
            } catch {
                log.error("transcription failed for \(entry.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Preserve the on-device draft; only the state changes.
                await inboxStore.updateTranscript(
                    id: entry.id, text: entry.transcript ?? "", state: .failed)
            }
        }
    }
}
```

- [ ] **Step 4: Run the worker tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -aE "InboxTranscriptionWorkerTests|Executed|TEST (SUCCEEDED|FAILED)"`
Expected: all five worker cases pass; `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(inbox): InboxTranscriptionWorker (serial, eligibility-gated, draft-preserving)"
```

---

## Task 4: Own + start the worker in `DocumentStore`

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift`

- [ ] **Step 1: Add the worker property + a transcriber factory.** Near the `inboxStore` lazy property:

```swift
@MainActor private var _transcriptionWorker: InboxTranscriptionWorker?
@MainActor var transcriptionWorker: InboxTranscriptionWorker {
    if let w = _transcriptionWorker { return w }
    let w = InboxTranscriptionWorker(
        inboxStore: inboxStore,
        transcriber: Self.makeTranscriber(),
        model: InboxTranscriptionWorker.configuredModel)
    _transcriptionWorker = w
    return w
}

/// Production transcriber. Returns nil in Commit 1 (no WhisperKit yet) so the
/// worker is inert in production while remaining fully testable via injection.
/// Commit 2 returns a WhisperKitTranscriber (Apple-Silicon only).
@MainActor private static func makeTranscriber() -> Transcriber? { nil }
```

- [ ] **Step 2: Poke the worker from the `.inbox` presenter arm.** Extend the existing `case .inbox` arm:

```swift
case .inbox(let kind, _):
    NotificationCenter.default.post(
        name: .maughamInboxChanged, object: self,
        userInfo: ["kind": kind.rawValue])
    Task { @MainActor in await inboxStore.refresh() }
    if kind == .audio {
        Task { @MainActor in transcriptionWorker.onInboxChanged() }
    }
```

- [ ] **Step 3: Build + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -aE "Executed|TEST (SUCCEEDED|FAILED)"`
Expected: `** TEST SUCCEEDED **`, 0 failures. (Worker is inert in production — `makeTranscriber()` returns nil — so no behavior change yet.)

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(inbox): DocumentStore owns the transcription worker; pokes it on audio changes"
```

**End of Commit-1 scope — everything above builds and tests in this environment with no external dependency.**

---

## Task 5: WhisperKit dependency + `WhisperKitTranscriber`

> ⚠️ **External-fetch risk.** This task adds a GitHub SPM package (large, CoreML). If the build environment can't resolve it, this task is "code-complete, verify on a real Apple-Silicon Mac" — Commit 1 stays green regardless. WhisperKit's exact API may differ across versions; **verify method names against the resolved `Package.resolved` version** when wiring.

**Files:**
- Modify: `project.yml`
- Create: `Maugham/Stores/WhisperKitTranscriber.swift`
- Modify: `Maugham/Stores/DocumentStore.swift`

- [ ] **Step 1: Add the package to `project.yml`.** Under the top-level `packages:` block (alongside `MaughamCore`):

```yaml
packages:
  MaughamCore:
    path: Packages/MaughamCore
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit
    from: 0.9.0   # pin to the current release; confirm latest at wiring time
```

Under the `Maugham` target's `dependencies:` (Mac target only — NOT MaughamPhone):

```yaml
    dependencies:
      - package: MaughamCore
      - package: WhisperKit
      - target: maugham-mcp
        copy:
          destination: executables
          codeSign: false
```

- [ ] **Step 2: Implement the production transcriber**

```swift
// Maugham/Stores/WhisperKitTranscriber.swift
import Foundation
import MaughamCore
import WhisperKit

/// Production Transcriber backed by WhisperKit (Apple-Silicon CoreML). Loads /
/// lazily downloads the model on first use into the variant-scoped model dir,
/// then transcribes. Apple-Silicon only — DocumentStore.makeTranscriber()
/// returns nil on Intel so the worker stays inert there. See spec §3.5.
///
/// NOTE: verify WhisperKit's init/transcribe API against the resolved package
/// version — the surface below targets WhisperKit ~0.9.
actor WhisperKitTranscriber: Transcriber {
    private var pipe: WhisperKit?
    private var loadedModel: String?

    private static var modelFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(BuildVariant.current.supportFolderName)
            .appendingPathComponent("WhisperModels")
    }

    func transcribe(_ audio: URL, model: String) async throws -> String {
        if pipe == nil || loadedModel != model {
            let config = WhisperKitConfig(
                model: model,
                downloadBase: Self.modelFolder,
                download: true)            // lazy download-then-transcribe
            pipe = try await WhisperKit(config)
            loadedModel = model
        }
        let results = try await pipe!.transcribe(audioPath: audio.path)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 3: Inject it in `DocumentStore.makeTranscriber()`** — replace the nil stub:

```swift
@MainActor private static func makeTranscriber() -> Transcriber? {
    #if arch(arm64)
    return WhisperKitTranscriber()
    #else
    return nil   // Intel: WhisperKit needs Apple-Silicon CoreML; worker stays inert
    #endif
}
```

- [ ] **Step 4: Regenerate + build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -aE "error:|BUILD"`
Expected: no errors. **If SPM resolution fails in this environment, stop and hand off to a real Mac — do not block Commit 1.**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(inbox): WhisperKitTranscriber + SPM dependency (Mac target, Apple-Silicon)"
```

---

## Task 6: Voice transcription Settings tab

**Files:**
- Create: `Maugham/Views/SettingsTabs/VoiceSettingsTab.swift`
- Modify: `Maugham/Views/SettingsView.swift`

- [ ] **Step 1: Create the tab**

```swift
// Maugham/Views/SettingsTabs/VoiceSettingsTab.swift
import SwiftUI
import MaughamCore

struct VoiceSettingsTab: View {
    @AppStorage("whisperModel") private var model = "openai_whisper-base"

    private static let models: [(id: String, label: String)] = [
        ("openai_whisper-base", "Base (~150 MB)"),
        ("openai_whisper-small", "Small (~500 MB)"),
        ("openai_whisper-large-v3", "Large v3 (~3 GB)"),
    ]

    var body: some View {
        Form {
            #if arch(arm64)
            Picker("Model", selection: $model) {
                ForEach(Self.models, id: \.id) { Text($0.label).tag($0.id) }
            }
            Text("Voice captures from MaughamPhone are re-transcribed locally with WhisperKit. The model downloads on first use.")
                .font(.caption).foregroundStyle(.secondary)
            #else
            Label("Apple Silicon required for local transcription.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            #endif
        }
        .padding()
        .frame(width: 420)
    }
}
```

> Live byte-level download progress + a "Download now" button are deferred (spec §3.5 deferred list) — they need WhisperKit's progress callback surface; the model downloads lazily on first transcription in v1. The picker + Apple-Silicon gate ship now.

- [ ] **Step 2: Add the tab to `SettingsView`** — inside the `TabView`:

```swift
VoiceSettingsTab()
    .tabItem { Label("Voice", systemImage: "mic") }
```

- [ ] **Step 3: Regenerate + build + suite**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -aE "Executed|TEST (SUCCEEDED|FAILED)"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(settings): Voice transcription tab (model picker + Apple-Silicon gate)"
```

---

## Manual smoke (after Task 5 on a real Apple-Silicon Mac)

1. Drop a real `.m4a` + a matching `InboxEntry` (kind audio, `transcription_state: on_device_draft`) into a project's `.maugham/inbox/audio/` + `inbox.<slug>.jsonl`.
2. Open the project; the InboxPane (⌘⌥6) shows the draft. Within ~60s (first run includes model download) the transcript replaces the draft and the state flips to whisper-final.
3. Edit a transcript via Edit Transcript, then drop another audio — confirm the edited one is untouched (`.userEdited`), the new one transcribes.
4. Settings → Voice → switch model → drop audio → confirm the new model is used.

---

## Self-Review

- **Spec coverage (§3.5):** protocol seam ✓ (T2); worker lifecycle/serial/eligibility/failure ✓ (T3); `.userEdited` ✓ (T1); model default + storage path ✓ (T5); Intel handling ✓ (T5 `#if arch(arm64)` + T6 gate); Settings picker ✓ (T6); deferred items recorded ✓ (spec). Lazy download-then-transcribe ✓ (T5 `download: true`).
- **Placeholders:** none — every code step is complete. The one explicit unknown is WhisperKit's exact API surface (external dep), flagged with a verify-at-wiring note, which is honest rather than a placeholder.
- **Type consistency:** `Transcriber.transcribe(_:model:)` identical across T2/T3/T5; `TranscriptionState.userEdited` (raw `user_edited`) used in T1/T3/T6; `InboxStore.updateTranscript(id:text:state:)` and `.assetURL(for:)` match the shipped InboxStore; `makeTranscriber() -> Transcriber?` consistent T4/T5; `configuredModel` defined T3, used T4.
- **Scope:** single subsystem (Mac transcription), two clean commits with the external-fetch risk isolated to Commit 2.
