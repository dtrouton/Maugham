import XCTest
import AppKit
@testable import Maugham

/// **A canvas file that is there but can't be read right now is never written
/// over** (issue #88). Before it, `CanvasStore.load()` read both files with
/// `try?`, so an unreadable `canvas.json` loaded as `.absent` (every write
/// allowed) and an unreadable `canvas.md` loaded as "no scraps" — and the next
/// edit rewrote `canvas.md` EMPTY. Windowless (tripwire 33); every fixture is
/// under `TestTemp.root`, and an unreadable file is a `chmod 000` file, a
/// directory standing at the file's path, bytes that are not UTF-8, an
/// `.icloud` placeholder, or an injected stub probe.
@MainActor
final class CanvasUnreadableTests: XCTestCase {

    /// `attach` measures cards through production typography.
    override class func setUp() { FontWarmup.ensure() }

    private var root: URL!
    private var sidecarFile: URL { root.appendingPathComponent(CanvasStore.sidecarRelativePath) }
    private var scrapsFile: URL { root.appendingPathComponent(CanvasStore.scrapsRelativePath) }
    /// Every path a test locked, so `tearDown` can unlock it — `TestTemp`'s
    /// cleanup cannot remove what it cannot read.
    private var locked: [URL] = []

    private static let sentence =
        "Maugham couldn't read this canvas's files just now, so it can't be changed yet. If the project is in iCloud they may still be downloading — Maugham will keep trying."

    override func setUpWithError() throws {
        root = TestTemp.root.appendingPathComponent("canvas-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sidecarFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unlockAll()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func sampleScene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("s1"), kind: .scrap,
                            origin: CGPoint(x: 12, y: 34), width: 240,
                            cachedHeight: 88, z: 1))
        return s
    }

    /// A good pair on disk: a decoding sidecar and one scrap's words.
    private func seedGoodCanvas() {
        CanvasStore(projectRoot: root).save(scene: sampleScene(),
                                            scraps: [CanvasNodeID("s1"): "The falls at night."])
    }

    private func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        locked.append(url)
    }

    private func unlockAll() {
        for url in locked {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        locked = []
    }

    /// Replace a file with a directory of the same name.
    private func directory(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Each unreadable shape, applied to `url` over a good canvas.
    private enum Shape: CaseIterable { case locked, directory }

    private func make(_ shape: Shape, _ url: URL) throws {
        switch shape {
        case .locked: try lock(url)
        case .directory: try directory(at: url)
        }
    }

    // MARK: - The sentence

    func test_unreadableSaysTheRulingSentence() {
        XCTAssertEqual(CanvasStore.SidecarRefused.Reason.unreadable.sentence, Self.sentence)
        XCTAssertEqual(CanvasStore.SidecarRefused(projectName: "P", reason: .unreadable)
            .errorDescription, Self.sentence)
        XCTAssertEqual(CanvasReadOnlyNotice.sentence(for: .unreadable), Self.sentence)
    }

    /// No Start a Fresh Layout: the files are not damaged, only not readable yet,
    /// and Claude is told the same.
    func test_unreadableOffersNoFreshLayoutAndClaudeIsToldToWait() {
        XCTAssertFalse(CanvasReadOnlyNotice.offersStartFresh(for: .unreadable))
        let hint = AddCanvasScrapsTool.unreadableHint(.unreadable)
        XCTAssertFalse(hint.contains(CanvasReadOnlyNotice.startFreshTitle), hint)
        XCTAssertFalse(hint.contains("Update Maugham"), hint)
        XCTAssertTrue(hint.contains("iCloud"), hint)
        XCTAssertTrue(hint.contains("list_canvas"), hint)
    }

    // MARK: - The classifier

    /// Absent is still absent: no file and no placeholder is a canvas with
    /// nothing to lose (the control for every case below).
    func test_aMissingFileWithNoPlaceholderIsStillAbsent() {
        let loaded = CanvasStore(projectRoot: root).load()
        XCTAssertEqual(loaded.sidecar, .absent)
        XCTAssertNil(loaded.refusal)
        XCTAssertEqual(CanvasStore.read(sidecarFile, isStub: { _ in false },
                                        startDownload: { _ in XCTFail("nothing to download") }),
                       .absent)
    }

    /// An unreadable `canvas.json`, each shape → `.unreadable`, not `.absent`.
    func test_anUnreadableLayoutFileIsRefusedAsUnreadable() throws {
        for shape in Shape.allCases {
            seedGoodCanvas()
            try make(shape, sidecarFile)
            let loaded = CanvasStore(projectRoot: root).load()
            XCTAssertEqual(loaded.sidecar, .refused, "\(shape)")
            XCTAssertEqual(loaded.refusal?.reason, .unreadable, "\(shape)")
            XCTAssertEqual(loaded.refusal?.projectName, root.lastPathComponent)
            XCTAssertEqual(loaded.scraps[CanvasNodeID("s1")], "The falls at night.",
                           "\(shape): the words that DID read are kept, to be shown loose")
            XCTAssertThrowsError(try CanvasStore(projectRoot: root).loadForTransientWrite()) {
                XCTAssertEqual(($0 as? CanvasStore.SidecarRefused)?.reason, .unreadable)
            }
            unlockAll()
            try? FileManager.default.removeItem(at: sidecarFile)
        }
    }

    /// **The worse sibling**: an unreadable `canvas.md` beside a perfectly good
    /// layout is refused too — before #88 it loaded as "no scraps", and the next
    /// edit wrote that over every word.
    func test_anUnreadableWordsFileIsRefusedAsUnreadable() throws {
        for shape in Shape.allCases {
            seedGoodCanvas()
            try make(shape, scrapsFile)
            let loaded = CanvasStore(projectRoot: root).load()
            XCTAssertEqual(loaded.sidecar, .refused, "\(shape)")
            XCTAssertEqual(loaded.refusal?.reason, .unreadable, "\(shape)")
            XCTAssertTrue(loaded.scene.isEmpty,
                          "\(shape): a layout of empty cards is not the writer's canvas")
            unlockAll()
            try? FileManager.default.removeItem(at: scrapsFile)
        }
    }

    /// Bytes that are not UTF-8 are words this build cannot read — a lossy
    /// decode would save its own guess over them.
    func test_aWordsFileThatIsNotUTF8IsUnreadable() throws {
        seedGoodCanvas()
        try Data([0x23, 0x23, 0x20, 0xFF, 0xFE, 0x0A]).write(to: scrapsFile)
        XCTAssertEqual(CanvasStore(projectRoot: root).load().refusal?.reason, .unreadable)
    }

    /// An old-style iCloud placeholder — `.canvas.json.icloud`, no real file —
    /// is somebody's file still in the cloud, not an absent one; and a download
    /// is asked for so a later retry finds it.
    func test_anICloudPlaceholderIsUnreadableAndADownloadIsRequested() throws {
        let placeholder = sidecarFile.deletingLastPathComponent()
            .appendingPathComponent(".canvas.json.icloud")
        try Data().write(to: placeholder)
        var requested: [URL] = []
        let store = CanvasStore(projectRoot: root, isStub: { _ in false },
                                startDownload: { requested.append($0) })
        XCTAssertEqual(store.load().refusal?.reason, .unreadable)
        XCTAssertEqual(requested.map(\.lastPathComponent), ["canvas.json"])

        // …and the same for the words file.
        try FileManager.default.removeItem(at: placeholder)
        try Data().write(to: root.appendingPathComponent(".canvas.md.icloud"))
        XCTAssertEqual(CanvasStore(projectRoot: root).load().refusal?.reason, .unreadable)
    }

    /// **A dataless stub is decided from its resource values, never by reading
    /// it** — reading one from the main actor can block on a download. The
    /// proof: over a path with no file at all, a probe answering "stub" gives
    /// `.unreadable`; had the bytes been asked for, the answer would be `.absent`.
    func test_aStubIsUnreadableWithoutABytesRead() {
        var requested: [URL] = []
        XCTAssertEqual(CanvasStore.read(root.appendingPathComponent("nowhere.json"),
                                        isStub: { _ in true },
                                        startDownload: { requested.append($0) }),
                       .unreadable)
        XCTAssertEqual(requested.count, 1, "a download is asked for, never waited on")

        seedGoodCanvas()
        let stubbed = CanvasStore(projectRoot: root, isStub: { $0.lastPathComponent == "canvas.md" },
                                  startDownload: { _ in })
        XCTAssertEqual(stubbed.load().refusal?.reason, .unreadable,
                       "a perfectly good file iCloud says is not current waits")
    }

    /// The production probe answers false for a file iCloud does not know about,
    /// so an ordinary local canvas reads as before.
    func test_theProductionProbeLeavesALocalCanvasAlone() {
        seedGoodCanvas()
        let loaded = CanvasStore(projectRoot: root).load()
        XCTAssertEqual(loaded.sidecar, .decoded)
        XCTAssertNil(loaded.refusal)
    }

    // MARK: - Nothing is written over

    /// **Every write verb leaves both files byte-identical** after an unreadable
    /// load — whichever file it was, and whatever shape.
    func test_aStoreWhoseFilesWereUnreadableWritesNothingThroughAnyVerb() throws {
        for target in [sidecarFile, scrapsFile] {
            for shape in Shape.allCases {
                seedGoodCanvas()
                let sidecarBefore = try Data(contentsOf: sidecarFile)
                let scrapsBefore = try Data(contentsOf: scrapsFile)
                try make(shape, target)
                let label = "\(target.lastPathComponent) \(shape)"

                let store = CanvasStore(projectRoot: root)
                XCTAssertEqual(store.load().refusal?.reason, .unreadable, label)
                store.scheduleSave(scene: sampleScene(), scraps: [:])
                XCTAssertFalse(store.hasPendingWrite, label)
                store.flush()
                store.save(scene: CanvasScene(), scraps: [:])
                store.saveSceneOnly(CanvasScene())
                NotificationCenter.default.post(   // adr-0021-ok: AppKit lifecycle notification, not a maugham.* event
                    name: NSApplication.willTerminateNotification, object: NSApplication.shared)

                unlockAll()
                if shape == .directory {
                    var isDir: ObjCBool = false
                    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path,
                                                                 isDirectory: &isDir) && isDir.boolValue,
                                  "\(label): nothing replaced what stood at the path")
                    try FileManager.default.removeItem(at: target)
                    let other = target == sidecarFile ? scrapsFile : sidecarFile
                    let otherBefore = target == sidecarFile ? scrapsBefore : sidecarBefore
                    XCTAssertEqual(try Data(contentsOf: other), otherBefore, label)
                } else {
                    XCTAssertEqual(try Data(contentsOf: sidecarFile), sidecarBefore, label)
                    XCTAssertEqual(try Data(contentsOf: scrapsFile), scrapsBefore,
                                   "\(label): the words are byte-identical")
                }
                try? FileManager.default.removeItem(at: sidecarFile)
                try? FileManager.default.removeItem(at: scrapsFile)
            }
        }
    }

    /// The model on top: read-only, every verb refused in memory, and nothing on
    /// disk changes through a detach or a quit — `canvas.md` above all.
    func test_aModelAttachedOverUnreadableWordsIsReadOnlyAndWritesNothing() throws {
        seedGoodCanvas()
        let sidecarBefore = try Data(contentsOf: sidecarFile)
        let scrapsBefore = try Data(contentsOf: scrapsFile)
        try lock(scrapsFile)

        let model = CanvasModel()
        model.attach(projectRoot: root)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertEqual(model.sidecarRefusal?.reason, .unreadable)
        model.setScrapText("over the words", for: CanvasNodeID("s1"))
        model.mutate("Move") { $0.insert(CanvasNode(id: CanvasNodeID("s2"), kind: .scrap,
                                                    origin: .zero, width: 200,
                                                    cachedHeight: 40, z: 2)) }
        XCTAssertNil(model.scene.node(CanvasNodeID("s2")), "refused in memory")
        model.flush()
        model.detach()
        NotificationCenter.default.post(   // adr-0021-ok: AppKit lifecycle notification, not a maugham.* event
            name: NSApplication.willTerminateNotification, object: NSApplication.shared)

        unlockAll()
        XCTAssertEqual(try Data(contentsOf: scrapsFile), scrapsBefore,
                       "an unreadable canvas.md never becomes an empty one")
        XCTAssertEqual(try Data(contentsOf: sidecarFile), sidecarBefore)
    }

    /// Start a Fresh Layout's file half refuses an unreadable layout with that
    /// reason — not "nothing damaged, close and reopen" — and moves nothing.
    func test_settingAsideAnUnreadableLayoutRefusesAndMovesNothing() throws {
        seedGoodCanvas()
        try directory(at: sidecarFile)
        XCTAssertThrowsError(try CanvasStore(projectRoot: root).setDamagedSidecarAside()) {
            XCTAssertEqual(($0 as? CanvasStore.SidecarRefused)?.reason, .unreadable)
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: sidecarFile.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["canvas.json"], "nothing set aside")

        let model = CanvasModel()
        model.attach(projectRoot: root)
        XCTAssertThrowsError(try model.startFreshLayout()) {
            XCTAssertEqual(($0 as? CanvasStore.SidecarRefused)?.reason, .unreadable)
        }
        XCTAssertTrue(model.isReadOnly)
    }
}
