import Foundation
import MaughamCore

/// **Which pieces a writer let go of** — emptied from Trash, deleted from it
/// permanently, or swept out of it after 30 days (Denver's ruling, 2026-09-24).
///
/// Permanent deletion from Trash removes the entry folder and nothing else: a
/// piece's op log stays on disk, as it always has. Without a record of the
/// let-go, a piece that some archived outline in `.maugham/conflicts/` once
/// held would come back under *Removed Elsewhere* (`RemovedElsewhere`) as if
/// another device had dropped it. This record is what says it was let go.
///
/// **Derived sidecar, per device** (tripwire 17): each device appends only to
/// its own `.maugham/let-go/let-go.<slug>.jsonl`, and a reader takes the UNION
/// of every device's file, so a piece another Mac let go of is not offered back
/// here either once its record has synced. Losing the directory costs only
/// that: pieces some archive held come back under Removed Elsewhere, from
/// which Trash is the way back out.
///
/// One JSON object per line — `{"id":"doc-…","at":"<ISO 8601>"}` — the id of
/// every structure row the entry recorded, a trashed group's children included.
enum LetGoRecord {

    struct Line: Codable, Equatable {
        let id: String
        let at: Date
    }

    static func directory(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/let-go", isDirectory: true)
    }

    /// The one filename builder (tripwire 24: the slug is interpolated here,
    /// at the filename point, and nowhere else).
    static func fileURL(for device: DeviceSlug, in projectURL: URL) -> URL {
        directory(in: projectURL).appendingPathComponent("let-go.\(device.raw).jsonl")
    }

    /// This device's slug, from the author identity (tripwire 35).
    static var thisDevice: DeviceSlug {
        DeviceSlug.make(from: DeviceIdentity.author.deviceId)
    }

    /// Append `ids` to `device`'s file, in ONE write. Nothing to write for an
    /// empty set.
    ///
    /// **Through `JSONLAppendStore`, unchained** — the house append for a
    /// per-device JSONL sidecar (the publication log's shape): the write is
    /// under `NSFileCoordinator`, like every other append to a file iCloud
    /// syncs, and the line format (sorted keys, the store's date strategy) is
    /// the one every other sidecar uses (review N4).
    static func record(
        ids: Set<String>, in projectURL: URL,
        device: DeviceSlug = LetGoRecord.thisDevice, at date: Date = Date()
    ) async throws {
        guard !ids.isEmpty else { return }
        try await JSONLAppendStore<Line>(fileURL: fileURL(for: device, in: projectURL))
            .appendBatch(ids.sorted().map { Line(id: $0, at: date) })
    }

    /// Record what `entryFolder` accounts for, logging rather than throwing:
    /// the deletion it follows has already happened, and a missing record
    /// costs only a row under Removed Elsewhere, from which Trash is the way
    /// back out.
    static func recordLettingGo(of ids: Set<String>, in projectURL: URL) async {
        do {
            try await record(ids: ids, in: projectURL)
        } catch {
            projectStoreLog.error(
                "Could not record \(ids.count) let-go id(s) in \(projectURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Every id any device let go of — the union of every `let-go.*.jsonl`.
    /// Hidden-flag safe: lists with no options (never `.skipsHiddenFiles`,
    /// which also honours the UF_HIDDEN flag a daemon may set), and skips only
    /// dotfiles by name. A line this build cannot read is skipped. Each file
    /// is read under a coordinated read, the write's counterpart; synchronous,
    /// because `RemovedElsewhere.scan` runs it off the main actor.
    static func ids(in projectURL: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory(in: projectURL), includingPropertiesForKeys: nil,
            options: [])) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JSONLAppendStore<Line>.dateDecoding
        var ids = Set<String>()
        for file in files
        where !DotfileScan.isDotfile(file)
            && file.lastPathComponent.hasPrefix("let-go.")
            && file.pathExtension == "jsonl" {
            guard let data = coordinatedRead(file) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let parsed = try? decoder.decode(Line.self, from: Data(line)) {
                    ids.insert(parsed.id)
                }
            }
        }
        return ids
    }

    private static func coordinatedRead(_ file: URL) -> Data? {
        var data: Data?
        var coordErr: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: file, options: [], error: &coordErr
        ) { url in
            data = try? Data(contentsOf: url)  // adr-0018-ok: derived let-go sidecar, not manuscript
        }
        return coordErr == nil ? data : nil
    }

    /// The structure ids a Trash entry folder accounts for, read before the
    /// folder goes: the manuscript row its record holds and every row beneath
    /// it, plus the id its folder name carries (`yyyyMMdd-HHmmss-<id>`), which
    /// is all an entry with an unreadable record still says. A research,
    /// capture or Maugham-internal entry lets go of no manuscript piece.
    static func ids(inTrashEntryFolder folder: URL) -> Set<String> {
        var ids = Set<String>()
        let metaURL = folder.appendingPathComponent("meta.json")
        let meta = (try? Data(contentsOf: metaURL))  // adr-0018-ok: trash metadata read, not manuscript
            .flatMap { try? JSONDecoder().decode(TrashStore.TrashMeta.self, from: $0) }
        if let meta {
            switch meta.subject {
            case .manuscriptItem, nil:
                break
            case .researchItem, .captureAsset, .internalArtifact, .priorVersion:
                return []
            }
            if let item = try? JSONDecoder().decode(StructureItem.self, from: meta.itemMetadata) {
                ids.formUnion(TreeWalk.collectIds(in: [item]))
            }
        }
        let parts = folder.lastPathComponent.split(separator: "-", maxSplits: 2)
        if parts.count == 3 { ids.insert(String(parts[2])) }
        return ids
    }
}
