import XCTest
@testable import MaughamCore

@MainActor
final class TranslationStoreTests: XCTestCase {
    private var projectURL: URL!
    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: projectURL) }

    func test_filename_template() {
        let url = TranslationStore.fileURL(
            forDocId: "d_chapter-01", language: "es",
            deviceSlug: DeviceSlug.unsafeForTesting("maca-1234"), in: projectURL)
        XCTAssertEqual(url.path,
            projectURL.appendingPathComponent(".maugham/translations/d_chapter-01.es.maca-1234.jsonl").path)
    }

    func test_languageTagValidation() {
        XCTAssertTrue(TranslationRecord.isValidLanguageTag("es"))
        XCTAssertTrue(TranslationRecord.isValidLanguageTag("pt-br"))
        XCTAssertFalse(TranslationRecord.isValidLanguageTag("ES"))
        XCTAssertFalse(TranslationRecord.isValidLanguageTag(""))
        XCTAssertFalse(TranslationRecord.isValidLanguageTag("e"))
        XCTAssertFalse(TranslationRecord.isValidLanguageTag("es_MX"))
    }

    func test_appendAndLoadMerged_roundTrip() async throws {
        let slug = DeviceSlug.unsafeForTesting("maca-1234")
        let rec = TranslationRecord(paragraphId: "aaaa", language: "es",
                                    text: "Hola", sourceHash: "deadbeefdeadbeef",
                                    at: Date(timeIntervalSince1970: 1_753_000_000))
        try await TranslationStore.append(rec, forDocId: "doc1", deviceSlug: slug, in: projectURL)
        let loaded = TranslationStore.loadMerged(forDocId: "doc1", language: "es", in: projectURL)
        XCTAssertEqual(loaded, [rec])
    }

    func test_loadMerged_mergesAcrossDeviceFiles_opIdOrdered_deduped() async throws {
        let a = DeviceSlug.unsafeForTesting("maca-1111")
        let b = DeviceSlug.unsafeForTesting("macb-2222")
        let r1 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "v1", sourceHash: "h1",
                                   at: Date(timeIntervalSince1970: 1_753_000_000))
        let r2 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "v2", sourceHash: "h1",
                                   at: Date(timeIntervalSince1970: 1_753_000_001))
        // ULID.generate() is process-monotonic: r1.opId < r2.opId
        try await TranslationStore.append(r2, forDocId: "doc1", deviceSlug: b, in: projectURL)
        try await TranslationStore.append(r1, forDocId: "doc1", deviceSlug: a, in: projectURL)
        try await TranslationStore.append(r1, forDocId: "doc1", deviceSlug: b, in: projectURL) // duplicate opId
        let loaded = TranslationStore.loadMerged(forDocId: "doc1", language: "es", in: projectURL)
        XCTAssertEqual(loaded.map(\.opId), [r1.opId, r2.opId])
    }

    func test_latestByParagraph_lastOpIdWins_andTombstoneRemoves() {
        let r1 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "old", sourceHash: "h",
                                   at: Date(timeIntervalSince1970: 1_753_000_000))
        let r2 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "new", sourceHash: "h",
                                   at: Date(timeIntervalSince1970: 1_753_000_001))
        let t  = TranslationRecord(paragraphId: "bbbb", language: "es", text: "x", sourceHash: "h",
                                   at: Date(timeIntervalSince1970: 1_753_000_002))
        let tomb = TranslationRecord(paragraphId: "bbbb", language: "es", text: nil, sourceHash: "h",
                                     at: Date(timeIntervalSince1970: 1_753_000_003))
        let latest = TranslationStore.latestByParagraph([r1, r2, t, tomb])
        XCTAssertEqual(latest["aaaa"]?.text, "new")
        XCTAssertNil(latest["bbbb"])
    }

    func test_appendBatch_writesAllRecordsInOneOperation() throws {
        let slug = DeviceSlug.unsafeForTesting("maca-1234")
        let records = (0..<3).map { i in
            TranslationRecord(paragraphId: "aaa\(i)", language: "es", text: "t\(i)", sourceHash: "h",
                              at: Date(timeIntervalSince1970: 1_753_000_000 + TimeInterval(i)))
        }
        try TranslationStore.appendBatch(records, forDocId: "doc1", language: "es",
                                         deviceSlug: slug, in: projectURL)
        let url = TranslationStore.fileURL(forDocId: "doc1", language: "es", deviceSlug: slug, in: projectURL)
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
        let loaded = TranslationStore.loadMerged(forDocId: "doc1", language: "es", in: projectURL)
        XCTAssertEqual(Set(loaded.map(\.paragraphId)), Set(records.map(\.paragraphId)))
    }

    func test_appendBatch_failurePathWritesNothing() throws {
        // Make ".maugham" a FILE, so creating ".maugham/translations"
        // underneath it fails — the write must throw and leave no jsonl file.
        let blockerPath = projectURL.appendingPathComponent(".maugham")
        try Data().write(to: blockerPath)
        let slug = DeviceSlug.unsafeForTesting("maca-1234")
        let records = [TranslationRecord(paragraphId: "aaaa", language: "es", text: "x", sourceHash: "h")]
        XCTAssertThrowsError(
            try TranslationStore.appendBatch(records, forDocId: "doc1", language: "es",
                                             deviceSlug: slug, in: projectURL))
        let url = TranslationStore.fileURL(forDocId: "doc1", language: "es", deviceSlug: slug, in: projectURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_tombstoneRemovesKey_andLaterValueRestoresIt() {
        // Order pinned by construction order: ULID.generate() is process-monotonic,
        // so opId ordering follows call order here, not `at` or array position.
        let value1 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "hola", sourceHash: "h")
        let tombstone = TranslationRecord(paragraphId: "aaaa", language: "es", text: nil, sourceHash: "h")
        let value2 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "hola de nuevo", sourceHash: "h")

        // Value then tombstone (later opId): the key is removed.
        XCTAssertNil(TranslationStore.latestByParagraph([value1, tombstone])["aaaa"])

        // Tombstone then a later value: the value restores the key.
        XCTAssertEqual(TranslationStore.latestByParagraph([tombstone, value2])["aaaa"]?.text, "hola de nuevo")

        // All three, fed out of opId order: last-opId-wins still applies.
        XCTAssertEqual(TranslationStore.latestByParagraph([value2, tombstone, value1])["aaaa"]?.text, "hola de nuevo")
    }

    func test_languages_scansDirectory() async throws {
        let slug = DeviceSlug.unsafeForTesting("maca-1234")
        for (i, lang) in ["es", "fr"].enumerated() {
            try await TranslationStore.append(
                TranslationRecord(paragraphId: "aaaa", language: lang, text: "x", sourceHash: "h",
                                  at: Date(timeIntervalSince1970: 1_753_000_000 + TimeInterval(i))),
                forDocId: "doc1", deviceSlug: slug, in: projectURL)
        }
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc1", in: projectURL).sorted(), ["es", "fr"])
    }
}
