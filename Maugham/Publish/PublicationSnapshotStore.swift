import Foundation
import MaughamCore

public actor PublicationSnapshotStore {

    public enum Error: Swift.Error, Equatable {
        case invalidSnapshotID(String)
        case pathTraversal(relativePath: String)
    }

    nonisolated public let projectURL: URL

    public init(projectURL: URL) {
        self.projectURL = projectURL
    }

    nonisolated public var snapshotsDir: URL {
        projectURL.appendingPathComponent(".maugham/publications", isDirectory: true)
    }

    nonisolated public func snapshotURL(id: String) -> URL {
        snapshotsDir.appendingPathComponent("\(id).json")
    }

    /// Rejects snapshot IDs that could escape `snapshotsDir` (path separators,
    /// `..` segments, leading `.`, empty). Snapshot IDs are minted by `capture()`
    /// in the form `snap-<uuid-lowercase>`, but snapshots arrive on disk and via
    /// iCloud/MCP, so any path-shaped input is treated as adversarial.
    nonisolated internal static func validate(snapshotID id: String) throws {
        if id.isEmpty
            || id.contains("/")
            || id.contains("\\")
            || id.contains("\0")
            || id.hasPrefix(".")
            || id.split(separator: "/").contains("..")
        {
            throw Error.invalidSnapshotID(id)
        }
    }

    /// Capture the current `.maugham/publish/` contents into a snapshot value.
    /// Does NOT persist.
    nonisolated public func capture(
        config: PublishConfig,
        maughamVersion: String,
        tectonicVersion: String
    ) throws -> PublicationSnapshot {
        let publish = projectURL.appendingPathComponent(".maugham/publish",
                                                        isDirectory: true)
        let files = try collectFiles(under: publish, relativeTo: publish)
        return PublicationSnapshot(
            snapshotID: "snap-" + UUID().uuidString.lowercased(),
            createdAt: Date(),
            publishFiles: files,
            config: config,
            maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion)
    }

    nonisolated public func save(_ snap: PublicationSnapshot) throws {
        try Self.validate(snapshotID: snap.snapshotID)
        try FileManager.default.createDirectory(
            at: snapshotsDir, withIntermediateDirectories: true)
        let url = snapshotURL(id: snap.snapshotID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snap).write(to: url, options: .atomic)
    }

    nonisolated public func load(id: String) throws -> PublicationSnapshot {
        try Self.validate(snapshotID: id)
        let url = snapshotURL(id: id)
        let data = try Data(contentsOf: url)  // adr-0018-ok: publication snapshot JSON read, not manuscript
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PublicationSnapshot.self, from: data)
    }

    /// Extract a snapshot's `publishFiles` into a destination directory.
    ///
    /// Validates that each `file.relativePath` resolves inside `destination`.
    /// Snapshots are JSON files that can be edited, synced via iCloud, or arrive
    /// from MCP callers; their `publishFiles` entries are untrusted input.
    public static func extract(
        _ snap: PublicationSnapshot, into destination: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        let destPrefix = destination.standardizedFileURL.path + "/"
        for file in snap.publishFiles {
            let rel = file.relativePath
            // Reject absolute / parent-escape / hidden-root paths before joining.
            if rel.isEmpty
                || rel.hasPrefix("/")
                || rel.hasPrefix("~")
                || rel.contains("\0")
                || rel.split(separator: "/").contains("..")
            {
                throw Error.pathTraversal(relativePath: rel)
            }
            let dst = destination.appendingPathComponent(rel).standardizedFileURL
            guard dst.path.hasPrefix(destPrefix) else {
                throw Error.pathTraversal(relativePath: rel)
            }
            try FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if let text = file.textContent {
                try text.write(to: dst, atomically: true, encoding: .utf8)
            } else if let b64 = file.base64Content, let data = Data(base64Encoded: b64) {
                try data.write(to: dst, options: .atomic)
            }
        }
    }

    // MARK: - private

    private static let textExtensions: Set<String> = [
        "tex", "css", "json", "md", "txt"
    ]

    private static let skipPrefixes: [String] = [
        "build/",
    ]

    /// `template.tex.sb-1a2b3c4d-Xxxxxx` — the transient sibling Foundation's
    /// atomic writes create beside their destination and rename away.
    nonisolated static func isAtomicWriteTemp(_ name: String) -> Bool {
        name.range(of: #"\.sb-[0-9a-fA-F]{8}-"#, options: .regularExpression) != nil
    }

    nonisolated private func collectFiles(
        under directory: URL, relativeTo root: URL
    ) throws -> [PublicationSnapshot.File] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []) else { return [] }
        var out: [PublicationSnapshot.File] = []
        let rootPath = try root.standardizedFileURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? root.path
        while let url = enumerator.nextObject() as? URL {
            // Dotfiles by name, never by the `hidden` flag (`DotfileScan`).
            if DotfileScan.isDotfile(url) {
                enumerator.skipDescendants()
                continue
            }
            // Foundation's atomic-write temp (`<name>.sb-<hex>-<random>`) is
            // another writer's EMISSION.md refresh mid-rename (a concurrent
            // compile or a preview). Skip it by NAME before any stat or read —
            // it can vanish between enumeration and either, and a snapshot
            // must not embed it even when the read wins the race.
            if Self.isAtomicWriteTemp(url.lastPathComponent) { continue }
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }

            let absPath = try url.standardizedFileURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? url.path
            guard absPath.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(absPath.dropFirst(rootPath.count + 1))

            if Self.skipPrefixes.contains(where: { relativePath.hasPrefix($0) }) {
                continue
            }

            let ext = (relativePath as NSString).pathExtension.lowercased()
            if Self.textExtensions.contains(ext) {
                let text = try String(contentsOf: url)  // adr-0018-ok: publication snapshot text read, not manuscript
                out.append(.init(relativePath: relativePath,
                                 textContent: text, base64Content: nil))
            } else {
                let data = try Data(contentsOf: url)  // adr-0018-ok: publication snapshot bytes read, not manuscript
                out.append(.init(relativePath: relativePath,
                                 textContent: nil,
                                 base64Content: data.base64EncodedString()))
            }
        }
        return out.sorted { $0.relativePath < $1.relativePath }
    }
}
