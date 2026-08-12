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

    /// Device manifests `refresh()` could not read, by filename (RULING-7,
    /// M8-IN-012: unreadable is never presented as empty — before this, an
    /// unreadable file silently vanished every capture from that device). The
    /// pane shows a notice when non-empty; the rows are intact on disk.
    private(set) var unreadableManifests: [String] = []

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
        var unreadable: [String] = []
        for url in urls {
            // No dedupKey: we need every status-transition row, then collapse
            // last-wins ourselves (JSONLAppendStore's dedup keeps *first*).
            let store = JSONLAppendStore<InboxEntry>(fileURL: url)
            do { rows.append(contentsOf: try await store.loadStrict()) }
            catch {
                // Unreadable is RECORDED, never presented as empty (RULING-7):
                // the device's captures are intact in the file; the pane says
                // so instead of showing nothing.
                unreadable.append(url.lastPathComponent)
                inboxStoreLog.error(
                    "inbox manifest unreadable: \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        unreadableManifests = unreadable.sorted()
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
        // RULING-53: the inbox trash keeps the project trash's retention — a
        // trashed capture ages out at 30 days on RULING-39's quiet clock. The
        // sweep disposes the ASSET and hides the row; the manifest row itself
        // stays `.trashed`, because a new status value would decode as `.new`
        // on an older phone build (ADR 0015's unknown-case tolerance) and
        // resurrect the capture there. Age is `resolvedAt` (stamped at trash
        // time, cleared by restore), falling back to the row's write time for
        // legacy rows.
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let trashed = collapsed.filter { $0.status == .trashed }
        for expired in trashed where (expired.resolvedAt ?? writeTime(expired)) < cutoff {
            if let asset = assetURL(for: expired),
               FileManager.default.fileExists(atPath: asset.path) {
                try? FileManager.default.removeItem(at: asset)
            }
        }
        trashedEntries = trashed
            .filter { ($0.resolvedAt ?? writeTime($0)) >= cutoff }
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
    /// Fire-and-forget append: persists `entry` and LOGS (can't cleanly
    /// propagate) if the write fails. Its callers are UI transitions
    /// (trash/restore/transcript) with no throwing channel; the manifest is the
    /// inbox's source of truth, so a swallowed `try?` would lose a status
    /// transition silently — hence surface the failure to the log at least.
    /// Paths that CAN propagate (the promote flows) use `appendThrowing`.
    private func append(_ entry: InboxEntry) async {
        do { try await appendThrowing(entry) }
        catch {
            inboxStoreLog.error(
                "inbox manifest append failed for entry \(entry.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Throwing core of `append`, used by callers with a throwing channel (the
    /// promote flows) so a failed terminal status write surfaces instead of
    /// being swallowed (S8).
    private func appendThrowing(_ entry: InboxEntry) async throws {
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
        try await store.append(stamped)
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

    /// Throwing sibling of `updateStatus` for the promote flows, which are
    /// `async throws` and MUST learn if the terminal `.promoted` flip fails to
    /// persist. Otherwise the entry stays `.new` while its content is already on
    /// the card, and a retry would double-append (S8). Non-promote transitions
    /// (restore, transcript) stay on the non-throwing `updateStatus`. Throws
    /// `entryNotFound` rather than silently no-op'ing on an unknown id.
    func updateStatusThrowing(id: String, to status: InboxEntry.Status,
                              resolvedAt: Date? = Date()) async throws {
        guard var next = currentEntry(id: id) else {
            throw InboxError.entryNotFound(id)
        }
        next.status = status
        next.resolvedAt = resolvedAt
        try await appendThrowing(next)
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

    // MARK: - Throwing transition siblings (RULING-22, M8-IN-006)
    //
    // The pane's transitions used to ride the non-throwing channel: a trash
    // click whose append failed completed silently, the row sprang back on
    // refresh, and the only witness was an os_log line. The PANE now calls
    // these and shows the failure; the worker's transcript write keeps the
    // non-throwing channel deliberately (its retry loop is the next drain).

    func trashThrowing(id: String) async throws {
        try await updateStatusThrowing(id: id, to: .trashed)
    }

    func restoreThrowing(id: String) async throws {
        try await updateStatusThrowing(id: id, to: .new, resolvedAt: nil)
    }

    /// Throwing sibling of `updateTranscript`, for the edit sheet.
    func updateTranscriptThrowing(id: String, text: String,
                                  state: InboxEntry.TranscriptionState,
                                  error: String? = nil) async throws {
        guard var next = currentEntry(id: id) else {
            throw InboxError.entryNotFound(id)
        }
        next.transcript = text
        next.transcriptionState = state
        next.transcriptionError = error
        try await appendThrowing(next)
        await refresh()
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
        // The ordering is the palette sibling's, adopted here under RULING-7
        // (M8-IN-001/002, fixed 2026-08-09): every fallible write BEFORE the
        // throwing flip, the original's retirement AFTER it. This was the one
        // sibling whose terminal flip could not throw and whose original was
        // trashed first — so a failed flip reported success on both surfaces
        // while the entry sat `.new` with its asset gone, and every retry hit
        // `assetMissing` permanently.
        let created: ResearchItem
        var originalToRetire: URL?
        switch entry.kind {
        case .text:
            created = try await projectStore.createResearchNote(
                scope: scope, title: promotionTitle(for: entry))
            if let path = created.path {
                let dest = projectStore.url.appendingPathComponent(path)
                // `try`, not `try?`: a failed body write used to leave an EMPTY
                // note reported as a successful promotion, the capture's words
                // surviving only in the promoted-hidden manifest history.
                try (entry.inlineText ?? "").write(
                    to: dest, atomically: true, encoding: .utf8)
            }
        case .image, .audio:
            guard let asset = assetURL(for: entry),
                  FileManager.default.fileExists(atPath: asset.path) else {
                throw InboxError.assetMissing(entry.sourceFilename ?? entry.id)
            }
            // createResearchAsset copies; the inbox original goes to the trash
            // AFTER the flip commits (RULING-15 for the trash, RULING-7 for
            // the order — a failed flip leaves the original in place and the
            // retry re-copies: a recoverable duplicate, never a stuck `.new`).
            created = try await projectStore.createResearchAsset(
                scope: scope, fromURL: asset)
            originalToRetire = asset
        }
        try await updateStatusThrowing(id: entry.id, to: .promoted)
        if let originalToRetire {
            await trashPromotedAsset(originalToRetire, entry: entry, projectStore: projectStore)
        }
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
        // Deferred until AFTER the status flip commits: removing the inbox
        // original before the throwing flip would strand the entry `.new` with
        // the asset gone, so a retry hits `assetMissing` permanently. Removing it
        // after means a failed flip leaves the original in place and a retry
        // re-copies (a recoverable duplicate, never a stuck `.new`) — the same
        // non-destructive contract the text/audio paths get from idempotent
        // append (S8 whole-branch-review follow-up).
        var originalToRemove: URL?
        switch entry.kind {
        case .text:
            let text = Self.flattenToNote(entry.inlineText ?? "")
            // Reject an empty/whitespace-only capture the same way `.audio` does:
            // otherwise a `SensoryNote(sense: nil, text: "")` is appended, the
            // renderer emits a bare `"- "` line, and the next reparse silently
            // DROPS it (`"- "` trims to `"-"`, failing the `- ` item guard) (S5).
            guard !text.isEmpty else { throw InboxError.nothingToPromote(entry.id) }
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
            // Retry convergence, the note arm's dedup one kind over (RULING-8,
            // M8-IN-003): if the well's most recent image is byte-identical to
            // this asset, the previous attempt's copy landed even though its
            // status flip failed — skip re-adding and retry only the flip.
            if let card = projectStore.loadPaletteCards()
                .first(where: { $0.researchItemId == cardId }),
               let lastPath = card.imagePaths.last,
               let existing = try? Data(contentsOf: // adr-0018-ok: palette image bytes for retry dedup, not manuscript
                    projectStore.url.appendingPathComponent(lastPath)),
               let incoming = try? Data(contentsOf: asset), // adr-0018-ok: inbox asset bytes for retry dedup, not manuscript
               existing == incoming {
                result = card
            } else {
                // addImage copies into the card's `<slug>_assets/` folder; the
                // inbox original is removed only after the status flip commits
                // (see above).
                result = try await projectStore.addImage(toPaletteCard: cardId, fileURL: asset)
            }
            originalToRemove = asset
        }
        // Throwing flip (S8): the note/image is already on the card, so a
        // swallowed status-write failure would leave the entry `.new` and a
        // retry would double-append. Surface it — the append step above is now
        // idempotent, so a caught-and-retried promote converges to one note.
        try await updateStatusThrowing(id: entry.id, to: .promoted)
        // Only now that the entry is durably `.promoted` do we drop the inbox
        // original — into the trash rather than off the disk (RULING-15). A
        // failed move still leaves a recoverable duplicate.
        if let originalToRemove {
            await trashPromotedAsset(originalToRemove, entry: entry, projectStore: projectStore)
        }
        return result
    }

    /// Send a capture straight to the planning canvas (spec §8A.4) — the **third
    /// sibling** of `promoteToResearch` and `promoteToPaletteCard`, and
    /// deliberately not a new spelling of them.
    ///
    /// **The pipeline is `inbox → canvas → research`, and this is the first
    /// arrow.** Promotion (§6) has been the second one since 1C-c2. Requiring a
    /// capture be promoted to research *before* it can be thought about builds the
    /// durable artifact first and does the thinking afterwards, which inverts what
    /// the canvas is for. Inbox → research stays exactly as it is and stays
    /// appropriate; it simply stops being the only road onto the canvas.
    ///
    /// **All three kinds, or it does not ship** (§8A.4's own ruling). `.text` and
    /// `.audio` become a **scrap** carrying the inline text or the transcript —
    /// words into `canvas.md`, keyed by the new node's id, exactly as a typed
    /// scrap's are. `.image` becomes an **owned** item node: the picture is
    /// ingested into `canvas_assets/` through the one ingestion pair, because the
    /// inbox is a queue the writer *clears* and a node pointing into one dangles
    /// the day they tidy up.
    ///
    /// **A capture with nothing in it is refused and stays `.new`**, exactly as
    /// `promoteToPaletteCard` refuses one: a blank card plus a `.promoted` entry is
    /// the capture lost, and the writer can transcribe and retry.
    ///
    /// **The ordering is `promoteToPaletteCard`'s, and it is chosen rather than
    /// inherited by coincidence.** The two existing siblings order it differently
    /// — `promoteToResearch` removes the source asset *before* its flip, while the
    /// palette one copies, flips, and only then removes — and §8A.4's sentence
    /// ("flip to `.promoted` only after every mutating step has succeeded") is the
    /// palette one's. So: ingest (a copy, never a move), write the canvas, flip,
    /// and remove the inbox original last. A flip that fails then leaves the
    /// original in place, never a capture stranded `.new` with its asset already
    /// gone — which is a permanent `assetMissing` on every retry.
    ///
    /// **And the retry converges** (S7, issue #29): the image arm asks the canvas
    /// whether this capture is already on it *before* copying, so the second
    /// attempt repeats only the flip and the removal. Ordering alone left the
    /// duplicate recoverable in principle and invisible in practice — a copy in
    /// `canvas_assets/` that no node references is reachable from no surface at
    /// all. The card's half of this is `CanvasCapture`'s derived node id
    /// (RULING-8, M8-IN-004); this is its file half.
    ///
    /// **An audio capture's recording is NOT removed**, which the palette sibling
    /// also does and for the same reason: what went to the canvas is the
    /// transcript, and the recording in `inbox/audio/` is the only copy of the
    /// writer's voice. Removing it would delete something nothing else holds.
    @discardableResult
    func sendToCanvas(
        _ entry: InboxEntry, projectStore: ProjectStore,
        placement: CanvasCapture.Placement
    ) async throws -> CanvasNodeID {
        let content: CanvasCapture.Content
        // Set only for `.image`: see the ordering note above.
        var originalToRemove: URL?
        switch entry.kind {
        case .text:
            let text = (entry.inlineText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw InboxError.nothingToPromote(entry.id) }
            // Trimmed at the ends and NOT flattened, unlike the palette sibling: a
            // `SensoryNote` is one line of prose and a scrap is not — paragraph
            // structure is exactly what a captured note has and what the canvas
            // can hold.
            content = .words(text)
        case .audio:
            let text = (entry.transcript ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw InboxError.nothingToPromote(entry.id) }
            content = .words(text)
        case .image:
            guard let asset = assetURL(for: entry),
                  FileManager.default.fileExists(atPath: asset.path) else {
                throw InboxError.assetMissing(entry.sourceFilename ?? entry.id)
            }
            // **The already-on-canvas question, asked before the copy** (S7, issue
            // #29). The only reachable second send is the retry after a failed
            // flip, and on that path the previous attempt's copy AND its card both
            // landed — only the flip failed. `CanvasCapture.send` would skip the
            // card, but the ingest below has already run by then, stranding a
            // second copy in the well that no node will ever reference and nothing
            // enumerates. So: retry the flip and the removal alone.
            //
            // The `.text`/`.audio` arms need no twin — they read the entry's words
            // and nothing else, so `send`'s own short-circuit is early enough.
            if let existing = CanvasCapture.existingNode(
                forCapture: entry.id, store: projectStore, projectRoot: projectStore.url) {
                try await updateStatusThrowing(id: entry.id, to: .promoted)
                await trashPromotedAsset(asset, entry: entry, projectStore: projectStore)
                return existing
            }
            // A COPY into the canvas's own well; the inbox original goes below,
            // after the flip commits.
            content = .picture(path: try await projectStore.ingestCanvasAsset(fileURL: asset))
            originalToRemove = asset
        }
        let node = CanvasCapture.send(content, placement, captureID: entry.id,
                                      store: projectStore, projectRoot: projectStore.url)
        // Throwing flip (S8's lesson, one sibling over): the card is already on the
        // canvas, so a swallowed status-write failure would leave the entry `.new`
        // and a retry would land a second card.
        try await updateStatusThrowing(id: entry.id, to: .promoted)
        if let originalToRemove {
            await trashPromotedAsset(originalToRemove, entry: entry, projectStore: projectStore)
        }
        return node
    }

    /// Retire a promoted capture's original: to the project trash, never off
    /// the disk (RULING-15 — its three named defects were the three
    /// `FileManager.removeItem` calls this replaces). Best-effort in the same
    /// sense the removals were: the content is already durably at its
    /// destination, and a failure here leaves a duplicate rather than a loss,
    /// so it is logged rather than thrown over a promotion that succeeded.
    private func trashPromotedAsset(
        _ asset: URL, entry: InboxEntry, projectStore: ProjectStore
    ) async {
        guard let relative = TrashStore.relativePath(of: asset, under: projectURL) else {
            inboxStoreLog.error(
                "inbox asset for entry \(entry.id, privacy: .public) is not inside the project; left in place")
            return
        }
        do {
            _ = try await projectStore.trashCaptureAsset(
                at: relative,
                displayTitle: entry.sourceFilename ?? entry.title ?? entry.id)
        } catch {
            inboxStoreLog.error(
                "trashing the promoted inbox asset for entry \(entry.id, privacy: .public) failed; the original is left in place: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Id-taking twin, for the caller that has only an id: the canvas drop, whose
    /// payload is `inbox:<id>` (`CanvasDrop`) and never a whole entry.
    ///
    /// Throws `entryNotFound` rather than silently doing nothing, so a drag of a
    /// row that has been resolved on another device since the pane last refreshed
    /// tells the writer instead of springing back with nothing said.
    @discardableResult
    func sendToCanvas(
        entryID: String, projectStore: ProjectStore,
        placement: CanvasCapture.Placement
    ) async throws -> CanvasNodeID {
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            throw InboxError.entryNotFound(entryID)
        }
        return try await sendToCanvas(entry, projectStore: projectStore, placement: placement)
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
        // Idempotency guard against a double-promote retry (S8): if the most-
        // recent note is already identical (same sense + text), the previous
        // attempt's append landed even though its `.promoted` status flip may
        // have failed — so skip re-adding it and return the card unchanged,
        // letting the caller retry only the status flip. Dedup is scoped to the
        // immediately-preceding note (the retry signature), so a legitimately-
        // repeated note typed later still appends.
        if card.notes.last == note { return card }
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
