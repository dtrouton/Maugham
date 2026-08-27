import XCTest
import MaughamCore
@testable import Maugham

/// **One chapter Maugham cannot read must not cost the writer the whole
/// department** (issue #43, F-D).
///
/// `EditionStatus.languageRows` opens every manuscript document — the cost of
/// P2's query widening, which made the open-query half of the union a fact
/// about every chapter rather than only the translated ones. Before this
/// milestone that open was on the outside of nothing: one document whose op log
/// was present and unreadable threw out of the whole walk, and both readers
/// answered with a falsehood — the desk kept whatever it last derived (on a
/// first mount, "No translations yet." over a book with four editions) and
/// `translation_status` escaped a raw `OpLogStore.ReadError`.
///
/// The rows a failed document would have contributed are genuinely missing, and
/// that is what `Report.unreadable` is for: the walk degrades, names the
/// chapter, and goes on. Every test here has a control, because a degrade path
/// that is never compared against the healthy answer cannot tell you whether it
/// degraded too much.
@MainActor
final class EditionStatusTests: XCTestCase {

    // MARK: - The degrade

    /// The load-bearing one: two chapters, both with a Spanish file, one of them
    /// unreadable. The readable chapter's coverage is intact, the unreadable one
    /// is named with the failure's own sentence, and the call answers.
    ///
    /// The disable experiment: put the per-document reads back outside a `do`
    /// and this test cannot even run its assertions — `languageRows` throws
    /// before it returns anything at all.
    func test_oneUnreadableChapterDegradesToANamedSkipAndTheRestOfTheBookIsComplete()
        async throws {
        let h = try await makeProject()
        try Self.squatTheOpLog(ofDocId: h.doc2Id, in: h.projectURL)

        let report = await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL)

        XCTAssertEqual(report.rows.map(\.language), ["es"],
                       "the book's one edition is still on the desk")
        let es = try XCTUnwrap(report.rows.first)
        XCTAssertEqual(es.fresh, 1, "chapter 1's translated paragraph")
        XCTAssertEqual(es.missing, 1, "…and its untranslated one")

        XCTAssertEqual(report.unreadable.map(\.documentId), ["doc-2"])
        let skipped = try XCTUnwrap(report.unreadable.first)
        XCTAssertEqual(skipped.title, "Chapter 2",
                       "named as the writer's own tree names it, never by id")
        XCTAssertFalse(skipped.reason.isEmpty,
                       "a skip with no reason on it is a silent skip with a "
                       + "label")

        await h.documentStore.close()
    }

    /// The control: the same fixture with nothing squatted. Both chapters
    /// contribute, and the report says nothing was skipped — so the assertions
    /// above are about the squat rather than about the fixture.
    func test_aReadableBookReportsNothingUnreadable() async throws {
        let h = try await makeProject()

        let report = await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL)

        XCTAssertEqual(report.unreadable, [],
                       "nothing failed, so nothing is named")
        let es = try XCTUnwrap(report.rows.first { $0.language == "es" })
        XCTAssertEqual(es.fresh, 2, "one translated paragraph in each chapter")
        XCTAssertEqual(es.missing, 1, "chapter 1's second paragraph")

        await h.documentStore.close()
    }

    /// **A book whose every chapter is unreadable still shows the editions it
    /// has named**, because the fold's manifest arm is a fact about the project
    /// rather than about any document — and "no editions" over a book with a
    /// named translator is exactly the false claim F-D exists to stop.
    func test_everyChapterUnreadableStillShowsAStoredTranslatorsEdition()
        async throws {
        let h = try await makeProject()
        let minted = try await h.projectStore.translatorRole(for: "pt-br")
        try await h.projectStore.renameProductionRole(id: minted.id, to: "Ana")
        try Self.squatTheOpLog(ofDocId: h.doc1Id, in: h.projectURL)
        try Self.squatTheOpLog(ofDocId: h.doc2Id, in: h.projectURL)
        // Chapter 1 is open in the editor, and an open document is read from
        // memory — squatting its op log cannot make it fail. Closing it is what
        // puts BOTH chapters on the transient-load path this test is about.
        await h.doc1.close()
        h.documentStore.unregister(path: h.path1)

        let report = await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL)

        XCTAssertEqual(report.unreadable.map(\.documentId).sorted(),
                       ["doc-1", "doc-2"])
        XCTAssertEqual(report.rows.map(\.language), ["pt-br"],
                       "the edition the writer named survives a book nothing "
                       + "could be read from")
        XCTAssertEqual(report.rows.first?.translator, "Ana")

        await h.documentStore.close()
    }

    /// **A named chapter with an unusable reason is the labelled silent skip
    /// this degrade exists to replace** (issue #43, whole-branch review).
    ///
    /// A manifest `.document` row with **no path** is the second error class
    /// F-D degrades — `withAnnotationDocument` throws `MCPError.invalidArgument`
    /// for it — and `MCPError` conforms to `Error`, not `LocalizedError`. So a
    /// bare `localizedDescription` renders it as Foundation's fallback, "The
    /// operation couldn't be completed. (Maugham.MCPError error 3.)": a
    /// sentence naming a chapter the writer is told to repair while saying
    /// nothing whatever about what is wrong with it.
    ///
    /// The disable experiment: drop the `(error as? MCPError)?.message` arm in
    /// `documentRows` and the first assertion fails with that exact string.
    func test_aPathlessChapterDegradesWithAReasonTheWriterCanActOn() async throws {
        let h = try await makeProject(pathlessThirdChapter: true)

        let report = await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL)

        let skipped = try XCTUnwrap(report.unreadable.first { $0.documentId == "doc-3" })
        XCTAssertEqual(skipped.title, "Chapter 3")
        XCTAssertFalse(
            skipped.reason.localizedCaseInsensitiveContains("operation couldn't be completed"),
            "Foundation's fallback for a non-LocalizedError says nothing the "
            + "writer can act on; got \(skipped.reason.debugDescription)")
        XCTAssertEqual(skipped.reason, MCPError.invalidArgument(
            "document_id not found in project manifest: doc-3").message,
            "the reason must be MCPError's own message")

        // The control: the rest of the book is untouched by the degrade.
        XCTAssertEqual(report.unreadable.map(\.documentId), ["doc-3"])
        let es = try XCTUnwrap(report.rows.first { $0.language == "es" })
        XCTAssertEqual(es.fresh, 2, "both readable chapters still counted")

        await h.documentStore.close()
    }

    // MARK: - The fixture

    /// Two manuscript chapters, both with one Spanish paragraph written.
    /// **Chapter 2 is CLOSED** (loaded to mint its op log, then closed and
    /// unregistered), because an open document is read out of memory and a
    /// squatted op log would never be touched — the transient load is the only
    /// path a bad file is on.
    private struct Fixture {
        let projectURL: URL
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let path1: String
        let doc1: Document
        let doc1Id: String
        let doc2Id: String
    }

    /// `pathlessThirdChapter` adds a manifest `.document` row carrying **no
    /// path** — the second thing F-D degrades, and the one the fixture can
    /// express directly because `StructureItem.path` is `String?` with a `nil`
    /// default. It needs no file and no op log: the failure is that there is
    /// nowhere to load it from.
    private func makeProject(
        pathlessThirdChapter: Bool = false
    ) async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EST-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let path1 = "manuscript/c1.md"
        let path2 = "manuscript/c2.md"
        try "Doc one first.\n\nDoc one second."
            .write(to: tmp.appendingPathComponent(path1), atomically: true, encoding: .utf8)
        try "Doc two only."
            .write(to: tmp.appendingPathComponent(path2), atomically: true, encoding: .utf8)

        let manifest = ProjectManifest(
            type: .novel, title: "The Project", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-1", title: "Chapter 1", type: .document, path: path1),
                StructureItem(id: "doc-2", title: "Chapter 2", type: .document, path: path2),
            ] + (pathlessThirdChapter
                 ? [StructureItem(id: "doc-3", title: "Chapter 3", type: .document)]
                 : []),
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let projectStore = try await ProjectStore.load(from: tmp)
        let documentStore = try await DocumentStore.open(url: tmp)
        projectStore.documentStore = documentStore

        let doc1 = try await Document.load(
            url: tmp.appendingPathComponent(path1),
            device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc1, for: path1)
        let doc2 = try await Document.load(
            url: tmp.appendingPathComponent(path2),
            device: "test", session: "s", presenter: nil)

        try await Self.seed(doc: doc1, paragraphId: doc1.sequence[0],
                            language: "es", text: "uno", in: tmp)
        try await Self.seed(doc: doc2, paragraphId: doc2.sequence[0],
                            language: "es", text: "dos", in: tmp)

        let doc2Id = doc2.docId
        await doc2.close()

        return Fixture(projectURL: tmp, projectStore: projectStore,
                       documentStore: documentStore, path1: path1,
                       doc1: doc1, doc1Id: doc1.docId, doc2Id: doc2Id)
    }

    private static func seed(doc: Document, paragraphId: String,
                             language: String, text: String, in projectURL: URL) async throws {
        let source = doc.paragraphs[paragraphId] ?? ""
        try await TranslationStore.append(
            TranslationRecord(paragraphId: paragraphId, language: language, text: text,
                              sourceHash: TranslationHash.hash(source), verbatim: false),
            forDocId: doc.docId,
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
            in: projectURL)
    }

    /// **A DIRECTORY where an op-log file goes** — `ReadOnlyRecoveryTests`'
    /// primitive, and the one way to make a load refuse over a file that is
    /// unmistakably present. A missing `.md` does not do it: `Document.load`
    /// bootstraps an empty manuscript from one.
    private static func squatTheOpLog(ofDocId docId: String, in projectURL: URL) throws {
        let squat = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: DeviceSlug.make(from: "bad"), in: projectURL)
        try FileManager.default.createDirectory(at: squat, withIntermediateDirectories: true)
    }
}
