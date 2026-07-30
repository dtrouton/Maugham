import XCTest
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Maugham

/// The canvas's rasterisation harness — **one copy, shared by every fixture that
/// renders `CanvasRenderer.draw` and reads pixels back.**
///
/// It lives here because it was three copies. `CanvasRegionRenderTests` and
/// `CanvasLineRenderTests` carried byte-identical `Page` structs and byte-identical
/// 35-line renderers, and the drift had already started on the first duplication:
/// the second copy silently dropped the buffer-row note below, which is the one
/// comment standing between a reader and an upside-down page.
///
/// **The BUFFER is shared; the READERS stay with their callers.** Ink and colour
/// are two vocabularies — "is this pixel darker than paper by 100 levels, and
/// which rows carry glyphs" is a different question from "what colour is this and
/// how many pixels changed" — and the two even want opposite answers off the end
/// of the page: a colour reader returns a sentinel no pixel can equal, an ink
/// reader returns the paper so an off-page read is never mistaken for ink. So the
/// bitmap, its geometry and the one way a scene becomes pixels live here, the
/// colour vocabulary lives here with the two suites that reason in it, and
/// `CanvasRendererTests` carries its ink vocabulary as an extension on this type.
struct CanvasPage {
    let bytes: [UInt8]
    let bytesPerRow: Int
    let width: Int
    let height: Int
    /// What an unpainted pixel on this page reads — the green byte of the
    /// backing, measured off the context **before anything is drawn over it**
    /// rather than assumed.
    ///
    /// A buffer fact rather than an ink one, which is why it is stored here and
    /// not in the ink extension: it can only be taken at the moment the page is
    /// filled, and by then the reader is long gone. Reading it back from pixel
    /// (0, 0) afterwards would work only for fixtures that happen to paint
    /// nothing in the corner.
    let paper: UInt8

}

// MARK: - The COLOUR vocabulary
//
// Shared by `CanvasRegionRenderTests` and `CanvasLineRenderTests`, which both
// reason in "what colour is this pixel" and "how many pixels changed between two
// renders". It is an extension rather than part of the type above so the seam
// between the buffer and a vocabulary is visible in the source — the ink
// vocabulary in `CanvasRendererTests` is the same shape on the other side of it.

extension CanvasPage {

    /// R, G, B at `point`, in 0–1.
    ///
    /// The context is `premultipliedFirst` with the default byte order, so the
    /// bytes run **A, R, G, B** — measured in `CanvasRendererTests` by filling a
    /// known colour and reading the four bytes back, not inferred. A point
    /// outside the page returns a sentinel that no rendered pixel can equal, so
    /// an off-page read can never pass an equality assertion by accident.
    func color(at point: CGPoint) -> SIMD3<Double> {
        let x = Int(point.x), y = Int(point.y)
        guard (0..<width).contains(x), (0..<height).contains(y) else {
            return SIMD3<Double>(-1, -1, -1)
        }
        let o = y * bytesPerRow + x * 4
        return SIMD3<Double>(Double(bytes[o + 1]) / 255,
                             Double(bytes[o + 2]) / 255,
                             Double(bytes[o + 3]) / 255)
    }

    /// The largest per-channel difference at `point`, in 0–1.
    func distance(to other: CanvasPage, at point: CGPoint) -> Double {
        let d = color(at: point) - other.color(at: point)
        return max(abs(d.x), max(abs(d.y), abs(d.z)))
    }

    /// The largest per-channel difference between two points on THIS page.
    func difference(between p: CGPoint, and q: CGPoint) -> Double {
        let d = color(at: p) - color(at: q)
        return max(abs(d.x), max(abs(d.y), abs(d.z)))
    }

    /// How many pixels inside `rect` differ from the other page's.
    ///
    /// The unit the drawn-output fixtures are built on: render two scenes that
    /// differ in exactly one model fact and every changed pixel is that fact,
    /// drawn. Exact — no colour threshold to tune, and a control rect asserting
    /// *zero* is a real assertion rather than a rounding allowance.
    func differingPixels(from other: CanvasPage, in rect: CGRect) -> Int {
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                // + 0.5 lands in the middle of the pixel; `color(at:)` truncates,
                // so this addresses pixel (x, y) exactly.
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if color(at: p) != other.color(at: p) { count += 1 }
            }
        }
        return count
    }
}

/// Draw a whole scene through the real `CanvasRenderer.draw` and read the pixels.
///
/// **The single test-side call site of `draw`'s full signature**, which is the
/// other half of this file's purpose: a parameter added to `draw` lands in one
/// place here rather than in every fixture that happens to render a scene.
///
/// A free function rather than a method on a shared base class, so both suites
/// keep calling it as `render(scene:size:…)` exactly as they did when each owned
/// a private copy.
@MainActor
func render(scene: CanvasScene,
            size: CGSize,
            selection: CanvasSelection? = nil,
            scraps: [CanvasNodeID: String] = [:],
            items: CanvasItemPresentation = .empty,
            sweep: CGRect? = nil,
            pendingLine: (from: CGPoint, to: CGPoint)? = nil,
            scheme: ColorScheme = .light,
            backing: NSColor? = nil) throws -> CanvasPage {
    try renderCanvasPage(size: size, scheme: scheme, backing: backing) { cx in
        CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: size,
                            layouts: [:], scraps: scraps, items: items, selection: selection,
                            visibleEditorNodeID: nil,
                            straighten: CanvasFocusStraighten(),
                            pendingRegionDraw: sweep,
                            pendingLine: pendingLine, into: &cx)
    }
}

/// Write a PNG of a known size — the fixture an item node's thumbnail is decoded
/// from.
///
/// **Generated rather than committed**, on `CanvasThumbnailTests`' stated terms:
/// nothing here measures decode *time*, so what a fixture has to be is a real
/// image file of a known SHAPE, and a gradient gives that for a few kilobytes
/// without putting a binary in the tree that nobody can review.
///
/// The gradient runs on both axes deliberately: a flat fill would let a picture
/// drawn at the wrong rect, or not drawn at all, be indistinguishable from the
/// card's own paper in a changed-pixel count.
func writeCanvasFixtureImage(width: Int, height: Int, to url: URL) throws {
    let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
    for y in 0..<height {
        for x in 0..<width {
            ctx.setFillColor(red: Double(x) / Double(width),
                             green: Double(y) / Double(height),
                             blue: 0.35, alpha: 1)
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    let image = try XCTUnwrap(ctx.makeImage())
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let destination = try XCTUnwrap(
        CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination), "could not write the fixture image")
}

/// Resolve an item presentation the way the view does — ask, miss, service, ask
/// again.
///
/// **Through the real two-verb split rather than around it.** `resolved` never
/// decodes, so the first resolve always misses a photograph; a helper that
/// handed back a picture without going through `servicePending()` would let a
/// fixture pass over a view that never schedules the servicing at all.
@MainActor
func resolvedItemPresentation(scene: CanvasScene,
                              index: CanvasItemIndex,
                              projectRoot: URL) async -> CanvasItemPresentation {
    let cache = CanvasThumbnails()
    _ = CanvasItemPresentation.resolve(scene: scene, index: index,
                                       thumbnails: cache, projectRoot: projectRoot)
    _ = await cache.servicePending()
    return CanvasItemPresentation.resolve(scene: scene, index: index,
                                          thumbnails: cache, projectRoot: projectRoot)
}

/// Render an arbitrary `Canvas` draw closure at scale 1 and read its pixels.
///
/// The colour scheme is PINNED rather than inherited: this test process runs
/// under DarkAqua, so an unpinned dynamic `NSColor` resolves dark inside a light
/// render — which is how a white-bitmap ink test came to measure zero ink and
/// pass everywhere except a dark-mode Mac. The BACKING is resolved under the
/// matching appearance for the same reason, and defaults to the card paper so the
/// light fixtures sit on exactly the page `CanvasRendererTests` measures against.
@MainActor
func renderCanvasPage(size: CGSize,
                      scheme: ColorScheme,
                      backing: NSColor?,
                      _ draw: @escaping (inout GraphicsContext) -> Void) throws -> CanvasPage {
    let renderer = ImageRenderer(
        content: Canvas { cx, _ in draw(&cx) }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme))
    renderer.scale = 1
    let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")

    let w = image.width, h = image.height
    let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
    var backingColor: CGColor?
    NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        .performAsCurrentDrawingAppearance {
            backingColor = (backing ?? CanvasRenderer.cardPaper)
                .usingColorSpace(.sRGB)?.cgColor
        }
    ctx.setFillColor(try XCTUnwrap(backingColor, "could not resolve the page backing"))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // Read the backing back BEFORE anything is drawn over it, so `paper` is the
    // value an unpainted pixel actually holds. Green, index 2 — see `color(at:)`.
    let paper = ctx.data!.bindMemory(to: UInt8.self, capacity: 4)[2]
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    let count = ctx.bytesPerRow * h
    // Row 0 of a CGBitmapContext's buffer is the TOP row of the drawn image, so
    // buffer row == point y — verified in `CanvasRendererTests` against a
    // GraphicsContext fill at y = 0.
    let bytes = Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self,
                                                                     capacity: count),
                                          count: count))
    return CanvasPage(bytes: bytes, bytesPerRow: ctx.bytesPerRow,
                      width: w, height: h, paper: paper)
}
