import XCTest
@testable import Maugham

final class CanvasLineCodecTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-line-codec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func sidecarURL() -> URL {
        root.appendingPathComponent(CanvasStore.sidecarRelativePath)
    }

    private func writeSidecar(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: sidecarURL().deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: sidecarURL(), atomically: true, encoding: .utf8)
    }

    /// The one assertion of the literal that carries the number in its NAME, and
    /// the two other files that pin it point here. Rename it at every bump — a
    /// test called `…IsSeven` asserting 8 is the comment that lies loudest,
    /// because the name is what a reader greps for.
    func test_theSchemaVersionIsNine() {
        XCTAssertEqual(CanvasSceneDTO.currentSchemaVersion, 9)
    }

    func test_linesRoundTripThroughDisk() {
        var s = CanvasScene()
        for id in ["a", "b"] {
            s.insert(CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                                origin: CGPoint(x: 10, y: 20), width: 240, cachedHeight: 80))
        }
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b"), label: "leads to"))
        CanvasStore(projectRoot: root).save(scene: s, scraps: [:])
        let loaded = CanvasStore(projectRoot: root).load().scene
        let line = loaded.lines.first
        XCTAssertEqual(line?.id, CanvasLineID("l1"))
        XCTAssertEqual(line?.from, CanvasNodeID("a"))
        XCTAssertEqual(line?.to, CanvasNodeID("b"))
        XCTAssertEqual(line?.label, "leads to")
    }

    /// ADR 0015's additive-optional contract: a schema-2 sidecar — everything
    /// 1C-b wrote — has no `lines` key at all, and must open with none rather
    /// than throw on a missing key.
    func test_aSchemaV2SidecarLoadsWithNoLines() throws {
        try writeSidecar("""
        {"schemaVersion":2,"nodes":[{"id":"a","kind":"scrap","x":5,"y":6,\
        "width":240,"cachedHeight":80,"z":1}],"regions":[]}
        """)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(scene.count, 1)
        XCTAssertEqual(scene.lines, [])
    }

    func test_aLineNamingAMissingNodeIsDropped() throws {
        try writeSidecar("""
        {"schemaVersion":3,"nodes":[],"regions":[],\
        "lines":[{"id":"l1","from":"ghost","to":"also"}]}
        """)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(scene.lines, [])
    }

    /// insertLine rejects self-lines; the loader must go through it.
    func test_aSelfLineInTheFileIsDropped() throws {
        try writeSidecar("""
        {"schemaVersion":3,"nodes":[{"id":"a","kind":"scrap","x":0,"y":0,\
        "width":240,"cachedHeight":80,"z":1}],"regions":[],\
        "lines":[{"id":"l1","from":"a","to":"a"}]}
        """)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(scene.lines, [],
                       "insertLine rejects self-lines; the loader must go through it")
    }

    func test_linesAreWrittenInIDOrderRegardlessOfDictionaryIteration() throws {
        var s = CanvasScene()
        for id in ["a", "b"] {
            s.insert(CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                                origin: CGPoint(x: 0, y: 0), width: 240, cachedHeight: 80))
        }
        for id in ["l9", "l1", "l5"] {
            s.insertLine(CanvasLine(id: CanvasLineID(id), from: CanvasNodeID("a"),
                                    to: CanvasNodeID("b")))
        }
        CanvasStore(projectRoot: root).save(scene: s, scraps: [:])
        let dto = try JSONDecoder().decode(
            CanvasSceneDTO.self, from: try Data(contentsOf: sidecarURL()))
        XCTAssertEqual(dto.lines?.map(\.id), ["l1", "l5", "l9"])
    }

    /// The guard that makes the bump non-destructive in both directions: a
    /// schema-9 sidecar (from the future, past this build's schema-8) opened
    /// by this build loses the arrangement and keeps the words. One line
    /// count, not three — a later slice bumps again.
    ///
    /// **Rebump this fixture at every bump, and rename it with the number.**
    /// Left at the version this build now writes it stops being from the future,
    /// the `schemaVersion <= currentSchemaVersion` gate passes, and the test
    /// asserts nothing while still going green. It has needed doing at every
    /// bump so far, 1C-d's included.
    func test_aSchemaTenSidecarLosesTheArrangementAndKeepsTheWords() throws {
        try writeSidecar("""
        {"schemaVersion":10,"nodes":[{"id":"a","kind":"scrap","x":5,"y":6,\
        "width":240,"cachedHeight":80,"z":1}]}
        """)
        try "\(ScrapText.banner)\n\n## a\n\nthe falls at night\n"
            .write(to: root.appendingPathComponent(CanvasStore.scrapsRelativePath),
                   atomically: true, encoding: .utf8)
        let loaded = CanvasStore(projectRoot: root).load()
        XCTAssertEqual(loaded.scene.count, 0)
        XCTAssertEqual(loaded.scraps[CanvasNodeID("a")], "the falls at night")
    }
}
