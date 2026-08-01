import Foundation
import MaughamCore

/// read_visual_language — the book's look, read by Claude while authoring a
/// LaTeX or CSS template. **This is M1's second named protection** (spec §10):
/// visual language gets a consumer in the milestone that builds it, or it is an
/// artifact that does nothing for three milestones. The other half of the
/// protection is the line in `docs/skills/maugham-bootstrap/SKILL.md` that tells
/// a Claude authoring a template to come here first — a tool nobody is told to
/// call leaves the protection unmet.
///
/// **Project scope, and the schema says so by taking nothing else.** Visual
/// language is project-scope by construction: `StatementConvention.newPath` has
/// no row for `(.visualLanguage, .document)` and `createStatement` throws
/// `.statementHasNoStorage` for that pair (spec §3.2 — the book has one look).
///
/// ABSENCE IS VALID: returns `{exists: false}`, never an error, and mints
/// nothing on the way — `read_craft_intent`'s shape, for the same reason.
public enum ReadVisualLanguageTool: MCPTool {
    public static let method = "read_visual_language"
    public static let description =
        "Read the project's visual language — the writer's freeform statement of how "
        + "the book should LOOK (typeface feel, scale, rule weights, the idea behind "
        + "per-piece variation), plus the images they referenced. Read this before "
        + "authoring or revising a LaTeX or EPUB/CSS template, and let it decide the "
        + "typography rather than choosing on the writer's behalf. Project scope only "
        + "— the book has one look. Returns exists:false when the writer has not "
        + "declared one; that is a valid, deliberate state, not an error. "
        + "image_paths are project-relative PATHS, not pixels: no tool in this server "
        + "reads a file by project-relative path, so use them to see WHICH images the "
        + "look is built on and ask the writer about any you need to see."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    public struct Params: Codable {
        public let project_id: String
    }
    public struct Result: Codable, Equatable {
        public let exists: Bool
        public let markdown: String?
        public let path: String?
        /// The images the prose references, project-relative, in document order
        /// and each once. Nil — not empty — when there is no statement at all,
        /// so absence of the artifact and absence of pictures in it stay
        /// distinguishable.
        public let image_paths: [String]?
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        guard let statement = entry.store.statement(kind: .visualLanguage, scope: .project) else {
            // Absence, not an error. Nothing is minted on the way — a read that
            // created the file would put a statement in the Visual Language pane
            // the writer never opened.
            return try JSONEncoder().encode(
                Result(exists: false, markdown: nil, path: nil, image_paths: nil))
        }
        // Derived, never the `.md` (tripwire 20): `statementText` owns both of
        // ADR 0018's branches and is shared with `read_craft_intent`. The images
        // are scanned out of that same text, so a stale file cannot contribute a
        // picture either.
        let markdown = entry.store.statementText(of: statement)
        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(Result(
                exists: true,
                markdown: markdown,
                path: statement.path,
                image_paths: imagePaths(in: markdown, statementPath: statement.path))),
            hint: "The visual-language doc is too large to return in one MCP response. "
                + "Open it directly on disk at \(statement.path).")
    }

    /// Every image the prose points at, project-relative, in document order and
    /// deduplicated — the answer is *which images*, so a picture cited twice is
    /// one picture.
    ///
    /// **Scanned with `MarkdownBlockParser.findInlineImages`, which is the
    /// shared unanchored scanner and already exists** — `PaletteCard`'s own
    /// `inlineImagePaths` is a one-line delegate to it. So there is nothing to
    /// promote into MaughamCore and no loss to accept: an image referenced
    /// mid-paragraph is reported, which matters because visual language is prose
    /// with pictures in it rather than a gallery. (`matchSoloImage`, the other
    /// public entry point, is whole-line-anchored **and `./`-only**; planting it
    /// here drops the mid-paragraph references *and* every `research/…` one.)
    ///
    /// Resolution is `ProjectStore.resolveImageRef`, the single spelling of
    /// ref→path in this repo; a second one is the drift
    /// `ProjectStore+CanvasAssets.swift` warns about at length. The directory it
    /// resolves against is the statement's own — `visual-language.md` sits at the
    /// project root today, and deriving it rather than assuming "" keeps that a
    /// fact about the path instead of a fact about this function. It does not
    /// collapse `..`, so a reference the writer wrote to somewhere outside the
    /// project is reported as they wrote it — which is the honest answer, since
    /// nothing in the catalogue could open it either way.
    ///
    /// **A remote URL is dropped, and that is the same rule `PaletteCard`
    /// applies** (whole-branch review): this field is documented as
    /// *project-relative paths* that `read_publish_image` opens, and a
    /// `https://…` ref sitting in it looks like one — so the tool's own
    /// description becomes false for exactly that input. An absolute local path
    /// is kept: it is still a path, and reporting it is how a writer finds out
    /// their look is built on a file outside the project.
    @MainActor
    private static func imagePaths(in markdown: String, statementPath: String) -> [String] {
        let directory = (statementPath as NSString).deletingLastPathComponent
        var seen: Set<String> = []
        return MarkdownBlockParser.findInlineImages(in: markdown).compactMap { image in
            // `![alt]()` is a reference to nothing; resolving it would name the
            // statement's own directory.
            guard !image.path.isEmpty, !image.path.contains("://") else { return nil }
            let path = ProjectStore.resolveImageRef(image.path, relativeTo: directory)
            guard seen.insert(path).inserted else { return nil }
            return path
        }
    }
}
