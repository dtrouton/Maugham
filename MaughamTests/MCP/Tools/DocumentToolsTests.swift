import XCTest
@testable import Maugham

@MainActor
final class DocumentToolsTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "Chapter 1\n\nFirst paragraph.\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let ch = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    func test_getOutline_returnsStructure() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await GetOutlineTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let outline = try decoder.decode(GetOutlineTool.Outline.self, from: json)
        XCTAssertEqual(outline.nodes.count, 1)
        XCTAssertEqual(outline.nodes[0].title, "Ch 1")
        XCTAssertEqual(outline.nodes[0].type, "document")
        // T-pre-tag: document nodes carry filesystem mtime so agents can answer
        // "what have you been working on lately?"
        XCTAssertNotNil(outline.nodes[0].modified)
    }

    func test_readDocument_returnsContent() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"ch-1\"}"
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let doc = try JSONDecoder().decode(
            ReadDocumentTool.DocumentContent.self, from: json)
        XCTAssertEqual(doc.title, "Ch 1")
        XCTAssertTrue(doc.text.contains("First paragraph"))
        XCTAssertEqual(doc.mode, "prose")
    }

    func test_readDocument_missingDoc_throws() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"nope\"}"
        do {
            _ = try await ReadDocumentTool.handle(
                paramsJSON: Data(req.utf8), registry: reg)
            XCTFail()
        } catch MCPError.invalidArgument {
            // ok
        } catch {
            XCTFail("wrong: \(error)")
        }
    }
}

extension DocumentToolsTests {
    /// Every node in the outline response must contain the keys
    /// `synopsis`, `status`, `word_count`, `word_target`, and `modified`
    /// (with null when the value is nil) — not omitted. This keeps the
    /// JSON shape uniform across documents regardless of which optional
    /// fields are populated.
    func test_getOutline_documentNodes_alwaysIncludeOptionalKeys() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("GOK-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "a".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        try "b".write(to: tmp.appendingPathComponent("manuscript/c2.md"),
                       atomically: true, encoding: .utf8)
        // ch-1 has all metadata; ch-2 has none — both should report all keys.
        let ch1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                 path: "manuscript/c1.md",
                                 synopsis: "S", status: "draft", wordTarget: 500)
        let ch2 = StructureItem(id: "ch-2", title: "b", type: .document,
                                 path: "manuscript/c2.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1, ch2], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await GetOutlineTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        // Parse as raw JSON so we can confirm key *presence* (not just decoded
        // values — those'd swallow the omitted-vs-null distinction).
        guard let any = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let nodes = any["nodes"] as? [[String: Any]] else {
            return XCTFail("expected {nodes: [...]}")
        }
        XCTAssertEqual(nodes.count, 2)
        for node in nodes {
            let title = (node["title"] as? String) ?? "?"
            for key in ["synopsis", "status", "word_count", "word_target", "modified"] {
                XCTAssertNotNil(node[key],
                    "node \"\(title)\" missing key \(key); got: \(node.keys.sorted())")
            }
        }
    }

    /// search_text used to emit document_id as a file path; that breaks the
    /// chain search → read_document because read_document expects a
    /// StructureItem.id. Regression: document_id must be the real id.
    func test_searchText_returnsRealStructureItemId() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("STID-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "The lighthouse keeper waited.".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let ch = StructureItem(
            id: "doc-lookup-target", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"query\":\"lighthouse\"}"
        let json = try await SearchTextTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let matches = try JSONDecoder().decode(
            [SearchTextTool.Match].self, from: json)
        XCTAssertFalse(matches.isEmpty, "expected at least one match for 'lighthouse'")
        // Real id is "doc-lookup-target", NOT the path "manuscript/c1.md".
        XCTAssertEqual(matches[0].document_id, "doc-lookup-target",
            "document_id should be the structure item id, not a path; got: \(matches[0].document_id)")
    }

    func test_readDocument_returnsResearchNoteText() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RDR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "# Sarah\n\nSoft, clipped voice.\n".write(
            to: tmp.appendingPathComponent("research/sarah.md"),
            atomically: true, encoding: .utf8)
        let sarah = ResearchItem(
            id: "res-sarah-target",
            title: "Sarah",
            type: .asset,
            kind: .document,
            path: "research/sarah.md",
            addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"res-sarah-target\"}"
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let doc = try JSONDecoder().decode(
            ReadDocumentTool.DocumentContent.self, from: json)
        XCTAssertEqual(doc.id, "res-sarah-target")
        XCTAssertEqual(doc.title, "Sarah")
        XCTAssertTrue(doc.text.contains("Soft, clipped voice"))
        XCTAssertEqual(doc.mode, "prose")
    }

    /// Reading an image research item returns an MCP content envelope with
    /// a base64-encoded image block. The wrapper in MCPToolsCallHandler
    /// detects the envelope shape and passes it through unchanged.
    func test_readDocument_returnsImageBase64Envelope() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RDRI-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        // 1x1 PNG (smallest valid PNG).
        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ]
        let pngData = Data(pngBytes)
        try pngData.write(to: tmp.appendingPathComponent("research/cover.png"))
        let img = ResearchItem(
            id: "res-image",
            title: "Cover Photo",
            type: .asset,
            kind: .image,
            path: "research/cover.png",
            addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [img])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"res-image\"}"
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "image")
        XCTAssertEqual(content[0]["mimeType"] as? String, "image/png")
        let b64 = try XCTUnwrap(content[0]["data"] as? String)
        let decoded = try XCTUnwrap(Data(base64Encoded: b64))
        XCTAssertEqual(decoded, pngData,
            "decoded base64 should round-trip to the original PNG bytes")
    }

    /// MCPToolsCallHandler must pass through tool results that are already
    /// MCP-shaped (top-level `content` array). Without this, image envelopes
    /// would be re-wrapped as a text block containing stringified JSON.
    func test_toolsCallHandler_passesThroughMCPContentEnvelope() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ]
        try Data(pngBytes).write(to: tmp.appendingPathComponent("research/cover.png"))
        let img = ResearchItem(
            id: "res-image",
            title: "Cover Photo",
            type: .asset,
            kind: .image,
            path: "research/cover.png",
            addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [img])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let router = MCPRouter()
        router.register(method: ReadDocumentTool.method) { params in
            try await ReadDocumentTool.handle(paramsJSON: params, registry: reg)
        }

        let id = ProjectIdentifier.id(for: tmp)
        let callJSON = """
        {"name":"read_document","arguments":{"project_id":"\(id)","document_id":"res-image"}}
        """
        let resp = try await MCPToolsCallHandler.handle(
            paramsJSON: Data(callJSON.utf8), router: router)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: resp) as? [String: Any])
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        // Image block came through, NOT stringified as text.
        XCTAssertEqual(content[0]["type"] as? String, "image",
            "envelope should pass through unchanged; got: \(content)")
    }

    /// Groups should expose a modified timestamp derived from the max of
    /// descendant document mtimes. Empty groups can stay nil.
    func test_getOutline_groupModified_isMaxOfDescendantDocs() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("GOM-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript/act-one"),
            withIntermediateDirectories: true)
        let c1Path = tmp.appendingPathComponent("manuscript/act-one/c1.md")
        let c2Path = tmp.appendingPathComponent("manuscript/act-one/c2.md")
        try "a".write(to: c1Path, atomically: true, encoding: .utf8)
        try "b".write(to: c2Path, atomically: true, encoding: .utf8)
        // Force c2 to be more recent than c1 by a measurable delta.
        let recent = Date()
        let older = recent.addingTimeInterval(-3600)
        try FileManager.default.setAttributes(
            [.modificationDate: older], ofItemAtPath: c1Path.path)
        try FileManager.default.setAttributes(
            [.modificationDate: recent], ofItemAtPath: c2Path.path)

        let c1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                path: "manuscript/act-one/c1.md")
        let c2 = StructureItem(id: "ch-2", title: "Ch 2", type: .document,
                                path: "manuscript/act-one/c2.md")
        let act1 = StructureItem(id: "grp-act1", title: "Act One", type: .group,
                                  path: nil, children: [c1, c2])
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [act1], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await GetOutlineTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let outline = try decoder.decode(
            GetOutlineTool.Outline.self, from: json)
        XCTAssertEqual(outline.nodes.count, 1)
        let group = outline.nodes[0]
        XCTAssertEqual(group.type, "group")
        let groupModified = try XCTUnwrap(group.modified,
            "group should expose modified derived from descendant docs")
        // Within ~5s of the most-recent child (`recent`)
        XCTAssertEqual(groupModified.timeIntervalSince(recent), 0, accuracy: 5)
    }
}
