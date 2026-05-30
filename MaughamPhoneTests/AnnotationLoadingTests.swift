import XCTest
@testable import MaughamPhone
import MaughamCore

/// Unit tests for the pure core of the Annotations tab (Task F.4): doc-id
/// parsing out of an `.maugham/ops/` directory listing, and the open-annotation
/// projection from a doc's op stream.
final class AnnotationLoadingTests: XCTestCase {

    // Two real-shaped ULID doc ids (26-char Crockford-base32 bodies).
    private let docA = "d_01HQZZZZZZZZZZZZZZZZZZZZZZ"
    private let docB = "d_01HQYYYYYYYYYYYYYYYYYYYYYY"

    // MARK: - docIds

    func test_docIds_parsesPerDeviceAndLegacy_ignoringNonOpLogFiles() {
        let filenames = [
            "\(docA).macA.jsonl",    // per-device
            "\(docA).jsonl",         // legacy unsuffixed, same doc
            "\(docB).phoneB.jsonl",  // a second distinct doc
            "garbage.txt",           // not jsonl
            "inbox.x.jsonl",         // inbox manifest, not an op log
            "d_short.jsonl",         // d_-prefixed but body isn't a 26-char ULID
        ]
        let ids = AnnotationLoading.docIds(inOpsDirectoryFilenames: filenames)
        XCTAssertEqual(ids, [docA, docB],
            "two distinct doc ids; the per-device + legacy files for docA collapse to one, and non-op-log files are ignored")
    }

    func test_docIds_emptyDirectory_isEmpty() {
        XCTAssertTrue(AnnotationLoading.docIds(inOpsDirectoryFilenames: []).isEmpty)
    }

    // MARK: - openAnnotations

    func test_openAnnotations_excludesAcceptedSuggestion() {
        let creation = suggestionOp(opId: "01CREATION", paragraphId: "k7m3", prior: "Old.", next: "New.")
        let accept = acceptOp(opId: "01ACCEPT", sourceAnnotationId: "01CREATION", paragraphId: "k7m3", prior: "Old.", next: "New.")

        let open = AnnotationLoading.openAnnotations(ops: [creation, accept])
        XCTAssertTrue(open.isEmpty,
            "an accepted suggestion is resolved (status != .open) and must not appear on the triage list")
    }

    func test_openAnnotations_includesUnresolvedComment() {
        let comment = commentOp(opId: "01COMMENT", paragraphId: "k7m3", body: "nice line")

        let open = AnnotationLoading.openAnnotations(ops: [comment])
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.id, "01COMMENT")
        XCTAssertEqual(open.first?.status, .open)
        XCTAssertEqual(open.first?.body, "nice line")
    }

    // MARK: - Op builders (mirrors AnnotationWriterTests' shape)

    private func suggestionOp(opId: String, paragraphId: String, prior: String, next: String) -> Op {
        Op(
            opId: opId, docId: "d_x", at: Date(timeIntervalSince1970: 1_700_000_000),
            device: "phone:TEST", session: "s", kind: .claudeSuggestion,
            changes: [Op.ParagraphChange(paragraphId: paragraphId, prior: prior, next: next)],
            sequence: nil,
            provenance: Op.Provenance(sessionId: "s", annotationBody: "consider this"))
    }

    private func acceptOp(opId: String, sourceAnnotationId: String, paragraphId: String, prior: String, next: String) -> Op {
        Op(
            opId: opId, docId: "d_x", at: Date(timeIntervalSince1970: 1_700_000_100),
            device: "phone:TEST", session: "s", kind: .claudeAccept,
            changes: [Op.ParagraphChange(paragraphId: paragraphId, prior: prior, next: next)],
            sequence: nil,
            provenance: Op.Provenance(sessionId: "s", sourceAnnotationId: sourceAnnotationId))
    }

    private func commentOp(opId: String, paragraphId: String, body: String) -> Op {
        Op(
            opId: opId, docId: "d_x", at: Date(timeIntervalSince1970: 1_700_000_000),
            device: "phone:TEST", session: "s", kind: .claudeComment,
            changes: [Op.ParagraphChange(paragraphId: paragraphId, prior: nil, next: "")],
            sequence: nil,
            provenance: Op.Provenance(sessionId: "s", annotationBody: body))
    }
}
