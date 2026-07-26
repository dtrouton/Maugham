import SwiftUI

/// What a canvas element is, for an assistive client.
enum CanvasAXRole: String, Equatable, Sendable {
    case scrap
    case item
}

/// One synthetic accessibility element mirroring one node of the scene graph.
struct CanvasAXElement: Equatable, Identifiable {
    let id: CanvasNodeID
    /// What the element IS, plus where — "Scrap, 3 of 12" reads badly, so the
    /// label carries the kind and the value carries the words.
    let role: CanvasAXRole
    let label: String
    let value: String
    /// CONTENT coordinates, deliberately: an element that carried view
    /// coordinates would be invalidated by every pan and zoom, so the whole list
    /// would be rebuilt on every scroll event — scene-proportional work inside a
    /// per-frame loop. The camera is applied at the point of use instead.
    let contentFrame: CGRect

    /// Where an assistive client should point, right now.
    func viewFrame(in camera: CanvasCamera) -> CGRect {
        let origin = camera.viewPoint(fromContent: contentFrame.origin)
        return CGRect(x: origin.x, y: origin.y,
                      width: contentFrame.width * camera.zoom,
                      height: contentFrame.height * camera.zoom)
    }
}

/// The canvas's accessibility tree.
///
/// Spec §7A.6: *"We own accessibility for the canvas. Drawn content has no AX
/// tree… Budget an AX layer mirroring the scene graph; Figma does exactly this.
/// Not optional in a writing tool."*
///
/// Four rules, each deliberate:
///
/// 1. **Every node is here, not just the visible ones.** Culling is a drawing
///    optimisation; a node you cannot see is still a node you must be able to
///    reach, and an assistive client walks elements rather than panning first.
/// 2. **Reading order is rows, then columns** — banded by y so roughly-level
///    cards read left to right. Z-order is a drawing concern and would read the
///    canvas out in the order the writer happened to touch it.
/// 3. **The mounted editor is a real `NSTextView`** and is natively accessible.
///    That is the whole point of the one-real-editor-on-focus rule: drawing text
///    forfeits IME, caret placement, spell-check, selection and
///    magnification-follows-caret. Nothing here may hide it.
/// 4. **Nothing here depends on the camera**, so panning and zooming — the
///    commonest per-frame path — cannot invalidate the list. `CanvasView`
///    rebuilds it from an `.onChange` on the STRUCTURAL counter, never inside
///    `body` and never from `revision`, which every animation frame increments.
enum CanvasAccessibility {

    static let canvasLabel = "Planning canvas"
    static let emptyCanvasValue = "Empty canvas. Double-click to add a scrap."
    static let emptyScrapValue = "Empty scrap"

    /// Cards within this many points of each other vertically read as one row.
    private static let rowBand: CGFloat = 60
    /// A node that has never been measured still needs a rect, or it drops out
    /// of the tree the instant a writer creates it.
    private static let unmeasuredHeight: CGFloat = 40

    static func elements(scene: CanvasScene,
                         scraps: [CanvasNodeID: String]) -> [CanvasAXElement] {
        // `unorderedNodes`, not `nodes`: `nodes` sorts into DRAW order on every
        // access, and this method immediately re-sorts into READING order. One
        // sort, not two.
        scene.unorderedNodes
            .sorted { a, b in
                let bandA = (a.origin.y / rowBand).rounded(.down)
                let bandB = (b.origin.y / rowBand).rounded(.down)
                if bandA != bandB { return bandA < bandB }
                if a.origin.x != b.origin.x { return a.origin.x < b.origin.x }
                return a.id.raw < b.id.raw
            }
            .map { node in
                let frame = CGRect(origin: node.origin,
                                   size: CGSize(width: node.width,
                                                height: node.cachedHeight ?? unmeasuredHeight))
                switch node.kind {
                case .scrap:
                    let text = scraps[node.id] ?? ""
                    return CanvasAXElement(
                        id: node.id, role: .scrap,
                        label: "Scrap",
                        value: text.isEmpty ? emptyScrapValue : text,
                        contentFrame: frame)
                case .item(let referenceId):
                    return CanvasAXElement(
                        id: node.id, role: .item,
                        label: "Reference",
                        value: CanvasRenderer.placeholderLabel(forReference: referenceId),
                        contentFrame: frame)
                }
            }
    }

    /// What the canvas itself says when focused, before its children are walked.
    ///
    /// `scene.count`, never `scene.nodes.count` — this is read from `body`, and
    /// `nodes` sorts the whole scene to hand back a number the dictionary
    /// already knows.
    static func summary(scene: CanvasScene) -> String {
        let count = scene.count
        guard count > 0 else { return emptyCanvasValue }
        return "\(count) \(count == 1 ? "item" : "items")"
    }
}

/// The synthetic children, extracted so SwiftUI can skip rebuilding them.
///
/// Inline in `CanvasView.body`, this `ForEach` re-evaluates N views on every
/// body pass because it reads `camera` — scene-proportional work at frame rate,
/// which is what `CanvasAccessibility`'s own doc comment forbids one layer up.
/// As an `Equatable` view used with `.equatable()`, SwiftUI skips it whenever
/// neither the elements nor the camera changed: a straighten, a coast, a node
/// drag and typing all qualify. A pan or a zoom does rebuild it — the frames
/// have to follow the camera to stay pointable — and that is the accepted cost,
/// bounded by the same 2,000-node number Task 16 defends.
struct CanvasAXChildren: View, Equatable {
    let elements: [CanvasAXElement]
    let camera: CanvasCamera

    var body: some View {
        ForEach(elements) { element in
            let frame = element.viewFrame(in: camera)
            Color.clear
                .frame(width: max(1, frame.width), height: max(1, frame.height))
                .position(x: frame.midX, y: frame.midY)
                .accessibilityElement()
                // The trait is load-bearing, not decoration. Measured against a
                // hosted window on 2026-07-26: without it SwiftUI gives the
                // synthetic node the role AXUnknown and files the string under
                // AXValueDescription, leaving `accessibilityValue` — the slot the
                // mounted NSTextView publishes its own text in, and the slot
                // VoiceOver reads a card out of — EMPTY. The card would announce
                // "Scrap" and stop, which is spec §7A.6's blank rectangle with a
                // label on it. With the trait the role is AXStaticText and the
                // writer's sentence is where an assistive client looks for it.
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(element.label)
                .accessibilityValue(element.value)
        }
    }
}
