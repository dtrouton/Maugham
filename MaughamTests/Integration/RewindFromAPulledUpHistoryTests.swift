import XCTest
import MaughamCore
@testable import Maugham

/// **A Rewind pressed in a pulled-up History acts on that History's piece, and
/// only while that piece is the one open** (shell p3 final wave, C1).
///
/// A pulled-up History keeps its piece while the faces move. The rewind post
/// used to carry no document, so the receiver opened the sheet for the
/// window's FACES: History of A pulled up, B opened, a Rewind on A's row, and
/// RULING-27's nearest-moment rule rewound **B** to the time of A's op.
///
/// The exact sequence, over real `Document`s registered with a real
/// `DocumentStore` the way `EditorHost` registers them: what the row posts
/// (`HistoryPane.rewindPayload`), what the pane offers
/// (`HistoryPane.offersRewind(_:documentIsOpen:)`) and what the receiver
/// presents for (`RewindModifier.rewindTarget`).
@MainActor
final class RewindFromAPulledUpHistoryTests: XCTestCase {

    private struct Chapters {
        let documentStore: DocumentStore
        let a: Document
        let b: Document
        let aPath = "manuscript/a.md"
        let bPath = "manuscript/b.md"
    }

    private func twoChapters() async throws -> Chapters {
        let root = TestTemp.root.appendingPathComponent("RW-\(UUID().uuidString)")
        let manuscript = root.appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(at: manuscript, withIntermediateDirectories: true)
        try "Chapter A's words.".write(to: manuscript.appendingPathComponent("a.md"),
                                       atomically: true, encoding: .utf8)
        try "Chapter B's words.".write(to: manuscript.appendingPathComponent("b.md"),
                                       atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md"),
                StructureItem(id: "doc-b", title: "B", type: .document, path: "manuscript/b.md"),
            ],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("project.maugham.json"))
        let documentStore = try await DocumentStore.open(url: root)
        let a = try await Document.load(url: manuscript.appendingPathComponent("a.md"),
                                        device: "test", session: "s", presenter: nil)
        let b = try await Document.load(url: manuscript.appendingPathComponent("b.md"),
                                        device: "test", session: "s", presenter: nil)
        addTeardownBlock { await documentStore.close() }
        return Chapters(documentStore: documentStore, a: a, b: b)
    }

    private let bookAuthor = Posture(.unrestricted)

    func test_aRewindOnAPulledUpHistoryOfANeverTouchesTheChapterOpenedSince() async throws {
        let h = try await twoChapters()
        let isOpen: (String) -> Bool = { h.documentStore.document(forDocId: $0) != nil }
        let opsOfA = try await h.a.opLog()
        let anOpOfA = try XCTUnwrap(opsOfA.last)

        // 1. Faces on A; History of A pulled up. A is the open piece: Rewind is
        //    offered, and its post names A.
        h.documentStore.register(document: h.a, for: h.aPath)
        XCTAssertTrue(HistoryPane.offersRewind(bookAuthor, documentIsOpen: isOpen(h.a.docId)))
        let rowPost = HistoryPane.rewindPayload(docId: h.a.docId, before: anOpOfA)
        let headerPost = HistoryPane.rewindPayload(docId: h.a.docId, before: nil)
        XCTAssertEqual(rowPost[ManuscriptNavigation.docIdKey] as? String, h.a.docId,
                       "the row's post carries its own piece, as jump does")
        XCTAssertEqual(headerPost[ManuscriptNavigation.docIdKey] as? String, h.a.docId,
                       "the toolbar's post carries its own piece too")
        XCTAssertEqual(RewindModifier.rewindTarget(of: rowPost, isOpen: isOpen), h.a.docId)

        // 2. B opened in the tree; the History of A stays pulled up.
        h.documentStore.unregister(path: h.aPath)
        h.documentStore.register(document: h.b, for: h.bPath)

        // 3. A's History offers no Rewind now: A is not the open piece.
        XCTAssertFalse(HistoryPane.offersRewind(bookAuthor, documentIsOpen: isOpen(h.a.docId)),
                       "Rewind is hidden where its piece is not the one open")

        // 4. And a post that names A — one drawn before B opened — never
        //    reaches B: the receiver presents for A or for nothing.
        XCTAssertNil(RewindModifier.rewindTarget(of: rowPost, isOpen: isOpen),
                     "A is not open: the receiver presents nothing rather than B's sheet")
        XCTAssertNil(RewindModifier.rewindTarget(of: headerPost, isOpen: isOpen))
        XCTAssertNotEqual(RewindModifier.rewindTarget(of: rowPost, isOpen: isOpen), h.b.docId)

        // A post that names no piece (the old shape) presents nothing either.
        XCTAssertNil(RewindModifier.rewindTarget(of: ["scrub_op_id": "x"], isOpen: isOpen))
    }

    /// **Owner's answer 13 (2026-11-22)**: Rewind stays the open piece's, and
    /// where it is missing because the History pulled up is of a piece that
    /// is not open, the slot says how to get it — a button that opens the
    /// piece, its History staying up. Never for the project's or a figure's
    /// History, and never where this Mac may not write the text.
    func test_whereRewindIsMissingTheHistorySaysOpenThePieceToRewindIt() throws {
        XCTAssertEqual(HistoryPane.rewindSlot(bookAuthor, documentIsOpen: true, pieceNoun: "chapter"), .rewind)
        XCTAssertEqual(HistoryPane.rewindSlot(bookAuthor, documentIsOpen: false, pieceNoun: "chapter"),
                       .openToRewind("Open this chapter to rewind it"))
        XCTAssertEqual(HistoryPane.rewindSlot(bookAuthor, documentIsOpen: false, pieceNoun: "story"),
                       .openToRewind("Open this story to rewind it"), "the project's own word")
        XCTAssertEqual(HistoryPane.rewindSlot(bookAuthor, documentIsOpen: false, pieceNoun: nil), .none,
                       "the project's History, a figure's: no piece to open")
        XCTAssertEqual(HistoryPane.rewindSlot(nil, documentIsOpen: false, pieceNoun: "chapter"), .none,
                       "no door behind the pane fails closed")
        let pane = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/HistoryPane.swift"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(pane.contains("if case .openToRewind(let line) = rewindSlot { Button(line) { ResolveNavigation.go(toDocId: activeDocId) }"),
                      "the line is a button that opens the piece (the ordinary place keeps what is beside)")
        XCTAssertTrue(pane.contains("var rewindIsOffered: Bool { rewindSlot == .rewind }"))
        let pulledUp = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/PulledUpView.swift"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(pulledUp.contains("pieceNoun: HistoryPane.pieceNoun(docId: docId, store: store))"))
        // The ordinary place keeps what is pulled up beside.
        let beside = WindowSubject(open: .item("doc-b"), faces: .item("doc-b"), beside: .history(docId: "doc-a"))
        XCTAssertEqual(ManuscriptNavigation.destination(toDocument: "doc-a", current: beside).beside,
                       .history(docId: "doc-a"))
    }

    /// The project's History (`noDocumentSubject`) offers no Rewind — there is
    /// no piece to rewind — and its checkpoint Revert keeps working through
    /// the picker, which is not this rule's.
    func test_theProjectsHistoryOffersNoRewind() {
        XCTAssertFalse(HistoryPane.offersRewind(bookAuthor, documentIsOpen: false))
        XCTAssertNil(RewindModifier.rewindTarget(
            of: HistoryPane.rewindPayload(docId: BinderSubject.noDocumentSubject, before: nil),
            isOpen: { $0 != BinderSubject.noDocumentSubject }))
    }

    /// **Every rewind post goes through the one payload builder** — so none
    /// can name no piece again.
    func test_everyRewindPostCarriesItsPiece() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Integration/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham")
        var posters: [String] = []
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".maughamOpenRewind") {
                let lines = text.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where line.contains(".maughamOpenRewind") {
                    let window = lines[max(0, i - 2)...min(lines.count - 1, i + 3)].joined()
                    if window.contains("post(") || window.contains("MaughamEvent.post") {
                        posters.append(url.lastPathComponent)
                        // `comparePayload` is `rewindPayload`'s keys plus
                        // the checkpoint's moment (`ReadThroughVerbsTests`).
                        XCTAssertTrue(window.contains("rewindPayload(")
                                      || window.contains("comparePayload("),
                                      "\(url.lastPathComponent):\(i + 1) posts a rewind without its piece")
                    }
                }
            }
        }
        XCTAssertEqual(posters.sorted(), ["HistoryPane.swift", "HistoryRow.swift", "HistoryRow.swift"],
                       "the rewind posts are the toolbar's, the row's Rewind and the row's Compare…")
    }
}
