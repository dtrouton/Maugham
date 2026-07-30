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

/// `add_canvas_scraps(project_id, scraps, source_item_id?, region_label?, connect?)`
/// — what Claude read off a photographed page, on the writer's planning canvas.
///
/// **The membrane holds, and the reasoning is recorded rather than assumed** (MCP
/// tripwire 6, spec §8A.2). Must-not #1 forbids AI originating *manuscript* text.
/// The canvas is a planning surface in the parallel plane, exactly where Claude
/// already writes annotations, translations and palette material: nothing it puts
/// here is manuscript, and nothing reaches the manuscript except through promotion
/// (§6), which is a deliberate writer act. This tool writes `canvas.md` and
/// `.maugham/canvas.json` and nothing else —
/// `test_itNeverTouchesAManuscriptOrAResearchFile` compares the whole project tree
/// before and after rather than trusting that sentence.
///
/// **The signature is the guarantee** (roadmap line 64). There is no position, no
/// node id and no region id here, so *where* Claude's cards land is the canvas's
/// decision (`CanvasClaudePlacement`) and not Claude's. `connect` indexes **this
/// call's own `scraps` array**, which is what lets Claude draw the arrows it read
/// off a page while reaching nothing the writer made. Adding `region_id` or an
/// `x`/`y` for convenience would end that;
/// `test_theSignatureCannotExpressAPositionOrAnId` reads this type's own schema and
/// is what will still be here when someone tries.
///
/// **Every refusal fails loudly and teaches, and validation completes before
/// anything is written.** A half-applied batch on a surface whose whole promise is
/// predictability is worse than a refusal — `PromotionPerformer`'s validate-first
/// rule, same reason. The subtlest of them is the source id: the likeliest wrong
/// one is an *inbox entry* id, because a capture is not a research item until it
/// has been promoted (§8A.4), so the message names `promote_inbox_entry` — while
/// saying *why* it might apply, since a refusal that orders a promotion the caller
/// has already performed is the "Promote both cards first" failure recurring.
public enum AddCanvasScrapsTool: MCPTool {

    public struct Params: Codable {
        public let project_id: String
        /// One card per entry, in reading order. `connect` indexes this array.
        public let scraps: [String]
        /// The **research item** the words were read off — not an inbox entry id
        /// and not a node id. Optional: without it the batch still lands in a
        /// labelled region, because nothing Claude adds is loose.
        public let source_item_id: String?
        public let region_label: String?
        /// Pairs of positions in `scraps`.
        public let connect: [[Int]]?
    }

    /// Ids only. There is no `x`, no `y` and no `width` on the way out either —
    /// not because they would breach the guarantee (the canvas chose them) but
    /// because a caller that reads them starts reasoning about layout, and the next
    /// request is a parameter for it. `list_canvas` reports geometry.
    public struct Result: Codable, Equatable {
        public let region_id: String
        /// In the order the scraps were sent, so a caller can say which card holds
        /// which thought.
        public let node_ids: [String]
        /// The page node, when `source_item_id` named one. Present whether the page
        /// was added by this call or was already on the canvas.
        public let source_node_id: String?
        public let line_ids: [String]
    }

    public static let method = "add_canvas_scraps"

    public static let description = """
        Add cards to a project's planning canvas — what you read off a photographed \
        page of the writer's notes, or thoughts you are offering them. Each string \
        in `scraps` becomes one card, marked as yours so the writer can tell at a \
        glance what they wrote from what you added. They all land together in one \
        labelled region: nothing you add is ever loose on their canvas. \
        **You cannot say where anything goes** — no position, no node id, no region \
        id — because the canvas decides that, and you cannot touch a card the writer \
        made. `connect` draws lines among the cards THIS call creates, given as \
        pairs of positions in your own `scraps` array (`[[0, 2]]` joins the first to \
        the third); a line is undirected and asserts nothing, so send each pair \
        once. `source_item_id` is the RESEARCH ITEM the words came off — the page \
        stays on the canvas beside them so the writer can check the reading against \
        the source. An inbox capture is not a research item until it is promoted. \
        Nothing here is manuscript: the canvas is a thinking surface, and its \
        contents reach the manuscript only when the writer promotes them.
        """

    public static let inputSchemaJSON = #"""
        {"type":"object","properties":{"project_id":{"type":"string"},"scraps":{"type":"array","items":{"type":"string"},"description":"One card per entry, in reading order. Must be non-empty, and no entry may be blank."},"source_item_id":{"type":"string","description":"The research item these words were read off (e.g. a photographed page promoted into research). Not an inbox entry id, and not a canvas node id. The item is placed on the canvas above the scraps so the reading and its source can be checked side by side."},"region_label":{"type":"string","description":"What to call the region these cards land in. Defaults to \"From Claude\"."},"connect":{"type":"array","items":{"type":"array","items":{"type":"integer"}},"description":"Lines among the cards this call creates, as pairs of positions in this call's own scraps array — [[0, 2]] joins the first scrap to the third. It cannot reach a card that already exists. A line is undirected and untyped, so [0, 1] and [1, 0] are the same line; send each pair once."}},"required":["project_id","scraps"]}
        """#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)

        // ---- Everything is validated before anything is written. ----

        guard !params.scraps.isEmpty else {
            throw MCPError.toolError(payload: .init(
                error: "no_scraps",
                message: "add_canvas_scraps was called with no scraps.",
                hint: "Pass at least one scrap — each string becomes one card. An "
                    + "empty batch would leave a labelled but empty region on the "
                    + "writer's canvas, which is indistinguishable from a fault."))
        }
        if let blank = params.scraps.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            throw MCPError.toolError(payload: .init(
                error: "blank_scrap",
                message: "scraps[\(blank)] is empty or only whitespace.",
                hint: "Every scrap becomes a card with those words on it, so a blank "
                    + "one reads as a rendering fault rather than as a thought. Drop "
                    + "the entry, or give it the words you read.",
                fields: ["index": .int(blank)]))
        }
        if let sourceID = params.source_item_id {
            // The tree walk matches groups as well as items, so the type check is
            // not belt-and-braces: a folder id would mint `item:<groupId>`, an item
            // node pointing at something with no title card, no glyph and no
            // thumbnail — a card no other surface can create and 1C-d has no case
            // for. `AddNoteTool` checks the type of its own tree parameter for the
            // same reason.
            switch TreeWalk.find(id: sourceID, in: entry.store.manifest.research) {
            case nil:
                throw MCPError.toolError(payload: .init(
                    error: "research_item_not_found",
                    message: "'\(sourceID)' is not a research item in this project.",
                    hint: "source_item_id names a research item — call list_research "
                        + "to find the right id. If this id came from list_inbox it "
                        + "is a capture rather than a research item: captures become "
                        + "research items through promote_inbox_entry, and it is the "
                        + "id that returns which belongs here. Omit source_item_id to "
                        + "add the scraps without a source page.",
                    fields: ["source_item_id": .string(sourceID)]))
            case .some(let item) where item.type == .group:
                throw MCPError.toolError(payload: .init(
                    error: "research_item_is_a_group",
                    message: "'\(sourceID)' names the research group '\(item.title)', "
                        + "not an item in it.",
                    hint: "source_item_id is the page the words were read off — a "
                        + "note, an image, a document. A group is a folder, and a "
                        + "card standing for a folder is not something the writer "
                        + "can look at beside the scraps. Call list_research and "
                        + "pass the id of the item inside the group.",
                    fields: ["source_item_id": .string(sourceID)]))
            default:
                break
            }
        }
        let connections = try validated(params.connect ?? [], against: params.scraps.count)

        // ---- Nothing above can fail from here on. ----

        // The shared discriminator, so a `list_canvas` and an `add_canvas_scraps` in
        // the same breath cannot address two different scenes — and so the plan is
        // made against the scene it is about to be applied to, which is the only
        // scene it is valid for (`CanvasClaudePlacement.apply`).
        let read = CanvasClaudeWrite.readScene(store: entry.store, projectRoot: entry.url)
        let plan = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: params.scraps,
                                          sourceReferenceID: params.source_item_id,
                                          regionLabel: params.region_label,
                                          connections: connections),
            in: read.scene)
        try CanvasClaudeWrite.apply(plan, store: entry.store, projectRoot: entry.url)

        // Project-scoped (ADR 0021), as every data event is: a window on another
        // project must not announce cards it did not receive. `maughamMCPNoteAdded`
        // is the model.
        MaughamEvent.post(
            .maughamCanvasNodesAdded,
            to: .project(id: params.project_id),
            payload: [
                MaughamEvent.canvasScrapCountKey: plan.scraps.count,
                MaughamEvent.canvasRegionIDKey: plan.regionID.raw
            ])

        // **"Added to the canvas", never "saved".** `CanvasStore.writeNow` swallows
        // every I/O error with `try?` — area-wide and pre-existing — so `apply`
        // returning is evidence the scene now holds these cards, and not evidence
        // that the disk does.
        return try JSONEncoder().encode(Result(
            region_id: plan.regionID.raw,
            node_ids: plan.scraps.map(\.node.id.raw),
            source_node_id: plan.source?.id.raw,
            line_ids: plan.lines.map(\.id.raw)))
    }

    /// **Fail rather than drop, on every one of the four ways a pair can be wrong.**
    ///
    /// `CanvasScene.insertLine` silently refuses a self-line at the model boundary,
    /// which is right for the model and wrong for a tool: a silently-dropped line is
    /// a caller believing something exists that does not. The same reasoning settles
    /// the duplicate and the reversed pair, which is the less obvious call. A canvas
    /// line is **undirected and untyped** (spec §5) — it asserts nothing, and
    /// `CanvasLine`'s `from`/`to` are the two ends of a segment rather than a
    /// direction — so `[0, 1]` and `[1, 0]` are one relationship, and two lines drawn
    /// between the same pair of centres are coincident and indistinguishable from
    /// one. Deduping silently would hand back fewer connections than were asked for,
    /// which is the dropped-line failure wearing a tidier coat.
    private static func validated(_ pairs: [[Int]],
                                  against scrapCount: Int) throws -> [(Int, Int)] {
        var seen: Set<[Int]> = []
        var out: [(Int, Int)] = []
        for (index, pair) in pairs.enumerated() {
            guard pair.count == 2 else {
                throw invalidConnection(
                    at: index,
                    "connect[\(index)] has \(pair.count) "
                        + (pair.count == 1 ? "entry" : "entries") + ".",
                    "Each connection is a pair of two positions in this call's own "
                        + "`scraps` array — write it as [[0, 2]] to join the first "
                        + "scrap to the third.")
            }
            let (from, to) = (pair[0], pair[1])
            if let outside = pair.first(where: { $0 < 0 || $0 >= scrapCount }) {
                throw invalidConnection(
                    at: index,
                    "connect[\(index)] names position \(outside), and this call has "
                        + "\(scrapCount) "
                        + (scrapCount == 1 ? "scrap" : "scraps") + ".",
                    "`connect` indexes this call's own `scraps` array, counted from "
                        + "0 — not node ids on the canvas. It can only join cards "
                        + "this call is creating; it cannot reach a card the writer "
                        + "already has.")
            }
            guard from != to else {
                throw invalidConnection(
                    at: index,
                    "connect[\(index)] joins position \(from) to itself.",
                    "A line runs between two different cards. If two thoughts belong "
                        + "together, give the two positions they hold in this call's "
                        + "`scraps` array.")
            }
            guard seen.insert([min(from, to), max(from, to)]).inserted else {
                throw invalidConnection(
                    at: index,
                    "connect[\(index)] repeats the connection between positions "
                        + "\(from) and \(to).",
                    "A canvas line is undirected and asserts nothing, so [\(from), "
                        + "\(to)] and [\(to), \(from)] are the same line — drawn "
                        + "twice they land on top of each other and read as one. "
                        + "Send each connection once.")
            }
            out.append((from, to))
        }
        return out
    }

    private static func invalidConnection(at index: Int,
                                          _ message: String,
                                          _ hint: String) -> MCPError {
        .toolError(payload: .init(error: "invalid_connection",
                                  message: message,
                                  hint: hint,
                                  fields: ["index": .int(index)]))
    }
}
