import XCTest
@testable import MaughamPhone
import MaughamCore

/// Acceptance tests for the phone-side `AnnotationWriter` (Task F.2). The
/// load-bearing case is the accept round-trip: a `claudeAccept` of a suggested
/// change must carry the creation op's `changes` VERBATIM so the Mac
/// re-materializes the edit on replay (spec §3.9).
final class AnnotationWriterTests: XCTestCase {

    // Shared fixtures.
    private let deviceId = "phone:TEST"
    private let appVersion = "0.1.0"
    private let osVersion = "iOS 17.4"
    // The real on-disk format (ADR 0008): `doc-<8hex>` or `scene-<8hex>`.
    // The earlier `d_<ULID>` shape is fabricated and was behind the phone-v0.1.1
    // "No open annotations" footgun.
    private let docId = "doc-0f677d7e"

    private func makeWriter(projectRoot: URL = FileManager.default.temporaryDirectory) -> AnnotationWriter {
        AnnotationWriter(
            projectRoot: projectRoot,
            docId: docId,
            deviceId: deviceId,
            io: CoordinatedFileIO(),
            appVersion: appVersion,
            osVersion: osVersion,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    /// A `.comment` annotation (no paragraph mutation).
    private func commentAnnotation() -> Annotation {
        Annotation(
            id: "01CREATIONCOMMENT", kind: .comment, paragraphId: "k7m3",
            body: "nice line", suggestedText: nil, priorText: "The sun was setting.",
            createdAt: Date(timeIntervalSince1970: 1_699_000_000), createdBySession: "s",
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false)
    }

    // Encode an op the same way the writer (and the Mac reader) does.
    private func encodeOp(_ op: Op) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(op)
    }

    private func decodeOp(_ data: Data) throws -> Op {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return try dec.decode(Op.self, from: data)
    }

    // MARK: - 1. Reject op shape

    func test_makeReject_opShape_andSnakeCaseKeys() throws {
        let writer = makeWriter()
        let ann = commentAnnotation()
        let reason = "doesn't fit the voice"

        let op = writer.makeReject(for: ann, reason: reason)
        let data = try encodeOp(op)
        let decoded = try decodeOp(data)

        XCTAssertEqual(decoded.kind, .claudeReject)
        XCTAssertEqual(decoded.kind.rawValue, "claude_reject")
        XCTAssertEqual(decoded.changes, [], "a reject carries no manuscript change")
        XCTAssertEqual(decoded.provenance?.sourceAnnotationId, ann.id)
        XCTAssertEqual(decoded.provenance?.userResponse, reason)
        XCTAssertEqual(decoded.provenance?.appVersion, appVersion)
        XCTAssertEqual(decoded.provenance?.osVersion, osVersion)
        XCTAssertTrue(decoded.device.hasPrefix("phone:"))
        // session and provenance.sessionId are the SAME minted value.
        XCTAssertEqual(decoded.session, decoded.provenance?.sessionId)
        XCTAssertNil(decoded.sequence, "lifecycle ops don't set sequence")

        // The raw JSON must use the snake_case keys the Mac decodes on.
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"claude_reject\""))
        XCTAssertTrue(json.contains("\"source_annotation_id\""))
        XCTAssertTrue(json.contains("\"user_response\""))
        XCTAssertTrue(json.contains("\"app_version\""))
        XCTAssertTrue(json.contains("\"os_version\""))
    }

    func test_makeReject_nilReason_leavesUserResponseNil() throws {
        let writer = makeWriter()
        let op = writer.makeReject(for: commentAnnotation(), reason: nil)
        XCTAssertNil(op.provenance?.userResponse)
    }

    // MARK: - 2. Accept of a suggested change — THE load-bearing regression net

    func test_makeAccept_suggestedChange_copiesChangeVerbatim_andMaterializes() throws {
        let creationOpId = "01CREATIONSUGGESTION"
        // Build the creation (suggestion) op exactly as the Mac would.
        let creation = Op(
            opId: creationOpId, docId: docId, at: Date(timeIntervalSince1970: 1_699_000_000),
            device: "mac", session: "s", kind: .claudeSuggestion,
            changes: [Op.ParagraphChange(
                paragraphId: "k7m3",
                prior: "The sun was setting.",
                next: "The sun bled into the horizon.")],
            provenance: Op.Provenance(sessionId: "s", annotationBody: "stronger image"))

        // Derive the annotation the way the iOS detail view will.
        let ann = AnnotationDeriver.derive(
            ops: [creation],
            paragraphs: ["k7m3": "The sun was setting."]).first!
        XCTAssertEqual(ann.kind, .suggestedChange)
        XCTAssertEqual(ann.id, creationOpId)

        let writer = makeWriter()
        let accept = try writer.makeAccept(for: ann)

        // (a) The accept copies the change verbatim.
        XCTAssertEqual(accept.kind, .claudeAccept)
        XCTAssertEqual(accept.changes, creation.changes,
                       "claude_accept MUST carry the suggestion's ParagraphChange verbatim")
        XCTAssertEqual(accept.changes.first?.paragraphId, "k7m3")
        XCTAssertEqual(accept.changes.first?.prior, "The sun was setting.")
        XCTAssertEqual(accept.changes.first?.next, "The sun bled into the horizon.")

        // (b) Materialization round-trip: replaying [creation, accept] applies it.
        let withAccept = Deriver.derive(ops: [creation, accept])
        XCTAssertEqual(withAccept.paragraphs["k7m3"], "The sun bled into the horizon.",
                       "the manuscript materialized the accepted change on replay")

        // (c) Without the accept, the suggestion alone does NOT materialize — proves
        // it's the accept, not the suggestion, that mutates the manuscript.
        let withoutAccept = Deriver.derive(ops: [creation])
        XCTAssertNotEqual(withoutAccept.paragraphs["k7m3"], "The sun bled into the horizon.",
                          "the suggestion op alone must not overwrite the live paragraph")

        // (d) The annotation now reads as accepted.
        let resolved = AnnotationDeriver.derive(
            ops: [creation, accept],
            paragraphs: ["k7m3": "The sun bled into the horizon."]).first!
        XCTAssertEqual(resolved.status, .accepted)
    }

    /// A span whose quoted phrase is no longer in the current paragraph is
    /// REFUSED (RULING-5, 2026-08-09): `makeAccept` throws rather than build an
    /// accept that would replace the whole paragraph with the bare span-sized
    /// replacement. Same decision as the Mac, made by the shared
    /// `SuggestionSplice.attempt` (tripwire 19).
    func test_makeAccept_lostSpanAnchor_isRefused() throws {
        let para = "She was very angry."
        let span = SpanAnchorResolver.capture(in: para, range: 8..<18)
        let creation = Op(
            opId: "01LOSTANCHORSUG", docId: docId,
            at: Date(timeIntervalSince1970: 1_699_000_000),
            device: "mac", session: "s", kind: .claudeSuggestion,
            changes: [Op.ParagraphChange(
                paragraphId: "k7m3", prior: para, next: "furious")],
            provenance: Op.Provenance(
                sessionId: "s", annotationBody: "tighten",
                spanQuote: span.quote, spanPrefix: span.prefix,
                spanSuffix: span.suffix, spanPosHint: span.posHint))
        let ann = AnnotationDeriver.derive(
            ops: [creation], paragraphs: ["k7m3": para]).first!

        let writer = makeWriter()
        XCTAssertThrowsError(try writer.makeAccept(
            for: ann, currentParagraph: "She was livid about it all.")) { error in
            guard case AnnotationWriter.WriteError
                .suggestionAnchorLost(annotationId: ann.id) = error else {
                return XCTFail("expected suggestionAnchorLost, got \(error)")
            }
        }
    }

    /// Span-anchored (sub-paragraph) suggestion: the phone accept must SPLICE the
    /// bare replacement into the current paragraph (shared `SuggestionSplice`),
    /// not replace the whole paragraph with the bare word. Mirrors the Mac.
    func test_makeAccept_spanSuggestion_splicesOnlyTheSpan() throws {
        let para = "She was very angry."
        // Span over "very angry" (grapheme offsets 8..<18).
        let span = SpanAnchorResolver.capture(in: para, range: 8..<18)
        let creation = Op(
            opId: "01SPANSUGGESTION", docId: docId,
            at: Date(timeIntervalSince1970: 1_699_000_000),
            device: "mac", session: "s", kind: .claudeSuggestion,
            // The op stores the BARE suggested text.
            changes: [Op.ParagraphChange(
                paragraphId: "k7m3", prior: para, next: "furious")],
            provenance: Op.Provenance(
                sessionId: "s", annotationBody: "tighten",
                spanQuote: span.quote, spanPrefix: span.prefix,
                spanSuffix: span.suffix, spanPosHint: span.posHint))

        let ann = AnnotationDeriver.derive(
            ops: [creation], paragraphs: ["k7m3": para]).first!
        XCTAssertEqual(ann.suggestedText, "furious",
            "bare suggestion is stored for display")

        let writer = makeWriter()
        let accept = try writer.makeAccept(for: ann, currentParagraph: para)

        XCTAssertEqual(accept.changes.first?.next, "She was furious.",
            "phone accept must splice the span into the current paragraph")

        // Round-trip: replay materializes the spliced paragraph.
        XCTAssertEqual(
            Deriver.derive(ops: [creation, accept]).paragraphs["k7m3"],
            "She was furious.")
    }

    // MARK: - 3. Accept of a non-suggestion is empty-changes

    func test_makeAccept_comment_producesEmptyChanges() throws {
        let writer = makeWriter()
        let accept = try writer.makeAccept(for: commentAnnotation())
        XCTAssertEqual(accept.kind, .claudeAccept)
        XCTAssertEqual(accept.changes, [],
                       "a comment accept must not fabricate a manuscript change")
    }

    /// Fail loud: a malformed suggestion (nil suggestedText) THROWS rather than
    /// emitting an empty-changes accept that would mark the annotation accepted
    /// while materializing nothing (silent manuscript data loss).
    func test_makeAccept_malformedSuggestion_throws() {
        let malformed = Annotation(
            id: "01MALFORMED", kind: .suggestedChange, paragraphId: "k7m3",
            body: "x", suggestedText: nil, priorText: "old",
            createdAt: Date(), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false)
        // Disable the Debug assertion so we can exercise the thrown error without
        // aborting the test process; production keeps the loud assert.
        var writer = makeWriter()
        writer.assertOnMalformed = false
        XCTAssertThrowsError(try writer.makeAccept(for: malformed)) { error in
            guard case AnnotationWriter.WriteError.malformedSuggestion(let id) = error else {
                return XCTFail("expected .malformedSuggestion, got \(error)")
            }
            XCTAssertEqual(id, "01MALFORMED")
        }
    }

    // MARK: - 4. Provenance forensic fields + replay-invariance

    func test_provenanceFields_populated_andIgnoredByReplay() async throws {
        let writer = makeWriter()
        let op = writer.makeReject(for: commentAnnotation(), reason: "nope")
        XCTAssertEqual(op.provenance?.appVersion, appVersion)
        XCTAssertEqual(op.provenance?.osVersion, osVersion)

        // Round-trips through JSONLAppendStore<Op> encode/decode unchanged.
        let roundTripped = try decodeOp(try encodeOp(op))
        XCTAssertEqual(roundTripped, op)

        // Replay is identical whether or not the forensic fields are present —
        // they're ignored by the deriver (a reject contributes nothing either way).
        let withFields = Deriver.derive(ops: [op])
        let strippedProvenance = Op.Provenance(
            sourceAnnotationId: op.provenance?.sourceAnnotationId,
            userResponse: op.provenance?.userResponse)
        let stripped = Op(
            opId: op.opId, docId: op.docId, at: op.at, device: op.device,
            session: op.session, kind: op.kind, changes: op.changes,
            sequence: op.sequence, provenance: strippedProvenance)
        let withoutFields = Deriver.derive(ops: [stripped])
        XCTAssertEqual(withFields, withoutFields)
    }

    // MARK: - 5. Coordinated append lands at the per-device op-log path

    @MainActor
    func test_reject_appendsToPerDeviceOpLogFile() async throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let writer = makeWriter(projectRoot: projectRoot)
        let ann = commentAnnotation()
        let appended = try await writer.reject(ann, reason: "off-voice")

        // The file must exist at .maugham/ops/<docId>.<slug>.jsonl (docId already
        // carries the d_ prefix; OpLogStore does NOT add another).
        let expectedURL = projectRoot
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent("\(docId).\(DeviceSlug.make(from: deviceId).raw).jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path),
                      "op-log file should exist at the per-device path")

        // Load it back through JSONLAppendStore<Op> and confirm the op matches.
        let store = JSONLAppendStore<Op>(fileURL: expectedURL)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, appended)
        XCTAssertEqual(loaded.first?.provenance?.sourceAnnotationId, ann.id)
        XCTAssertEqual(loaded.first?.provenance?.userResponse, "off-voice")
    }
}
