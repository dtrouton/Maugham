import XCTest
import MaughamCore
@testable import Maugham

/// Provenance on a card and on a line, across the disk boundary.
///
/// Schema 7 (1C-c3's `author`) is additive-optional in BOTH directions, which is
/// the pattern every canvas bump has kept: an older sidecar decodes unchanged,
/// and a newer one costs an older build the arrangement and never the words
/// (`CanvasStore.load`). The version literal itself is asserted once, in
/// `CanvasLineCodecTests.test_theSchemaVersionIsSeven` — a fifth copy of the
/// number here would be a fifth site to rebump.
///
/// **nil means the writer.** There is no `.human`-by-default anywhere: a canvas
/// written before this build, and every card the writer makes in it, carries no
/// `author` key at all.
final class CanvasAuthorCodecTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let l1 = CanvasLineID("l1")

    /// Two measured scraps and one line between them, all the writer's own.
    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for id in [a, b] {
            s.insert(CanvasNode(id: id, kind: .scrap, origin: CGPoint(x: 10, y: 20),
                                width: 240, cachedHeight: 80))
        }
        s.insertLine(CanvasLine(id: l1, from: a, to: b, label: "leads to"))
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
         "regions":[],
         "lines":[{"id":"l1","from":"a","to":"b","label":"leads to"}]}
        """
        let s = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8)).scene
        XCTAssertNil(s.node(a)?.author)
        XCTAssertNil(s.node(b)?.author)
        XCTAssertNil(s.line(l1)?.author)
        XCTAssertEqual(s.node(a)?.width, 240, "the rest of the file must survive the bump")
        XCTAssertEqual(s.line(l1)?.label, "leads to")
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
         "regions":[],
         "lines":[{"id":"l1","from":"a","to":"b","author":"collaborator"}]}
        """
        let s = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8)).scene
        XCTAssertEqual(s.node(a)?.author, .claude,
                       "an unknown author must over-mark, never read as the writer's")
        XCTAssertEqual(s.line(l1)?.author, .claude)
        XCTAssertNil(s.node(b)?.author, "a node with no key at all is still the writer's")
    }
}
