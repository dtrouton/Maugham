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
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSView(frame: editor.frame)
        window.contentView?.addSubview(editor)
        editor.layoutSubtreeIfNeeded()
        return window
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

        editor.removeFromSuperview()
        XCTAssertEqual(l.lineGeometrySignature, beforeFocus,
                       "unmounting the editor changed the layout — text will jump on blur")
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
}
