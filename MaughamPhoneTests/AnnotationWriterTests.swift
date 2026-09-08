import XCTest
@testable import MaughamPhone
@testable import MaughamCore

/// Acceptance tests for the phone-side `AnnotationWriter` (Task F.2). The
/// load-bearing case is the accept round-trip: a `claudeAccept` of a suggested
/// change must carry the creation op's `changes` VERBATIM so the Mac
/// re-materializes the edit on replay (spec §3.9).
@MainActor
final class AnnotationWriterTests: XCTestCase {

    // Shared fixtures. The simulator's own identity may or may not hold a key,
    // so the seal half is asserted under a software signer — the same choice
    // `InboxCaptureWriterTests` makes, and for the same reason.
    private var identity: DeviceIdentity!
    private var deviceId: String { identity.deviceId }
    private let appVersion = "0.1.0"
    private let osVersion = "iOS 17.4"
    // The real on-disk format (ADR 0008): `doc-<8hex>` or `scene-<8hex>`.
    // The earlier `d_<ULID>` shape is fabricated and was behind the phone-v0.1.1
    // "No open annotations" footgun.
    private let docId = "doc-0f677d7e"

    override func setUpWithError() throws {
        identity = .softwareForTesting()
    }

    private func makeWriter(
        projectRoot: URL = FileManager.default.temporaryDirectory,
        identity: DeviceIdentity? = nil
    ) -> AnnotationWriter {
        AnnotationWriter(
            projectRoot: projectRoot,
            docId: docId,
            identity: identity ?? self.identity,
            appVersion: appVersion,
            osVersion: osVersion,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    /// A fresh project root that is cleaned up with the test. Each one is its
    /// own chain, so a remembered head never leaks between cases.
    private func makeProjectRoot(
        _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// The stream's raw lines, seals and all.
    private func lines(in url: URL) throws -> [Data] {
        try Data(contentsOf: url)
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }.map { Data($0) }
    }

    private func opLogURL(in projectRoot: URL, slug: DeviceSlug? = nil) -> URL {
        projectRoot
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent("\(docId).\((slug ?? identity.slug).raw).jsonl")
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
        XCTAssertEqual(decoded.device, deviceId,
            "the op carries the writer's own device id verbatim; the phone:<uuid> "
            + "prefix convention is gone — the id is a key fingerprint now")
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

    /// A suggestion the writer WITHDREW on another device must not be
    /// spliceable from a stale phone view (RULING-33's status/manuscript
    /// agreement + tripwire 19: the same rule as the Mac's guard, decided by
    /// the same shared AnnotationDeriver.isWithdrawn).
    func test_accept_refusesAWithdrawnSuggestion_givenTheMergedOps() throws {
        let para = "She was very angry."
        let creation = Op(
            opId: "01AWITHDRAWNSUG", docId: docId,
            at: Date(timeIntervalSince1970: 1_699_000_000),
            device: "mac", session: "s", kind: .claudeSuggestion,
            changes: [Op.ParagraphChange(
                paragraphId: "k7m3", prior: para, next: "furious")],
            provenance: Op.Provenance(sessionId: "s", annotationBody: "b"))
        let withdraw = Op(
            opId: "01BWITHDRAWOP00", docId: docId,
            at: Date(timeIntervalSince1970: 1_699_000_100),
            device: "mac", session: "s", kind: .annotationWithdraw,
            changes: [], provenance: Op.Provenance(
                sessionId: "s", sourceAnnotationId: "01AWITHDRAWNSUG"))
        let ann = AnnotationDeriver.derive(
            ops: [creation], paragraphs: ["k7m3": para]).first!

        let writer = makeWriter()
        XCTAssertThrowsError(try writer.makeAccept(
            for: ann, currentParagraph: para,
            verifyingAgainst: [creation, withdraw])) { error in
            guard case AnnotationWriter.WriteError
                .annotationWithdrawn(annotationId: ann.id) = error else {
                return XCTFail("expected annotationWithdrawn, got \(error)")
            }
        }
        // Without the withdraw in the verification set, the accept builds.
        XCTAssertNoThrow(try writer.makeAccept(
            for: ann, currentParagraph: para, verifyingAgainst: [creation]))
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

    // MARK: - 5. The chained append lands at the per-device op-log path

    func test_reject_appendsToPerDeviceOpLogFile() async throws {
        let projectRoot = try makeProjectRoot("AnnotationWriterTests")

        let writer = makeWriter(projectRoot: projectRoot)
        let ann = commentAnnotation()
        let appended = try await writer.reject(ann, reason: "off-voice")

        // The file must exist at .maugham/ops/<docId>.<slug>.jsonl (docId already
        // carries its full form; OpLogStore does NOT add a prefix).
        let expectedURL = opLogURL(in: projectRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path),
                      "op-log file should exist at the per-device path")

        // Load it back through JSONLAppendStore<Op> and confirm the op matches.
        let store = JSONLAppendStore<Op>(fileURL: expectedURL)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1, "one op — the seal is not an element")
        XCTAssertEqual(loaded.first, appended)
        XCTAssertEqual(loaded.first?.provenance?.sourceAnnotationId, ann.id)
        XCTAssertEqual(loaded.first?.provenance?.userResponse, "off-voice")
    }

    // MARK: - 6. The chain (task 8)

    /// Every op links to the head this phone verified, and a seal signs it on
    /// the spot — so the SECOND op's `prev` is the first op's SEAL, which is the
    /// head by then. The Mac's own reader sees two ops and no seals.
    func test_everyOpIsChainedAndSealedOnTheSpot() async throws {
        let projectRoot = try makeProjectRoot("AnnotationWriterChain")
        let writer = makeWriter(projectRoot: projectRoot)
        let ann = commentAnnotation()
        let first = try await writer.reject(ann, reason: "off-voice")
        let second = try await writer.archive(ann)

        let url = opLogURL(in: projectRoot)
        let lines = try lines(in: url)
        XCTAssertEqual(lines.count, 4, "an op and a seal for each of the two ops")

        XCTAssertEqual(OpLogChain.prev(ofLine: lines[0]) ?? nil, OpLogChain.genesis,
                       "the first line of a fresh file chains to the genesis sentinel")
        let firstSeal = try XCTUnwrap(OpLogChain.Seal.parse(lines[1]))
        XCTAssertTrue(firstSeal.verifies())
        XCTAssertEqual(firstSeal.key, identity.fingerprint)
        XCTAssertEqual(firstSeal.head, OpLogChain.lineHash(lines[0]))

        XCTAssertEqual(OpLogChain.prev(ofLine: lines[2]) ?? nil,
                       OpLogChain.lineHash(lines[1]),
                       "the second op chains onto the head — the seal that preceded it")
        let secondSeal = try XCTUnwrap(OpLogChain.Seal.parse(lines[3]))
        XCTAssertTrue(secondSeal.verifies())
        XCTAssertEqual(secondSeal.head, OpLogChain.lineHash(lines[2]))

        let loaded = try await JSONLAppendStore<Op>(fileURL: url).load()
        XCTAssertEqual(loaded.map(\.opId), [first, second].map(\.opId).sorted(),
                       "the Mac reader sees two ops and no seals")
    }

    /// A phone with no key is a state, not a failure: the ops are written,
    /// chained to each other, and nothing throws — there is simply no seal.
    func test_aPhoneWithNoKeyChainsItsOpsAndSealsNothing() async throws {
        let projectRoot = try makeProjectRoot("AnnotationWriterUnsigned")
        let unsigned = DeviceIdentity.unsignedForTesting(token: Data(repeating: 7, count: 32))
        let writer = makeWriter(projectRoot: projectRoot, identity: unsigned)
        let ann = commentAnnotation()
        _ = try await writer.reject(ann, reason: "no")
        _ = try await writer.archive(ann)

        let url = opLogURL(in: projectRoot, slug: unsigned.slug)
        let lines = try lines(in: url)
        XCTAssertEqual(lines.count, 2, "two ops, no seals")
        XCTAssertEqual(OpLogChain.prev(ofLine: lines[1]) ?? nil,
                       OpLogChain.lineHash(lines[0]))
        let loaded = try await JSONLAppendStore<Op>(fileURL: url).load()
        XCTAssertEqual(loaded.count, 2)
    }

    /// The op's `device` field and the stream's own filename come from ONE
    /// name — the identity's. Two spellings could file an op under a device
    /// whose key never signed it.
    func test_theOpsDeviceIsTheIdentityThatSignedIt() async throws {
        let projectRoot = try makeProjectRoot("AnnotationWriterName")
        let writer = makeWriter(projectRoot: projectRoot)
        let appended = try await writer.reject(commentAnnotation(), reason: "no")

        XCTAssertEqual(appended.device, identity.deviceId)
        let url = opLogURL(in: projectRoot)
        XCTAssertEqual(url.lastPathComponent,
                       "\(docId).\(identity.slug.raw).jsonl")
        let seal = try XCTUnwrap(OpLogChain.Seal.parse(try lines(in: url)[1]))
        XCTAssertEqual(seal.key, identity.fingerprint)
    }
}
