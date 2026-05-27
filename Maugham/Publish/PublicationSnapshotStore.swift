import Foundation

public actor PublicationSnapshotStore {
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
        try FileManager.default.createDirectory(
            at: snapshotsDir, withIntermediateDirectories: true)
        let url = snapshotURL(id: snap.snapshotID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snap).write(to: url, options: .atomic)
    }

    nonisolated public func load(id: String) throws -> PublicationSnapshot {
        let url = snapshotURL(id: id)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PublicationSnapshot.self, from: data)
    }

    /// Extract a snapshot's `publishFiles` into a destination directory.
    public static func extract(
        _ snap: PublicationSnapshot, into destination: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        for file in snap.publishFiles {
            let dst = destination.appendingPathComponent(file.relativePath)
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

    nonisolated private func collectFiles(
        under directory: URL, relativeTo root: URL
    ) throws -> [PublicationSnapshot.File] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [PublicationSnapshot.File] = []
        let rootPath = try root.standardizedFileURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? root.path
        while let url = enumerator.nextObject() as? URL {
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
                let text = try String(contentsOf: url)
                out.append(.init(relativePath: relativePath,
                                 textContent: text, base64Content: nil))
            } else {
                let data = try Data(contentsOf: url)
                out.append(.init(relativePath: relativePath,
                                 textContent: nil,
                                 base64Content: data.base64EncodedString()))
            }
        }
        return out.sorted { $0.relativePath < $1.relativePath }
    }
}
