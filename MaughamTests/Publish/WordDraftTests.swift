import XCTest
import MaughamCore
@testable import Maugham

/// **A Word export is a draft, not a version** (report plan 4, R-4-1, R-4-4;
/// review focus 2): a `.docx` compile never reads or moves `next_version`,
/// takes Draft N from the book's sent copies, is named `{title}-draft{N}.docx`,
/// carries its label in `docProps/custom.xml`, and keeps what it sent under
/// `.maugham/exports/<book>/<export-id>/`. A republish is the same draft
/// re-rendered and writes no sent copy.
@MainActor
final class WordDraftTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = TestTemp.root.appendingPathComponent("WordDraft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
        try await PublishConfigStore(projectURL: tmp)
            .save(PublishConfig(metadata: .init(title: "Word", author: "T")))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture

    /// Two pieces with their op-log paragraphs, as `ProjectStoreASTSource`
    /// hands them over.
    private struct Src: ProjectASTBuilder.Source {
        static let pieces: [(id: String, title: String, paragraphs: [(id: String, text: String)])] = [
            ("p1", "Introduction", [("a1b2", "# Introduction"), ("c3d4", "The first finding.")]),
            ("p2", "Method", [("e5f6", "We asked *everyone*."), ("g7h8", "Twice.")]),
        ]
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            Self.pieces.map { piece in
                .init(pieceID: piece.id, title: piece.title, mode: .prose,
                      displayText: piece.paragraphs.map(\.text).joined(separator: "\n\n"),
                      paragraphs: piece.paragraphs)
            }
        }
    }

    private func orchestrator(gate: PublishMintGate = PublishMintGate(),
                              source: ProjectASTBuilder.Source = Src()) -> CompileOrchestrator {
        CompileOrchestrator(
            projectURL: tmp, astSource: source,
            configStore: PublishConfigStore(projectURL: tmp),
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(), mintGate: gate,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
    }

    private func exportWord(_ orch: CompileOrchestrator? = nil,
                            file: StaticString = #filePath, line: UInt = #line) async throws -> Publication {
        let outcome = try await (orch ?? orchestrator()).compile(format: .docx, label: nil)
        guard case .completed(let pub, _) = outcome else {
            XCTFail("expected a completed Word export, got \(outcome)", file: file, line: line)
            throw XCTSkip("no export")
        }
        return pub
    }

    private var sentCopies: [SentCopyStore.Draft] {
        SentCopyStore(projectURL: tmp).drafts(book: "book")
    }

    private func nextVersion() async throws -> String? {
        try await PublishConfigStore(projectURL: tmp).load()?.nextVersion
    }

    // MARK: - review focus 2: drafts never move the version

    /// Three Word exports, then a PDF: the PDF is still v0.1, the drafts are
    /// 1, 2 and 3, and each file is `{title}-draft{N}.docx`.
    func test_threeWordExportsThenAPDF_thePDFIsV01_andTheDraftsAre1To3() async throws {
        try await TectonicProbe.requireReady()
        let orch = orchestrator()
        var drafts: [Publication] = []
        for _ in 1...3 { drafts.append(try await exportWord(orch)) }

        XCTAssertEqual(drafts.map(\.version), ["draft-1", "draft-2", "draft-3"])
        XCTAssertEqual(drafts.map { ($0.outputPath as NSString).lastPathComponent },
                       ["Word-draft1.docx", "Word-draft2.docx", "Word-draft3.docx"])
        let afterWord = try await nextVersion()
        XCTAssertEqual(afterWord, "0.1", "a Word export never moves next_version")
        XCTAssertEqual(sentCopies.compactMap(\.copy?.draft), [1, 2, 3])

        let pdf = try await orch.compile(format: .pdf, label: nil)
        guard case .completed(let pub, _) = pdf else { return XCTFail("the PDF: \(pdf)") }
        XCTAssertEqual(pub.version, "0.1")
        XCTAssertEqual(pub.format, .pdf)
        let afterPDF = try await nextVersion()
        XCTAssertEqual(afterPDF, "0.2", "the PDF still bumps the book's version")
        XCTAssertEqual(sentCopies.count, 3, "a PDF writes no sent copy")
    }

    /// The same, without tectonic: an EPUB after three Word exports is v0.1.
    func test_threeWordExportsThenAnEPUB_theEPUBIsV01() async throws {
        let orch = orchestrator()
        for _ in 1...3 { _ = try await exportWord(orch) }
        let epub = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let pub, _) = epub else { return XCTFail("the EPUB: \(epub)") }
        XCTAssertEqual(pub.version, "0.1")
        let next = try await nextVersion()
        XCTAssertEqual(next, "0.2")
    }

    /// A Word export mints a draft, so a pinned version means nothing to it
    /// and is refused, minting nothing.
    func test_aPinnedVersionIsRefusedForAWordExport() async throws {
        let outcome = try await orchestrator().compile(format: .docx, label: nil, version: "0.1")
        guard case .failed(_, let excerpt) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(excerpt.hasPrefix("version_for_a_draft"), excerpt)
        XCTAssertTrue(sentCopies.isEmpty)
    }

    // MARK: - concurrency

    /// A draft in flight is held on the mint gate under `(imprint, draft-N,
    /// docx)`, with no language — the number is the book's — and a second
    /// export of it is refused, never handed the same N.
    func test_aDraftInFlightIsRefused_notShared() async throws {
        let gate = PublishMintGate()
        let key = PublishMintGate.Key(version: "draft-1", language: nil, format: .docx, imprint: nil)
        let reserved = await gate.reserve(key)
        XCTAssertTrue(reserved, "premise: this test holds Draft 1")
        let refused = try await orchestrator(gate: gate).compile(format: .docx, label: nil)
        guard case .failed(_, let excerpt) = refused else { return XCTFail("\(refused)") }
        XCTAssertTrue(excerpt.hasPrefix(CompileOrchestrator.mintInFlightLogExcerpt), excerpt)
        XCTAssertTrue(sentCopies.isEmpty, "a refused export writes no sent copy")

        await gate.release(key)
        let pub = try await exportWord(orchestrator(gate: gate))
        XCTAssertEqual(pub.version, "draft-1")
        let held = await gate._inFlightForTesting
        XCTAssertTrue(held.isEmpty, "the export released its draft: \(held)")
    }

    /// A source that, while the plan is built — after the draft is counted
    /// and before it is reserved — lands another export's Draft 1 sent copy:
    /// the window an export that held N, landed and released can slip into.
    private struct LandsADraftWhilePlanning: LanguageRebindableSource {
        let projectURL: URL
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] { Src().orderedPieces() }
        func rebound(toLanguage tag: String?) -> ProjectASTBuilder.Source {
            let folder = SentCopyStore.directory(book: "book", in: projectURL)
                .appendingPathComponent("20261021-120000-another-mac-1a2b3c4d")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? #"{"label":"Draft 1","draft":1,"sentAt":"2026-10-21T12:00:00Z","language":"en","book":"book","pieces":[]}"#
                .write(to: folder.appendingPathComponent("sent.json"), atomically: true, encoding: .utf8)
            return self
        }
    }

    /// **The draft is asked again once it is reserved**: a number another
    /// export landed in the window between the count and the reservation is
    /// refused, never shared — and the next export takes the next number.
    func test_aDraftLandedBetweenTheCountAndTheReservationIsRefused() async throws {
        let gate = PublishMintGate()
        let refused = try await orchestrator(gate: gate, source: LandsADraftWhilePlanning(projectURL: tmp))
            .compile(format: .docx, label: nil)
        guard case .failed(let errors, let excerpt) = refused else {
            return XCTFail("Draft 1 was landed by another export; this one must not take it: \(refused)")
        }
        XCTAssertTrue(excerpt.hasPrefix(CompileOrchestrator.mintInFlightLogExcerpt), excerpt)
        XCTAssertTrue(errors.contains { $0.message.contains("Draft 1") }, "\(errors.map(\.message))")
        XCTAssertEqual(sentCopies.compactMap(\.copy?.draft), [1], "only the other export's Draft 1")
        let held = await gate._inFlightForTesting
        XCTAssertTrue(held.isEmpty, "the refusal released its draft: \(held)")
        let pub = try await exportWord(orchestrator(gate: gate))
        XCTAssertEqual(pub.version, "draft-2")
    }

    /// Concurrent Word exports of one book never share a draft number: each
    /// one either lands a number no other holds or is refused.
    func test_concurrentWordExportsNeverShareADraft() async throws {
        let orch = orchestrator()
        async let a = orch.compile(format: .docx, label: nil)
        async let b = orch.compile(format: .docx, label: nil)
        async let c = orch.compile(format: .docx, label: nil)
        let outcomes = try await [a, b, c]
        let landed = outcomes.compactMap { outcome -> String? in
            if case .completed(let pub, _) = outcome { return pub.version }
            return nil
        }
        XCTAssertFalse(landed.isEmpty, "at least one export lands: \(outcomes)")
        XCTAssertEqual(Set(landed).count, landed.count, "no two exports share a draft: \(landed)")
        let sent = sentCopies.compactMap(\.copy?.draft)
        XCTAssertEqual(sent.count, landed.count, "one sent copy per landed export")
        XCTAssertEqual(Set(sent).count, sent.count, "no two sent copies name one draft: \(sent)")
    }

    // MARK: - the sent copy

    /// `sent.json` holds the label, the draft, when it was sent, the language,
    /// the book and every piece's paragraphs exactly as exported; the folder
    /// holds the `.docx` as it left and nothing else.
    func test_theSentCopyHoldsTheDocxAndEveryParagraphAsExported() async throws {
        let before = Date()
        let pub = try await exportWord()
        let drafts = sentCopies
        XCTAssertEqual(drafts.count, 1)
        let draft = try XCTUnwrap(drafts.first)
        let copy = try XCTUnwrap(draft.copy)

        XCTAssertEqual(copy.draft, 1)
        XCTAssertEqual(copy.book, "book")
        XCTAssertEqual(copy.language, "en")
        XCTAssertEqual(copy.label, "Draft 1, sent " + WordDraft.date(copy.sentAt, language: "en"))
        XCTAssertGreaterThanOrEqual(copy.sentAt.timeIntervalSince1970, before.timeIntervalSince1970.rounded(.down))
        XCTAssertEqual(copy.pieces, Src.pieces.map { piece in
            SentCopyStore.Piece(pieceID: piece.id, title: piece.title,
                                paragraphs: piece.paragraphs.map { .init(id: $0.id, text: $0.text) })
        })

        let slug = DeviceIdentity.author.slug.raw
        XCTAssertNotNil(draft.exportID.range(of: #"^\d{8}-\d{6}-"# + NSRegularExpression.escapedPattern(for: slug) + "$",
                                             options: .regularExpression), draft.exportID)
        let folder = SentCopyStore.directory(book: "book", in: tmp).appendingPathComponent(draft.exportID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["export.docx", "sent.json"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("export.docx")),
                       try Data(contentsOf: tmp.appendingPathComponent(pub.outputPath)),
                       "the sent copy is the file that left")

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("sent.json"))) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["label", "draft", "sentAt", "language", "book", "pieces"])
        let sentAt = try XCTUnwrap(json["sentAt"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: sentAt), "sentAt is ISO 8601: \(sentAt)")
        let piece = try XCTUnwrap((json["pieces"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(piece.keys), ["pieceID", "title", "paragraphs"])
        XCTAssertEqual((piece["paragraphs"] as? [[String: String]])?.first, ["id": "a1b2", "text": "# Introduction"])
    }

    /// In production the paragraphs are the op log's: a real project's sent
    /// copy names each paragraph by its `¶id`.
    func test_aRealProjectsSentCopyNamesItsParagraphsByTheirIds() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "Sent", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let path = try XCTUnwrap(store.manifest.structure.first { $0.path != nil }?.path)
        let docURL = url.appendingPathComponent(path)
        try "The first line.\n\nThe second line.".write(to: docURL, atomically: true, encoding: .utf8)
        let doc = try await Document.load(url: docURL, actor: .author, session: "word", presenter: nil)
        await doc.close()
        try? await PublishStarter.install(into: url, force: false)
        try await PublishConfigStore(projectURL: url)
            .save(PublishConfig(metadata: .init(title: "Sent", author: "T")))

        let orch = CompileOrchestrator(
            projectURL: url, astSource: ProjectStoreASTSource(projectStore: store),
            configStore: PublishConfigStore(projectURL: url),
            publicationStore: PublicationStore(projectURL: url),
            snapshotStore: PublicationSnapshotStore(projectURL: url),
            jobManager: CompileJobManager(), mintGate: PublishMintGate(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        _ = try await exportWord(orch)

        let copy = try XCTUnwrap(SentCopyStore(projectURL: url).drafts(book: "book").first?.copy)
        let paragraphs = copy.pieces.flatMap(\.paragraphs)
        XCTAssertTrue(paragraphs.contains { $0.text == "The first line." }, "\(paragraphs)")
        XCTAssertTrue(paragraphs.contains { $0.text == "The second line." }, "\(paragraphs)")
        XCTAssertTrue(paragraphs.allSatisfy { ParagraphID.parseComment(ParagraphID.formatComment($0.id)) == $0.id },
                      "every paragraph has its ¶id: \(paragraphs)")
    }

    // MARK: - the label in the file

    /// The label goes into `docProps/custom.xml` — `MaughamExportLabel`,
    /// `MaughamDraft` (an i4) and `MaughamBook` — and the file still passes the
    /// structural validator.
    func test_theLabelIsInTheFilesCustomProperties() async throws {
        _ = try await exportWord()
        let pub = try await exportWord()
        let docx = tmp.appendingPathComponent(pub.outputPath)
        XCTAssertEqual(DOCXValidator.problems(in: docx), [])

        let custom = try XMLDocument(xmlString: String(
            decoding: try XCTUnwrap(try ZipArchive.read(docx)["docProps/custom.xml"]), as: UTF8.self))
        let properties = DOCXValidator.elements(custom, "property")
        XCTAssertEqual(properties.compactMap { DOCXValidator.attr($0, "name") },
                       ["MaughamExportLabel", "MaughamDraft", "MaughamBook"])
        let label = try XCTUnwrap(sentCopies.last?.copy?.label)
        XCTAssertTrue(label.hasPrefix("Draft 2, sent "), label)
        XCTAssertEqual(DOCXValidator.elements(properties[0], "vt:lpwstr").first?.stringValue, label)
        XCTAssertEqual(DOCXValidator.elements(properties[1], "vt:i4").first?.stringValue, "2")
        XCTAssertEqual(DOCXValidator.elements(properties[2], "vt:lpwstr").first?.stringValue, "book")
    }

    /// "Draft N, sent <date>" in the book's language: the words from
    /// `ElementWords` (a config word wins), the writer's LOCAL calendar day
    /// (R-S6) in the language's long style, Serbian in Latin script,
    /// `en_US_POSIX` for a tag Foundation can't place.
    func test_theLabelIsInTheBooksLanguage() throws {
        let day = try localDate(hour: 23, minute: 30)
        func label(_ language: String, _ words: PublishConfig.ElementWordsOverride? = nil) -> String {
            WordDraft.Label(draft: 3, sentAt: day, book: "book")
                .text(metadata: .init(language: language, elementWords: words))
        }
        XCTAssertTrue(label("en").hasPrefix("Draft 3, sent "), label("en"))
        XCTAssertTrue(label("en").contains("October 21"), label("en"))
        XCTAssertTrue(label("es").hasPrefix("Borrador 3, enviado "), label("es"))
        XCTAssertTrue(label("es").contains("octubre"), label("es"))
        XCTAssertTrue(label("sr").hasPrefix("Nacrt 3, poslato "), label("sr"))
        XCTAssertTrue(label("sr").contains("oktobar"), "Serbian is written in Latin script: \(label("sr"))")
        XCTAssertTrue(label("de").hasPrefix("Entwurf 3, gesendet 21. Oktober"), label("de"))
        XCTAssertTrue(label("fr").hasPrefix("Brouillon 3, envoyé 21 octobre"), label("fr"))
        XCTAssertTrue(label("it").hasPrefix("Bozza 3, inviata 21 ottobre"), label("it"))
        XCTAssertTrue(label("pt").hasPrefix("Rascunho 3, enviado 21 de outubro"), label("pt"))
        XCTAssertEqual(label("zz"), "Draft 3, sent October 21, 2026", "an unknown tag reads English, POSIX")
        XCTAssertTrue(label("en", .init(draft: "Version", sent: "issued")).hasPrefix("Version 3, issued "))
    }

    /// 21 October 2026 at `hour:minute` on this Mac's own clock.
    private func localDate(hour: Int, minute: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 21, hour: hour, minute: minute)))
    }

    /// R-S6: the label's day is the writer's own, at either edge of it —
    /// never the UTC day, which for a writer away from UTC is often the day
    /// before or after. Pinned in two zones either side of UTC, so the test
    /// can't pass by the machine happening to sit on UTC.
    func test_theLabelsDayIsTheWritersLocalDay() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        for zone in ["America/Los_Angeles", "Asia/Tokyo"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
            for (hour, minute) in [(0, 15), (23, 45)] {
                let date = try localDate(hour: hour, minute: minute)
                XCTAssertEqual(WordDraft.date(date, language: "zz"), "October 21, 2026",
                               "\(zone) \(hour):\(minute)")
            }
        }
    }

    func test_aDraftVersionAndItsFilenameToken() {
        XCTAssertEqual(WordDraft.version(3), "draft-3")
        XCTAssertEqual(WordDraft.number(ofVersion: "draft-3"), 3)
        XCTAssertEqual(WordDraft.number(ofVersion: "draft-12-r1a2b3c4d"), 12)
        XCTAssertNil(WordDraft.number(ofVersion: "0.1"))
        XCTAssertNil(WordDraft.number(ofVersion: "draft-"))
        XCTAssertNil(WordDraft.number(ofVersion: "draft-3x"))
        XCTAssertEqual(WordDraft.filenameToken(forVersion: "draft-3"), "draft3")
        XCTAssertEqual(WordDraft.filenameToken(forVersion: "draft-3-r1a2b3c4d"), "draft3-r1a2b3c4d")
        XCTAssertNil(WordDraft.filenameToken(forVersion: "0.1-r1a2b3c4d"))
        XCTAssertEqual(WordDraft.next(sentCopies: 2, taken: [1, 2]), 3)
        XCTAssertEqual(WordDraft.next(sentCopies: 2, taken: [1, 3]), 4, "a gap never hands out a held number")
        XCTAssertEqual(WordDraft.displayName(ofVersion: "draft-3"), "Draft 3")
        XCTAssertEqual(WordDraft.displayName(ofVersion: "draft-3-r1a2b3c4d"), "Draft 3-r1a2b3c4d")
        XCTAssertNil(WordDraft.displayName(ofVersion: "0.1"))
    }

    /// Every surface that names a publication (the desk's completed line, the
    /// preview's menu) calls a draft "Draft N", never "vdraft-N".
    func test_aDraftIsNamedDraftN_whereAPublicationIsNamed() async throws {
        let pub = try await exportWord()
        XCTAssertTrue(PublishPreviewCentre.label(for: pub).hasPrefix("Draft 1 · "), PublishPreviewCentre.label(for: pub))
        XCTAssertFalse(DepartmentCompileState.completedLine(pub).contains("vdraft"),
                       DepartmentCompileState.completedLine(pub))
    }

    // MARK: - two devices

    /// Two devices exporting the same second write two folders — the slug is
    /// in the name — and the next draft counts both.
    func test_twoDevicesNeverCollide_andTheCountUnionsBoth() async throws {
        let store = SentCopyStore(projectURL: tmp)
        let docx = tmp.appendingPathComponent("stand-in.docx")
        try Data("PK".utf8).write(to: docx)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let copy = SentCopyStore.SentCopy(label: "Draft 1, sent", draft: 1, sentAt: at,
                                          language: "en", book: "book", pieces: [])
        let a = try store.write(copy, docx: docx, device: DeviceSlug.make(from: "mac-A"))
        let b = try store.write(copy, docx: docx, device: DeviceSlug.make(from: "mac-B"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(store.drafts(book: "book").count, 2)
        let again = try store.write(copy, docx: docx, device: DeviceSlug.make(from: "mac-A"))
        XCTAssertEqual(again.lastPathComponent, a.lastPathComponent + "-2",
                       "a second export from one device in one second takes -2, never the first's folder")
        XCTAssertEqual(store.drafts(book: "book").count, 3)

        let pub = try await exportWord()
        XCTAssertEqual(pub.version, "draft-4", "every sent copy counts, both devices': the next is 4")
    }

    /// An imprint counts its own drafts, in its own folder.
    func test_anImprintKeepsItsOwnDrafts() {
        XCTAssertEqual(WordDraft.book(of: PublishConfig()), "book")
        var special = PublishConfig()
        special.imprint = "special"
        XCTAssertEqual(WordDraft.book(of: special), "special")
        XCTAssertEqual(SentCopyStore.directory(book: "special", in: tmp).path,
                       tmp.appendingPathComponent(".maugham/exports/special").path)
    }

    // MARK: - only a successful export is sent

    /// An export that fails (its file's place is taken) or only asks (a dry
    /// run) writes no sent copy and records nothing.
    func test_aFailedOrDryExportWritesNoSentCopy() async throws {
        let dry = try await orchestrator().compile(format: .docx, label: nil, dryRun: true)
        guard case .dryRunPassed = dry else { return XCTFail("\(dry)") }
        XCTAssertTrue(sentCopies.isEmpty, "a dry run mints nothing")

        let exports = tmp.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: exports.appendingPathComponent("Word-draft1.docx"))
        let refused = try await orchestrator().compile(format: .docx, label: nil)
        guard case .failed = refused else { return XCTFail("expected the occupied refusal: \(refused)") }
        XCTAssertTrue(sentCopies.isEmpty, "a failed export writes no sent copy")
        let pubs = try await PublicationStore(projectURL: tmp).load()
        XCTAssertTrue(pubs.isEmpty)
    }

    // MARK: - republish

    /// A Word republish re-renders the same draft under `-r`: it keeps the
    /// draft's label and writes no sent copy.
    func test_aWordRepublishIsTheSameDraft_andWritesNoSentCopy() async throws {
        let pub = try await exportWord()
        let original = try XCTUnwrap(sentCopies.first?.copy)
        let republisher = Republisher(
            projectURL: tmp, astSource: Src(),
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(), mintGate: PublishMintGate(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let outcome = try await republisher.republish(snapshotID: pub.snapshotID, format: .docx, label: nil)
        guard case .completed(let again, _) = outcome else { return XCTFail("\(outcome)") }

        XCTAssertTrue(again.version.hasPrefix("draft-1-r"), again.version)
        XCTAssertEqual(again.republishedFrom, "draft-1")
        XCTAssertTrue((again.outputPath as NSString).lastPathComponent.hasPrefix("Word-draft1-r"), again.outputPath)
        XCTAssertEqual(sentCopies.count, 1, "a republish writes no sent copy")
        let next = try await nextVersion()
        XCTAssertEqual(next, "0.1")

        let custom = try XMLDocument(xmlString: String(decoding: try XCTUnwrap(
            try ZipArchive.read(tmp.appendingPathComponent(again.outputPath))["docProps/custom.xml"]), as: UTF8.self))
        let values = DOCXValidator.elements(custom, "property").map { $0.stringValue }
        XCTAssertEqual(values, [original.label, "1", "book"], "the same draft's label, sent the same day")

        let nextDraft = try await exportWord()
        XCTAssertEqual(nextDraft.version, "draft-2", "the republish took no number")
    }

    /// A draft is a Word export's number: a PDF or EPUB of its snapshot is
    /// refused in a sentence, before anything is minted.
    func test_aPDFOrEPUBRepublishOfADraftIsRefused() async throws {
        let pub = try await exportWord()
        let republisher = Republisher(
            projectURL: tmp, astSource: Src(),
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(), mintGate: PublishMintGate(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        for format in [PublishConfig.Format.pdf, .epub] {
            do {
                _ = try await republisher.republish(snapshotID: pub.snapshotID, format: format, label: nil)
                XCTFail("a \(format) republish of Draft 1 must be refused")
            } catch let error as RepublishError {
                XCTAssertEqual(error.localizedDescription.hasPrefix("Draft 1 is a Word export"), true,
                               error.localizedDescription)
            }
        }
        let pubs = try await PublicationStore(projectURL: tmp).load()
        XCTAssertEqual(pubs.map(\.version), ["draft-1"], "nothing minted")
    }

    /// Only a format that mints drafts is named as one.
    func test_aDraftVersionIsNamedAsADraftOnlyInWord() {
        var config = PublishConfig(metadata: .init(title: "Word"))
        config.nextVersion = "draft-1-rabc"
        XCTAssertEqual(OutputFilenameBuilder.make(config: config, format: .docx, label: nil, language: nil),
                       "Word-draft1-rabc.docx")
        XCTAssertFalse(OutputFilenameBuilder.make(config: config, format: .pdf, label: nil, language: nil)
            .contains("draft1"))
    }

    // MARK: - nothing is kept of an export that didn't land

    /// If the snapshot can't be saved after the sent copy is written, the sent
    /// copy and the file go with the failure, and Draft 1 is free again.
    func test_aFailureAfterTheSentCopyGivesBackTheDraft() async throws {
        let blocked = tmp.appendingPathComponent("not-a-folder")
        try Data("a file where the snapshots folder would go".utf8).write(to: blocked)
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: PublishConfigStore(projectURL: tmp),
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: blocked),
            jobManager: CompileJobManager(), mintGate: PublishMintGate(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let outcome = try? await orch.compile(format: .docx, label: nil)
        if case .completed? = outcome { return XCTFail("the snapshot save must fail: \(String(describing: outcome))") }
        XCTAssertTrue(sentCopies.isEmpty, "the sent copy went with the failure")
        let exported = (try? FileManager.default.contentsOfDirectory(
            atPath: tmp.appendingPathComponent("Exports").path)) ?? []
        XCTAssertFalse(exported.contains("Word-draft1.docx"), "and so did the file: \(exported)")

        let pub = try await exportWord()
        XCTAssertEqual(pub.version, "draft-1", "Draft 1 was never burned")
    }

    /// A write sweeps staging folders a crash left behind, and only those
    /// older than ten minutes.
    func test_aWriteSweepsStaleStagingOnly() throws {
        let book = SentCopyStore.directory(book: "book", in: tmp)
        let stale = book.appendingPathComponent(".staging-old")
        let fresh = book.appendingPathComponent(".staging-new")
        for folder in [stale, fresh] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-11 * 60)], ofItemAtPath: stale.path)
        SentCopyStore.sweepStaleStaging(in: book)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a crash's staging is swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "an export in progress is not")
    }
}
