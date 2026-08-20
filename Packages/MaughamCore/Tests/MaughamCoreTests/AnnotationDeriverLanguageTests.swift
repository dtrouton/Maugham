import XCTest
@testable import MaughamCore

/// Task 5: a `claudeQuery` op whose `toolArgs` provenance carries a
/// `"language"` tag surfaces as `Annotation.language`. Absent or malformed
/// toolArgs derive `nil` and never throw.
///
/// P2's final wave widened the projection to `claudeCraftNote`, because the
/// one translation question that cannot be a `.query` — a whole-document one,
/// which `addAnnotation` refuses to anchor to nothing — mints as a craft note,
/// and an untagged one is invisible to every reader that filters by language.
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

    /// A comment carrying a stray `language` in toolArgs does not surface one.
    /// The projection is for the two kinds a translation question can wear,
    /// not for anything that happens to have the key.
    func test_aCommentDoesNotSurfaceLanguage() {
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

    /// **The whole-document translation question.** It has no paragraph, so it
    /// mints as a craft note; if the tag stopped at `.query` the note would be
    /// unfindable by language, which is how a fresh session came to re-ask the
    /// same question forever.
    func test_aCraftNoteCarriesItsTranslationLanguage() {
        let op = Op(
            opId: ULID.generate(),
            docId: "d", at: Date(), device: "test", session: "s",
            kind: .claudeCraftNote,
            changes: [],
            provenance: Op.Provenance(
                sessionId: "s",
                toolArgs: #"{"language":"es","role_id":"role-es"}"#,
                annotationBody: "Translation query (es) — tú or usted throughout?"))
        let anns = AnnotationDeriver.derive(ops: [op], paragraphs: ["p1": "Source."])
        XCTAssertEqual(anns.count, 1)
        XCTAssertEqual(anns.first?.kind, .craftNote)
        XCTAssertNil(anns.first?.paragraphId)
        XCTAssertEqual(anns.first?.language, "es")
    }

    /// An ordinary craft note — `add_craft_note`'s, whose Params carry no
    /// `language` at all — is untagged, which is what keeps the widened
    /// projection from sweeping other people's notes into a translation round.
    func test_anUntaggedCraftNoteHasNoLanguage() {
        let op = Op(
            opId: ULID.generate(),
            docId: "d", at: Date(), device: "test", session: "s",
            kind: .claudeCraftNote,
            changes: [],
            provenance: Op.Provenance(
                sessionId: "s",
                toolArgs: #"{"body":"Kelly never uses contractions.","document_id":"d"}"#,
                annotationBody: "Kelly never uses contractions."))
        let anns = AnnotationDeriver.derive(ops: [op], paragraphs: ["p1": "Source."])
        XCTAssertEqual(anns.count, 1)
        XCTAssertNil(anns.first?.language)
    }
}
