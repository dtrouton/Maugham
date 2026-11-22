import XCTest
import MaughamCore
@testable import Maugham

/// **Project Find & Replace leaves a piece in read-through as it was**
/// (shell read-through Task 2): typing is off there, so Replace is too. A
/// single Replace in such a piece is refused with its name and writes
/// nothing; Replace All replaces the rest of the book, skips the piece and
/// names it in its notice. The pieces come from the session's store
/// (`ProjectStore.readThroughPieceIds`, set by `ProjectSession.open`).
@MainActor
final class ReadThroughReplaceTests: XCTestCase {

    private var project: URL!

    override func tearDown() async throws {
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    /// A book with two chapters, each saying "cat", bootstrapped through
    /// `Document.load` so the search reads them from the op log.
    private func makeBook(three: String = "Three cats.\n", query: String = "cat") async throws -> ProjectStore {
        project = TestTemp.root.appendingPathComponent("ReadThroughReplace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("manuscript"),
                                                withIntermediateDirectories: true)
        try "One cat.\n".write(to: project.appendingPathComponent("manuscript/one.md"),
                               atomically: true, encoding: .utf8)
        try three.write(to: project.appendingPathComponent("manuscript/three.md"),
                        atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-one", title: "Chapter One", type: .document, path: "manuscript/one.md"),
                StructureItem(id: "doc-three", title: "Chapter Three", type: .document,
                              path: "manuscript/three.md"),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: project.appendingPathComponent("project.maugham.json"))
        for path in ["manuscript/one.md", "manuscript/three.md"] {
            let doc = try await Document.load(url: project.appendingPathComponent(path),
                                              device: "test", session: "bootstrap", presenter: nil)
            await doc.close()
        }
        let store = try await ProjectStore.load(from: project)
        store.readThroughPieceIds = { ["doc-three"] }
        await store.searchNow(query: query, options: SearchOptions())
        if query == "cat" {
            XCTAssertEqual(store.currentSearch?.matchCount, 2, "premise: one match in each chapter")
        }
        return store
    }

    private func reload(_ path: String) async throws -> String {
        let doc = try await Document.load(url: project.appendingPathComponent(path),
                                          device: "verify", session: "verify", presenter: nil)
        let text = doc.displayText
        await doc.close()   // closed before tearDown removes the folder
        return text
    }

    func test_aSingleReplaceInAPieceInReadThroughIsRefusedAndNamed() async throws {
        let store = try await makeBook()
        let results = try XCTUnwrap(store.currentSearch)
        let inThree = try XCTUnwrap(results.matches.first { $0.documentPath == "manuscript/three.md" })
        do {
            try await store.replaceMatch(inThree, with: "dog")
            XCTFail("a Replace in a piece in read-through must refuse")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .inReadThrough(title: "Chapter Three"))
            XCTAssertEqual(error.localizedDescription,
                           "Left as it was \u{2014} \u{201C}Chapter Three\u{201D} is in read-through. Resume writing to replace it.")
        }
        let text = try await reload("manuscript/three.md")
        XCTAssertTrue(text.hasPrefix("Three cats."), "nothing written: \(text)")
        // The other chapter still takes a Replace.
        let inOne = try XCTUnwrap(store.currentSearch?.matches.first { $0.documentPath == "manuscript/one.md" })
        try await store.replaceMatch(inOne, with: "dog")
        let one = try await reload("manuscript/one.md")
        XCTAssertTrue(one.hasPrefix("One dog."), one)
    }

    /// **A piece rename's wiki-link sweep is a deliberate sweep: it rewrites
    /// a link inside a piece in read-through** (ruling, ADR 0039 §4,
    /// 2026-11-22), unlike Replace — refusing it would leave a dangling link,
    /// and the rename is the writer's deliberate act.
    func test_aRenamesLinkSweepRewritesAPieceInReadThrough_deliberately() async throws {
        let store = try await makeBook(three: "See [[Chapter One]].\n", query: "See")
        XCTAssertNotNil(store.readThroughGate().refusal(.piece("doc-three")), "premise: Three is in read-through")
        _ = try await store.renameStructureItem(id: "doc-one", newTitle: "Chapter Uno")
        let three = try await reload("manuscript/three.md")
        XCTAssertTrue(three.hasPrefix("See [[Chapter Uno]]."), "the link stays valid: \(three)")
    }

    func test_replaceAllSkipsAPieceInReadThroughAndNamesIt() async throws {
        let store = try await makeBook()
        let outcome = try await store.replaceAll(in: try XCTUnwrap(store.currentSearch), with: "dog")
        XCTAssertEqual(outcome.inReadThrough, ["Chapter Three"])
        XCTAssertEqual(outcome.notice, "Left as it was \u{2014} in read-through: Chapter Three.")
        let one = try await reload("manuscript/one.md")
        let three = try await reload("manuscript/three.md")
        XCTAssertTrue(one.hasPrefix("One dog."), "the rest of the book is replaced: \(one)")
        XCTAssertTrue(three.hasPrefix("Three cats."), "the piece in read-through is left as it was: \(three)")
    }

    private func match(_ path: String, _ title: String) -> SearchMatch {
        SearchMatch(
            documentPath: path, documentTitle: title, documentSource: .manuscript,
            lineNumber: 1, charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "cat", matchRangeInLine: NSRange(location: 0, length: 3))
    }

    /// **Find says before the press what read-through leaves** (review M3):
    /// Replace All's confirm counts only what will be replaced and names the
    /// piece in read-through apart; that piece's rows offer no Replace.
    func test_findSaysBeforeThePressWhatReadThroughLeaves() throws {
        let one = [match("manuscript/one.md", "Chapter One"), match("manuscript/one.md", "Chapter One")]
        let three = match("manuscript/three.md", "Chapter Three")
        let results = SearchResults(query: "cat", options: SearchOptions(), matches: one + [three])
        var asked: [String] = []
        let gate = ProjectSearchView.ReplaceGate(
            results, posture: { _ in Posture(.unrestricted) },
            inReadThrough: { path, _ in asked.append(path); return path == "manuscript/three.md" })
        XCTAssertEqual(asked.sorted(), ["manuscript/one.md", "manuscript/three.md"], "once per document")
        XCTAssertTrue(one.allSatisfy(gate.mayReplace))
        XCTAssertFalse(gate.mayReplace(three), "no per-row Replace in a piece in read-through")
        XCTAssertTrue(gate.isInReadThrough(three))
        let split = ProjectSearchView.replaceability(results, mayReplace: gate.mayReplace,
                                                     inReadThrough: gate.isInReadThrough)
        XCTAssertEqual(split.replaceable, 2)
        XCTAssertEqual(split.leftAlone, [], "not a posture refusal")
        XCTAssertEqual(split.inReadThrough, ["Chapter Three"])
        XCTAssertEqual(ProjectSearchView.replaceAllMessage(split),
                       "2 matches will be replaced. Left as it was \u{2014} in read-through: Chapter Three.")
        // The row says why, before the press; the view asks the store.
        let view = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ProjectSearchView.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(view.contains("} else if showReplace, gate.isInReadThrough(match) {"))
        XCTAssertTrue(view.contains(".help(Self.readThroughRowHelp)"))
        XCTAssertTrue(view.contains("case .manuscript: return store.pieceInReadThrough(atPath: path) != nil"))
        XCTAssertTrue(view.contains(
            "case .research: return store.researchReadThroughRefusal(atPath: path, gate: gate) != nil"))
        XCTAssertTrue(view.contains("inReadThrough: { [gate = store.readThroughGate()] path, source in"),
                      "one gate per pass, never one per document (M6)")
        // The research arm asks the gate's own rule, never a second spelling (M8).
        let search = SourceScan.codeLines(of: try SourceTree.read("Maugham/Stores/ProjectStore+Search.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(search.contains("return gate.refusal(.research(item.id))"))
        XCTAssertTrue(search.contains("return gate.refusal(researchPath: path)"))
        XCTAssertFalse(search.contains("researchScopePieceId"), "no second spelling of the research rule")
        XCTAssertTrue(view.contains("inReadThrough: gate.isInReadThrough)"), "the confirm counts it")
    }

    // MARK: - A piece's own research (shell read-through Task 4)

    /// A Collection: piece A (in read-through) with a note in its own folder,
    /// and a shared note, each saying "cat".
    private func makeCollection() async throws -> ProjectStore {
        project = TestTemp.root.appendingPathComponent("ReadThroughReplaceResearch-\(UUID().uuidString)")
        let files = ["pieces/01-a/a.md": "Alpha.\n", "pieces/01-a/research/tide.md": "A cat at the tide.\n",
                     "research/ships.md": "A cat on the ship.\n"]
        for (path, text) in files {
            let url = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .collection, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "piece-a", title: "Alpha", type: .document,
                                      path: "pieces/01-a/a.md", pieceKind: .loose)],
            research: [
                ResearchItem(id: "tide", title: "Tide", type: .asset, kind: .document,
                             path: "pieces/01-a/research/tide.md"),
                ResearchItem(id: "ships", title: "Ships", type: .asset, kind: .document,
                             path: "research/ships.md"),
            ])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: project.appendingPathComponent("project.maugham.json"))
        let doc = try await Document.load(url: project.appendingPathComponent("pieces/01-a/a.md"),
                                          device: "test", session: "bootstrap", presenter: nil)
        await doc.close()
        let store = try await ProjectStore.load(from: project)
        store.readThroughPieceIds = { ["piece-a"] }
        await store.searchNow(query: "cat", options: SearchOptions())
        XCTAssertEqual(store.currentSearch?.matches.map(\.documentPath).sorted(),
                       ["pieces/01-a/research/tide.md", "research/ships.md"], "premise: one match in each note")
        return store
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: project.appendingPathComponent(path), encoding: .utf8)
    }

    /// **A note in the folder of a piece in read-through is left as it was**,
    /// like the piece: a single Replace refuses with its name, Replace All
    /// skips and names it, the row offers no Replace; a shared note is
    /// replaced (control).
    func test_aNoteInThePiecesFolderIsLeftAsItWas_aSharedNoteIsReplaced() async throws {
        let store = try await makeCollection()
        let results = try XCTUnwrap(store.currentSearch)
        let tide = try XCTUnwrap(results.matches.first { $0.documentPath == "pieces/01-a/research/tide.md" })
        let ships = try XCTUnwrap(results.matches.first { $0.documentPath == "research/ships.md" })
        let rt = store.readThroughGate()
        XCTAssertNotNil(store.researchReadThroughRefusal(atPath: tide.documentPath, gate: rt))
        XCTAssertNil(store.researchReadThroughRefusal(atPath: ships.documentPath, gate: rt))

        let gate = ProjectSearchView.ReplaceGate(
            results, posture: { _ in Posture(.unrestricted) },
            inReadThrough: { path, source in
                source == .research && store.researchReadThroughRefusal(atPath: path, gate: rt) != nil
            })
        XCTAssertTrue(gate.isInReadThrough(tide))
        XCTAssertFalse(gate.mayReplace(tide), "no per-row Replace in the piece's folder")
        XCTAssertTrue(gate.mayReplace(ships), "control: a shared note takes one")

        do {
            try await store.replaceMatch(tide, with: "dog")
            XCTFail("a Replace in the piece's folder must refuse")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .inReadThrough(title: "Alpha"), "it names the piece, which can be resumed")
        }
        let outcome = try await store.replaceAll(in: results, with: "dog")
        XCTAssertEqual(outcome.inReadThrough, ["\(tide.documentTitle) (in \u{201C}Alpha\u{201D})"],
                       "the note, and the piece it is in")
        XCTAssertTrue(try read("pieces/01-a/research/tide.md").contains("A cat at the tide."), "left as it was")
        XCTAssertTrue(try read("research/ships.md").contains("A dog on the ship."), "the shared note is replaced")
    }

    /// The session hands the store its pieces, weakly.
    func test_theSessionHandsTheStoreItsPieces() throws {
        let session = SourceScan.codeLines(of: try SourceTree.read("Maugham/Stores/ProjectSession.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(session.contains(
            "s.readThroughPieceIds = { [weak readThrough] in readThrough?.pieceIds ?? [] }"))
    }
}
