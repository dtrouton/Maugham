import Foundation
import MaughamCore

/// One thing pinned beside a document, resolved to something renderable.
///
/// **The `id` is the underlying id or path, never a minted one**, and that is
/// what makes the list stable across a recomputation: a pane holds a selection
/// through a manifest change, and `PinnedReferences.pinned` is a pure function
/// its callers are expected to re-run rather than cache. A minted id would make
/// two runs over an unchanged project unequal, and the selection would drop on
/// every keystroke that moved the manifest.
///
/// **`title` is always a real title.** A pin whose title could not be resolved
/// is not a pin — see `PinnedReferences.pinned`'s dangling rule.
struct PinnedReference: Identifiable, Equatable, Sendable {

    /// **A ROUTING vocabulary, and deliberately coarser than what the canvas
    /// draws with.** Each case answers one question its readers actually ask:
    /// which surface renders this (the References pane's assistant column) and
    /// which MCP tool fetches it (the compiler's context listing). A research
    /// note, a PDF and a research photograph are one case here because the
    /// answer for all three is the same — `read_document`'s research arm and
    /// the research preview — while a palette card has its own read tool and
    /// its own read view, so it is its own case.
    ///
    /// A reader wanting a finer *glyph* has `CanvasItemIndex` in hand already
    /// (it is what built this list) and should ask it, exactly as the canvas
    /// does. This enum growing an arm per asset kind would be the fifth
    /// spelling of the research glyph table that `CanvasItemKind` already
    /// records as a known duplication.
    enum Kind: Equatable, Sendable {
        /// Anything the project's research tree holds that is not a palette
        /// card — a note, a PDF, a recording, a link, a group, a research
        /// photograph.
        case research(itemId: String)
        /// A `.document` asset living inside the palette group. **Told apart by
        /// POSITION, through `CanvasItemIndex`** — nothing on the item itself
        /// says so, so this is never derivable from the id.
        case palette(cardId: String)
        /// A picture the canvas ingested into `canvas_assets/` and owns
        /// (`CanvasItemReference.owned`). Project-relative path, which is both
        /// its identity here and what the thumbnail cache is keyed on
        /// (tripwire 22).
        case photo(path: String)
        /// A loose thought typed onto the canvas. Its words live in
        /// `canvas.md`, never in the manifest.
        case scrap(nodeId: String)
    }

    let id: String
    let kind: Kind
    let title: String
}

/// **The union**: the research a writer LINKED to a document, plus the cards
/// they clustered for it on the planning canvas — the two ways something
/// becomes context for a piece — resolved to one ordered, deduplicated list.
///
/// Three readers consume it and none of them may re-derive it: the References
/// pane and its assistant column, and the author compiler's context listing.
/// That is the whole reason it is a pure function in the model layer rather
/// than a computed property on a view.
///
/// **It reaches for nothing.** The scene arrives as a value, the manifest as a
/// `CanvasItemIndex`, the scrap words as a dictionary. `CompilerEnvironment`'s
/// stated reason applies unchanged: a function that named a `ProjectStore`
/// could not be driven with no project on disk, and a manifest walk reached for
/// from a `body` is tripwire 4.
enum PinnedReferences {

    /// How much of a scrap's first line a pin shows before it elides.
    ///
    /// A character cap and not a width, because this list has three readers
    /// with three different type sizes and one of them is a *prompt*, which has
    /// no width at all. The canvas's own truncation (`CanvasRenderer.truncated`)
    /// is width-based and stays that way — it draws into a card of known size.
    static let scrapTitleCharacterLimit = 80

    /// - Parameters:
    ///   - docId: the document's id, which is the same string a region or a
    ///     card carries as its `boundPieceID` (`CanvasPieceTitles.over` builds
    ///     its table from `StructureItem.id`).
    ///   - links: `StructureItem.links` — research item ids the writer linked.
    ///   - scene: nil when the project's Plan side has never been opened, which
    ///     is a real state and not an error; the links still pin.
    ///   - scraps: `CanvasModel.scraps`. Required rather than defaulted: a
    ///     caller who forgot it would get a list of cards all reading
    ///     "Empty scrap" with nothing red.
    ///   - items: `CanvasItemIndex.over(research:)` — the canvas's own manifest
    ///     index, which answers both the title and the research-vs-palette
    ///     question. Built once per manifest change at the composition root.
    static func pinned(forDocId docId: String,
                       links: [String]?,
                       scene: CanvasScene?,
                       scraps: [CanvasNodeID: String],
                       items: CanvasItemIndex) -> [PinnedReference] {

        var out: [PinnedReference] = []
        var seen = Set<String>()

        // Deduplication is on the pin's id, so an item that is both linked and
        // on the canvas resolves to the same pin twice and lands once — in the
        // LINKED position. The two sources are two ways of saying one thing
        // about one object, and neither wins: they produce identical values.
        func take(_ pin: PinnedReference?) {
            guard let pin, seen.insert(pin.id).inserted else { return }
            out.append(pin)
        }

        // Manifest order, which is the writer's order — never sorted. A sort
        // applied to the whole list would put the canvas set among the links
        // and lose the distinction the pane draws on.
        for id in links ?? [] { take(projectPin(id, in: items)) }

        guard let scene else { return out }

        // `RegionBinding.references` and never a walk of our own: residents
        // only, unioned across every region bound to this piece, plus the cards
        // bound to it themselves. Those two rules have already been re-derived
        // wrongly once, as `home ∪ appearances`, by a reader that read
        // `bound_piece_id` raw.
        let clustered = RegionBinding.references(forPiece: docId, in: scene)
            .compactMap { pin(for: $0, in: scene, scraps: scraps, items: items) }
            .sorted { a, b in
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return order == .orderedAscending }
                // Not decoration: every empty scrap answers with the same
                // placeholder, so title alone would leave a `Set`'s iteration
                // order deciding the list — a different order on every launch.
                // `RegionInspector.rows` takes the identical discipline.
                return a.id < b.id
            }
        for pin in clustered { take(pin) }
        return out
    }

    // MARK: - Resolving one node

    private static func pin(for id: CanvasNodeID,
                            in scene: CanvasScene,
                            scraps: [CanvasNodeID: String],
                            items: CanvasItemIndex) -> PinnedReference? {
        guard let node = scene.node(id) else { return nil }
        switch node.kind {
        case .scrap:
            return PinnedReference(id: id.raw,
                                   kind: .scrap(nodeId: id.raw),
                                   title: scrapTitle(scraps[id] ?? ""))
        case .item(.owned(let path)):
            // Needs no manifest — it exists nowhere else in the project — so it
            // resolves in full against an empty index, and is never dropped.
            return PinnedReference(id: path,
                                   kind: .photo(path: path),
                                   title: CanvasItemFacts.ownedTitle)
        case .item(.project(let referenceID)):
            return projectPin(referenceID, in: items)
        }
    }

    /// **A reference the manifest cannot resolve is DROPPED**, whether it
    /// arrived as a link or as a card. The writer deleted the note; a row
    /// reading `res-3f2a` is a code, and a reference list has nothing to show.
    ///
    /// This is deliberately not `CanvasItemFacts.resolve`, whose missing arm
    /// answers `missingTitle` — *"No longer in the project."* — instead. That is
    /// the right answer for the CANVAS, which keeps drawing a card the writer
    /// placed and owes them a reason it is blank. A list the writer never
    /// arranged owes them nothing but its true contents.
    private static func projectPin(_ id: String, in items: CanvasItemIndex) -> PinnedReference? {
        guard let entry = items.entry(of: id) else { return nil }
        return PinnedReference(id: id,
                               kind: entry.kind == .paletteCard
                                   ? .palette(cardId: id)
                                   : .research(itemId: id),
                               title: entry.title)
    }

    private static func scrapTitle(_ text: String) -> String {
        let line = ScrapText.firstLine(of: text)
        guard !line.isEmpty else { return CanvasAccessibility.emptyScrapValue }
        guard line.count > scrapTitleCharacterLimit else { return line }
        return String(line.prefix(scrapTitleCharacterLimit))
            .trimmingCharacters(in: .whitespaces) + CanvasRenderer.ellipsis
    }
}
