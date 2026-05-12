import Foundation

/// Per-project trash directory operations. Lives at <projectURL>/.trash/
/// with each trashed item in its own timestamped subfolder containing the
/// original file/folder plus a meta.json describing the restoration target.
@MainActor
public struct TrashStore {
    public let projectURL: URL

    public init(projectURL: URL) {
        self.projectURL = projectURL
    }

    var trashRoot: URL {
        projectURL.appendingPathComponent(".trash")
    }

    /// List all current trash entries, newest first.
    public func list() async throws -> [TrashEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashRoot.path) else { return [] }
        let folders = (try? fm.contentsOfDirectory(
            at: trashRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        var entries: [TrashEntry] = []
        for folder in folders where folder.hasDirectoryPath {
            let metaURL = folder.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(TrashMeta.self, from: data),
                  let trashedAt = Self.parseTimestamp(from: folder.lastPathComponent) else {
                continue
            }
            entries.append(TrashEntry(
                id: folder.lastPathComponent,
                trashedAt: trashedAt,
                originalRelativePath: meta.originalRelativePath,
                displayTitle: meta.displayTitle,
                itemMetadata: meta.itemMetadata))
        }
        return entries.sorted { $0.trashedAt > $1.trashedAt }
    }

    /// Remove entries older than 30 days. Called from ProjectStore.load.
    public func sweep() async throws {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let entries = try await list()
        for entry in entries where entry.trashedAt < cutoff {
            let folder = trashRoot.appendingPathComponent(entry.id)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Internal metadata persisted in each trash folder's meta.json.
    struct TrashMeta: Codable {
        let originalRelativePath: String
        let displayTitle: String
        let itemMetadata: Data
        let originalParentId: String?
        let originalIndex: Int
    }

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        return f
    }()

    static func parseTimestamp(from folderName: String) -> Date? {
        // Folder name: "yyyyMMdd-HHmmss-<original-id>"
        let parts = folderName.split(separator: "-", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let stamp = "\(parts[0])-\(parts[1])"
        return timestampFormatter.date(from: stamp)
    }

    static func timestampPrefix(for date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    public enum TrashError: Error {
        case entryFileMissing(String)
        case malformedEntryId(String)
    }
}
