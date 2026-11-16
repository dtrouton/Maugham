import Foundation

/// **Who wrote the text now on disk for a Research note**: its `ContentHash`
/// and the writer (the writer, or the assistant over MCP). The note twin of
/// what `ResearchTableSidecar` carries for a table; a note has nothing else
/// to remember, so this is all of it. A Research label, never a signature.
///
/// At `.maugham/research-notes/<item id>.json`, keyed by item id so a move or
/// rename never stales it. A reader decides the record "is for this text" by
/// `contentHash == ContentHash.of(bytes)`. Tolerant (ADR 0015): a field that
/// does not read is nil.
public struct ResearchNoteRecord: Codable, Equatable, Sendable {
    public var contentHash: String?
    public var writtenBy: ResearchWriter?

    public init(contentHash: String? = nil, writtenBy: ResearchWriter? = nil) {
        self.contentHash = contentHash
        self.writtenBy = writtenBy
    }

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case writtenBy = "written_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentHash = (try? c.decodeIfPresent(String.self, forKey: .contentHash)) ?? nil
        writtenBy = (try? c.decodeIfPresent(ResearchWriter.self, forKey: .writtenBy)) ?? nil
    }

    /// The folder every note record lives in, project-relative. Spelled here only.
    public static let folder = ".maugham/research-notes"

    /// **Where item `itemId`'s record lives**: `<folder>/<itemId>.json`. The id
    /// comes from the synced manifest, so it must be a doc id that can name a
    /// file (`SafeRelativePath.requireDocId`), and the folder is checked on
    /// disk (`SafeRelativePath.resolveFile`, a change form — tripwire 58).
    public static func fileURL(forItem itemId: String, in projectURL: URL) throws -> URL {
        try SafeRelativePath.requireDocId(itemId)
        return try SafeRelativePath.resolveFile(named: "\(itemId).json", in: folder, under: projectURL)
    }

    /// Item `itemId`'s record, or nil when it has none. Throws for an id that
    /// cannot name a file, or a file that is there but is not a JSON object.
    public static func read(forItem itemId: String, in projectURL: URL) throws -> ResearchNoteRecord? {
        let url = try fileURL(forItem: itemId, in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url) // adr-0018-ok: a Research note's record JSON, not manuscript
        return try JSONDecoder().decode(ResearchNoteRecord.self, from: data)
    }

    /// Writes item `itemId`'s record, replacing any there, atomically.
    public static func write(_ record: ResearchNoteRecord, forItem itemId: String,
                             in projectURL: URL) throws {
        let url = try fileURL(forItem: itemId, in: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    /// Removes the files of items destroyed for good (never one in the Trash:
    /// a restore needs it). Ids that cannot name a file are skipped.
    public static func remove(forItems ids: Set<String>, in projectURL: URL) {
        ResearchItemFiles.remove(forItems: ids, in: projectURL, fileURL: fileURL(forItem:in:))
    }

    /// Removes the file of every item not in `liveItemIds` (callers unite the
    /// manifest's and the Trash's ids) whose modification date is older than
    /// `minimumAge`; these files carry no device, so the file's own date rules.
    public static func sweepOrphans(liveItemIds: Set<String>, in projectURL: URL,
                                    minimumAge: TimeInterval, now: Date = Date()) {
        ResearchItemFiles.sweepOrphans(
            liveItemIds: liveItemIds, in: projectURL, folder: folder, minimumAge: minimumAge,
            now: now, fileURL: fileURL(forItem:in:))
    }
}

/// **The removal both per-item derived files share** (`ResearchNoteRecord`,
/// `ResearchTableSidecar`): one `<folder>/<itemId>.json` per item, no device
/// in the name. Each type's `remove(forItems:in:)` and `sweepOrphans` call
/// here with its own folder and its own `fileURL(forItem:in:)`, so every path
/// still comes through that type's `SafeRelativePath` check (tripwire 58).
enum ResearchItemFiles {

    /// Removes each item's file; an id that cannot name a file, or a file
    /// that is not there, is skipped.
    static func remove(forItems ids: Set<String>, in projectURL: URL,
                       fileURL: (String, URL) throws -> URL) {
        for id in ids {
            guard let url = try? fileURL(id, projectURL) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes the file of every item not in `liveItemIds` whose modification
    /// date is older than `minimumAge`. Younger files stay: the Trash entry
    /// that claims one may still be on its way from another Mac.
    static func sweepOrphans(liveItemIds: Set<String>, in projectURL: URL, folder: String,
                             minimumAge: TimeInterval, now: Date,
                             fileURL: (String, URL) throws -> URL) {
        guard let root = try? SafeRelativePath.resolve(folder, under: projectURL),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [])
        else { return }
        for entry in entries where !DotfileScan.isDotfile(entry) && entry.pathExtension == "json" {
            let id = entry.deletingPathExtension().lastPathComponent
            guard !liveItemIds.contains(id), let url = try? fileURL(id, projectURL),
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate,
                  now.timeIntervalSince(modified) > minimumAge else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
