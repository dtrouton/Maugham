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
///
/// **`add_canvas_scraps` is the write half, and the tests for it are organised
/// around a different pair of risks.** The first is the *signature*: roadmap line
/// 64 commits this tool to expressing no position, no node id and no region id, so
/// where Claude's cards land is the canvas's decision. That guarantee is asserted
/// against the tool's own `inputSchemaJSON` rather than described in a comment,
/// because a comment is what someone adding `region_id` for convenience reads
/// past. The second is *all-or-nothing*: every refusal test asserts that nothing
/// whatever reached disk, not merely that the bad part is absent — a half-applied
/// batch on a surface whose whole promise is predictability is worse than a
/// refusal, and "the line is missing" is satisfied by a run that wrote three cards
/// and then threw.
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

    /// **nil means the writer.** `AnnotationAuthor.SourceKind` does have a
    /// `.human` case; what `CanvasNode.author` has no `.human` DEFAULT — the field
    /// is optional and absence is what records the writer — so the response says
    /// so by omitting the key rather than by putting a provenance record on the
    /// wire that the canvas never made. The assertion that matters is the pair:
    /// Claude's card names Claude, and the writer's names nobody.
    ///
    /// **Every "names nobody" assertion unwraps its subject first**, and that is
    /// not ceremony: on an optional chain, `XCTAssertNil(reported(…)?.author)` is
    /// satisfied by the card being ABSENT FROM THE RESPONSE ENTIRELY, so a
    /// regression that dropped the writer's card would be green in the test
    /// written to check what the writer's card reports. Four assertions in this
    /// slice have failed that way already.
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

        let writersCard = try XCTUnwrap(reported(result, "aaaa"),
                                        "the writer's own card is missing from the "
                                        + "response altogether")
        XCTAssertNil(writersCard.author,
                     "the writer's own card claims no author — absence is the whole "
                     + "convention, and a value here would tell the writer they did "
                     + "not write their own sentence")
        XCTAssertEqual(reported(result, "bbbb")?.author, "claude")
        let itemNode = try XCTUnwrap(reported(result, "cccc"),
                                     "the item node is missing from the response "
                                     + "altogether")
        XCTAssertNil(itemNode.author,
                     "an item node already exists as itself and carries no author")

        let byID = Dictionary(uniqueKeysWithValues: result.lines.map { ($0.id, $0) })
        let writersLine = try XCTUnwrap(byID["l1"],
                                        "the writer's own line is missing from the "
                                        + "response altogether")
        XCTAssertNil(writersLine.author, "the writer drew this one")
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
        // Against the LITERAL and not against `scene.count`: two derived counts
        // that are both zero agree, and the loop below then runs no times while
        // reading as full coverage. That is the same empty-vs-empty shape this
        // slice has already shipped once.
        XCTAssertEqual(scene.count, Self.hugeCanvasCards,
                       "precondition: the fixture built the cards it claims to")
        XCTAssertEqual(result.nodes.count, Self.hugeCanvasCards,
                       "every card survives the trim — it is only the words that go")
        for node in result.nodes {
            XCTAssertNil(node.text, "the trimmed read carries no words at all")
        }
    }

    /// Named so the trim test can assert against the number rather than against
    /// another collection's count — see there for why that distinction is load-bearing.
    private static let hugeCanvasCards = 12

    /// Past the 900 KB text budget by construction: twelve scraps of 100 KB each.
    private func hugeCanvas() -> (CanvasScene, [CanvasNodeID: String]) {
        let words = String(repeating: "a", count: 100_000)
        var scene = CanvasScene()
        var scraps: [CanvasNodeID: String] = [:]
        for i in 0..<Self.hugeCanvasCards {
            let id = CanvasNodeID("h\(i)")
            scene.insert(CanvasNode(id: id, kind: .scrap,
                                    origin: CGPoint(x: 0, y: CGFloat(i) * 100),
                                    width: 220, cachedHeight: 60))
            scraps[id] = words
        }
        return (scene, scraps)
    }

    // MARK: - add_canvas_scraps: fixtures

    private func add(_ registry: ProjectRegistry,
                     _ projectId: String,
                     scraps: [String],
                     sourceItemID: String? = nil,
                     regionLabel: String? = nil,
                     connect: [[Int]]? = nil) async throws -> AddCanvasScrapsTool.Result {
        let params = AddCanvasScrapsTool.Params(
            project_id: projectId, scraps: scraps, source_item_id: sourceItemID,
            region_label: regionLabel, connect: connect)
        let json = try await AddCanvasScrapsTool.handle(
            paramsJSON: try JSONEncoder().encode(params), registry: registry)
        return try JSONDecoder().decode(AddCanvasScrapsTool.Result.self, from: json)
    }

    /// The words as `canvas.md` actually holds them, read back through the parser
    /// the app itself uses. The scraps file is *content* (spec §3.2) — the sidecar
    /// can be deleted without losing a word, and this is the file that would have
    /// to have lost it.
    private func scrapsOnDisk(at projectRoot: URL) throws -> [CanvasNodeID: String] {
        let url = projectRoot.appendingPathComponent(CanvasStore.scrapsRelativePath)
        return ScrapText.parse(try String(contentsOf: url, encoding: .utf8))
    }

    /// **All-or-nothing, asserted as absence of the whole write.** A refusal test
    /// that only checked the offending line was missing would pass for a run that
    /// created the region and three cards and then threw — which is precisely the
    /// half-applied batch the validate-first rule exists to prevent. Neither canvas
    /// file may exist at all.
    private func assertNothingWasWritten(at projectRoot: URL,
                                         _ what: String = "",
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        for relative in [CanvasStore.scrapsRelativePath, CanvasStore.sidecarRelativePath] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: projectRoot.appendingPathComponent(relative).path),
                "a refused call wrote \(relative): the batch was applied in part and "
                + "then abandoned, which leaves the writer's canvas holding cards "
                + "from a call that reported failure. \(what)",
                file: file, line: line)
        }
    }

    /// Every file under the project, keyed by its path relative to the root. The
    /// membrane check compares two of these.
    ///
    /// Both sides are resolved through their symlinks before the prefix is taken:
    /// the temp root arrives as `/var/…` and the enumerator hands back
    /// `/private/var/…`, so a plain string strip silently produces keys nothing can
    /// match and the whole comparison degenerates into two disjoint sets.
    private func fileTree(at root: URL) throws -> [String: Data] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var out: [String: Data] = [:]
        let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = walker?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
            else { continue }
            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(base + "/") else {
                XCTFail("\(full) is not under \(base) — the relative keys below "
                        + "would be meaningless and the comparison vacuous")
                continue
            }
            out[String(full.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return out
    }

    // MARK: - add_canvas_scraps: the batch arrives

    /// The payoff, end to end: three thoughts read off a page become three cards
    /// in a region of their own, with their words in `canvas.md` — the file that is
    /// content, not the sidecar that is derived.
    ///
    /// Nothing Claude adds is loose (§8A.2 constraint 2), so the region is not a
    /// nicety: it is what makes "what was read off this page" answerable by looking.
    func test_itAddsTheScrapsInARegionOfTheirOwn() async throws {
        let (url, store, registry, id) = try await registeredProject()
        let model = attached(to: store, at: url)

        let result = try await add(registry, id, scraps: [
            "the harbour at four", "and the boy on the wall", "October, and no rain",
        ])

        XCTAssertEqual(result.node_ids.count, 3, "one card per scrap")
        XCTAssertEqual(Set(result.node_ids).count, 3, "three distinct ids, or two "
                       + "cards are the same card and one set of words is lost")
        XCTAssertNil(result.source_node_id, "no page was named")
        XCTAssertEqual(result.line_ids, [])

        let region = try XCTUnwrap(model.scene.region(CanvasRegionID(result.region_id)),
                                   "the region the response names is not on the canvas")
        XCTAssertEqual(region.label, CanvasClaudePlacement.defaultRegionLabel,
                       "an unnamed batch still arrives labelled — an unlabelled one "
                       + "is indistinguishable from a region the writer swept and "
                       + "has not named yet")

        let words = ["the harbour at four", "and the boy on the wall", "October, and no rain"]
        let onDisk = try scrapsOnDisk(at: url)
        for (index, nodeId) in result.node_ids.enumerated() {
            let node = try XCTUnwrap(model.scene.node(CanvasNodeID(nodeId)),
                                     "a card the response promised is not in the scene")
            XCTAssertEqual(model.scraps[node.id], words[index],
                           "the ids come back in the order the scraps were sent, or a "
                           + "caller cannot say which card holds which thought")
            XCTAssertTrue(region.homeMembers.contains(node.id),
                          "a card outside the region is loose, and where it came from "
                          + "is unrecoverable by looking")
            XCTAssertEqual(onDisk[node.id], words[index],
                           "the words are in memory and not in canvas.md — the canvas "
                           + "has no op log behind it, so a quit here loses them")
        }
    }

    /// **Claude-created nodes must be visibly marked as such** (§8A.2 constraint 1):
    /// the writer has to be able to tell at a glance what they wrote from what was
    /// read off a photograph. The card is unwrapped before its author is read —
    /// `XCTAssertEqual(scene.node(id)?.author, .claude)` would be satisfied by the
    /// card being absent, which is the shape that has produced four false greens in
    /// this slice.
    func test_theScrapsAreMarkedAsClaudes() async throws {
        let (url, store, registry, id) = try await registeredProject()
        let model = attached(to: store, at: url)

        let result = try await add(registry, id, scraps: ["one", "two"])

        XCTAssertEqual(result.node_ids.count, 2,
                       "precondition: there are cards for the loop below to check")
        for nodeId in result.node_ids {
            let node = try XCTUnwrap(model.scene.node(CanvasNodeID(nodeId)),
                                     "the card is missing from the scene altogether")
            XCTAssertEqual(node.author, .claude,
                           "an unmarked card claims to be the writer's own thought")
        }
    }

    /// **The reproduction corollary in full** (§8A.2 constraint 2): the page stays
    /// on the canvas beside what was read off it, so the two are checkable side by
    /// side. And the page carries no author — the tint means *these words came off
    /// a machine*, and the photograph is the writer's.
    func test_aNamedSourcePutsThePageInTheRegionWithThem() async throws {
        let (url, store, registry, id) = try await registeredProject()
        let model = attached(to: store, at: url)
        let page = try await store.addResearchTextNote(parentId: nil, title: "Page 4")

        let result = try await add(registry, id,
                                   scraps: ["a note in the margin"],
                                   sourceItemID: page.id)

        let sourceNodeId = try XCTUnwrap(result.source_node_id,
                                         "the response never named the page, so a "
                                         + "caller cannot point at what was read")
        let sourceNode = try XCTUnwrap(model.scene.node(CanvasNodeID(sourceNodeId)),
                                       "the page is not on the canvas, so what the "
                                       + "scraps were read off is unrecoverable")
        XCTAssertEqual(sourceNode.kind, .item(referenceId: page.id),
                       "the page node must point at the research item itself")
        XCTAssertNil(sourceNode.author,
                     "the photograph is the writer's; tinting it would say Claude "
                     + "took it")

        let region = try XCTUnwrap(model.scene.region(CanvasRegionID(result.region_id)))
        XCTAssertTrue(region.homeMembers.contains(sourceNode.id),
                      "the page and its scraps must be in one region, or \"what was "
                      + "read off this page\" is not answerable by looking")
        let scrap = try XCTUnwrap(result.node_ids.first)
        XCTAssertTrue(region.homeMembers.contains(CanvasNodeID(scrap)))
    }

    /// `connect` indexes **this call's own `scraps` array**, which is what lets
    /// Claude draw the arrows it read off a page while reaching nothing the writer
    /// made.
    func test_connectDrawsLinesAmongTheNewScraps() async throws {
        let (url, store, registry, id) = try await registeredProject()
        let model = attached(to: store, at: url)

        let result = try await add(registry, id,
                                   scraps: ["first", "second", "third"],
                                   connect: [[0, 2]])

        XCTAssertEqual(result.line_ids.count, 1)
        XCTAssertEqual(result.node_ids.count, 3,
                       "precondition: the indices below name real positions")
        let line = try XCTUnwrap(model.scene.line(CanvasLineID(result.line_ids[0])),
                                 "the line the response promised is not on the canvas")
        XCTAssertEqual(line.from, CanvasNodeID(result.node_ids[0]))
        XCTAssertEqual(line.to, CanvasNodeID(result.node_ids[2]))
        XCTAssertEqual(line.author, .claude,
                       "an unmarked line claims the writer drew it")
        XCTAssertNil(line.label,
                     "a label from Claude on an edge is the nearest thing to the "
                     + "typed edge §5 spends its length rejecting")
    }

    /// **The banner's event, and it is project-scoped.** A window on another
    /// project must not announce cards it did not receive, so the scope is the
    /// delivery rule rather than a payload field the receiver compares
    /// (`maughamMCPNoteAdded` is the model). The test receives through the real
    /// wrapper, so the filter itself is on the asserted path.
    func test_itPostsForTheBanner() async throws {
        let (url, store, registry, id) = try await registeredProject()
        _ = attached(to: store, at: url)

        var observed: Notification?
        let arrived = expectation(description: "the canvas announced the arrival")
        let token = MaughamEvent.observe(
            .maughamCanvasNodesAdded,
            context: { EventReceiverContext(kind: .project(id: id),
                                            isWindowLive: true, isWindowKey: false) },
            handler: { note in
                observed = note
                arrived.fulfill()
            })
        defer { NotificationCenter.default.removeObserver(token) }

        let result = try await add(registry, id, scraps: ["one", "two", "three"])
        await fulfillment(of: [arrived], timeout: 1)

        let note = try XCTUnwrap(observed,
                                 "nothing was posted, so the writer's only notice "
                                 + "that Claude added anything is noticing it")
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeKindKey] as? String, "project",
                       "an unscoped or key-window post reaches windows on other "
                       + "projects, or none at all")
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeIdKey] as? String, id)
        XCTAssertEqual(note.userInfo?[MaughamEvent.canvasScrapCountKey] as? Int, 3,
                       "the count is how the banner says what arrived")
        XCTAssertEqual(note.userInfo?[MaughamEvent.canvasRegionIDKey] as? String,
                       result.region_id,
                       "the region id is how a receiver takes the writer to it "
                       + "without re-reading the whole canvas")
    }

    // MARK: - add_canvas_scraps: the signature is the guarantee

    /// **The guarantee as a test rather than as a comment.** Roadmap line 64 commits
    /// this tool to expressing no position, no node id and no region id, so where
    /// Claude's scraps land is the canvas's decision and not Claude's. Any one of
    /// `region_id`, `node_id`, `x`, `y` or `width` on this schema breaks it — and
    /// each of them is exactly the kind of thing that gets added for convenience by
    /// someone who read the doc comment and found it agreeable.
    func test_theSignatureCannotExpressAPositionOrAnId() throws {
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(AddCanvasScrapsTool.inputSchemaJSON.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any],
                                       "the schema declares no properties at all")

        XCTAssertEqual(
            Set(properties.keys),
            ["project_id", "scraps", "source_item_id", "region_label", "connect"],
            "the write tool's signature has changed. If a position, a node id or a "
            + "region id has been added, the canvas no longer decides where Claude's "
            + "cards go — which is the guarantee this tool was shaped around "
            + "(roadmap line 64). `connect` indexes this call's own `scraps` array "
            + "precisely so Claude can draw the arrows it read off a page and reach "
            + "nothing the writer made.")
        XCTAssertEqual(schema["required"] as? [String], ["project_id", "scraps"],
                       "the words and the project are the whole of what a caller "
                       + "must supply")
    }

    /// **The membrane check** (MCP tripwire 6). A write tool needs justification,
    /// and the justification is that the canvas is a planning surface in the
    /// parallel plane: nothing here is manuscript, and nothing reaches the
    /// manuscript except through promotion, which is a writer act. That argument
    /// only holds if the tool writes what it says it writes — so the whole project
    /// tree is compared before and after, and exactly two files may differ.
    ///
    /// **Both calls name a source item, deliberately.** The `source_item_id` arm is
    /// the only one that reads the research manifest, and it is the one a later
    /// author is likeliest to extend into a *write* — stamping the item with where
    /// it went. Exercised with scraps only, this test would leave that branch
    /// outside the very comparison written to catch it.
    func test_itNeverTouchesAManuscriptOrAResearchFile() async throws {
        let (url, store, registry, id) = try await registeredProject()
        let page = try await store.addResearchTextNote(parentId: nil, title: "Page 4")
        // The first call creates the canvas files, so the snapshot below is taken
        // over a tree that already holds every file this tool is allowed to touch —
        // and, because the research note is made first, over the note and the
        // manifest it must not touch.
        _ = try await add(registry, id, scraps: ["a first pass"], sourceItemID: page.id)
        let before = try fileTree(at: url)
        XCTAssertTrue(before.keys.contains { $0.hasPrefix("research/") },
                      "precondition: the research note is in the snapshot, or the "
                      + "research tree is not actually under this guard")

        _ = try await add(registry, id, scraps: ["and a second"], sourceItemID: page.id)

        let after = try fileTree(at: url)
        let changed = Set(after.keys).symmetricDifference(before.keys)
            .union(before.keys.filter { after[$0] != before[$0] })
        XCTAssertEqual(changed, [CanvasStore.scrapsRelativePath,
                                 CanvasStore.sidecarRelativePath],
                       "add_canvas_scraps writes canvas.md and canvas.json and "
                       + "nothing else. A manuscript, a research note or a manifest "
                       + "in this set is the membrane breached (MCP tripwire 6): "
                       + "Claude does not originate manuscript text, and the canvas "
                       + "reaches it only through promotion, which is a writer act.")
        XCTAssertFalse(changed.isEmpty,
                       "precondition: the second call wrote something, or this test "
                       + "passes by writing nothing at all")
    }

    // MARK: - add_canvas_scraps: refusals

    /// The likeliest wrong id is an **inbox entry** id: a capture is not a research
    /// item until it is promoted, and this tool takes a research item id (§8A.4
    /// records why the asymmetry with the writer's own route exists).
    ///
    /// **A refusal that does not teach is a recorded failure here.** The message
    /// must name `promote_inbox_entry` — and must not simply order a promotion, the
    /// way "Promote both cards first" once told a writer who had already promoted
    /// one card to do the thing they had just done.
    func test_itRefusesAnInboxEntryIdAndSaysWhatToDo() async throws {
        let (url, _, registry, id) = try await registeredProject()

        do {
            _ = try await add(registry, id, scraps: ["off a photographed page"],
                              sourceItemID: "inbox-entry-01J9")
            XCTFail("expected a refusal for an id that is not a research item")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "research_item_not_found")
            XCTAssertTrue(payload.message.contains("inbox-entry-01J9"),
                          "the refusal must quote the id it could not find; got: "
                          + payload.message)
            let hint = try XCTUnwrap(payload.hint)
            XCTAssertTrue(hint.contains("promote_inbox_entry"),
                          "the refusal has to name the tool that fixes it — the "
                          + "likeliest cause is an inbox entry id, and a capture is "
                          + "not a research item until it is promoted. got: \(hint)")
            XCTAssertTrue(hint.contains("list_research"),
                          "…and the way to find the right id, for the caller whose "
                          + "id was never an inbox entry at all. got: \(hint)")
        }
        assertNothingWasWritten(at: url)
    }

    /// A research **group** is found by the tree walk but is not a page: an item
    /// node standing for a folder has no title, no glyph and no thumbnail to draw,
    /// and no other surface can create one. The refusal has to say *group*, because
    /// "not found" is a claim the caller can disprove with `list_research` and would
    /// send them hunting for a typo that is not there.
    func test_itRefusesAResearchGroupAsTheSource() async throws {
        let (url, store, registry, id) = try await registeredProject()
        // Built into the manifest directly: `addResearchItem` needs a
        // `DocumentStore` these fixtures do not wire, and what is under test is the
        // tool's reading of the tree rather than how the folder got there.
        store.manifest.research.append(ResearchItem(
            id: "res-grp-notebooks", title: "Notebooks", type: .group, kind: nil,
            path: "research/notebooks", url: nil, caption: nil, tags: nil,
            links: nil, addedAt: Date(), children: []))

        do {
            _ = try await add(registry, id, scraps: ["a line off page four"],
                              sourceItemID: "res-grp-notebooks")
            XCTFail("expected a refusal: a folder is not a page")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "research_item_is_a_group")
            XCTAssertTrue(payload.message.contains("Notebooks"),
                          "the refusal must name the group, so the caller can see it "
                          + "picked the folder rather than what is in it; got: "
                          + payload.message)
            let hint = try XCTUnwrap(payload.hint)
            XCTAssertTrue(hint.contains("list_research"),
                          "the refusal has to name the way to the right id; got: \(hint)")
        }
        assertNothingWasWritten(at: url)
    }

    /// A blank card is indistinguishable from a rendering fault, and an empty batch
    /// leaves an empty labelled region on the writer's canvas.
    func test_itRefusesAnEmptyOrBlankScrap() async throws {
        let empty = try await registeredProject("Empty")
        do {
            _ = try await add(empty.registry, empty.id, scraps: [])
            XCTFail("expected a refusal for a batch with no scraps in it")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "no_scraps")
        }
        assertNothingWasWritten(at: empty.url)

        let blank = try await registeredProject("Blank")
        do {
            _ = try await add(blank.registry, blank.id, scraps: ["a real thought", "   "])
            XCTFail("expected a refusal for a whitespace-only scrap")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "blank_scrap")
            // `contains("1")` would be satisfied by "scraps[10]" or "1 scrap" — the
            // whole of the requirement is that the refusal names the POSITION.
            XCTAssertTrue(payload.message.contains("scraps[1]"),
                          "the refusal must say WHICH scrap; got: " + payload.message)
        }
        assertNothingWasWritten(at: blank.url,
                                "the valid first scrap must not survive the refusal")
    }

    /// **Fail rather than drop.** `CanvasScene.insertLine` silently refuses a
    /// self-line at the model boundary, which is right for the model and wrong for
    /// a tool: a silently-dropped line is a caller believing something exists that
    /// does not.
    func test_itRefusesASelfConnection() async throws {
        let (url, _, registry, id) = try await registeredProject()

        do {
            _ = try await add(registry, id, scraps: ["one", "two"], connect: [[1, 1]])
            XCTFail("expected a refusal, not a line quietly dropped by the model")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "invalid_connection")
            let hint = try XCTUnwrap(payload.hint)
            XCTAssertTrue(hint.contains("two different"),
                          "the refusal has to say what a connection is; got: \(hint)")
        }
        assertNothingWasWritten(at: url)
    }

    /// An out-of-range index is the caller reaching for a card that does not exist
    /// — most likely a node id it read from `list_canvas`, which `connect` cannot
    /// express and must not appear to.
    func test_itRefusesAConnectionToNowhere() async throws {
        let (url, _, registry, id) = try await registeredProject()

        do {
            _ = try await add(registry, id, scraps: ["one", "two"], connect: [[0, 5]])
            XCTFail("expected a refusal for an index past the end of this call's scraps")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "invalid_connection")
            let hint = try XCTUnwrap(payload.hint)
            XCTAssertTrue(hint.contains("scraps"),
                          "the refusal must say what connect indexes, because the "
                          + "wrong answer is a node id; got: \(hint)")
        }
        assertNothingWasWritten(at: url)
    }

    func test_itRefusesAConnectionThatIsNotAPair() async throws {
        let (url, _, registry, id) = try await registeredProject()

        do {
            _ = try await add(registry, id, scraps: ["one", "two", "three"],
                              connect: [[0, 1, 2]])
            XCTFail("expected a refusal: a line runs between exactly two cards")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "invalid_connection")
        }
        assertNothingWasWritten(at: url)
    }

    /// **The ruling on duplicate and reversed pairs: refuse.** A canvas line is
    /// untyped and asserts nothing (spec §5), so `[0, 1]` and `[1, 0]` are the same
    /// relationship — drawn twice they are coincident and read as one line. Deduping
    /// would leave the caller believing it made two connections when it made one,
    /// which is the same failure as a silently-dropped self-line, so the same answer
    /// applies: fail, and say why.
    func test_itRefusesTheSameConnectionTwice() async throws {
        let reversed = try await registeredProject("Reversed")
        do {
            _ = try await add(reversed.registry, reversed.id,
                              scraps: ["one", "two"], connect: [[0, 1], [1, 0]])
            XCTFail("expected a refusal: a line has no direction, so these are one line")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "invalid_connection")
            let hint = try XCTUnwrap(payload.hint)
            XCTAssertTrue(hint.contains("same line"),
                          "the refusal has to explain that a line is undirected, or "
                          + "the caller cannot see what it did wrong; got: \(hint)")
        }
        assertNothingWasWritten(at: reversed.url)

        let repeated = try await registeredProject("Repeated")
        do {
            _ = try await add(repeated.registry, repeated.id,
                              scraps: ["one", "two"], connect: [[0, 1], [0, 1]])
            XCTFail("expected a refusal: two coincident lines are indistinguishable "
                    + "from one")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "invalid_connection")
        }
        assertNothingWasWritten(at: repeated.url)
    }
}
