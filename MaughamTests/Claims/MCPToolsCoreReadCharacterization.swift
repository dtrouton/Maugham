import XCTest
import MaughamCore
@testable import Maugham

/// MCP/Tools characterisation — register module MCPTools
/// (register/reconciliation/MCPTools.{claims,filings}.json). PERMANENT pinned
/// suite: a red test here means a pinned MCP tool-failure behaviour changed.

/// Characterisation of the FAILURE TAIL of the core-read MCP tools —
/// `list_projects`, `get_metadata`, `get_outline`, `read_document`,
/// `search_text`, `list_scenes`, `get_session_stats`,
/// `list_documents_by_tag`, `find_references`, `list_all_links`.
///
/// Every assertion here was written from printed output of a probe run, not
/// from reading the handlers. Happy paths and cache behaviour are pinned
/// elsewhere (`MCP/Tools/DocumentToolsTests`, `ProjectToolsTests`,
/// `ReferenceToolsTests`, `ListAllLinksToolTests`, `ReadDocumentOpLogSourceTests`,
/// `ReferenceOpLogSourceTests`); nothing here duplicates them.
///
/// The recurring subject is RULING-54 — *a reader of a durable store treats an
/// unreadable-yet-present file as an ERROR to surface, never as empty* — and
/// what these ten tools actually do when they meet one.
@MainActor
final class MCPToolsCoreReadCharacterization: XCTestCase {

    // MARK: - Fixtures

    /// Mirrors `DocumentToolsTests.makeProject()`, widened to N documents.
    private func makeProject(
        type: ProjectType = .novel,
        docs: [(id: String, title: String, file: String, body: String)] = [
            (id: "ch-1", title: "Ch 1", file: "manuscript/c1.md",
             body: "Chapter 1\n\nFirst paragraph.\n")
        ],
        research: [ResearchItem] = []
    ) async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreRead-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        var items: [StructureItem] = []
        for d in docs {
            try d.body.write(
                to: tmp.appendingPathComponent(d.file), atomically: true, encoding: .utf8)
            items.append(StructureItem(
                id: d.id, title: d.title, type: .document, path: d.file))
        }
        let manifest = ProjectManifest(
            type: type, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: items, research: research)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    /// Bootstrap a document's op log so the closed-doc derivation has ops.
    @discardableResult
    private func bootstrap(_ projectURL: URL, _ file: String) async throws -> Document {
        let doc = try await Document.load(
            url: projectURL.appendingPathComponent(file),
            device: "probe", session: "s", presenter: nil)
        await doc.close()
        return doc
    }

    /// Make one of `docId`'s op-log files unreadable-yet-PRESENT by squatting a
    /// DIRECTORY at a second device's filename — the idiom `ReadOnlyRecoveryTests`
    /// uses. `Data(contentsOf:)` fails on it, so `OpLogStore.loadSyncMerged`
    /// reaches its RULING-54 throw with the real log still intact beside it.
    @discardableResult
    private func squatUnreadableOpLogFile(
        forDocId docId: String, in projectURL: URL, device: String = "bad"
    ) throws -> URL {
        let url = OpLogStore.opLogFileURL(
            forDocId: docId,
            deviceSlug: DeviceSlug.make(from: device),
            in: projectURL)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The writer-facing rendering of a thrown tool error: exactly what
    /// `MCPToolsCallHandler` puts in the isError result's text content.
    private func payload(_ error: Error) -> MCPError.ToolErrorPayload {
        MCPToolsCallHandler.toolErrorPayload(for: error)
    }

    /// Call `body`, requiring it to throw, and return the rendered payload.
    private func refusal(
        _ what: String, _ body: () async throws -> Data,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> MCPError.ToolErrorPayload {
        do {
            let d = try await body()
            XCTFail("\(what) did not refuse; returned \(String(data: d, encoding: .utf8) ?? "?")",
                    file: file, line: line)
            throw XCTSkip("no refusal")
        } catch let e as XCTSkip {
            throw e
        } catch {
            return payload(error)
        }
    }

    /// `get_outline` encodes `modified` with `.iso8601`, so its responses need
    /// a matching decoder — a plain `JSONDecoder()` throws on the date.
    private func outline(
        _ projectURL: URL, _ reg: ProjectRegistry
    ) async throws -> GetOutlineTool.Outline {
        let d = try await GetOutlineTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(ProjectIdentifier.id(for: projectURL))\"}".utf8),
            registry: reg)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(GetOutlineTool.Outline.self, from: d)
    }

    private func readDoc(
        _ projectURL: URL, _ documentId: String, _ reg: ProjectRegistry
    ) async throws -> ReadDocumentTool.DocumentContent {
        let id = ProjectIdentifier.id(for: projectURL)
        let d = try await ReadDocumentTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\",\"document_id\":\"\(documentId)\"}".utf8),
            registry: reg)
        return try JSONDecoder().decode(ReadDocumentTool.DocumentContent.self, from: d)
    }

    // MARK: - Unknown project id

    /// Every project-scoped core-read tool routes its unknown-project refusal
    /// through the one shared `resolveProject` helper, so all nine give a
    /// byte-identical structured payload: code `unknown_project_id`, the id
    /// echoed in `fields`, and the two-server hint.
    func test_everyProjectScopedCoreReadTool_refusesAnUnknownProjectIdIdentically() async throws {
        let args = Data(#"{"project_id":"no-such-project","document_id":"ch-1","query":"x","tag":"t","target":"x"}"#.utf8)
        let reg = ProjectRegistry()
        let tools: [(String, (Data, ProjectRegistry) async throws -> Data)] = [
            ("get_metadata", { try await GetMetadataTool.handle(paramsJSON: $0, registry: $1) }),
            ("get_outline", { try await GetOutlineTool.handle(paramsJSON: $0, registry: $1) }),
            ("read_document", { try await ReadDocumentTool.handle(paramsJSON: $0, registry: $1) }),
            ("search_text", { try await SearchTextTool.handle(paramsJSON: $0, registry: $1) }),
            ("list_scenes", { try await ListScenesTool.handle(paramsJSON: $0, registry: $1) }),
            ("get_session_stats", { try await GetSessionStatsTool.handle(paramsJSON: $0, registry: $1) }),
            ("list_documents_by_tag", { try await ListDocumentsByTagTool.handle(paramsJSON: $0, registry: $1) }),
            ("find_references", { try await FindReferencesTool.handle(paramsJSON: $0, registry: $1) }),
            ("list_all_links", { try await ListAllLinksTool.handle(paramsJSON: $0, registry: $1) }),
        ]
        for (name, call) in tools {
            let p = try await refusal(name) { try await call(args, reg) }
            XCTAssertEqual(p.error, "unknown_project_id", "\(name)")
            XCTAssertEqual(
                p.message, "Project ID 'no-such-project' is not open on this server.", "\(name)")
            XCTAssertEqual(
                p.fields["project_id"], .string("no-such-project"),
                "\(name) must echo the rejected id as a typed field")
            XCTAssertTrue(
                p.hint?.contains("Call list_projects") == true,
                "\(name) must name the recovery action")
        }
    }

    /// `list_projects` is the one core-read tool that takes no project id — and
    /// it decodes no params at all, so garbage arguments are accepted rather
    /// than refused. An empty registry answers `[]`, not an error.
    func test_listProjects_ignoresItsArgumentsEntirely() async throws {
        let empty = ProjectRegistry()
        for args: Data? in [nil, Data("nonsense".utf8), Data(#"{"project_id":"bogus"}"#.utf8)] {
            let d = try await ListProjectsTool.handle(paramsJSON: args, registry: empty)
            XCTAssertEqual(String(data: d, encoding: .utf8), "[]")
        }
        let (url, _, reg) = try await makeProject()
        let d = try await ListProjectsTool.handle(
            paramsJSON: Data("nonsense".utf8), registry: reg)
        let list = try JSONDecoder().decode([ListProjectsTool.Project].self, from: d)
        XCTAssertEqual(list.map(\.id), [ProjectIdentifier.id(for: url)],
            "garbage params still return the full registry listing")
    }

    // MARK: - Malformed params

    /// Four distinct malformations — absent params, an empty object, a
    /// wrong-typed field, and bytes that are not JSON — are indistinguishable
    /// at the surface: one `invalid_argument`, one message naming the TOOL,
    /// never the offending FIELD, and no hint. `decodeParams` swallows the
    /// underlying `DecodingError` with `try?` before it can say more.
    func test_everyMalformationOfParamsRendersTheSameFieldlessMessage() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let malformed: [Data?] = [
            nil,
            Data("{}".utf8),
            Data(#"{"project_id":42}"#.utf8),
            Data("nonsense".utf8),
        ]
        for args in malformed {
            let p = try await refusal("get_metadata") {
                try await GetMetadataTool.handle(paramsJSON: args, registry: reg)
            }
            XCTAssertEqual(p.error, "invalid_argument")
            XCTAssertEqual(p.message, "malformed or missing parameters for get_metadata")
            XCTAssertNil(p.hint)
            XCTAssertTrue(p.fields.isEmpty)
        }
        // The same shape for a second required field on a different tool.
        let missingDocId = try await refusal("read_document") {
            try await ReadDocumentTool.handle(
                paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        }
        XCTAssertEqual(missingDocId.message,
            "malformed or missing parameters for read_document",
            "the message names the tool; it does not name document_id as the missing field")
        let missingQuery = try await refusal("search_text") {
            try await SearchTextTool.handle(
                paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        }
        XCTAssertEqual(missingQuery.message,
            "malformed or missing parameters for search_text")
    }

    // MARK: - Unknown ids inside a known project

    /// An unknown `document_id` refuses and names the id. An unresolvable
    /// `find_references` target and an unused tag do NOT refuse — they answer
    /// with an empty array, which reads to Claude exactly like "exists, but
    /// nothing points at it".
    func test_anUnknownDocumentIdRefusesButAnUnknownTargetOrTagAnswersEmpty() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let p = try await refusal("read_document") {
            try await ReadDocumentTool.handle(
                paramsJSON: Data("{\"project_id\":\"\(id)\",\"document_id\":\"nope\"}".utf8),
                registry: reg)
        }
        XCTAssertEqual(p.error, "invalid_argument")
        XCTAssertEqual(p.message, "document not found: nope")
        XCTAssertNil(p.hint, "no hint points at get_outline for a fresh id")

        let refs = try await FindReferencesTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\",\"target\":\"nope\"}".utf8),
            registry: reg)
        XCTAssertEqual(String(data: refs, encoding: .utf8), "[]")

        let tagged = try await ListDocumentsByTagTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\",\"tag\":\"nope\"}".utf8),
            registry: reg)
        XCTAssertEqual(String(data: tagged, encoding: .utf8), "[]")
    }

    // MARK: - RULING-54 at read_document's manuscript arm

    /// The manuscript arm honours RULING-54 — it refuses rather than deriving a
    /// shortened manuscript — but the refusal loses its voice on the way out.
    /// `OpLogStore.ReadError` is a `LocalizedError` whose `errorDescription`
    /// explains the condition and the fix; `toolErrorPayload(for:)` has no arm
    /// for it, so it falls through to `default` and interpolates `"\(error)"` —
    /// the Swift enum's debug form. Claude sees `internal_error` and
    /// `unreadableFile(name:…)`: the FILE survives into the message, the
    /// writer-facing prose and the recovery hint do not.
    func test_anUnreadableOpLogFile_refusesAsInternalErrorInSwiftEnumDebugForm() async throws {
        let (url, _, reg) = try await makeProject()
        let doc = try await bootstrap(url, "manuscript/c1.md")
        let squat = try squatUnreadableOpLogFile(forDocId: doc.docId, in: url)
        let p = try await refusal("read_document") { try await
            ReadDocumentTool.handle(
                paramsJSON: Data("{\"project_id\":\"\(ProjectIdentifier.id(for: url))\",\"document_id\":\"ch-1\"}".utf8),
                registry: reg)
        }
        XCTAssertEqual(p.error, "internal_error",
            "there is no arm for OpLogStore.ReadError; it takes the fall-through")
        XCTAssertTrue(p.message.hasPrefix("unreadableFile(name:"),
            "the message is the enum's debug description, not its errorDescription: \(p.message)")
        XCTAssertTrue(p.message.contains(squat.lastPathComponent),
            "the offending file IS named, which is the part that survives")
        XCTAssertNil(p.hint, "the fall-through arm attaches no hint")
        XCTAssertTrue(p.fields.isEmpty, "and no typed fields")
        // The prose the ruling actually wrote for this condition never arrives.
        let written = OpLogStore.ReadError
            .unreadableFile(name: squat.lastPathComponent, underlying: "x")
            .errorDescription ?? ""
        XCTAssertTrue(written.contains("Your words are intact inside it"),
            "precondition: the ruling's prose exists on the error")
        XCTAssertFalse(p.message.contains("Your words are intact inside it"),
            "…and does not reach the writer-facing payload")
    }

    /// A closed document with NO op log at all reads as an EMPTY document —
    /// no refusal, `text: ""`, `word_count: 0` — while the `.md` beside it
    /// still holds the writer's words. Absent and empty are the same answer
    /// here, which is the opposite half of the ruling from the case above.
    func test_aDocumentWithNoOpLogReadsAsEmptyRatherThanRefusing() async throws {
        let (url, _, reg) = try await makeProject()
        let onDisk = try String(
            contentsOf: url.appendingPathComponent("manuscript/c1.md"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("First paragraph."), "precondition: the .md has words")
        let c = try await readDoc(url, "ch-1", reg)
        XCTAssertEqual(c.text, "")
        XCTAssertEqual(c.word_count, 0)
        XCTAssertEqual(c.character_count, 0)
        XCTAssertEqual(c.path, "manuscript/c1.md",
            "the path is reported, so the answer looks like a real empty document")
    }

    /// A torn final op line — what a crash mid-`append` leaves — is dropped
    /// silently by `OpLogStore.loadSyncMerged`'s per-line `try?`, so
    /// `read_document` returns a SHORTER manuscript with no error and nothing
    /// in the payload to say a line was skipped. Contrast the whole-file case
    /// above, which refuses.
    func test_aTornOpLineIsDroppedSilentlyAndTheManuscriptComesBackShorter() async throws {
        let (url, _, reg) = try await makeProject(docs: [
            (id: "ch-1", title: "Ch 1", file: "manuscript/c1.md",
             body: "Alpha paragraph.\n\nBeta paragraph.\n")
        ])
        let doc = try await Document.load(
            url: url.appendingPathComponent("manuscript/c1.md"),
            device: "probe", session: "s", presenter: nil)
        // A second op, so the tear costs the LAST edit rather than everything.
        doc.setFullText("Alpha paragraph.\n\nBeta paragraph.\n\nGamma paragraph.\n")
        try await doc.flushBurstNow()
        await doc.close()

        let before = try await readDoc(url, "ch-1", reg)
        XCTAssertTrue(before.text.contains("Gamma paragraph."), "precondition")

        guard let log = OpLogStore.opLogFileURLs(forDocId: doc.docId, in: url).first
        else { return XCTFail("no op-log file") }
        var lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertGreaterThan(lines.count, 1, "precondition: more than one op on the log")
        guard let last = lines.popLast() else { return XCTFail("empty log") }
        lines.append(String(last.prefix(last.count / 2)))   // tear it in half
        try (lines.joined(separator: "\n") + "\n")
            .write(to: log, atomically: true, encoding: .utf8)

        let after = try await readDoc(url, "ch-1", reg)   // must not throw
        XCTAssertLessThan(after.text.count, before.text.count,
            "the torn op's content is gone from the derived manuscript")
        XCTAssertFalse(after.text.contains("Gamma paragraph."),
            "the last edit is silently absent")
    }

    /// The quarantine archive is written by the LOAD path (`Document.load` →
    /// `IntegrityQuarantine.record`), never by an MCP read — and once written,
    /// no core-read tool mentions it. A quarantined-and-continued document is
    /// an ordinary document to Claude: the surviving log is presented as the
    /// whole truth, with the archived lines invisible.
    func test_theQuarantineArchiveIsInvisibleToEveryCoreReadTool() async throws {
        let (url, _, reg) = try await makeProject()
        let doc = try await bootstrap(url, "manuscript/c1.md")
        guard let log = OpLogStore.opLogFileURLs(forDocId: doc.docId, in: url).first
        else { return XCTFail("no op-log file") }
        var text = try String(contentsOf: log, encoding: .utf8)
        text += "{this is not valid json}\n"
        try text.write(to: log, atomically: true, encoding: .utf8)

        let quarantineDir = url.appendingPathComponent(".maugham/conflicts/quarantine")
        func quarantined() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: quarantineDir.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
        }
        // An MCP read of the torn log records nothing.
        let viaMCP = try await readDoc(url, "ch-1", reg)
        XCTAssertEqual(quarantined(), [],
            "read_document never quarantines — the skip is not recorded on this path")
        // Opening the document does record it…
        _ = try await bootstrap(url, "manuscript/c1.md")
        XCTAssertEqual(quarantined().count, 1,
            "the load path writes exactly one record for the torn line")
        XCTAssertTrue(quarantined()[0].hasPrefix("ch-1."), "keyed by docId")

        // …and afterwards the tool's answer is unchanged and says nothing.
        let after = try await readDoc(url, "ch-1", reg)
        XCTAssertEqual(after.text, viaMCP.text)
        XCTAssertFalse(after.text.lowercased().contains("quarantine"))
    }

    // MARK: - RULING-54 across a multi-document scan

    /// One unreadable document splits this family THREE ways, and a caller
    /// cannot tell which behaviour they are getting from the tool's schema:
    ///
    /// * `search_text` SKIPS it — the matches inside it are silently absent,
    ///   with no per-document error channel (intentional; see the comment at
    ///   `ProjectSearchEngine.swift:46`).
    /// * `find_references` and `list_all_links` REFUSE the whole call.
    /// * `get_outline` and `get_metadata` are UNAFFECTED — neither reads the
    ///   op log, so both answer normally about a document nobody can derive.
    func test_oneUnreadableDocumentSplitsTheScanningToolsThreeWays() async throws {
        let (url, _, reg) = try await makeProject(docs: [
            (id: "ch-1", title: "Ch 1", file: "manuscript/c1.md",
             body: "Chapter 1\n\nThe needle is here. See [[Ch 2]].\n"),
            (id: "ch-2", title: "Ch 2", file: "manuscript/c2.md",
             body: "Chapter 2\n\nThe needle is here too.\n")
        ])
        let d1 = try await bootstrap(url, "manuscript/c1.md")
        _ = try await bootstrap(url, "manuscript/c2.md")
        let id = ProjectIdentifier.id(for: url)
        let unreadable = try squatUnreadableOpLogFile(forDocId: d1.docId, in: url)

        // (1) skipped, silently
        let hits = try JSONDecoder().decode([SearchTextTool.Match].self, from:
            try await SearchTextTool.handle(
                paramsJSON: Data("{\"project_id\":\"\(id)\",\"query\":\"needle\"}".utf8),
                registry: reg))
        XCTAssertEqual(hits.map(\.document_id), ["ch-2"],
            "ch-1's match is dropped with no error and no marker in the result")

        // (2) refused, whole call
        for (name, call): (String, (Data, ProjectRegistry) async throws -> Data) in [
            ("find_references", { try await FindReferencesTool.handle(paramsJSON: $0, registry: $1) }),
            ("list_all_links", { try await ListAllLinksTool.handle(paramsJSON: $0, registry: $1) }),
        ] {
            let args = Data("{\"project_id\":\"\(id)\",\"target\":\"Ch 2\"}".utf8)
            let p = try await refusal(name) { try await call(args, reg) }
            XCTAssertEqual(p.error, "internal_error", "\(name)")
            XCTAssertTrue(p.message.contains(unreadable.lastPathComponent),
                "\(name) names the file but drops ch-2's readable answer with it")
        }

        // (3) unaffected
        let tree = try await outline(url, reg)
        XCTAssertEqual(tree.nodes.map(\.id), ["ch-1", "ch-2"],
            "get_outline reports the underivable document as an ordinary node")
        _ = try await GetMetadataTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
    }

    /// `list_scenes` sits with the refusers: a screenplay whose first scene
    /// document is unreadable yields no scenes at all, not the scenes of the
    /// documents that ARE readable.
    func test_listScenes_refusesTheWholeScriptForOneUnreadableSceneDocument() async throws {
        let (url, _, reg) = try await makeProject(
            type: .screenplay,
            docs: [
                (id: "sc-1", title: "S1", file: "manuscript/s1.fountain",
                 body: "INT. KITCHEN - DAY\n\nShe waits.\n"),
                (id: "sc-2", title: "S2", file: "manuscript/s2.fountain",
                 body: "EXT. STREET - NIGHT\n\nHe leaves.\n")
            ])
        let d1 = try await bootstrap(url, "manuscript/s1.fountain")
        _ = try await bootstrap(url, "manuscript/s2.fountain")
        let id = ProjectIdentifier.id(for: url)
        let args = Data("{\"project_id\":\"\(id)\"}".utf8)
        let healthy = try JSONDecoder().decode([ListScenesTool.Scene].self, from:
            try await ListScenesTool.handle(paramsJSON: args, registry: reg))
        XCTAssertEqual(healthy.map(\.document_id), ["sc-1", "sc-2"], "precondition")

        let unreadable = try squatUnreadableOpLogFile(forDocId: d1.docId, in: url)
        let p = try await refusal("list_scenes") {
            try await ListScenesTool.handle(paramsJSON: args, registry: reg)
        }
        XCTAssertEqual(p.error, "internal_error")
        XCTAssertTrue(p.message.contains(unreadable.lastPathComponent))
    }

    /// Control for the reading above: `get_outline`'s `word_count` is null for
    /// a healthy, freshly-loaded project too. It comes from
    /// `ProjectStore.cachedWordCount` and is never derived on demand, so a null
    /// there says "not cached yet" and never "this document could not be read".
    func test_getOutlineWordCountIsCacheOnlyAndSaysNothingAboutReadability() async throws {
        let (url, _, reg) = try await makeProject(docs: [
            (id: "ch-1", title: "Ch 1", file: "manuscript/c1.md", body: "One two three.\n"),
            (id: "ch-2", title: "Ch 2", file: "manuscript/c2.md", body: "Four five six.\n")
        ])
        let d1 = try await bootstrap(url, "manuscript/c1.md")
        _ = try await bootstrap(url, "manuscript/c2.md")
        let healthy = try await outline(url, reg)
        XCTAssertEqual(healthy.nodes.compactMap(\.word_count), [],
            "both documents report a null word_count while perfectly readable")

        try squatUnreadableOpLogFile(forDocId: d1.docId, in: url)
        let afterSquat = try await outline(url, reg)
        XCTAssertEqual(afterSquat.nodes.map(\.id), healthy.nodes.map(\.id))
        XCTAssertEqual(afterSquat.nodes.compactMap(\.word_count), [],
            "and the unreadable file changes nothing about the outline")
        XCTAssertNotNil(afterSquat.nodes[0].modified,
            "mtime still comes off the .md, which is readable")
    }

    // MARK: - The response budget

    /// `read_document`'s own `MCPResponseBudget.enforce` refuses before the
    /// central backstop can, so the refusal carries the document-specific hint
    /// naming `search_text` and per-chapter splitting, plus typed byte counts.
    func test_anOversizedDocumentRefusesWithPayloadTooLargeAndANarrowingHint() async throws {
        let (url, _, reg) = try await makeProject(docs: [
            (id: "ch-1", title: "Ch 1", file: "manuscript/c1.md",
             body: String(repeating: "a", count: 950_000) + "\n")
        ])
        try await bootstrap(url, "manuscript/c1.md")
        let p = try await refusal("read_document") {
            try await ReadDocumentTool.handle(
                paramsJSON: Data("{\"project_id\":\"\(ProjectIdentifier.id(for: url))\",\"document_id\":\"ch-1\"}".utf8),
                registry: reg)
        }
        XCTAssertEqual(p.error, "payload_too_large")
        XCTAssertTrue(p.message.contains("over the 900000-byte MCP text budget"))
        XCTAssertEqual(p.fields["max_bytes"], .int(MCPResponseBudget.maxTextBytes))
        if case .int(let n)? = p.fields["byte_count"] {
            XCTAssertGreaterThan(n, MCPResponseBudget.maxTextBytes)
        } else {
            XCTFail("byte_count must be a typed int, got \(String(describing: p.fields["byte_count"]))")
        }
        XCTAssertEqual(p.hint,
            "This document is too large to return in one MCP response. "
            + "Use search_text to locate the passage you need, or split the "
            + "manuscript into per-chapter documents in the binder and read one.")
    }

    // MARK: - Read-only recovery

    /// A read-only recovery `Document` is never entered in `DocumentStore`'s
    /// registry, which is the collection `read_document` resolves an open
    /// document through. So while the writer is looking at a partial view,
    /// MCP still sees a CLOSED document and gets the strict refusal — never
    /// the partial state. Registering the same instance flips the answer,
    /// which is what makes the non-registration load-bearing rather than
    /// incidental.
    func test_aReadOnlyRecoveryDocumentIsInvisibleToTheRegistryMCPResolvesThrough() async throws {
        let (url, store, reg) = try await makeProject()
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let docURL = url.appendingPathComponent("manuscript/c1.md")
        let first = try await Document.load(
            url: docURL, device: "probe", session: "s", presenter: nil)
        let docId = first.docId
        await first.close()
        let unreadable = try squatUnreadableOpLogFile(forDocId: docId, in: url)

        // The strict load refuses, which is what puts the writer on the ladder.
        do {
            _ = try await Document.load(
                url: docURL, device: "probe", session: "s", presenter: nil)
            XCTFail("precondition: the strict load must refuse")
        } catch { /* expected */ }

        // EditorHost.openReadOnly's call, and it does NOT register.
        let partial = try await Document.load(
            url: docURL, device: "probe", session: "s", presenter: nil,
            recovery: .readOnlyPartial)
        XCTAssertTrue(partial.isReadOnlyRecovery)
        XCTAssertTrue(partial.materialize().contains("First paragraph."),
            "precondition: the partial view HAS text to leak")
        XCTAssertNil(ds.document(forDocId: docId), "invisible by docId")
        XCTAssertNil(ds.document(for: "manuscript/c1.md"), "invisible by path")

        let p = try await refusal("read_document") {
            try await ReadDocumentTool.handle(
                paramsJSON: Data("{\"project_id\":\"\(ProjectIdentifier.id(for: url))\",\"document_id\":\"ch-1\"}".utf8),
                registry: reg)
        }
        XCTAssertEqual(p.error, "internal_error")
        XCTAssertTrue(p.message.contains(unreadable.lastPathComponent),
            "MCP meets the strict closed-doc refusal, not the partial text")

        // Falsifier: registering the very same Document hands the partial text over.
        ds.register(document: partial, for: "manuscript/c1.md")
        let leaked = try await readDoc(url, "ch-1", reg)
        XCTAssertTrue(leaked.text.contains("First paragraph."),
            "so the non-registration is the whole of the protection")
        ds.unregister(path: "manuscript/c1.md")
        await partial.close()
    }

    // MARK: - get_session_stats

    /// `get_session_stats` swallows every failure of its underlying store: no
    /// `DocumentStore` at all, a `sessions.json` full of garbage, and a
    /// `sessions.json` that exists but cannot be read all return the same
    /// all-zero aggregate. There is no code path by which this tool reports
    /// that it could not read the log — RULING-54's opposite.
    func test_getSessionStatsReportsZeroForEveryUnreadableLogState() async throws {
        let (url, store, reg) = try await makeProject()
        let args = Data("{\"project_id\":\"\(ProjectIdentifier.id(for: url))\"}".utf8)
        let zero = GetSessionStatsTool.SessionStats(
            daily: [], total_words: 0, total_minutes: 0)

        func stats() async throws -> GetSessionStatsTool.SessionStats {
            try JSONDecoder().decode(GetSessionStatsTool.SessionStats.self, from:
                try await GetSessionStatsTool.handle(paramsJSON: args, registry: reg))
        }
        let noStore = try await stats()
        XCTAssertEqual(noStore, zero, "no DocumentStore attached")

        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let logURL = url.appendingPathComponent(".maugham/sessions.json")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham"), withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: logURL)
        let garbage = try await stats()
        XCTAssertEqual(garbage, zero, "undecodable sessions.json")

        try FileManager.default.removeItem(at: logURL)
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
        let unreadable = try await stats()
        XCTAssertEqual(unreadable, zero, "unreadable-yet-present sessions.json")
    }

    // MARK: - read_document's research arm

    /// Every non-readable research KIND refuses with a message naming the item
    /// by title and the real reason — the best refusals in this family. But a
    /// research document whose file is MISSING, or present-and-unreadable,
    /// does not refuse at all: `(try? String(contentsOf:)) ?? ""` turns both
    /// into an empty document. The same tool therefore obeys RULING-54 on its
    /// manuscript arm and contradicts it on its research arm.
    func test_theResearchArmNamesEveryBadKindButReadsAnUnreadableFileAsEmpty() async throws {
        func asset(_ id: String, _ title: String, _ kind: ResearchItem.AssetKind?,
                   _ path: String?, _ url: String? = nil) -> ResearchItem {
            ResearchItem(id: id, title: title, type: .asset, kind: kind, path: path, url: url)
        }
        let (url, _, reg) = try await makeProject(research: [
            ResearchItem(id: "grp", title: "A Group", type: .group),
            asset("r-doc", "A Note", .document, "research/note.md"),
            asset("r-gone", "A Missing Note", .document, "research/gone.md"),
            asset("r-nopath", "Pathless", .document, nil),
            asset("r-pdf", "A PDF", .pdf, "research/x.pdf"),
            asset("r-audio", "An Audio", .audio, "research/x.m4a"),
            asset("r-link", "A Link", .link, nil, "https://example.com"),
            asset("r-nokind", "No Kind", nil, "research/x"),
        ])
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("research"), withIntermediateDirectories: true)
        let noteURL = url.appendingPathComponent("research/note.md")
        try "Real note body.\n".write(to: noteURL, atomically: true, encoding: .utf8)

        // Refusals that name the item and the cause.
        let expected: [(String, String)] = [
            ("grp", "Research item 'A Group' is a group, not a readable document"),
            ("r-nopath", "Research item 'Pathless' has no on-disk path"),
            ("r-pdf", "Research item 'A PDF' is a PDF, not a readable text document. Use list_research for metadata."),
            ("r-audio", "Research item 'An Audio' is an audio file, not a readable text document. Use list_research for metadata."),
            ("r-link", "Research item 'A Link' is a web link (https://example.com). Use list_research for the URL."),
            ("r-nokind", "Research item 'No Kind' has no kind set"),
        ]
        for (target, message) in expected {
            let p = try await refusal(target) { try await
                ReadDocumentTool.handle(
                    paramsJSON: Data("{\"project_id\":\"\(ProjectIdentifier.id(for: url))\",\"document_id\":\"\(target)\"}".utf8),
                    registry: reg)
            }
            XCTAssertEqual(p.error, "invalid_argument", target)
            XCTAssertEqual(p.message, message, target)
            XCTAssertNil(p.hint, "\(target): the cause is in the message, never in a hint")
        }

        // The readable one, as a control.
        let control = try await readDoc(url, "r-doc", reg)
        XCTAssertEqual(control.text, "Real note body.\n")

        // Absent file: empty, silently.
        let gone = try await readDoc(url, "r-gone", reg)
        XCTAssertEqual(gone.text, "")
        XCTAssertEqual(gone.word_count, 0)

        // Present-but-unreadable: also empty, silently.
        try FileManager.default.removeItem(at: noteURL)
        try FileManager.default.createDirectory(at: noteURL, withIntermediateDirectories: true)
        let nowUnreadable = try await readDoc(url, "r-doc", reg)
        XCTAssertEqual(nowUnreadable.text, "",
            "an unreadable research note is indistinguishable from an empty one")
    }

    /// A manifest-supplied research path that escapes the project root is
    /// refused by `SafeRelativePath` before any read, and the refusal names
    /// both the item and the offending path (A5).
    func test_theResearchArmRefusesAPathThatEscapesTheProjectRoot() async throws {
        let (url, _, reg) = try await makeProject(research: [
            ResearchItem(id: "r-escape", title: "Escaping", type: .asset,
                         kind: .document, path: "../../etc/passwd")
        ])
        let p = try await refusal("r-escape") { try await
            ReadDocumentTool.handle(
                paramsJSON: Data("{\"project_id\":\"\(ProjectIdentifier.id(for: url))\",\"document_id\":\"r-escape\"}".utf8),
                registry: reg)
        }
        XCTAssertEqual(p.error, "invalid_argument")
        XCTAssertEqual(p.message,
            "Research item 'Escaping' has an unsafe path: Path escapes the project root: ../../etc/passwd")
    }

    // MARK: - The .md is derived, and it shows

    /// Deleting the manuscript `.md` costs `get_outline` its `modified` stamp
    /// (an mtime read) but costs `read_document` nothing at all — it derives
    /// from the op log (ADR 0018), so Claude still reads the full anchored
    /// text of a document that no longer exists on disk.
    func test_deletingTheMarkdownCostsTheOutlineItsMtimeButNotTheDocumentItsText() async throws {
        let (url, _, reg) = try await makeProject()
        try await bootstrap(url, "manuscript/c1.md")
        try FileManager.default.removeItem(at: url.appendingPathComponent("manuscript/c1.md"))
        let tree = try await outline(url, reg)
        XCTAssertNil(tree.nodes[0].modified, "no file, no mtime")

        let c = try await readDoc(url, "ch-1", reg)
        XCTAssertTrue(c.text.contains("First paragraph."))
        XCTAssertTrue(c.text.contains("<!-- ¶"), "and in anchored form")
        XCTAssertEqual(c.path, "manuscript/c1.md",
            "the reported path points at a file that is no longer there")
    }
}
