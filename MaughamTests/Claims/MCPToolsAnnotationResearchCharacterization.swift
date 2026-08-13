import XCTest
import MaughamCore
@testable import Maugham

/// MCP/Tools characterisation — register module MCPTools
/// (register/reconciliation/MCPTools.{claims,filings}.json). PERMANENT pinned
/// suite: a red test here means a pinned MCP tool-failure behaviour changed.
///
/// Characterisation of the FAILURE tail of the annotation / task / research /
/// link MCP family: `add_comment`, `add_suggested_change`, `add_query`,
/// `add_craft_note`, `list_annotations`, `get_annotation`, `list_tasks`,
/// `get_task`, `add_note`, `list_research`, `link_research`,
/// `unlink_research`, `move_research_item`.
///
/// Every assertion below was written from observed handler output, never from
/// reading the handler, so a future run that diverges shows the new reality
/// beside the pinned one.
///
/// The writer-facing surface is `MCPToolsCallHandler.toolErrorPayload(for:)` —
/// the `{error, message, hint, fields}` Claude actually receives — so that,
/// and not the raw Swift error, is what these tests pin.
@MainActor
final class MCPToolsAnnotationResearchCharacterization: XCTestCase {

    // MARK: - Harness

    struct Harness {
        let url: URL
        let projectId: String
        let store: ProjectStore
        let ds: DocumentStore
        let reg: ProjectRegistry
        let openDoc: Document
        let openParagraphId: String
        let closedDocId: String
        let closedDocPath: String
    }

    private var chmodded: [String] = []

    override func tearDown() async throws {
        for path in chmodded {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path)
        }
        chmodded = []
        try await super.tearDown()
    }

    private func chmod(_ url: URL, _ mode: Int) throws {
        chmodded.append(url.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// Novel project with one OPEN document (registered in the DocumentStore),
    /// one CLOSED document (manifest-present, never loaded — the transient-load
    /// path in `withAnnotationDocument`), and one research note.
    private func makeHarness() async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MARP-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        try fm.createDirectory(
            at: tmp.appendingPathComponent("research"),
            withIntermediateDirectories: true)

        try "First paragraph.".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        try "Closed chapter body.".write(
            to: tmp.appendingPathComponent("manuscript/c2.md"),
            atomically: true, encoding: .utf8)
        try "Sarah is thirty.".write(
            to: tmp.appendingPathComponent("research/sarah.md"),
            atomically: true, encoding: .utf8)

        let open = StructureItem(
            id: "doc-open", title: "Chapter 1", type: .document,
            path: "manuscript/c1.md")
        let closed = StructureItem(
            id: "doc-closed", title: "Chapter 2", type: .document,
            path: "manuscript/c2.md")
        let sarah = ResearchItem(
            id: "res-sarah", title: "Sarah", type: .asset, kind: .document,
            path: "research/sarah.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [open, closed], research: [sarah])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds

        let doc = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: "manuscript/c1.md")

        let log = try await doc.opLog()
        let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? ""
        XCTAssertFalse(pid.isEmpty, "harness needs a bootstrap paragraph id")

        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        return Harness(
            url: tmp,
            projectId: ProjectIdentifier.id(for: tmp),
            store: store, ds: ds, reg: reg,
            openDoc: doc, openParagraphId: pid,
            closedDocId: "doc-closed",
            closedDocPath: "manuscript/c2.md")
    }

    private func json(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }

    private func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    /// Diagnostic sink. During characterisation this also teed observed output
    /// to a scratchpad file; as a permanent resident it just goes to stdout so
    /// the suite carries no session-specific path.
    private func print(_ s: String) {
        Swift.print(s)
    }

    @discardableResult
    private func report(
        _ label: String, _ error: Error
    ) -> MCPError.ToolErrorPayload {
        let p = MCPToolsCallHandler.toolErrorPayload(for: error)
        print("PROBE[\(label)] raw = \(error)")
        print("PROBE[\(label)] localized = \(error.localizedDescription)")
        print("PROBE[\(label)] code = \(p.error)")
        print("PROBE[\(label)] message = \(p.message)")
        print("PROBE[\(label)] hint = \(p.hint ?? "<nil>")")
        print("PROBE[\(label)] fields = \(p.fields)")
        return p
    }

    /// Run a tool call that is expected to throw, returning the rendered
    /// payload plus the raw error. Fails the test if it does NOT throw.
    private func expectRefusal(
        _ label: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Data
    ) async -> (payload: MCPError.ToolErrorPayload, raw: Error)? {
        do {
            let d = try await body()
            print("PROBE[\(label)] NO THROW -> \(text(d))")
            XCTFail("expected \(label) to refuse", file: file, line: line)
            return nil
        } catch {
            return (report(label, error), error)
        }
    }

    // MARK: - A. unknown paragraph id → named `paragraph_not_found`

    func test_addComment_unknownParagraphId_isNamedWithCountAndHint() async throws {
        let h = try await makeHarness()
        let r = await expectRefusal("A") {
            try await AddCommentTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "document_id": "doc-open",
                    "paragraph_id": "zzzz",
                    "body": "no such paragraph"]),
                registry: h.reg)
        }
        XCTAssertEqual(r?.payload.error, "paragraph_not_found")
        XCTAssertEqual(
            r?.payload.message,
            "Paragraph 'zzzz' is not in the current document sequence.")
        XCTAssertEqual(r?.payload.hint?.contains("Call read_document"), true)
        XCTAssertEqual(r?.payload.fields["paragraph_id"], .string("zzzz"))
        XCTAssertEqual(r?.payload.fields["current_paragraph_count"], .int(1))
        await h.ds.close()
    }

    // MARK: - B. non-matching quote → named `span_not_found` carrying the quote

    func test_addComment_quoteNotInParagraph_isNamedWithQuoteAndHint() async throws {
        let h = try await makeHarness()
        let r = await expectRefusal("B") {
            try await AddCommentTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "document_id": "doc-open",
                    "paragraph_id": h.openParagraphId,
                    "body": "b",
                    "quote": "a phrase that is absent"]),
                registry: h.reg)
        }
        XCTAssertEqual(r?.payload.error, "span_not_found")
        XCTAssertEqual(
            r?.payload.message,
            "The quoted span was not found in paragraph '\(h.openParagraphId)'.")
        XCTAssertEqual(r?.payload.hint?.contains("omit `quote`"), true)
        XCTAssertEqual(
            r?.payload.fields["quote"], .string("a phrase that is absent"))
        XCTAssertEqual(
            r?.payload.fields["paragraph_id"], .string(h.openParagraphId))
        await h.ds.close()
    }

    /// A quote AND an unknown paragraph: the more specific paragraph error
    /// wins. `resolveSpanAnchor`'s doc comment says so explicitly — "When the
    /// paragraph isn't present at all this returns nil rather than throwing,
    /// so the downstream `addAnnotation` validation surfaces the more specific
    /// `paragraph_not_found` error."
    func test_addComment_quoteWithUnknownParagraph_reportsTheParagraph() async throws {
        let h = try await makeHarness()
        let r = await expectRefusal("B2") {
            try await AddCommentTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "document_id": "doc-open",
                    "paragraph_id": "zzzz",
                    "body": "b",
                    "quote": "absent"]),
                registry: h.reg)
        }
        XCTAssertEqual(r?.payload.error, "paragraph_not_found")
        await h.ds.close()
    }

    // MARK: - C. closed doc, op log present but UNREADABLE (RULING-54)

    /// The RULING-54 refusal reaches Claude — no tool answers "empty" over an
    /// unreadable history — but it arrives as the generic `internal_error`
    /// fall-through with the Swift enum's reflection dump as its message. The
    /// authored `ReadError.errorDescription` ("Your words are intact inside
    /// it…") exists on the error and is DISCARDED by the renderer, and the
    /// payload carries no hint and no fields.
    func test_closedDocUnreadableOpLog_refusesAsInternalErrorLosingTheAuthoredText() async throws {
        let h = try await makeHarness()

        let closedURL = h.url.appendingPathComponent(h.closedDocPath)
        let warm = try await Document.load(
            url: closedURL, device: "test", session: "warm", presenter: nil)
        await warm.close()

        let logs = OpLogStore.opLogFileURLs(forDocId: h.closedDocId, in: h.url)
        print("PROBE[C] op log files = \(logs.map(\.lastPathComponent))")
        XCTAssertFalse(logs.isEmpty, "expected a materialised op log to corrupt")
        for u in logs { try chmod(u, 0o000) }

        let add = await expectRefusal("C-add") {
            try await AddCommentTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "document_id": h.closedDocId,
                    "paragraph_id": "zzzz",
                    "body": "does this even reach validation?"]),
                registry: h.reg)
        }
        let list = await expectRefusal("C-list") {
            try await ListAnnotationsTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "document_id": h.closedDocId]),
                registry: h.reg)
        }
        let tasks = await expectRefusal("C-tasks") {
            try await ListTasksTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "scope": "document",
                    "document_id": h.closedDocId]),
                registry: h.reg)
        }

        for r in [add, list, tasks] {
            XCTAssertEqual(r?.payload.error, "internal_error")
            XCTAssertEqual(r?.payload.message.hasPrefix("unreadableFile(name:"), true)
            XCTAssertNil(r?.payload.hint)
            XCTAssertEqual(r?.payload.fields.isEmpty, true)
            // The file's NAME survives into the message; the authored
            // human-readable guidance does not.
            XCTAssertEqual(r?.payload.message.contains(".jsonl"), true)
            XCTAssertEqual(
                r?.payload.message.contains("Your words are intact"), false)
            XCTAssertEqual(
                r?.raw.localizedDescription.contains("Your words are intact"), true)
        }
        await h.ds.close()
    }

    // MARK: - C2. closed doc, op log present, readable, UNDECODABLE

    /// The other half of the unreadable/corrupt split: bytes that CAN be read
    /// but decode to nothing derive an EMPTY document, and the annotation
    /// reads answer as if the document were simply empty. `list_annotations`
    /// returns `[]` with no signal, and `add_comment` reports
    /// `current_paragraph_count: 0` — Claude cannot tell a document with no
    /// annotations from one whose entire history failed to decode.
    func test_closedDocUndecodableOpLog_readsAsAnEmptyDocument() async throws {
        let h = try await makeHarness()
        let closedURL = h.url.appendingPathComponent(h.closedDocPath)
        let warm = try await Document.load(
            url: closedURL, device: "test", session: "warm", presenter: nil)
        await warm.close()

        let logs = OpLogStore.opLogFileURLs(forDocId: h.closedDocId, in: h.url)
        for u in logs {
            try Data("{not json at all\nnor this\n".utf8).write(to: u)
        }

        let listed = try await ListAnnotationsTool.handle(
            paramsJSON: try json([
                "project_id": h.projectId,
                "document_id": h.closedDocId]),
            registry: h.reg)
        print("PROBE[C2-list] -> \(text(listed))")
        XCTAssertEqual(text(listed), "[]")

        let r = await expectRefusal("C2-add") {
            try await AddCommentTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "document_id": h.closedDocId,
                    "paragraph_id": "zzzz",
                    "body": "x"]),
                registry: h.reg)
        }
        XCTAssertEqual(r?.payload.error, "paragraph_not_found")
        XCTAssertEqual(r?.payload.fields["current_paragraph_count"], .int(0))
        await h.ds.close()
    }

    // MARK: - D. manifest entry whose file is ABSENT from disk

    /// A document in the manifest whose `.md` is gone answers as an empty
    /// document rather than refusing: `list_annotations` returns `[]`.
    func test_closedDocFileMissing_listAnnotationsAnswersEmpty() async throws {
        let h = try await makeHarness()
        try FileManager.default.removeItem(
            at: h.url.appendingPathComponent(h.closedDocPath))
        let d = try await ListAnnotationsTool.handle(
            paramsJSON: try json([
                "project_id": h.projectId,
                "document_id": h.closedDocId]),
            registry: h.reg)
        print("PROBE[D-list] -> \(text(d))")
        XCTAssertEqual(text(d), "[]")
        await h.ds.close()
    }

    /// The write half of the same shape: `add_craft_note` against a document
    /// whose file does not exist SUCCEEDS, returning an annotation id and
    /// minting an op log for a document that is not on disk. Nothing in the
    /// call path checks that the manifest's path resolves to a file.
    func test_addCraftNote_againstAMissingFile_succeedsAndMintsAnOpLog() async throws {
        let h = try await makeHarness()
        let mdURL = h.url.appendingPathComponent(h.closedDocPath)
        try FileManager.default.removeItem(at: mdURL)

        let d = try await AddCraftNoteTool.handle(
            paramsJSON: try json([
                "project_id": h.projectId,
                "document_id": h.closedDocId,
                "body": "a craft note on a document that is not there"]),
            registry: h.reg)
        print("PROBE[D2-craftNote] -> \(text(d))")
        let result = try JSONDecoder().decode(
            AddCraftNoteTool.Result.self, from: d)
        XCTAssertFalse(result.annotation_id.isEmpty)

        let logs = OpLogStore.opLogFileURLs(forDocId: h.closedDocId, in: h.url)
        print("PROBE[D2] op logs after = \(logs.map(\.lastPathComponent))")
        XCTAssertEqual(logs.count, 1, "an op log for a document with no file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mdURL.path))
        await h.ds.close()
    }

    // MARK: - E. unknown ids at the two resolution layers

    /// The two layers refuse with different qualities of answer: an unknown
    /// PROJECT gets the named `unknown_project_id` with a hint and a field; an
    /// unknown DOCUMENT gets a bare `invalid_argument` — cause named in prose,
    /// but no code to route on, no hint, no fields.
    func test_unknownDocumentAndProject_refuseWithDifferentShapes() async throws {
        let h = try await makeHarness()
        let doc = await expectRefusal("E-doc") {
            try await AddCommentTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "document_id": "doc-nope",
                    "paragraph_id": "zzzz",
                    "body": "x"]),
                registry: h.reg)
        }
        XCTAssertEqual(doc?.payload.error, "invalid_argument")
        XCTAssertEqual(
            doc?.payload.message,
            "document_id not found in project manifest: doc-nope")
        XCTAssertNil(doc?.payload.hint)
        XCTAssertEqual(doc?.payload.fields.isEmpty, true)

        let proj = await expectRefusal("E-proj") {
            try await ListAnnotationsTool.handle(
                paramsJSON: try self.json([
                    "project_id": "proj-nope",
                    "document_id": "doc-open"]),
                registry: h.reg)
        }
        XCTAssertEqual(proj?.payload.error, "unknown_project_id")
        XCTAssertEqual(proj?.payload.fields["project_id"], .string("proj-nope"))
        XCTAssertEqual(proj?.payload.hint?.contains("list_projects"), true)
        await h.ds.close()
    }

    // MARK: - F. malformed params

    /// Three distinct malformations — no params at all, a missing required
    /// field, and a required field of the wrong JSON type — are rendered as
    /// ONE message that names the tool and nothing else. Which field was wrong
    /// is not recoverable from the refusal.
    func test_malformedParams_collapseToOneUndifferentiatedMessage() async throws {
        let h = try await makeHarness()
        let expected = "malformed or missing parameters for add_comment"

        let nilParams = await expectRefusal("F-nil") {
            try await AddCommentTool.handle(paramsJSON: nil, registry: h.reg)
        }
        let missing = await expectRefusal("F-missing") {
            try await AddCommentTool.handle(
                paramsJSON: try self.json(["project_id": h.projectId]),
                registry: h.reg)
        }
        let wrongType = await expectRefusal("F-type") {
            try await AddCommentTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "document_id": "doc-open",
                    "paragraph_id": 42,
                    "body": "x"]),
                registry: h.reg)
        }
        for r in [nilParams, missing, wrongType] {
            XCTAssertEqual(r?.payload.error, "invalid_argument")
            XCTAssertEqual(r?.payload.message, expected)
            XCTAssertNil(r?.payload.hint)
        }
        await h.ds.close()
    }

    // MARK: - G. get_annotation unknown id

    /// `get_annotation` fails loudly and names the id, but as a bare
    /// `invalid_argument` — no `annotation_not_found` code, no hint, no
    /// fields. Its sibling `get_task` answers the same question with a named
    /// `task_not_found` payload (pinned below).
    func test_getAnnotation_unknownId_isUnnamedInvalidArgument() async throws {
        let h = try await makeHarness()
        let r = await expectRefusal("G") {
            try await GetAnnotationTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "document_id": "doc-open",
                    "annotation_id": "ann-nope"]),
                registry: h.reg)
        }
        XCTAssertEqual(r?.payload.error, "invalid_argument")
        XCTAssertEqual(r?.payload.message, "annotation_id not found: ann-nope")
        XCTAssertNil(r?.payload.hint)
        XCTAssertEqual(r?.payload.fields.isEmpty, true)
        await h.ds.close()
    }

    // MARK: - H. unrecognised filter vocabulary is silently widened

    /// `kinds`/`statuses` tokens that match no enum case are dropped, and a
    /// filter left empty by that drop collapses to the DEFAULT (`[open]`,
    /// all kinds). A caller who asks for `statuses: ["not_a_status"]` is
    /// answered with the open annotations, as though it had asked for them.
    func test_listAnnotations_unrecognisedFilterTokens_returnTheDefaultSet() async throws {
        let h = try await makeHarness()
        _ = try await AddCommentTool.handle(
            paramsJSON: try json([
                "project_id": h.projectId,
                "document_id": "doc-open",
                "paragraph_id": h.openParagraphId,
                "body": "seeded"]),
            registry: h.reg)

        for (label, extra) in [
            ("kinds", ["kinds": ["not_a_kind"]] as [String: Any]),
            ("statuses", ["statuses": ["not_a_status"]] as [String: Any]),
            ("both", ["kinds": ["not_a_kind"],
                      "statuses": ["not_a_status"]] as [String: Any])
        ] {
            var p: [String: Any] = [
                "project_id": h.projectId, "document_id": "doc-open"]
            for (k, v) in extra { p[k] = v }
            let d = try await ListAnnotationsTool.handle(
                paramsJSON: try json(p), registry: h.reg)
            print("PROBE[H-\(label)] -> \(text(d))")
            let items = try XCTUnwrap(
                JSONSerialization.jsonObject(with: d) as? [[String: Any]])
            XCTAssertEqual(items.count, 1, "\(label) widened to the default set")
            XCTAssertEqual(items.first?["body"] as? String, "seeded")
            XCTAssertEqual(items.first?["status"] as? String, "open")
            XCTAssertEqual(items.first?["kind"] as? String, "comment")
        }
        await h.ds.close()
    }

    // MARK: - I. link_research reports success for ids that do not exist

    /// `link_research` validates neither id. With an unknown document it
    /// reports `linked: true` having written nothing; with a REAL document and
    /// an unknown research id it reports `linked: true` and PERSISTS a link to
    /// a research item that does not exist.
    func test_linkResearch_unknownIds_reportSuccess_andCanPersistADanglingLink() async throws {
        let h = try await makeHarness()

        let bothUnknown = try await LinkResearchTool.handle(
            paramsJSON: try json([
                "project_id": h.projectId,
                "research_id": "res-nope",
                "document_id": "doc-also-nope"]),
            registry: h.reg)
        print("PROBE[I-bothUnknown] -> \(text(bothUnknown))")
        XCTAssertEqual(text(bothUnknown), #"{"linked":true}"#)
        XCTAssertEqual(h.store.linkedResearchIds(forDocumentId: "doc-open"), [])
        XCTAssertEqual(
            h.store.linkedResearchIds(forDocumentId: "doc-also-nope"), [])

        let unknownResearch = try await LinkResearchTool.handle(
            paramsJSON: try json([
                "project_id": h.projectId,
                "research_id": "res-nope",
                "document_id": "doc-open"]),
            registry: h.reg)
        print("PROBE[I-unknownResearch] -> \(text(unknownResearch))")
        print("PROBE[I-links-after] -> \(h.store.linkedResearchIds(forDocumentId: "doc-open"))")
        XCTAssertEqual(text(unknownResearch), #"{"linked":true}"#)
        XCTAssertEqual(
            h.store.linkedResearchIds(forDocumentId: "doc-open"), ["res-nope"])
        await h.ds.close()
    }

    /// `unlink_research` is documented idempotent — "no-op if the link doesn't
    /// exist" — and reports `linked: false` whether it removed a link, found
    /// no link, or was handed two ids that name nothing.
    func test_unlinkResearch_absentLinkAndUnknownIds_reportTheSameSuccess() async throws {
        let h = try await makeHarness()
        let absent = try await UnlinkResearchTool.handle(
            paramsJSON: try json([
                "project_id": h.projectId,
                "research_id": "res-sarah",
                "document_id": "doc-open"]),
            registry: h.reg)
        print("PROBE[J-absentLink] -> \(text(absent))")
        XCTAssertEqual(text(absent), #"{"linked":false}"#)

        let unknown = try await UnlinkResearchTool.handle(
            paramsJSON: try json([
                "project_id": h.projectId,
                "research_id": "res-nope",
                "document_id": "doc-nope"]),
            registry: h.reg)
        print("PROBE[J-unknownIds] -> \(text(unknown))")
        XCTAssertEqual(text(unknown), #"{"linked":false}"#)
        await h.ds.close()
    }

    // MARK: - K/L/M. move_research_item refusals

    /// Every store-level refusal in `move_research_item` reaches Claude as
    /// `internal_error` carrying the Swift enum's reflection dump. The
    /// authored `ProjectStoreError.errorDescription` — which the binder's own
    /// alerts show — is discarded, and the worst of them, `structureMissing`,
    /// renders as the bare word with the offending id nowhere in the payload.
    func test_moveResearchItem_storeRefusals_renderAsInternalErrorEnumDumps() async throws {
        let h = try await makeHarness()

        let group = await expectRefusal("K-group") {
            try await MoveResearchItemTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "research_ids": ["res-sarah"],
                    "target_group_id": "grp-nope"]),
                registry: h.reg)
        }
        XCTAssertEqual(group?.payload.error, "internal_error")
        XCTAssertEqual(group?.payload.message, #"parentNotFound("grp-nope")"#)
        XCTAssertEqual(
            group?.raw.localizedDescription.contains("could not be found"), true)

        let piece = await expectRefusal("K-piece") {
            try await MoveResearchItemTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "research_ids": ["res-sarah"],
                    "target_document_id": "doc-nope"]),
                registry: h.reg)
        }
        XCTAssertEqual(piece?.payload.error, "internal_error")
        XCTAssertEqual(
            piece?.payload.message,
            #"fileSystemError("Operation only valid for Collection projects")"#)

        let unknownItem = await expectRefusal("L-unknownItem") {
            try await MoveResearchItemTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "research_ids": ["res-nope"],
                    "target": "shared"]),
                registry: h.reg)
        }
        XCTAssertEqual(unknownItem?.payload.error, "internal_error")
        XCTAssertEqual(unknownItem?.payload.message, "structureMissing")
        XCTAssertEqual(unknownItem?.payload.message.contains("res-nope"), false)
        XCTAssertEqual(
            unknownItem?.raw.localizedDescription,
            "That item is no longer in the project.")
        await h.ds.close()
    }

    /// The tool's OWN argument validation, by contrast, is a named-enough
    /// `invalid_argument` with a message that says what to do.
    func test_moveResearchItem_argumentValidation_isInvalidArgument() async throws {
        let h = try await makeHarness()
        let empty = await expectRefusal("M-empty") {
            try await MoveResearchItemTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "research_ids": [] as [String],
                    "target": "shared"]),
                registry: h.reg)
        }
        XCTAssertEqual(empty?.payload.error, "invalid_argument")
        XCTAssertEqual(empty?.payload.message, "research_ids must not be empty")

        let badTarget = await expectRefusal("M-badTarget") {
            try await MoveResearchItemTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "research_ids": ["res-sarah"],
                    "target": "elsewhere"]),
                registry: h.reg)
        }
        XCTAssertEqual(badTarget?.payload.error, "invalid_argument")
        XCTAssertEqual(badTarget?.payload.message, #"target must be "shared""#)
        await h.ds.close()
    }

    /// One unknown id in a batch moves nothing — the store validates the whole
    /// batch before it touches the filesystem ("Validates the whole batch up
    /// front — one invalid id moves nothing").
    func test_moveResearchItem_batchWithOneUnknownId_movesNothing() async throws {
        let h = try await makeHarness()
        let group = try await h.store.addResearchItem(
            parentId: nil, title: "Folder", kind: nil)
        let note = try await h.store.addResearchTextNote(
            parentId: group.id, title: "Batchee")
        let before = TreeWalk.find(id: note.id, in: h.store.manifest.research)?.path
        print("PROBE[M-batch] path before = \(String(describing: before))")

        let r = await expectRefusal("M-batch") {
            try await MoveResearchItemTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "research_ids": [note.id, "res-nope"],
                    "target": "shared"]),
                registry: h.reg)
        }
        XCTAssertEqual(r?.payload.message, "structureMissing")
        let after = TreeWalk.find(id: note.id, in: h.store.manifest.research)?.path
        print("PROBE[M-batch] path after  = \(String(describing: after))")
        XCTAssertEqual(after, before)
        await h.ds.close()
    }

    // MARK: - N/O. add_note failure ordering (RULING-52)

    /// The tool's own validation runs before any write: an unknown
    /// `parent_group_id` is refused with nothing created on disk and nothing
    /// added to the manifest.
    func test_addNote_unknownParentGroup_writesNothing() async throws {
        let h = try await makeHarness()
        let researchDir = h.url.appendingPathComponent("research")
        let before = try FileManager.default
            .contentsOfDirectory(atPath: researchDir.path).sorted()

        let r = await expectRefusal("N") {
            try await AddNoteTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "title": "Ghost",
                    "body": "should not land",
                    "parent_group_id": "grp-nope"]),
                registry: h.reg)
        }
        XCTAssertEqual(r?.payload.error, "invalid_argument")
        XCTAssertEqual(
            r?.payload.message, "parent_group_id not found: grp-nope")

        let after = try FileManager.default
            .contentsOfDirectory(atPath: researchDir.path).sorted()
        print("PROBE[N] research before = \(before) after = \(after)")
        XCTAssertEqual(after, before)
        XCTAssertEqual(h.store.manifest.research.map(\.title), ["Sarah"])
        await h.ds.close()
    }

    /// A failure INSIDE the create path is not equally clean. With the project
    /// root unwritable, the note's `.md` is created first and the manifest
    /// save then fails: the call refuses, but an EMPTY `half-landed.md` is
    /// left in `research/`, the in-memory manifest (what the binder shows this
    /// session) holds the note, the on-disk manifest does not, and the body
    /// Claude sent was never written. The refusal names the manifest and says
    /// nothing about the file that landed.
    func test_addNote_manifestUnwritable_refusesAfterCreatingAnEmptyOrphanFile() async throws {
        let h = try await makeHarness()
        try chmod(h.url, 0o500)

        let r = await expectRefusal("O") {
            try await AddNoteTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "title": "Half Landed",
                    "body": "body text"]),
                registry: h.reg)
        }
        XCTAssertEqual(r?.payload.error, "internal_error")
        XCTAssertEqual(r?.payload.message.hasPrefix("manifestUnwritable("), true)
        XCTAssertEqual(r?.payload.message.contains("half-landed.md"), false)

        let researchDir = h.url.appendingPathComponent("research")
        let files = try FileManager.default
            .contentsOfDirectory(atPath: researchDir.path).sorted()
        print("PROBE[O] research dir = \(files)")
        XCTAssertTrue(files.contains("half-landed.md"),
                      "the orphan file the refusal left behind")

        let body = try String(
            contentsOf: researchDir.appendingPathComponent("half-landed.md"),
            encoding: .utf8)
        print("PROBE[O] created file body = '\(body)'")
        XCTAssertEqual(body, "", "the body Claude sent never reached the file")

        XCTAssertEqual(
            h.store.manifest.research.map(\.title), ["Sarah", "Half Landed"],
            "the live manifest holds a note the disk does not")
        let onDisk = try String(
            contentsOf: h.url.appendingPathComponent("project.maugham.json"),
            encoding: .utf8)
        XCTAssertFalse(onDisk.contains("Half Landed"))

        try chmod(h.url, 0o755)
        await h.ds.close()
    }

    /// When the research FOLDER is the unwritable one the failure lands before
    /// the manifest is touched, so nothing is left behind — and Claude sees a
    /// raw `NSError` description, absolute filesystem path included.
    func test_addNote_researchFolderUnwritable_leavesNothingButLeaksTheRawNSError() async throws {
        let h = try await makeHarness()
        let researchDir = h.url.appendingPathComponent("research")
        try chmod(researchDir, 0o500)

        let r = await expectRefusal("O2") {
            try await AddNoteTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "title": "Blocked",
                    "body": "body text"]),
                registry: h.reg)
        }
        XCTAssertEqual(r?.payload.error, "internal_error")
        XCTAssertEqual(r?.payload.message.contains("NSCocoaErrorDomain"), true)
        XCTAssertEqual(r?.payload.message.contains("/var/folders/"), true)
        XCTAssertEqual(h.store.manifest.research.map(\.title), ["Sarah"])

        try chmod(researchDir, 0o755)
        await h.ds.close()
    }

    // MARK: - P. list_tasks / get_task tail

    /// `list_tasks(scope: "document")` answers an unknown document with an
    /// empty task list rather than refusing — the handler says so: "If docId
    /// isn't in the manifest, fall through to an empty result rather than
    /// erroring… aligning with that silence." An unrecognised status token is
    /// dropped the same way `list_annotations` drops one. The scope token
    /// itself IS validated, and `get_task` names its miss.
    func test_listTasks_unknownDocumentIsSilent_butScopeAndTaskIdAreNot() async throws {
        let h = try await makeHarness()

        let unknownDoc = try await ListTasksTool.handle(
            paramsJSON: try json([
                "project_id": h.projectId,
                "scope": "document",
                "document_id": "doc-nope"]),
            registry: h.reg)
        print("PROBE[P-unknownDoc] -> \(text(unknownDoc))")
        XCTAssertEqual(text(unknownDoc), #"{"tasks":[]}"#)

        let badStatus = try await ListTasksTool.handle(
            paramsJSON: try json([
                "project_id": h.projectId,
                "scope": "project",
                "statuses": ["not_a_status"]]),
            registry: h.reg)
        print("PROBE[P-badStatus] -> \(text(badStatus))")
        XCTAssertEqual(text(badStatus), #"{"tasks":[]}"#)

        let badScope = await expectRefusal("P-badScope") {
            try await ListTasksTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "scope": "chapter"]),
                registry: h.reg)
        }
        XCTAssertEqual(badScope?.payload.error, "invalid_argument")
        XCTAssertEqual(
            badScope?.payload.message,
            #"scope must be "document" or "project""#)

        let getTask = await expectRefusal("P-getTask") {
            try await GetTaskTool.handle(
                paramsJSON: try self.json([
                    "project_id": h.projectId,
                    "task_id": "task-nope"]),
                registry: h.reg)
        }
        XCTAssertEqual(getTask?.payload.error, "task_not_found")
        XCTAssertEqual(getTask?.payload.fields["task_id"], .string("task-nope"))
        XCTAssertEqual(getTask?.payload.hint?.contains("Call list_tasks"), true)
        await h.ds.close()
    }

    // MARK: - Q. list_research over a dangling path

    /// `list_research` reports the manifest verbatim: an item whose file has
    /// been deleted is still listed, with its path, and nothing marks it as
    /// missing.
    func test_listResearch_listsAnItemWhoseFileIsGone() async throws {
        let h = try await makeHarness()
        try FileManager.default.removeItem(
            at: h.url.appendingPathComponent("research/sarah.md"))
        let d = try await ListResearchTool.handle(
            paramsJSON: try json(["project_id": h.projectId]),
            registry: h.reg)
        print("PROBE[Q] -> \(text(d))")
        let tree = try JSONDecoder().decode(
            ListResearchTool.ResearchTree.self, from: d)
        XCTAssertEqual(tree.items.count, 1)
        XCTAssertEqual(tree.items.first?.id, "res-sarah")
        XCTAssertEqual(tree.items.first?.path, "research/sarah.md")
        await h.ds.close()
    }

    // MARK: - K2. unknown piece id in a COLLECTION project

    /// The novel-project refusal above ("Operation only valid for Collection
    /// projects") is about the project type, not the id. In a Collection —
    /// where the target IS meaningful — an unknown piece id names itself, but
    /// still arrives as `internal_error` carrying the enum dump.
    func test_moveResearchItem_unknownPieceInACollection_namesTheIdInsideAnInternalError() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MARPC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "MARPColl", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)
        let note = try await store.addResearchTextNote(
            parentId: nil, title: "Coll Note")

        let r = await expectRefusal("K2") {
            try await MoveResearchItemTool.handle(
                paramsJSON: try self.json([
                    "project_id": projectId,
                    "research_ids": [note.id],
                    "target_document_id": "piece-nope"]),
                registry: reg)
        }
        XCTAssertEqual(r?.payload.error, "internal_error")
        XCTAssertEqual(
            r?.payload.message,
            #"fileSystemError("Unknown loose piece: piece-nope")"#)
        XCTAssertNil(r?.payload.hint)
        await ds.close()
    }
}
