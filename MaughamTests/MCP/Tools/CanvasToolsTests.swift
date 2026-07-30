import XCTest
@testable import Maugham
import MaughamCore

/// **What Claude sees when it looks at the planning canvas.**
///
/// `list_canvas` is the read half of 1C-c3's MCP surface. It has one job and two
/// ways to get it wrong, and the tests below are organised around them:
///
/// - **It must report the whole scene** — every card, every region, every line,
///   and the marks the inspector shows beside them. A missing field here is not a
///   cosmetic loss: `promoted_item_id` and `contributed_to_item_id` are two
///   different facts (spec §6.3), and a reader that cannot tell them apart would
///   offer to rewrite a six-card note with one card's text.
/// - **It must say WHICH canvas answered.** The live model is ahead of the sidecar
///   and never behind it, so `read_from` is the difference between "this is what
///   the writer is looking at" and "this is what was last written to disk".
///   `read_preview_page` puts `preview_filename`/`preview_mtime` in its response
///   for the same reason: provenance the caller cannot recover is provenance the
///   response has to carry.
///
/// The budget test is the third thing, and it is not a formality: scrap text is
/// unbounded, so a real canvas can outgrow the 900 KB text budget. The refusal has
/// to name a way through, and the test after it proves the way through actually
/// works — a hint naming an escape hatch nobody built is a dead end with better
/// manners.
@MainActor
final class CanvasToolsTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    // MARK: - Fixtures

    private func registeredProject(
        _ name: String = "CanvasMCP"
    ) async throws -> (url: URL, store: ProjectStore, registry: ProjectRegistry, id: String) {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let registry = ProjectRegistry()
        registry.register(url: url, store: store)
        return (url, store, registry, ProjectIdentifier.id(for: url))
    }

    /// An attached model wired to its store — the shape a tool meets while the
    /// writer has the Plan persona on screen.
    private func attached(to store: ProjectStore, at projectRoot: URL) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: projectRoot)
        store.liveCanvas = model
        return model
    }

    private func node(_ id: String,
                      kind: CanvasNodeKind = .scrap,
                      x: CGFloat = 0, y: CGFloat = 0,
                      width: CGFloat = 220,
                      height: CGFloat? = 60,
                      promoted: String? = nil,
                      contributed: String? = nil,
                      piece: String? = nil,
                      author: AnnotationAuthor.SourceKind? = nil) -> CanvasNode {
        CanvasNode(id: CanvasNodeID(id), kind: kind,
                   origin: CGPoint(x: x, y: y), width: width, cachedHeight: height,
                   promotedItemID: promoted, boundPieceID: piece,
                   contributedToItemID: contributed, author: author)
    }

    private func call(_ registry: ProjectRegistry,
                      _ projectId: String,
                      includeText: Bool? = nil) async throws -> ListCanvasTool.Result {
        var params = "{\"project_id\":\"\(projectId)\""
        if let includeText { params += ",\"include_text\":\(includeText)" }
        params += "}"
        let json = try await ListCanvasTool.handle(
            paramsJSON: Data(params.utf8), registry: registry)
        return try JSONDecoder().decode(ListCanvasTool.Result.self, from: json)
    }

    private func reported(_ result: ListCanvasTool.Result,
                          _ id: String) -> ListCanvasTool.Node? {
        result.nodes.first { $0.id == id }
    }

    // MARK: - The whole scene

    /// Two scraps, an item node, a region holding one of each way, and a line —
    /// every primitive the canvas has, and every one of them in the response with
    /// the fields that make it usable.
    func test_itReportsEveryNodeRegionAndLine() async throws {
        let (url, store, registry, id) = try await registeredProject()
        let model = attached(to: store, at: url)
        model.withScene { scene in
            scene.insert(node("aaaa", x: 10, y: 20, width: 200, height: 44))
            scene.insert(node("bbbb", x: 300, y: 20))
            scene.insert(node("cccc", kind: .item(referenceId: "res-7"), x: 10, y: 200))
            var region = CanvasRegion(id: CanvasRegionID("r1"), label: "The port",
                                      frame: CGRect(x: 0, y: 0, width: 500, height: 300))
            region.addHome(CanvasNodeID("aaaa"))
            region.addAppearance(CanvasNodeID("cccc"))
            scene.insertRegion(region)
            scene.insertLine(CanvasLine(id: CanvasLineID("l1"),
                                        from: CanvasNodeID("aaaa"),
                                        to: CanvasNodeID("bbbb"),
                                        label: "leads to"))
        }
        model.setScrapText("the harbour at four", for: CanvasNodeID("aaaa"))
        model.setScrapText("and the boy on the wall", for: CanvasNodeID("bbbb"))

        let result = try await call(registry, id)

        XCTAssertEqual(result.nodes.count, 3, "every card, including the item node")
        XCTAssertEqual(result.regions.count, 1)
        XCTAssertEqual(result.lines.count, 1)

        let scrap = try XCTUnwrap(reported(result, "aaaa"))
        XCTAssertEqual(scrap.kind, "scrap")
        XCTAssertNil(scrap.reference_id, "a scrap points at nothing")
        XCTAssertEqual(scrap.text, "the harbour at four",
                       "the words are the card — a position without them is unreadable")
        XCTAssertEqual(scrap.x, 10)
        XCTAssertEqual(scrap.y, 20)
        XCTAssertEqual(scrap.width, 200)
        XCTAssertEqual(scrap.height, 44)

        let item = try XCTUnwrap(reported(result, "cccc"))
        XCTAssertEqual(item.kind, "item")
        XCTAssertEqual(item.reference_id, "res-7",
                       "an item node is only useful if it says what it points at")
        XCTAssertNil(item.text, "the canvas never holds an item's words")

        let region = try XCTUnwrap(result.regions.first)
        XCTAssertEqual(region.id, "r1")
        XCTAssertEqual(region.label, "The port")
        XCTAssertEqual(region.x, 0)
        XCTAssertEqual(region.y, 0)
        XCTAssertEqual(region.width, 500)
        XCTAssertEqual(region.height, 300)
        XCTAssertFalse(region.is_collapsed)

        let line = try XCTUnwrap(result.lines.first)
        XCTAssertEqual(line.id, "l1")
        XCTAssertEqual(line.from_node_id, "aaaa")
        XCTAssertEqual(line.to_node_id, "bbbb")
        XCTAssertEqual(line.label, "leads to")
    }

    /// **Where the answer came from is a fact the caller cannot recover.** The live
    /// model holds everything the sidecar does and more — including the sentence
    /// the writer is mid-way through typing, which the mounted editor folds in on
    /// every keystroke (tripwire 28). A response that did not say which canvas it
    /// read would make "the canvas has three cards" and "the canvas had three
    /// cards when it was last saved" the same sentence.
    func test_itSaysWhereItRead() async throws {
        let closed = try await registeredProject("Closed")
        CanvasStore(projectRoot: closed.url).save(
            scene: CanvasScene(nodes: [node("dddd")]),
            scraps: [CanvasNodeID("dddd"): "off the page"])
        XCTAssertNil(closed.store.liveCanvas, "precondition: nobody has this canvas open")

        let fromDisk = try await call(closed.registry, closed.id)
        XCTAssertEqual(fromDisk.read_from, "sidecar")
        XCTAssertEqual(fromDisk.nodes.count, 1, "precondition: it really read the sidecar")

        let open = try await registeredProject("Open")
        let model = attached(to: open.store, at: open.url)
        model.withScene { $0.insert(node("eeee")) }
        model.setScrapText("mid-sentence, and that is the poin", for: CanvasNodeID("eeee"))

        let live = try await call(open.registry, open.id)
        XCTAssertEqual(live.read_from, "open_canvas")
        XCTAssertEqual(reported(live, "eeee")?.text, "mid-sentence, and that is the poin",
                       "the live read is ahead of the sidecar, half-typed sentence and all")
    }

    // MARK: - Provenance and the marks

    /// **nil means the writer.** `CanvasNode.author` has no `.human` case on
    /// purpose, so absence carries the meaning — and the response says so by
    /// omitting the key rather than by inventing a value the model does not have.
    /// The assertion that matters is the pair: Claude's card names Claude, and the
    /// writer's names nobody.
    func test_itNamesTheAuthorOfClaudesNodesAndLines() async throws {
        let (url, store, registry, id) = try await registeredProject()
        let model = attached(to: store, at: url)
        model.withScene { scene in
            scene.insert(node("aaaa"))
            scene.insert(node("bbbb", author: .claude))
            scene.insert(node("cccc", kind: .item(referenceId: "res-1"), y: 400))
            scene.insertLine(CanvasLine(id: CanvasLineID("l1"),
                                        from: CanvasNodeID("aaaa"), to: CanvasNodeID("bbbb")))
            scene.insertLine(CanvasLine(id: CanvasLineID("l2"),
                                        from: CanvasNodeID("bbbb"), to: CanvasNodeID("cccc"),
                                        author: .claude))
        }

        let result = try await call(registry, id)

        XCTAssertNil(reported(result, "aaaa")?.author,
                     "the writer's own card claims no author — absence is the whole "
                     + "convention, and a value here would tell the writer they did "
                     + "not write their own sentence")
        XCTAssertEqual(reported(result, "bbbb")?.author, "claude")
        XCTAssertNil(reported(result, "cccc")?.author,
                     "an item node already exists as itself and carries no author")

        let byID = Dictionary(uniqueKeysWithValues: result.lines.map { ($0.id, $0) })
        XCTAssertNil(byID["l1"]?.author, "the writer drew this one")
        XCTAssertEqual(byID["l2"]?.author, "claude")
    }

    /// **The two marks are two facts, and the payload keeps them apart.**
    ///
    /// `promoted_item_id` means *this card produced this artifact* — it is what
    /// `Promotion.existingArtifact` reads to offer a Rewrite.
    /// `contributed_to_item_id` means *this card's words are in that artifact,
    /// along with other cards'*, and re-promoting a contributor must offer only a
    /// new artifact (spec §6.3). Merged into one field they would let a
    /// re-promotion rewrite a six-card note with one card's text — the 1C-c2
    /// Critical returning as a mark that does not record its cardinality. So the
    /// test asserts they are readable SEPARATELY on a card carrying both.
    func test_itSurfacesTheMarksTheInspectorShows() async throws {
        let (url, store, registry, id) = try await registeredProject()
        let model = attached(to: store, at: url)
        model.withScene { scene in
            scene.insert(node("aaaa", promoted: "note-own",
                              contributed: "card-joint", piece: "piece-3"))
            scene.insert(node("bbbb", y: 200, contributed: "card-joint"))
            var region = CanvasRegion(id: CanvasRegionID("r1"), label: "Weather",
                                      frame: CGRect(x: 0, y: 0, width: 400, height: 400),
                                      boundPieceID: "piece-9",
                                      isCollapsed: true,
                                      promotedItemID: "card-joint")
            region.addHome(CanvasNodeID("aaaa"))
            region.addHome(CanvasNodeID("bbbb"))
            scene.insertRegion(region)
        }

        let result = try await call(registry, id)

        let both = try XCTUnwrap(reported(result, "aaaa"))
        XCTAssertEqual(both.promoted_item_id, "note-own",
                       "the artifact this card BECAME — the one an Update may rewrite")
        XCTAssertEqual(both.contributed_to_item_id, "card-joint",
                       "the artifact this card's words went INTO alongside others'")
        XCTAssertNotEqual(both.promoted_item_id, both.contributed_to_item_id,
                          "precondition: the fixture gives the two marks different "
                          + "values, or the separation is untested")
        XCTAssertEqual(both.bound_piece_id, "piece-3")

        let contributorOnly = try XCTUnwrap(reported(result, "bbbb"))
        XCTAssertNil(contributorOnly.promoted_item_id,
                     "a contributing card has produced nothing of its own — reported "
                     + "as promoted, a re-promotion would offer to rewrite the joint "
                     + "note with this one card's text")
        XCTAssertEqual(contributorOnly.contributed_to_item_id, "card-joint")

        let region = try XCTUnwrap(result.regions.first)
        XCTAssertEqual(region.promoted_item_id, "card-joint")
        XCTAssertEqual(region.bound_piece_id, "piece-9")
        XCTAssertTrue(region.is_collapsed,
                      "a collapsed region hides its residents on screen; a reader that "
                      + "did not know would wonder why the writer cannot see them")
    }

    /// Living in a region and merely appearing in one are different relationships
    /// (§4.3) — only home members travel with the region and only they inherit its
    /// piece binding. The two lists are reported separately for that reason.
    func test_itReportsWhichRegionEachCardLivesIn() async throws {
        let (url, store, registry, id) = try await registeredProject()
        let model = attached(to: store, at: url)
        model.withScene { scene in
            scene.insert(node("aaaa"))
            scene.insert(node("bbbb", y: 200))
            scene.insert(node("cccc", y: 400))
            var lives = CanvasRegion(id: CanvasRegionID("r1"), label: "Home",
                                     frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            lives.addHome(CanvasNodeID("aaaa"))
            lives.addAppearance(CanvasNodeID("bbbb"))
            scene.insertRegion(lives)
            scene.insertRegion(CanvasRegion(id: CanvasRegionID("r2"), label: "Empty",
                                            frame: CGRect(x: 500, y: 0, width: 200, height: 200)))
        }

        let result = try await call(registry, id)

        let home = try XCTUnwrap(result.regions.first { $0.id == "r1" })
        XCTAssertEqual(home.home_node_ids, ["aaaa"],
                       "the card that LIVES here — the one that travels with the region")
        XCTAssertEqual(home.appearance_node_ids, ["bbbb"],
                       "the card that merely appears here: a reference, never a copy")
        XCTAssertFalse(home.home_node_ids.contains("bbbb"),
                       "an appearance reported as a home would say the region owns a "
                       + "card it only cites")
        XCTAssertFalse(home.home_node_ids.contains("cccc"),
                       "a card in no region is in no region's lists")

        let empty = try XCTUnwrap(result.regions.first { $0.id == "r2" })
        XCTAssertEqual(empty.home_node_ids, [])
        XCTAssertEqual(empty.appearance_node_ids, [])
    }

    // MARK: - Absence and failure

    func test_anUnknownProjectFailsLoudly() async throws {
        let registry = ProjectRegistry()
        do {
            _ = try await ListCanvasTool.handle(
                paramsJSON: Data("{\"project_id\":\"nope\"}".utf8), registry: registry)
            XCTFail("expected a throw for a project this server has never opened")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
            XCTAssertEqual(payload.fields["project_id"], .string("nope"))
        }
    }

    /// A project whose writer has never opened the Plan persona has an empty
    /// canvas, and that is a fact rather than a failure — `read_craft_intent`'s
    /// `exists: false` is the precedent. An error here would make "nothing planned
    /// yet" indistinguishable from "something is broken".
    func test_anEmptyCanvasIsNotAnError() async throws {
        let (_, _, registry, id) = try await registeredProject()

        let result = try await call(registry, id)

        XCTAssertEqual(result.nodes, [])
        XCTAssertEqual(result.regions, [])
        XCTAssertEqual(result.lines, [])
        XCTAssertEqual(result.read_from, "sidecar")
    }

    /// **Scrap text is unbounded, so this tool enforces the budget itself.**
    ///
    /// The central backstop in `MCPToolsCallHandler` only covers the `tools/call`
    /// dispatch path, and every tool method is ALSO registered as a top-level
    /// JSON-RPC method (`MaughamApp.registerTools`) which bypasses it. A tool that
    /// leaned on the backstop would be unguarded down that second path, so the
    /// `enforce` call is here and this test is what holds it here.
    func test_aHugeCanvasFailsWithABudgetError() async throws {
        let (url, _, registry, id) = try await registeredProject()
        let (scene, scraps) = hugeCanvas()
        CanvasStore(projectRoot: url).save(scene: scene, scraps: scraps)

        do {
            _ = try await ListCanvasTool.handle(
                paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: registry)
            XCTFail("expected a structured refusal, not a payload the transport drops")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "payload_too_large")
            XCTAssertEqual(payload.fields["max_bytes"],
                           .int(MCPResponseBudget.maxTextBytes))
            let hint = try XCTUnwrap(payload.hint)
            XCTAssertTrue(hint.contains("include_text"),
                          "the hint must name the narrower read that fits rather than "
                          + "dead-ending the caller; got: \(hint)")
        }
    }

    /// The other half of the refusal above: the way out it names has to work. A
    /// hint pointing at an escape hatch nobody built is a dead end with better
    /// manners — so the same canvas that overflowed is read again without the
    /// words, and every card is still there with its ids and its marks.
    func test_theNarrowerReadTheHintNamesActuallyFits() async throws {
        let (url, _, registry, id) = try await registeredProject()
        let (scene, scraps) = hugeCanvas()
        CanvasStore(projectRoot: url).save(scene: scene, scraps: scraps)

        let result = try await call(registry, id, includeText: false)

        XCTAssertFalse(result.includes_text,
                       "the response has to say the words are missing by request, or "
                       + "an empty canvas and a trimmed one read the same")
        XCTAssertEqual(result.nodes.count, scene.count,
                       "every card survives the trim — it is only the words that go")
        for node in result.nodes {
            XCTAssertNil(node.text, "the trimmed read carries no words at all")
        }
    }

    /// Past the 900 KB text budget by construction: twelve scraps of 100 KB each.
    private func hugeCanvas() -> (CanvasScene, [CanvasNodeID: String]) {
        let words = String(repeating: "a", count: 100_000)
        var scene = CanvasScene()
        var scraps: [CanvasNodeID: String] = [:]
        for i in 0..<12 {
            let id = CanvasNodeID("h\(i)")
            scene.insert(CanvasNode(id: id, kind: .scrap,
                                    origin: CGPoint(x: 0, y: CGFloat(i) * 100),
                                    width: 220, cachedHeight: 60))
            scraps[id] = words
        }
        return (scene, scraps)
    }
}
