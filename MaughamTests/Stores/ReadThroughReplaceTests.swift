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
    private func makeBook() async throws -> ProjectStore {
        project = TestTemp.root.appendingPathComponent("ReadThroughReplace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("manuscript"),
                                                withIntermediateDirectories: true)
        try "One cat.\n".write(to: project.appendingPathComponent("manuscript/one.md"),
                               atomically: true, encoding: .utf8)
        try "Three cats.\n".write(to: project.appendingPathComponent("manuscript/three.md"),
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
        await store.searchNow(query: "cat", options: SearchOptions())
        XCTAssertEqual(store.currentSearch?.matchCount, 2, "premise: one match in each chapter")
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
            inReadThrough: { asked.append($0); return $0 == "manuscript/three.md" })
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
        XCTAssertTrue(view.contains("inReadThrough: { store.pieceInReadThrough(atPath: $0) != nil })"))
        XCTAssertTrue(view.contains("inReadThrough: gate.isInReadThrough)"), "the confirm counts it")
    }

    /// The session hands the store its pieces, weakly.
    func test_theSessionHandsTheStoreItsPieces() throws {
        let session = SourceScan.codeLines(of: try SourceTree.read("Maugham/Stores/ProjectSession.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(session.contains(
            "s.readThroughPieceIds = { [weak readThrough] in readThrough?.pieceIds ?? [] }"))
    }
}
