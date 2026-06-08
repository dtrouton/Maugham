# Inbox Re-transcribe + Failure Visibility — Design

**Date:** 2026-06-07
**Status:** Approved (brainstorm), pre-plan

## Problem

A voice capture in the inbox came back with a **blank** transcript even though the
phone's on-device draft had text, and there was no failure indicator. Two gaps:

1. **No way to re-run transcription.** `InboxTranscriptionWorker.processEligible()`
   only processes entries whose `transcriptionState` is `.none` or `.onDeviceDraft`.
   `.failed` and `.whisperFinal` entries are never re-run, so there is no recovery
   path — neither for a failure nor for "I switched to a better model and want this
   clip redone."

2. **A latent clobber bug masquerading as the failure.** `WhisperKitTranscriber.transcribe`
   returns `results.map(\.text).joined(...).trimmingCharacters(...)`. When WhisperKit
   yields **no segments** (a silent/unclear clip, or a decode that produces nothing),
   that expression is the empty string `""` and **does not throw**. The worker's
   success path then writes `state: .whisperFinal` with empty text, **overwriting the
   on-device draft with nothing**. The draft-preservation on the failure path only runs
   when `transcribe` actually throws — an empty-but-"successful" result sails past it.
   This is why the observed entry went blank *and* showed no `.failed` state.

   (The reporting clip was well under WhisperKit's ~5 min degradation threshold, so
   length was not the cause — a short clip producing empty output points at silence,
   decode failure, or an under-powered model, all of which a re-run with a larger model
   can plausibly fix.)

## Goals

- Treat an empty transcription result as a **failure**, preserving the existing draft.
- Surface **why** a transcription failed, in the inbox pane and the edit sheet.
- Let the writer **re-trigger transcription** on `.failed` and `.whisperFinal` audio
  entries — picking up the currently-configured (possibly upgraded) model.

## Non-goals

- **Chunking long audio (>5 min).** Deferred in v1; remains deferred. The error text
  names length as a *secondary* suspect so the writer knows a re-run may not help that
  specific case, but no chunking is built here.
- **Bulk "re-transcribe all" in Settings.** Out of scope; per-entry gesture only. Can
  be added later if a model upgrade needs to sweep many clips.
- **Re-transcribing `.userEdited` entries.** The writer owns that transcript; the
  gesture is not offered for it (consistent with the worker never overwriting it).

## Design

### Part 1 — Empty result is a failure (bug fix)

In `InboxTranscriptionWorker.processEligible()`, after `let text = try await transcriber.transcribe(...)`:

- **Non-empty `text`** → existing success path (post-await eligibility re-check, then
  `updateTranscript(..., state: .whisperFinal, error: nil)`).
- **Empty `text`** (already trimmed by the transcriber) → failure path: preserve the
  existing draft (`entry.transcript ?? ""`), set `state: .failed`, and stamp
  `error: "WhisperKit produced no text for this clip — it may be silent or unclear. "
  + "Try a larger model, or re-record."`

The existing `catch` (a thrown error — model download failure, unreadable file) keeps
preserving the draft and now also stamps `error: error.localizedDescription`.

Both failure routes preserve the draft; neither clobbers a non-empty transcript.

### Part 2 — `transcriptionError` on `InboxEntry` (MaughamCore)

Add to `InboxEntry`:

```swift
public var transcriptionError: String?   // nil unless the last transcription attempt failed
```

- JSON key `transcription_error` (snake_case, matching the file's convention).
- **Optional**, so older phone/Mac readers decode it as `nil` — no migration, no
  cross-surface break (tripwire 19). The phone does not read or write it.
- Added to `init` (defaulted `nil`) and `CodingKeys`.

`InboxStore.updateTranscript` gains an `error: String? = nil` parameter so the success
path can **clear** it (`error: nil`) and the failure path can **set** it. The stored
row's `transcriptionError` is set to the passed value on every transition.

### Part 3 — Re-transcribe gesture

**`InboxStore.requestRetranscription(id:)`** — appends a transition row for the entry
that:
- resets `transcriptionState` to `.onDeviceDraft` (keeping the current `transcript`
  text as the draft, so a *second* failure still has something to preserve),
- clears `transcriptionError` (`nil`),
- leaves `status` (`.new`) and all other fields unchanged.

No-op if `id` is unknown (consistent with the other mutations).

**`DocumentStore.retranscribe(_ entry:)`** — `await inboxStore.requestRetranscription(id: entry.id)`
then `transcriptionWorker.onInboxChanged()`. The worker reads `configuredModel` fresh
each drain, so the re-run uses the current Settings model.

**`InboxPane`** — a context-menu item **"Transcribe Again"** on audio rows, shown only
when:
- a transcriber is available (hidden on Intel, where `makeTranscriber()` is `nil`), and
- the entry's state is `.failed` or `.whisperFinal`.

Not offered for `.userEdited` (protects manual edits) or `.onDeviceDraft`/`.none`
(already auto-running). Wired via a `retranscribe: (InboxEntry) -> Void` closure passed
from `DetailPaneToggle.inboxPane`, where the `DocumentStore` (`ds`) is in scope:
`InboxPane(store:projectStore:canTranscribe:retranscribe:)`.

**Failure surfacing in `InboxPane`:**
- `subtitle(for:)` — when `transcriptionState == .failed`, return
  `"Failed · \(error)"` (truncated by the existing `.lineLimit(1)`), rendered in the
  warning color (e.g. `.foregroundStyle(.orange)` on that row's subtitle).
- `EditTranscriptSheet` — when an error is present, show it as a caption note above the
  `TextEditor`, so the writer sees the reason alongside the preserved draft.

`canTranscribe` is derived once at the `DetailPaneToggle` call site (`#if arch(arm64)`),
mirroring `makeTranscriber()`'s gate, and passed in — the pane stays free of `#if`.

## Data flow

```
Settings model change ──┐
                        ▼
"Transcribe Again" → DocumentStore.retranscribe(entry)
        │                   │
        │                   ├─ InboxStore.requestRetranscription(id)
        │                   │     → append row: state=.onDeviceDraft, error=nil
        │                   └─ worker.onInboxChanged()
        ▼                         │
   (auto path also)               ▼
                          processEligible() — reads current model
                                  │
                          transcribe(url, model)
                          ┌───────┴────────┐
                       throws            returns text
                          │           ┌────┴─────┐
                          ▼        empty ""    non-empty
                    .failed +        │            │
                    error=localized  ▼            ▼
                    (draft kept)  .failed +    re-check eligibility
                                  error=        then .whisperFinal,
                                  "no text…"    error=nil
                                  (draft kept)
```

## Testing

Extend `InboxTranscriptionWorkerTests` and `InboxStore` coverage:

1. **Empty result → failed, draft preserved.** Stub `Transcriber` returns `""`; entry
   starting `.onDeviceDraft` with draft text ends `.failed`, `transcript` unchanged
   (draft intact), `transcriptionError` set to the no-text message.
2. **Thrown error → failed, draft preserved, error = localizedDescription.** Stub
   throws; assert state/draft/error.
3. **Re-transcribe a `.whisperFinal` entry.** After `requestRetranscription`, the entry
   is eligible; a stub returning new text drives it to `.whisperFinal` with the new text
   and `error == nil`.
4. **`requestRetranscription` mechanics.** Appends a row with `state == .onDeviceDraft`,
   `transcriptionError == nil`, transcript text preserved, status still `.new`; no-op on
   unknown id.
5. **Success path clears a prior error.** An entry with a stored `transcriptionError`
   that then transcribes non-empty ends with `error == nil`.

## Files touched

- `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift` — new field + key.
- `Maugham/Stores/InboxStore.swift` — `updateTranscript(error:)`, `requestRetranscription`.
- `Maugham/Stores/InboxTranscriptionWorker.swift` — empty-result branch + error stamping;
  update the header comment about `.failed` retry.
- `Maugham/Stores/DocumentStore.swift` — `retranscribe(_:)`.
- `Maugham/Views/InboxPane.swift` — context-menu item, subtitle error, edit-sheet note,
  new init params.
- `Maugham/Views/DetailPaneToggle.swift` — pass `canTranscribe` + `retranscribe`.
- `MaughamTests/InboxTranscriptionWorkerTests.swift` (+ store test file as needed).
