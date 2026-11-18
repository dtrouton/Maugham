import XCTest
import MaughamCore
@testable import Maugham

/// **A row's click goes to its place** (shell plan 2 Task 4): the payload a
/// To resolve row posts always names its document and a paragraph, so
/// `ManuscriptNavigation` opens that piece on that paragraph whatever the
/// centre was — which is how a row on a piece that is not open becomes a row
/// that can act. Pure (tripwire 33), plus a census that the posts go through
/// `MaughamEvent` (tripwire 21).
@MainActor
final class ResolveNavigationTests: XCTestCase {

    private let t = Date(timeIntervalSince1970: 1_700_000_000)
    private let docKey = ManuscriptNavigation.docIdKey

    private func note(_ id: String, on docId: String, pid: String?) -> ResolveItem {
        .note(ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .comment, paragraphId: pid, body: id, suggestedText: nil, priorText: nil,
            createdAt: t, createdBySession: nil, status: .open, userResponse: nil,
            resolvedAt: nil, isStale: false)))
    }

    private func finding(_ id: String, on docId: String, pid: String?) -> ResolveItem {
        .finding(docId: docId, Diagnostic(
            id: id, docId: docId, anchor: pid.map { .init(paragraphId: $0, anchorText: "x") },
            body: id, category: nil, runId: "run-1", kind: .conformanceStrain))
    }

    private func todo(_ id: String, on docId: String?, pid: String?) -> ResolveItem {
        .todo(WriterTask(id: id, kind: .paneCreated,
                         anchor: docId.map { TaskAnchor(docId: $0, paragraphId: pid) },
                         body: id, status: .open, priority: 0, parentTaskId: nil,
                         createdAt: t, createdBySession: nil))
    }

    func test_aRowPayloadAlwaysNamesItsDocument() {
        for item in [note("n1", on: "doc-b", pid: "bb22"),
                     finding("s1", on: "doc-b", pid: "bb22"),
                     todo("t1", on: "doc-b", pid: "bb22")] {
            XCTAssertEqual(ResolveNavigation.payload(for: item, firstParagraph: "aa11"),
                           [docKey: "doc-b", "paragraph_id": "bb22"],
                           "\(item.id) names its own document and its own paragraph")
        }
    }

    func test_aWholePieceRowLandsOnTheFirstParagraph() {
        for item in [note("n1", on: "doc-b", pid: nil),
                     finding("s1", on: "doc-b", pid: nil),
                     todo("t1", on: "doc-b", pid: nil)] {
            XCTAssertEqual(ResolveNavigation.payload(for: item, firstParagraph: "aa11"),
                           [docKey: "doc-b", "paragraph_id": "aa11"],
                           "\(item.id) points at no paragraph: the piece's first")
            XCTAssertNil(ResolveNavigation.payload(for: item, firstParagraph: nil),
                         "a piece with no paragraph has no place to name")
        }
        XCTAssertNil(ResolveNavigation.payload(
            for: todo("b1", on: ProjectStore.projectTasksDocId, pid: nil), firstParagraph: "aa11"),
            "a Book-level to-do has no place in the manuscript")
        XCTAssertNil(ResolveNavigation.payload(for: todo("b2", on: nil, pid: nil), firstParagraph: "aa11"),
                     "nor one with no anchor")
        XCTAssertNil(ResolveNavigation.payload(for: note("f1", on: "fig-aaaa1111", pid: nil),
                                               firstParagraph: "aa11"),
                     "a figure's note goes to its figure, not to a paragraph")
    }

    /// The posts go through the typed wrapper, a note's annotation event
    /// first — the receivers are unchanged.
    func test_goPostsThroughMaughamEventOnly() throws {
        let code = try SourceTree.read("Maugham/Views/Resolve/ResolveNavigation.swift")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("NotificationCenter"), "tripwire 21: MaughamEvent only")
        let annotation = try XCTUnwrap(code.range(of: "MaughamEvent.post(.maughamNavigateToAnnotation"))
        let paragraph = try XCTUnwrap(code.range(of: "MaughamEvent.post(.maughamNavigateToParagraph"))
        XCTAssertLessThan(annotation.lowerBound, paragraph.lowerBound,
                          "a note's annotation event is posted before the paragraph's")
    }
}
