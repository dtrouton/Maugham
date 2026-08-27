import XCTest
import AppKit
@testable import Maugham

final class ScrapLayoutTests: XCTestCase {

    private let sample = "The falls at night: sodium light on the spray, and "
        + "nobody there but the man selling ponchos. October says the doctor "
        + "was kind about it, which is not the same as being right."

    private func layout(width: CGFloat = 240) -> ScrapLayout {
        ScrapLayout(text: sample, width: width,
                    font: NSFont(name: "Iowan Old Style", size: 13)
                        ?? .systemFont(ofSize: 13))
    }

    /// Put `editor` in a real window. `NSTextView` needs one before `insertText`
    /// does anything, and the spike's harness failures were all missing windows.
    @discardableResult
    private func host(_ editor: NSTextView) -> NSWindow {
        let content = NSView(frame: editor.frame)
        content.addSubview(editor)
        let window = TestWindow.make(SilentTestWindow.self, contentRect: editor.frame,
                                     contentView: content, present: .unshown)
        editor.layoutSubtreeIfNeeded()
        return window
    }

    /// **A mounted editor outlives the `ScrapLayout` that built it**, and that is
    /// the fact `CanvasView.rebuildLayouts` rests on.
    ///
    /// `applySnapshot` replaces `layouts[id]` while the writer is still in the
    /// scrap, which releases that scrap's `ScrapLayout` synchronously — a whole
    /// SwiftUI update pass before `ScrapEditorHost.updateNSView` rebinds. The
    /// question is what the still-mounted text view is left holding through that
    /// window, and the plausible-sounding answer is "a container whose layout
    /// manager has gone": `ScrapLayout` privately owns the `NSTextStorage`, the
    /// `NSTextContentStorage` and the `NSTextLayoutManager`, and
    /// `NSTextContainer.textLayoutManager` is a weak back-link.
    ///
    /// Measured here instead of assumed. An `NSTextView` built through
    /// `NSTextView(frame:textContainer:)` owns its TextKit 2 stack itself: with
    /// the `ScrapLayout` released and nothing but the view alive, every object in
    /// the stack is still there and the view still lays out, draws and reads.
    ///
    /// This is a fact about AppKit rather than about our code, so it is asserted
    /// where it can be asserted in isolation — no SwiftUI, no undo, no timing.
    /// If a future macOS changes it, THIS is the test that says so, and
    /// `rebuildLayouts`'s doc is what has to change with it.
    func test_theMountedEditorOutlivesTheScrapLayoutThatBuiltIt() {
        var editor: NSTextView?
        weak var weakLayout: ScrapLayout?
        weak var weakLayoutManager: NSTextLayoutManager?
        weak var weakContentStorage: NSTextContentStorage?
        weak var weakStorage: NSTextStorage?

        autoreleasepool {
            let l = layout()
            weakLayout = l
            let tv = l.makeEditor(frame: CGRect(x: 0, y: 0, width: 240, height: 200))
            editor = tv
            weakLayoutManager = tv.textContainer?.textLayoutManager
            weakContentStorage = tv.textContentStorage
            weakStorage = tv.textStorage
            XCTAssertNotNil(weakLayoutManager,
                            "precondition: the mounted view is on the layout's own "
                            + "TextKit 2 stack, which is the whole of ScrapLayout's "
                            + "reason to exist")
            XCTAssertNotNil(weakStorage, "precondition: and on its storage")
        }
        // The `ScrapLayout` is gone. Only the text view is left holding anything.
        XCTAssertNil(weakLayout,
                     "precondition, and the control for every assertion below: the "
                     + "ScrapLayout really was deallocated. Without this they would "
                     + "all be true of an object that is simply still alive, and the "
                     + "weak references would be measuring nothing")

        XCTAssertNotNil(weakLayoutManager,
                        "the layout manager went with the ScrapLayout, so replacing a "
                        + "mounted scrap's layout leaves the writer's live editor "
                        + "pointing at a deallocated stack — CanvasView.applySnapshot "
                        + "does exactly that on every ⌘Z inside a scrap")
        XCTAssertNotNil(weakContentStorage, "the content storage went with it too")
        XCTAssertNotNil(weakStorage,
                        "the NSTextStorage the writer is typing into went with it")
        XCTAssertNotNil(editor?.textContainer?.textLayoutManager,
                        "the container's back-link to the layout manager is nil, so "
                        + "the next layout pass on the mounted view has nothing to "
                        + "lay out with")
        XCTAssertEqual(editor?.string, sample,
                       "the mounted view can no longer read its own text")

        // And it still works, rather than merely still existing.
        editor?.layoutSubtreeIfNeeded()
        editor?.needsDisplay = true
        editor?.displayIfNeeded()
        XCTAssertGreaterThan(editor?.textContainer?.textLayoutManager?
            .usageBoundsForTextContainer.height ?? 0, 0,
                             "the mounted view lays out to nothing once its ScrapLayout "
                             + "is gone")
    }

    /// THE §7A.2 PIN. If drawn and edited layout differ by even a fraction, text
    /// visibly jumps every time the writer clicks in and again when they click
    /// out. Spike verified this holds; this test keeps it holding.
    func test_layoutIsIdenticalAcrossFocusAndBlur() {
        let l = layout()
        let beforeFocus = l.lineGeometrySignature
        XCTAssertFalse(beforeFocus.isEmpty)

        let editor = l.makeEditor(frame: CGRect(x: 0, y: 0, width: 240,
                                                height: l.measuredHeight))
        host(editor)

        XCTAssertEqual(l.lineGeometrySignature, beforeFocus,
                       "mounting the editor changed the layout — text will jump on focus")

        // `removeFromSuperview()` is NOT a detach — the container goes on pointing
        // at the view and the layout manager is untouched, so on its own the
        // assertion below would re-read a signature nothing could have moved.
        // Blur is what Task 9 does: release the editor off the shared container.
        editor.removeFromSuperview()
        l.releaseEditor()
        XCTAssertNil(editor.textContainer,
                     "releaseEditor left the view attached — the blur half is a no-op")
        XCTAssertEqual(l.lineGeometrySignature, beforeFocus,
                       "unmounting the editor changed the layout — text will jump on blur")
    }

    /// The pin above mounts at exactly the container's width, which is the one
    /// width at which it cannot fail for the reason it names: a container that
    /// tracked its text view would recompute the width to the value it already
    /// has, and nothing would reflow. This one mounts WIDER than the layout, which
    /// is the real shape of the bug — `CanvasCardMetrics` insets the text box 10pt
    /// per side from the card, so a Task 9 that mounts the editor at *card* width
    /// mounts it wider than the layout it shares. With `widthTracksTextView` left
    /// at its default the scrap re-wraps the instant the editor appears, and stays
    /// re-wrapped after it goes: the writer sees the text jump on the way in and
    /// never sees it jump back.
    func test_layoutSurvivesAnEditorMountedWiderThanTheLayout() {
        let l = layout(width: 240)
        let beforeFocus = l.lineGeometrySignature
        XCTAssertFalse(beforeFocus.isEmpty)

        let editor = l.makeEditor(frame: CGRect(x: 0, y: 0, width: 300,
                                                height: l.measuredHeight))
        host(editor)

        XCTAssertEqual(l.lineGeometrySignature, beforeFocus,
                       "the editor's own width reflowed the shared layout on focus")

        editor.removeFromSuperview()
        l.releaseEditor()
        XCTAssertEqual(l.lineGeometrySignature, beforeFocus,
                       "the layout stayed reflowed after blur")
    }

    /// The trap the spike found: with `attributedString` wiring the scrap
    /// renders perfectly and silently swallows every keystroke.
    func test_mountedEditorActuallyEditsTheSharedStack() {
        let l = layout()
        let editor = l.makeEditor(frame: CGRect(x: 0, y: 0, width: 240,
                                                height: l.measuredHeight))
        host(editor)

        XCTAssertEqual(editor.string.count, sample.count,
                       "the editor cannot see the text — this is the "
                       + "attributedString-instead-of-textStorage wiring bug")

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(l.text.hasPrefix("Z"),
                      "typing did not reach the shared stack")
    }

    func test_containerDefaultsAreOverridden() {
        let l = layout()
        // lineFragmentPadding defaults to 5 and would shift drawn against edited.
        XCTAssertEqual(l.debugLineFragmentPadding, 0)
        XCTAssertFalse(l.debugWidthTracksTextView)
    }

    func test_mountedEditorHasZeroInsetAndLeavesUndoToTheCanvas() {
        let l = layout()
        let editor = l.makeEditor(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        XCTAssertEqual(editor.textContainerInset, .zero,
                       "a non-zero inset shifts edited text against drawn text")
        XCTAssertFalse(editor.allowsUndo,
                       "with allowsUndo the text view registers its OWN step on the "
                       + "shared canvas manager and the canvas snapshot registers a "
                       + "second one covering the same change — one keystroke, two "
                       + "steps, and the text view's step targets an NSTextStorage "
                       + "the next rebuildLayouts() orphans (Task 15)")
    }

    func test_measuredHeightIsPositiveAndGrowsAsWidthShrinks() {
        let wide = layout(width: 400).measuredHeight
        let narrow = layout(width: 200).measuredHeight
        XCTAssertGreaterThan(wide, 0)
        XCTAssertGreaterThan(narrow, wide, "narrower scrap must wrap to more lines")
    }

    func test_setWidth_reflowsAndChangesHeight() {
        let l = layout(width: 400)
        let before = l.measuredHeight
        l.setWidth(200)
        XCTAssertGreaterThan(l.measuredHeight, before)
    }

    /// Sample the MIDDLE of each line, derived from the layout itself. An
    /// earlier draft walked down in a literal 17 pt stride, which only samples
    /// distinct lines while Iowan Old Style 13's line height stays at or above
    /// 17 pt — a theme change or an OS font update would make the test start
    /// sampling the same line twice and fail for a reason that is not a bug.
    func test_characterIndexAtPoint_isMonotonicDownTheLines() {
        let l = layout()
        let lineCount = l.lineGeometrySignature.count
        XCTAssertGreaterThan(lineCount, 2, "the fixture must wrap to several lines")
        let lineHeight = l.measuredHeight / CGFloat(lineCount)
        let indices = (0..<lineCount).map {
            l.characterIndex(at: CGPoint(x: 90, y: (CGFloat($0) + 0.5) * lineHeight))
        }
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(Set(indices).count, indices.count)
    }

    func test_drawIntoContext_putsInkOnThePage() {
        let l = layout()
        let w = 480, h = Int(ceil(l.measuredHeight)) * 2
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: l.measuredHeight)
        ctx.scaleBy(x: 1, y: -1)
        // The glyph colour is `labelColor`, which is WHITE under a dark
        // appearance — on this white bitmap that measures as zero ink and fails
        // for a reason that is not a bug. Pin the drawing appearance so the test
        // asserts the same thing on a dark-mode Mac as on a light-mode CI box.
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            l.draw(into: ctx, at: .zero)
        }

        let bytes = UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self,
                                                                   capacity: ctx.bytesPerRow * h),
                                        count: ctx.bytesPerRow * h)
        let ink = stride(from: 1, to: bytes.count, by: 4).filter { bytes[$0] < 200 }.count
        XCTAssertGreaterThan(ink, 500, "nothing was drawn")
    }

    // MARK: - The spike's bitmap half

    /// THE OTHER HALF OF THE §7A.2 PIN. The spike
    /// (`docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md`, Q3) says to
    /// pin "fragment geometry equality across mount and unmount, **plus a bitmap
    /// diff**". Geometry equality says the shared layout did not move; only pixels
    /// say the two consumers PAINT it the same. The gap between those two claims is
    /// `textContainerInset`, which shifts the mounted editor's glyphs without
    /// touching the layout at all — every geometry assertion in this file stays
    /// green while the scrap visibly jumps on focus.
    ///
    /// Method is the spike's: draw the layout into a bitmap the way `Canvas` will,
    /// render the mounted `NSTextView` into a bitmap of identical geometry, diff.
    /// Tolerance is the spike's measurement — 0.0000–0.0069% differing pixels at
    /// max channel delta 1, ink bounding boxes identical (`dx 0, dy 0`).
    ///
    /// This test renders a view into a hand-built flipped context, which the spike
    /// found can corrupt subsequent hit testing. It hit-tests nothing afterwards,
    /// and its `ScrapLayout` is its own. Keep it that way.
    func test_drawnPixelsMatchTheMountedEditorsPixels() {
        let l = layout()
        let scale = 2, widthPt = 300, heightPt = Int(ceil(l.measuredHeight))
        let w = widthPt * scale, h = heightPt * scale

        let drawn = whitePage(w: w, h: h)
        applyCameraCTM(drawn, scale: scale, heightInPoints: heightPt)
        Self.aqua.performAsCurrentDrawingAppearance { l.draw(into: drawn, at: .zero) }

        let editor = l.makeEditor(frame: CGRect(x: 0, y: 0, width: 240,
                                                height: CGFloat(heightPt)))
        host(editor).appearance = Self.aqua

        let edited = whitePage(w: w, h: h)
        applyCameraCTM(edited, scale: scale, heightInPoints: heightPt)
        let editedContext = NSGraphicsContext(cgContext: edited, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = editedContext
        Self.aqua.performAsCurrentDrawingAppearance {
            editor.displayIgnoringOpacity(editor.bounds, in: editedContext)
        }
        NSGraphicsContext.restoreGraphicsState()

        let a = pixels(drawn, height: h), b = pixels(edited, height: h)
        // Without this the whole comparison passes vacuously on two blank pages.
        XCTAssertGreaterThan(stride(from: 1, to: a.count, by: 4).filter { a[$0] < 200 }.count,
                             500, "the drawn page is blank — the diff below proves nothing")

        var differing = 0, maxDelta = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            var delta = 0
            for channel in 1...3 { delta = max(delta, abs(Int(a[i + channel]) - Int(b[i + channel]))) }
            if delta > 0 { differing += 1 }
            maxDelta = max(maxDelta, delta)
        }
        let differingFraction = Double(differing) / Double(w * h)

        XCTAssertLessThanOrEqual(maxDelta, 1,
                                 "a drawn pixel and its edited twin differ by more than "
                                 + "colour-space rounding — the mounted editor is not "
                                 + "painting what the canvas painted")
        XCTAssertLessThan(differingFraction, 0.0005,
                          String(format: "%.4f%% of pixels differ (spike measured at most "
                                 + "0.0069%%) — drawn and edited text do not line up, so "
                                 + "the scrap will jump when the writer clicks in",
                                 differingFraction * 100))
    }

    // MARK: - Bitmap helpers

    private static let aqua = NSAppearance(named: .aqua)!

    private func whitePage(w: Int, h: Int) -> CGContext {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    /// What a `Canvas` hands `draw(into:at:)` and what a flipped `NSView` draws
    /// into: top-left origin, y downwards, at backing scale.
    private func applyCameraCTM(_ ctx: CGContext, scale: Int, heightInPoints: Int) {
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: 0, y: CGFloat(heightInPoints))
        ctx.scaleBy(x: 1, y: -1)
    }

    private func pixels(_ ctx: CGContext, height: Int) -> [UInt8] {
        let count = ctx.bytesPerRow * height
        return Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self,
                                                                    capacity: count),
                                         count: count))
    }
}
