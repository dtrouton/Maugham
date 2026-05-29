import Foundation
import MaughamCore

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
    /// `.new` entries only, newest first. promoted/trashed are terminal and
    /// filtered out (they don't belong in the triage pane).
    private(set) var entries: [InboxEntry] = []

    private let inboxDir: URL
    /// This Mac's own device identifier — matches the op-log `device` (hostName)
    /// so a single machine's inbox + op-log writes carry a consistent identity.
    private let deviceId: String

    init(projectURL: URL, deviceId: String = InboxStore.currentDeviceId) {
        self.inboxDir = projectURL.appendingPathComponent(".maugham/inbox")
        self.deviceId = deviceId
    }

    /// Mirrors `EditorHost.deviceId`: hostName, best-effort stable per machine.
    nonisolated static var currentDeviceId: String {
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? "unknown-host" : name
    }

    private var ownManifestURL: URL {
        inboxDir.appendingPathComponent("inbox.\(DeviceSlug.make(from: deviceId)).jsonl")
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
        entries = byId.values
            .filter { $0.status == .new }
            .sorted { $0.createdAt > $1.createdAt }
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
        stamped.writtenAt = Date()   // row-write time orders the last-wins merge
        let store = JSONLAppendStore<InboxEntry>(fileURL: ownManifestURL)
        try? await store.append(stamped)
    }

    /// Replace an entry's transcript + transcription state (Whisper result, or a
    /// manual correction). Preserves every other field. No-op if `id` is unknown.
    func updateTranscript(id: String, text: String,
                          state: InboxEntry.TranscriptionState) async {
        guard var next = currentEntry(id: id) else { return }
        next.transcript = text
        next.transcriptionState = state
        await append(next)
        await refresh()
    }

    /// Move an entry to a terminal status (`.promoted` / `.trashed`), stamping
    /// `resolvedAt`. Asset relocation (into `research/` or `.maugham/trash/`) is
    /// the caller's responsibility and must be coordinated separately.
    func updateStatus(id: String, to status: InboxEntry.Status,
                      resolvedAt: Date = Date()) async {
        guard var next = currentEntry(id: id) else { return }
        next.status = status
        next.resolvedAt = resolvedAt
        await append(next)
        await refresh()
    }

    /// The current (newest) row for `id` from the in-memory `entries`. Since
    /// `entries` is `.new`-only, this finds entries eligible for transition.
    private func currentEntry(id: String) -> InboxEntry? {
        entries.first { $0.id == id }
    }

    /// Absolute URL of an entry's asset file (image/audio), or nil for inline
    /// text. Used by the pane for playback and by promote/trash for relocation.
    func assetURL(for entry: InboxEntry) -> URL? {
        guard let name = entry.sourceFilename else { return nil }
        let subdir: String
        switch entry.kind {
        case .image: subdir = "images"
        case .audio: subdir = "audio"
        case .text:  return nil
        }
        return inboxDir.appendingPathComponent(subdir).appendingPathComponent(name)
    }
}
