import XCTest
import AppKit
@testable import Maugham

final class ScrapEditorHostTests: XCTestCase {

    private let size = CGSize(width: 240, height: 100)

    private func layout(_ text: String = "The falls at night: sodium light on the "
                        + "spray, and nobody there but the man selling ponchos.") -> ScrapLayout {
        ScrapLayout(text: text, width: 240,
                    font: NSFont(name: "Iowan Old Style", size: 13) ?? .systemFont(ofSize: 13))
    }

    /// Keep the window alive for the length of the test — a released window
    /// drops first responder and the assertion becomes a coin flip.
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    /// - Parameter contentSize: the window's content view. Defaults to the scrap's
    ///   unzoomed box, which is all most tests need; the rasterisation test hosts
    ///   in a bigger one because `cacheDisplay` clips to the visible rect and a
    ///   zoomed container is larger than the box it was laid out for.
    @discardableResult
    private func host(_ container: ScrapEditorContainer,
                      contentSize: CGSize? = nil) -> NSWindow {
        let frame = CGRect(origin: .zero, size: contentSize ?? size)
        let content = NSView(frame: frame)
        content.addSubview(container)
        let window = TestWindow.make(SilentTestWindow.self, contentRect: frame,
                                     contentView: content, present: .unshown)
        container.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    func test_boundsScalingLeavesTheUnzoomedCoordinateSpaceIntact() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 2)
        XCTAssertEqual(container.frame.size, CGSize(width: 480, height: 200))
        XCTAssertEqual(container.bounds.size, size,
                       "bounds must stay unzoomed — that is what keeps the drawn "
                       + "and edited layouts identical at zoom")
    }

    func test_zoomChangeResizesFrameButNeverBounds() {
        let container = ScrapEditorContainer(frame: .zero)
        let l = layout()
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        let signature = l.lineGeometrySignature
        container.mount(layout: l, unscaledSize: size, zoom: 3)
        XCTAssertEqual(container.bounds.size, size)
        XCTAssertEqual(l.lineGeometrySignature, signature,
                       "zooming must not re-lay-out the text")
    }

    /// The two tests above cannot tell bounds scaling from a blurry upscale: a
    /// layer scaled up 3x reports exactly the same frame and bounds and re-lays
    /// out nothing either. What separates them is whether AppKit rasterises the
    /// glyphs UNDER the scale — so this measures the pixels.
    ///
    /// Both halves are needed. The pixel dimensions prove the bounds→frame scale
    /// reaches the backing store rather than being a bitmap stretch after the
    /// fact; the ink count growing as zoom² proves real glyphs were drawn into
    /// those pixels and not one glyph's worth smeared across them.
    func test_boundsScalingReRasterisesRatherThanUpscaling() throws {
        let big = CGSize(width: 800, height: 400)

        func ink(atZoom zoom: CGFloat) throws -> (pixelsWide: Int, ink: Int) {
            let container = ScrapEditorContainer(frame: .zero)
            container.mount(layout: layout(), unscaledSize: size, zoom: zoom)
            host(container, contentSize: big)
            let rep = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: rep)
            return (rep.pixelsWide, try inkPixelCount(rep))
        }

        let one = try ink(atZoom: 1)
        let three = try ink(atZoom: 3)

        XCTAssertGreaterThan(one.ink, 0, "nothing was drawn — the measurement is vacuous")
        XCTAssertEqual(Double(three.pixelsWide) / Double(one.pixelsWide), 3, accuracy: 0.02,
                       "the backing store did not grow with zoom, so the glyphs were "
                       + "not rasterised under the scale — this is an upscale")

        // UPPER BOUND, and the principled half: a 3x upscale maps each source
        // pixel onto exactly 9, so pixel replication lands AT 9 — or above it,
        // once interpolation bleeds the antialiased edges.
        //
        // Why honest rasterisation lands BELOW 9 is not that the strokes thin
        // out: stroke width scales with point size, so glyph ink area grows as
        // zoom² under honest rasterisation too, and the geometric expectation is
        // also ≈9. It is the counter. `inkPixelCount` scores any non-zero sample,
        // so at 13pt a large share of what it counts is faint antialiased fringe
        // (plus small-size stem darkening), which inflates the 1x denominator.
        // Measured 2026-07-26 on macOS 26.5: 480px/9536 ink at 1x, 1440px/56503
        // at 3x — ratio 5.93. Expect that number to move with the typeface:
        // `layout()` falls back to `systemFont` where Iowan Old Style is absent,
        // and this is the only test here whose numbers depend on which font ran.
        //
        // LOWER BOUND, and it is not decorative: it guards a failure the
        // assertion above cannot see. Drop the bounds restore in `mount` — let
        // bounds grow with the frame — and the glyphs are rasterised at their
        // UNZOOMED size into a backing store that still grew 3x, so the text
        // does not grow with the card. Measured by mutation 2026-07-26: the
        // pixel-dimension assertion above PASSED and this one failed, at a ratio
        // of exactly 1.0.
        let ratio = Double(three.ink) / Double(one.ink)
        XCTAssertGreaterThan(ratio, 3,
                             "ink did not grow with the raster — the glyphs were "
                             + "drawn at their unzoomed size into a zoomed backing "
                             + "store, so the text does not grow with the card")
        XCTAssertLessThan(ratio, 9,
                          "ink grew by exactly the pixel count, which is what "
                          + "replicating each source pixel 3x3 does — the glyphs "
                          + "were upscaled, not re-rasterised")
    }

    private func inkPixelCount(_ rep: NSBitmapImageRep) throws -> Int {
        try XCTSkipIf(rep.isPlanar || rep.bitsPerSample != 8,
                      "unexpected bitmap format: \(rep.bitmapFormat)")
        let data = try XCTUnwrap(rep.bitmapData)
        let samples = rep.samplesPerPixel
        var count = 0
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide {
                let pixel = row + x * samples
                for sample in 0..<samples where pixel[sample] != 0 {
                    count += 1
                    break
                }
            }
        }
        return count
    }

    /// `mount` writes `frame` and then `bounds`, so the invariant it sets up would
    /// be sequence-dependent if anything else could write the frame — and
    /// something can: this is an `NSViewRepresentable`, and SwiftUI's layout pass
    /// writes the hosted view's frame after `updateNSView` has returned, at a size
    /// it derived itself.
    ///
    /// What has to survive that is the SCALE — not `bounds.size`. The scale is
    /// what the glyphs are rasterised and positioned at, so it is what keeps the
    /// editor's text on top of the same layout the renderer is drawing (§7A.2).
    ///
    /// AppKit already defends it. Measured on macOS 26.5, an `NSView` holds a
    /// per-axis frame→bounds scale and moves `bounds.size` with the frame to
    /// PRESERVE that scale, rather than holding the bounds size and letting the
    /// scale move. Every external write tried over a 2x mount left the scale at
    /// exactly (2, 2), the text view included: a 500x210 write, a reposition, a
    /// 1pt `setFrameSize` nudge, frame → .zero and back, a superview autoresize,
    /// two writes in a row, and a layout+display pass afterwards.
    ///
    /// The aspect-breaking write below is the discriminator, which is why it is
    /// the one asserted. A preserved-SIZE model keeps bounds at 240x100 and
    /// splits the scale to (4, 1); a preserved-SCALE model moves bounds to
    /// 480x50 and holds (2, 2). It is the second.
    ///
    /// So the container deliberately does NOT override `setFrameSize` to force
    /// `bounds.size` back to the unzoomed box. That override does not protect the
    /// invariant, it breaks it: measured by mutation 2026-07-26, it puts the
    /// editor at scale 2.0833 under a 500x210 frame — and at (2.833, 3.0) under a
    /// superview autoresize — while the renderer draws at 2, sliding the glyphs
    /// off the card beneath, which IS the text-jumping failure. Recomputing
    /// bounds as frame/zoom is the same mistake wearing a different hat: it
    /// hand-derives a scale AppKit already holds exactly (`ScrapLayout`
    /// requirement 3). This test fails if either is added, and if AppKit ever
    /// stops preserving the scale.
    func test_anExternalFrameWriteLeavesTheEditorAtTheCameraScale() throws {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 2)
        host(container, contentSize: CGSize(width: 1200, height: 800))
        let editor = try XCTUnwrap(container.textView)

        func scale(of view: NSView) -> (x: CGFloat, y: CGFloat) {
            let origin = view.convert(CGPoint.zero, to: nil)
            let alongX = view.convert(CGPoint(x: 100, y: 0), to: nil)
            let alongY = view.convert(CGPoint(x: 0, y: 100), to: nil)
            return ((alongX.x - origin.x) / 100, abs(alongY.y - origin.y) / 100)
        }

        // Aspect-breaking on purpose — see the doc comment.
        container.wantsLayer = true
        container.frame = CGRect(x: 17, y: 23, width: 960, height: 100)

        let container2 = scale(of: container)
        XCTAssertEqual(container2.x, 2, accuracy: 0.0001,
                       "a frame write from outside mount changed the scale the "
                       + "editor draws at — its glyphs no longer land where the "
                       + "renderer is drawing the same layout, so the text jumps")
        XCTAssertEqual(container2.y, 2, accuracy: 0.0001,
                       "the vertical scale moved on its own — the frame→bounds "
                       + "scale is not being preserved per axis")
        // The one that actually reaches the glyphs.
        let editorScale = scale(of: editor)
        XCTAssertEqual(editorScale.x, 2, accuracy: 0.0001)
        XCTAssertEqual(editorScale.y, 2, accuracy: 0.0001)
        XCTAssertEqual(container.bounds.size, CGSize(width: 480, height: 50),
                       "AppKit no longer moves bounds to preserve the scale across "
                       + "a frame write, so mount's bounds restore IS now sequence-"
                       + "dependent and the container has to defend the scale itself")
    }

    func test_mountedEditorSharesTheLayoutStack() {
        let container = ScrapEditorContainer(frame: .zero)
        let l = layout()
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        host(container)
        container.textView?.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(l.text.hasPrefix("Z"))
    }

    /// Contract from Task 3: mount at the TEXT box, never the card. Mounting wider
    /// than the container is only survivable because `widthTracksTextView` is
    /// false, and that setting is the one thing between this design and a scrap
    /// that re-wraps every time it is clicked.
    func test_theEditorIsMountedAtTheUnzoomedTextBoxItWasGiven() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 3)
        XCTAssertEqual(container.textView?.frame.size, size,
                       "the text view lives in the container's UNZOOMED space; "
                       + "sizing it by zoom would double-apply the scale")
    }

    /// Contract from Task 3, and the reason it is asserted here as well as there:
    /// `textContainerInset` is the one lever that moves edited against drawn
    /// WITHOUT moving the shared layout, so `lineGeometrySignature` — and every
    /// other geometry assertion in this file — is blind to it. Only a bitmap
    /// caught it during the spike.
    func test_theMountedEditorKeepsTheZeroTextContainerInset() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        XCTAssertEqual(container.textView?.textContainerInset, .zero)
    }

    func test_remountingTheSameLayoutKeepsOneEditorAndDoesNotRebuild() {
        let container = ScrapEditorContainer(frame: .zero)
        let l = layout()
        XCTAssertTrue(container.mount(layout: l, unscaledSize: size, zoom: 1))
        XCTAssertFalse(container.mount(layout: l, unscaledSize: size, zoom: 1),
                       "the same layout must not tear down a live editor")
        XCTAssertEqual(container.subviews.count, 1)
    }

    /// Counting subviews is not enough: an editor still bound to the FIRST
    /// scrap while the writer types into the second is invisible to a count.
    func test_remountingADifferentLayoutRebindsTheEditorToTheNewScrap() {
        let container = ScrapEditorContainer(frame: .zero)
        let first = layout("first scrap")
        let second = layout("second scrap")

        container.mount(layout: first, unscaledSize: size, zoom: 1)
        host(container)
        XCTAssertTrue(container.mount(layout: second, unscaledSize: size, zoom: 1),
                      "a different layout must rebuild the editor")
        XCTAssertEqual(container.subviews.count, 1,
                       "a second mount must not leave the first editor behind")

        container.textView?.setSelectedRange(NSRange(location: 0, length: 0))
        container.textView?.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(second.text.hasPrefix("Z"),
                      "the editor is still bound to the FIRST scrap — clicking from "
                      + "scrap A to scrap B keeps editing A")
        XCTAssertFalse(first.text.hasPrefix("Z"))
    }

    /// The test above passes whether or not the old scrap was really detached:
    /// building the second editor binds the SECOND layout's container, so the
    /// first one is left holding a view nobody can see and nothing will notice.
    /// Task 3's `releaseEditor()` is the only real detach — `removeFromSuperview`
    /// leaves the container pointing at the view and the layout manager untouched,
    /// so whatever the mount did to the first scrap's layout stays done.
    func test_rebindingReallyDetachesTheOldScrapRatherThanJustUnparentingIt() throws {
        let container = ScrapEditorContainer(frame: .zero)
        let first = layout("first scrap")
        container.mount(layout: first, unscaledSize: size, zoom: 1)
        host(container)
        let firstEditor = try XCTUnwrap(container.textView)
        let signature = first.lineGeometrySignature

        container.mount(layout: layout("second scrap"), unscaledSize: size, zoom: 1)

        XCTAssertNil(firstEditor.textContainer,
                     "the first scrap's editor is still attached to its shared "
                     + "container — removeFromSuperview is not a detach")
        XCTAssertEqual(first.lineGeometrySignature, signature,
                       "blurring the first scrap moved its layout — its text jumps "
                       + "the moment the writer clicks away")
    }

    /// Task 3 advertises mount → release → remount but nothing there calls
    /// `makeEditor` twice. It is the sequence this container performs most: every
    /// focus change is one. An `NSTextContainer` holds a single `textView`, so a
    /// remount over a container that was never released rebinds it and orphans
    /// the first view.
    func test_theSameLayoutCanBeMountedReleasedAndMountedAgain() throws {
        let container = ScrapEditorContainer(frame: .zero)
        let l = layout("remount me")
        let signature = l.lineGeometrySignature

        container.mount(layout: l, unscaledSize: size, zoom: 1)
        host(container)
        container.unmount()

        XCTAssertTrue(container.mount(layout: l, unscaledSize: size, zoom: 1),
                      "a layout that was unmounted must rebuild on the way back in")
        XCTAssertEqual(container.subviews.count, 1)
        let editor = try XCTUnwrap(container.textView)
        XCTAssertNotNil(editor.textContainer,
                        "the remounted editor is not attached to the shared stack")

        // Before any typing, so what is compared is the effect of the CYCLE and
        // nothing else — and the WHOLE signature, not its count. Measured
        // 2026-07-26: the full signature does survive the cycle, byte for byte.
        //
        // The count alone cannot do this job, and the difference is not academic.
        // Asserted below the typing instead, as it was, `insertText("Z")` moves
        // this scrap's only line from 71.315918 pt wide to 78.645996 — a change
        // the count is blind to, which is why a count comparison was the only
        // form that could survive down there. A cycle that shifts a line without
        // changing how many there are is exactly the drift that shows up as text
        // jumping when the writer clicks back in.
        XCTAssertEqual(l.lineGeometrySignature, signature,
                       "a mount/unmount/mount cycle relaid the text out")

        container.requestFocus(caretIndex: 0)
        editor.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(l.text.hasPrefix("Z"),
                      "the remounted editor does not reach the scrap's storage — "
                      + "clicking back into a scrap gives a caret that types nowhere")
    }

    /// M7. `unmount` is a full teardown, so it must not leave the container in the
    /// mid-straighten state the last scrap was unmounted in: `isEditorVisible` is
    /// guarded on a real change, so a container unmounted while invisible and
    /// later remounted stays at alpha 0 until something writes a DIFFERENT value.
    /// Harmless while `dismantleNSView` discards the view, and a scrap that mounts
    /// focused and permanently invisible the moment anything reuses one.
    func test_unmountLeavesTheContainerReadyToBeSeenAgain() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        container.isEditorVisible = false

        container.unmount()

        XCTAssertTrue(container.isEditorVisible,
                      "unmount left the visibility switch where the straighten put it")
        XCTAssertEqual(container.alphaValue, 1,
                       "a reused container mounts invisible — the writer types into "
                       + "a scrap whose editor is never drawn")
    }

    func test_unmountDetachesTheEditorFromTheSharedStack() throws {
        let container = ScrapEditorContainer(frame: .zero)
        let l = layout()
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        host(container)
        let editor = try XCTUnwrap(container.textView)
        let signature = l.lineGeometrySignature

        container.unmount()

        XCTAssertNil(container.textView)
        XCTAssertEqual(container.subviews.count, 0)
        XCTAssertNil(editor.textContainer,
                     "unmount left the editor bound to the shared container — the "
                     + "stack is not drawn-only again and the next mount orphans it")
        XCTAssertNil(editor.delegate,
                     "a detached editor still reporting into the canvas is a "
                     + "keystroke folded into whatever scrap is focused next")
        XCTAssertEqual(l.lineGeometrySignature, signature,
                       "unmounting changed the layout — the text jumps on blur")
    }

    /// `makeNSView` runs before the view is in a window, so
    /// `tv.window` is nil and makeFirstResponder is a silent no-op.
    func test_focusRequestedBeforeMountIsClaimedOnceTheViewEntersAWindow() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        container.requestFocus(caretIndex: 3)
        XCTAssertNil(container.window, "precondition: not in a window yet")

        let window = host(container)

        XCTAssertTrue(window.firstResponder === container.textView,
                      "focus was requested while window was nil and silently dropped — "
                      + "the scrap mounts and refuses every keystroke")
        XCTAssertEqual(container.textView?.selectedRange().location, 3)
    }

    func test_focusRequestedWhileAlreadyInAWindowIsImmediate() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        let window = host(container)
        container.requestFocus(caretIndex: 0)
        XCTAssertTrue(window.firstResponder === container.textView)
    }

    /// The whole reason the editor mounts on the click rather than on `isLevel`:
    /// double-click empty canvas and start typing, and the first characters must
    /// land somewhere. They land here, in an editor nobody can see yet, while the
    /// renderer keeps drawing the card's own (rotating, live) text.
    func test_anInvisibleEditorStillHoldsFocusAndTakesKeystrokes() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        let l = layout("before")
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        container.isEditorVisible = false
        let window = host(container)
        container.requestFocus(caretIndex: 0)

        XCTAssertEqual(container.alphaValue, 0,
                       "the editor must not be drawn while the card is still "
                       + "drawing its own text — that is a double-draw")
        XCTAssertTrue(window.firstResponder === container.textView,
                      "invisible must not mean unfocused, or the writer's first "
                      + "characters after a double-click go nowhere")

        container.textView?.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(l.text.hasPrefix("Z"),
                      "a keystroke during the straighten was discarded")
    }

    /// Visibility and hit testing are the same switch. While the editor is
    /// invisible the pointer belongs to `CanvasEventNSView`, whose space IS
    /// canvas space — so nothing resolves a click or a pinch against the
    /// editor's unrotated box while the card under it is still tilted.
    func test_anInvisibleEditorLetsThePointerThroughToTheCanvas() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        host(container)
        let inside = CGPoint(x: 10, y: 10)

        XCTAssertNotNil(container.hitTest(inside),
                        "precondition: a visible editor owns its own mouse")
        container.isEditorVisible = false
        XCTAssertNil(container.hitTest(inside),
                     "an invisible editor is still frontmost — if it hit-tests it "
                     + "eats the click and anchors the pinch on a card that is "
                     + "not where the writer sees it")
    }

    /// Not `isHidden`, and not SwiftUI's `.hidden()`: AppKit moves first responder
    /// off a hidden view, which loses exactly the keystrokes that mounting on the
    /// click exists to keep. This pins the mechanism, not just the outcome.
    func test_invisibilityIsAlphaAndHitTestingRatherThanHiding() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        host(container)
        container.isEditorVisible = false
        XCTAssertFalse(container.isHidden,
                       "isHidden takes first responder off the view; alphaValue does not")
        XCTAssertFalse(container.textView?.isHidden == true)
    }

    func test_caretIndexBeyondTheTextIsClampedRatherThanCrashing() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        let l = layout("short")
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        host(container)
        container.requestFocus(caretIndex: 9_999)
        XCTAssertEqual(container.textView?.selectedRange().location, 5)
    }

    /// The caret index comes from `ScrapLayout.characterIndex(at:)`, which is an
    /// offset into an `NSTextStorage` — UTF-16. Clamping it against `String.count`
    /// instead clamps a perfectly valid caret backwards the moment a scrap
    /// contains an emoji, and lands it at the wrong word.
    func test_theCaretClampCountsTheSameUnitsAsTheSelection() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        // Three non-BMP characters: 6 UTF-16 units, 3 Swift Characters.
        let l = layout("👋👋👋")
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        host(container)
        container.requestFocus(caretIndex: 6)
        XCTAssertEqual(container.textView?.selectedRange().location, 6,
                       "the caret was clamped in Characters against a range measured "
                       + "in UTF-16 units, so it landed short of where the writer clicked")
    }

    /// C5. Typing mutates the shared NSTextStorage in place. If nothing reports
    /// that, `scraps[id]` keeps the text as it was BEFORE the writer typed — the
    /// debounced payload is stale, the drawn card never grows, and quitting
    /// without clicking away leaves an empty scrap on disk.
    func test_typingReportsItselfSoTheCanvasCanFoldItIntoTheModel() {
        let container = ScrapEditorContainer(frame: .zero)
        var changes = 0
        container.onTextChanged = { changes += 1 }
        let l = layout("before")
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        host(container)

        container.textView?.setSelectedRange(NSRange(location: 0, length: 0))
        container.textView?.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertGreaterThan(changes, 0,
                             "nothing told the canvas the writer typed — the words "
                             + "live only in the NSTextStorage and are lost on quit")
        XCTAssertTrue(l.text.hasPrefix("Z"))
    }

    func test_mountSetsTheContainerAsTheTextViewsDelegate() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        XCTAssertTrue(container.textView?.delegate === container,
                      "without the delegate there is no textDidChange and C5 returns")
    }

    /// The editor is frontmost, so it gets the scroll wheel while the writer is
    /// editing. Without forwarding, panning dies wherever the scrap is.
    func test_theContainerForwardsScrollAndMagnifyToTheCamera() {
        let container = ScrapEditorContainer(frame: .zero)
        var scrolls: [CGFloat] = []
        var magnifications: [CGFloat] = []
        container.onScroll = { _, dy, _ in scrolls.append(dy) }
        container.onMagnify = { m, _ in magnifications.append(m) }
        container.applyScroll(deltaX: 0, deltaY: 12, precise: true)
        container.applyMagnify(magnification: 0.25, atEditorPoint: .zero)
        XCTAssertEqual(scrolls, [12])
        XCTAssertEqual(magnifications, [0.25])
    }

    /// I7. The container's bounds are the scrap's own UNZOOMED text box, so the
    /// point it forwards is not canvas space and must not be scaled on the way
    /// out either — `ScrapEditorGeometry` is the one place that maps it.
    func test_theForwardedMagnifyPointStaysInTheEditorsOwnUnzoomedSpace() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 2)
        var points: [CGPoint] = []
        container.onMagnify = { _, p in points.append(p) }
        container.applyMagnify(magnification: 0.1, atEditorPoint: CGPoint(x: 10, y: 20))
        XCTAssertEqual(points, [CGPoint(x: 10, y: 20)],
                       "the container must not pre-apply zoom — bounds are unzoomed")
    }

    /// The mapping the composed view uses. Anchoring the pinch on the raw
    /// editor point instead zooms about a point the writer never touched.
    func test_editorPointsMapIntoCanvasViewSpaceThroughTheCamera() {
        var camera = CanvasCamera()
        camera.zoom = 2
        camera.pan = CGPoint(x: 50, y: 30)
        let mapped = ScrapEditorGeometry.viewPoint(fromEditorPoint: CGPoint(x: 10, y: 10),
                                                   textOrigin: CGPoint(x: 100, y: 100),
                                                   camera: camera)
        // content (110,110) -> view (50 + 220, 30 + 220)
        XCTAssertEqual(mapped.x, 270, accuracy: 0.0001)
        XCTAssertEqual(mapped.y, 250, accuracy: 0.0001)
    }

    /// ⌘Z while a scrap is focused must run the CANVAS stack (Task 15).
    ///
    /// The plan asserted this as `textView.undoManager === manager` alongside
    /// `allowsUndo == false`. Those two cannot both hold: measured on macOS 26.5,
    /// `NSTextView` gates `undoManager` on `allowsUndo` and returns nil before
    /// consulting delegate or responder chain, so with `allowsUndo` false the
    /// text view's manager is nil no matter what is wired to it, and with it true
    /// the text view starts registering typing steps on the canvas stack — the
    /// double-registration `ScrapLayout.makeEditor` rejects at length.
    ///
    /// So the reachable contract is asserted instead, end to end: the text view
    /// keeps no stack, the action walks past it to the container, and the
    /// container runs the canvas manager. The nil assertion is the load-bearing
    /// one — it is the premise the container's `undo:` exists for, and if a
    /// future AppKit stops short-circuiting, this test says so.
    func test_undoWhileEditingRunsTheCanvasStack() throws {
        let container = ScrapEditorContainer(frame: .zero)
        let manager = UndoManager()
        // The recorder rather than the bare manager: ⌘Z inside a scrap has an
        // open gesture to close first, so `undo:` routes through `CanvasUndo`.
        container.canvasUndo = CanvasUndo(undoManager: manager)
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        host(container)
        let editor = try XCTUnwrap(container.textView)

        XCTAssertFalse(editor.allowsUndo,
                       "one change, one step: see ScrapLayout.makeEditor")
        XCTAssertNil(editor.undoManager,
                     "the text view vends a stack again — re-check whether it is "
                     + "now registering its own typing steps on the canvas manager")
        XCTAssertFalse(editor.responds(to: #selector(ScrapEditorContainer.undo(_:))),
                       "if NSTextView starts handling undo: the action stops here "
                       + "and never reaches the canvas stack")
        XCTAssertTrue(editor.nextResponder === container,
                      "the chain from the editor must arrive at the container")

        // Falsifiable end to end: register on the canvas stack, send the action
        // the way the menu does, and require that it actually ran.
        var undone = false
        manager.registerUndo(withTarget: self) { _ in undone = true }
        container.undo(nil)
        XCTAssertTrue(undone,
                      "⌘Z inside a scrap did not reach the canvas stack — it runs "
                      + "the window delegate's manager, which is SwiftUI's")
    }

    /// AppKit enables a menu item whose responder merely responds to the
    /// selector, so the container claiming `undo:` is what would otherwise offer
    /// a live Undo over an empty stack the instant a scrap takes focus.
    func test_undoIsOfferedOnlyWhenTheCanvasStackHasSomethingToUndo() {
        let container = ScrapEditorContainer(frame: .zero)
        let manager = UndoManager()
        // The recorder rather than the bare manager: ⌘Z inside a scrap has an
        // open gesture to close first, so `undo:` routes through `CanvasUndo`.
        container.canvasUndo = CanvasUndo(undoManager: manager)
        let item = NSMenuItem(title: "Undo",
                              action: #selector(ScrapEditorContainer.undo(_:)),
                              keyEquivalent: "z")

        XCTAssertFalse(container.validateUserInterfaceItem(item),
                       "Undo is enabled with nothing on the canvas stack")
        manager.registerUndo(withTarget: self) { _ in }
        XCTAssertTrue(container.validateUserInterfaceItem(item))
    }

    /// Spec §7A.6: the mounted editor must stay reachable by VoiceOver. It is a
    /// real NSTextView, so this is about not hiding it.
    ///
    /// The plan expected this to need adjusting, because `isAccessibilityElement()`
    /// is not contractually pinned for an unhosted `NSView`. It did not: measured
    /// 2026-07-26, both assertions hold whether or not the container is in a
    /// window. It is hosted anyway, so what is asserted is a view in the state
    /// VoiceOver would actually meet it in. What it guards is narrow and worth
    /// being clear about — it cannot fail on AppKit's defaults, only if this file
    /// starts calling `setAccessibilityElement`. Task 14 owns the real
    /// accessibility layer.
    func test_theMountedEditorIsExposedToAccessibility() throws {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        host(container)
        let editor = try XCTUnwrap(container.textView)

        XCTAssertFalse(container.isAccessibilityElement(),
                       "the container must not absorb its text view's AX identity")
        XCTAssertTrue(editor.isAccessibilityElement())

        // The two above are AppKit defaults. This one is reachability — it is
        // what VoiceOver actually walks, and it can fail for reasons other than a
        // `setAccessibilityElement` call in this file.
        XCTAssertTrue(container.accessibilityChildren()?.contains { $0 as AnyObject === editor } == true,
                      "the mounted editor is not among the container's AX children, "
                      + "so VoiceOver cannot reach the text the writer is editing")

        // alpha 0 is this task's own invention, and the editor is focused and
        // taking keystrokes for the whole ~120 ms it lasts.
        container.isEditorVisible = false
        XCTAssertTrue(container.accessibilityChildren()?.contains { $0 as AnyObject === editor } == true,
                      "the editor leaves the AX tree while the card straightens, "
                      + "so VoiceOver loses the scrap it is focused on")
    }
}
