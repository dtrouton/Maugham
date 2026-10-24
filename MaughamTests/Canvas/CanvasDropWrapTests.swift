import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Maugham

/// A drop on bare canvas while a chapter is selected arrives in a new region
/// bound to that chapter (spec §2, "Dropped items with a chapter selected").
/// The region is the drop's container: it joins the dropped items and never
/// a bystander.
@MainActor
final class CanvasDropWrapTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = TestTemp.root.appendingPathComponent("canvas-drop-wrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - Fixtures

    private let noteID = "res-note"

    private func index() -> CanvasItemIndex {
        CanvasItemIndex(entriesByID: [noteID: .init(title: "The falls", kind: .researchNote)])
    }

    /// Attached, so `CanvasUndo` records snapshots (`CanvasModel.attach`).
    private func attachedModel() -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.undoManager.groupsByEvent = false
        return model
    }

    private func researchNode(at point: CGPoint, in model: CanvasModel) throws -> CanvasNode {
        guard case .create(let node) = CanvasDrop.decide(
            payload: noteID, at: point, in: model.scene, index: index(), pictureAspect: nil) else {
            XCTFail("precondition: a known id creates")
            throw CocoaError(.featureUnsupported)
        }
        return node
    }

    // MARK: - Wrapping

    func test_oneDroppedItemIsWrappedInARegionBoundToTheChapter() throws {
        let model = attachedModel()
        let node = try researchNode(at: CGPoint(x: 200, y: 150), in: model)

        let wrapped = CanvasDrop.apply(node, in: model, wrappingInPiece: "p1")

        let id = try XCTUnwrap(wrapped, "a drop on bare canvas with a chapter selected is wrapped")
        let region = try XCTUnwrap(model.scene.region(id))
        XCTAssertEqual(region.boundPieceID, "p1")
        XCTAssertEqual(region.homeMembers, [node.id], "the item is the region's one resident")
        let lit = CanvasHighlight.resolve(subject: .piece("p1"), in: model.scene)
        XCTAssertTrue(lit.nodes.contains(node.id), "the item is lit under its chapter")
        XCTAssertTrue(lit.regions.contains(id))
    }

    func test_severalItemsInOneDropShareOneRegion() throws {
        let model = attachedModel()

        let made = CanvasExternalDrop.apply(
            paths: ["canvas_assets/a.png", "canvas_assets/b.png", "canvas_assets/c.png"],
            aspects: [:], at: CGPoint(x: 300, y: 300), in: model, wrappingInPiece: "p1")

        XCTAssertEqual(made.nodes.count, 3)
        XCTAssertEqual(model.scene.regionCount, 1, "one drop, one region")
        let id = try XCTUnwrap(made.wrappedIn)
        XCTAssertEqual(model.scene.region(id)?.homeMembers, Set(made.nodes))
        XCTAssertEqual(model.scene.region(id)?.boundPieceID, "p1")
    }

    func test_anItemDroppedIntoARegionJoinsItAndNothingIsWrapped() throws {
        let model = attachedModel()
        let existing = CanvasRegionID("r1")
        model.withScene(persist: false) {
            $0.insertRegion(CanvasRegion(id: existing, label: "Fog",
                                         frame: CGRect(x: 100, y: 100, width: 400, height: 300)))
        }
        let node = try researchNode(at: CGPoint(x: 150, y: 150), in: model)

        let wrapped = CanvasDrop.apply(node, in: model, wrappingInPiece: "p1")

        XCTAssertNil(wrapped, "a drop into a region joins it and makes none")
        XCTAssertEqual(model.scene.regionCount, 1)
        let region = try XCTUnwrap(model.scene.region(existing))
        XCTAssertTrue(region.livesHere(node.id))
        XCTAssertNil(region.boundPieceID, "the existing region's binding is the writer's, untouched")
    }

    func test_theBookLeavesDropsLoose() throws {
        XCTAssertNil(CanvasDropWrap.piece(for: .wholeProject))
        XCTAssertNil(CanvasDropWrap.piece(for: .group(["p1", "p2"])))
        XCTAssertNil(CanvasDropWrap.piece(for: .research("res-note")))
        XCTAssertEqual(CanvasDropWrap.piece(for: .piece("p1")), "p1")

        let model = attachedModel()
        let node = try researchNode(at: CGPoint(x: 200, y: 150), in: model)
        let wrapped = CanvasDrop.apply(node, in: model,
                                       wrappingInPiece: CanvasDropWrap.piece(for: .wholeProject))
        XCTAssertNil(wrapped)
        XCTAssertEqual(model.scene.regionCount, 0, "with the book selected the drop lands loose")
    }

    func test_theWrapAbsorbsNoBystander() throws {
        let model = attachedModel()
        let bystander = CanvasNodeID("bystander")
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: bystander, kind: .scrap, origin: CGPoint(x: 210, y: 155),
                                 width: 20, cachedHeight: 10, z: 1))
        }
        let node = try researchNode(at: CGPoint(x: 200, y: 150), in: model)

        let id = try XCTUnwrap(CanvasDrop.apply(node, in: model, wrappingInPiece: "p1"))

        let region = try XCTUnwrap(model.scene.region(id))
        let bystanderFrame = try XCTUnwrap(model.scene.node(bystander)?.frame)
        XCTAssertTrue(region.frame.contains(CGPoint(x: bystanderFrame.midX, y: bystanderFrame.midY)),
                      "premise: the bystander's centre is inside the wrap")
        XCTAssertEqual(region.homeMembers, [node.id])
        XCTAssertNil(CanvasMembership.homeRegion(of: bystander, in: model.scene),
                     "the wrap is the drop's container, not a sweep")
    }

    func test_theWrapFrameIsNeverUnderMinimumSide() {
        let tiny = CanvasDropWrap.frame(around: [CGRect(x: 10, y: 20, width: 5, height: 5)])
        XCTAssertGreaterThanOrEqual(tiny.width, CanvasRegionMetrics.minimumSide)
        XCTAssertGreaterThanOrEqual(tiny.height, CanvasRegionMetrics.minimumSide)

        let pad = CanvasClaudePlacement.padding
        let chrome = CanvasRegionMetrics.chromeHeight
        let a = CGRect(x: 0, y: 0, width: 200, height: 100)
        let b = CGRect(x: 150, y: 80, width: 200, height: 100)
        XCTAssertEqual(CanvasDropWrap.frame(around: [a, b]),
                       CGRect(x: -pad, y: -chrome - pad,
                              width: 350 + 2 * pad, height: 180 + chrome + 2 * pad),
                       "the union, padded, with the chrome bar above")
    }

    func test_oneUndoTakesTheItemAndItsRegion() throws {
        let model = attachedModel()
        let before = model.scene
        let node = try researchNode(at: CGPoint(x: 200, y: 150), in: model)

        XCTAssertNotNil(CanvasDrop.apply(node, in: model, wrappingInPiece: "p1"))

        XCTAssertTrue(model.undo.undoMenuItemTitle.contains(CanvasDrop.undoStepName),
                      "found: " + model.undo.undoMenuItemTitle)
        model.undo.undo()
        XCTAssertEqual(model.scene, before, "one ⌘Z takes the card and its region")
        XCTAssertFalse(model.undoManager.canUndo, "and it was one step")
    }

    // MARK: - A photograph is born at its real height (task 3 review)

    /// A portrait PNG on disk, outside any project: 200×400.
    private func writePortraitPNG() throws -> URL {
        let url = root.appendingPathComponent("portrait-\(UUID().uuidString).png")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private var portraitHeight: CGFloat {
        CanvasCardMetrics.itemCardHeight(forCardWidth: CanvasInteraction.defaultScrapWidth,
                                         pictureAspect: 0.5)
    }

    private func assertSitsInside(_ node: CanvasNodeID, _ region: CanvasRegionID,
                                  _ scene: CanvasScene, file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let frame = try XCTUnwrap(scene.node(node)?.frame, file: file, line: line)
        let wrap = try XCTUnwrap(scene.region(region)?.frame, file: file, line: line)
        XCTAssertTrue(wrap.contains(frame), "\(frame) is not inside its wrap \(wrap)",
                      file: file, line: line)
    }

    func test_aPortraitPhotoDroppedFromTheFinderSitsInsideItsWrap() async throws {
        let png = try writePortraitPNG()
        let seam = CanvasAssetIngest(file: { _ in "canvas_assets/portrait.png" },
                                     image: { _ in throw CanvasAssetIngest.Unavailable() })
        let outcome = await CanvasExternalDrop.ingest(
            providers: [NSItemProvider(item: png as NSURL,
                                       typeIdentifier: UTType.fileURL.identifier)],
            using: seam)
        XCTAssertEqual(outcome.aspects["canvas_assets/portrait.png"] ?? 0, 0.5, accuracy: 0.0001)

        let model = attachedModel()
        let made = CanvasExternalDrop.apply(paths: outcome.paths, aspects: outcome.aspects,
                                            at: CGPoint(x: 100, y: 100), in: model,
                                            wrappingInPiece: "p1")

        let id = try XCTUnwrap(made.nodes.first)
        XCTAssertEqual(model.scene.node(id)?.cachedHeight, portraitHeight,
                       "born at the photograph's height, not a label's")
        XCTAssertGreaterThan(portraitHeight, CanvasCardMetrics.itemLabelOnlyHeight)
        try assertSitsInside(id, try XCTUnwrap(made.wrappedIn), model.scene)
    }

    func test_aPortraitCaptureSitsInsideItsWrap() throws {
        var scene = CanvasScene()
        let landing = CanvasCapture.plan(.picture(path: "canvas_assets/p.png", aspect: 0.5),
                                         .dropped(at: CGPoint(x: 40, y: 90), wrappingInPiece: "p1"),
                                         captureID: "c1", in: scene)
        XCTAssertEqual(landing.node.cachedHeight, portraitHeight)

        let region = try XCTUnwrap(CanvasCapture.apply(landing, to: &scene))
        try assertSitsInside(landing.node.id, region, scene)
    }

    func test_aResearchPhotoIsBornAtItsAspectAndANoteAtTheLabelFloor() throws {
        let scene = CanvasScene()
        guard case .create(let photo) = CanvasDrop.decide(
            payload: noteID, at: .zero, in: scene, index: index(), pictureAspect: 0.5),
              case .create(let note) = CanvasDrop.decide(
            payload: noteID, at: .zero, in: scene, index: index(), pictureAspect: nil) else {
            return XCTFail("a known id creates")
        }
        XCTAssertEqual(photo.cachedHeight, portraitHeight)
        XCTAssertEqual(note.cachedHeight, CanvasCardMetrics.itemLabelOnlyHeight)
    }

    func test_aWrappedCaptureDropLandsInABoundRegion() throws {
        var scene = CanvasScene()
        let landing = CanvasCapture.plan(.words("A heron on the weir"),
                                         .dropped(at: CGPoint(x: 40, y: 90), wrappingInPiece: "p1"),
                                         captureID: "c1", in: scene)

        let wrapped = CanvasCapture.apply(landing, to: &scene)

        let id = try XCTUnwrap(wrapped)
        XCTAssertEqual(scene.region(id)?.boundPieceID, "p1")
        XCTAssertEqual(scene.region(id)?.homeMembers, [landing.node.id])

        var loose = CanvasScene()
        let unwrapped = CanvasCapture.plan(.words("x"), .dropped(at: .zero, wrappingInPiece: nil),
                                           captureID: "c2", in: loose)
        XCTAssertNil(CanvasCapture.apply(unwrapped, to: &loose))
        XCTAssertEqual(loose.regionCount, 0)
    }
}
