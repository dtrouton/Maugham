import SwiftUI

/// What a canvas element is, for an assistive client.
enum CanvasAXRole: String, Equatable, Sendable {
    case scrap
    case item
    case region
}

/// What a synthetic element stands for.
///
/// Nodes and regions have separate id spaces — `CanvasNodeID("r1")` and
/// `CanvasRegionID("r1")` are different things and may both exist — so the tree
/// cannot key on a bare string without two primitives silently sharing one
/// `Identifiable` id and one of them dropping out of the `ForEach`.
enum CanvasAXIdentity: Hashable, Sendable {
    case node(CanvasNodeID)
    case region(CanvasRegionID)

    /// A stable, unique string. The prefix is what keeps the two spaces apart;
    /// nodes keep their bare id so the reading-order fixtures still read as the
    /// ids the scene was built with.
    var raw: String {
        switch self {
        case .node(let id): return id.raw
        case .region(let id): return "region:\(id.raw)"
        }
    }
}

/// One synthetic accessibility element mirroring one node or region of the
/// scene graph.
struct CanvasAXElement: Equatable, Identifiable {
    let id: CanvasAXIdentity
    let role: CanvasAXRole
    /// What the element IS, plus where — "Scrap, 3 of 12" reads badly, so the
    /// label carries the kind and the value carries the words.
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
/// 2. **Reading order is rows, then columns** — banded by the gap between one
///    card and the next below it, so roughly-level cards read left to right
///    wherever they sit (see `rowOrdered`). Z-order is a drawing concern and
///    would read the canvas out in the order the writer happened to touch it.
/// 3. **The mounted editor is a real `NSTextView`** and is natively accessible.
///    That is the whole point of the one-real-editor-on-focus rule: drawing text
///    forfeits IME, caret placement, spell-check, selection and
///    magnification-follows-caret. Nothing here may hide it.
/// 4. **Nothing here depends on the camera**, so panning and zooming — the
///    commonest per-frame path — cannot invalidate the list. `CanvasView`
///    rebuilds it from an `.onChange` on the STRUCTURAL counter, never inside
///    `body` and never from `revision`, which every animation frame increments.
/// 5. **A line is not an element of its own.** Every element carries a
///    content-space frame and an assistive client navigates by it; a line's
///    frame is the bounding box of its two endpoints, which is mostly bare
///    ground with two other people's cards in the corners — so a VoiceOver user
///    would walk into a large rectangle and find nothing in it, and on a
///    near-axis-aligned line they would walk into a sliver. A line is a
///    RELATIONSHIP, and the place a relationship is legible is at its ends: each
///    connected node names how many lines touch it and what they are called, and
///    `summary` reports the total so a canvas with lines on it does not sound
///    identical to one without. That also keeps the whole line layer on the same
///    `sceneRevision` rebuild the elements already use, and adds no new frame
///    path. *Open, for a VoiceOver walk and not a unit test:* whether a line
///    should be independently navigable after all — see AREA.md, beside the
///    focused-scrap divergence.
enum CanvasAccessibility {

    static let canvasLabel = "Planning canvas"
    static let emptyCanvasValue = "Empty canvas. Double-click to add a scrap."
    static let emptyScrapValue = "Empty scrap"

    /// What a region announces itself as, before its name. Internal so the tests
    /// assert against the same word production ships rather than a literal that
    /// can drift away from it — and named separately from `CanvasAXRole.region`
    /// because that enum is a test-visible classification and this is prose an
    /// assistive client reads aloud.
    static let regionKind = "Region"

    /// Cards within this many points of each other vertically read as one row.
    ///
    /// Internal rather than private so the reading-order tests can express their
    /// fixtures in terms of it: a fixture written against a literal 60 agrees with
    /// a grid implementation by coincidence, and stops discriminating at all if
    /// this number ever moves.
    static let rowBand: CGFloat = 60
    /// A node that has never been measured still needs a rect, or it drops out
    /// of the tree the instant a writer creates it.
    private static let unmeasuredHeight: CGFloat = 40

    /// How a node's lines are named in its label, or nil when nothing touches it.
    ///
    /// The COUNT first, because it is the one fact every connected card has;
    /// then the names of the lines that have one. An unlabelled line contributes
    /// to the count and nothing else — a line is untyped and optionally named by
    /// design (spec §5), so most of them have nothing to say, and reading
    /// "unnamed" out three times says less than "3 lines" does.
    ///
    /// **Whitespace is no name, and the trim is `.whitespacesAndNewlines`** —
    /// the rule `LineInspector.normalise` applies on the way in. A label that
    /// arrived from a hand-edited sidecar never passed through it, and
    /// `.whitespaces` is space and tab only: a label of `"\n"` survives that
    /// narrower trim, and an assistive client is handed `"1 line:"` followed by
    /// silence, which is indistinguishable from a bug.
    ///
    /// **`CanvasRenderer.lineLabelBox` now trims the same set** *(widened
    /// 1C-c3)*, so all three readings of "whitespace is no name" agree and this
    /// comment no longer records a divergence. It used to, and the reason is
    /// worth keeping: matching the renderer was never the precedent here,
    /// because what the renderer drew in that case was the defect `normalise`'s
    /// own doc comment describes — an empty pill, visible, unreadable, and
    /// removable only by finding the field and clearing it twice. The agreement
    /// was reached by fixing the drawing, not by announcing it. See AREA.md.
    ///
    /// **Whose hand drew them rides in the count clause** (spec §8A.2
    /// constraint 1), and it has to: a line is an element nowhere, so its ends
    /// are the only place anything can be said about it, and the drawn signal is
    /// a hue shift on a 1.5 pt hairline that an assistive client cannot see at
    /// all. This is what carries a Claude line's provenance whatever the stroke
    /// manages to say.
    ///
    /// **The count stays the whole set and the provenance is a share of it.**
    /// "2 from Claude" beside "3 lines" is a fact about the same three; a count
    /// that excluded the writer's would be a different, smaller canvas. The two
    /// phrasings differ on purpose — all of them reads "2 lines from Claude",
    /// some of them reads "3 lines, 2 from Claude" — because "3 lines, 3 from
    /// Claude" is the clumsy way to say the first, and a card whose every line
    /// came from Claude is the ordinary case for a batch it placed itself.
    ///
    /// Internal rather than private so the tests assert against the wording
    /// production ships, and pure so they can do it without a scene.
    static func connectionPhrase(for lines: [CanvasLine]) -> String? {
        guard !lines.isEmpty else { return nil }
        var count = "\(lines.count) \(lines.count == 1 ? "line" : "lines")"
        let claudes = lines.count { $0.author == .claude }
        if claudes == lines.count {
            count += " \(claudeTerm)"
        } else if claudes > 0 {
            count += ", \(claudes) \(claudeTerm)"
        }
        let names = lines
            .compactMap { $0.label?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? count : "\(count): \(names.joined(separator: ", "))"
    }

    /// Which lines touch each node, in one pass.
    ///
    /// **Built once per rebuild, deliberately, and this is why
    /// `CanvasScene.lines(touching:)` was deleted rather than given its caller
    /// here.** Asking the scene per node is `O(nodes × lines)` with an array
    /// allocated per node, and lines are the one collection on this surface that
    /// nothing bounds — a writer can draw one per card. This rebuild is not on
    /// the frame path, but it *is* on the gesture path: `sceneRevision` bumps at
    /// the end of every drag and resize, on every create, delete and ⌘Z. A
    /// quadratic term there is a hitch when the writer lets go of a card, which
    /// is the worst moment on a surface whose whole argument is that it feels
    /// like paper. See AREA.md for the measurement.
    ///
    /// The lists inherit `scene.lines`' id order, so a label's names are in the
    /// same order twice running. That is not decoration: `Set`/dictionary
    /// iteration is seeded per process, so a phrase built from an unordered walk
    /// reads differently between two runs of the same binary — the bug
    /// `CanvasMembership.homeRegion` was measured flaking on.
    ///
    /// **A line with a HIDDEN end is not announced**, and the filter is
    /// `scene.isHidden` — the same predicate the node loop below reads, so this
    /// tree has one rule about a collapsed region rather than two. A resident of
    /// a collapsed region has left the tree entirely, so naming a line to it
    /// would announce a relationship to a card an assistive client cannot
    /// navigate to at all.
    ///
    /// **An UNMEASURED end is announced, and that is deliberately not the
    /// renderer's rule.** `CanvasScene.drawnLines` drops both cases and would
    /// have been the tempting single source, but the node loop below keeps an
    /// unmeasured card in the tree on purpose (`unmeasuredHeight` exists for
    /// exactly that) — a scrap the writer just made must not be unreachable
    /// until a layout pass happens to run. A line to a card that IS in the tree
    /// belongs in the tree with it.
    private static func connections(in scene: CanvasScene) -> [CanvasNodeID: [CanvasLine]] {
        var index: [CanvasNodeID: [CanvasLine]] = [:]
        for line in scene.lines where !scene.isHidden(line.from) && !scene.isHidden(line.to) {
            index[line.from, default: []].append(line)
            index[line.to, default: []].append(line)
        }
        return index
    }

    /// The word a promoted node or region carries in its label. A constant so
    /// the tests assert against what ships, exactly as `regionKind` is.
    static let promotedTerm = "promoted"

    /// The word anything Claude made or placed carries — a scrap, a region, an
    /// item node, and a line inside `connectionPhrase`. A constant for the reason
    /// `promotedTerm` and `regionKind` are, and **one wording for one fact**: the
    /// region a batch lands in is called
    /// `CanvasClaudePlacement.defaultRegionLabel` ("From Claude") and the undo
    /// step is `CanvasClaudeWrite.undoStepName` ("Add Scraps from Claude"), so a
    /// third phrasing here would make one thing sound like three.
    /// `CanvasAccessibilityTests`'
    /// `test_theSpokenTermAgreesWithTheRegionLabelAndTheUndoStep` holds the three
    /// against each other.
    ///
    /// **It is ONE term across all three primitives even though the two drawn
    /// signals answer different questions** — the tint says *whose words these
    /// are* and the tilt says *who placed this here*, and on an item node only
    /// the second is true. Two spoken wordings were considered and rejected
    /// (Denver, 2026-07-30): a listener holding "from Claude" and a second
    /// phrase apart, and having to remember which primitive takes which, is a
    /// worse cost than one phrase that is slightly loose on the one primitive
    /// where the two signals diverge.
    static let claudeTerm = "from Claude"

    /// **The one ordering rule for every label on this surface.** The kind,
    /// then what it is called, then where it came from, then the durable facts
    /// in the order they were added.
    ///
    /// The kind stays FIRST because `CanvasAXRole` never reaches an assistive
    /// client — see `elements`. A name follows it, because kind-plus-name is how
    /// a primitive identifies itself and splitting the two with anything else
    /// makes the name sound like an afterthought (and in the ordinary Claude
    /// case it would read "Region, from Claude, From Claude"). **Provenance sits
    /// before the durable facts** because it is prior to them: where a thing
    /// came from does not change, and what has happened to it since is read
    /// against that.
    ///
    /// Every arm of `elements` goes through here, deliberately — the region arm
    /// built its own array until 2026-07-30, and the moment provenance had to
    /// join it there were two copies of this ordering with nothing holding them
    /// together.
    private static func label(_ kind: String,
                              named name: String? = nil,
                              fromClaude: Bool,
                              promoted: Bool,
                              connectedBy lines: [CanvasLine]? = nil,
                              collapsed: Bool = false) -> String {
        var parts = [kind]
        if let name { parts.append(name) }
        if fromClaude { parts.append(claudeTerm) }
        if promoted { parts.append(promotedTerm) }
        if let phrase = connectionPhrase(for: lines ?? []) { parts.append(phrase) }
        if collapsed { parts.append(collapsedTerm) }
        return parts.joined(separator: ", ")
    }

    /// The word a collapsed region carries, last. A constant beside the other
    /// two so the tests assert what ships.
    static let collapsedTerm = "collapsed"

    static func elements(scene: CanvasScene,
                         scraps: [CanvasNodeID: String]) -> [CanvasAXElement] {
        let connections = connections(in: scene)
        // Regions first into the list, but the ORDER is decided by `rowOrdered`
        // over everything together — a region's frame starts at or above-left of
        // the cards inside it, so the same rows-then-columns rule reads a region
        // out before its contents without a special case for it.
        var elements: [CanvasAXElement] = scene.unorderedRegions.map { region in
            let residents = CanvasMembership.residents(of: region.id, in: scene).count
            return CanvasAXElement(
                id: .region(region.id), role: .region,
                // **The kind rides in the LABEL, because `role` never reaches an
                // assistive client.** `CanvasAXChildren` publishes label and
                // value and nothing else — `CanvasAXRole` is computed here and
                // read only by these tests — so a region announced as
                // "Act II fog, 3 cards" says what it is called and never says
                // what it is, beside a scrap that opens with "Scrap" and an item
                // node that opens with "Reference". §7A.6 calls this tree
                // non-optional in a writing tool, and a primitive the writer can
                // see and the VoiceOver user cannot name is exactly what it
                // exists to prevent.
                //
                // The collapsed state rides there too: the value is the card
                // count either way, so without it a collapsed region and an
                // expanded one holding the same cards read out identically —
                // and collapse is the one thing about a region a VoiceOver user
                // cannot otherwise discover, because its cards have left the
                // tree entirely.
                //
                // "Promoted" rides there too, and so does WHOSE HAND SWEPT IT.
                // A region carries no tint at all — no paper, no ink of its own
                // — so the 1° lean is the whole of its provenance, and a lean is
                // inaudible. Without the term a sighted writer sees "a machine
                // put this here" and a VoiceOver user is told nothing, which is
                // the failure §7A.6 calls not optional in a writing tool and
                // §8A.2 constraint 1 asks us to close.
                //
                // **The repetition is accepted, not overlooked** (Denver,
                // 2026-07-30). Walking a Claude region of six cards says the
                // phrase seven times, and a region left on its default label
                // says it twice in a row — "Region, From Claude, from Claude, 6
                // cards". The alternative was announcing it once, here, and
                // leaving the cards silent; **this tree is FLAT** — `rowOrdered`
                // interleaves regions and cards by position and a card is not a
                // child of its region — so a user walking card to card can reach
                // a Claude card without ever passing the region that would have
                // said it. Silence in that case is exactly the failure above.
                // Repetitive and never wrong beats quiet and sometimes wrong.
                //
                // For the same reason the term is NOT suppressed when the
                // region's name already contains it: a term whose presence
                // depends on what the writer happened to call the region is a
                // term no listener can rely on, and a renamed region — the case
                // with the real hole — is precisely where it would vanish.
                label: label(regionKind,
                             named: region.displayLabel,
                             fromClaude: region.author == .claude,
                             promoted: region.promotedItemID != nil,
                             collapsed: region.isCollapsed),
                value: region.isCollapsed
                    ? CanvasRenderer.collapsedSummary(for: region.id, in: scene)
                    : "\(residents) \(residents == 1 ? "card" : "cards")",
                contentFrame: region.frame)
        }

        // A resident of a collapsed region is not drawn, not clickable and not
        // here: a VoiceOver user must not walk into cards that are not on
        // screen. `unorderedNodes` deliberately still returns them, because
        // `CanvasView.rebuildLayouts()` must keep measuring a hidden scrap.
        for node in scene.unorderedNodes where !scene.isHidden(node.id) {
            let frame = CGRect(origin: node.origin,
                               size: CGSize(width: node.width,
                                            height: node.cachedHeight ?? unmeasuredHeight))
            switch node.kind {
            case .scrap:
                let text = scraps[node.id] ?? ""
                elements.append(CanvasAXElement(
                    id: .node(node.id), role: .scrap,
                    label: label("Scrap",
                                 fromClaude: node.author == .claude,
                                 promoted: node.promotedItemID != nil,
                                 connectedBy: connections[node.id]),
                    value: text.isEmpty ? emptyScrapValue : text,
                    contentFrame: frame))
            case .item(let reference):
                elements.append(CanvasAXElement(
                    id: .node(node.id), role: .item,
                    // `promoted: false` unconditionally, and the author READ —
                    // and the two are not the same kind of decision.
                    //
                    // `promoted: false` is closed: an item node already exists as
                    // itself, so it cannot be promoted and a mark on one says
                    // nothing true. `CanvasClaudePlacement` sets no
                    // `promotedItemID`, a hand-edited sidecar can, and
                    // `CanvasRenderer` refuses the stripe on exactly these terms.
                    //
                    // **`fromClaude` deliberately does NOT follow
                    // `CanvasRenderer.paper(for:)`, which refuses to tint an item
                    // node whatever its author says.** Those answer different
                    // questions. `paper(for:)` answers the TINT's — *whose words
                    // are these* — and a photographed page's words are the
                    // writer's own, so it is right to refuse. The *tilt* answers
                    // *who placed this here*, and since 2026-07-30
                    // `CanvasClaudePlacement` writes `author: .claude` on every
                    // source page it creates, so `seededRotation(for:)` draws it
                    // perfectly straight — Claude did mint the node and choose
                    // its place. A lean is inaudible. Passing `false` here left
                    // the page visually marked as placed-by-Claude and silent to
                    // VoiceOver, which is the §7A.6 failure this whole layer
                    // exists to prevent, so it is spoken (Denver, 2026-07-30).
                    //
                    // The looseness is real and was weighed: on this one
                    // primitive the shared `claudeTerm` covers a placement rather
                    // than an authorship, so "Reference, from Claude" says
                    // slightly more than is true of the words on the page. A
                    // second wording for that distinction was rejected — see
                    // `claudeTerm`. One phrase every primitive uses beats two the
                    // listener has to keep apart.
                    label: label("Reference",
                                 fromClaude: node.author == .claude,
                                 promoted: false,
                                 connectedBy: connections[node.id]),
                    value: CanvasRenderer.placeholderLabel(for: reference),
                    contentFrame: frame))
            }
        }

        return rowOrdered(elements)
    }

    /// Reading order: rows top to bottom, then left to right within a row.
    ///
    /// The bands are found by PROXIMITY — the gap between one card and the next
    /// card down — and deliberately not by `(y / rowBand).rounded(.down)`, which
    /// looks like the same thing and is not. A fixed grid measures each card's
    /// distance from the ORIGIN, so whether two cards read as one row depends on
    /// where the canvas's cell boundaries happen to fall between them: two cards
    /// 2pt apart straddling a boundary read as two rows, while two cards a whole
    /// band apart inside one cell read as one. On a surface where the writer
    /// places cards freely that is not a corner case, and it makes the stated
    /// invariant — roughly level reads as one row — true only by luck.
    ///
    /// One consequence is worth stating rather than discovering: proximity bands
    /// CHAIN. A staircase of cards each half a band below the last is one row, of
    /// any length. That is the honest reading of "these are all roughly level
    /// with their neighbours", it is what a fixed grid gets wrong in the other
    /// direction, and a writer who lays a canvas out that way has not drawn rows.
    ///
    /// It orders ELEMENTS rather than nodes, so a region takes its place in the
    /// reading order by where it sits, not by a rule that says "regions first".
    /// The two agree in the ordinary case and the general one is the honest one:
    /// a region drawn low on the canvas should not be announced before the cards
    /// above it.
    private static func rowOrdered(_ elements: [CanvasAXElement]) -> [CanvasAXElement] {
        // Top to bottom first, so "the gap to the previous card" is a gap
        // between vertical neighbours. Ties break on x and then on id so the
        // walk below is deterministic: `unorderedNodes` is in hash order.
        let byHeight = elements.sorted { a, b in
            let (p, q) = (a.contentFrame.origin, b.contentFrame.origin)
            if p.y != q.y { return p.y < q.y }
            if p.x != q.x { return p.x < q.x }
            return a.id.raw < b.id.raw
        }

        var band = 0
        var previousY: CGFloat?
        let banded: [(band: Int, element: CanvasAXElement)] = byHeight.map { element in
            let y = element.contentFrame.origin.y
            if let previousY, y - previousY > rowBand { band += 1 }
            previousY = y
            return (band, element)
        }

        return banded
            .sorted { a, b in
                if a.band != b.band { return a.band < b.band }
                let (p, q) = (a.element.contentFrame.origin, b.element.contentFrame.origin)
                if p.x != q.x { return p.x < q.x }
                return a.element.id.raw < b.element.id.raw
            }
            .map(\.element)
    }

    /// What the canvas itself says when focused, before its children are walked.
    ///
    /// `scene.count` and `scene.lineCount`, never `scene.nodes.count` or
    /// `scene.lines.count` — this is read from `body`, and both ordered
    /// accessors sort their whole collection with a `String` comparison in the
    /// predicate to hand back a number the dictionary already knows. That is the
    /// original regression, in two id spaces.
    ///
    /// **The lines are counted here because they are elements nowhere.** Without
    /// this, a canvas the writer has drawn twenty relationships on announces
    /// itself identically to one with none, and the only trace of the line layer
    /// is inside the labels of whichever cards the user happens to walk to.
    ///
    /// It is the WHOLE count, collapsed regions included — which matches
    /// `scene.count` right above it, since that has always counted residents of
    /// a collapsed region too. The summary says what is on the canvas; a
    /// collapsed region says separately what it is holding.
    static func summary(scene: CanvasScene) -> String {
        let count = scene.count
        guard count > 0 else { return emptyCanvasValue }
        let items = "\(count) \(count == 1 ? "item" : "items")"
        let lines = scene.lineCount
        guard lines > 0 else { return items }
        return "\(items), \(lines) \(lines == 1 ? "line" : "lines")"
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
