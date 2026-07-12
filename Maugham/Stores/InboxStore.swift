import Foundation
import MaughamCore
import os

// Subsystem from the running bundle id so dev/stable logs separate without
// hardcoding "com.maugham" (tripwire 13 spirit).
private let inboxStoreLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "InboxStore")

/// Owns a project's capture inbox (`.maugham/inbox/`). One per project window,
/// created by `DocumentStore`. Reads every per-device manifest stream
/// (`inbox.<slug>.jsonl` + legacy `inbox.jsonl`, ADR 0012) and presents the
/// `.new` entries newest-first; mutations append a fresh row (same `id`,
/// updated fields) to *this* Mac's own stream and re-`refresh()`.
///
/// Two layered merge semantics, both needed:
///   1. Status transitions append rows with the same `id` (new → promoted →
///      trashed), so we must keep the **newest** row per id — the opposite of
///      the op log's immutable first-wins. Hence `load()` is called with no
///      `dedupKey` (every row) and the merge does last-wins by `createdAt`.
///   2. Across per-device files, the same last-wins-by-`createdAt` rule lets a
///      phone "create" and a Mac "promote" for one id both survive, newest
///      winning, with neither file's writes silently lost.
@MainActor
@Observable
final class InboxStore {
    /// `.new` entries only, newest first. promoted/trashed are filtered out
    /// (they don't belong in the triage pane).
    private(set) var entries: [InboxEntry] = []

    /// `.trashed` entries, newest first — backs the inbox Trash view, where a
    /// capture can be restored. Trash only flips status (the asset stays in
    /// `inbox/`), so `restore` is a clean status flip back to `.new`.
    private(set) var trashedEntries: [InboxEntry] = []

    private let projectURL: URL
    private let inboxDir: URL
    /// This Mac's own device identifier — matches the op-log `device` (hostName)
    /// so a single machine's inbox + op-log writes carry a consistent identity.
    private let deviceId: String

    init(projectURL: URL, deviceId: String = InboxStore.currentDeviceId) {
        self.projectURL = projectURL
        self.inboxDir = projectURL.appendingPathComponent(".maugham/inbox")
        self.deviceId = deviceId
    }

    /// Mirrors `EditorHost.deviceId`: hostName, best-effort stable per machine.
    nonisolated static var currentDeviceId: String { MacDeviceID.current }

    private var ownManifestURL: URL {
        InboxManifest.inboxManifestURL(forDeviceSlug: DeviceSlug.make(from: deviceId),
                                       in: projectURL)
    }

    // MARK: - Read

    func refresh() async {
        let urls = manifestURLs()
        var rows: [InboxEntry] = []
        for url in urls {
            // No dedupKey: we need every status-transition row, then collapse
            // last-wins ourselves (JSONLAppendStore's dedup keeps *first*).
            let store = JSONLAppendStore<InboxEntry>(fileURL: url)
            rows.append(contentsOf: (try? await store.load()) ?? [])
        }
        // Last-wins by row-write time (writtenAt), across all files and all
        // rows for an id. createdAt is immutable across transition rows, so it
        // can't order them; writtenAt is stamped fresh on every append.
        func writeTime(_ e: InboxEntry) -> Date { e.writtenAt ?? e.createdAt }
        rows.sort { writeTime($0) < writeTime($1) }
        var byId: [String: InboxEntry] = [:]
        for row in rows { byId[row.id] = row }
        let collapsed = Array(byId.values)
        entries = collapsed
            .filter { $0.status == .new }
            .sorted { $0.createdAt > $1.createdAt }
        trashedEntries = collapsed
            .filter { $0.status == .trashed }
            .sorted { writeTime($0) > writeTime($1) }
    }

    private func manifestURLs() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: inboxDir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { url in
            let n = url.lastPathComponent
            return n == "inbox.jsonl"
                || (n.hasPrefix("inbox.") && n.hasSuffix(".jsonl"))
        }
    }

    // MARK: - Mutations (append a new row to this Mac's own stream)

    /// Append `entry` verbatim to this device's manifest. The caller supplies a
    /// fully-formed row (used by promote/trash/transcript transitions, which
    /// build the next row from the current one).
    private func append(_ entry: InboxEntry) async {
        try? FileManager.default.createDirectory(
            at: inboxDir, withIntermediateDirectories: true)
        var stamped = entry
        // Monotonic per-entry writtenAt: strictly newer than the row this
        // transition supersedes, so the new state always wins the last-wins
        // merge even when the prior row's writtenAt is in the future relative to
        // this Mac's clock (cross-device skew — e.g. the phone's clock ahead).
        // `entry` is built from the current winning row, so `entry.writtenAt` is
        // the max seen for this id; +1ms guarantees we out-rank it. Without this,
        // a future-dated draft out-ranks the Mac's transcript forever and the
        // worker re-transcribes in an infinite loop. (Smoke caught this.)
        let basis = entry.writtenAt ?? entry.createdAt
        stamped.writtenAt = max(Date(), basis.addingTimeInterval(0.001))
        let store = JSONLAppendStore<InboxEntry>(fileURL: ownManifestURL)
        // LOG (can't cleanly propagate): `append` is `async` non-throwing and
        // its callers are fire-and-forget UI transitions (promote/trash/
        // transcript). The manifest is the inbox's source of truth — a
        // swallowed `try?` would lose a status transition silently (e.g. a
        // promote that never persists), so surface the failure.
        do { try await store.append(stamped) }
        catch {
            inboxStoreLog.error(
                "inbox manifest append failed for entry \(stamped.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

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

    /// Move an entry to a terminal status (`.promoted` / `.trashed`), stamping
    /// `resolvedAt`. Asset relocation (into `research/` or `.maugham/trash/`) is
    /// the caller's responsibility and must be coordinated separately.
    func updateStatus(id: String, to status: InboxEntry.Status,
                      resolvedAt: Date? = Date()) async {
        guard var next = currentEntry(id: id) else { return }
        next.status = status
        next.resolvedAt = resolvedAt
        await append(next)
        await refresh()
    }

    /// The current (newest) row for `id` from the in-memory `entries`. Since
    /// `entries` is `.new`-only, this finds entries eligible for transition.
    private func currentEntry(id: String) -> InboxEntry? {
        entries.first { $0.id == id } ?? trashedEntries.first { $0.id == id }
    }

    /// Restore a trashed capture to the triage pane. Flips status back to `.new`
    /// and clears `resolvedAt`; the asset never left `inbox/`, so nothing to move.
    func restore(id: String) async {
        await updateStatus(id: id, to: .new, resolvedAt: nil)
    }

    enum InboxError: Error, LocalizedError {
        case assetMissing(String)
        case entryNotFound(String)
        case nothingToPromote(String)
        var errorDescription: String? {
            switch self {
            case .assetMissing(let n): return "Inbox asset file is missing: \(n)"
            case .entryNotFound(let id): return "Inbox entry not found or already resolved: \(id)"
            case .nothingToPromote:
                return "This capture has nothing to promote yet — record or add a transcript first."
            }
        }
    }

    /// Move a capture into `research/` and mark the manifest row `.promoted`.
    /// Shared by the InboxPane menu and the MCP `promote_inbox_entry` tool so
    /// both surfaces produce identical results. Text entries become a research
    /// `.md`; image/audio entries copy into `research/` (via the existing
    /// `addResearchAsset` flow) and the inbox original is removed to complete
    /// the move. Non-destructive in the failure sense: if the original removal
    /// fails, a duplicate asset is left (harmless) rather than data lost.
    /// A `scope` routes the created item — shared research, a collection
    /// piece's folder, or a chapter link (spec 2026-07-07).
    @discardableResult
    func promoteToResearch(
        _ entry: InboxEntry, projectStore: ProjectStore,
        scope: ResearchScope = .shared
    ) async throws -> ResearchItem {
        let created: ResearchItem
        switch entry.kind {
        case .text:
            created = try await projectStore.createResearchNote(
                scope: scope, title: promotionTitle(for: entry))
            if let path = created.path {
                let dest = projectStore.url.appendingPathComponent(path)
                try? (entry.inlineText ?? "").write(
                    to: dest, atomically: true, encoding: .utf8)
            }
        case .image, .audio:
            guard let asset = assetURL(for: entry),
                  FileManager.default.fileExists(atPath: asset.path) else {
                throw InboxError.assetMissing(entry.sourceFilename ?? entry.id)
            }
            // createResearchAsset copies; remove the inbox original to finish
            // the move. The asset lives under .maugham/inbox/ and is never an
            // open Document, so no close-before-FS guard (tripwire 14) needed.
            created = try await projectStore.createResearchAsset(
                scope: scope, fromURL: asset)
            try? FileManager.default.removeItem(at: asset)
        }
        await updateStatus(id: entry.id, to: .promoted)
        return created
    }

    /// Promote a capture INTO an existing palette card (sibling of
    /// `promoteToResearch`, same status handling). `.text`/`.audio` append a
    /// `SensoryNote` — tagged with `entry.sense` when it maps to a known `Sense`,
    /// untagged otherwise — carrying the inline text / transcript. `.image` copies
    /// the asset into the card's image well and removes the inbox original to
    /// complete the move (mirroring `promoteToResearch`'s copy-then-delete).
    ///
    /// The manifest row flips `.promoted` only after every mutating step
    /// succeeds, so a failure never leaves a half-promoted entry: an audio
    /// capture with no transcript throws and stays `.new` (the writer can
    /// transcribe and retry); an unknown `cardId` propagates the palette seam's
    /// throw. An asset removal that fails post-copy is non-fatal (a harmless
    /// duplicate is left rather than the note/image lost).
    @discardableResult
    func promoteToPaletteCard(
        _ entry: InboxEntry, projectStore: ProjectStore, cardId: String
    ) async throws -> PaletteCard {
        let sense = entry.sense.flatMap { PaletteCard.Sense(rawValue: $0) }
        let result: PaletteCard
        switch entry.kind {
        case .text:
            let text = Self.flattenToNote(entry.inlineText ?? "")
            result = try await appendSensoryNote(
                .init(sense: sense, text: text), toCard: cardId, projectStore: projectStore)
        case .audio:
            let text = Self.flattenToNote(entry.transcript ?? "")
            guard !text.isEmpty else { throw InboxError.nothingToPromote(entry.id) }
            result = try await appendSensoryNote(
                .init(sense: sense, text: text), toCard: cardId, projectStore: projectStore)
        case .image:
            guard let asset = assetURL(for: entry),
                  FileManager.default.fileExists(atPath: asset.path) else {
                throw InboxError.assetMissing(entry.sourceFilename ?? entry.id)
            }
            // addImage copies into the card's `<slug>_assets/` folder; remove the
            // inbox original to finish the move. Same non-destructive contract as
            // promoteToResearch: a failed removal leaves a duplicate, never data loss.
            result = try await projectStore.addImage(toPaletteCard: cardId, fileURL: asset)
            try? FileManager.default.removeItem(at: asset)
        }
        await updateStatus(id: entry.id, to: .promoted)
        return result
    }

    /// Load the card, append `note`, and persist via the palette seam. Throws
    /// `ProjectStoreError.structureMissing` for an unknown `cardId` (the same
    /// failure the seam's `updatePaletteCard` raises), so a bad target can't
    /// silently drop a promoted note.
    private func appendSensoryNote(
        _ note: PaletteCard.SensoryNote, toCard cardId: String, projectStore: ProjectStore
    ) async throws -> PaletteCard {
        guard let card = projectStore.loadPaletteCards()
            .first(where: { $0.researchItemId == cardId }) else {
            throw ProjectStoreError.structureMissing
        }
        let updated = PaletteCard(
            researchItemId: card.researchItemId, title: card.title, kind: card.kind,
            swatches: card.swatches, notes: card.notes + [note],
            imagePaths: card.imagePaths, body: card.body)
        try await projectStore.updatePaletteCard(updated)
        return updated
    }

    /// Collapse a capture's multi-line text into a single sensory-note line:
    /// trim each line, drop blanks, join with a space. A `SensoryNote` is one
    /// line of prose, so paragraph structure doesn't survive — the writer edits
    /// the card afterward if they want more.
    private static func flattenToNote(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func promotionTitle(for entry: InboxEntry) -> String {
        if let t = entry.title, !t.isEmpty { return t }
        let body = entry.inlineText ?? entry.transcript ?? ""
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return String(trimmed.prefix(60)) }
        switch entry.kind {
        case .image: return "Photo capture"
        case .audio: return "Voice capture"
        case .text:  return "Text capture"
        }
    }

    /// Absolute URL of an entry's asset file (image/audio), or nil for inline
    /// text. Used by the pane for playback and by promote/trash for relocation.
    /// Resolves via `InboxConvention` (MaughamCore) — the single source of
    /// truth shared with the phone writer's asset placement (E5a).
    ///
    /// `sourceFilename` is sidecar-supplied (a manifest row read off disk) —
    /// validated to stay inside the kind's asset subdir before being handed
    /// back as a URL (A5). An escaping filename resolves to nil, the same as
    /// a `.text` entry with no asset — every existing caller already treats
    /// nil as "nothing to relocate/play" and fails loudly downstream (e.g.
    /// `InboxError.assetMissing`).
    func assetURL(for entry: InboxEntry) -> URL? {
        guard let name = entry.sourceFilename,
              let dir = InboxConvention.assetDir(for: entry.kind, inboxDir: inboxDir) else {
            return nil
        }
        return try? SafeRelativePath.resolve(name, under: dir)
    }
}
