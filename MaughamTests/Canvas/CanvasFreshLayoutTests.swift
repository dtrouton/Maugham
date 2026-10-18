import XCTest
@testable import Maugham

/// The canvas's read-only notice and **Start a Fresh Layout** (issue #44) —
/// windowless (tripwire 33): the notice's decisions are its `static`s, and the
/// button's press is `CanvasModel.startFreshLayout`, driven here on a model
/// attached to a real project folder under `TestTemp.root`.
@MainActor
final class CanvasFreshLayoutTests: XCTestCase {

    /// `attach` measures a resurrected orphan's card through production
    /// typography (`FontWarmup`'s cold-start window).
    override class func setUp() { FontWarmup.ensure() }

    private var root: URL!
    private var sidecarURL: URL { root.appendingPathComponent(CanvasStore.sidecarRelativePath) }
    private var scrapsURL: URL { root.appendingPathComponent(CanvasStore.scrapsRelativePath) }
    private var maughamDir: URL { sidecarURL.deletingLastPathComponent() }

    private static let newerSidecar =
        #"{"schemaVersion":999,"nodes":[{"id":"futr","kind":"scrap","x":10,"y":10,"width":240,"z":3}]}"#
    private static let damagedSidecar = "not json at all"
    private static let words: [String: String] = [
        "ghst": "The words survive.",
        "secd": "A second card, also the writer's.",
    ]
    /// A fixed moment, so the aside name is known.
    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private var stamp: String { CanvasStore.asideStampFormatter.string(from: now) }

    override func setUpWithError() throws {
        root = TestTemp.root.appendingPathComponent("fresh-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func seed(sidecar: String) throws {
        try FileManager.default.createDirectory(at: maughamDir, withIntermediateDirectories: true)
        try sidecar.write(to: sidecarURL, atomically: true, encoding: .utf8)
        let scraps = Dictionary(uniqueKeysWithValues: Self.words.map { (CanvasNodeID($0.key), $0.value) })
        try ScrapText.render(scraps).write(to: scrapsURL, atomically: true, encoding: .utf8)
    }

    private func asideFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: maughamDir.path)
            .filter { $0.hasPrefix("canvas.damaged-") }.sorted()
    }

    // MARK: - The notice

    /// The notice says the refusal's OWN sentence for each reason — the words
    /// the inbox alert and the tool say too — and the two are different facts.
    func test_theNoticeSaysTheRefusalsOwnSentencePerReason() {
        for reason in [CanvasStore.SidecarRefused.Reason.newerVersion, .damaged] {
            let refusal = CanvasStore.SidecarRefused(projectName: "P", reason: reason)
            XCTAssertEqual(CanvasReadOnlyNotice.sentence(for: reason), refusal.errorDescription)
            XCTAssertTrue(CanvasReadOnlyNotice.accessibilityLabel(for: reason)
                .contains(CanvasReadOnlyNotice.sentence(for: reason)),
                          "VoiceOver hears the same sentence")
        }
        XCTAssertNotEqual(CanvasReadOnlyNotice.sentence(for: .newerVersion),
                          CanvasReadOnlyNotice.sentence(for: .damaged))
    }

    /// The button is offered for a damaged file ONLY — a newer build's file is a
    /// real layout, and setting it aside is the one thing never to offer.
    func test_startAFreshLayoutIsOfferedForADamagedFileOnly() {
        XCTAssertTrue(CanvasReadOnlyNotice.offersStartFresh(for: .damaged))
        XCTAssertFalse(CanvasReadOnlyNotice.offersStartFresh(for: .newerVersion))
    }

    /// The button's name is the one the damaged sentence and Claude's hint
    /// both tell the writer to press.
    func test_theButtonIsNamedWhatTheSentencesSayToPress() {
        XCTAssertEqual(CanvasReadOnlyNotice.startFreshTitle, "Start a Fresh Layout")
        XCTAssertTrue(CanvasReadOnlyNotice.sentence(for: .damaged)
            .contains(CanvasReadOnlyNotice.startFreshTitle))
        XCTAssertTrue(AddCanvasScrapsTool.unreadableHint(.damaged)
            .contains(CanvasReadOnlyNotice.startFreshTitle))
        XCTAssertFalse(AddCanvasScrapsTool.unreadableHint(.newerVersion)
            .contains(CanvasReadOnlyNotice.startFreshTitle))
    }

    /// The canvas centre mounts the notice off the model's own refusal and
    /// wires the button to the model's verb. (Textual: SwiftUI's inset has no
    /// windowless seam.)
    func test_theCanvasCentreMountsTheNoticeOffTheModel() throws {
        // The window's whole family, by type: the canvas centre lives in
        // `CentreColumn` since foundations plan 4, wherever its file is.
        let code = SourceScan.codeLines(of: try SourceTree.windowSource())
            .joined(separator: "\n")
        XCTAssertEqual(code.components(separatedBy: "CanvasReadOnlyNotice(refusal:").count - 1, 1)
        XCTAssertTrue(code.contains("if let refusal = canvasModel.sidecarRefusal"))
        XCTAssertTrue(code.contains("try canvasModel.startFreshLayout()"))
    }

    // MARK: - The aside name

    func test_theAsideNameAndItsCollisionSuffix() {
        XCTAssertEqual(CanvasStore.asideName(stamp: "20261018-120000", attempt: 1),
                       "canvas.damaged-20261018-120000.json")
        XCTAssertEqual(CanvasStore.asideName(stamp: "20261018-120000", attempt: 2),
                       "canvas.damaged-20261018-120000-2.json")
        XCTAssertNotNil(stamp.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression), stamp)
    }

    // MARK: - The verb

    /// **The damaged bytes are KEPT, under the aside name**, and the canvas is
    /// writable in the same session with every word laid out — and the fresh
    /// layout is on disk, decodable, before the writer's first edit.
    func test_aDamagedLayoutIsSetAsideKeptAndTheCanvasBecomesWritable() throws {
        try seed(sidecar: Self.damagedSidecar)
        let damagedBytes = try Data(contentsOf: sidecarURL)
        let model = CanvasModel()
        model.attach(projectRoot: root)
        XCTAssertEqual(model.sidecarRefusal?.reason, .damaged, "precondition")

        let aside = try model.startFreshLayout(now: now)

        XCTAssertEqual(aside.lastPathComponent, "canvas.damaged-\(stamp).json")
        XCTAssertEqual(aside.deletingLastPathComponent().standardizedFileURL,
                       maughamDir.standardizedFileURL, "beside the file it was")
        XCTAssertEqual(try Data(contentsOf: aside), damagedBytes, "the damaged file is kept whole")
        XCTAssertFalse(model.isReadOnly)
        XCTAssertNil(model.sidecarRefusal)
        for (id, text) in Self.words {
            XCTAssertEqual(model.scraps[CanvasNodeID(id)], text, "\(id)'s words")
            XCTAssertNotNil(model.scene.node(CanvasNodeID(id)), "\(id) is a card")
        }
        XCTAssertFalse(model.hasPendingSave, "saved once, now — not left in a debounce")

        let onDisk = CanvasStore(projectRoot: root).load()
        XCTAssertEqual(onDisk.sidecar, .decoded, "the fresh layout is a file this build reads")
        XCTAssertEqual(Set(onDisk.scene.nodes.map(\.id.raw)), Set(Self.words.keys))
        for (id, text) in Self.words {
            XCTAssertEqual(onDisk.scraps[CanvasNodeID(id)], text, "\(id)'s words on disk")
        }

        // And the canvas really is editable: an edit reaches disk.
        model.setScrapText("Edited after the fresh start.", for: CanvasNodeID("ghst"))
        model.flush()
        let afterEdit = CanvasStore(projectRoot: root).load()
        XCTAssertEqual(afterEdit.sidecar, .decoded)
        XCTAssertEqual(afterEdit.scraps[CanvasNodeID("ghst")], "Edited after the fresh start.")
        XCTAssertEqual(try Data(contentsOf: aside), damagedBytes, "and the aside file is still untouched")
        model.detach()
    }

    /// An earlier aside file is never overwritten: the next free `-N` is taken.
    func test_anExistingAsideFileIsNeverOverwritten() throws {
        try seed(sidecar: Self.damagedSidecar)
        let first = maughamDir.appendingPathComponent(CanvasStore.asideName(stamp: stamp, attempt: 1))
        let second = maughamDir.appendingPathComponent(CanvasStore.asideName(stamp: stamp, attempt: 2))
        try "earlier damage".write(to: first, atomically: true, encoding: .utf8)
        try "earlier damage 2".write(to: second, atomically: true, encoding: .utf8)

        let model = CanvasModel()
        model.attach(projectRoot: root)
        let aside = try model.startFreshLayout(now: now)

        XCTAssertEqual(aside.lastPathComponent, "canvas.damaged-\(stamp)-3.json")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), Self.damagedSidecar)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "earlier damage")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "earlier damage 2")
        model.detach()
    }

    /// **Refused for a newer build's file**, which is somebody's real layout:
    /// it throws that refusal, moves nothing, and the canvas stays read-only.
    func test_aNewerVersionFileIsNeverSetAside() throws {
        try seed(sidecar: Self.newerSidecar)
        let before = try Data(contentsOf: sidecarURL)
        let model = CanvasModel()
        model.attach(projectRoot: root)

        XCTAssertThrowsError(try model.startFreshLayout(now: now)) { error in
            XCTAssertEqual((error as? CanvasStore.SidecarRefused)?.reason, .newerVersion)
        }
        XCTAssertEqual(try Data(contentsOf: sidecarURL), before, "the file is untouched")
        XCTAssertEqual(try asideFiles(), [], "nothing was set aside")
        XCTAssertEqual(model.sidecarRefusal?.reason, .newerVersion, "still read-only")
        model.detach()
        XCTAssertEqual(try Data(contentsOf: sidecarURL), before)
    }

    /// The store re-reads the file: one that a sync turned into a NEWER build's
    /// since the damaged load is not set aside on the strength of the old verdict.
    func test_aFileThatBecameANewerBuildsSinceTheLoadIsNotSetAside() throws {
        try seed(sidecar: Self.damagedSidecar)
        let model = CanvasModel()
        model.attach(projectRoot: root)
        try Self.newerSidecar.write(to: sidecarURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try model.startFreshLayout(now: now)) { error in
            XCTAssertEqual((error as? CanvasStore.SidecarRefused)?.reason, .newerVersion)
        }
        XCTAssertEqual(try String(contentsOf: sidecarURL, encoding: .utf8), Self.newerSidecar)
        XCTAssertEqual(try asideFiles(), [])
        XCTAssertTrue(model.isReadOnly)
        model.detach()
    }

    /// Nothing to set aside on a writable canvas, and no verb at all with no
    /// canvas attached.
    func test_theVerbRefusesAWritableOrUnattachedCanvas() throws {
        let model = CanvasModel()
        XCTAssertThrowsError(try model.startFreshLayout(now: now)) { error in
            XCTAssertEqual(error as? CanvasStore.FreshLayoutRefused, .canvasNotOpen)
        }
        model.attach(projectRoot: root)
        XCTAssertThrowsError(try model.startFreshLayout(now: now)) { error in
            XCTAssertEqual(error as? CanvasStore.FreshLayoutRefused, .nothingDamaged)
        }
        model.detach()
    }

    /// A move that fails leaves the canvas read-only and the damaged file where
    /// it was, and says so by throwing.
    func test_aFailedMoveLeavesTheCanvasReadOnly() throws {
        try seed(sidecar: Self.damagedSidecar)
        let before = try Data(contentsOf: sidecarURL)
        let model = CanvasModel()
        model.attach(projectRoot: root)
        let fm = FileManager.default
        // A directory that refuses new entries refuses the move.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: maughamDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: maughamDir.path) }

        XCTAssertThrowsError(try model.startFreshLayout(now: now))
        XCTAssertEqual(model.sidecarRefusal?.reason, .damaged, "still read-only")
        XCTAssertEqual(try Data(contentsOf: sidecarURL), before)
        XCTAssertEqual(try asideFiles(), [])
        model.detach()
    }
}
