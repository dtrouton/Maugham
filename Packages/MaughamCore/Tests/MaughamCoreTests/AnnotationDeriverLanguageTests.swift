import XCTest
@testable import MaughamCore

/// Task 5: a `claudeQuery` op whose `toolArgs` provenance carries a
/// `"language"` tag surfaces as `Annotation.language`. Absent or malformed
/// toolArgs derive `nil` and never throw.
final class AnnotationDeriverLanguageTests: XCTestCase {

    private func queryOp(toolArgs: String?) -> Op {
        Op(
            opId: ULID.generate(),
            docId: "d", at: Date(), device: "test", session: "s",
            kind: .claudeQuery,
            changes: [.init(paragraphId: "p1", prior: "Source.", next: "")],
            provenance: Op.Provenance(
                sessionId: "s",
                toolArgs: toolArgs,
                annotationBody: "why this phrasing?"))
    }

    func test_toolArgsWithLanguage_surfacesOnAnnotation() {
        let op = queryOp(toolArgs: #"{"language":"es","body":"why this phrasing?"}"#)
        let anns = AnnotationDeriver.derive(ops: [op], paragraphs: ["p1": "Source."])
        XCTAssertEqual(anns.count, 1)
        XCTAssertEqual(anns.first?.kind, .query)
        XCTAssertEqual(anns.first?.language, "es")
    }

    func test_toolArgsWithoutLanguage_derivesNil() {
        let op = queryOp(toolArgs: #"{"body":"why this phrasing?"}"#)
        let anns = AnnotationDeriver.derive(ops: [op], paragraphs: ["p1": "Source."])
        XCTAssertEqual(anns.count, 1)
        XCTAssertNil(anns.first?.language)
    }

    func test_absentToolArgs_derivesNil() {
        let op = queryOp(toolArgs: nil)
        let anns = AnnotationDeriver.derive(ops: [op], paragraphs: ["p1": "Source."])
        XCTAssertEqual(anns.count, 1)
        XCTAssertNil(anns.first?.language)
    }

    func test_malformedToolArgs_derivesNilAndDoesNotThrow() {
        let op = queryOp(toolArgs: "{not valid json")
        let anns = AnnotationDeriver.derive(ops: [op], paragraphs: ["p1": "Source."])
        XCTAssertEqual(anns.count, 1)
        XCTAssertNil(anns.first?.language)
    }

    /// A non-query op carrying a stray `language` in toolArgs does not surface
    /// one — language is a query-only concept.
    func test_nonQueryOpDoesNotSurfaceLanguage() {
        let op = Op(
            opId: ULID.generate(),
            docId: "d", at: Date(), device: "test", session: "s",
            kind: .claudeComment,
            changes: [.init(paragraphId: "p1", prior: "Source.", next: "")],
            provenance: Op.Provenance(
                sessionId: "s",
                toolArgs: #"{"language":"es"}"#,
                annotationBody: "a comment"))
        let anns = AnnotationDeriver.derive(ops: [op], paragraphs: ["p1": "Source."])
        XCTAssertEqual(anns.count, 1)
        XCTAssertEqual(anns.first?.kind, .comment)
        XCTAssertNil(anns.first?.language)
    }
}
