import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 3, Task 1 — `BriefReader`: what a Brief scope holds, read from
/// statements and the manifest on a real project whose pieces are closed.
/// Review Focus 2: nothing here loads a manuscript.
@MainActor
final class BriefReaderTests: XCTestCase {

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400) }

    private func ruling(_ text: String, on day: Int?) -> Ruling {
        // A provenance, because `RulingsSection` writes a date with none in a
        // form its parser reads back as undated.
        Ruling(id: "", text: text, ruledOn: day.map(self.day), provenance: "fixture")
    }

    private struct Fixture {
        let root: URL
        let store: ProjectStore
        let ds: DocumentStore
    }

    /// A novel: Part One (`doc-a` with a synopsis, `doc-b` with none) and
    /// `doc-c`. Every piece is closed. Statements, written through the store's
    /// own seam: the book's intent, `doc-a`'s and `doc-b`'s intents, the
    /// lessons ledger (one lesson retired), the first reader and the `es`
    /// edition brief — each with dated rulings.
    private func makeFixture() async throws -> Fixture {
        let root = TestTemp.root.appendingPathComponent("BRIEF-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        for name in ["a", "b", "c"] {
            try Data("\(name) body.".utf8).write(to: root.appendingPathComponent("manuscript/\(name).md"))
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "grp-1", title: "Part One", type: .group, synopsis: "The Part's line.", children: [
                    StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md",
                                  synopsis: "Kelly lies to the harbourmaster."),
                    StructureItem(id: "doc-b", title: "B", type: .document, path: "manuscript/b.md", synopsis: ""),
                ]),
                StructureItem(id: "doc-c", title: "C", type: .document, path: "manuscript/c.md"),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: root.appendingPathComponent(ProjectManifest.fileName))

        let store = try await ProjectStore.load(from: root)
        let ds = try await DocumentStore.open(url: root)
        store.documentStore = ds
        ds.projectStore = store
        addTeardownBlock { try? fm.removeItem(at: root) }

        try await write(.intent, .project, essay: "The book is about a harbour.",
                        [ruling("book: the harbour stays shut", on: 5)], in: store)
        try await write(.intent, .document("doc-a"), essay: "Chapter A turns on a lie.\n\nIt is quiet.",
                        [ruling("a: no flashbacks", on: 2), ruling("a: Kelly never lies", on: 7)], in: store)
        try await write(.intent, .document("doc-b"), essay: "Chapter B is the storm.",
                        [ruling("b: rain all night", on: 3), ruling("b: hand-typed", on: nil)], in: store)
        try await write(.lessons, .project, essay: "",
                        [ruling("lessons: cut throat-clearing", on: 1),
                         ruling("lessons: over-explaining (retired 2 Sep 2026)", on: 4)], in: store)
        try await write(.firstReader, .project, essay: "Mara reads for the plot.",
                        [ruling("reader: skip the commas", on: 6)], in: store)
        try await write(.editionBrief("es"), .project, essay: "Rioplatense register.",
                        [ruling("es: tuteo, never voseo", on: 8)], in: store)
        return Fixture(root: root, store: store, ds: ds)
    }

    private func write(_ kind: Statement.Kind, _ scope: Statement.Scope, essay: String,
                       _ rulings: [Ruling], in store: ProjectStore) async throws {
        let statement = try await store.createStatement(kind: kind, scope: scope)
        let text = RulingsSection.render(essay: essay, rulings: rulings)
        try await store.mutateStatementText(of: statement, session: "brief-test") { _ in text }
    }

    /// A statement for `doc-c` whose op log is present and unreadable (a
    /// directory where bytes are expected — RULING-54's field shape).
    private func plantUnreadableIntent(for docId: String, in f: Fixture) throws -> String {
        let id = "stmt-unreadable"
        f.store.manifest.statements.append(
            Statement(id: id, kind: .intent, scope: .document(docId), path: "intent/unreadable.md"))
        try FileManager.default.createDirectory(
            at: f.root.appendingPathComponent(".maugham/ops/\(id).jsonl"), withIntermediateDirectories: true)
        return id
    }

    private func texts(_ decisions: [BriefDecision]) -> [String] { decisions.map(\.ruling.text) }

    // MARK: - Review Focus 2

    func test_readingAClosedPiecesBriefRegistersNoManuscriptDocument() async throws {
        let f = try await makeFixture()
        XCTAssertNil(f.ds.document(forDocId: "doc-a"), "premise: the piece is closed")

        let read = BriefReader.read(scope: .piece(docId: "doc-a"), store: f.store, bible: nil)

        XCTAssertEqual(read.scope, .piece(docId: "doc-a"))
        XCTAssertEqual(read.line, "Kelly lies to the harbourmaster.")
        XCTAssertEqual(read.intentEssay?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Chapter A turns on a lie.\n\nIt is quiet.")
        XCTAssertTrue(read.intentText?.contains(RulingsSection.heading) == true, "the WHOLE statement")
        XCTAssertEqual(texts(read.decisions), ["a: Kelly never lies", "a: no flashbacks"], "both read, newest first")
        XCTAssertEqual(read.decisions.map(\.origin), [.piece(docId: "doc-a"), .piece(docId: "doc-a")])
        XCTAssertEqual(read.bookIntentEssay?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "The book is about a harbour.", "what applies from the Book")
        XCTAssertEqual(read.bookDecisions.map(\.text), ["book: the harbour stays shut"])
        XCTAssertEqual(read.unconfirmedReadings, 0)
        XCTAssertEqual(read.unreadable, [])

        XCTAssertNil(f.ds.document(forDocId: "doc-a"), "reading registered no manuscript document")
        XCTAssertTrue(f.ds.allOpenDocuments().isEmpty)
    }

    func test_aPieceWithNoIntentReadsNoneAndAnEmptySynopsisIsNoLine() async throws {
        let f = try await makeFixture()
        let read = BriefReader.read(scope: .piece(docId: "doc-b"), store: f.store, bible: nil)
        XCTAssertNil(read.line, "a synopsis stored as \"\" is no line")
        XCTAssertEqual(texts(read.decisions), ["b: rain all night", "b: hand-typed"])

        let none = BriefReader.read(scope: .piece(docId: "doc-c"), store: f.store, bible: nil)
        XCTAssertNil(none.intentText, "no statement yet")
        XCTAssertNil(none.intentEssay)
        XCTAssertEqual(none.decisions, [])
        XCTAssertEqual(none.unreadable, [])
    }

    func test_aPartReadsItsChaptersDecisionsAndHasNoIntent() async throws {
        let f = try await makeFixture()
        let read = BriefReader.read(scope: .part(groupId: "grp-1", docIds: ["doc-a", "doc-b"]),
                                    store: f.store, bible: nil)
        XCTAssertNil(read.intentText, "a Part has no intent of its own")
        XCTAssertNil(read.intentEssay)
        XCTAssertEqual(read.line, "The Part's line.")
        XCTAssertEqual(texts(read.decisions),
                       ["a: Kelly never lies", "b: rain all night", "a: no flashbacks", "b: hand-typed"])
        XCTAssertEqual(read.decisions.map(\.origin), [.piece(docId: "doc-a"), .piece(docId: "doc-b"),
                                                      .piece(docId: "doc-a"), .piece(docId: "doc-b")])
        XCTAssertEqual(read.bookDecisions.map(\.text), ["book: the harbour stays shut"])
    }

    func test_theBookGathersEveryStandingDecisionByOrigin() async throws {
        let f = try await makeFixture()
        let read = BriefReader.read(scope: .book, store: f.store, bible: nil)
        XCTAssertEqual(read.intentEssay?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "The book is about a harbour.")
        XCTAssertNil(read.line)
        XCTAssertNil(read.bookIntentEssay, "the Book is not told what applies from itself")
        XCTAssertEqual(read.bookDecisions, [])
        XCTAssertEqual(texts(read.decisions), [
            "es: tuteo, never voseo", "a: Kelly never lies", "reader: skip the commas",
            "book: the harbour stays shut", "b: rain all night", "a: no flashbacks",
            "lessons: cut throat-clearing", "b: hand-typed",
        ], "every standing decision, newest first; the retired lesson is not standing")
        XCTAssertEqual(BriefDecisions.origins(of: read.decisions, structure: f.store.manifest.structure), [
            .book, .piece(docId: "doc-a"), .piece(docId: "doc-b"), .lessons, .firstReader,
            .edition(language: "es"),
        ])
        XCTAssertEqual(texts(BriefDecisions.filtered(read.decisions, by: .lessons)),
                       ["lessons: cut throat-clearing"])
    }

    func test_anEditionReadsItsBrief() async throws {
        let f = try await makeFixture()
        let read = BriefReader.read(scope: .edition(language: "es"), store: f.store, bible: nil)
        XCTAssertEqual(read.intentEssay?.trimmingCharacters(in: .whitespacesAndNewlines), "Rioplatense register.")
        XCTAssertEqual(texts(read.decisions), ["es: tuteo, never voseo"])
        XCTAssertEqual(read.decisions.map(\.origin), [.edition(language: "es")])

        for scope: BriefScope in [.outside, .elsewhere(docId: "doc-a")] {
            let empty = BriefReader.read(scope: scope, store: f.store, bible: nil)
            XCTAssertNil(empty.intentText)
            XCTAssertEqual(empty.decisions, [], "\(scope) holds nothing")
        }
    }

    func test_anUnreadableStatementIsNamedNotEmpty() async throws {
        let f = try await makeFixture()
        let id = try plantUnreadableIntent(for: "doc-c", in: f)
        let planted = try XCTUnwrap(f.store.statement(kind: .intent, scope: .document("doc-c")))
        XCTAssertThrowsError(try f.store.statementText(of: planted), "premise: the statement will not read")

        let piece = BriefReader.read(scope: .piece(docId: "doc-c"), store: f.store, bible: nil)
        XCTAssertNil(piece.intentText, "never read as empty")
        XCTAssertNil(piece.intentEssay)
        XCTAssertEqual(piece.unreadable, [id])

        let book = BriefReader.read(scope: .book, store: f.store, bible: nil)
        XCTAssertEqual(book.unreadable, [id], "the Book names it too")
        XCTAssertEqual(book.decisions.count, 8, "the rest still read")
    }

    // MARK: - The line index and the MCP listing

    func test_theLineIndexIsTheSynopsisElseThePiecesOwnIntentOpening() async throws {
        let f = try await makeFixture()
        let index = BriefLine.index(store: f.store)
        XCTAssertEqual(index["doc-a"], "Kelly lies to the harbourmaster.")
        XCTAssertEqual(index["doc-b"], "Chapter B is the storm.", "an empty synopsis falls back to the intent")
        XCTAssertEqual(index["grp-1"], "The Part's line.")
        XCTAssertNil(index["doc-c"], "no synopsis and no intent of its own: the Book's intent is not its line")
    }

    func test_theMCPListingCarriesTheLine() async throws {
        let f = try await makeFixture()
        let reg = ProjectRegistry()
        reg.register(url: f.root, store: f.store)
        let id = ProjectIdentifier.id(for: f.root)
        let data = try await GetOutlineTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let outline = try decoder.decode(GetOutlineTool.Outline.self, from: data)
        let part = try XCTUnwrap(outline.nodes.first)
        XCTAssertEqual(part.synopsis, "The Part's line.")
        XCTAssertEqual(part.children?.map(\.synopsis), ["Kelly lies to the harbourmaster.", "Chapter B is the storm."])
        XCTAssertNil(outline.nodes.last?.synopsis)
        XCTAssertTrue(GetOutlineTool.description.contains("the opening of its intent"),
                      "the description says what the field carries")
    }

    // MARK: - Census: no Brief source loads a manuscript

    static let forbidden = ["Document.load(", ".load(url:", "withAnnotationDocument"]

    static func offenders(in sources: [String: String]) -> [String] {
        sources.flatMap { name, text in
            forbidden.filter { text.contains($0) }.map { "\(name): \($0)" }
        }.sorted()
    }

    func test_noBriefSourceLoadsAManuscriptDocument() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appendingPathComponent("Maugham/Views/Brief")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(names.contains("BriefReader.swift"), "the census must read the reader itself")
        var sources: [String: String] = [:]
        for name in names {
            sources[name] = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        XCTAssertEqual(Self.offenders(in: sources), [])

        for spelling in Self.forbidden {
            let planted = sources.merging(["Planted.swift": "let d = try await \(spelling)x)"]) { $1 }
            XCTAssertEqual(Self.offenders(in: planted), ["Planted.swift: \(spelling)"],
                           "the census must catch \(spelling)")
        }
    }
}
