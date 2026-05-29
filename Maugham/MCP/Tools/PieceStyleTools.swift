import Foundation

// MARK: - set_piece_style

/// One-call create/replace of a per-piece LaTeX style override under
/// `.maugham/publish/pieces/` AND wiring it to the section's `style_file` in
/// publish config. Overwriting an existing style file moves the prior version
/// to the project trash (recoverable) — the project runs on iCloud + op-log,
/// there is no git, so trash is the safety net.
public enum SetPieceStyleTool: MCPTool {
    public static let method = "set_piece_style"
    public static let description =
    "Create or replace a per-piece LaTeX style file under pieces/ AND wire it to the section's style_file in one call. filename defaults to a deterministic slug of the piece title (same title -> same file; re-calling overwrites in place). Overwriting an existing style file moves the prior version to the project trash (recoverable). Per-piece files may \\renewcommand/\\definecolor/redefine environments and emit a title page at file top, but may NOT \\usepackage or change \\geometry (see EMISSION.md)."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "piece_id":{"type":"string"},
       "content":{"type":"string"},
       "filename":{"type":"string","description":"Optional. Defaults to a slug of the piece title + .tex."}
     },"required":["project_id","piece_id","content"]}
    """

    struct Params: Codable {
        let projectID: String
        let pieceID: String
        let content: String
        let filename: String?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case pieceID = "piece_id"
            case content
            case filename
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

        let store = PublishConfigStore(projectURL: entry.url)
        let cfg = (try await store.load()) ?? PublishConfig()

        // Resolve filename: explicit, else a deterministic slug of the title.
        let name: String
        if let explicit = params.filename, !explicit.isEmpty {
            name = explicit
        } else {
            let title = cfg.sections[params.pieceID]?.titleOverride ?? params.pieceID
            name = PieceStyleSlug.slug(title) + ".tex"
        }

        let rel = "pieces/\(name)"
        let url = try PublishPath.validateAndResolve(relativePath: rel, in: entry.url)

        // If a file already exists at this path, send the prior version to the
        // project trash before overwriting (recoverable safety net).
        if FileManager.default.fileExists(atPath: url.path) {
            let metadata = try JSONSerialization.data(
                withJSONObject: ["id": "style-\(name)"])
            _ = try await TrashStore(projectURL: entry.url).moveToTrash(
                fileRelativePath: ".maugham/publish/\(rel)",
                itemMetadata: metadata,
                originalParentId: nil,
                originalIndex: 0,
                displayTitle: name)
        }

        // Create pieces/ and write the new content.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try params.content.write(to: url, atomically: true, encoding: .utf8)

        // Wire config: section's style_file points at the new file.
        var sec = cfg.sections[params.pieceID] ?? PublishConfig.Section()
        sec.styleFile = name
        var next = cfg
        next.sections[params.pieceID] = sec
        try await store.save(next)

        return try JSONSerialization.data(
            withJSONObject: [
                "status": "set",
                "piece_id": params.pieceID,
                "style_file": name
            ],
            options: [.sortedKeys])
    }
}

// MARK: - clear_piece_style

/// Inverse of `set_piece_style`: unwire a section's `style_file` and delete the
/// file — but only delete it if NO OTHER section still references it (two pieces
/// may share one style file). The deleted file goes to the project trash
/// (recoverable), same as an overwrite in `set_piece_style`.
public enum ClearPieceStyleTool: MCPTool {
    public static let method = "clear_piece_style"
    public static let description =
    "Remove a section's per-piece style file wiring; deletes the file to the project trash only if no other section references it (shared style files survive). No-op if the section has no style_file."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "piece_id":{"type":"string"}
     },"required":["project_id","piece_id"]}
    """

    struct Params: Codable {
        let projectID: String
        let pieceID: String
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case pieceID = "piece_id"
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

        let store = PublishConfigStore(projectURL: entry.url)
        let cfg = (try await store.load()) ?? PublishConfig()

        guard let name = cfg.sections[params.pieceID]?.styleFile else {
            return try JSONSerialization.data(
                withJSONObject: [
                    "status": "noop",
                    "piece_id": params.pieceID
                ],
                options: [.sortedKeys])
        }

        // Unwire: drop the style_file on this section.
        var next = cfg
        if var sec = next.sections[params.pieceID] {
            sec.styleFile = nil
            next.sections[params.pieceID] = sec
        }

        // Orphan check over OTHER sections only (this one is already unwired).
        let stillReferenced = next.sections.values.contains { $0.styleFile == name }

        var deletedFile = false
        if !stillReferenced {
            let rel = "pieces/\(name)"
            let url = try PublishPath.validateAndResolve(relativePath: rel, in: entry.url)
            if FileManager.default.fileExists(atPath: url.path) {
                let metadata = try JSONSerialization.data(
                    withJSONObject: ["id": "style-\(name)"])
                _ = try await TrashStore(projectURL: entry.url).moveToTrash(
                    fileRelativePath: ".maugham/publish/\(rel)",
                    itemMetadata: metadata,
                    originalParentId: nil,
                    originalIndex: 0,
                    displayTitle: name)
                deletedFile = true
            }
        }

        try await store.save(next)

        return try JSONSerialization.data(
            withJSONObject: [
                "status": "cleared",
                "piece_id": params.pieceID,
                "deleted_file": deletedFile
            ],
            options: [.sortedKeys])
    }
}

// MARK: - slug

enum PieceStyleSlug {
    static func slug(_ s: String) -> String {
        let lowered = s.lowercased(); var out = ""; var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "piece" : trimmed
    }
}
