// MaughamTests/OpLog/ReviewerAnnotationCreationTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// Task 3b: human-authored comment/query annotations created from the editor
/// review toolbar, anchored to a sub-paragraph span via `SpanAnchor`.
@MainActor
final class ReviewerAnnotationCreationTests: XCTestCase {

    private func loadDoc() async throws -> (Document, String) {
        let (_, docURL) = try makeTestProject(
            prefix: "REVANN",
            initialMd: "She was angry and shaking with fury.")
        let doc = try await Document.load(
            url: docURL,
            device: "m", session: "s", presenter: nil)
        let log = try await doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { throw XCTSkip("no bootstrap paragraph") }
        return (doc, pid)
    }

    func test_addReviewerComment_isHumanAuthored_withSpanAndName() async throws {
        let (doc, pid) = try await loadDoc()
        let para = doc.paragraph(id: pid)!
        // Capture a span over the word "angry".
        let range = Array(para).count >= 13 ? 8..<13 : 0..<para.count
        let span = SpanAnchorResolver.capture(in: para, range: range)

        let id = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: pid, span: span,
            body: "consider showing", authorName: "Marian")

        let anns = doc.annotations()
        let ann = anns.first { $0.id == id }
        XCTAssertNotNil(ann)
        XCTAssertEqual(ann?.kind, .comment)
        XCTAssertEqual(ann?.author?.sourceKind, .human)
        XCTAssertEqual(ann?.author?.displayName, "Marian")
        XCTAssertNil(ann?.author?.collaboratorId,
                     "author_collaborator_id is decoded and never written (P3 spec §8)")
        XCTAssertEqual(ann?.span?.quote, span.quote)
        XCTAssertEqual(ann?.body, "consider showing")
    }

    /// A reviewer comment from a build before P3c carries
    /// `author_collaborator_id` in its log line. It is decoded and derived —
    /// old logs keep their attribution — though nothing writes it any more.
    func test_aLegacyLineCarryingACollaboratorIdStillDerivesIt() throws {
        let legacy = #"{"op_id":"01J0LEGACYAUTHORID000000002","doc_id":"doc-x","at":"2026-06-20T10:00:00Z","device":"legacy-mac","session":"s0","kind":"claude_comment","changes":[{"paragraph_id":"ab2c","prior":null,"next":""}],"provenance":{"annotation_body":"consider showing","author_source_kind":"human","author_display_name":"Marian","author_collaborator_id":"c-1","span_quote":"angry"}}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        let op = try dec.decode(Op.self, from: Data(legacy.utf8))
        let ann = AnnotationDeriver.derive(
            ops: [op], paragraphs: ["ab2c": "She was angry and shaking with fury."]).first
        XCTAssertEqual(ann?.author?.sourceKind, .human)
        XCTAssertEqual(ann?.author?.displayName, "Marian")
        XCTAssertEqual(ann?.author?.collaboratorId, "c-1")
        XCTAssertEqual(ann?.span?.quote, "angry")
    }

    func test_addReviewerQuery_kindIsQuery() async throws {
        let (doc, pid) = try await loadDoc()
        let para = doc.paragraph(id: pid)!
        let span = SpanAnchorResolver.capture(in: para, range: 0..<3)

        let id = try await doc.addReviewerAnnotation(
            kind: .query, paragraphId: pid, span: span,
            body: "is this intended?", authorName: "Reviewer")

        let ann = doc.annotations().first { $0.id == id }
        XCTAssertEqual(ann?.kind, .query)
        XCTAssertEqual(ann?.author?.sourceKind, .human)
        XCTAssertEqual(ann?.author?.displayName, "Reviewer")
        XCTAssertNil(ann?.author?.collaboratorId)
    }
}
