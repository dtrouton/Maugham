# Inbox Re-transcribe + Failure Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the writer re-trigger transcription on failed/already-transcribed inbox audio (picking up the current Settings model), surface the failure reason in the pane, and stop an empty WhisperKit result from silently clobbering the on-device draft.

**Architecture:** A new optional `transcriptionError` field on the shared `InboxEntry` (MaughamCore) carries the reason. `InboxStore` gains an `error:` param on `updateTranscript` and a thin `requestRetranscription(id:)` that resets state to `.onDeviceDraft` (worker-eligible) and clears the error. The worker is restructured so empty results route through the failure path, and a single post-await eligibility re-check guards every outcome (success/empty/throw) against a concurrent user-edit clobber. `DocumentStore.retranscribe(_:)` resets + pokes the worker; `InboxPane` exposes a "Transcribe Again" context-menu item and shows the error.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest. Two test targets: `MaughamCoreTests` (the shared package) and `MaughamTests` (Mac app).

---

## File Structure

- `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift` — **modify**: add `transcriptionError` field, init param, CodingKey.
- `Packages/MaughamCore/Tests/MaughamCoreTests/InboxEntryTranscriptionErrorTests.swift` — **create**: optional-decode tolerance.
- `Maugham/Stores/InboxStore.swift` — **modify**: `updateTranscript(error:)`, `requestRetranscription(id:)`.
- `MaughamTests/InboxRetranscribeTests.swift` — **create**: store-level re-transcribe mechanics.
- `Maugham/Stores/InboxTranscriptionWorker.swift` — **modify**: outcome restructure (empty→failed, single re-check, error stamping), header comment.
- `MaughamTests/InboxTranscriptionWorkerTests.swift` — **modify**: empty-result + failure-error + edit-during-failure + re-transcribe tests.
- `Maugham/Stores/DocumentStore.swift` — **modify**: `retranscribe(_:)` delegate.
- `Maugham/Views/InboxPane.swift` — **modify**: new init params, "Transcribe Again" menu item, subtitle error, edit-sheet note.
- `Maugham/Views/DetailPaneToggle.swift` — **modify**: pass `canTranscribe` + `retranscribe`.

**Build/test commands** (from repo root):

```bash
# MaughamCore package tests (fast — used for Tasks 1):
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamCoreTests/InboxEntryTranscriptionErrorTests 2>&1 | tail -20

# Mac app tests (Tasks 2–4):
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamTests/InboxRetranscribeTests \
  -only-testing:MaughamTests/InboxTranscriptionWorkerTests 2>&1 | tail -30
```

If `xcodebuild` can't find a newly-created file, run `./gen.sh` first (the `.xcodeproj` is generated from `project.yml`). MaughamCore sources and the Mac test folder are `type: folder` references, so new files are usually picked up without regen — but if a new file isn't compiled, `./gen.sh` then retry.

---

## Task 1: Add `transcriptionError` to `InboxEntry` (MaughamCore)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/InboxEntryTranscriptionErrorTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Packages/MaughamCore/Tests/MaughamCoreTests/InboxEntryTranscriptionErrorTests.swift`:

```swift
import XCTest
@testable import MaughamCore

/// `transcriptionError` is a later, optional addition to the cross-surface
/// `InboxEntry` contract. Older rows (and the phone, which never writes it)
/// omit the `transcription_error` key entirely — decoding MUST tolerate that
/// as `nil` rather than throwing (tripwire 19).
final class InboxEntryTranscriptionErrorTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = JSONLAppendStore<InboxEntry>.dateDecoding
        return d
    }

    func test_decodesMissingTranscriptionError_asNil() throws {
        let json = """
        {"id":"x","created_at":"2026-01-01T00:00:00Z","device_id":"d",\
        "kind":"audio","transcription_state":"failed","status":"new"}
        """.data(using: .utf8)!
        let entry = try decoder().decode(InboxEntry.self, from: json)
        XCTAssertNil(entry.transcriptionError)
    }

    func test_roundTripsTranscriptionError() throws {
        let json = """
        {"id":"x","created_at":"2026-01-01T00:00:00Z","device_id":"d",\
        "kind":"audio","transcription_state":"failed","status":"new",\
        "transcription_error":"no speech detected"}
        """.data(using: .utf8)!
        let entry = try decoder().decode(InboxEntry.self, from: json)
        XCTAssertEqual(entry.transcriptionError, "no speech detected")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamCoreTests/InboxEntryTranscriptionErrorTests 2>&1 | tail -20
```
Expected: compile failure — `InboxEntry` has no member `transcriptionError`. (If the new test file isn't compiled at all, run `./gen.sh` and retry.)

- [ ] **Step 3: Add the field, init param, and CodingKey**

In `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift`:

Add the stored property after `resolvedAt` (line 55):
```swift
    public var resolvedAt: Date?                // set when status leaves .new
    /// Human-readable reason the last transcription attempt failed (Whisper
    /// threw, or produced no text). nil unless `transcriptionState == .failed`.
    /// Optional so older readers and the phone (which never writes it) decode
    /// it as nil — tripwire 19.
    public var transcriptionError: String?
```

Add to `init` — new parameter after `resolvedAt` (defaulted, so call sites are unchanged):
```swift
        status: Status = .new,
        resolvedAt: Date? = nil,
        transcriptionError: String? = nil
    ) {
```
and the assignment after `self.resolvedAt = resolvedAt`:
```swift
        self.resolvedAt = resolvedAt
        self.transcriptionError = transcriptionError
```

Add to `CodingKeys` after `case resolvedAt = "resolved_at"`:
```swift
        case resolvedAt = "resolved_at"
        case transcriptionError = "transcription_error"
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamCoreTests/InboxEntryTranscriptionErrorTests 2>&1 | tail -20
```
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/InboxEntryTranscriptionErrorTests.swift
git commit -m "feat(inbox): add optional transcriptionError to InboxEntry

Carries the reason a transcription failed across the cross-surface
contract. Optional so older rows / the phone decode it as nil."
```

---

## Task 2: `InboxStore.updateTranscript(error:)` + `requestRetranscription`

**Files:**
- Modify: `Maugham/Stores/InboxStore.swift`
- Test: `MaughamTests/InboxRetranscribeTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/InboxRetranscribeTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

/// Store-level re-transcribe mechanics: requestRetranscription resets a
/// finished/failed entry to a worker-eligible draft and clears the stored
/// error; updateTranscript's error param sets/clears it.
@MainActor
final class InboxRetranscribeTests: XCTestCase {

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        return root
    }

    private func seed(_ root: URL, _ entry: InboxEntry) async throws {
        let url = root.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        let store = JSONLAppendStore<InboxEntry>(fileURL: url)
        try await store.append(entry)
    }

    func test_requestRetranscription_resetsToDraft_keepsTranscript_clearsError() async throws {
        let root = try makeProject()
        try await seed(root, InboxEntry(
            id: "a1", createdAt: Date(timeIntervalSince1970: 100), deviceId: "phone",
            kind: .audio, sourceFilename: "a1.m4a", transcript: "old result",
            transcriptionState: .whisperFinal, status: .new,
            transcriptionError: "boom"))
        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()

        await store.requestRetranscription(id: "a1")
        await store.refresh()

        let e = store.entries.first { $0.id == "a1" }
        XCTAssertEqual(e?.transcriptionState, .onDeviceDraft, "reset to a worker-eligible state")
        XCTAssertEqual(e?.transcript, "old result", "transcript preserved as the draft")
        XCTAssertNil(e?.transcriptionError, "error cleared on retry request")
    }

    func test_requestRetranscription_unknownId_isNoOp() async throws {
        let root = try makeProject()
        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()
        await store.requestRetranscription(id: "nope")  // must not crash
        await store.refresh()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_updateTranscript_setsAndClearsError() async throws {
        let root = try makeProject()
        try await seed(root, InboxEntry(
            id: "a1", createdAt: Date(timeIntervalSince1970: 100), deviceId: "phone",
            kind: .audio, sourceFilename: "a1.m4a", transcript: "draft",
            transcriptionState: .onDeviceDraft, status: .new))
        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()

        await store.updateTranscript(id: "a1", text: "draft", state: .failed, error: "no text")
        await store.refresh()
        XCTAssertEqual(store.entries.first?.transcriptionError, "no text")

        await store.updateTranscript(id: "a1", text: "WHISPER", state: .whisperFinal)
        await store.refresh()
        XCTAssertNil(store.entries.first?.transcriptionError, "success clears the error")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamTests/InboxRetranscribeTests 2>&1 | tail -20
```
Expected: compile failure — `updateTranscript` has no `error:` param / no `requestRetranscription`. (If the new file isn't compiled, run `./gen.sh` and retry.)

- [ ] **Step 3: Add the `error:` param and `requestRetranscription`**

In `Maugham/Stores/InboxStore.swift`, replace the `updateTranscript` method (lines 110-119) with:

```swift
    /// Replace an entry's transcript + transcription state (Whisper result, or a
    /// manual correction). Preserves every other field except `transcriptionError`,
    /// which is set to `error` (pass `nil` to clear it — e.g. on success or a manual
    /// edit). No-op if `id` is unknown.
    func updateTranscript(id: String, text: String,
                          state: InboxEntry.TranscriptionState,
                          error: String? = nil) async {
        guard var next = currentEntry(id: id) else { return }
        next.transcript = text
        next.transcriptionState = state
        next.transcriptionError = error
        await append(next)
        await refresh()
    }

    /// Re-arm a finished (`.whisperFinal`) or `.failed` audio entry for the
    /// transcription worker: reset its state to `.onDeviceDraft` (the worker's
    /// eligible set is `.none`/`.onDeviceDraft`), keep the current transcript as
    /// the draft (so a second failure still has something to preserve), and clear
    /// any stored error. Pairs with `DocumentStore.retranscribe`, which pokes the
    /// worker after this. No-op if `id` is unknown.
    func requestRetranscription(id: String) async {
        guard let cur = currentEntry(id: id) else { return }
        await updateTranscript(id: id, text: cur.transcript ?? "",
                               state: .onDeviceDraft, error: nil)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamTests/InboxRetranscribeTests 2>&1 | tail -20
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/InboxStore.swift MaughamTests/InboxRetranscribeTests.swift
git commit -m "feat(inbox): updateTranscript(error:) + requestRetranscription

Stores the failure reason on the entry and adds a thin re-arm that resets
a finished/failed entry to a worker-eligible draft, clearing the error."
```

---

## Task 3: Worker — empty result is a failure; single eligibility re-check; error stamping

**Files:**
- Modify: `Maugham/Stores/InboxTranscriptionWorker.swift`
- Test: `MaughamTests/InboxTranscriptionWorkerTests.swift`

Note: `MockTranscriber` already supports `.success("")` (empty) and `.failure` — no mock changes needed.

- [ ] **Step 1: Write the failing tests**

In `MaughamTests/InboxTranscriptionWorkerTests.swift`, add these three methods before the closing brace (after `test_userEditDuringTranscription_isNotClobbered`):

```swift
    func test_emptyResult_marksFailed_keepsDraft_setsError() async throws {
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber(); mock.mode = .success("")   // empty transcript
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        await inbox.refresh()
        let e = inbox.entries.first { $0.id == "a1" }
        XCTAssertEqual(e?.transcriptionState, .failed, "empty result is a failure, not a success")
        XCTAssertEqual(e?.transcript, "draft", "draft preserved, not clobbered with empty")
        XCTAssertNotNil(e?.transcriptionError, "a diagnostic error is recorded")
    }

    func test_thrownFailure_setsError() async throws {
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber(); mock.mode = .failure
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        await inbox.refresh()
        let e = inbox.entries.first { $0.id == "a1" }
        XCTAssertEqual(e?.transcriptionState, .failed)
        XCTAssertNotNil(e?.transcriptionError, "thrown error is surfaced")
    }

    func test_userEditDuringFailingTranscription_isNotClobbered() async throws {
        // Same protection as the success path, but for a failing transcription:
        // a concurrent user edit must not be overwritten by a .failed write.
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber(); mock.mode = .failure
        mock.onStart = { [inbox] in
            await inbox.updateTranscript(id: "a1", text: "my edit", state: .userEdited)
        }
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        await inbox.refresh()
        let e = inbox.entries.first { $0.id == "a1" }
        XCTAssertEqual(e?.transcriptionState, .userEdited,
                       "a user edit during a failing transcription must survive")
        XCTAssertEqual(e?.transcript, "my edit")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamTests/InboxTranscriptionWorkerTests 2>&1 | tail -30
```
Expected: `test_emptyResult_*` FAILS (state is `.whisperFinal`, transcript clobbered to `""`); `test_thrownFailure_setsError` FAILS (no error stored); `test_userEditDuringFailingTranscription_*` FAILS (edit clobbered by `.failed`).

- [ ] **Step 3: Restructure the per-entry loop**

In `Maugham/Stores/InboxTranscriptionWorker.swift`, replace the `for entry in eligible { ... }` loop body (lines 64-84) with the following. Note the structure: compute the outcome (`text`/`state`/`error`) for all three cases — success, empty-is-failure, thrown-failure — and fall through to a **single** shared post-await re-check + write. The thrown case must NOT `continue`; it sets the outcome and falls through like the others, or the failure won't be recorded.

```swift
        for entry in eligible {
            guard let url = inboxStore.assetURL(for: entry) else { continue }
            let text: String
            let state: InboxEntry.TranscriptionState
            let error: String?
            do {
                let result = try await transcriber.transcribe(url, model: model)
                if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // WhisperKit returns no segments for a silent/unclear clip and
                    // does NOT throw. Treat empty as a failure and preserve the
                    // on-device draft instead of overwriting it with empty text.
                    log.error("transcription empty for \(entry.id, privacy: .public)")
                    text = entry.transcript ?? ""
                    state = .failed
                    error = "WhisperKit produced no text for this clip — it may be "
                          + "silent or unclear. Try a larger model, or re-record."
                } else {
                    text = result
                    state = .whisperFinal
                    error = nil
                }
            } catch let thrown {
                log.error("transcription failed for \(entry.id, privacy: .public): \(thrown.localizedDescription, privacy: .public)")
                text = entry.transcript ?? ""   // preserve the on-device draft
                state = .failed
                error = thrown.localizedDescription
            }
            // Single post-await eligibility re-check guards EVERY outcome against a
            // concurrent user edit (→ .userEdited) clobber. Refresh first so the
            // edit's row (already appended) is visible.
            await inboxStore.refresh()
            let current = inboxStore.entries.first { $0.id == entry.id }?.transcriptionState
            guard current == .none || current == .onDeviceDraft else { continue }
            await inboxStore.updateTranscript(id: entry.id, text: text, state: state, error: error)
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamTests/InboxTranscriptionWorkerTests 2>&1 | tail -30
```
Expected: PASS — all worker tests, including the three new ones and the existing `test_failure_marksFailed_keepsDraft`, `test_userEditDuringTranscription_isNotClobbered`, `test_serial_oneTranscriptionAtATime`.

- [ ] **Step 5: Update the header comment**

In `Maugham/Stores/InboxTranscriptionWorker.swift`, replace the comment paragraph (lines 12-14) that begins `/// `.failed` entries are not auto-retried` with:

```swift
/// `.failed` entries are not *auto*-retried (avoids hammering a corrupt file);
/// the writer re-arms one explicitly via `DocumentStore.retranscribe` (the
/// "Transcribe Again" pane gesture), which resets it to `.onDeviceDraft` so this
/// worker picks it up with the current Settings model. An empty result is
/// treated as a failure (it does not throw) so it can't clobber the draft.
/// Long audio (>5 min) is not chunked in v1 — WhisperKit degrades past ~5 min.
```

- [ ] **Step 6: Commit**

```bash
git add Maugham/Stores/InboxTranscriptionWorker.swift MaughamTests/InboxTranscriptionWorkerTests.swift
git commit -m "fix(inbox): empty transcription is a failure, not a draft clobber

WhisperKit returns no segments (empty string, no throw) for silent/unclear
clips; the worker treated that as success and overwrote the on-device draft
with nothing. Route empty -> .failed with a diagnostic error, preserve the
draft, and add a single post-await eligibility re-check so failures (like
successes) can't clobber a concurrent user edit."
```

---

## Task 4: `DocumentStore.retranscribe(_:)`

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift`

This is a thin delegate (re-arm via the tested `InboxStore`, then poke the tested worker). No dedicated unit test — `DocumentStore` is the disk-opened coordinator and its inbox/worker behaviors are covered by Tasks 2–3; this method is verified by the manual smoke at the end. (Per CLAUDE.md: trivial delegates skip the formal review.)

- [ ] **Step 1: Add the method**

In `Maugham/Stores/DocumentStore.swift`, add directly after the `transcriptionWorker` computed property (after line 51, before the `makeTranscriber` doc comment):

```swift
    /// Re-arm an inbox audio entry for transcription and kick the worker. Resets
    /// the entry to `.onDeviceDraft` (clearing any failure error) and pokes the
    /// worker, which reads the current Settings model fresh — so this is also the
    /// "I switched to a better model, redo this clip" path. Backs the InboxPane
    /// "Transcribe Again" gesture.
    @MainActor
    func retranscribe(_ entry: InboxEntry) async {
        await inboxStore.requestRetranscription(id: entry.id)
        transcriptionWorker.onInboxChanged()
    }
```

- [ ] **Step 2: Verify it compiles (build the test target)**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build-for-testing CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Stores/DocumentStore.swift
git commit -m "feat(inbox): DocumentStore.retranscribe re-arms entry + pokes worker"
```

---

## Task 5: InboxPane — "Transcribe Again", error subtitle, edit-sheet note; wire from DetailPaneToggle

**Files:**
- Modify: `Maugham/Views/InboxPane.swift`
- Modify: `Maugham/Views/DetailPaneToggle.swift`

SwiftUI views aren't unit-tested in this codebase; this task is verified by the manual smoke (final section). Build-for-testing must still succeed.

- [ ] **Step 1: Add init params to `InboxPane`**

In `Maugham/Views/InboxPane.swift`, add two stored properties after `let projectStore: ProjectStore` (line 17):

```swift
    let projectStore: ProjectStore
    /// True when local transcription is available (Apple Silicon). Gates the
    /// "Transcribe Again" affordance — there's no transcriber on Intel.
    let canTranscribe: Bool
    /// Re-arm + kick transcription for an entry (DocumentStore.retranscribe).
    let retranscribe: (InboxEntry) -> Void
```

- [ ] **Step 2: Add the "Transcribe Again" menu item**

In `Maugham/Views/InboxPane.swift`, in `row(_:)`'s `.contextMenu` (lines 170-179), insert the re-transcribe item. Replace the existing contextMenu block with:

```swift
        .contextMenu {
            Button("Promote to Research") { promote(entry) }
            if entry.kind == .audio {
                Button("Edit Transcript…") { editing = entry }
                if canTranscribe,
                   entry.transcriptionState == .failed || entry.transcriptionState == .whisperFinal {
                    Button("Transcribe Again") {
                        audio.stop()
                        retranscribe(entry)
                    }
                }
            }
            Divider()
            Button("Trash", role: .destructive) {
                Task { await store.updateStatus(id: entry.id, to: .trashed) }
            }
        }
```

- [ ] **Step 3: Show the failure reason in the subtitle**

In `Maugham/Views/InboxPane.swift`, the row's subtitle `Text` (lines 160-164) needs the warning color when failed. Replace the `if let subtitle = subtitle(for: entry)` block with:

```swift
                if let subtitle = subtitle(for: entry) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(entry.transcriptionState == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
```

Then update `subtitle(for:)` (lines 213-220) to surface the error:

```swift
    private func subtitle(for entry: InboxEntry) -> String? {
        let relative = Self.relativeFormatter.localizedString(
            for: entry.createdAt, relativeTo: Date())
        if entry.transcriptionState == .failed {
            if let err = entry.transcriptionError, !err.isEmpty {
                return "Failed · \(err)"
            }
            return "Failed · \(relative)"
        }
        if entry.kind == .audio, entry.transcriptionState == .onDeviceDraft {
            return "Draft · \(relative)"
        }
        return relative
    }
```

- [ ] **Step 4: Show the error in the Edit Transcript sheet**

In `Maugham/Views/InboxPane.swift`, the `.sheet(item: $editing)` (lines 50-60) constructs `EditTranscriptSheet(initialText:)`. Pass the error in:

```swift
        .sheet(item: $editing) { entry in
            EditTranscriptSheet(initialText: entry.transcript ?? "",
                                errorNote: entry.transcriptionError) { newText in
                Task { await store.updateTranscript(id: entry.id, text: newText, state: .userEdited) }
            }
        }
```

Then update `EditTranscriptSheet` (lines 226-252) to accept and render `errorNote`:

```swift
private struct EditTranscriptSheet: View {
    @State private var text: String
    let errorNote: String?
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(initialText: String, errorNote: String? = nil, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: initialText)
        self.errorNote = errorNote
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Transcript").font(.headline)
            if let errorNote, !errorNote.isEmpty {
                Label(errorNote, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 360, minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(text); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
```

- [ ] **Step 5: Wire `canTranscribe` + `retranscribe` from `DetailPaneToggle`**

In `Maugham/Views/DetailPaneToggle.swift`, replace the `inboxPane` body's `InboxPane(...)` call (line 173) with:

```swift
            InboxPane(store: ds.inboxStore, projectStore: store,
                      canTranscribe: Self.localTranscriptionAvailable,
                      retranscribe: { entry in Task { await ds.retranscribe(entry) } })
```

Add this static near the top of the `DetailPaneToggle` struct (mirrors `DocumentStore.makeTranscriber`'s arch gate without exposing the transcriber):

```swift
    /// Local transcription exists only on Apple Silicon (see DocumentStore.makeTranscriber).
    private static var localTranscriptionAvailable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
```

- [ ] **Step 6: Build the app target**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build-for-testing CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`. If `DetailPaneToggle` can't see `localTranscriptionAvailable`, confirm it was added inside the struct, not the extension.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Views/InboxPane.swift Maugham/Views/DetailPaneToggle.swift
git commit -m "feat(inbox): Transcribe Again menu + failure reason in pane/edit sheet

Audio rows in .failed/.whisperFinal gain a Transcribe Again item (Apple
Silicon only); failed rows show the reason in the subtitle and the edit
sheet surfaces it above the draft."
```

---

## Task 6: Full suite + manual smoke

- [ ] **Step 1: Run the full Mac test suite**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25
```
Expected: all tests pass (the existing ~1532 + the new ones). If a phantom `Undefined symbol` link error appears after the `InboxEntry` public-init change, run `xcodebuild ... clean` once then re-test (CLAUDE.md: stale DerivedData after public-init changes).

- [ ] **Step 2: Run the MaughamCore-only tests**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamCoreTests 2>&1 | tail -15
```
Expected: PASS.

- [ ] **Step 3: Hand off for manual smoke (user runs this)**

The user runs the smoke manually (CLAUDE.md). Provide these steps:
1. Open a project that has an inbox audio capture (or sync one from MaughamPhone).
2. Confirm a previously-blank/failed audio row now shows `Failed · …` in orange with a reason (if it failed) — or its transcript if it succeeded.
3. Right-click the audio row → **Transcribe Again** → confirm it re-runs and the transcript updates (try after switching the model in Settings → Voice to a larger one).
4. Right-click a `.whisperFinal` row → **Transcribe Again** is offered; right-click a `.userEdited` row (one you edited) → it is **not** offered.
5. On Intel hardware (if available), confirm **Transcribe Again** does not appear.

Do not claim the feature works until the user confirms the smoke.

---

## Notes for the implementer

- **No migration.** The new field is additive and optional; existing inbox manifests decode fine (Task 1 test proves it). Don't write migration code.
- **Tripwire 19 (cross-surface contract):** `transcriptionError` is Mac-only in practice — the phone never reads or writes it. Because it's optional, no phone change is required and `TripwirePhoneGrepTest`/`TripwireGrepTests` are unaffected. Do not add a phone-side implementation.
- **Tripwire 13 ("maugham" literals):** none introduced — the worker's logger already derives its subsystem from the bundle id.
- **`./gen.sh`:** only needed if a newly-created file isn't compiled. MaughamCore sources and `MaughamTests`/`MaughamCoreTests` are folder references, so usually not required — but run it if a new test file is ignored.
```
