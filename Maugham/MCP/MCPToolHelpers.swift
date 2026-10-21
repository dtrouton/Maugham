import Foundation

/// Shared boilerplate for `MCPTool` conformers. Every tool that takes typed
/// params decodes them the same way, and every tool that operates on a project
/// resolves its `project_id` against the live registry the same way. Lifting
/// both here collapses ~30 near-identical guard blocks and gives the tool layer
/// a single, canonical "unknown project" failure (`unknownProjectID`).
public extension MCPTool {
    /// Decode the tool's typed params from the raw request JSON, or throw a
    /// structured `invalidArgument` naming the offending tool. Mirrors the
    /// `try?`-guard shape the tools used inline before this refactor.
    static func decodeParams<P: Decodable>(_ type: P.Type, from json: Data?) throws -> P {
        guard let json,
              let decoded = try? JSONDecoder().decode(P.self, from: json) else {
            throw MCPError.invalidArgument("malformed or missing parameters for \(method)")
        }
        return decoded
    }

    /// Resolve an open project by id, or throw the canonical structured
    /// unknown-project error. Returns the full registry `Entry` (id + url +
    /// store) because callers need all three.
    @MainActor
    static func resolveProject(_ id: String, in registry: ProjectRegistry) throws -> ProjectRegistry.Entry {
        guard let entry = registry.lookup(id: id) else {
            throw MCPError.unknownProjectID(id)
        }
        return entry
    }
}

/// **The JSON-Schema `enum` of a publish `format` parameter, derived from
/// `PublishConfig.Format`** (report plan 4, R-4-5): a format this build learns
/// reaches every tool's schema with no literal list to update.
enum MCPFormatEnum {
    /// `["pdf","epub",…]` — the raw names, in order.
    static func json(_ formats: [PublishConfig.Format]) -> String {
        "[" + formats.map { "\"\($0.rawValue)\"" }.joined(separator: ",") + "]"
    }

    /// Every format this build produces: `compile`, `list_publications`,
    /// `republish`.
    static var produced: String { json(PublishConfig.Format.allCases) }

    /// What `preview_compile` renders: the produced formats less every one
    /// the preview refuses (`PreviewCompiler.previewRefusal`).
    static var previewed: String {
        json(PublishConfig.Format.allCases.filter { PreviewCompiler.previewRefusal($0) == nil })
    }
}
