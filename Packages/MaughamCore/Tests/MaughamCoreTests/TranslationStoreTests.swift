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

    // MARK: - A tombstone-only batch mints nothing (review I1)

    func test_appendBatch_allTombstonesOnANeverTranslatedLanguage_writesNoFile() throws {
        // A `write_translation` call carrying only `delete: true` entries for a
        // (doc, language) nobody has translated into: there is nothing for a
        // tombstone to remove, and minting the file would put "es" in
        // `languages()` — and so in translation_status and the review picker —
        // forever, with nothing in it to purge.
        let slug = DeviceSlug.unsafeForTesting("maca-1234")
        let tombstones = ["aaaa", "bbbb"].map {
            TranslationRecord(paragraphId: $0, language: "es", text: nil, sourceHash: "h")
        }
        try TranslationStore.appendBatch(tombstones, forDocId: "doc1", language: "es",
                                         deviceSlug: slug, in: projectURL)

        let url = TranslationStore.fileURL(forDocId: "doc1", language: "es",
                                           deviceSlug: slug, in: projectURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a delete-only batch must not mint the file")
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc1", in: projectURL), [],
                       "no phantom language in the picker / translation_status")
        XCTAssertTrue(TranslationStore.fileURLs(forDocId: "doc1", language: "es",
                                                in: projectURL).isEmpty)
    }

    func test_appendBatch_allTombstonesWhereTheLanguageHasRecords_appendsNormally() throws {
        // The Translation Review pane's Remove-orphan case: the language is
        // real, so the tombstones must land.
        let slug = DeviceSlug.unsafeForTesting("maca-1234")
        try TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es", text: "Hola", sourceHash: "h")],
            forDocId: "doc1", language: "es", deviceSlug: slug, in: projectURL)
        try TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es", text: nil, sourceHash: "h")],
            forDocId: "doc1", language: "es", deviceSlug: slug, in: projectURL)

        let url = TranslationStore.fileURL(forDocId: "doc1", language: "es",
                                           deviceSlug: slug, in: projectURL)
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "the tombstone appends to the real language's file")
        let loaded = TranslationStore.loadMerged(forDocId: "doc1", language: "es", in: projectURL)
        XCTAssertTrue(TranslationStore.latestByParagraph(loaded).isEmpty,
                      "and it still removes the paragraph")
    }

    func test_appendBatch_allTombstonesWhereAnotherDeviceHasTheLanguage_writes() throws {
        // Why the check spans sibling device files rather than only this
        // device's: another device's translation is exactly what this
        // tombstone removes on merge, so it must be recordable.
        let other = DeviceSlug.unsafeForTesting("macb-2222")
        let mine = DeviceSlug.unsafeForTesting("maca-1111")
        try TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es", text: "Hola", sourceHash: "h")],
            forDocId: "doc1", language: "es", deviceSlug: other, in: projectURL)
        try TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es", text: nil, sourceHash: "h")],
            forDocId: "doc1", language: "es", deviceSlug: mine, in: projectURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath:
            TranslationStore.fileURL(forDocId: "doc1", language: "es",
                                     deviceSlug: mine, in: projectURL).path))
        let loaded = TranslationStore.loadMerged(forDocId: "doc1", language: "es", in: projectURL)
        XCTAssertTrue(TranslationStore.latestByParagraph(loaded).isEmpty,
                      "the sibling device's translation is removed")
    }

    func test_appendBatch_oneRealEntryAmongTombstones_writesTheWholeBatch() throws {
        let slug = DeviceSlug.unsafeForTesting("maca-1234")
        try TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es", text: "Hola", sourceHash: "h"),
             TranslationRecord(paragraphId: "bbbb", language: "es", text: nil, sourceHash: "h")],
            forDocId: "doc1", language: "es", deviceSlug: slug, in: projectURL)
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc1", in: projectURL), ["es"])
        XCTAssertEqual(
            TranslationStore.loadMerged(forDocId: "doc1", language: "es", in: projectURL).count, 2)
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

    func test_languages_wellFormed_pinsCurrentBehavior() async throws {
        // Step 1 (RED phase): enumerate what should parse correctly today
        // and verify it still parses after the fix.

        let slug1 = DeviceSlug.unsafeForTesting("maca-1111")
        let slug2 = DeviceSlug.unsafeForTesting("macb-2222")

        // Create files with various docId formats:
        // - simple: "simple.es.maca-1111.jsonl"
        // - dotted: "doc.chapter.en.macb-2222.jsonl"
        // - hyphenated: "my-doc.fr.maca-1111.jsonl"

        let files = [
            ("simple", "es", slug1),
            ("doc.chapter", "en", slug2),
            ("my-doc", "fr", slug1),
            ("a.b.c.d", "de", slug2),
        ]

        for (docId, lang, slug) in files {
            let rec = TranslationRecord(
                paragraphId: "aaaa", language: lang, text: "x", sourceHash: "h",
                at: Date(timeIntervalSince1970: 1_753_000_000)
            )
            try await TranslationStore.append(rec, forDocId: docId, deviceSlug: slug, in: projectURL)
        }

        // Verify each docId finds exactly its own language
        XCTAssertEqual(TranslationStore.languages(forDocId: "simple", in: projectURL), ["es"])
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc.chapter", in: projectURL), ["en"])
        XCTAssertEqual(TranslationStore.languages(forDocId: "my-doc", in: projectURL), ["fr"])
        XCTAssertEqual(TranslationStore.languages(forDocId: "a.b.c.d", in: projectURL), ["de"])
    }

    func test_languages_dottedPrefixDocIds_noCrossMatch() async throws {
        // Step 1 (RED phase): docId that is a dotted prefix of another
        // should not cross-match. This is the main bug the fix addresses.

        let slug1 = DeviceSlug.unsafeForTesting("maca-1111")
        let slug2 = DeviceSlug.unsafeForTesting("macb-2222")

        // Create: doc.a.en.maca-1111.jsonl and doc.a.b.en.macb-2222.jsonl
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "aaaa", language: "en", text: "x", sourceHash: "h"),
            forDocId: "doc.a", deviceSlug: slug1, in: projectURL
        )
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "bbbb", language: "en", text: "y", sourceHash: "h"),
            forDocId: "doc.a.b", deviceSlug: slug2, in: projectURL
        )

        // Query for "doc.a" should find only the first file
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc.a", in: projectURL), ["en"])

        // Query for "doc.a.b" should find only the second file
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc.a.b", in: projectURL), ["en"])

        // Query for non-existent "doc" should find nothing
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc", in: projectURL), [])
    }

    func test_languages_wrongComponentCounts_skipped() async throws {
        // Step 1 (RED phase): files with wrong component counts should be skipped.

        let dir = TranslationStore.directoryURL(in: projectURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Create a valid file first
        let slug = DeviceSlug.unsafeForTesting("maca-1111")
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "aaaa", language: "en", text: "x", sourceHash: "h"),
            forDocId: "doc", deviceSlug: slug, in: projectURL
        )

        // Now manually create malformed files in the directory
        let malformedFiles = [
            "doc.jsonl",                    // Too few components (missing language and slug)
            "doc.en.jsonl",                 // Too few components (missing slug)
            "doc.en.slug.extra.jsonl",      // Reconstructs to docId "doc.en", not "doc"
            "doc.en.slug",                  // Missing .jsonl extension
            "doc..en.slug.jsonl",           // Empty component
        ]

        for filename in malformedFiles {
            try Data().write(to: dir.appendingPathComponent(filename))
        }

        // Should still find only the valid "en" language
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc", in: projectURL), ["en"])
    }

    func test_fileURLs_dottedPrefixDocIds_noCrossMatch() async throws {
        // `fileURLs` shares `languages`' parse now, so the dotted-prefix
        // cross-match its old positional prefix match allowed is closed: a file
        // for docId "doc.en" is not a file for docId "doc" in language "en".
        let slug = DeviceSlug.unsafeForTesting("maca-1111")
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "aaaa", language: "fr", text: "x", sourceHash: "h"),
            forDocId: "doc.en", deviceSlug: slug, in: projectURL)

        XCTAssertTrue(
            TranslationStore.fileURLs(forDocId: "doc", language: "en", in: projectURL).isEmpty,
            "\"doc.en.fr.<slug>.jsonl\" belongs to docId doc.en, not to doc/en")
        XCTAssertEqual(
            TranslationStore.fileURLs(forDocId: "doc.en", language: "fr", in: projectURL).count, 1)
    }

    func test_languages_invalidLanguageTag_skipped() async throws {
        // Step 1 (RED phase): files with invalid language tags should be skipped.

        let dir = TranslationStore.directoryURL(in: projectURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Create a valid file
        let slug = DeviceSlug.unsafeForTesting("maca-1111")
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "aaaa", language: "en", text: "x", sourceHash: "h"),
            forDocId: "doc", deviceSlug: slug, in: projectURL
        )

        // Manually create files with invalid language tags
        let invalidFiles = [
            "doc.EN.maca-1111.jsonl",       // Uppercase (invalid)
            "doc.e.maca-1111.jsonl",        // Too short (invalid)
            "doc.123.maca-1111.jsonl",      // Numeric (invalid)
            "doc..maca-1111.jsonl",         // Empty language (invalid)
        ]

        for filename in invalidFiles {
            try Data().write(to: dir.appendingPathComponent(filename))
        }

        // Should still find only the valid "en" language
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc", in: projectURL), ["en"])
    }
}
