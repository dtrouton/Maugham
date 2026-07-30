import Foundation
import MaughamCore

/// `list_canvas(project_id, include_text?)` — the planning canvas, read whole.
///
/// **This is a read tool over a surface with no op log behind it.** The canvas's
/// only records are `canvas.md` and `.maugham/canvas.json`, and which of them is
/// authoritative depends on whether the writer has the Plan persona on screen. The
/// tool does not decide that for itself: `CanvasClaudeWrite.readScene` is the one
/// place the attached-or-sidecar discriminator is spelled, and the write tool uses
/// the same one, so a read and a write in the same breath cannot disagree about
/// which canvas is real.
///
/// **`read_from` is in the payload, not inferred.** The live model is ahead of the
/// sidecar and never behind it — the mounted editor folds every keystroke into the
/// scene (tripwire 28) — so an `open_canvas` read can contain a sentence the writer
/// is still typing. Without the field, "the canvas has three cards" and "the canvas
/// had three cards when it was last saved" would be the same sentence.
/// `read_preview_page` carries `preview_filename`/`preview_mtime` for exactly this
/// reason: provenance a caller cannot recover is provenance the response owes it.
///
/// **`promoted_item_id` and `contributed_to_item_id` are two fields because they
/// are two facts** (spec §6.3). The first means *this card produced this artifact*
/// and is what an Update offer reads; the second means *this card's words are in
/// that artifact, along with other cards'*. Collapsed into one, a re-promotion
/// could offer to rewrite a six-card note with one card's text.
public enum ListCanvasTool: MCPTool {

    public struct Params: Codable {
        public let project_id: String
        /// Default true. `false` returns the same structure with no scrap text —
        /// the way through when a canvas is over the response budget, which is
        /// why the budget refusal names it.
        public let include_text: Bool?
    }

    public struct Node: Codable, Equatable {
        public let id: String
        /// `"scrap"` (words that live only here) or `"item"` (something that
        /// already exists in the project; the canvas holds only its position).
        public let kind: String
        /// The research item / palette card an item node points at. Absent for a
        /// scrap.
        public let reference_id: String?
        /// A scrap's words. Absent for an item node, and absent for every node
        /// when `include_text` was false — `includes_text` on the result is what
        /// tells the two apart.
        public let text: String?
        public let x: Double
        public let y: Double
        public let width: Double
        /// Derived from the text, so it is absent until the card has been
        /// measured — an unmeasured card is not drawn and not clickable.
        public let height: Double?
        /// The artifact this card BECAME.
        public let promoted_item_id: String?
        /// The artifact this card's words went INTO, alongside other cards'.
        /// Never readable as `promoted_item_id`; see the type's doc comment.
        public let contributed_to_item_id: String?
        public let bound_piece_id: String?
        /// `"claude"` for a card this server added. **Absent means the writer.**
        ///
        /// `AnnotationAuthor.SourceKind` does have a `.human` case — what
        /// `CanvasNode.author` has no `.human` DEFAULT: the field is optional and
        /// absence is what records the writer, so that every card written before
        /// 1C-c3 stays theirs without an `author` key appearing in every sidecar
        /// for a feature nobody had used. Emitting a value here for a nil field
        /// would put a positive provenance record on the wire that the canvas
        /// never made.
        public let author: String?
    }

    public struct Region: Codable, Equatable {
        public let id: String
        public let label: String
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        /// A collapsed region's home members are hidden on the canvas — still in
        /// this response, still in the scene, not on screen.
        public let is_collapsed: Bool
        public let bound_piece_id: String?
        public let promoted_item_id: String?
        /// Cards that LIVE here: they travel with the region and inherit its
        /// piece binding (§4.4).
        public let home_node_ids: [String]
        /// Cards that merely APPEAR here — references, never copies (§4.3).
        public let appearance_node_ids: [String]
    }

    public struct Line: Codable, Equatable {
        public let id: String
        public let from_node_id: String
        public let to_node_id: String
        /// Free text, if the writer gave one. A line has no type and asserts
        /// nothing (spec §5).
        public let label: String?
        /// See `Node.author`.
        public let author: String?
    }

    public struct Result: Codable, Equatable {
        /// `"open_canvas"` or `"sidecar"`.
        public let read_from: String
        /// Whether scrap text is present. Distinguishes a card with no words from
        /// a card whose words were left out by request.
        public let includes_text: Bool
        public let nodes: [Node]
        public let regions: [Region]
        public let lines: [Line]
    }

    public static let method = "list_canvas"

    public static let description = """
        Read a project's planning canvas: every card, every region and every line, \
        with the marks the inspector shows. A "scrap" is a loose thought whose words \
        live only on the canvas; an "item" node points at research the canvas never \
        writes to. `read_from` says which canvas answered — "open_canvas" when the \
        writer has the Plan persona on screen, in which case the scene is live and \
        may include a sentence they are still typing, or "sidecar" when it was read \
        from disk. `author` is absent on the writer's own cards and lines and reads \
        "claude" on ones added through this server. `promoted_item_id` is the \
        artifact a card BECAME; `contributed_to_item_id` is an artifact its words \
        went into alongside other cards' — only the first means the card has \
        produced a note of its own. Pass include_text: false for the same structure \
        without the scraps' words when a canvas is too large to return whole.
        """

    public static let inputSchemaJSON = #"""
        {"type":"object","properties":{"project_id":{"type":"string"},"include_text":{"type":"boolean","description":"Include each scrap's words (default true). false returns the same cards, regions, lines and marks with no text — the narrower read to fall back on when the whole canvas is over the response budget."}},"required":["project_id"]}
        """#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let includeText = params.include_text ?? true

        // The shared discriminator, not a second reader: the write tool resolves
        // the same canvas the same way, so a read followed by a write cannot
        // address two different scenes.
        let read = CanvasClaudeWrite.readScene(store: entry.store, projectRoot: entry.url)

        let result = Result(
            read_from: read.fromOpenCanvas ? "open_canvas" : "sidecar",
            includes_text: includeText,
            // Draw order — z, then id. Total and stable, so two reads of an
            // unchanged canvas produce the same list.
            nodes: read.scene.nodes.map {
                describe($0, scraps: read.scraps, includeText: includeText)
            },
            // `regions` and `lines` are already id-sorted by the scene; a second
            // opinion about the order here would be a second opinion.
            regions: read.scene.regions.map(describe),
            lines: read.scene.lines.map(describe))

        // Enforced HERE and not left to `MCPToolsCallHandler`'s backstop: scrap
        // text is unbounded, and the backstop only covers the `tools/call`
        // dispatch path while every tool method is also registered as a top-level
        // JSON-RPC method that bypasses it (`MaughamApp.registerTools`).
        //
        // The hint names a read that is narrower in the dimension that actually
        // overflowed — the words — rather than dead-ending the caller. There is
        // no id- or region-scoped read to point at instead: the canvas is one
        // scene per project (spec §2), so trimming the unbounded field is the
        // only smaller thing to ask for.
        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(result),
            hint: "This canvas is too large to return in one MCP response. Call "
                + "list_canvas again with include_text: false for the same cards, "
                + "regions, lines and marks without the scraps' words, which are "
                + "the part that grows without limit.")
    }

    private static func describe(_ node: CanvasNode,
                                 scraps: [CanvasNodeID: String],
                                 includeText: Bool) -> Node {
        let kind: String
        let referenceId: String?
        let text: String?
        switch node.kind {
        case .scrap:
            kind = "scrap"
            referenceId = nil
            // A scrap with no entry has no words yet, which is not the same as a
            // read that carried none — `includes_text` is what says which.
            text = includeText ? (scraps[node.id] ?? "") : nil
        case .item(let reference):
            kind = "item"
            referenceId = reference
            text = nil
        }
        return Node(
            id: node.id.raw,
            kind: kind,
            reference_id: referenceId,
            text: text,
            x: Double(node.origin.x),
            y: Double(node.origin.y),
            width: Double(node.width),
            height: node.cachedHeight.map(Double.init),
            promoted_item_id: node.promotedItemID,
            contributed_to_item_id: node.contributedToItemID,
            bound_piece_id: node.boundPieceID,
            author: node.author?.rawValue)
    }

    private static func describe(_ region: CanvasRegion) -> Region {
        Region(
            id: region.id.raw,
            label: region.label,
            x: Double(region.frame.minX),
            y: Double(region.frame.minY),
            width: Double(region.frame.width),
            height: Double(region.frame.height),
            is_collapsed: region.isCollapsed,
            bound_piece_id: region.boundPieceID,
            promoted_item_id: region.promotedItemID,
            // Sorted for the reason the sidecar codec sorts them: `Set` iteration
            // order is not stable across runs, and two reads of an unchanged
            // canvas must not differ.
            home_node_ids: region.homeMembers.map(\.raw).sorted(),
            appearance_node_ids: region.appearances.map(\.raw).sorted())
    }

    private static func describe(_ line: CanvasLine) -> Line {
        Line(
            id: line.id.raw,
            from_node_id: line.from.raw,
            to_node_id: line.to.raw,
            label: line.label,
            author: line.author?.rawValue)
    }
}
