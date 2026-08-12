import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Maugham

/// Coverage for `Maugham/Canvas/CanvasThumbnails.swift` — the canvas's decode
/// and cache layer for the photographs it will draw.
///
/// **The failure this suite exists to prevent is invisible in a screenshot.** A
/// 6000×4000 photograph drawn on a card looks identical whether it was decoded
/// once at 512 px or decoded at full size on every one of the 120 frames a
/// resize drag produces. So nothing here asserts on how a card *looks*; the
/// three instruments are the returned image's **pixel dimensions**, the cache's
/// **decode counter**, and the fact that a decode never happens on the frame
/// path at all.
///
/// **Why the counter and not a stopwatch.** A wall-clock assertion on a loaded
/// CI machine is a flake, and this project already carries three clock-dependent
/// tests it regrets (`docs/superpowers/notes/2026-07-29-mcp-clock-dependent-tests.md`).
/// `CanvasThumbnails.decodeCount` is exact, deterministic and reads the same on
/// an idle Mac and a thrashing one.
///
/// **The fixture is generated rather than committed**, and the reason is that
/// nothing here measures decode *time*. What the tests need is an image whose
/// full-size dimensions are unmistakably larger than any thumbnail — 2400×1600
/// against a 256 px request — and a generated gradient gives exactly that for a
/// few kilobytes on disk. A committed multi-megabyte photograph would buy only
/// the property no assertion reads (incompressibility), and it would put a
/// binary in the tree that nobody can review.
///
/// **Every negative result here has a control that passes**, and the trap the
/// brief names is real: a cache that evicted *everything* on every insert would
/// satisfy an eviction assertion perfectly. So the eviction test's other half is
/// that a still-resident path does **not** re-decode.
@MainActor
final class CanvasThumbnailTests: XCTestCase {

    private var root: URL!

    /// Files written deliberately OUTSIDE `root` — the containment test's bait.
    /// Tracked because `tearDown` removes the project directory and these, by
    /// construction, are not in it.
    private var outsideRoot: [URL] = []

    /// The photograph's project-relative path — the shape
    /// `ProjectStore.ingestCanvasAsset` returns and
    /// `CanvasItemReference.owned(path:)` holds.
    private static let photo = "canvas_assets/image-20260730-220430.png"

    private static let sourceWidth = 2400
    private static let sourceHeight = 1600

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-thumbnails-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("canvas_assets"), withIntermediateDirectories: true)
        try Self.writeFixture(width: Self.sourceWidth, height: Self.sourceHeight,
                              to: root.appendingPathComponent(Self.photo))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        for url in outsideRoot { try? FileManager.default.removeItem(at: url) }
        outsideRoot = []
    }

    // MARK: - Decoding small

    /// The headline requirement: a large photograph comes back **small**, and it
    /// comes back the same *shape* it went in.
    ///
    /// The two assertions are a pair on purpose. Dimensions alone would be
    /// satisfied by a decode that squashed the image to a square; aspect alone
    /// would be satisfied by a full-size decode. Together they say "this is the
    /// photograph, and it is a thumbnail".
    ///
    /// **This is the assertion the disable experiment turns red.** Remove
    /// `kCGImageSourceThumbnailMaxPixelSize` from the decode options and the
    /// dimensions come back 2400×1600 while the aspect ratio — and every cache
    /// assertion in this file — stays green.
    func test_aLargePhotographResolvesToAThumbnailNoBiggerThanTheRequest() async throws {
        let cache = CanvasThumbnails()
        let image = try await resolve(Self.photo, at: 256, with: cache)

        XCTAssertLessThanOrEqual(image.width, 256,
                                 "decoded \(image.width)x\(image.height) for a 256 px request "
                                 + "— that is a full-size decode wearing a thumbnail's name")
        XCTAssertLessThanOrEqual(image.height, 256)

        // Control for the two assertions above: they are only meaningful because
        // the SOURCE is far larger than the request. If this ever fails, the two
        // above are passing for free.
        XCTAssertGreaterThan(Self.sourceWidth, 256 * 4,
                             "the fixture is not large enough for a thumbnail to be "
                             + "distinguishable from a full-size decode")

        let sourceAspect = Double(Self.sourceWidth) / Double(Self.sourceHeight)
        XCTAssertEqual(Double(image.width) / Double(image.height), sourceAspect, accuracy: 0.02,
                       "the thumbnail is a different shape from the photograph")
    }

    /// A portrait source, because an axis mix-up in the decode options reads as
    /// correct on a landscape image whose long edge happens to be the one the
    /// option names.
    func test_aPortraitPhotographKeepsItsOrientation() async throws {
        let path = "canvas_assets/portrait.png"
        try Self.writeFixture(width: 900, height: 1800, to: root.appendingPathComponent(path))

        let image = try await resolve(path, at: 256, with: CanvasThumbnails())

        XCTAssertLessThanOrEqual(max(image.width, image.height), 256)
        XCTAssertGreaterThan(image.height, image.width, "a portrait photograph came back landscape")
        XCTAssertEqual(Double(image.width) / Double(image.height), 0.5, accuracy: 0.02)
    }

    // MARK: - The frame path never decodes

    /// **A cache miss on the draw pass draws nothing and decodes nothing.**
    ///
    /// `resolved` is what `CanvasRenderer` will call inside the `Canvas` draw
    /// closure, at 60–120 Hz. It returns nil for an image it does not hold and
    /// leaves the work on a queue for something off the frame path to service.
    /// If this ever fails, the first photograph dropped on a canvas stalls the
    /// draw pass for the length of a full-size decode.
    func test_aMissOnTheFramePathDecodesNothingAndLeavesTheWorkQueued() async {
        let cache = CanvasThumbnails()

        for _ in 0..<50 {
            XCTAssertNil(cache.resolved(Self.photo, in: root, fitting: 256),
                         "the draw pass was handed an image it had not been asked to decode yet")
        }
        XCTAssertEqual(cache.decodeCount, 0,
                       "the frame path decoded — that is the whole failure this file exists for")
        XCTAssertEqual(cache.pendingCount, 1,
                       "fifty frames of the same miss must queue one decode, not fifty")

        // The control: the queued work is real, and servicing it off the frame
        // path is what turns the miss into a hit. Without this, the assertions
        // above are satisfied by a cache that simply never works.
        let landed = await cache.servicePending()
        XCTAssertTrue(landed)
        XCTAssertEqual(cache.decodeCount, 1)
        XCTAssertNotNil(cache.resolved(Self.photo, in: root, fitting: 256))
        XCTAssertEqual(cache.pendingCount, 0)
    }

    // MARK: - The same path twice is one decode

    func test_theSamePathAtTheSameSizeIsDecodedOnce() async throws {
        let cache = CanvasThumbnails()

        _ = try await resolve(Self.photo, at: 256, with: cache)
        XCTAssertEqual(cache.decodeCount, 1)

        for _ in 0..<20 { _ = try await resolve(Self.photo, at: 256, with: cache) }
        XCTAssertEqual(cache.decodeCount, 1,
                       "twenty more asks re-decoded a photograph the cache already holds")
    }

    /// **The requirement most likely to be got wrong, as an assertion.**
    ///
    /// Item nodes are resizable (1C-d), so a card's pixel size varies
    /// continuously while the writer drags its corner. A cache keyed on the
    /// card's *exact* current size is a decode on every frame of that drag —
    /// which is the bug, arriving through the mitigation. The chosen shape snaps
    /// a request UP to a bucket and keys on the bucket, so a 520-frame drag
    /// across three buckets costs three decodes.
    ///
    /// The control is the far side of the same number: it must be ≥ 3, or the
    /// bound below is being satisfied by a cache that ignores the request size
    /// and hands a 180 px card a 180 px thumbnail when it has grown to 700.
    func test_aResizeDragCostsOneDecodePerBucketRatherThanOnePerFrame() async throws {
        let cache = CanvasThumbnails()

        for width in stride(from: 180, through: 700, by: 1) {
            _ = try await resolve(Self.photo, at: CGFloat(width), with: cache)
        }

        XCTAssertEqual(cache.decodeCount, 3,
                       "a 521-frame resize drag cost \(cache.decodeCount) decodes; the buckets "
                       + "crossed between 180 px and 700 px are 256, 512 and 1024")
    }

    /// The ladder itself, since the test above reads three and the reason it is
    /// three lives here. **Snapping UP matters**: a request rounded DOWN gives a
    /// card a thumbnail smaller than the pixels it is drawn into, which is a soft
    /// photograph and a silent failure.
    func test_aRequestSnapsUpToABucketAndTheTopBucketClamps() {
        XCTAssertEqual(CanvasThumbnails.bucket(for: 1), 128)
        XCTAssertEqual(CanvasThumbnails.bucket(for: 128), 128)
        XCTAssertEqual(CanvasThumbnails.bucket(for: 129), 256)
        XCTAssertEqual(CanvasThumbnails.bucket(for: 700), 1024)
        XCTAssertEqual(CanvasThumbnails.bucket(for: 99_999), CanvasThumbnails.buckets.last,
                       "an absurd request must clamp — the top bucket is half of the memory "
                       + "bound's arithmetic")
    }

    // MARK: - Eviction, and its control

    /// **The eviction assertion and the assertion that makes it mean something.**
    ///
    /// An always-evicting cache — one that dropped every entry on every insert —
    /// passes the first half of this test perfectly. The second half is what it
    /// fails: a path that is still resident must not be decoded again.
    func test_theCacheEvictsAtItsBoundAndAStillResidentPathIsNotRedecoded() async throws {
        let cache = CanvasThumbnails(entryBudget: 2)
        let paths = try threeFixtures()

        for path in paths { _ = try await resolve(path, at: 256, with: cache) }
        XCTAssertEqual(cache.decodeCount, 3)

        // The oldest is gone: asking for it again is a real decode.
        XCTAssertNil(cache.resolved(paths[0], in: root, fitting: 256))
        _ = try await resolve(paths[0], at: 256, with: cache)
        XCTAssertEqual(cache.decodeCount, 4, "the evicted path was not re-decoded — nothing was "
                       + "evicted, and the bound is not a bound")

        // THE CONTROL. The two most recent are still resident, and asking for
        // them costs nothing. Delete the eviction bound entirely and this still
        // passes; make eviction unconditional and it goes red.
        XCTAssertNotNil(cache.resolved(paths[2], in: root, fitting: 256))
        _ = try await resolve(paths[2], at: 256, with: cache)
        XCTAssertEqual(cache.decodeCount, 4,
                       "a still-resident path was decoded again — an always-evicting cache "
                       + "passes every other assertion in this test")
    }

    /// The other bound. It is expressed in **bytes** because the buckets differ
    /// in size by a factor of 256, so an entry count alone is not a memory bound.
    ///
    /// The budget is measured from a real entry rather than written as a literal,
    /// so this test says the same thing under the disable experiment (where every
    /// entry is 60× larger) as it does normally.
    func test_theResidentBytesStayUnderTheByteBudget() async throws {
        let measure = CanvasThumbnails()
        _ = try await resolve(Self.photo, at: 256, with: measure)
        let oneEntry = measure.residentBytes
        XCTAssertGreaterThan(oneEntry, 0, "a resident thumbnail reported as costing nothing")

        let cache = CanvasThumbnails(byteBudget: oneEntry * 2 + oneEntry / 2)
        for path in try threeFixtures() { _ = try await resolve(path, at: 256, with: cache) }

        XCTAssertLessThanOrEqual(cache.residentBytes, oneEntry * 2 + oneEntry / 2)
        // Control: it did not simply empty itself.
        XCTAssertGreaterThan(cache.residentBytes, 0)
    }

    // MARK: - A file that is not there

    /// A photograph the writer deleted from the Finder. **Nil, not a throw and
    /// not a trap** — a card whose image has gone draws as a card without one.
    ///
    /// The second half is the one with teeth: an un-memoised failure is a decode
    /// attempt on every frame for the rest of the session, which is the per-frame
    /// decode this file exists to prevent arriving through the error path.
    func test_aMissingFileResolvesToNilAndIsNotRetriedOnEveryFrame() async throws {
        let cache = CanvasThumbnails()
        let gone = "canvas_assets/deleted-by-the-writer.png"

        XCTAssertNil(cache.resolved(gone, in: root, fitting: 256))
        _ = await cache.servicePending()
        XCTAssertNil(cache.resolved(gone, in: root, fitting: 256))
        XCTAssertEqual(cache.decodeCount, 1)

        for _ in 0..<50 { XCTAssertNil(cache.resolved(gone, in: root, fitting: 256)) }
        XCTAssertEqual(cache.pendingCount, 0,
                       "a file that is not there was queued for decoding again")
        _ = await cache.servicePending()
        XCTAssertEqual(cache.decodeCount, 1,
                       "the missing file was retried — that is a decode attempt per frame")

        // Control: the memo is per path, not a latch that stops the whole cache.
        let stillWorks = try await resolve(Self.photo, at: 256, with: cache)
        XCTAssertGreaterThan(stillWorks.width, 0)
        XCTAssertEqual(cache.decodeCount, 2)
    }

    /// A file that exists and is not an image — the shape a `.txt` renamed to
    /// `.png` takes, and the one `CGImageSourceCreateWithURL` succeeds on before
    /// the thumbnail fails.
    func test_bytesThatAreNotAnImageResolveToNil() async throws {
        let path = "canvas_assets/not-really.png"
        try "these are not pixels".write(to: root.appendingPathComponent(path),
                                         atomically: true, encoding: .utf8)
        let cache = CanvasThumbnails()

        XCTAssertNil(cache.resolved(path, in: root, fitting: 256))
        _ = await cache.servicePending()
        XCTAssertNil(cache.resolved(path, in: root, fitting: 256))
    }

    // MARK: - The key

    /// The cache key is the **project-relative path** plus the bucket, and the
    /// project the path is relative to. Two projects holding the same relative
    /// path — which is the ordinary case, since `ingestCanvasAsset` names files
    /// by timestamp — must not read each other's pixels.
    func test_twoProjectsWithTheSameRelativePathDoNotCollide() async throws {
        let other = root.appendingPathComponent("other-project")
        try FileManager.default.createDirectory(
            at: other.appendingPathComponent("canvas_assets"), withIntermediateDirectories: true)
        try Self.writeFixture(width: 900, height: 1800,
                              to: other.appendingPathComponent(Self.photo))

        let cache = CanvasThumbnails()
        let here = try await resolve(Self.photo, at: 256, with: cache)
        let there = try await resolve(Self.photo, at: 256, in: other, with: cache)

        XCTAssertEqual(cache.decodeCount, 2, "the second project read the first one's cache entry")
        XCTAssertGreaterThan(here.width, here.height)
        XCTAssertGreaterThan(there.height, there.width,
                             "the portrait photograph in the other project came back landscape "
                             + "— it is the first project's thumbnail")
    }

    // MARK: - The shape memo, and the reshoot that must not be missed

    /// **A photograph replaced in place is re-measured; a rung of the ladder is
    /// not** *(Task 5 re-review, folded in by Task 6)*.
    ///
    /// `aspectsByPath` is first-decode-wins, and it has to be: a thumbnail's own
    /// dimensions differ from its source's by up to a pixel of rounding at each
    /// rung — 256×171 is 1.4971 where 512×341 is 1.5015 — so a memo per bucket
    /// would move a card's height whenever its request crossed a rung, which is
    /// the jitter the memo exists to remove arriving through the back door.
    ///
    /// **But first-decode-wins is stale the moment the FILE changes**, and the
    /// resize (1C-d) is what makes that reachable without waiting for an
    /// eviction: a different request size is a different cache key and therefore
    /// a genuinely fresh decode of the new file, while the memo keeps the old
    /// shape. `GraphicsContext.draw(_:in:)` stretches to the rect it is given, so
    /// a portrait photograph replaced in place would be drawn **squashed into a
    /// landscape box** — the one thing an image on this surface may not do
    /// (§8A.2). A resize drag crosses buckets by design.
    ///
    /// **The MEMO is only half of it, and the other half is the PIXELS** *(review
    /// I1)*. `entries` is keyed by bucket and nothing invalidates it on a file
    /// change — the only removal is LRU — so moving the memo alone leaves every
    /// *other* bucket holding the old photograph, ready to be served into a box
    /// measured from the new shape. That is the same §8A.2 violation running the
    /// other way, and one resize gesture reaches it: drag the card out (fresh
    /// decode at the bigger bucket, memo moves, drawn correctly), drag it back in
    /// (the smaller bucket's stale pixels, in the new shape's box). So the
    /// reshape branch drops the other buckets too, and the fourth assertion here
    /// is what says so.
    ///
    /// The halves are asserted together on purpose. A containment written as
    /// "always record the newest" passes the second and fails the first; one that
    /// moves the memo and leaves the pixels passes the first three and fails the
    /// fourth; and one that simply cleared the cache would pass all four, which
    /// is what the untouched second photograph is the control for.
    func test_aReshootMovesTheShapeMemoAndTheStalePixelsWithIt() async throws {
        let cache = CanvasThumbnails()
        // A second photograph nobody reshoots — the control for the eviction
        // below, and the trap this file's own doc names: a cache that dropped
        // EVERYTHING on every insert would satisfy the fourth assertion perfectly.
        let untouched = try threeFixtures()[1]
        _ = try await resolve(untouched, at: 200, with: cache)

        _ = try await resolve(Self.photo, at: 200, with: cache)
        let landscape = try XCTUnwrap(cache.aspect(Self.photo, in: root),
                                      "nothing was memo'd by the first decode")
        XCTAssertEqual(landscape, 3.0 / 2.0, accuracy: 0.01,
                       "precondition: the 2400×1600 fixture did not memo as 3:2")

        // Cross a rung with the SAME file. A fresh decode at 512 measures the
        // same photograph a fraction differently, and the memo must not move —
        // this is the jitter the memo exists to remove.
        _ = try await resolve(Self.photo, at: 400, with: cache)
        XCTAssertEqual(cache.decodeCount, 3,
                       "control: the second ask did not decode, so nothing had the "
                       + "chance to overwrite the memo and the assertion below is free")
        XCTAssertEqual(try XCTUnwrap(cache.aspect(Self.photo, in: root)), landscape,
                       "a rung of the bucket ladder moved the shape memo, so every "
                       + "pictured card's height jitters as the writer resizes it")

        // Now the writer replaces the picture with a portrait one and the card is
        // resized, which crosses a rung: a genuinely different photograph, decoded
        // fresh, against a memo that says landscape.
        try Self.writeFixture(width: 900, height: 1800,
                              to: root.appendingPathComponent(Self.photo))
        let portrait = try await resolve(Self.photo, at: 900, with: cache)
        XCTAssertEqual(try XCTUnwrap(cache.aspect(Self.photo, in: root)),
                       0.5, accuracy: 0.01,
                       "the shape memo still says the photograph is landscape after "
                       + "the file was replaced with a portrait one, so the card draws "
                       + "it squashed into a box the wrong shape (§8A.2)")

        // **And the pixels at every OTHER bucket went with it.** Ask again at the
        // bucket the card was drawn at BEFORE the drag — which is where the drag
        // back in lands — and what comes back must be the photograph that is on
        // disk now, not the one the memo no longer describes.
        let backAtTheOldBucket = try await resolve(Self.photo, at: 200, with: cache)
        XCTAssertEqual(Double(backAtTheOldBucket.width) / Double(backAtTheOldBucket.height),
                       0.5, accuracy: 0.02,
                       "the smaller bucket still holds the OLD landscape photograph, and "
                       + "the card's box is now measured portrait — so dragging the card "
                       + "back in draws the reshot page squashed, which is the §8A.2 "
                       + "failure the reshape branch was supposed to remove rather than "
                       + "relocate")

        // The control that stops "clear the whole cache" passing the assertion
        // above: a path nobody reshot keeps its pixels and is not re-decoded.
        let decodesBefore = cache.decodeCount
        let untouchedImage = try await resolve(untouched, at: 200, with: cache)
        XCTAssertEqual(cache.decodeCount, decodesBefore,
                       "the reshape evicted a photograph that did not change — an "
                       + "always-evicting cache satisfies every assertion above and is "
                       + "a fresh decode per frame in production")

        // …and the byte accounting followed the eviction. Without the subtraction
        // `residentBytes` only ever grows, so the byte budget over-evicts for the
        // rest of the session — silently, and never visible as a wrong picture.
        XCTAssertEqual(cache.residentBytes,
                       [portrait, backAtTheOldBucket, untouchedImage]
                           .reduce(0) { $0 + $1.height * $1.bytesPerRow },
                       "residentBytes does not match what is actually resident, so the "
                       + "reshape dropped entries without giving their bytes back")
    }

    /// The tolerance itself, as arithmetic rather than as prose: the measured
    /// rounding spread across the ladder is far inside it and a reshoot is far
    /// outside, so the two cases cannot be confused by a number chosen badly.
    func test_theReshootToleranceSeparatesRoundingFromAReshape() {
        let tolerance = CanvasThumbnails.aspectReshapeTolerance
        // The measured spread at 3:2 across two rungs — 256×171 against 512×341.
        let spread = abs((256.0 / 171.0) - (512.0 / 341.0)) / (512.0 / 341.0)
        XCTAssertLessThan(spread, tolerance,
                          "the bucket ladder's own rounding is outside the tolerance, "
                          + "so crossing a rung re-memos and every card's height moves")
        // A 3:2 page reshot in portrait.
        let reshape = abs((3.0 / 2.0) - (2.0 / 3.0)) / (2.0 / 3.0)
        XCTAssertGreaterThan(reshape, tolerance,
                             "a photograph replaced by one of the opposite orientation "
                             + "is inside the tolerance, so the containment sees nothing")

        // **The margin above depends on which rungs are REACHABLE, and that is a
        // coupling nothing else records** *(review M1)*. The ladder's rounding
        // spread stays under 1% for every aspect up to 5.07:1 across
        // 256/512/1024/2048 — but bring 128 back into reach and it breaks at
        // **2.54:1**, which is an ordinary photograph, and a reshoot containment
        // that fires on rounding is the height jitter the memo exists to remove.
        // 128 is out of reach only because the narrowest card a writer can make
        // asks for ~200 px, and `minimumCardWidth` is a shared cross-kind constant
        // a later task could plausibly lower. Neither test above would go red:
        // both use 3:2, which survives even at 128.
        XCTAssertGreaterThanOrEqual(
            CanvasThumbnails.bucket(
                for: CanvasCardMetrics.textWidth(forCardWidth: CanvasInteraction.minimumCardWidth)
                    * CanvasThumbnails.assumedPixelScale),
            256,
            "the narrowest card on the canvas now reaches bucket 128, where the "
            + "ladder's own rounding exceeds aspectReshapeTolerance at 2.54:1 — "
            + "either raise the tolerance with the arithmetic re-done, or keep 128 "
            + "out of reach")
    }

    // MARK: - The path is a claim about THIS project

    /// **An `ownedPath` cannot dangle outside the project** (F8, issue #28).
    /// `Maugham/Canvas/AREA.md` says so; until this test nothing enforced it, and
    /// the path arrives from a sidecar — `.maugham/canvas.json` — which is a file
    /// on disk like any other, so a `../` in it read a photograph the project
    /// does not own and drew it on the writer's canvas.
    ///
    /// The escape is a REAL, decodable PNG, which is what makes the assertions
    /// mean anything: without the gate this resolves to pixels. And the refusal
    /// is checked at `decodeCount` as well as at the image, because a gate placed
    /// after the decode would still hand back nil while having already opened the
    /// file. The counter counts decode ATTEMPTS (see `CanvasThumbnails.decodeCount`)
    /// — a path refused before the decoder is asked is not one.
    func test_anEscapingOwnedPathIsRefusedRatherThanDecoded() async throws {
        let name = "outside-\(UUID().uuidString.prefix(8)).png"
        let escaping = "../\(name)"
        let outside = root.deletingLastPathComponent().appendingPathComponent(name)
        outsideRoot.append(outside)
        try Self.writeFixture(width: 400, height: 300, to: outside)

        let cache = CanvasThumbnails()
        XCTAssertNil(cache.resolved(escaping, in: root, fitting: 256))
        _ = await cache.servicePending()

        XCTAssertNil(cache.resolved(escaping, in: root, fitting: 256),
                     "the escape resolved to pixels — the containment gate is not "
                     + "being consulted, and a canvas can draw a file outside its project")
        XCTAssertEqual(cache.decodeCount, 0,
                       "the refusal has to happen BEFORE the decoder is handed the URL")

        // Cached as a FAILURE, like an undecodable file: refused once, never
        // re-queued. Without this a card naming an escaping path asks again on
        // every frame that draws it, which is the per-frame work this whole file
        // exists to prevent arriving through the refusal path.
        XCTAssertEqual(cache.pendingCount, 0,
                       "the refused path went back on the queue")

        // The control: the same cache, the same call, an honest path — so the
        // assertions above are about containment and not about a cache that
        // stopped decoding.
        let image = try await resolve(Self.photo, at: 256, with: cache)
        XCTAssertLessThanOrEqual(image.width, 256)
        XCTAssertEqual(cache.decodeCount, 1)
    }

    // MARK: - Helpers

    /// The full loop a card goes through: miss on the frame path, service off
    /// it, hit on the next frame. Every test drives the real two-verb API rather
    /// than a decode entry point of its own.
    @discardableResult
    private func resolve(_ path: String, at size: CGFloat,
                         in projectRoot: URL? = nil,
                         with cache: CanvasThumbnails,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> CGImage {
        let projectRoot = projectRoot ?? root!
        if let hit = cache.resolved(path, in: projectRoot, fitting: size) { return hit }
        _ = await cache.servicePending()
        return try XCTUnwrap(cache.resolved(path, in: projectRoot, fitting: size),
                             "\(path) did not resolve at \(size) px", file: file, line: line)
    }

    private func threeFixtures() throws -> [String] {
        let paths = (0..<3).map { "canvas_assets/photo-\($0).png" }
        for path in paths where !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(path).path) {
            try Self.writeFixture(width: Self.sourceWidth, height: Self.sourceHeight,
                                  to: root.appendingPathComponent(path))
        }
        return paths
    }

    /// A gradient, not a flat fill: nothing in this suite depends on the bitmap
    /// being uniform, and a fixture whose every pixel is identical would make a
    /// future test about pixels quietly meaningless.
    private static func writeFixture(width: Int, height: Int, to url: URL) throws {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context else {
            throw NSError(domain: "CanvasThumbnailTests", code: 1)
        }
        let bands = 32
        for band in 0..<bands {
            let t = CGFloat(band) / CGFloat(bands - 1)
            context.setFillColor(CGColor(red: t, green: 1 - t, blue: 0.5, alpha: 1))
            let bandWidth = ceil(CGFloat(width) / CGFloat(bands))
            context.fill(CGRect(x: CGFloat(band) * bandWidth, y: 0,
                                width: bandWidth, height: CGFloat(height)))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "CanvasThumbnailTests", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "CanvasThumbnailTests", code: 3)
        }
    }
}
