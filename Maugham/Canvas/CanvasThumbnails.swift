import CoreGraphics
import Foundation
import ImageIO
import MaughamCore

/// The canvas's thumbnails: **decode small, cache by path, never on the frame
/// path.**
///
/// The planning canvas is the first surface in Maugham with an *unbounded* image
/// count (spec §8A.1). Everywhere else an image appears — a palette card's
/// swatch, a research note's inline picture — the count is bounded by a list the
/// writer scrolls. Here it is bounded by nothing, drawn inside a `Canvas` closure
/// that runs at 60–120 Hz, and the cards it draws on are **resizable** (1C-d),
/// so a card's pixel size varies continuously for the length of a drag.
///
/// The failure that combination invites is a 6000×4000 photograph decoding at
/// full size on the draw pass, once per frame, per card — and it is invisible in
/// a screenshot, which is why this file's own tests assert on pixel dimensions
/// and on `decodeCount` rather than on how anything looks.
///
/// ## Two verbs, and the split between them is the whole design
///
/// - `resolved(_:in:fitting:)` is the **frame path**. It is a dictionary lookup.
///   It never decodes, never touches the filesystem, and returns nil for an image
///   it does not hold — a card whose thumbnail has not arrived yet draws without
///   one. A miss is *recorded*, not serviced.
/// - `servicePending()` is **off the frame path**. It drains what the draw pass
///   missed, decoding on a background task, and reports whether anything landed
///   so the caller knows to redraw.
///
/// A single verb that decoded on a miss would compile, read correctly, pass a
/// visual check, and put a full-size JPEG decode inside the draw closure the
/// first time a writer dropped a photograph on the canvas.
///
/// ## Bucketed sizes, and why the other shape was not chosen
///
/// A request is snapped **up** to the next entry in `buckets`, and the bucket —
/// not the request — is part of the cache key. A 521-frame resize drag from
/// 180 px to 700 px therefore costs **three** decodes, one per bucket crossed,
/// rather than 521.
///
/// The alternative considered was **one generous decode that the draw pass
/// scales down**, keyed on the path alone: simpler, one entry per image, and
/// scaling an already-small bitmap costs nothing. It was rejected on the number
/// it would have to pick. `CanvasCamera.zoomRange` is `0.1...6.0`, so the pixels
/// a card occupies span nearly two orders of magnitude, and "generous" has to
/// mean generous at the top of that range on a Retina display — several
/// megapixels — held for *every* cached image, including the ones drawn 40 pt
/// wide at 0.1×. On the one surface in the app whose image count nothing bounds,
/// that multiplies the memory bound's worst case by the entry count. Sizing it
/// for the *common* case instead does not rescue it either: scaling a small
/// bitmap **up** is a visibly soft photograph, and it fails silently — it reads
/// as a bad photograph rather than as a bug.
///
/// What the bucket ladder costs in exchange is that one image can be resident at
/// two sizes while a drag crosses a boundary. That is bounded by the ladder and
/// paid back by the bound below.
///
/// ## The key is a PATH (tripwire 22)
///
/// Never an item id. An *owned* asset has no item id at all
/// (`CanvasItemReference.owned(path:)` is a path and nothing else), and a
/// *referenced* research image's id is stable across a change to the file while
/// its pixels are not — so an id key serves a stale thumbnail after the writer
/// replaces the picture.
///
/// The path is **project-relative**, which is the string `ingestCanvasAsset`
/// returns and the model holds; the project URL is passed alongside and resolved
/// here. An API taking an absolute path would make every caller build one, which
/// is two spellings of one image's identity. The project root *is* part of the
/// in-memory key — two projects name their assets by timestamp and collide
/// constantly on the relative path alone — and that is an implementation detail
/// of one process's dictionary, not a stored or compared value.
@MainActor
public final class CanvasThumbnails {

    // MARK: - The bounds

    /// **These two are deliberately NOT in `CanvasMaterial`.** That file is the
    /// numbers the canvas's *look* is calibrated with, tuned by eye by the writer
    /// against a running app; every one of them changes a pixel. These change no
    /// pixel at all — they are a memory ceiling and an unbounded-growth guard,
    /// and a writer raising the grain amplitude has no business meeting them.
    ///
    /// The byte budget is the real bound: the ladder's entries differ in cost by
    /// a factor of 256, so an entry count alone is not a memory bound. 64 MB is
    /// four entries at the top bucket and roughly sixty at the one a card is
    /// ordinarily drawn at.
    ///
    /// **`nonisolated` is load-bearing, and deleting it is silent.** Both are
    /// spelled as the *default arguments* of `init`, and a default argument
    /// expression is evaluated in a nonisolated context regardless of the
    /// enclosing `@MainActor` — so as plain `static let`s on this class they are
    /// main-actor-isolated values read from a nonisolated one. That is a warning
    /// under the 5.10 language mode this project builds at and **an error under
    /// Swift 6**, which is the shape that stays quiet until the day the language
    /// mode moves. Neither constant touches actor-isolated state; they are `Int`s.
    nonisolated public static let defaultByteBudget = 64 << 20

    /// The count bound exists because a *failure* costs no bytes. A canvas whose
    /// photographs have all been deleted from the Finder would otherwise grow a
    /// memo per path forever under a byte budget alone.
    ///
    /// `nonisolated` for the reason above — it is `init`'s other default argument.
    nonisolated public static let defaultEntryBudget = 256

    /// Points → pixels, for a caller that has no way to ask the window.
    ///
    /// **This is not the raster scale spike requirement 3 forbids deriving**, and
    /// the distinction is the reason it is allowed to exist at all: that rule is
    /// about the scale a card's GLYPHS are drawn at, where a hand-derived number
    /// bakes in AppKit's frame rounding and shifts text by a subpixel. This number
    /// sizes a *decode request* — the drawn rect stays in points and the context's
    /// own scale rasterises it — so being wrong here costs sharpness or memory and
    /// can never move a pixel of drawn text.
    ///
    /// 2 rather than a reading, because a reading is not available: the cache is
    /// asked from a measurement pass that has no window, and `backingScaleFactor`
    /// is grep-banned across this directory. Over-asking on a 1× display costs one
    /// step of the ladder and nothing else; under-asking on a 2× display is a
    /// visibly soft photograph, which is the failure that fails *silently*.
    ///
    /// **The camera's zoom is deliberately not part of a request, and that is a
    /// ruling rather than an omission.** An item card's HEIGHT is derived from its
    /// picture's aspect ratio (`CanvasCardMetrics.itemCardHeight`), and a
    /// thumbnail's aspect ratio differs from the source's by up to a pixel of
    /// rounding at each rung — so a request that followed the zoom would re-measure
    /// every pictured card as the writer zoomed, jittering their heights and
    /// rebuilding the accessibility tree on the zoom path. A photograph inspected
    /// at 6× is therefore softer than the display could show, which is the smaller
    /// cost and is bounded by the card resize (1C-d): a card made bigger asks for
    /// more pixels, because the request follows the card's WIDTH.
    nonisolated public static let assumedPixelScale: CGFloat = 2

    /// **How far a fresh decode's shape may differ from the memo before the memo
    /// is a lie about a different photograph.**
    ///
    /// The memo below is first-decode-wins, which is right for the case it was
    /// written for and wrong for one case: the writer replaces the file at a path
    /// with a picture of a different shape. **The writer does not have to wait for
    /// an eviction for that to bite — a bucket change alone reaches it**, because
    /// a different request size is a different cache key and therefore a genuinely
    /// fresh decode of the new file. `GraphicsContext.draw(_:in:)` stretches to
    /// the rect it is given, so a portrait photograph replaced in place would be
    /// drawn squashed into a landscape box: the one thing an image on this surface
    /// may not do (spec §8A.2). An item node's resize (1C-d) is what made crossing
    /// a bucket an ordinary gesture rather than a rarity.
    ///
    /// **Crossing that threshold invalidates the pixels too, and it has to** — see
    /// `dropOtherBuckets(of:)`. The memo alone was half a fix: `entries` is keyed
    /// by bucket and nothing else invalidates it on a file change, so moving the
    /// memo and keeping the pixels relocates the squash into the *other* buckets
    /// instead of removing it, reachable in one drag out and back.
    ///
    /// **1%, and the two cases it separates are fifty times apart.** The measured
    /// rounding spread across the ladder is ≤0.3% — 256×171 is 1.4971 where
    /// 512×341 is 1.5015 against a source of 1.5 — while a reshoot in the other
    /// orientation is 1.5 → 0.667. So first-decode-wins survives intact for every
    /// case it was written for, and a reshoot is caught.
    ///
    /// **The margin depends on which rungs are REACHABLE**, which is a coupling to
    /// a constant in another file: the spread stays under 1% for every aspect up
    /// to 5.07:1 across 256/512/1024/2048, and bringing **128** back into reach
    /// breaks it at 2.54:1 — an ordinary photograph, and a containment firing on
    /// rounding is the height jitter the memo exists to remove. 128 is out of
    /// reach only because the narrowest card a writer can make
    /// (`CanvasInteraction.minimumCardWidth`) asks for ~200 px.
    /// `CanvasThumbnailTests.test_theReshootToleranceSeparatesRoundingFromAReshape`
    /// re-does that arithmetic and holds the coupling, rather than trusting this
    /// paragraph.
    public static let aspectReshapeTolerance: CGFloat = 0.01

    /// The size ladder. Powers of two so the count stays small over the camera's
    /// two-decade zoom range, and the top entry doubles as the clamp: no single
    /// decode may exceed it, which is the other half of the byte budget's
    /// arithmetic.
    public static let buckets: [Int] = [128, 256, 512, 1024, 2048]

    /// Snap a requested maximum pixel size **up** to the ladder.
    ///
    /// Up, not to the nearest: a thumbnail smaller than the pixels it is drawn
    /// into is a soft photograph, and that failure is silent. A request above the
    /// top bucket clamps rather than growing the ladder.
    public static func bucket(for maxPixelSize: CGFloat) -> Int {
        let wanted = Int(maxPixelSize.rounded(.up))
        return buckets.first { $0 >= wanted } ?? buckets[buckets.count - 1]
    }

    // MARK: - State

    private struct Key: Hashable {
        let root: String
        let path: String
        let bucket: Int
    }

    /// A photograph's identity for the SHAPE memo — the key above without its
    /// bucket, because a file's proportions are not a function of how big a
    /// thumbnail of it was asked for.
    private struct ShapeKey: Hashable {
        let root: String
        let path: String
    }

    /// A decoded thumbnail, or the memo of a decode that could not produce one.
    ///
    /// **The failure is cached too.** Without it a photograph the writer deleted
    /// from the Finder is re-queued by every frame that draws its card, which is
    /// the per-frame decode this whole file exists to prevent arriving through
    /// the error path.
    private struct Entry {
        let image: CGImage?
        let bytes: Int
        var lastUsed: UInt64
    }

    private var entries: [Key: Entry] = [:]

    /// **What SHAPE each photograph is, remembered for as long as the process
    /// lives — separately from its pixels, and never evicted.**
    ///
    /// An item card's HEIGHT is derived from its picture's aspect ratio, and that
    /// makes the eviction of a thumbnail a question about geometry unless this
    /// exists. It did once, and the failure was not subtle: above the byte budget
    /// a resolve misses on the tail the last service evicted, so the measurement
    /// pass saw a card lose its picture, re-measured it to the floor, asked for
    /// the picture again — and the surface entered an unbounded decode loop with
    /// every card's height rotating through it (Task 5 re-review, N1). **Pixels
    /// are a cache; a shape is a fact.**
    ///
    /// Keyed on the path WITHOUT the bucket, and **first decode wins**. A
    /// thumbnail's own dimensions differ from the source's by up to a pixel of
    /// rounding at each rung of the ladder — 256×171 is 1.4971 where 512×341 is
    /// 1.5015 — so a memo per bucket would move a card's height whenever its
    /// request crossed a rung, which is the jitter this exists to remove arriving
    /// through the back door.
    ///
    /// Unbounded, deliberately: it is 16 bytes per distinct photograph the
    /// session has decoded, against a 64 MiB pixel budget. A canvas would need
    /// millions of images for this to be the thing that hurt.
    private var aspectsByPath: [ShapeKey: CGFloat] = [:]

    private var queue: [Key] = []
    private var clock: UInt64 = 0
    private var isServicing = false

    private let byteBudget: Int
    private let entryBudget: Int

    /// Decode **attempts**, including the ones that produced nothing.
    ///
    /// The counter is the instrument every test in this area uses, because the
    /// alternative is a stopwatch: a wall-clock assertion about decoding is a
    /// flake on a loaded machine, and this project already carries three
    /// clock-dependent tests it regrets.
    public private(set) var decodeCount = 0

    /// Bytes held by resident thumbnails. Failures cost nothing here, which is
    /// what `entryBudget` is for.
    public private(set) var residentBytes = 0

    /// How many distinct decodes the draw pass has asked for and not yet had.
    /// A miss repeated over fifty frames is one pending request, not fifty.
    public var pendingCount: Int { queue.count }

    public init(byteBudget: Int = CanvasThumbnails.defaultByteBudget,
                entryBudget: Int = CanvasThumbnails.defaultEntryBudget) {
        self.byteBudget = byteBudget
        self.entryBudget = entryBudget
    }

    // MARK: - The frame path

    /// **Read a thumbnail. Never decodes.** Safe to call from inside the draw
    /// closure, once per visible card per frame.
    ///
    /// Returns nil when the image has not been decoded yet *and* when it never
    /// can be (the file is gone, or is not an image). The caller draws the card
    /// without a picture in both cases — a card is a card either way, and the
    /// difference is not something the draw pass can act on.
    ///
    /// A miss that is still resolvable is queued for `servicePending()`.
    public func resolved(_ path: String, in projectRoot: URL,
                         fitting maxPixelSize: CGFloat) -> CGImage? {
        let key = Key(root: projectRoot.standardizedFileURL.path,
                      path: path,
                      bucket: Self.bucket(for: maxPixelSize))
        if var entry = entries[key] {
            clock += 1
            entry.lastUsed = clock
            entries[key] = entry
            return entry.image
        }
        if !queue.contains(key) { queue.append(key) }
        return nil
    }

    /// **What shape that photograph is, whether or not its pixels are resident.**
    /// Also never decodes, and also safe on the frame path — it is the lookup a
    /// MEASUREMENT asks, and it answers for anything this session has ever
    /// decoded. Nil until the first successful decode, and nil forever for a file
    /// that cannot be read.
    ///
    /// See `aspectsByPath` for why a card's height must not depend on whether its
    /// thumbnail is currently resident.
    public func aspect(_ path: String, in projectRoot: URL) -> CGFloat? {
        aspectsByPath[ShapeKey(root: projectRoot.standardizedFileURL.path, path: path)]
    }

    // MARK: - Off the frame path

    /// Decode everything the draw pass missed. **Never call this from inside a
    /// draw closure** — it is `async` so that it cannot be, and the decode itself
    /// runs off the main actor.
    ///
    /// Returns whether anything landed, so the caller can decide to redraw
    /// without asking the cache what changed.
    @discardableResult
    public func servicePending() async -> Bool {
        guard !isServicing else { return false }
        isServicing = true
        defer { isServicing = false }

        var landed = false
        while !queue.isEmpty {
            let key = queue.removeFirst()
            guard entries[key] == nil else { continue }
            // **The one place in this file the path becomes a filesystem URL, so
            // the one place the containment gate runs** (F8, issue #28). An
            // owned path is a claim about a file THIS project owns
            // (`Maugham/Canvas/AREA.md`) and it arrives from a sidecar, which is
            // an ordinary file on disk — a `../` in `canvas.json` otherwise
            // draws a photograph the project does not own on the writer's
            // canvas. `SafeRelativePath.resolve` returns exactly the URL
            // `appendingPathComponent` built before it, so nothing about a
            // legitimate path moves.
            //
            // A refused path is cached as a FAILURE, like a file that is not an
            // image: refused once, never re-queued. Without that the card naming
            // it asks again on every frame that draws it — the per-frame work
            // this file exists to prevent, arriving through the refusal path.
            guard let url = try? SafeRelativePath.resolve(
                key.path, under: URL(fileURLWithPath: key.root)) else {
                store(nil, for: key)
                continue
            }
            let bucket = key.bucket
            let image = await Task.detached(priority: .utility) {
                Self.decode(url, maxPixelSize: bucket)
            }.value
            decodeCount += 1
            store(image, for: key)
            landed = landed || image != nil
        }
        return landed
    }

    // MARK: - The decode

    /// No single decode may begin on a source claiming more pixels than this
    /// (F13, issue #28) — 200 MP passes any real camera or panorama and
    /// refuses the bomb class. Dimensions come from the header without
    /// decoding; a source with UNREADABLE dimensions proceeds, because the
    /// bomb must declare its size to work and the thumbnailer already fails
    /// honestly on garbage.
    nonisolated static let sourcePixelCap = 200_000_000

    /// One decode, at thumbnail size, through `CGImageSource`.
    ///
    /// **`CGImageSourceCreateThumbnailAtIndex`, not a full-size decode followed
    /// by a redraw.** The palette wall's `downscaled(_:maxEdge:)` does exactly
    /// that — `NSImage(contentsOf:)` then `lockFocus`/`draw` — and it gets away
    /// with it because a palette holds a handful of cards. Copying it here would
    /// pull every pixel of a 6000×4000 photograph through memory to produce a
    /// 256 px card.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageAlways` is what makes this honest:
    /// without it ImageIO serves whatever thumbnail the file happens to embed,
    /// which for a phone capture is often 160 px and for a PNG is nothing at all.
    /// `…WithTransform` applies the EXIF orientation, so a photograph taken in
    /// portrait is not drawn on its side.
    ///
    /// **The bucket ladder bounds the OUTPUT; it does not bound ImageIO's peak
    /// working set while producing it, which is proportional to the SOURCE**
    /// (F13, issue #28). A tiny-on-disk file that *claims* an enormous pixel
    /// count — a decompression bomb — can spike memory before
    /// `kCGImageSourceThumbnailMaxPixelSize` ever gets a say, so the gate below
    /// reads the claimed dimensions from the header, without decoding, and
    /// refuses before the thumbnailer runs.
    ///
    /// `internal` rather than `private` so the test can exercise the cap
    /// directly: a forged-huge-header fixture fails to decode for other
    /// reasons (ImageIO validates the file against the claim) and cannot
    /// discriminate the gate from an ordinary decode failure — only a small
    /// cap against an honest, decodable fixture can.
    nonisolated static func decode(_ url: URL, maxPixelSize: Int,
                                   sourcePixelCap: Int = CanvasThumbnails.sourcePixelCap) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        // Header only — no decode. A source with UNREADABLE dimensions proceeds
        // rather than refusing, so this is **a floor over sources that declare
        // themselves, not a guarantee**: a TIFF claiming 65535×65535 can return
        // a properties dict with no pixel-width/height keys at all and sail
        // straight past this (measured, #28 review), failing harmlessly on its
        // own merits at the thumbnailer a few lines down. Refusing everything
        // that will not state its size would refuse honest files too.
        //
        // `multipliedReportingOverflow` because the claim is the ATTACKER's
        // number: two Ints out of a header multiply to a trap on overflow, and a
        // crash is a worse answer than a refusal. An overflowing product is over
        // any cap by construction.
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int {
            let (pixels, overflowed) = width.multipliedReportingOverflow(by: height)
            if overflowed || pixels > sourcePixelCap { return nil }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Storage and eviction

    private func store(_ image: CGImage?, for key: Key) {
        clock += 1
        let bytes = image.map { $0.height * $0.bytesPerRow } ?? 0
        entries[key] = Entry(image: image, bytes: bytes, lastUsed: clock)
        residentBytes += bytes
        // The SHAPE is recorded before the pixels can be evicted, and first decode
        // wins — so a later request at a different bucket cannot move a card by a
        // rounding error. A failed decode records nothing.
        //
        // **Except when the FILE changed shape**, which first-decode-wins alone
        // cannot see: the writer replaces the picture at a path with one of a
        // different orientation, a later request crosses a bucket, and that fresh
        // decode of the new file meets a memo describing the old one. The card is
        // then measured to the wrong shape and `GraphicsContext.draw(_:in:)`
        // stretches the photograph into it. See `aspectReshapeTolerance` for why
        // 1% separates the ladder's rounding from a reshoot with fifty times to
        // spare.
        //
        // **A reshoot invalidates the PIXELS as well as the memo, and the memo
        // alone was half a fix** *(review I1)*. `entries` is keyed by BUCKET and
        // nothing else ever invalidates it on a file change — the only removal is
        // LRU — so moving the memo and leaving the pixels relocates the squash
        // rather than removing it: every other bucket still holds the old
        // photograph, ready to be served into a box measured from the new shape.
        // **One resize gesture reaches it**: drag the card out (fresh decode at
        // the bigger bucket, memo moves, drawn correctly), then drag it back in,
        // and the smaller bucket's stale pixels are drawn in the new shape's box.
        if let image, image.height > 0 {
            let shape = ShapeKey(root: key.root, path: key.path)
            let aspect = CGFloat(image.width) / CGFloat(image.height)
            if let memo = aspectsByPath[shape] {
                if abs(aspect - memo) > memo * Self.aspectReshapeTolerance {
                    aspectsByPath[shape] = aspect
                    dropOtherBuckets(of: key)
                }
            } else {
                aspectsByPath[shape] = aspect
            }
        }
        evictIfNeeded()
    }

    /// Forget every OTHER bucket's pixels for the photograph `key` names — the
    /// reshoot path, and the only invalidation in this file that is not LRU.
    ///
    /// Narrow on purpose: it drops entries for **this one path in this one
    /// project** and nothing else, because a cache that dropped more than it had
    /// evidence about would be a fresh decode per frame wearing a correctness
    /// fix's name. `test_aReshootMovesTheShapeMemoAndTheStalePixelsWithIt`'s
    /// untouched second photograph is the control that says so.
    ///
    /// **The keys are collected before any removal.** Writing through `entries`
    /// while iterating it is the kind of thing copy-on-write happens to make safe
    /// rather than the kind of thing that IS safe — `CanvasScene.remove` says the
    /// same about its own dictionaries. Nothing is re-queued here: the next
    /// `resolved` for a dropped bucket misses, and a miss is already a request.
    private func dropOtherBuckets(of key: Key) {
        let stale = entries.keys.filter {
            $0.root == key.root && $0.path == key.path && $0.bucket != key.bucket
        }
        for staleKey in stale {
            residentBytes -= entries[staleKey]?.bytes ?? 0
            entries.removeValue(forKey: staleKey)
        }
    }

    /// Least-recently-used, over both bounds.
    ///
    /// The `count > 1` guard is not decoration: a single entry larger than the
    /// whole byte budget would otherwise evict itself the instant it was stored,
    /// so every ask for it would be a fresh decode — an always-evicting cache,
    /// which is precisely the shape a naive eviction test cannot see.
    private func evictIfNeeded() {
        while entries.count > 1 && (entries.count > entryBudget || residentBytes > byteBudget) {
            guard let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })
            else { return }
            residentBytes -= oldest.value.bytes
            entries.removeValue(forKey: oldest.key)
        }
    }
}
