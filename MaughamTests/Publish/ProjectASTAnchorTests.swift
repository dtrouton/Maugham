import XCTest
import MaughamCore
@testable import Maugham

/// P3 Task 1 — the anchor seam. Every op-log paragraph's `¶id` rides the FIRST
/// AST node that paragraph produced, carried on `ProjectAST.Section.anchors`
/// (node index → `¶id`). Tasks 2–3 turn those into `\hypertarget{p-<tag>-<id>}`
/// and `id="p-<tag>-<id>"`; nothing consumes them yet.
///
/// The load-bearing pin is `test_nodesAreIdenticalWithAndWithoutParagraphs…`:
/// handing the builder `paragraphs` must change NOTHING about the nodes. The
/// builder still parses `displayText` exactly as it always did and only
/// *computes* the anchors alongside — anchors are a projection, never an input
/// to parsing.
@MainActor
final class ProjectASTAnchorTests: XCTestCase {

    // MARK: - fixtures

    private struct StubSource: ProjectASTBuilder.Source {
        let pieces: [ProjectASTBuilder.PieceRef]
        func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] { pieces }
    }

    private struct Piece {
        let displayText: String
        let paragraphs: [(id: String, text: String)]
    }

    /// Split a body the way the op log really does (`ParagraphParser`, the same
    /// call `Document.load`'s bootstrap makes), mint 4-char ids from
    /// `ParagraphID`'s own alphabet (tripwire 8), and materialize the anchored
    /// `.md` — so `displayText` here is byte-identical to what
    /// `ProjectStoreASTSource` hands the builder in production.
    private func makePiece(_ body: String, fountain: Bool = false) -> Piece {
        let parsed = ParagraphParser.parse(body, preservesHeldBlankLines: fountain)
        let ids = (0..<parsed.count).map { String(format: "aa%02d", $0) }
        var map: [String: String] = [:]
        for (id, p) in zip(ids, parsed) { map[id] = p.text }
        return Piece(
            displayText: Materializer.materialize(paragraphs: map, sequence: ids),
            paragraphs: ids.map { (id: $0, text: map[$0] ?? "") })
    }

    private func section(
        _ piece: Piece, mode: ProjectAST.Mode, withParagraphs: Bool = true
    ) throws -> ProjectAST.Section {
        let ref = ProjectASTBuilder.PieceRef(
            pieceID: "piece", title: "T", mode: mode,
            displayText: piece.displayText,
            paragraphs: withParagraphs ? piece.paragraphs : nil)
        let ast = try ProjectASTBuilder.build(from: StubSource(pieces: [ref]))
        return try XCTUnwrap(ast.sections.first)
    }

    // MARK: - fountain

    /// A cue and its speech carry no blank line between them, so they are ONE
    /// op-log paragraph — one id, on the cue. The dialogue node that follows in
    /// the same paragraph takes none: an anchor per paragraph, not per node.
    func test_fountainCueAndDialogue_oneIdOnTheCue_noneOnTheDialogue() throws {
        let piece = makePiece(
            "INT. KITCHEN - DAY\n\nAARON\nMorning, everyone.", fountain: true)
        XCTAssertEqual(piece.paragraphs.count, 2, "fixture must be two paragraphs")

        let s = try section(piece, mode: .fountain)
        XCTAssertEqual(s.nodes, [
            .fountain(.sceneHeading("INT. KITCHEN - DAY", sceneNumber: nil)),
            .fountain(.character("AARON")),
            .fountain(.dialogue("Morning, everyone.")),
        ])
        XCTAssertEqual(s.anchors, [0: "aa00", 1: "aa01"])
        XCTAssertNil(s.anchors[2], "the dialogue shares the cue's paragraph — one id, not two")
    }

    /// Two action lines with no blank between them are one paragraph and
    /// coalesce into one node — the id rides that node, and the anchor is
    /// looked up by the buffer's START line, not the line that flushed it.
    func test_coalescedActionLinesInOneParagraph_takeOneId() throws {
        let piece = makePiece(
            "INT. KITCHEN - DAY\n\nShe crosses the room.\nShe opens the window.",
            fountain: true)
        XCTAssertEqual(piece.paragraphs.count, 2, "fixture must be two paragraphs")

        let s = try section(piece, mode: .fountain)
        XCTAssertEqual(s.nodes, [
            .fountain(.sceneHeading("INT. KITCHEN - DAY", sceneNumber: nil)),
            .fountain(.action("She crosses the room. She opens the window.")),
        ])
        XCTAssertEqual(s.anchors, [0: "aa00", 1: "aa01"])
    }

    // MARK: - prose

    func test_proseBlockquote_takesItsParagraphsId() throws {
        let piece = makePiece("Preamble.\n\n> Quoted line.")
        XCTAssertEqual(piece.paragraphs.count, 2, "fixture must be two paragraphs")

        let s = try section(piece, mode: .prose)
        XCTAssertEqual(s.nodes.count, 2)
        guard case .prose(.blockquote) = s.nodes[1] else {
            return XCTFail("second node must be a blockquote, got \(s.nodes[1])")
        }
        XCTAssertEqual(s.anchors, [0: "aa00", 1: "aa01"])
    }

    func test_twoParagraphProseDoc_putsIdsOnIndicesZeroAndOne() throws {
        let piece = makePiece("First paragraph with *emphasis*.\n\nSecond paragraph, plain.")
        let s = try section(piece, mode: .prose)
        XCTAssertEqual(s.nodes.count, 2)
        XCTAssertEqual(s.anchors[0], "aa00")
        XCTAssertEqual(s.anchors[1], "aa01")
        XCTAssertEqual(s.anchors.count, 2)
    }

    /// A fenced block with an internal blank line is TWO op-log paragraphs (the
    /// blank splits them) but ONE `.verbatim` node — so one id lands, on the
    /// node the first of those paragraphs started. The second paragraph gets no
    /// anchor at all, which is the honest answer: it produced no node of its own.
    func test_fencedCodeWithInternalBlankLine_takesOneId() throws {
        let piece = makePiece("""
        Preamble text.

        ```
        line one

        line three
        ```

        Trailing text.
        """)
        XCTAssertEqual(piece.paragraphs.count, 4,
            "fixture must split the fence at its internal blank")

        let s = try section(piece, mode: .prose)
        XCTAssertEqual(s.nodes.count, 3, "paragraph + verbatim + paragraph")
        guard case .prose(.verbatim) = s.nodes[1] else {
            return XCTFail("second node must be the fence, got \(s.nodes[1])")
        }
        XCTAssertEqual(s.anchors[1], "aa01", "the fence takes its FIRST paragraph's id")
        XCTAssertEqual(s.anchors, [0: "aa00", 1: "aa01", 2: "aa03"])
    }

    // MARK: - nil paragraphs

    /// With no paragraphs the builder is byte-for-byte what it was: same nodes,
    /// no anchors. The `withParagraphs: true` control in the same test is what
    /// keeps this from passing vacuously.
    func test_nilParagraphs_yieldsNoAnchorsAndIdenticalNodes() throws {
        let piece = makePiece("First paragraph.\n\nSecond paragraph.")
        let without = try section(piece, mode: .prose, withParagraphs: false)
        let with = try section(piece, mode: .prose, withParagraphs: true)

        XCTAssertEqual(without.nodes, with.nodes)
        XCTAssertEqual(without.anchors, [:], "nil paragraphs must produce no anchors")
        XCTAssertFalse(with.anchors.isEmpty,
            "control: the same piece WITH paragraphs must anchor, or the assertion above is vacuous")
    }

    /// `Section.anchors` defaults to `[:]`, so every existing construction site
    /// (emitter tests included) keeps compiling and keeps meaning what it meant.
    func test_sectionAnchorsDefaultToEmpty() {
        let s = ProjectAST.Section(pieceID: "p", title: "T", mode: .prose, nodes: [])
        XCTAssertEqual(s.anchors, [:])
    }

    // MARK: - the equivalence pin (constraint 2)

    /// Every fixture body `ASTTranslationSubstitutionTests` uses, built both
    /// ways. Handing the builder `paragraphs` must not move a single node —
    /// the builder parses `displayText` exactly as before and only computes the
    /// anchors from the paragraph spans.
    func test_nodesAreIdenticalWithAndWithoutParagraphs_everyTranslationFixtureBody() throws {
        let fixtures: [(body: String, mode: ProjectAST.Mode)] = [
            ("First paragraph with *emphasis*.\n\nSecond paragraph, plain.", .prose),
            ("INT. KITCHEN - DAY\n\nAARON\nMorning, everyone.", .fountain),
            ("""
            Preamble text.

            ```
            line one

            line three
            ```

            Trailing text.
            """, .prose),
            ("INT. KITCHEN - DAY\n\nAARON\nWhat's for breakfast?\n", .fountain),
            ("> **Doctor:** How are you feeling today?", .prose),
        ]
        for (body, mode) in fixtures {
            let piece = makePiece(body, fountain: mode == .fountain)
            let with = try section(piece, mode: mode, withParagraphs: true)
            let without = try section(piece, mode: mode, withParagraphs: false)
            XCTAssertEqual(with.nodes, without.nodes,
                "paragraphs must not change the nodes for \(body.debugDescription)")
            XCTAssertFalse(with.nodes.isEmpty, "fixture produced no nodes")
            XCTAssertFalse(with.anchors.isEmpty,
                "control: \(body.debugDescription) must anchor something")
        }
    }

    // MARK: - negative arms

    /// Paragraphs that do not join back to the parsed text are a source the
    /// builder cannot map honestly — it refuses rather than guessing an
    /// alignment, because a wrong anchor silently links a reader to the wrong
    /// paragraph.
    ///
    /// This fixture's paragraphs line up PERFECTLY by line count and differ only
    /// in their words, so the arithmetic reconciliation below cannot see it —
    /// only the text equality can. Without that check both nodes would take an
    /// id from a document they have nothing to do with.
    func test_paragraphsThatDoNotJoinToTheDisplayText_yieldNoAnchors() throws {
        let ref = ProjectASTBuilder.PieceRef(
            pieceID: "piece", title: "T", mode: .prose,
            displayText: "Alpha.\n\nBeta.",
            paragraphs: [(id: "aa00", text: "Gamma."), (id: "aa01", text: "Delta.")])
        let ast = try ProjectASTBuilder.build(from: StubSource(pieces: [ref]))
        let s = try XCTUnwrap(ast.sections.first)
        XCTAssertEqual(s.nodes, [.paragraph("Alpha."), .paragraph("Beta.")],
            "the nodes still come from displayText")
        XCTAssertEqual(s.anchors, [:], "a join mismatch must refuse, not guess")
    }

    /// The other half of the reconciliation, and the one the text equality
    /// cannot see: a paragraph whose own body carries an anchor-shaped line.
    /// `stripAnchors` eats that line and the blank after it, so the join still
    /// compares EQUAL to the parsed text while every line index past it has
    /// slid by two. The spans are then unmappable, and a partial map is worse
    /// than none — here it would anchor "Alpha." and silently leave "Beta."
    /// with nothing, which reads as a paragraph that simply cannot be linked to.
    func test_paragraphWhoseBodyCarriesAnAnchorLine_yieldsNoAnchors() throws {
        let paragraphs = [
            (id: "aa00", text: "\(ParagraphID.formatComment("bb00"))\n\nAlpha."),
            (id: "aa01", text: "Beta."),
        ]
        var map: [String: String] = [:]
        for p in paragraphs { map[p.id] = p.text }
        let ref = ProjectASTBuilder.PieceRef(
            pieceID: "piece", title: "T", mode: .prose,
            displayText: Materializer.materialize(
                paragraphs: map, sequence: paragraphs.map(\.id)),
            paragraphs: paragraphs)
        let ast = try ProjectASTBuilder.build(from: StubSource(pieces: [ref]))
        let s = try XCTUnwrap(ast.sections.first)
        XCTAssertEqual(s.nodes, [.paragraph("Alpha."), .paragraph("Beta.")],
            "the nodes still come from displayText")
        XCTAssertEqual(s.anchors, [:], "an unreconcilable span must refuse, not guess")
    }

    /// Paragraphs that reconstitute nothing like the parsed text — a shorter
    /// document entirely. Refuses for the same reason.
    func test_paragraphsWhoseLineCountsDoNotReconcile_yieldNoAnchors() throws {
        let ref = ProjectASTBuilder.PieceRef(
            pieceID: "piece", title: "T", mode: .prose,
            displayText: "Something entirely else.\n\nAnd more.",
            paragraphs: [(id: "aa00", text: "Not the same text at all.")])
        let ast = try ProjectASTBuilder.build(from: StubSource(pieces: [ref]))
        let s = try XCTUnwrap(ast.sections.first)
        XCTAssertEqual(s.nodes.count, 2, "the nodes still come from displayText")
        XCTAssertEqual(s.anchors, [:], "an unreconcilable span must refuse, not guess")
    }

    /// `stripAnchors` trims the whole text's outer whitespace, so a paragraph 0
    /// that opens with a blank line makes the parsed text start one line LATER
    /// than the joined text. Without accounting for that shift every anchor
    /// after the first lands on the wrong paragraph — here the second one
    /// vanishes entirely.
    func test_leadingBlankLineInParagraphZero_doesNotShiftTheAnchors() throws {
        let paragraphs = [(id: "aa00", text: "\nFirst."), (id: "aa01", text: "Second.")]
        var map: [String: String] = [:]
        for p in paragraphs { map[p.id] = p.text }
        let ref = ProjectASTBuilder.PieceRef(
            pieceID: "piece", title: "T", mode: .prose,
            displayText: Materializer.materialize(
                paragraphs: map, sequence: paragraphs.map(\.id)),
            paragraphs: paragraphs)
        let ast = try ProjectASTBuilder.build(from: StubSource(pieces: [ref]))
        let s = try XCTUnwrap(ast.sections.first)
        XCTAssertEqual(s.nodes, [.paragraph("First."), .paragraph("Second.")])
        XCTAssertEqual(s.anchors, [0: "aa00", 1: "aa01"])
    }

    // MARK: - the production source actually hands them over

    /// Everything above builds `PieceRef`s by hand, so all of it would still
    /// pass if `ProjectStoreASTSource` quietly handed `paragraphs: nil`. This is
    /// the pin that says the real adapter wires them — on the nil-language path
    /// (closed doc → `derivedCache`) and on a language edition, whose ids come
    /// from the translation deriver's entries.
    func test_projectStoreASTSource_handsParagraphsOnBothPaths() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASTAnchors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = "manuscript/story.md"
        let docId = "doc-story-md"
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let docURL = tmp.appendingPathComponent(path)
        try "First paragraph.\n\nSecond paragraph.".write(
            to: docURL, atomically: true, encoding: .utf8)

        let item = StructureItem(id: docId, title: "Ch", type: .document, path: path)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent(ProjectManifest.fileName))

        let store = try await ProjectStore.load(from: tmp)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let ids = doc.sequence
        XCTAssertEqual(ids.count, 2, "fixture must bootstrap two paragraphs")

        // Verbatim translation records so the language path has entries.
        for id in ids {
            let source = doc.paragraphs[id] ?? ""
            try await TranslationStore.append(
                TranslationRecord(
                    paragraphId: id, language: "es", text: source,
                    sourceHash: TranslationHash.hash(source), verbatim: true),
                forDocId: docId, deviceSlug: DeviceSlug.make(from: "test-mac"), in: store.url)
        }

        let source = try ProjectASTBuilder
            .build(from: ProjectStoreASTSource(projectStore: store))
            .sections
        let translated = try ProjectASTBuilder
            .build(from: ProjectStoreASTSource(projectStore: store, language: "es"))
            .sections

        XCTAssertEqual(source.first?.anchors, [0: ids[0], 1: ids[1]],
            "the nil-language path must hand the op log's own ¶ids through")
        XCTAssertEqual(translated.first?.anchors, [0: ids[0], 1: ids[1]],
            "a language edition anchors on the SAME source ¶ids — a translation "
            + "is the same paragraph in another language, not a new one")
    }

    /// One paragraph, several nodes: the FIRST takes the id and the rest take
    /// none. A blockquote whose body is a quoted heading plus quoted prose is
    /// one node, so this uses the shape that really produces two — a fountain
    /// cue block, whose three nodes are one paragraph.
    func test_laterNodesInOneParagraphsSpan_takeNoId() throws {
        let piece = makePiece("AARON\n(quietly)\nMorning.", fountain: true)
        XCTAssertEqual(piece.paragraphs.count, 1, "fixture must be ONE paragraph")

        let s = try section(piece, mode: .fountain)
        XCTAssertEqual(s.nodes.count, 3, "cue + parenthetical + dialogue")
        XCTAssertEqual(s.anchors, [0: "aa00"],
            "one paragraph anchors exactly one node — its first")
    }
}
