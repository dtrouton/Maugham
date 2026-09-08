import XCTest
@testable import MaughamCore

@MainActor
final class TranslationStoreTests: XCTestCase {
    private var projectURL: URL!
    /// This device: four actors, four software keys.
    private var mine: LocalIdentities!
    private var myState: OpLogDeviceState!
    /// A second Mac, so "another device's file" means a file signed by a key
    /// this device does not hold — the case the trust set has to get right.
    private var theirs: LocalIdentities!
    private var theirState: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham"), withIntermediateDirectories: true)
        mine = .softwareForTesting()
        myState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("my-state.json"),
            identity: mine.author.fingerprint)
        theirs = .softwareForTesting()
        theirState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("their-state.json"),
            identity: theirs.author.fingerprint)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: projectURL) }

    // MARK: - Fixture

    private func merged(docId: String = "doc1", language: String = "es") -> [TranslationRecord] {
        TranslationStore.loadMerged(
            forDocId: docId, language: language, in: projectURL,
            identities: mine, state: myState)
    }

    /// Every non-blank line of one actor's file.
    private func lines(of identity: DeviceIdentity, docId: String = "doc1",
                       language: String = "es") throws -> [Data] {
        let url = TranslationStore.fileURL(
            forDocId: docId, language: language, deviceSlug: identity.slug, in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Data(contentsOf: url)
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map { Data($0) }
    }

    private func seals(of identity: DeviceIdentity, docId: String = "doc1",
                       language: String = "es") throws -> [OpLogChain.Seal] {
        try lines(of: identity, docId: docId, language: language)
            .compactMap(OpLogChain.Seal.parse)
    }

    private func recordLines(of identity: DeviceIdentity, docId: String = "doc1",
                             language: String = "es") throws -> [Data] {
        try lines(of: identity, docId: docId, language: language)
            .filter { !OpLogChain.isSealLine($0) }
    }

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
        let rec = TranslationRecord(paragraphId: "aaaa", language: "es",
                                    text: "Hola", sourceHash: "deadbeefdeadbeef",
                                    at: Date(timeIntervalSince1970: 1_753_000_000))
        try await TranslationStore.append(rec, forDocId: "doc1", identity: mine.translator,
                                          identities: mine, state: myState, in: projectURL)
        XCTAssertEqual(merged(), [rec])
    }

    func test_loadMerged_mergesAcrossDeviceFiles_opIdOrdered_deduped() async throws {
        let r1 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "v1", sourceHash: "h1",
                                   at: Date(timeIntervalSince1970: 1_753_000_000))
        let r2 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "v2", sourceHash: "h1",
                                   at: Date(timeIntervalSince1970: 1_753_000_001))
        // ULID.generate() is process-monotonic: r1.opId < r2.opId
        try await TranslationStore.append(r2, forDocId: "doc1", identity: mine.translator,
                                          identities: mine, state: myState, in: projectURL)
        try await TranslationStore.append(r1, forDocId: "doc1", identity: theirs.translator,
                                          identities: theirs, state: theirState, in: projectURL)
        // Duplicate opId, into a file that already holds r2.
        try await TranslationStore.append(r1, forDocId: "doc1", identity: mine.translator,
                                          identities: mine, state: myState, in: projectURL)
        XCTAssertEqual(merged().map(\.opId), [r1.opId, r2.opId])
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

    func test_appendBatch_writesAllRecordsInOneOperation() async throws {
        let records = (0..<3).map { i in
            TranslationRecord(paragraphId: "aaa\(i)", language: "es", text: "t\(i)", sourceHash: "h",
                              at: Date(timeIntervalSince1970: 1_753_000_000 + TimeInterval(i)))
        }
        try await TranslationStore.appendBatch(records, forDocId: "doc1", language: "es",
                                               identity: mine.translator, identities: mine,
                                               state: myState, in: projectURL)
        XCTAssertEqual(try recordLines(of: mine.translator).count, 3)
        XCTAssertEqual(try seals(of: mine.translator).count, 1,
                       "one batch, one seal — not one per record")
        XCTAssertEqual(Set(merged().map(\.paragraphId)), Set(records.map(\.paragraphId)))
    }

    func test_appendBatch_failurePathWritesNothing() async throws {
        // Make ".maugham" a FILE, so creating ".maugham/translations"
        // underneath it fails — the write must throw and leave no jsonl file.
        let blockerPath = projectURL.appendingPathComponent(".maugham")
        try? FileManager.default.removeItem(at: blockerPath)
        try Data().write(to: blockerPath)
        let records = [TranslationRecord(paragraphId: "aaaa", language: "es", text: "x", sourceHash: "h")]
        do {
            try await TranslationStore.appendBatch(records, forDocId: "doc1", language: "es",
                                                   identity: mine.translator, identities: mine,
                                                   state: myState, in: projectURL)
            XCTFail("a blocked directory must throw")
        } catch {}
        let url = TranslationStore.fileURL(forDocId: "doc1", language: "es",
                                           deviceSlug: mine.translator.slug, in: projectURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - A tombstone-only batch mints nothing (review I1)

    func test_appendBatch_allTombstonesOnANeverTranslatedLanguage_writesNoFile() async throws {
        // A `write_translation` call carrying only `delete: true` entries for a
        // (doc, language) nobody has translated into: there is nothing for a
        // tombstone to remove, and minting the file would put "es" in
        // `languages()` — and so in translation_status and the review picker —
        // forever, with nothing in it to purge.
        let tombstones = ["aaaa", "bbbb"].map {
            TranslationRecord(paragraphId: $0, language: "es", text: nil, sourceHash: "h")
        }
        try await TranslationStore.appendBatch(tombstones, forDocId: "doc1", language: "es",
                                               identity: mine.translator, identities: mine,
                                               state: myState, in: projectURL)

        let url = TranslationStore.fileURL(forDocId: "doc1", language: "es",
                                           deviceSlug: mine.translator.slug, in: projectURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a delete-only batch must not mint the file")
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc1", in: projectURL), [],
                       "no phantom language in the picker / translation_status")
        XCTAssertTrue(TranslationStore.fileURLs(forDocId: "doc1", language: "es",
                                                in: projectURL).isEmpty)
    }

    func test_appendBatch_allTombstonesWhereTheLanguageHasRecords_appendsNormally() async throws {
        // The Translation Review pane's Remove-orphan case: the language is
        // real, so the tombstones must land.
        try await TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es", text: "Hola", sourceHash: "h")],
            forDocId: "doc1", language: "es", identity: mine.translator,
            identities: mine, state: myState, in: projectURL)
        try await TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es", text: nil, sourceHash: "h")],
            forDocId: "doc1", language: "es", identity: mine.translator,
            identities: mine, state: myState, in: projectURL)

        XCTAssertEqual(try recordLines(of: mine.translator).count, 2,
                       "the tombstone appends to the real language's file")
        XCTAssertTrue(TranslationStore.latestByParagraph(merged()).isEmpty,
                      "and it still removes the paragraph")
    }

    func test_appendBatch_allTombstonesWhereAnotherDeviceHasTheLanguage_writes() async throws {
        // Why the check spans sibling device files rather than only this
        // device's: another device's translation is exactly what this
        // tombstone removes on merge, so it must be recordable.
        try await TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es", text: "Hola", sourceHash: "h")],
            forDocId: "doc1", language: "es", identity: theirs.translator,
            identities: theirs, state: theirState, in: projectURL)
        try await TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es", text: nil, sourceHash: "h")],
            forDocId: "doc1", language: "es", identity: mine.translator,
            identities: mine, state: myState, in: projectURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath:
            TranslationStore.fileURL(forDocId: "doc1", language: "es",
                                     deviceSlug: mine.translator.slug, in: projectURL).path))
        XCTAssertTrue(TranslationStore.latestByParagraph(merged()).isEmpty,
                      "the sibling device's translation is removed")
    }

    func test_appendBatch_oneRealEntryAmongTombstones_writesTheWholeBatch() async throws {
        try await TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es", text: "Hola", sourceHash: "h"),
             TranslationRecord(paragraphId: "bbbb", language: "es", text: nil, sourceHash: "h")],
            forDocId: "doc1", language: "es", identity: mine.translator,
            identities: mine, state: myState, in: projectURL)
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc1", in: projectURL), ["es"])
        XCTAssertEqual(merged().count, 2)
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
        for (i, lang) in ["es", "fr"].enumerated() {
            try await TranslationStore.append(
                TranslationRecord(paragraphId: "aaaa", language: lang, text: "x", sourceHash: "h",
                                  at: Date(timeIntervalSince1970: 1_753_000_000 + TimeInterval(i))),
                forDocId: "doc1", identity: mine.translator, identities: mine,
                state: myState, in: projectURL)
        }
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc1", in: projectURL).sorted(), ["es", "fr"])
    }

    func test_languages_wellFormed_pinsCurrentBehavior() async throws {
        // Step 1 (RED phase): enumerate what should parse correctly today
        // and verify it still parses after the fix.

        let one = mine.translator
        let two = theirs.translator

        // Create files with various docId formats:
        // - simple: "simple.es.maca-1111.jsonl"
        // - dotted: "doc.chapter.en.macb-2222.jsonl"
        // - hyphenated: "my-doc.fr.maca-1111.jsonl"

        let files = [
            ("simple", "es", one),
            ("doc.chapter", "en", two),
            ("my-doc", "fr", one),
            ("a.b.c.d", "de", two),
        ]

        for (docId, lang, identity) in files {
            let rec = TranslationRecord(
                paragraphId: "aaaa", language: lang, text: "x", sourceHash: "h",
                at: Date(timeIntervalSince1970: 1_753_000_000)
            )
            try await TranslationStore.append(rec, forDocId: docId, identity: identity,
                                              identities: mine, state: myState, in: projectURL)
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

        // Create: doc.a.en.<slug1>.jsonl and doc.a.b.en.<slug2>.jsonl
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "aaaa", language: "en", text: "x", sourceHash: "h"),
            forDocId: "doc.a", identity: mine.translator, identities: mine,
            state: myState, in: projectURL
        )
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "bbbb", language: "en", text: "y", sourceHash: "h"),
            forDocId: "doc.a.b", identity: theirs.translator, identities: mine,
            state: myState, in: projectURL
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
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "aaaa", language: "en", text: "x", sourceHash: "h"),
            forDocId: "doc", identity: mine.translator, identities: mine,
            state: myState, in: projectURL
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
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "aaaa", language: "fr", text: "x", sourceHash: "h"),
            forDocId: "doc.en", identity: mine.translator, identities: mine,
            state: myState, in: projectURL)

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
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "aaaa", language: "en", text: "x", sourceHash: "h"),
            forDocId: "doc", identity: mine.translator, identities: mine,
            state: myState, in: projectURL
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
