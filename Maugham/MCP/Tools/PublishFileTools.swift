import Foundation

// MARK: - Shared path validation

/// Path-traversal hardening for `.maugham/publish/` MCP tools. Mirrors the
/// shape used by `PublicationSnapshotStore.extract`: reject `..` *segments*
/// (not substrings — a filename like `chapter..outline.tex` is legal),
/// leading `/`, null bytes; finally re-check after standardization that
/// the resolved path is still inside the publish root.
enum PublishPath {

    static func validateAndResolve(
        relativePath: String, in projectURL: URL
    ) throws -> URL {
        if relativePath.isEmpty {
            throw MCPError.invalidArgument("path is empty")
        }
        if relativePath.contains("\0") {
            throw MCPError.invalidArgument("path contains null byte")
        }
        if relativePath.hasPrefix("/") {
            throw MCPError.invalidArgument("path must be relative")
        }
        // Strict: any path component that is exactly `..` is rejected.
        // Substring-only is allowed (e.g. `chapter..outline.tex` is legal).
        let segments = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains("..") {
            throw MCPError.invalidArgument("path must not contain '..' segments")
        }
        let publishRoot = projectURL
            .appendingPathComponent(".maugham/publish", isDirectory: true)
        let candidate = publishRoot.appendingPathComponent(relativePath)
        let resolvedPath = candidate.standardizedFileURL.path
        let rootPath = publishRoot.standardizedFileURL.path
        guard resolvedPath == rootPath
            || resolvedPath.hasPrefix(rootPath + "/") else {
            throw MCPError.invalidArgument("path escapes publish dir")
        }
        return candidate
    }

    /// Files the user-facing publish workflow assumes are present. Delete
    /// refuses these without `force=true`.
    static let protected: Set<String> = ["template.tex", "config.json", "styles.css"]
}

// MARK: - list_publish_files

public enum ListPublishFilesTool: MCPTool {
    public static let method = "list_publish_files"
    public static let description =
    "List files under .maugham/publish/ for a project. Returns [{path, size, modified_at}] sorted by path. Skips the build/ subdirectory (transient compile artifacts)."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}
    """

    struct Params: Codable {
        let projectID: String
        enum CodingKeys: String, CodingKey { case projectID = "project_id" }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else {
            throw MCPError.invalidArgument("missing params")
        }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let entry = registry.lookup(id: params.projectID) else {
            throw MCPError.invalidArgument("unknown project_id")
        }
        let publishRoot = entry.url
            .appendingPathComponent(".maugham/publish", isDirectory: true)
        var files: [[String: Any]] = []
        if FileManager.default.fileExists(atPath: publishRoot.path),
           let enumerator = FileManager.default.enumerator(
            at: publishRoot,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) {
            let rootPath = publishRoot.standardizedFileURL.path + "/"
            let iso = ISO8601DateFormatter()
            while let item = enumerator.nextObject() as? URL {
                let res = try item.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard res.isRegularFile == true else { continue }
                let abs = item.standardizedFileURL.path
                guard abs.hasPrefix(rootPath) else { continue }
                let rel = String(abs.dropFirst(rootPath.count))
                if rel.hasPrefix("build/") { continue }
                let mod = res.contentModificationDate.map { iso.string(from: $0) } ?? ""
                files.append([
                    "path": rel,
                    "size": res.fileSize ?? 0,
                    "modified_at": mod
                ])
            }
        }
        files.sort {
            ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "")
        }
        return try JSONSerialization.data(
            withJSONObject: ["files": files], options: [.sortedKeys])
    }
}

// MARK: - read_publish_file

public enum ReadPublishFileTool: MCPTool {
    public static let method = "read_publish_file"
    public static let description =
    "Read a text file under .maugham/publish/ as UTF-8. For binary files (covers, font previews) use read_publish_image."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "path":{"type":"string"}
     },"required":["project_id","path"]}
    """

    struct Params: Codable {
        let projectID: String
        let path: String
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case path
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else {
            throw MCPError.invalidArgument("missing params")
        }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let entry = registry.lookup(id: params.projectID) else {
            throw MCPError.invalidArgument("unknown project_id")
        }
        let url = try PublishPath.validateAndResolve(
            relativePath: params.path, in: entry.url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPError.invalidArgument("file not found: \(params.path)")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try JSONSerialization.data(
            withJSONObject: ["path": params.path, "content": text],
            options: [.sortedKeys])
    }
}

// MARK: - read_publish_image

public enum ReadPublishImageTool: MCPTool {
    public static let method = "read_publish_image"
    public static let description =
    "Read an image under .maugham/publish/ (e.g. cover.jpg, font samples). Returns a downscaled JPEG inside an MCP content envelope. Region coordinates are normalized 0–1 with top-left origin."
    public static let inputSchemaJSON = #"""
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "path":{"type":"string"},
       "max_dimension":{"type":"integer","description":"Longest-edge cap (256–4096, default 2048)."},
       "quality":{"type":"integer","description":"JPEG quality 10–100 (default 85)."},
       "region":{"type":"object","description":"Optional crop, normalized 0–1, top-left origin.","properties":{"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"}},"required":["x","y","width","height"]}
     },"required":["project_id","path"]}
    """#

    struct Params: Codable {
        let projectID: String
        let path: String
        let maxDimension: Int?
        let quality: Int?
        let region: ImageResponseBuilder.Region?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case path
            case maxDimension = "max_dimension"
            case quality, region
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else {
            throw MCPError.invalidArgument("missing params")
        }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let entry = registry.lookup(id: params.projectID) else {
            throw MCPError.invalidArgument("unknown project_id")
        }
        let url = try PublishPath.validateAndResolve(
            relativePath: params.path, in: entry.url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPError.invalidArgument("image not found: \(params.path)")
        }
        return try ImageResponseBuilder.encodeEnvelope(
            at: url,
            region: params.region,
            maxDimension: params.maxDimension,
            quality: params.quality)
    }
}

// MARK: - write_publish_file

public enum WritePublishFileTool: MCPTool {
    public static let method = "write_publish_file"
    public static let description =
    "Write a text or binary file under .maugham/publish/. content_encoding=\"utf8\" (default) writes content as text; \"base64\" decodes content as binary. Creates parent subdirectories as needed."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "path":{"type":"string"},
       "content":{"type":"string"},
       "content_encoding":{"type":"string","enum":["utf8","base64"],"default":"utf8"}
     },"required":["project_id","path","content"]}
    """

    struct Params: Codable {
        let projectID: String
        let path: String
        let content: String
        let contentEncoding: String?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case path, content
            case contentEncoding = "content_encoding"
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else {
            throw MCPError.invalidArgument("missing params")
        }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let entry = registry.lookup(id: params.projectID) else {
            throw MCPError.invalidArgument("unknown project_id")
        }
        let url = try PublishPath.validateAndResolve(
            relativePath: params.path, in: entry.url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let encoding = params.contentEncoding ?? "utf8"
        switch encoding {
        case "utf8":
            try params.content.write(to: url, atomically: true, encoding: .utf8)
        case "base64":
            guard let data = Data(base64Encoded: params.content) else {
                throw MCPError.invalidArgument("content is not valid base64")
            }
            try data.write(to: url, options: .atomic)
        default:
            throw MCPError.invalidArgument(
                "content_encoding must be \"utf8\" or \"base64\"")
        }
        return try JSONSerialization.data(
            withJSONObject: ["status": "written", "path": params.path],
            options: [.sortedKeys])
    }
}

// MARK: - delete_publish_file

public enum DeletePublishFileTool: MCPTool {
    public static let method = "delete_publish_file"
    public static let description =
    "Delete a file under .maugham/publish/. Refuses to delete protected files (template.tex, config.json, styles.css) unless force=true."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "path":{"type":"string"},
       "force":{"type":"boolean","default":false}
     },"required":["project_id","path"]}
    """

    struct Params: Codable {
        let projectID: String
        let path: String
        let force: Bool?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case path, force
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else {
            throw MCPError.invalidArgument("missing params")
        }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let entry = registry.lookup(id: params.projectID) else {
            throw MCPError.invalidArgument("unknown project_id")
        }
        if PublishPath.protected.contains(params.path) && !(params.force ?? false) {
            throw MCPError.invalidArgument(
                "\(params.path) is protected; pass force=true to delete")
        }
        let url = try PublishPath.validateAndResolve(
            relativePath: params.path, in: entry.url)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return try JSONSerialization.data(
            withJSONObject: ["status": "deleted", "path": params.path],
            options: [.sortedKeys])
    }
}
