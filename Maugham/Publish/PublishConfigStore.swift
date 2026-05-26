import Foundation

/// Read/write `.maugham/publish/config.json`. Pretty-printed, snake_case keys.
/// Atomic writes (write to temp + rename).
public actor PublishConfigStore {
    public let projectURL: URL

    public init(projectURL: URL) {
        self.projectURL = projectURL
    }

    public var fileURL: URL {
        projectURL.appendingPathComponent(".maugham/publish/config.json")
    }

    public func load() throws -> PublishConfig? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PublishConfig.self, from: data)
    }

    public func save(_ config: PublishConfig) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)

        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }
}
