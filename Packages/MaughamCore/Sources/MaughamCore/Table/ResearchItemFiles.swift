import Foundation

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
