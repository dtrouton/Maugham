import XCTest
@testable import MaughamPhone
import MaughamCore

/// Unit tests for the pure core of the Annotations tab (Task F.4): doc-id
/// parsing out of an `.maugham/ops/` directory listing, and the open-annotation
/// projection from a doc's op stream.
final class AnnotationLoadingTests: XCTestCase {

    // Two real-shaped doc ids as actually minted (ADR 0008): "<prefix>-<id>",
    // e.g. `doc-<8hex>` from ProjectFactory and `scene-<8hex>` for screenplay
    // scenes. These are NOT a `d_<ULID>` shape — the on-disk filenames are the
    // ground truth (see ~/Documents/Maugham/*/.maugham/ops/).
    private let docA = "doc-0f677d7e"
    private let docB = "scene-f8c9644e"

    // MARK: - docIds

    func test_docIds_parsesPerDeviceAndLegacy_ignoringNonOpLogFiles() {
        let filenames = [
            "\(docA).denvers-macbook-air-loca-8a62e7c9.jsonl",  // per-device
            "\(docA).jsonl",                                    // legacy unsuffixed, same doc
            "\(docA).mcp-cba8e063.jsonl",                       // another device, same doc
            "\(docB).phoneB.jsonl",                             // a second distinct doc
            "garbage.txt",                                      // not jsonl
            "__project__.jsonl",                                // synthetic task/checkpoint log: no annotations, excluded
            "__project__.macA.jsonl",                           // per-device synthetic, excluded
        ]
        let ids = AnnotationLoading.docIds(inOpsDirectoryFilenames: filenames)
        XCTAssertEqual(ids, [docA, docB],
            "real doc-/scene- ids are recognized; per-device + legacy files collapse to one; __project__ and non-jsonl files are excluded")
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

    // MARK: - allAnnotations

    func test_allAnnotations_includesResolvedAndOpen() {
        let creation = suggestionOp(opId: "01CREATION", paragraphId: "k7m3", prior: "Old.", next: "New.")
        let accept = acceptOp(opId: "01ACCEPT", sourceAnnotationId: "01CREATION", paragraphId: "k7m3", prior: "Old.", next: "New.")
        let comment = commentOp(opId: "01COMMENT", paragraphId: "k7m3", body: "nice line")

        let all = AnnotationLoading.allAnnotations(ops: [creation, accept, comment])
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        XCTAssertEqual(all.count, 2, "both the resolved suggestion and the open comment are present")
        XCTAssertEqual(byId["01CREATION"]?.status, .accepted)
        XCTAssertEqual(byId["01COMMENT"]?.status, .open)
    }

    // MARK: - Op builders (mirrors AnnotationWriterTests' shape)

    private func suggestionOp(opId: String, paragraphId: String, prior: String, next: String) -> Op {
        Op(
            opId: opId, docId: "doc-0f677d7e", at: Date(timeIntervalSince1970: 1_700_000_000),
            device: "phone:TEST", session: "s", kind: .claudeSuggestion,
            changes: [Op.ParagraphChange(paragraphId: paragraphId, prior: prior, next: next)],
            sequence: nil,
            provenance: Op.Provenance(sessionId: "s", annotationBody: "consider this"))
    }

    private func acceptOp(opId: String, sourceAnnotationId: String, paragraphId: String, prior: String, next: String) -> Op {
        Op(
            opId: opId, docId: "doc-0f677d7e", at: Date(timeIntervalSince1970: 1_700_000_100),
            device: "phone:TEST", session: "s", kind: .claudeAccept,
            changes: [Op.ParagraphChange(paragraphId: paragraphId, prior: prior, next: next)],
            sequence: nil,
            provenance: Op.Provenance(sessionId: "s", sourceAnnotationId: sourceAnnotationId))
    }

    private func commentOp(opId: String, paragraphId: String, body: String) -> Op {
        Op(
            opId: opId, docId: "doc-0f677d7e", at: Date(timeIntervalSince1970: 1_700_000_000),
            device: "phone:TEST", session: "s", kind: .claudeComment,
            changes: [Op.ParagraphChange(paragraphId: paragraphId, prior: nil, next: "")],
            sequence: nil,
            provenance: Op.Provenance(sessionId: "s", annotationBody: body))
    }
}
