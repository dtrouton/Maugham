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
                                    text: "Hola", sourceHash: "deadbeefdeadbeef")
        try await TranslationStore.append(rec, forDocId: "doc1", deviceSlug: slug, in: projectURL)
        let loaded = TranslationStore.loadMerged(forDocId: "doc1", language: "es", in: projectURL)
        XCTAssertEqual(loaded, [rec])
    }

    func test_loadMerged_mergesAcrossDeviceFiles_opIdOrdered_deduped() async throws {
        let a = DeviceSlug.unsafeForTesting("maca-1111")
        let b = DeviceSlug.unsafeForTesting("macb-2222")
        let r1 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "v1", sourceHash: "h1")
        let r2 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "v2", sourceHash: "h1")
        // ULID.generate() is process-monotonic: r1.opId < r2.opId
        try await TranslationStore.append(r2, forDocId: "doc1", deviceSlug: b, in: projectURL)
        try await TranslationStore.append(r1, forDocId: "doc1", deviceSlug: a, in: projectURL)
        try await TranslationStore.append(r1, forDocId: "doc1", deviceSlug: b, in: projectURL) // duplicate opId
        let loaded = TranslationStore.loadMerged(forDocId: "doc1", language: "es", in: projectURL)
        XCTAssertEqual(loaded.map(\.opId), [r1.opId, r2.opId])
    }

    func test_latestByParagraph_lastOpIdWins_andTombstoneRemoves() {
        let r1 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "old", sourceHash: "h")
        let r2 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "new", sourceHash: "h")
        let t  = TranslationRecord(paragraphId: "bbbb", language: "es", text: "x", sourceHash: "h")
        let tomb = TranslationRecord(paragraphId: "bbbb", language: "es", text: nil, sourceHash: "h")
        let latest = TranslationStore.latestByParagraph([r1, r2, t, tomb])
        XCTAssertEqual(latest["aaaa"]?.text, "new")
        XCTAssertNil(latest["bbbb"])
    }

    func test_languages_scansDirectory() async throws {
        let slug = DeviceSlug.unsafeForTesting("maca-1234")
        for lang in ["es", "fr"] {
            try await TranslationStore.append(
                TranslationRecord(paragraphId: "aaaa", language: lang, text: "x", sourceHash: "h"),
                forDocId: "doc1", deviceSlug: slug, in: projectURL)
        }
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc1", in: projectURL).sorted(), ["es", "fr"])
    }
}
