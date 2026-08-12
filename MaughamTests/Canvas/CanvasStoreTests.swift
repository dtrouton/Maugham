import XCTest
import AppKit
@testable import Maugham

final class CanvasStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sampleScene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("s1"), kind: .scrap,
                            origin: CGPoint(x: 12, y: 34), width: 240,
                            cachedHeight: 88, z: 1))
        // An item node is not CREATED by 1C-a, but the codec must carry one:
        // 1C-b and 1C-c depend on this round-trip.
        s.insert(CanvasNode(id: .item("r-9"), kind: .item(.project(id: "r-9")),
                            origin: CGPoint(x: 400, y: 100), width: 180,
                            cachedHeight: 120, z: 2))
        return s
    }

    func test_saveThenLoad_roundTripsSceneAndScraps() {
        let store = CanvasStore(projectRoot: root)
        let scene = sampleScene()
        let scraps = [CanvasNodeID("s1"): "The falls at night."]
        store.save(scene: scene, scraps: scraps)

        let loaded = CanvasStore(projectRoot: root).load()
        XCTAssertEqual(loaded.scene, scene)
        XCTAssertEqual(loaded.scraps, scraps)
    }

    func test_load_onAFreshProjectYieldsAnEmptyCanvas() {
        let loaded = CanvasStore(projectRoot: root).load()
        XCTAssertTrue(loaded.scene.isEmpty)
        XCTAssertTrue(loaded.scraps.isEmpty)
    }

    func test_sidecarAndScrapsLandAtTheirDocumentedPaths() {
        CanvasStore(projectRoot: root).save(scene: sampleScene(),
                                            scraps: [CanvasNodeID("s1"): "x"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".maugham/canvas.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("canvas.md").path),
            "scrap TEXT is content and belongs at project root, not in the sidecar")
    }

    /// Spec §8: the sidecar is derived UI state, deletable without loss of
    /// content. Deleting it must lose positions but never words.
    func test_deletingTheSidecar_losesLayoutButKeepsTheWords() throws {
        let store = CanvasStore(projectRoot: root)
        store.save(scene: sampleScene(), scraps: [CanvasNodeID("s1"): "The falls at night."])
        try FileManager.default.removeItem(at: root.appendingPathComponent(".maugham/canvas.json"))

        let loaded = CanvasStore(projectRoot: root).load()
        XCTAssertTrue(loaded.scene.isEmpty)
        XCTAssertEqual(loaded.scraps[CanvasNodeID("s1")], "The falls at night.")
    }

    /// ADR 0015 — a sidecar from a newer build must not throw the canvas away.
    func test_aNewerSchemaVersionLoadsAsEmptyRatherThanCrashing() throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"schemaVersion":999,"nodes":[]}"#
            .write(to: dir.appendingPathComponent("canvas.json"),
                   atomically: true, encoding: .utf8)
        XCTAssertTrue(CanvasStore(projectRoot: root).load().scene.isEmpty)
    }

    func test_corruptSidecarLoadsAsEmptyRatherThanCrashing() throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json at all".write(to: dir.appendingPathComponent("canvas.json"),
                                    atomically: true, encoding: .utf8)
        XCTAssertTrue(CanvasStore(projectRoot: root).load().scene.isEmpty)
    }

    func test_unknownNodeKindIsDroppedNotFatal() throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"schemaVersion":1,"nodes":[
          {"id":"s1","kind":"scrap","x":0,"y":0,"width":240,"z":0},
          {"id":"weird","kind":"hologram","x":0,"y":0,"width":240,"z":0}
        ]}
        """
        try json.write(to: dir.appendingPathComponent("canvas.json"),
                       atomically: true, encoding: .utf8)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertNotNil(scene.node(CanvasNodeID("s1")))
        XCTAssertNil(scene.node(CanvasNodeID("weird")))
    }

    // MARK: - Debounce and flush

    func test_scheduleSaveDoesNotWriteImmediately() {
        let store = CanvasStore(projectRoot: root)
        store.scheduleSave(scene: sampleScene(), scraps: [CanvasNodeID("s1"): "x"])
        XCTAssertTrue(store.hasPendingWrite)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("canvas.md").path))
    }

    /// The 750ms window is exactly long enough to lose the last drag on quit.
    func test_flushWritesThePendingDebouncedPayload() {
        let store = CanvasStore(projectRoot: root)
        store.scheduleSave(scene: sampleScene(), scraps: [CanvasNodeID("s1"): "The falls."])
        store.flush()
        XCTAssertFalse(store.hasPendingWrite)
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scraps[CanvasNodeID("s1")],
                       "The falls.")
    }

    func test_flushWithNothingPendingWritesNothing() {
        let store = CanvasStore(projectRoot: root)
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("canvas.md").path),
            "an empty flush must not stamp an empty canvas.md over a real one")
    }

    /// `.onDisappear` does not fire on app quit. The store owns the quit hook
    /// itself so no caller has to remember.
    ///
    /// This asserts on the SAME TURN as the post, which only holds because the
    /// observer is registered with `queue: nil` — the block then runs
    /// synchronously on the posting thread. With `queue: .main` it is enqueued
    /// instead, this test fails, and at real quit time the hop may never run.
    func test_appTerminationFlushesThePendingWrite() {
        let store = CanvasStore(projectRoot: root)
        store.scheduleSave(scene: sampleScene(), scraps: [CanvasNodeID("s1"): "quit me"])
        NotificationCenter.default.post(   // adr-0021-ok: AppKit lifecycle notification, not a maugham.* event
            name: NSApplication.willTerminateNotification, object: NSApplication.shared)
        XCTAssertFalse(store.hasPendingWrite)
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scraps[CanvasNodeID("s1")],
                       "quit me")
    }

    /// C5's last line of defence. The words the writer just typed live in the
    /// mounted editor until something pulls them into the model; the store gives
    /// its owner one synchronous call to do that before it writes.
    func test_beforeFlushCanReplaceThePayloadOnItsWayOut() {
        let store = CanvasStore(projectRoot: root)
        store.scheduleSave(scene: sampleScene(), scraps: [CanvasNodeID("s1"): "stale"])
        store.beforeFlush = { [weak store] in
            store?.scheduleSave(scene: self.sampleScene(),
                                scraps: [CanvasNodeID("s1"): "what the writer actually typed"])
        }
        store.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scraps[CanvasNodeID("s1")],
                       "what the writer actually typed")
    }

    /// F11 (issue #28): the content file must hit disk before the derived one.
    /// A crash in the gap between the two writes may only ever LAG `canvas.json`
    /// — the old order could resurrect a node in the sidecar whose words never
    /// reached `canvas.md`, and the scrap reloads empty (constitution must #1).
    /// Black-box I/O cannot see the interleaving, so this pins the source.
    func test_writeNowPutsContentBeforeDerived() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // MaughamTests/Canvas
            .deletingLastPathComponent()          // MaughamTests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Maugham/Canvas/CanvasStore.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        guard let fn = text.range(of: "func writeNow") else {
            return XCTFail("writeNow not found — if it was renamed, move this pin with it")
        }
        let tail = text[fn.lowerBound...]
        guard let content = tail.range(of: "ScrapText.render"),
              let derived = tail.range(of: "writeSidecar(") else {
            return XCTFail("writeNow no longer names both writes — re-pin the new spellings")
        }
        XCTAssertTrue(content.lowerBound < derived.lowerBound,
            "canvas.md (content) must be written before canvas.json (derived)")
    }
}
