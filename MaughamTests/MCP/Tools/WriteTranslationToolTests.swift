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

    private func makeHarness(
        body: String = "First paragraph with **bold** word.\n\nSecond paragraph plain."
    ) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WTT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        try body
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

    // MARK: - M1 write: the delete form

    /// The tombstone path becomes reachable: `delete: true` persists a
    /// `text: nil` record and the derived read stops reporting a translation
    /// for that paragraph. The paragraph is still live, so nothing is orphaned.
    func test_deleteEntryWritesATombstone_andDerivationDropsTheKey() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[0]

        _ = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": pid, "text": "Primer párrafo con **negrita**."]]
        ])

        let deleteResultData = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": pid, "delete": true]]
        ])
        let deleteResult = try JSONDecoder().decode(
            WriteTranslationTool.Result.self, from: deleteResultData)
        XCTAssertEqual(deleteResult.written, 1)
        XCTAssertTrue(deleteResult.warnings.isEmpty,
                      "a delete has no text to advise on: \(deleteResult.warnings)")

        // Both records survive on disk (append-only); the tombstone is last.
        let records = TranslationStore.loadMerged(
            forDocId: h.doc.docId, language: "es", in: h.projectURL)
        XCTAssertEqual(records.count, 2, "append-only: the tombstone joins the value")
        XCTAssertNil(records.last?.text, "the delete entry persists text: nil")
        XCTAssertNil(TranslationStore.latestByParagraph(records)[pid],
                     "the tombstone removes the key")

        // And the read surface agrees: untranslated, not orphaned.
        let readData = try await ReadTranslationTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "language": "es"
            ]), registry: h.registry)
        let read = try JSONDecoder().decode(ReadTranslationTool.Result.self, from: readData)
        let entry = read.entries.first { $0.paragraph_id == pid }
        XCTAssertEqual(entry?.status, "missing", "a tombstoned paragraph reads as untranslated")
        XCTAssertNil(entry?.translated_text)
        XCTAssertEqual(read.orphan_count, 0,
                       "the paragraph is still in the manuscript — nothing is orphaned")

        await h.documentStore.close()
    }

    /// The unknown-id rule bends for delete and only for delete: an orphan
    /// names a paragraph that no longer exists, so a delete entry is exempt —
    /// but a *text* entry's unknown id still rejects the whole batch, delete
    /// siblings included.
    func test_deleteOfUnknownOrOrphanedIdIsAccepted() async throws {
        let h = try await makeHarness()
        let livePid = h.doc.sequence[0]

        // Exempt: an id absent from the document. The call is ACCEPTED and
        // reports the entry written — but for a language nothing has ever been
        // translated into, acceptance costs no file: a tombstones-only sidecar
        // would put "es" in `languages()`, and so in translation_status and the
        // Translation Review picker, permanently, with nothing in it to purge
        // (review I1).
        let resultData = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": "zzzz", "delete": true]]
        ])
        let result = try JSONDecoder().decode(
            WriteTranslationTool.Result.self, from: resultData)
        XCTAssertEqual(result.written, 1, "deleting an orphaned id is legal")

        var records = TranslationStore.loadMerged(
            forDocId: h.doc.docId, language: "es", in: h.projectURL)
        XCTAssertTrue(records.isEmpty, "nothing to remove, so nothing recorded")
        XCTAssertTrue(
            TranslationStore.fileURLs(
                forDocId: h.doc.docId, language: "es", in: h.projectURL).isEmpty,
            "no tombstones-only file")
        XCTAssertFalse(
            TranslationStore.languages(forDocId: h.doc.docId, in: h.projectURL).contains("es"),
            "and so no phantom language")

        // Once the language is real, the same delete form tombstones for real —
        // and repeating it is idempotent in the derived state.
        _ = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": livePid, "text": "vivo"]]
        ])
        for _ in 0..<2 {
            _ = try await call(h, [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "language": "es",
                "entries": [["paragraph_id": livePid, "delete": true]]
            ])
        }
        records = TranslationStore.loadMerged(
            forDocId: h.doc.docId, language: "es", in: h.projectURL)
        XCTAssertEqual(records.count, 3, "the value plus both tombstones are on disk")
        XCTAssertTrue(TranslationStore.latestByParagraph(records).isEmpty,
                      "a repeated tombstone is still a tombstone")

        // Not exempt: a text entry's unknown id takes its delete sibling down
        // with it — the whole batch is rejected.
        do {
            _ = try await call(h, [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "language": "fr",
                "entries": [
                    ["paragraph_id": livePid, "text": "vivant"],
                    ["paragraph_id": "wwww", "text": "inconnu"],
                    ["paragraph_id": "yyyy", "delete": true]
                ]
            ])
            XCTFail("expected invalidArgument for the unknown id on a text entry")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("wwww"), "message should name the text entry's id: \(msg)")
            XCTAssertFalse(msg.contains("yyyy"),
                           "a delete entry's id is exempt from the unknown-id check: \(msg)")
        }
        XCTAssertTrue(
            TranslationStore.loadMerged(
                forDocId: h.doc.docId, language: "fr", in: h.projectURL).isEmpty,
            "all-or-nothing includes the batch's delete entries")

        await h.documentStore.close()
    }

    /// Exactly one of `{text, verbatim: true, delete: true}` — the two-way
    /// exclusivity check became three-way.
    func test_entryMustBeExactlyOneOfTextVerbatimDelete() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[0]

        let badEntries: [[String: Any]] = [
            ["paragraph_id": pid, "text": "x", "delete": true],
            ["paragraph_id": pid, "verbatim": true, "delete": true],
            ["paragraph_id": pid, "text": "x", "verbatim": true, "delete": true],
            ["paragraph_id": pid]
        ]
        for entry in badEntries {
            do {
                _ = try await call(h, [
                    "project_id": h.projectId,
                    "document_id": h.doc.docId,
                    "language": "es",
                    "entries": [entry]
                ])
                XCTFail("expected invalidArgument for entry \(entry)")
            } catch let MCPError.invalidArgument(msg) {
                XCTAssertTrue(msg.contains(pid), "message should name the paragraph: \(msg)")
            }
        }

        // `delete: false` is not a delete — it leaves the entry with nothing.
        do {
            _ = try await call(h, [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "language": "es",
                "entries": [["paragraph_id": pid, "delete": false]]
            ])
            XCTFail("expected invalidArgument for delete: false with no other form")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains(pid), "got: \(msg)")
        }

        XCTAssertTrue(
            TranslationStore.loadMerged(
                forDocId: h.doc.docId, language: "es", in: h.projectURL).isEmpty,
            "no rejected entry wrote anything")

        await h.documentStore.close()
    }

    // MARK: - T1: the batch is one write

    /// Structural: the write builds every record first and persists them in a
    /// single `appendBatch` call, so "nothing is written" holds for an I/O
    /// failure and not only for a validation failure. The behavioural half
    /// (one device file, one line per entry) can't tell one write from three,
    /// so the call shape is pinned at the source by
    /// `TripwireGrepTests.test_theTranslationWritePipelineIsTheOnlyPlaceAWriteBatchIsAppended`
    /// — which supersedes the file-scoped census that used to sit here: it
    /// scans all of `Maugham/` rather than one file, so it survives the write
    /// path moving into `TranslationWritePipeline` and catches a second
    /// pipeline anywhere.
    func test_midBatchFailureWritesNothing() async throws {
        let h = try await makeHarness()
        let ids = h.doc.sequence

        _ = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [
                ["paragraph_id": ids[0], "text": "Primer párrafo con **negrita**."],
                ["paragraph_id": ids[1], "text": "Segundo párrafo simple."],
                ["paragraph_id": "zzzz", "delete": true]
            ]
        ])

        let files = TranslationStore.fileURLs(
            forDocId: h.doc.docId, language: "es", in: h.projectURL)
        XCTAssertEqual(files.count, 1, "one device file for the batch")
        let lines = try String(contentsOf: files[0], encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3, "one JSONL line per entry, mixed forms included")

        await h.documentStore.close()
    }

    // MARK: - T2: the equals-source advisory sees the display form

    /// The advisory compares against the source normalized the way the
    /// freshness hash normalizes it. Before T2 it compared the raw source, so
    /// on an anchored paragraph — a slugline or a numeral, exactly the lines
    /// the advisory exists for — it could never fire.
    func test_verbatimAdvisoryFiresOnAnchoredParagraph() async throws {
        let h = try await makeHarness(
            body: "Ten pounds <!--t-a1b2c3--> and no more.\n\nSecond paragraph plain.")
        let pid = h.doc.sequence[0]
        let source = h.doc.paragraphs[pid]!
        XCTAssertTrue(source.contains("<!--t-a1b2c3-->"),
                      "the fixture must reach the tool still carrying its task anchor: \(source)")
        let display = MarkdownDisplayFilter.stripAnchors(source)
        XCTAssertNotEqual(display, source, "the anchor is what the raw comparison tripped over")

        let resultData = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": pid, "text": display]]
        ])
        let result = try JSONDecoder().decode(
            WriteTranslationTool.Result.self, from: resultData)
        XCTAssertEqual(result.written, 1, "the advisory never blocks the write")
        XCTAssertTrue(
            result.warnings.contains(
                "¶\(pid): translated text equals source — mark verbatim: true if deliberate"),
            "a verbatim copy of an anchored paragraph must be advised: \(result.warnings)")

        await h.documentStore.close()
    }

    func test_advisoryStillSilentForAGenuineTranslationOfAnAnchoredParagraph() async throws {
        let h = try await makeHarness(
            body: "Ten pounds <!--t-a1b2c3--> and no more.\n\nSecond paragraph plain.")
        let pid = h.doc.sequence[0]

        let resultData = try await call(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": [["paragraph_id": pid, "text": "Diez libras y no más."]]
        ])
        let result = try JSONDecoder().decode(
            WriteTranslationTool.Result.self, from: resultData)
        XCTAssertTrue(result.warnings.isEmpty,
                      "normalizing the source must not make every anchored paragraph warn: " +
                      "\(result.warnings)")

        await h.documentStore.close()
    }
}
