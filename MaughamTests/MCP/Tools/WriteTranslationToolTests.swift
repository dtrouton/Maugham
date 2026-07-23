import XCTest
import MaughamCore
@testable import Maugham

/// Harness mirrors `AnnotationCreationToolsTests`: a project on disk with one
/// multi-paragraph manuscript, an open `Document` registered in the
/// `DocumentStore`, and a `ProjectRegistry` for id resolution. The manuscript
/// carries a `**bold**` construct so the construct-drift warning path can be
/// exercised.
@MainActor
final class WriteTranslationToolTests: XCTestCase {

    private struct Harness {
        let projectURL: URL
        let projectId: String
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let doc: Document
    }

    private func makeHarness() async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WTT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        try "First paragraph with **bold** word.\n\nSecond paragraph plain."
            .write(to: tmp.appendingPathComponent(docPath),
                   atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: "doc-tr-test", title: "Chapter 1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let pStore = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        pStore.documentStore = ds

        let docURL = tmp.appendingPathComponent(docPath)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: docPath)

        let reg = ProjectRegistry()
        reg.register(url: tmp, store: pStore)

        return Harness(
            projectURL: tmp,
            projectId: ProjectIdentifier.id(for: tmp),
            documentStore: ds,
            registry: reg,
            doc: doc)
    }

    private func call(_ h: Harness, _ obj: [String: Any]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try await WriteTranslationTool.handle(paramsJSON: data, registry: h.registry)
    }

    // MARK: - Behavior 4/5/7: happy-path batch of two

    func test_writeTranslation_happyPathBatchOfTwo() async throws {
        let h = try await makeHarness()
        let ids = h.doc.sequence
        XCTAssertEqual(ids.count, 2)
        let src0 = h.doc.paragraphs[ids[0]]!
        let src1 = h.doc.paragraphs[ids[1]]!

        let resultData = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [
                ["paragraph_id": ids[0], "text": "Primer párrafo con **negrita**."],
                ["paragraph_id": ids[1], "text": "Segundo párrafo simple."]
            ]
        ])
        let result = try JSONDecoder().decode(
            WriteTranslationTool.Result.self, from: resultData)
        XCTAssertEqual(result.written, 2)
        XCTAssertEqual(result.language, "es")
        XCTAssertTrue(result.warnings.isEmpty, "no construct drift expected: \(result.warnings)")

        let records = TranslationStore.loadMerged(
            forDocId: h.doc.docId, language: "es", in: h.projectURL)
        XCTAssertEqual(records.count, 2)
        let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.paragraphId, $0) })
        XCTAssertEqual(byId[ids[0]]?.text, "Primer párrafo con **negrita**.")
        XCTAssertEqual(byId[ids[1]]?.text, "Segundo párrafo simple.")
        // sourceHash is server-stamped from the current paragraph text.
        XCTAssertEqual(byId[ids[0]]?.sourceHash, TranslationHash.hash(src0))
        XCTAssertEqual(byId[ids[1]]?.sourceHash, TranslationHash.hash(src1))

        await h.documentStore.close()
    }

    // MARK: - Behavior 3: unknown ids are all-or-nothing

    func test_writeTranslation_unknownIds_allOrNothing() async throws {
        let h = try await makeHarness()
        let goodId = h.doc.sequence[0]

        do {
            _ = try await call(h, [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "language": "es",
                "entries": [
                    ["paragraph_id": goodId, "text": "válido"],
                    ["paragraph_id": "zzzz", "text": "malo"],
                    ["paragraph_id": "wwww", "text": "malo"]
                ]
            ])
            XCTFail("expected invalidArgument for unknown ids")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("zzzz"), "message should list zzzz: \(msg)")
            XCTAssertTrue(msg.contains("wwww"), "message should list wwww: \(msg)")
        }

        // All-or-nothing: nothing appended, including the valid entry.
        let records = TranslationStore.loadMerged(
            forDocId: h.doc.docId, language: "es", in: h.projectURL)
        XCTAssertTrue(records.isEmpty, "store must be empty after all-or-nothing reject")

        await h.documentStore.close()
    }

    // MARK: - Behavior 4: verbatim copies the current source text

    func test_writeTranslation_verbatimCopiesSource() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[0]
        let src = h.doc.paragraphs[pid]!

        _ = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": pid, "verbatim": true]]
        ])

        let records = TranslationStore.loadMerged(
            forDocId: h.doc.docId, language: "es", in: h.projectURL)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].text, src, "verbatim entry copies the source text")
        XCTAssertTrue(records[0].verbatim)
        XCTAssertEqual(records[0].sourceHash, TranslationHash.hash(src))

        await h.documentStore.close()
    }

    // MARK: - Behavior 6: construct-drift warning when a `**` is dropped

    func test_writeTranslation_constructDriftWarning() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[0]  // source carries **bold**

        let resultData = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": pid, "text": "Primer párrafo sin negrita."]]
        ])
        let result = try JSONDecoder().decode(
            WriteTranslationTool.Result.self, from: resultData)
        XCTAssertEqual(result.written, 1)
        XCTAssertFalse(result.warnings.isEmpty, "dropping ** should warn")
        XCTAssertTrue(result.warnings.contains { $0.contains(pid) },
                      "warning should name the paragraph: \(result.warnings)")

        await h.documentStore.close()
    }

    // MARK: - Behavior 1: invalid language tag

    func test_writeTranslation_invalidLanguageTag() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[0]

        do {
            _ = try await call(h, [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "language": "ES_MX",
                "entries": [["paragraph_id": pid, "text": "x"]]
            ])
            XCTFail("expected invalidArgument for bad language tag")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("invalid language tag"), "got: \(msg)")
        }

        await h.documentStore.close()
    }

    // MARK: - Behavior 2: neither text nor verbatim, or both

    func test_writeTranslation_neitherTextNorVerbatim() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[0]

        do {
            _ = try await call(h, [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "language": "es",
                "entries": [["paragraph_id": pid]]
            ])
            XCTFail("expected invalidArgument for entry with neither text nor verbatim")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains(pid), "message should name the paragraph: \(msg)")
        }

        await h.documentStore.close()
    }

    func test_writeTranslation_bothTextAndVerbatim() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[0]

        do {
            _ = try await call(h, [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "language": "es",
                "entries": [["paragraph_id": pid, "text": "x", "verbatim": true]]
            ])
            XCTFail("expected invalidArgument for entry with both text and verbatim")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains(pid), "message should name the paragraph: \(msg)")
        }

        await h.documentStore.close()
    }

    // MARK: - F8: equals-source advisory (non-verbatim entry whose text matches source)

    func test_writeTranslation_equalsSourceAdvisory_firesForNonVerbatimMatch() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[1]  // "Second paragraph plain." — no bold to drift on
        let src = h.doc.paragraphs[pid]!

        let resultData = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": pid, "text": src]]
        ])
        let result = try JSONDecoder().decode(
            WriteTranslationTool.Result.self, from: resultData)
        XCTAssertEqual(result.written, 1, "advisory never blocks the write")
        XCTAssertTrue(
            result.warnings.contains(
                "¶\(pid): translated text equals source — mark verbatim: true if deliberate"),
            "got: \(result.warnings)")

        // The write still lands.
        let records = TranslationStore.loadMerged(
            forDocId: h.doc.docId, language: "es", in: h.projectURL)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].text, src)

        await h.documentStore.close()
    }

    func test_writeTranslation_equalsSourceAdvisory_doesNotFireForVerbatimTrue() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[1]

        let resultData = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": pid, "verbatim": true]]
        ])
        let result = try JSONDecoder().decode(
            WriteTranslationTool.Result.self, from: resultData)
        XCTAssertTrue(result.warnings.isEmpty,
                      "verbatim: true entries are the deliberate case — no advisory: \(result.warnings)")

        await h.documentStore.close()
    }

    func test_writeTranslation_equalsSourceAdvisory_doesNotFireForGenuineTranslation() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[1]

        let resultData = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": pid, "text": "Segundo párrafo simple."]]
        ])
        let result = try JSONDecoder().decode(
            WriteTranslationTool.Result.self, from: resultData)
        XCTAssertTrue(result.warnings.isEmpty,
                      "genuinely different translated text should not trigger the advisory: \(result.warnings)")

        await h.documentStore.close()
    }

    // MARK: - I1: write_translation posts maughamTranslationDidUpdate

    func test_writeTranslation_postsTranslationDidUpdateEvent() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[0]

        // Observe the project-scoped refresh event through the real
        // MaughamEvent filter (a live window on THIS project).
        var receivedDoc: String?
        var receivedLang: String?
        let token = MaughamEvent.observe(
            .maughamTranslationDidUpdate,
            context: {
                EventReceiverContext(
                    kind: .project(id: h.projectId),
                    isWindowLive: true, isWindowKey: false)
            },
            handler: {
                receivedDoc = $0.userInfo?["document_id"] as? String
                receivedLang = $0.userInfo?["language"] as? String
            })
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": pid, "text": "Primer párrafo."]]
        ])

        XCTAssertEqual(receivedDoc, h.doc.docId,
            "write_translation must announce the affected document")
        XCTAssertEqual(receivedLang, "es",
            "write_translation must announce the affected language")

        await h.documentStore.close()
    }

    // MARK: - Behavior 2a: duplicate ids in batch are rejected atomically

    func test_writeTranslation_duplicateIdsInBatch_rejectedAtomically() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[0]

        do {
            _ = try await call(h, [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "language": "es",
                "entries": [
                    ["paragraph_id": pid, "text": "primera entrada"],
                    ["paragraph_id": pid, "text": "segunda entrada"]
                ]
            ])
            XCTFail("expected invalidArgument for duplicate paragraph ids in batch")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("duplicate paragraph ids in batch"), "got: \(msg)")
            XCTAssertTrue(msg.contains(pid), "message should name the duplicate id: \(msg)")
        }

        // All-or-nothing: nothing appended.
        let records = TranslationStore.loadMerged(
            forDocId: h.doc.docId, language: "es", in: h.projectURL)
        XCTAssertTrue(records.isEmpty, "store must be empty after duplicate-id reject")

        await h.documentStore.close()
    }
}
