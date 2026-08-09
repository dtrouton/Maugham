import XCTest
import MaughamCore
@testable import Maugham

/// Provenance on a card, on a line and on a region, across the disk boundary.
///
/// Schema 7 (1C-c3's `author`) is additive-optional in BOTH directions, which is
/// the pattern every canvas bump has kept: an older sidecar decodes unchanged,
/// and a newer one costs an older build the arrangement and never the words
/// (`CanvasStore.load`). The version literal itself is asserted once, in
/// `CanvasLineCodecTests.test_theSchemaVersionIsNine` — a fifth copy of the
/// number here would be a fifth site to rebump.
///
/// **nil means the writer.** There is no `.human`-by-default anywhere: a canvas
/// written before this build, and every card the writer makes in it, carries no
/// `author` key at all.
final class CanvasAuthorCodecTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let l1 = CanvasLineID("l1")
    private let r1 = CanvasRegionID("r1")

    private func region(_ author: AnnotationAuthor.SourceKind? = nil) -> CanvasRegion {
        CanvasRegion(id: r1, label: "Act II fog",
                     frame: CGRect(x: 10, y: 20, width: 300, height: 200),
                     author: author)
    }

    /// Two measured scraps, one line between them and the region round them, all
    /// the writer's own.
    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for id in [a, b] {
            s.insert(CanvasNode(id: id, kind: .scrap, origin: CGPoint(x: 10, y: 20),
                                width: 240, cachedHeight: 80))
        }
        s.insertLine(CanvasLine(id: l1, from: a, to: b, label: "leads to"))
        s.insertRegion(region())
        return s
    }

    private func roundTrip(_ s: CanvasScene) throws -> CanvasScene {
        let data = try JSONEncoder().encode(CanvasSceneDTO(scene: s))
        return try JSONDecoder().decode(CanvasSceneDTO.self, from: data).scene
    }

    func test_anAuthoredNodeAndLineSurviveARoundTrip() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 10, y: 20),
                            width: 240, cachedHeight: 80, author: .claude))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 300, y: 20),
                            width: 240, cachedHeight: 80, author: .claude))
        s.insertLine(CanvasLine(id: l1, from: a, to: b, label: "leads to", author: .claude))

        let loaded = try roundTrip(s)
        XCTAssertEqual(loaded.node(a)?.author, .claude)
        XCTAssertEqual(loaded.node(b)?.author, .claude)
        XCTAssertEqual(loaded.line(l1)?.author, .claude)
        XCTAssertEqual(loaded.line(l1)?.label, "leads to",
                       "the rest of the line must survive the bump")
    }

    /// A region's author, which rides the SAME schema 7 rather than a bump of
    /// its own: node, line and region provenance are one slice's one concept,
    /// they are optional in both directions, and no build outside this branch
    /// has written a 7 for an older one to disagree with.
    ///
    /// It is the primitive that needs this most. A card and a line each carry a
    /// colour as well; a region has no paper and no stroke of its own, so the
    /// seeded lean is the **whole** of its provenance
    /// (`CanvasRenderer.seededRotation(for: region)`) — and an author that did
    /// not survive the disk would draw the writer's region straight on reload
    /// and say Claude swept it.
    ///
    /// `XCTUnwrap` rather than `?.author`: an optional chain cannot tell "the
    /// region reports no author" from "the region is not there", and a codec
    /// test is exactly where the second one happens.
    func test_anAuthoredRegionSurvivesARoundTrip() throws {
        var s = CanvasScene()
        s.insertRegion(region(.claude))

        let loaded = try XCTUnwrap(roundTrip(s).region(r1),
                                   "the region itself must survive, or the assertion "
                                   + "below is about a region that is not there")
        XCTAssertEqual(loaded.author, .claude)
        XCTAssertEqual(loaded.frame, CGRect(x: 10, y: 20, width: 300, height: 200),
                       "the rest of the region must survive the bump")
        XCTAssertEqual(loaded.label, "Act II fog")
    }

    /// The additive-optional guarantee: a schema-6 sidecar — every canvas 1C-c2b
    /// wrote — has no `author` key anywhere and must decode with none rather than
    /// throw on a missing one. The fixture is a LITERAL, not a re-encode of
    /// today's DTO: a test that writes its own input cannot see a key that
    /// stopped being optional.
    func test_aSchemaSixSidecarDecodesWithNoAuthor() throws {
        let json = """
        {"schemaVersion":6,
         "nodes":[{"id":"a","kind":"scrap","x":10,"y":20,"width":240,
                   "cachedHeight":80,"z":0},
                  {"id":"b","kind":"scrap","x":300,"y":20,"width":240,
                   "cachedHeight":80,"z":0}],
         "regions":[{"id":"r1","label":"Act II fog","x":10,"y":20,"width":300,
                     "height":200,"homeMembers":["a"],"appearances":[],
                     "isCollapsed":false}],
         "lines":[{"id":"l1","from":"a","to":"b","label":"leads to"}]}
        """
        let s = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8)).scene
        // Unwrapped first, every one of them: `XCTAssertNil(s.node(a)?.author)`
        // passes just as happily when the node was never decoded at all, which
        // is the failure this whole file exists to catch.
        let nodeA = try XCTUnwrap(s.node(a))
        let nodeB = try XCTUnwrap(s.node(b))
        let line = try XCTUnwrap(s.line(l1))
        let region = try XCTUnwrap(s.region(r1))
        XCTAssertNil(nodeA.author)
        XCTAssertNil(nodeB.author)
        XCTAssertNil(line.author)
        XCTAssertNil(region.author,
                     "a region written before 1C-c3 is the writer's, and drawing it "
                     + "straight would say Claude swept it")
        XCTAssertEqual(nodeA.width, 240, "the rest of the file must survive the bump")
        XCTAssertEqual(line.label, "leads to")
        XCTAssertEqual(region.frame, CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    /// An unchanged canvas's sidecar must not grow. MEASURED on the encoded
    /// bytes rather than inferred from Codable's synthesis rules: if this ever
    /// starts writing `"author":null` on every node and line, every writer's
    /// next save is a whole-file diff for a feature they have not used.
    func test_theWritersOwnCardsWriteNoAuthorKey() throws {
        let data = try JSONEncoder().encode(CanvasSceneDTO(scene: scene()))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("author"), "found it in: \(text)")
    }

    /// A value this build does not know decodes as `.claude`, **not** as nil.
    ///
    /// The tint means *not your words*, so the safe failure direction is to
    /// over-mark: telling a writer someone else wrote their sentence is a
    /// question they can answer, and telling them they wrote a sentence they did
    /// not is one they cannot. A genuine third author kind wants its own
    /// `AnnotationAuthor.SourceKind` case, not this fallback.
    func test_anUnrecognisedAuthorIsNotReadAsTheWriters() throws {
        let json = """
        {"schemaVersion":7,
         "nodes":[{"id":"a","kind":"scrap","x":10,"y":20,"width":240,
                   "cachedHeight":80,"z":0,"author":"collaborator"},
                  {"id":"b","kind":"scrap","x":300,"y":20,"width":240,
                   "cachedHeight":80,"z":0}],
         "regions":[{"id":"r1","label":"Act II fog","x":10,"y":20,"width":300,
                     "height":200,"homeMembers":[],"appearances":[],
                     "isCollapsed":false,"author":"collaborator"}],
         "lines":[{"id":"l1","from":"a","to":"b","author":"collaborator"}]}
        """
        let s = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8)).scene
        XCTAssertEqual(s.node(a)?.author, .claude,
                       "an unknown author must over-mark, never read as the writer's")
        XCTAssertEqual(s.line(l1)?.author, .claude)
        XCTAssertEqual(try XCTUnwrap(s.region(r1)).author, .claude,
                       "a region reads the same table, so it over-marks the same way — "
                       + "drawn square, which says nobody's hand put it there")
        // Unwrapped, for this file's own reason 54 lines up: `s.node(b)?.author`
        // is nil just as happily when node `b` was never decoded — which the
        // decoder's `guard let kind else { continue }` can do, and which is the
        // failure `test_aSchemaSixSidecarDecodesWithNoAuthor` exists to catch.
        XCTAssertNil(try XCTUnwrap(s.node(b)).author,
                     "a node with no key at all is still the writer's")
    }
}
