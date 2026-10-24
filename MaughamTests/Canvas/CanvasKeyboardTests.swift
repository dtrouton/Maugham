import XCTest
@testable import Maugham

final class CanvasKeyboardTests: XCTestCase {

    private func id(_ s: String) -> CanvasNodeID { CanvasNodeID(s) }

    private func card(_ s: String, _ x: CGFloat, _ y: CGFloat, w: CGFloat = 100, h: CGFloat? = 50) -> CanvasNode {
        CanvasNode(id: id(s), kind: .scrap, origin: CGPoint(x: x, y: y), width: w, cachedHeight: h)
    }

    // MARK: - Tables

    func test_theCanvasKeyTable() {
        let k = CanvasKeyboard.canvasKey
        XCTAssertEqual(k("\r", []), .returnKey)
        XCTAssertEqual(k("\u{3}", []), .returnKey)
        XCTAssertEqual(k("\r", [.numericPad, .capsLock]), .returnKey)
        XCTAssertEqual(k("\r", .command), .commandReturn)
        XCTAssertNil(k("\r", [.command, .shift]))
        XCTAssertNil(k("\r", [.command, .option]))
        XCTAssertNil(k("\r", [.command, .control]))
        XCTAssertNil(k("\r", .option))
        XCTAssertNil(k("\r", .shift))
        XCTAssertEqual(k("\t", []), .tab)
        XCTAssertEqual(k("\u{19}", []), .backtab)
        XCTAssertEqual(k("\t", .shift), .backtab)
        XCTAssertEqual(k("\u{19}", .shift), .backtab, "AppKit keeps .shift set on ⇧Tab")
        XCTAssertNil(k("\r", .control))
        XCTAssertNil(k("\t", .command))
        XCTAssertEqual(k("\u{F700}", [.numericPad, .function]), .arrow(.up))
        XCTAssertEqual(k("\u{F701}", []), .arrow(.down))
        XCTAssertEqual(k("\u{F702}", []), .arrow(.left))
        XCTAssertEqual(k("\u{F703}", []), .arrow(.right))
        XCTAssertNil(k("\u{F703}", .shift))
        XCTAssertNil(k("\u{7F}", []))
        XCTAssertNil(k("a", []))
        XCTAssertNil(k(nil, []))
    }

    func test_theEditorCommandTable() {
        func c(_ s: Selector, _ m: NSEvent.ModifierFlags = []) -> ScrapEditorCommand? {
            CanvasKeyboard.editorCommand(selector: s, modifiers: m, hasMarkedText: false)
        }
        XCTAssertEqual(c(#selector(NSResponder.insertNewline(_:))), .finish)
        XCTAssertNil(c(#selector(NSResponder.insertNewline(_:)), .shift))
        XCTAssertNil(c(#selector(NSResponder.insertLineBreak(_:))))
        XCTAssertNil(c(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))))
        XCTAssertEqual(c(#selector(NSResponder.cancelOperation(_:))), .finish)
        XCTAssertEqual(c(#selector(NSResponder.insertTab(_:))), .makeJoined)
        XCTAssertNil(c(#selector(NSResponder.insertBacktab(_:))))
        XCTAssertNil(c(#selector(NSResponder.moveLeft(_:))))
    }

    func test_aKeyDuringMarkedTextIsLeftToTheInputMethod() {
        for s in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)),
                  #selector(NSResponder.insertTab(_:))] {
            XCTAssertNil(CanvasKeyboard.editorCommand(selector: s, modifiers: [], hasMarkedText: true))
        }
    }

    func test_commandShiftReturnIsNeverAnEditorKeyEquivalent() {
        XCTAssertEqual(CanvasKeyboard.editorKeyEquivalent(characters: "\r", modifiers: .command), .makeBelow)
        XCTAssertNil(CanvasKeyboard.editorKeyEquivalent(characters: "\r", modifiers: [.command, .shift]))
        XCTAssertNil(CanvasKeyboard.editorKeyEquivalent(characters: "\r", modifiers: []))
        XCTAssertNil(CanvasKeyboard.editorKeyEquivalent(characters: "x", modifiers: .command))
    }

    // MARK: - Placement

    private let size = CGSize(width: 100, height: 50)

    func test_placementOnAnEmptySceneIsTheStart() {
        let p = CanvasKeyboard.clearOrigin(startingAt: CGPoint(x: 7, y: 9), stepping: .down,
                                           size: size, in: CanvasScene())
        XCTAssertEqual(p, CGPoint(x: 7, y: 9))
    }

    func test_placementStepsPastAColumnOfCardsAndTerminates() {
        var s = CanvasScene()
        let gap = CanvasKeyboard.placementGap
        for i in 0..<300 {
            s.insert(card("c\(i)", 0, CGFloat(i) * (50 + gap)))
        }
        let p = CanvasKeyboard.clearOrigin(startingAt: .zero, stepping: .down, size: size, in: s)
        let placed = CGRect(origin: p, size: size)
        for i in 0..<199 {
            XCTAssertFalse(placed.intersects(s.node(id("c\(i)"))!.frame!), "overlaps c\(i)")
        }
        // The step limit is why it stops here: 200 steps, each past one card, lands
        // just below c199 (cards are one gap apart), at c200's origin.
        XCTAssertEqual(p, s.node(id("c200"))!.origin)
    }

    func test_aHugeRegionDoesNotBlockPlacement() {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r"), label: "R",
                                    frame: CGRect(x: -1000, y: -1000, width: 5000, height: 5000)))
        XCTAssertEqual(CanvasKeyboard.clearOrigin(startingAt: .zero, stepping: .down, size: size, in: s), .zero)
    }

    func test_aCardAtExactly45DegreesAnswersToBothArrows() {
        var s = CanvasScene()
        s.insert(card("d", 200, 175))   // centre (250,200) from (50,0): dx = dy = 200
        XCTAssertEqual(CanvasKeyboard.nearest(from: CGPoint(x: 50, y: 0), toward: .right, in: s, excluding: nil), id("d"))
        XCTAssertEqual(CanvasKeyboard.nearest(from: CGPoint(x: 50, y: 0), toward: .down, in: s, excluding: nil), id("d"))
    }

    func test_placementStepsRightPastACard() {
        var s = CanvasScene()
        s.insert(card("a", 0, 0))
        let p = CanvasKeyboard.clearOrigin(startingAt: .zero, stepping: .right, size: size, in: s)
        XCTAssertEqual(p, CGPoint(x: 100 + CanvasKeyboard.placementGap, y: 0))
    }

    func test_placementIgnoresHiddenCards() {
        var s = CanvasScene()
        s.insert(card("a", 0, 0))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r"), label: "R",
                                    frame: CGRect(x: -500, y: -500, width: 10, height: 10),
                                    isCollapsed: true))
        CanvasMembership.join(id("a"), home: CanvasRegionID("r"), in: &s)
        XCTAssertTrue(s.isHidden(id("a")))
        XCTAssertEqual(CanvasKeyboard.clearOrigin(startingAt: .zero, stepping: .down, size: size, in: s), .zero)
    }

    func test_placementIgnoresUnmeasuredCards() {
        var s = CanvasScene()
        s.insert(card("a", 0, 0, h: nil))
        XCTAssertEqual(CanvasKeyboard.clearOrigin(startingAt: .zero, stepping: .down, size: size, in: s), .zero)
    }

    func test_aCardExactlyOneGapAwayIsClear() {
        var s = CanvasScene()
        let gap = CanvasKeyboard.placementGap
        s.insert(card("a", 0, 0))
        let start = CGPoint(x: 0, y: 50 + gap)
        XCTAssertEqual(CanvasKeyboard.clearOrigin(startingAt: start, stepping: .down, size: size, in: s), start)
        let tooClose = CGPoint(x: 0, y: 50 + gap - 1)
        XCTAssertEqual(CanvasKeyboard.clearOrigin(startingAt: tooClose, stepping: .down, size: size, in: s), start)
    }

    func test_newCardSizeIsTheDefaultWidthAndAnEmptyCardsHeight() {
        let z = CanvasKeyboard.newCardSize()
        XCTAssertEqual(z.width, CanvasInteraction.defaultScrapWidth)
        XCTAssertEqual(z.height, CanvasScrapMeasure.height(text: "", cardWidth: z.width))
    }

    // MARK: - Arrow targets

    func test_nearestRespectsTheConeAndDistance() {
        var s = CanvasScene()
        s.insert(card("near", 300, 0))     // centre (350,25)
        s.insert(card("far", 600, 0))
        s.insert(card("off", 200, 400))    // outside the right cone
        let from = CGPoint(x: 50, y: 25)
        XCTAssertEqual(CanvasKeyboard.nearest(from: from, toward: .right, in: s, excluding: nil), id("near"))
        XCTAssertEqual(CanvasKeyboard.nearest(from: from, toward: .down, in: s, excluding: nil), id("off"))
        XCTAssertEqual(CanvasKeyboard.nearest(from: from, toward: .right, in: s, excluding: id("near")), id("far"))
        XCTAssertNil(CanvasKeyboard.nearest(from: from, toward: .left, in: s, excluding: nil))
        XCTAssertNil(CanvasKeyboard.nearest(from: from, toward: .up, in: s, excluding: nil))
    }

    func test_nearestTiesBreakOnTheSmallerID() {
        var s = CanvasScene()
        s.insert(card("b", 300, -100))
        s.insert(card("a", 300, 100))
        XCTAssertEqual(CanvasKeyboard.nearest(from: CGPoint(x: 50, y: 25), toward: .right, in: s, excluding: nil), id("a"))
    }

    func test_noCandidateIsNil() {
        XCTAssertNil(CanvasKeyboard.nearest(from: .zero, toward: .right, in: CanvasScene(), excluding: nil))
    }

    func test_nearestSkipsHiddenAndUnmeasured() {
        var s = CanvasScene()
        s.insert(card("hid", 300, 0))
        s.insert(card("unm", 310, 0, h: nil))
        s.insert(card("ok", 900, 0))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r"), label: "R",
                                    frame: CGRect(x: -500, y: -500, width: 10, height: 10),
                                    isCollapsed: true))
        CanvasMembership.join(id("hid"), home: CanvasRegionID("r"), in: &s)
        XCTAssertEqual(CanvasKeyboard.nearest(from: .zero, toward: .right, in: s, excluding: nil), id("ok"))
    }

    // MARK: - Centre

    func test_centreOfANodeARegionAndALine() {
        var s = CanvasScene()
        s.insert(card("a", 0, 0))
        s.insert(card("b", 200, 100))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r"), label: "R", frame: CGRect(x: 10, y: 20, width: 100, height: 60)))
        s.insertLine(CanvasLine(id: CanvasLineID("l"), from: id("a"), to: id("b")))
        XCTAssertEqual(CanvasKeyboard.centre(of: .node(id("a")), in: s), CGPoint(x: 50, y: 25))
        XCTAssertEqual(CanvasKeyboard.centre(of: .region(CanvasRegionID("r")), in: s), CGPoint(x: 60, y: 50))
        XCTAssertNil(CanvasKeyboard.centre(of: .node(id("zz")), in: s))
    }

    func test_centreOfALineIsTheMidpoint() {
        var s = CanvasScene()
        s.insert(card("a", 0, 0))      // centre (50,25)
        s.insert(card("b", 200, 100))  // centre (250,125)
        s.insertLine(CanvasLine(id: CanvasLineID("l"), from: id("a"), to: id("b")))
        XCTAssertEqual(CanvasKeyboard.centre(of: .line(CanvasLineID("l")), in: s), CGPoint(x: 150, y: 75))
    }

    // MARK: - Reveal

    func test_revealIsANoOpForAVisibleRectAndPansTheLeastOtherwise() {
        let view = CGSize(width: 800, height: 600)
        var c = CanvasCamera()
        c.reveal(CGRect(x: 100, y: 100, width: 200, height: 100), viewSize: view)
        XCTAssertEqual(c, CanvasCamera())

        c.reveal(CGRect(x: 700, y: 100, width: 200, height: 100), viewSize: view)  // maxX 900
        XCTAssertEqual(c.pan, CGPoint(x: -100, y: 0))

        c = CanvasCamera()
        c.reveal(CGRect(x: -50, y: 550, width: 100, height: 100), viewSize: view)  // left and bottom
        XCTAssertEqual(c.pan, CGPoint(x: 50, y: -50))
    }

    func test_revealNeverZooms() {
        var c = CanvasCamera()
        c.zoom = 2
        c.pan = CGPoint(x: 10, y: 10)
        c.reveal(CGRect(x: 1000, y: 1000, width: 100, height: 100), viewSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(c.zoom, 2)
        let v = c.viewPoint(fromContent: CGPoint(x: 1100, y: 1100))
        XCTAssertEqual(v.x, 800, accuracy: 0.001)
        XCTAssertEqual(v.y, 600, accuracy: 0.001)
    }
}
