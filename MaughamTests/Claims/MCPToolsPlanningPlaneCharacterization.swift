import XCTest
import MaughamCore
@testable import Maugham

/// MCP/Tools characterisation — register module MCPTools
/// (register/reconciliation/MCPTools.{claims,filings}.json). PERMANENT pinned
/// suite: a red test here means a pinned MCP tool-failure behaviour changed.

/// **Characterisation of the planning-plane MCP tools' FAILURE tail** — the
/// spine readers (`read_craft_intent`, `read_visual_language`), the canvas pair
/// (`list_canvas`, `add_canvas_scraps`), the palette pair, the inbox trio, the
/// translation trio, `get_help` and `list_maugham_tools`.
///
/// Every assertion here was written from printed output of a probe run, not from
/// reading the handlers. Nothing in this file asserts what the code *should* do:
/// a red test means the pinned behaviour moved, and the register moves with it.
///
/// The organising question is RULING-54's: **is an unreadable-yet-present file
/// presented to Claude as an error, or silently as empty?** The family answers
/// it four different ways, and the four are pinned separately below.
@MainActor
final class MCPToolsPlanningPlaneCharacterization: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    // MARK: - Fixtures

    private struct Fixture {
        let url: URL
        let store: ProjectStore
        let ds: DocumentStore
        let reg: ProjectRegistry
        let id: String
    }

    private func makeProject(_ name: String = "PlanProbe") async throws -> Fixture {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return Fixture(url: url, store: store, ds: ds, reg: reg,
                       id: ProjectIdentifier.id(for: url))
    }

    /// Make a path unreadable-yet-present the way the register's existing
    /// unreadable probes do (`InboxCharacterization`): a directory squats on the
    /// file's path — the same failure shape as a permissions break or an iCloud
    /// stub, and one `tearDown` can still remove.
    private func makeUnreadable(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// The payload Claude actually sees for a thrown error.
    private func payload(_ error: Error) -> MCPError.ToolErrorPayload {
        MCPToolsCallHandler.toolErrorPayload(for: error)
    }

    private func tree(of url: URL) -> [String] {
        let e = FileManager.default.enumerator(atPath: url.path)
        var out: [String] = []
        while let n = e?.nextObject() as? String { out.append(n) }
        return out.sorted()
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The spine readers over an unreadable statement (RULING-54)

    /// **The headline.** `ProjectStore.statementText(of:)` throws for an
    /// unreadable-yet-present statement log, and both spine readers let that
    /// throw out rather than answering `exists: false` — the forbidden shape
    /// (an unreadable statement presented as an undeclared one) does NOT occur.
    ///
    /// What Claude sees is the fall-through, though: `internal_error` carrying
    /// the *raw Swift enum description* of `OpLogStore.ReadError.unreadableFile`.
    /// The real cause survives — the filename and "couldn't be opened" are both
    /// in the message — but the refusal is unnamed, has no hint, and the
    /// `LocalizedError` prose that `ReadError` defines for exactly this case
    /// ("Your words are intact inside it…") is discarded, because
    /// `toolErrorPayload`'s default arm interpolates `"\(error)"` rather than
    /// `error.localizedDescription`.
    func test_anUnreadableStatementRefusesRatherThanReadingAsAbsent() async throws {
        for kind in [Statement.Kind.intent, Statement.Kind.visualLanguage] {
            let f = try await makeProject("Stmt-\(kind.rawValue)")
            let statement = try await f.store.createStatement(kind: kind, scope: .project)
            try await write("The harbour smells of diesel.", into: statement, at: f.url)

            let logs = OpLogStore.opLogFileURLs(forDocId: statement.id, in: f.url)
            XCTAssertEqual(logs.count, 1, "fixture: the statement has exactly one op log")
            let logName = logs[0].lastPathComponent
            for u in logs { try makeUnreadable(u) }

            let params = Data(#"{"project_id":"\#(f.id)"}"#.utf8)
            do {
                let data = kind == .intent
                    ? try await ReadCraftIntentTool.handle(paramsJSON: params, registry: f.reg)
                    : try await ReadVisualLanguageTool.handle(paramsJSON: params, registry: f.reg)
                XCTFail("an unreadable statement was presented as a readable answer: "
                        + (String(data: data, encoding: .utf8) ?? ""))
            } catch {
                let p = payload(error)
                XCTAssertEqual(p.error, "internal_error",
                               "the refusal is the fall-through, not a named cause")
                XCTAssertTrue(p.message.hasPrefix("unreadableFile(name: \"\(logName)\""),
                              "the message is the raw Swift enum description, got: \(p.message)")
                XCTAssertTrue(p.message.contains("couldn’t be opened"),
                              "the real cause survives into the message")
                XCTAssertNil(p.hint, "the fall-through carries no hint")
                XCTAssertTrue(p.fields.isEmpty)
                XCTAssertFalse(p.message.contains("Your words are intact"),
                               "ReadError's LocalizedError prose is discarded by the "
                               + "fall-through's \"\\(error)\" interpolation")
            }
            await f.ds.close()
        }
    }

    /// A read that SUCCEEDED before the log became unreadable does not go on
    /// answering from the warm `DerivedManuscriptCache`: the cache token is
    /// (mtime, size) per op-log file, so the file changing shape invalidates it
    /// and the second call refuses like the first.
    func test_aWarmDerivedCacheDoesNotServeStaleTextOverAnUnreadableLog() async throws {
        let f = try await makeProject("StmtWarm")
        let statement = try await f.store.createStatement(kind: .intent, scope: .project)
        try await write("Warm words.", into: statement, at: f.url)
        let params = Data(#"{"project_id":"\#(f.id)"}"#.utf8)

        let first = try JSONDecoder().decode(
            ReadCraftIntentTool.Result.self,
            from: try await ReadCraftIntentTool.handle(paramsJSON: params, registry: f.reg))
        XCTAssertEqual(first.markdown, "Warm words.", "fixture: the first read is warm")

        for u in OpLogStore.opLogFileURLs(forDocId: statement.id, in: f.url) {
            try makeUnreadable(u)
        }
        do {
            _ = try await ReadCraftIntentTool.handle(paramsJSON: params, registry: f.reg)
            XCTFail("the warm cache served text over an unreadable log")
        } catch {
            XCTAssertEqual(payload(error).error, "internal_error")
        }
        await f.ds.close()
    }

    /// The control beside the unreadable case: a statement the writer declared
    /// but never typed into has NO op log at all, and that reads as
    /// **`exists: true` with empty markdown** — present-and-empty, which is a
    /// different answer from `exists: false` (undeclared) and from the refusal
    /// above.
    func test_aDeclaredButEmptyStatementReadsAsPresentWithEmptyText() async throws {
        let f = try await makeProject("StmtEmpty")
        let statement = try await f.store.createStatement(kind: .intent, scope: .project)
        XCTAssertTrue(OpLogStore.opLogFileURLs(forDocId: statement.id, in: f.url).isEmpty,
                      "fixture: nothing was ever typed, so there is no op log")

        let result = try JSONDecoder().decode(
            ReadCraftIntentTool.Result.self,
            from: try await ReadCraftIntentTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(f.id)"}"#.utf8), registry: f.reg))
        XCTAssertTrue(result.exists)
        XCTAssertEqual(result.markdown, "")
        XCTAssertEqual(result.path, "intent.md")
        await f.ds.close()
    }

    // MARK: - add_canvas_scraps: named refusals, and nothing written (RULING-52)

    /// Every one of the six refusal shapes names its own cause with a machine
    /// code of its own — and every one leaves the project tree byte-identical:
    /// validation completes before `CanvasClaudeWrite.apply` is reached, so
    /// neither `canvas.md` nor `.maugham/canvas.json` is created.
    func test_everyAddCanvasScrapsRefusalIsNamedAndWritesNothing() async throws {
        let f = try await makeProject("CanvasRefuse")
        let group = try await f.store.addResearchItem(
            parentId: nil, title: "Folder", kind: nil)

        let cases: [(label: String, params: String, code: String, message: String)] = [
            ("empty", #"{"project_id":"\#(f.id)","scraps":[]}"#,
             "no_scraps", "add_canvas_scraps was called with no scraps."),
            ("blank", #"{"project_id":"\#(f.id)","scraps":["ok","   "]}"#,
             "blank_scrap", "scraps[1] is empty or only whitespace."),
            ("unknown source",
             #"{"project_id":"\#(f.id)","scraps":["a"],"source_item_id":"res-nope"}"#,
             "research_item_not_found", "'res-nope' is not a research item in this project."),
            ("group source",
             #"{"project_id":"\#(f.id)","scraps":["a"],"source_item_id":"\#(group.id)"}"#,
             "research_item_is_a_group",
             "'\(group.id)' names the research group 'Folder', not an item in it."),
            ("pair arity", #"{"project_id":"\#(f.id)","scraps":["a","b"],"connect":[[0]]}"#,
             "invalid_connection", "connect[0] has 1 entry."),
            ("pair out of range",
             #"{"project_id":"\#(f.id)","scraps":["a","b"],"connect":[[0,5]]}"#,
             "invalid_connection",
             "connect[0] names position 5, and this call has 2 scraps."),
            ("pair to itself",
             #"{"project_id":"\#(f.id)","scraps":["a","b"],"connect":[[1,1]]}"#,
             "invalid_connection", "connect[0] joins position 1 to itself."),
            ("pair reversed and repeated",
             #"{"project_id":"\#(f.id)","scraps":["a","b"],"connect":[[0,1],[1,0]]}"#,
             "invalid_connection",
             "connect[1] repeats the connection between positions 1 and 0."),
        ]

        for c in cases {
            let before = tree(of: f.url)
            do {
                _ = try await AddCanvasScrapsTool.handle(
                    paramsJSON: Data(c.params.utf8), registry: f.reg)
                XCTFail("\(c.label): expected a refusal")
            } catch {
                let p = payload(error)
                XCTAssertEqual(p.error, c.code, "\(c.label): machine code")
                XCTAssertEqual(p.message, c.message, "\(c.label): message")
                XCTAssertNotNil(p.hint, "\(c.label): every canvas refusal teaches")
            }
            XCTAssertEqual(tree(of: f.url), before,
                           "\(c.label): a refused call wrote into the project")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: f.url.appendingPathComponent(CanvasStore.scrapsRelativePath).path),
            "no refusal minted canvas.md")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: f.url.appendingPathComponent(CanvasStore.sidecarRelativePath).path),
            "no refusal minted the sidecar")
        await f.ds.close()
    }

    /// The two refusals that carry an index carry it as a typed field, not only
    /// in the prose — so a caller can act on it without parsing English.
    func test_theIndexedCanvasRefusalsCarryTheirIndexAsAField() async throws {
        let f = try await makeProject("CanvasFields")
        do {
            _ = try await AddCanvasScrapsTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(f.id)","scraps":["ok","  "]}"#.utf8),
                registry: f.reg)
            XCTFail("expected blank_scrap")
        } catch {
            XCTAssertEqual(payload(error).fields["index"], .int(1))
        }
        do {
            _ = try await AddCanvasScrapsTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(f.id)","scraps":["a"],"source_item_id":"res-nope"}"#.utf8),
                registry: f.reg)
            XCTFail("expected research_item_not_found")
        } catch {
            XCTAssertEqual(payload(error).fields["source_item_id"], .string("res-nope"))
        }
        await f.ds.close()
    }

    // MARK: - list_canvas over an unreadable sidecar (RULING-54, one surface over)

    /// **An arrangement this build cannot read is reported to Claude as an
    /// EMPTY canvas**, with nothing in the payload saying so.
    ///
    /// `CanvasStore.load()` computes the distinction — `SidecarState.refused`
    /// exists precisely so a reader can tell "there was nothing here" from
    /// "there is something here I cannot read" — and `CanvasClaudeWrite.readScene`
    /// drops it on the floor: it returns `(scene, scraps, fromOpenCanvas)` and no
    /// state, so `list_canvas` has nothing to report even if it wanted to. The
    /// scrap TEXT is still in `canvas.md` and still readable, but with no nodes
    /// on the wire the words are unreachable too.
    func test_anUnreadableCanvasSidecarIsReportedAsAnEmptyCanvas() async throws {
        for (label, corrupt) in [("undecodable bytes", true), ("unreadable file", false)] {
            let f = try await makeProject("CanvasCorrupt-\(corrupt)")
            var scene = CanvasScene()
            scene.insert(CanvasNode(id: CanvasNodeID("n1"), kind: .scrap,
                                    origin: CGPoint(x: 10, y: 20), width: 220,
                                    cachedHeight: 60))
            CanvasStore(projectRoot: f.url)
                .save(scene: scene, scraps: [CanvasNodeID("n1"): "The writer's card."])
            let sidecar = f.url.appendingPathComponent(CanvasStore.sidecarRelativePath)

            if corrupt {
                try Data("{ this is not canvas json".utf8).write(to: sidecar)
            } else {
                try makeUnreadable(sidecar)
            }
            XCTAssertEqual(CanvasStore(projectRoot: f.url).load().sidecar,
                           corrupt ? .refused : .absent,
                           "\(label): precondition — what the store itself concluded")

            let data = try await ListCanvasTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(f.id)"}"#.utf8), registry: f.reg)
            let result = try JSONDecoder().decode(ListCanvasTool.Result.self, from: data)
            XCTAssertEqual(result.read_from, "sidecar")
            XCTAssertTrue(result.nodes.isEmpty,
                          "\(label): the writer's card is gone from the answer")
            XCTAssertTrue(result.regions.isEmpty)
            XCTAssertTrue(result.lines.isEmpty)
            XCTAssertEqual(
                Set(try json(data).keys),
                ["read_from", "includes_text", "nodes", "regions", "lines", "piece_references"],
                "\(label): no field carries the fact that the sidecar was refused")
            XCTAssertTrue(
                (try? String(contentsOf: f.url
                    .appendingPathComponent(CanvasStore.scrapsRelativePath), encoding: .utf8))?
                    .contains("The writer's card.") ?? false,
                "\(label): the words are still on disk — only unreachable through the tool")
            await f.ds.close()
        }
    }

    /// **And a WRITE stamps over it.** `add_canvas_scraps` on a project whose
    /// sidecar is `.refused` loads the empty fallback scene, adds Claude's cards
    /// to it, and saves — replacing the writer's arrangement with a sidecar that
    /// holds Claude's card alone. `SidecarState.acceptsARepairWrite` is the rule
    /// that forbids exactly this, and nothing on the MCP write path consults it.
    /// The scrap TEXT survives in `canvas.md` as an orphan with no node.
    func test_addCanvasScrapsStampsOverAnUnreadableSidecar() async throws {
        let f = try await makeProject("CanvasStamp")
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: CanvasNodeID("n1"), kind: .scrap,
                                origin: CGPoint(x: 10, y: 20), width: 220,
                                cachedHeight: 60))
        CanvasStore(projectRoot: f.url)
            .save(scene: scene, scraps: [CanvasNodeID("n1"): "The writer's card."])
        let sidecar = f.url.appendingPathComponent(CanvasStore.sidecarRelativePath)
        let corrupt = "{ not canvas json"
        try Data(corrupt.utf8).write(to: sidecar)

        _ = try await AddCanvasScrapsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(f.id)","scraps":["Claude's card"]}"#.utf8),
            registry: f.reg)

        let after = CanvasStore(projectRoot: f.url).load()
        XCTAssertEqual(after.sidecar, .decoded, "the refused bytes were replaced")
        XCTAssertEqual(after.scene.unorderedNodes.count, 1,
                       "only Claude's card is left in the arrangement")
        XCTAssertFalse(after.scene.unorderedNodes.contains { $0.id == CanvasNodeID("n1") },
                       "the writer's node is gone from the sidecar")
        XCTAssertEqual(after.scraps[CanvasNodeID("n1")], "The writer's card.",
                       "its words survive in canvas.md as an orphan with no node")
        await f.ds.close()
    }

    /// The control: with no sidecar at all there is nothing to lose, and the
    /// same call is an ordinary success that mints one.
    func test_addCanvasScrapsOverAnAbsentSidecarSimplyMintsOne() async throws {
        let f = try await makeProject("CanvasAbsent")
        let result = try JSONDecoder().decode(
            AddCanvasScrapsTool.Result.self,
            from: try await AddCanvasScrapsTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(f.id)","scraps":["Only card"]}"#.utf8),
                registry: f.reg))
        XCTAssertEqual(result.node_ids.count, 1)
        XCTAssertEqual(CanvasStore(projectRoot: f.url).load().sidecar, .decoded)
        await f.ds.close()
    }

    // MARK: - The inbox tools over an unreadable device manifest

    /// **M8-IN-012's TOOL half, and it is not what the pane does.**
    /// `InboxStore.refresh` records the unreadable manifest (RULING-7, so the
    /// pane can say a device's captures cannot be read) — and `list_inbox`
    /// returns the readable subset with **no notice of any kind**: its response
    /// has one key, `entries`, and the record the store just made is not on the
    /// wire. Claude cannot distinguish "that device has no captures" from "that
    /// device's captures could not be read".
    func test_listInboxPresentsTheReadableSubsetWithNoNoticeOfTheUnreadableOne() async throws {
        let f = try await makeProject("InboxProbe")
        let dir = f.url.appendingPathComponent(".maugham/inbox")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await JSONLAppendStore<InboxEntry>(fileURL: dir.appendingPathComponent("inbox.aaa.jsonl"))
            .append(InboxEntry(id: "keep", createdAt: Date(timeIntervalSince1970: 100),
                               deviceId: "mac", kind: .text, inlineText: "Readable."))
        try await JSONLAppendStore<InboxEntry>(fileURL: dir.appendingPathComponent("inbox.bbb.jsonl"))
            .append(InboxEntry(id: "lost", createdAt: Date(timeIntervalSince1970: 200),
                               deviceId: "phone", kind: .text, inlineText: "Hidden."))

        let params = Data(#"{"project_id":"\#(f.id)"}"#.utf8)
        let before = try JSONDecoder().decode(
            ListInboxTool.Result.self,
            from: try await ListInboxTool.handle(paramsJSON: params, registry: f.reg))
        XCTAssertEqual(Set(before.entries.map(\.id)), ["keep", "lost"], "fixture: both visible")

        try makeUnreadable(dir.appendingPathComponent("inbox.bbb.jsonl"))

        let data = try await ListInboxTool.handle(paramsJSON: params, registry: f.reg)
        let after = try JSONDecoder().decode(ListInboxTool.Result.self, from: data)
        XCTAssertEqual(after.entries.map(\.id), ["keep"],
                       "the unreadable device's capture is simply absent")
        XCTAssertEqual(Set(try json(data).keys), ["entries"],
                       "no field on the response says a manifest could not be read")
        XCTAssertEqual(f.store.documentStore?.inboxStore.unreadableManifests,
                       ["inbox.bbb.jsonl"],
                       "the STORE recorded it (M8-IN-012 / RULING-7) — the tool did not carry it")
        await f.ds.close()
    }

    /// And the per-entry tools report the same capture as **not found or
    /// already resolved** — word for word the answer an id that never existed
    /// gets. A capture intact on disk is described to Claude as gone.
    func test_anEntryInAnUnreadableManifestIsReportedAsNotFound() async throws {
        let f = try await makeProject("InboxLost")
        let dir = f.url.appendingPathComponent(".maugham/inbox")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await JSONLAppendStore<InboxEntry>(fileURL: dir.appendingPathComponent("inbox.bbb.jsonl"))
            .append(InboxEntry(id: "lost", createdAt: Date(timeIntervalSince1970: 200),
                               deviceId: "phone", kind: .text, inlineText: "Hidden."))
        try makeUnreadable(dir.appendingPathComponent("inbox.bbb.jsonl"))

        for (label, call) in [
            ("read_inbox_entry", { try await ReadInboxEntryTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(f.id)","entry_id":"lost"}"#.utf8),
                registry: f.reg) }),
            ("promote_inbox_entry", { try await PromoteInboxEntryTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(f.id)","entry_id":"lost"}"#.utf8),
                registry: f.reg) }),
        ] as [(String, () async throws -> Data)] {
            do {
                _ = try await call()
                XCTFail("\(label): expected a refusal")
            } catch {
                let p = payload(error)
                XCTAssertEqual(p.error, "invalid_argument", label)
                XCTAssertEqual(p.message,
                               "inbox entry not found or already resolved: lost", label)
                XCTAssertNil(p.hint, "\(label): no hint")
            }
        }

        // Word for word what a never-existing id gets.
        do {
            _ = try await ReadInboxEntryTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(f.id)","entry_id":"never-existed"}"#.utf8),
                registry: f.reg)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(payload(error).message,
                           "inbox entry not found or already resolved: never-existed")
        }
        await f.ds.close()
    }

    /// A project with no live `DocumentStore` has no inbox to resolve, and the
    /// inbox trio says so in its own words — distinct from `unknown_project_id`,
    /// though it shares the generic `invalid_argument` code.
    func test_theInboxToolsNameAnUnavailableInboxSeparatelyFromAnUnknownProject() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "NoDS", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let id = ProjectIdentifier.id(for: url)
        do {
            _ = try await ListInboxTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(id)"}"#.utf8), registry: reg)
            XCTFail("expected a refusal")
        } catch {
            let p = payload(error)
            XCTAssertEqual(p.error, "invalid_argument")
            XCTAssertEqual(p.message, "inbox unavailable for project: \(id)")
        }
    }

    // MARK: - The palette tools over an unreadable card

    /// **An unreadable palette card is presented as an unknown id.** The card's
    /// markdown is what `loadPaletteCards()` parses, so a card whose file cannot
    /// be read simply drops out of the parsed set — it vanishes from
    /// `list_palette_cards` while the manifest still holds it, and
    /// `read_palette_card` on its perfectly valid id answers *"unknown card_id …
    /// — call list_palette_cards for valid ids"*, which sends the caller to a
    /// listing that has just as certainly lost it.
    func test_anUnreadablePaletteCardIsPresentedAsAnUnknownId() async throws {
        let f = try await makeProject("PaletteUnreadable")
        let a = try await f.store.addPaletteCard(title: "The Flat", kind: .location)
        let b = try await f.store.addPaletteCard(title: "Marlowe", kind: .character)
        let listParams = Data(#"{"project_id":"\#(f.id)"}"#.utf8)

        let before = try JSONDecoder().decode(
            ListPaletteCardsTool.Result.self,
            from: try await ListPaletteCardsTool.handle(paramsJSON: listParams, registry: f.reg))
        XCTAssertEqual(Set(before.cards.map(\.id)), [a.id, b.id], "fixture: both cards list")

        try makeUnreadable(f.url.appendingPathComponent(try XCTUnwrap(a.path)))

        let after = try JSONDecoder().decode(
            ListPaletteCardsTool.Result.self,
            from: try await ListPaletteCardsTool.handle(paramsJSON: listParams, registry: f.reg))
        XCTAssertEqual(after.cards.map(\.id), [b.id],
                       "the unreadable card left the listing with no notice")
        XCTAssertEqual(Set(f.store.paletteCardItems().map(\.id)), [a.id, b.id],
                       "while the manifest still holds it — so this is a READ loss, not a delete")

        do {
            _ = try await ReadPaletteCardTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(f.id)","card_id":"\#(a.id)"}"#.utf8),
                registry: f.reg)
            XCTFail("expected a refusal")
        } catch {
            let p = payload(error)
            XCTAssertEqual(p.error, "invalid_argument")
            XCTAssertEqual(p.message,
                           "unknown card_id \(a.id) — call list_palette_cards for valid ids")
        }
        await f.ds.close()
    }

    /// A card id that never existed gets the same sentence — the refusal names
    /// the id and points at the listing, and has no hint field.
    func test_readPaletteCardNamesAnUnknownIdAndPointsAtTheListing() async throws {
        let f = try await makeProject("PaletteUnknown")
        do {
            _ = try await ReadPaletteCardTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(f.id)","card_id":"res-nope"}"#.utf8),
                registry: f.reg)
            XCTFail("expected a refusal")
        } catch {
            let p = payload(error)
            XCTAssertEqual(p.error, "invalid_argument")
            XCTAssertEqual(p.message,
                           "unknown card_id res-nope — call list_palette_cards for valid ids")
            XCTAssertNil(p.hint)
        }
        await f.ds.close()
    }

    // MARK: - write_translation: all-or-nothing, and the offending id is named

    /// One `text` entry naming an unknown paragraph rejects the whole batch —
    /// its `delete` siblings included — the refusal names the offending id, and
    /// **nothing at all is written**: no translation file for the language, no
    /// `.maugham/translations` directory.
    func test_writeTranslationRejectsTheWholeBatchByNameAndWritesNothing() async throws {
        let h = try await makeTranslationHarness()
        let ids = h.doc.sequence
        XCTAssertEqual(ids.count, 2, "fixture")

        let batch: [String: Any] = [
            "project_id": h.id, "document_id": "doc-tr-probe", "language": "es",
            "entries": [
                ["paragraph_id": ids[0], "delete": true],
                ["paragraph_id": "zzzz", "text": "Un párrafo."],
            ]
        ]
        do {
            _ = try await WriteTranslationTool.handle(
                paramsJSON: try JSONSerialization.data(withJSONObject: batch), registry: h.reg)
            XCTFail("expected a refusal")
        } catch {
            let p = payload(error)
            XCTAssertEqual(p.error, "invalid_argument")
            XCTAssertEqual(p.message, "unknown paragraph ids: zzzz",
                           "the refusal names the offending id")
            XCTAssertNil(p.hint)
        }
        XCTAssertTrue(TranslationStore.languages(forDocId: "doc-tr-probe", in: h.url).isEmpty,
                      "a rejected batch minted no language")
        XCTAssertTrue(tree(of: h.url).filter { $0.contains("translation") }.isEmpty,
                      "a rejected batch left no translation file behind")
        await h.ds.close()
    }

    /// The rest of `write_translation`'s validation tail, each refusal honest
    /// about its cause under the generic `invalid_argument` code.
    func test_theOtherWriteTranslationRefusalsNameTheirCause() async throws {
        let h = try await makeTranslationHarness()
        let ids = h.doc.sequence
        let cases: [(String, [String: Any], String)] = [
            ("bad language tag",
             ["project_id": h.id, "document_id": "doc-tr-probe",
              "language": "Español!", "entries": []],
             "invalid language tag: Español!"),
            ("two forms at once",
             ["project_id": h.id, "document_id": "doc-tr-probe", "language": "es",
              "entries": [["paragraph_id": ids[0], "text": "x", "verbatim": true]]],
             "entry for paragraph \(ids[0]) must supply exactly one of `text`, "
             + "`verbatim: true` or `delete: true`"),
            ("no form at all",
             ["project_id": h.id, "document_id": "doc-tr-probe", "language": "es",
              "entries": [["paragraph_id": ids[0]]]],
             "entry for paragraph \(ids[0]) must supply exactly one of `text`, "
             + "`verbatim: true` or `delete: true`"),
            ("duplicate ids in one batch",
             ["project_id": h.id, "document_id": "doc-tr-probe", "language": "es",
              "entries": [["paragraph_id": ids[0], "text": "a"],
                          ["paragraph_id": ids[0], "text": "b"]]],
             "duplicate paragraph ids in batch: \(ids[0])"),
            ("unknown document",
             ["project_id": h.id, "document_id": "doc-nope", "language": "es",
              "entries": [["paragraph_id": ids[0], "text": "a"]]],
             "document_id not found in project manifest: doc-nope"),
        ]
        for (label, obj, message) in cases {
            do {
                _ = try await WriteTranslationTool.handle(
                    paramsJSON: try JSONSerialization.data(withJSONObject: obj), registry: h.reg)
                XCTFail("\(label): expected a refusal")
            } catch {
                let p = payload(error)
                XCTAssertEqual(p.error, "invalid_argument", label)
                XCTAssertEqual(p.message, message, label)
            }
        }
        await h.ds.close()
    }

    /// `read_translation`'s two ids behave differently on purpose: an unknown
    /// LANGUAGE is not an error (every paragraph reads `missing`, as the tool's
    /// own description promises), while an unknown DOCUMENT refuses by name.
    func test_readTranslationAcceptsAnUnknownLanguageAndRefusesAnUnknownDocument() async throws {
        let h = try await makeTranslationHarness()
        let result = try JSONDecoder().decode(
            ReadTranslationTool.Result.self,
            from: try await ReadTranslationTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(h.id)","document_id":"doc-tr-probe","language":"zz"}"#.utf8),
                registry: h.reg))
        XCTAssertEqual(result.language, "zz")
        XCTAssertEqual(result.entries.map(\.status), ["missing", "missing"])
        XCTAssertEqual(result.orphan_count, 0)

        do {
            _ = try await ReadTranslationTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(h.id)","document_id":"doc-nope","language":"es"}"#.utf8),
                registry: h.reg)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(payload(error).message,
                           "document_id not found in project manifest: doc-nope")
        }
        do {
            _ = try await ReadTranslationTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(h.id)","document_id":"doc-tr-probe","language":"es","status":"bogus"}"#.utf8),
                registry: h.reg)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(payload(error).message,
                           "invalid status filter: bogus (expected fresh, stale, or missing)")
        }
        await h.ds.close()
    }

    /// A translation read over an unreadable op log takes the same
    /// `internal_error` fall-through the statement readers take — RULING-54
    /// holds (nothing derives short), and the writer-facing shape is the same
    /// raw enum dump.
    func test_theTranslationReadersRefuseOverAnUnreadableOpLogWithTheSameFallThrough() async throws {
        let f = try await makeProject("TransUnreadable")
        let chapter = try XCTUnwrap(
            TreeWalk.collect(in: f.store.manifest.structure,
                             where: { $0.type == .document }).first)
        try await write("A paragraph the writer wrote.",
                        toPath: try XCTUnwrap(chapter.path), at: f.url)
        for u in OpLogStore.opLogFileURLs(forDocId: chapter.id, in: f.url) {
            try makeUnreadable(u)
        }
        do {
            _ = try await ReadTranslationTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(f.id)","document_id":"\#(chapter.id)","language":"es"}"#.utf8),
                registry: f.reg)
            XCTFail("expected a refusal")
        } catch {
            let p = payload(error)
            XCTAssertEqual(p.error, "internal_error")
            XCTAssertTrue(p.message.hasPrefix("unreadableFile(name: \"\(chapter.id)."),
                          "got: \(p.message)")
        }
        await f.ds.close()
    }

    /// And in the PROJECT-WIDE walk, one unreadable document's log fails the
    /// whole report rather than reporting the documents it could read: the
    /// refusal names the file, and `rows` for every other document never
    /// arrives.
    func test_projectWideTranslationStatusFailsWholeOnOneUnreadableDocument() async throws {
        let f = try await makeProject("StatusUnreadable")
        let chapter = try XCTUnwrap(
            TreeWalk.collect(in: f.store.manifest.structure,
                             where: { $0.type == .document }).first)
        try await write("A paragraph.", toPath: try XCTUnwrap(chapter.path), at: f.url)
        try TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es", text: "Un párrafo.",
                               sourceHash: TranslationHash.hash("A paragraph."),
                               verbatim: false)],
            forDocId: chapter.id, language: "es",
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current), in: f.url)

        let params = Data(#"{"project_id":"\#(f.id)"}"#.utf8)
        let before = try JSONDecoder().decode(
            TranslationStatusTool.Result.self,
            from: try await TranslationStatusTool.handle(paramsJSON: params, registry: f.reg))
        XCTAssertEqual(before.rows.map(\.document_id), [chapter.id], "fixture: one row")

        for u in OpLogStore.opLogFileURLs(forDocId: chapter.id, in: f.url) {
            try makeUnreadable(u)
        }
        do {
            _ = try await TranslationStatusTool.handle(paramsJSON: params, registry: f.reg)
            XCTFail("expected a refusal")
        } catch {
            let p = payload(error)
            XCTAssertEqual(p.error, "internal_error")
            XCTAssertTrue(p.message.hasPrefix("unreadableFile(name: \"\(chapter.id)."),
                          "got: \(p.message)")
        }
        await f.ds.close()
    }

    // MARK: - get_help and list_maugham_tools

    /// **An unknown help topic is an unnamed `internal_error` whose message is
    /// a Swift enum dump.** `HelpTopicIndex.LoadError` is not `LocalizedError`
    /// and is not mapped, so `toolErrorPayload`'s default arm renders
    /// `topicMissing("no-such-topic")` verbatim — no hint, and no list of the
    /// topics that DO exist, which the tool is holding at that moment.
    func test_getHelpRendersAnUnknownTopicAsARawEnumDump() async throws {
        let f = try await makeProject("Help")
        do {
            _ = try await GetHelpTool.handle(
                paramsJSON: Data(#"{"topic":"no-such-topic"}"#.utf8), registry: f.reg)
            XCTFail("expected a refusal")
        } catch {
            let p = payload(error)
            XCTAssertEqual(p.error, "internal_error")
            XCTAssertEqual(p.message, #"topicMissing("no-such-topic")"#)
            XCTAssertNil(p.hint)
        }
        await f.ds.close()
    }

    /// `get_help` and `list_maugham_tools` are the family's two tools with no
    /// required parameter, and both decode leniently: nil params, and a `topic`
    /// of the wrong JSON type, both fall back to the full listing rather than
    /// refusing.
    func test_theParameterlessToolsDecodeLenientlyRatherThanRefusing() async throws {
        let f = try await makeProject("Lenient")
        for params in [nil, Data(#"{"topic":123}"#.utf8)] as [Data?] {
            let obj = try json(try await GetHelpTool.handle(
                paramsJSON: params, registry: f.reg))
            XCTAssertNotNil(obj["topics"], "get_help fell back to the topic listing")
            XCTAssertNotNil(obj["count"])
        }
        let tools = try json(try await ListMaughamToolsTool.handle(
            paramsJSON: Data(#"{"name_contains":42}"#.utf8), registry: f.reg))
        XCTAssertNotNil(tools["tools"])
        XCTAssertNotNil(tools["server"])
        await f.ds.close()
    }

    // MARK: - Family-wide parameter shapes

    /// Every tool in the family that takes a `project_id` answers an unknown one
    /// with the same structured `unknown_project_id` payload — code, message,
    /// hint and a typed `project_id` field.
    func test_everyToolInTheFamilyRefusesAnUnknownProjectIdentically() async throws {
        let reg = ProjectRegistry()
        let cases: [(String, () async throws -> Data)] = [
            ("read_craft_intent", { try await ReadCraftIntentTool.handle(paramsJSON: Data(#"{"project_id":"nope"}"#.utf8), registry: reg) }),
            ("read_visual_language", { try await ReadVisualLanguageTool.handle(paramsJSON: Data(#"{"project_id":"nope"}"#.utf8), registry: reg) }),
            ("list_palette_cards", { try await ListPaletteCardsTool.handle(paramsJSON: Data(#"{"project_id":"nope"}"#.utf8), registry: reg) }),
            ("read_palette_card", { try await ReadPaletteCardTool.handle(paramsJSON: Data(#"{"project_id":"nope","card_id":"x"}"#.utf8), registry: reg) }),
            ("list_canvas", { try await ListCanvasTool.handle(paramsJSON: Data(#"{"project_id":"nope"}"#.utf8), registry: reg) }),
            ("add_canvas_scraps", { try await AddCanvasScrapsTool.handle(paramsJSON: Data(#"{"project_id":"nope","scraps":["a"]}"#.utf8), registry: reg) }),
            ("list_inbox", { try await ListInboxTool.handle(paramsJSON: Data(#"{"project_id":"nope"}"#.utf8), registry: reg) }),
            ("read_inbox_entry", { try await ReadInboxEntryTool.handle(paramsJSON: Data(#"{"project_id":"nope","entry_id":"x"}"#.utf8), registry: reg) }),
            ("promote_inbox_entry", { try await PromoteInboxEntryTool.handle(paramsJSON: Data(#"{"project_id":"nope","entry_id":"x"}"#.utf8), registry: reg) }),
            ("write_translation", { try await WriteTranslationTool.handle(paramsJSON: Data(#"{"project_id":"nope","document_id":"d","language":"es","entries":[]}"#.utf8), registry: reg) }),
            ("read_translation", { try await ReadTranslationTool.handle(paramsJSON: Data(#"{"project_id":"nope","document_id":"d","language":"es"}"#.utf8), registry: reg) }),
            ("translation_status", { try await TranslationStatusTool.handle(paramsJSON: Data(#"{"project_id":"nope"}"#.utf8), registry: reg) }),
        ]
        for (label, call) in cases {
            do {
                _ = try await call()
                XCTFail("\(label): expected a refusal")
            } catch {
                let p = payload(error)
                XCTAssertEqual(p.error, "unknown_project_id", label)
                XCTAssertEqual(p.message, "Project ID 'nope' is not open on this server.", label)
                XCTAssertEqual(p.fields["project_id"], .string("nope"), label)
                XCTAssertNotNil(p.hint, label)
            }
        }
    }

    /// **A missing required field, a wrong JSON type and nil params are one
    /// answer, not three.** `MCPTool.decodeParams` collapses them all into
    /// `invalid_argument: "malformed or missing parameters for <method>"` —
    /// which names the tool but never the field, and carries no hint.
    func test_malformedParamsCollapseToOneUnfieldedRefusalNamingOnlyTheMethod() async throws {
        let f = try await makeProject("Malformed")
        let nilCases: [(String, () async throws -> Data)] = [
            ("read_craft_intent", { try await ReadCraftIntentTool.handle(paramsJSON: nil, registry: f.reg) }),
            ("read_visual_language", { try await ReadVisualLanguageTool.handle(paramsJSON: nil, registry: f.reg) }),
            ("list_palette_cards", { try await ListPaletteCardsTool.handle(paramsJSON: nil, registry: f.reg) }),
            ("read_palette_card", { try await ReadPaletteCardTool.handle(paramsJSON: nil, registry: f.reg) }),
            ("list_canvas", { try await ListCanvasTool.handle(paramsJSON: nil, registry: f.reg) }),
            ("add_canvas_scraps", { try await AddCanvasScrapsTool.handle(paramsJSON: nil, registry: f.reg) }),
            ("list_inbox", { try await ListInboxTool.handle(paramsJSON: nil, registry: f.reg) }),
            ("read_inbox_entry", { try await ReadInboxEntryTool.handle(paramsJSON: nil, registry: f.reg) }),
            ("promote_inbox_entry", { try await PromoteInboxEntryTool.handle(paramsJSON: nil, registry: f.reg) }),
            ("write_translation", { try await WriteTranslationTool.handle(paramsJSON: nil, registry: f.reg) }),
            ("read_translation", { try await ReadTranslationTool.handle(paramsJSON: nil, registry: f.reg) }),
            ("translation_status", { try await TranslationStatusTool.handle(paramsJSON: nil, registry: f.reg) }),
        ]
        for (method, call) in nilCases {
            do {
                _ = try await call()
                XCTFail("\(method): expected a refusal")
            } catch {
                let p = payload(error)
                XCTAssertEqual(p.error, "invalid_argument", method)
                XCTAssertEqual(p.message, "malformed or missing parameters for \(method)", method)
                XCTAssertNil(p.hint, method)
                XCTAssertTrue(p.fields.isEmpty, method)
            }
        }

        // A missing required field and a wrong-typed one are the same answer.
        for params in [#"{"project_id":"\#(f.id)"}"#,                 // no `scraps`
                       #"{"project_id":"\#(f.id)","scraps":"a string"}"#] {
            do {
                _ = try await AddCanvasScrapsTool.handle(
                    paramsJSON: Data(params.utf8), registry: f.reg)
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(payload(error).message,
                               "malformed or missing parameters for add_canvas_scraps")
            }
        }
        await f.ds.close()
    }

    // MARK: - Helpers

    /// Put `text` into a statement the way the writer does — through its op log.
    private func write(_ text: String, into statement: Statement, at projectURL: URL) async throws {
        try await write(text, toPath: statement.path, at: projectURL)
    }

    private func write(_ text: String, toPath path: String, at projectURL: URL) async throws {
        let document = try await Document.load(
            url: projectURL.appendingPathComponent(path),
            device: MacDeviceID.current, session: "probe", presenter: nil)
        document.setFullText(text)
        try await document.flushBurstNow()
        await document.close()
    }

    private struct TransHarness {
        let url: URL
        let id: String
        let reg: ProjectRegistry
        let ds: DocumentStore
        let doc: Document
    }

    /// A two-paragraph manuscript with its `Document` open and registered —
    /// `WriteTranslationToolTests`' harness, narrowed.
    private func makeTranslationHarness() async throws -> TransHarness {
        let tmp = temp.url.appendingPathComponent("tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try "First paragraph.\n\nSecond paragraph."
            .write(to: tmp.appendingPathComponent(docPath), atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-tr-probe", title: "Chapter 1",
                                 type: .document, path: docPath)
        let manifest = ProjectManifest(type: .novel, title: "T", author: "A",
                                       created: Date(), modified: Date(),
                                       structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let pStore = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        pStore.documentStore = ds
        let doc = try await Document.load(url: tmp.appendingPathComponent(docPath),
                                          device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: docPath)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: pStore)
        return TransHarness(url: tmp, id: ProjectIdentifier.id(for: tmp),
                            reg: reg, ds: ds, doc: doc)
    }
}
