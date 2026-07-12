import XCTest
import MaughamCore
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
        // Bootstrap the document so the op log exists: ADR 0018 routes the
        // closed-doc branch through DerivedManuscript, which reads the op log.
        _ = try await Document.load(
            url: url.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)
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

    /// E6: the closed-doc branch derives through the per-project
    /// `DerivedManuscriptCache`, not a bare `DerivedManuscript.materialize`.
    /// The two must return byte-identical anchored text for the same closed
    /// doc — the cache only memoizes the intermediate `DerivedState`.
    func test_readDocument_closedDoc_equivalentToDirectMaterialize() async throws {
        let (url, _, reg) = try await makeProject()
        _ = try await Document.load(
            url: url.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"ch-1\"}"
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let doc = try JSONDecoder().decode(
            ReadDocumentTool.DocumentContent.self, from: json)
        // Direct derive bypasses the cache entirely; the tool's cache-backed
        // read must match it exactly (anchored form).
        let direct = DerivedManuscript.materialize(forDocId: "ch-1", in: url)
        XCTAssertFalse(direct.isEmpty, "op log should have bootstrap ops")
        XCTAssertEqual(doc.text, direct,
            "cache-backed closed-doc read must equal a direct materialize")
    }

    /// A second identical closed-doc read hits the cache — `deriveCount` (the
    /// number of actual JSONL decodes) stays at 1 across two reads, proving the
    /// tool now shares the per-project cache instead of decoding every call.
    func test_readDocument_closedDoc_secondReadHitsCache() async throws {
        let (url, store, reg) = try await makeProject()
        _ = try await Document.load(
            url: url.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"ch-1\"}"
        _ = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        XCTAssertEqual(store.derivedCache.deriveCount, 1,
            "first read should derive exactly once")
        _ = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        XCTAssertEqual(store.derivedCache.deriveCount, 1,
            "second read of an unchanged closed doc should hit the cache")
    }

    /// Freshness: an op appended to a CLOSED doc's log after the cache is
    /// filled must be reflected on the next read. The validity token is the
    /// op-log file set's (path, mtime, size); the append grows the file, so the
    /// token invalidates and the tool re-derives (deriveCount 1 → 2) rather
    /// than serving stale text. This is the test that pins the invalidation
    /// contract — read_document via the cache can never lag the op log.
    func test_readDocument_closedDoc_reflectsOpAppendedAfterCacheFill() async throws {
        let (url, store, reg) = try await makeProject()
        let docURL = url.appendingPathComponent("manuscript/c1.md")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"ch-1\"}"

        // First read fills the cache (one derive).
        let firstJSON = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let first = try JSONDecoder().decode(
            ReadDocumentTool.DocumentContent.self, from: firstJSON)
        XCTAssertFalse(first.text.contains("Second paragraph inserted"))
        XCTAssertEqual(store.derivedCache.deriveCount, 1)

        // Append a new paragraph to the closed doc's op log and make it durable.
        doc.setFullText("Chapter 1\n\nFirst paragraph.\n\nSecond paragraph inserted.\n")
        try await doc.flushBurstNow()

        // Second read must reflect the new op — re-derived, not a stale hit.
        let secondJSON = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let second = try JSONDecoder().decode(
            ReadDocumentTool.DocumentContent.self, from: secondJSON)
        XCTAssertTrue(second.text.contains("Second paragraph inserted"),
            "closed-doc read must reflect the appended op, not stale cached text")
        XCTAssertEqual(store.derivedCache.deriveCount, 2,
            "the op-log append should invalidate the token and force a re-derive")
    }

    /// TB tracer (§3.7): read_document resolved OPEN docs by PATH
    /// (`ds.document(for: path)`) while the annotation tools resolve by
    /// DOCID (`ds.document(forDocId:)`). A rename that updates the
    /// manifest's `path` before the DocumentStore registry is re-keyed to
    /// match — the exact window between a rename op landing and the
    /// registry catching up — used to make read_document silently fall
    /// through to the closed-doc (DerivedManuscript) branch even though the
    /// doc was open live with unflushed edits, re-opening the ADR-0018
    /// read/comment id-disagreement the tripwire-20 era closed.
    func test_readDocument_openDoc_resolvesByDocIdDespitePathRename() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RDID-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try "Chapter 1\n\nFirst paragraph.\n".write(
            to: tmp.appendingPathComponent(docPath),
            atomically: true, encoding: .utf8)
        let ch = StructureItem(id: "ch-1", title: "Ch 1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds

        let doc = try await Document.load(
            url: tmp.appendingPathComponent(docPath),
            device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: docPath)

        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let id = ProjectIdentifier.id(for: tmp)

        // Live, unflushed edit: only visible via the live Document, not the
        // op log the closed-doc branch derives from.
        doc.setFullText("Chapter 1\n\nLIVE EDIT NOT YET FLUSHED.\n")

        // Simulate the rename-timing window: the manifest's path changes (as
        // a rename op would produce) but the DocumentStore registry is NOT
        // re-keyed — it's still keyed by the old path.
        store.manifest.structure[0].path = "manuscript/renamed.md"

        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"ch-1\"}"
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let content = try JSONDecoder().decode(
            ReadDocumentTool.DocumentContent.self, from: json)
        XCTAssertTrue(content.text.contains("LIVE EDIT NOT YET FLUSHED"),
            "read_document must resolve the open doc by docId, not by the "
            + "(possibly stale) manifest path, so it returns the live "
            + "in-memory text instead of silently falling to the closed-doc "
            + "derived branch; got: \(content.text)")
    }

    /// WB fix 2 (2026-07-11 whole-branch review): the path-fallback leg
    /// `?? ds.document(for: path)` returned whatever doc is registered under that
    /// path STRING without confirming its `docId == item.id`. In a rename /
    /// path-reuse window — a DIFFERENT open doc registered under the target's path
    /// — read_document for the target would serve the OTHER doc's body under the
    /// target's id/title (a mirror of the bug the docId-first primary leg fixed).
    /// The fallback must confirm identity and otherwise fall to the closed-doc
    /// (derived-from-op-log) branch.
    func test_readDocument_pathFallback_confirmsDocIdIdentity() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RDFB-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        // Target doc (ch-1) with distinctive real text; a second doc (ch-2) whose
        // body must never surface under ch-1's identity.
        try "Chapter 1\n\nThe target paragraph.\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        try "Chapter 2\n\nWRONG DOC BODY must not leak.\n".write(
            to: tmp.appendingPathComponent("manuscript/c2.md"),
            atomically: true, encoding: .utf8)
        let ch1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document, path: "manuscript/c1.md")
        let ch2 = StructureItem(id: "ch-2", title: "Ch 2", type: .document, path: "manuscript/c2.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1, ch2], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds

        // ch-1 is CLOSED (op log bootstrapped so the derived branch has real text)
        // and NOT in the registry.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)

        // ch-2 is OPEN but — the path-reuse window — registered under ch-1's PATH
        // key. `document(forDocId: "ch-1")` misses (ch-1 not open); the fallback
        // `document(for: "manuscript/c1.md")` returns THIS ch-2 doc.
        let ch2doc = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c2.md"),
            device: "test", session: "s", presenter: nil)
        XCTAssertEqual(ch2doc.docId, "ch-2")
        ds.register(document: ch2doc, for: "manuscript/c1.md")

        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"ch-1\"}"
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let content = try JSONDecoder().decode(
            ReadDocumentTool.DocumentContent.self, from: json)
        XCTAssertTrue(content.text.contains("The target paragraph"),
            "read_document for ch-1 must return ch-1's derived text; got: \(content.text)")
        XCTAssertFalse(content.text.contains("WRONG DOC BODY"),
            "the path-fallback must not serve the wrongly-registered ch-2 body under ch-1's id")
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
        // ADR 0018: seed the op log before search_text — the engine reads from
        // the op log, not the .md.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)
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

    /// Helpers shared by the image tests.
    private func makeSolidPNG(width: Int, height: Int, color: NSColor) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Top-half red, bottom-half blue. Used to verify that crop coordinates
    /// use top-left origin (y=0 should pick up red, y=0.5 should pick up blue).
    private func makeTwoToneVerticalPNG(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Cocoa is bottom-up: y=0 is the bottom of the bitmap. To put red at
        // the visual top, fill the upper half (high y).
        NSColor.red.setFill()
        NSRect(x: 0, y: height / 2, width: width, height: height / 2).fill()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func setupImageProject(pngData: Data) async throws -> (tmp: URL, reg: ProjectRegistry, id: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RDRI-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try pngData.write(to: tmp.appendingPathComponent("research/cover.png"))
        let img = ResearchItem(
            id: "res-image", title: "Cover Photo",
            type: .asset, kind: .image,
            path: "research/cover.png", addedAt: Date())
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
        return (tmp, reg, ProjectIdentifier.id(for: tmp))
    }

    /// Default behavior: 2048 px longest edge, JPEG quality 85. The envelope
    /// must contain exactly one image block (no fallback note) when the
    /// payload fits the byte budget.
    func test_readDocument_imageDefaults_returnsJPEGAt2048() async throws {
        let png = try makeSolidPNG(width: 3000, height: 2000, color: .systemBlue)
        let (_, reg, id) = try await setupImageProject(pngData: png)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"res-image\"}"
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1, "no fallback note expected for solid-color input")
        XCTAssertEqual(content[0]["type"] as? String, "image")
        XCTAssertEqual(content[0]["mimeType"] as? String, "image/jpeg")
        let b64 = try XCTUnwrap(content[0]["data"] as? String)
        let decoded = try XCTUnwrap(Data(base64Encoded: b64))
        let decodedImage = try XCTUnwrap(NSImage(data: decoded))
        let longest = max(decodedImage.size.width, decodedImage.size.height)
        XCTAssertEqual(longest, 2048, accuracy: 1,
            "default max_dimension should be 2048; got \(decodedImage.size)")
        XCTAssertLessThan(decoded.count, 720_000,
            "encoded JPEG should fit the byte budget")
    }

    /// `region` crops in source pixel coords using top-left origin. A crop of
    /// the top half of a top=red / bottom=blue image must come back red.
    func test_readDocument_imageRegion_cropsWithTopLeftOrigin() async throws {
        let png = try makeTwoToneVerticalPNG(width: 1000, height: 1000)
        let (_, reg, id) = try await setupImageProject(pngData: png)
        let req = """
        {"project_id":"\(id)","document_id":"res-image","region":{"x":0,"y":0,"width":1.0,"height":0.5}}
        """
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        let b64 = try XCTUnwrap(content.last?["data"] as? String)
        let decoded = try XCTUnwrap(Data(base64Encoded: b64))
        let decodedImage = try XCTUnwrap(NSImage(data: decoded))
        let pixel = try samplePixelColor(from: decodedImage, at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertGreaterThan(pixel.red, 0.6,
            "top-half crop should sample red; got rgba=\(pixel)")
        XCTAssertLessThan(pixel.blue, 0.3,
            "top-half crop should not sample blue; got rgba=\(pixel)")
    }

    /// Invalid regions are rejected with a clear MCP error rather than
    /// silently clamping. x+width > 1 is the canonical mistake.
    func test_readDocument_imageRegion_rejectsOutOfBounds() async throws {
        let png = try makeSolidPNG(width: 500, height: 500, color: .systemBlue)
        let (_, reg, id) = try await setupImageProject(pngData: png)
        let req = """
        {"project_id":"\(id)","document_id":"res-image","region":{"x":0.7,"y":0.0,"width":0.5,"height":0.5}}
        """
        do {
            _ = try await ReadDocumentTool.handle(
                paramsJSON: Data(req.utf8), registry: reg)
            XCTFail("expected throw for x+width > 1")
        } catch MCPError.invalidArgument {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// max_dimension is honored when explicitly set, and clamped to the
    /// 256–4096 range. 512 px override should produce a 512 px JPEG.
    func test_readDocument_imageMaxDimension_overrideHonored() async throws {
        let png = try makeSolidPNG(width: 3000, height: 2000, color: .systemTeal)
        let (_, reg, id) = try await setupImageProject(pngData: png)
        let req = """
        {"project_id":"\(id)","document_id":"res-image","max_dimension":512}
        """
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        let b64 = try XCTUnwrap(content.last?["data"] as? String)
        let decoded = try XCTUnwrap(Data(base64Encoded: b64))
        let decodedImage = try XCTUnwrap(NSImage(data: decoded))
        XCTAssertEqual(max(decodedImage.size.width, decodedImage.size.height), 512, accuracy: 1)
    }

    /// Sample the first pixel of `image` at normalized point (x,y) in
    /// top-left-origin coords. Tests use this to verify region crops.
    private func samplePixelColor(
        from image: NSImage, at point: CGPoint
    ) throws -> (red: Double, green: Double, blue: Double) {
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep
            ?? NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        // Flip y because NSBitmapImageRep.colorAt is also bottom-up.
        let px = Int(point.x * Double(rep.pixelsWide))
        let py = Int((1.0 - point.y) * Double(rep.pixelsHigh))
        let color = try XCTUnwrap(rep.colorAt(x: px, y: py))
        let conv = color.usingColorSpace(.deviceRGB) ?? color
        return (Double(conv.redComponent), Double(conv.greenComponent), Double(conv.blueComponent))
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
        let png = try makeSolidPNG(width: 64, height: 64, color: .systemTeal)
        try png.write(to: tmp.appendingPathComponent("research/cover.png"))
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
