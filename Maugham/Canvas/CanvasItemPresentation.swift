import CoreGraphics
import Foundation

/// What the canvas has RESOLVED about the item nodes in a scene: what each one
/// says it is (`CanvasItemFacts`), and the picture to draw on it when one has
/// arrived.
///
/// **One value, three consumers, and that is the whole point of it.** The draw
/// pass, the measurement pass (`CanvasView.rebuildLayouts`) and the accessibility
/// tree all read the same resolved facts, so the card a writer looks at, the rect
/// a click lands in and the sentence VoiceOver reads cannot come to different
/// conclusions about what a card is. `layouts` is the shape being copied: a
/// dictionary built once per structural change and handed to everything that
/// needs it, rather than resolved per node inside a `Canvas` closure that runs at
/// 60–120 Hz (tripwire 4, tripwire 30).
///
/// **It is not a cache and it holds no policy.** `CanvasItemIndex` decides what an
/// item is called, `CanvasThumbnails` decides what is decoded and when, and this
/// is the answer they produce together, frozen for as long as the scene and the
/// manifest hold still.
struct CanvasItemPresentation {

    /// One item node's resolved appearance.
    struct Item {
        let facts: CanvasItemFacts
        /// Nil until the thumbnail lands — `CanvasThumbnails.resolved` never
        /// decodes, so the first pass after a picture appears on the canvas
        /// always misses. The card draws its label and nothing else, and its
        /// height is the floor, until `servicePending()` has run.
        let picture: CGImage?

        /// The picture's width over its height, or nil when there is no picture
        /// yet. **This is what makes an item card's height a function of its
        /// width** (spec §7A.3), so it is read off the decoded thumbnail rather
        /// than stored anywhere: the thumbnail is the same shape as the
        /// photograph (`CanvasThumbnailTests` pins that), and nothing else in the
        /// project knows a research image's dimensions without opening it.
        var pictureAspect: CGFloat? {
            guard let picture, picture.height > 0 else { return nil }
            return CGFloat(picture.width) / CGFloat(picture.height)
        }
    }

    private let itemsByNode: [CanvasNodeID: Item]

    /// Nothing resolved: every item node draws its card and no content, and
    /// measures to the floor.
    ///
    /// **This is a real state and not a test convenience.** It is what the first
    /// frame after a load looks like on a canvas whose window has not built its
    /// index yet, and the surface has to be honest in it rather than blank.
    static let empty = CanvasItemPresentation(itemsByNode: [:])

    private init(itemsByNode: [CanvasNodeID: Item]) {
        self.itemsByNode = itemsByNode
    }

    func item(for id: CanvasNodeID) -> Item? { itemsByNode[id] }

    /// How many item nodes resolved to a picture — the instrument a test uses to
    /// say a thumbnail landed without reading pixels.
    var picturedCount: Int { itemsByNode.values.count { $0.picture != nil } }

    /// Facts only, no pictures — for a caller that has to NAME an item node
    /// without drawing one.
    ///
    /// `RegionInspector`'s member lists are the caller: a Claude region holds the
    /// page its scraps were read off, so a region's rows really do include item
    /// nodes, and a row is a title rather than a card. It is `nonisolated` and
    /// touches no cache, which is the whole difference from `resolve` below.
    ///
    /// **One spelling of "what is this node called", not two.** A pane that
    /// resolved a title of its own would drift from the card, which is
    /// `PromotedArtifactSection`'s own history on the neighbouring field.
    static func facts(in scene: CanvasScene, index: CanvasItemIndex) -> CanvasItemPresentation {
        var items: [CanvasNodeID: Item] = [:]
        for node in scene.unorderedNodes {
            guard case .item(let reference) = node.kind else { continue }
            items[node.id] = Item(facts: CanvasItemFacts.resolve(reference, in: index),
                                  picture: nil)
        }
        return CanvasItemPresentation(itemsByNode: items)
    }

    /// Resolve every item node in the scene.
    ///
    /// **`@MainActor` because `CanvasThumbnails` is**, and that is the whole of
    /// this function's isolation story: the cache records a miss when it is asked
    /// for an image it does not hold, so asking is a mutation and belongs on the
    /// actor that owns it. Nothing here decodes — `resolved(_:in:fitting:)` is a
    /// dictionary lookup by contract — so this is safe to run on the same pass
    /// that measures the scene.
    ///
    /// **The pixel size asked for is the card's CONTENT width, in pixels rather
    /// than points.** `CanvasThumbnails.assumedPixelScale` is the points→pixels
    /// allowance, and it is not the drawing scale spike requirement 3 forbids
    /// deriving: this number sizes a *decode request*, the drawn rect stays in
    /// points, and the context's own scale does the rasterising. The camera's zoom
    /// is deliberately **not** in it — see `CanvasThumbnails.assumedPixelScale`.
    @MainActor
    static func resolve(scene: CanvasScene,
                        index: CanvasItemIndex,
                        thumbnails: CanvasThumbnails,
                        projectRoot: URL) -> CanvasItemPresentation {
        var items: [CanvasNodeID: Item] = [:]
        for node in scene.unorderedNodes {
            guard case .item(let reference) = node.kind else { continue }
            let facts = CanvasItemFacts.resolve(reference, in: index)
            let picture = facts.thumbnailPath.flatMap {
                thumbnails.resolved($0, in: projectRoot,
                                    fitting: CanvasCardMetrics.textWidth(forCardWidth: node.width)
                                        * CanvasThumbnails.assumedPixelScale)
            }
            items[node.id] = Item(facts: facts, picture: picture)
        }
        return CanvasItemPresentation(itemsByNode: items)
    }
}
