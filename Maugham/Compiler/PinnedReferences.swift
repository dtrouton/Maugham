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

/// One run of pinned references under an optional heading — a `PinnedShelf`'s
/// element.
///
/// **The title is the writer's own word for the group**, never a category name
/// invented here: a region's label, or `Promotion.regionTitle`'s fallback while
/// the region is still unlabelled. `nil` means the run needs no heading — the
/// research at the top of the shelf, which is one undifferentiated list whether
/// the writer linked it or their project type contains it.
struct PinnedSection: Equatable, Sendable {
    let title: String?
    let references: [PinnedReference]
}

/// **What a document is pinned to, grouped the way the writer arranged it.**
///
/// The references-shelf design's §2.2: the projection used to dissolve the
/// canvas into one alphabetical list, so a writer who had put six cards in
/// reading order under a titled region got six titles in dictionary order with
/// nothing saying they belonged together. A shelf keeps the arrangement, and
/// each reader takes what it can use — the References pane draws the headings,
/// the compiler's context listing emits them as `##` lines, and a reader
/// wanting a plain list reads `references`.
struct PinnedShelf: Equatable, Sendable {

    /// The heading over cards the writer tied to the piece ITSELF, which belong
    /// to no region of its. One fixed string rather than a spelling per reader:
    /// the pane draws this heading and the compiler's briefing emits it, and a
    /// writer reading both must not find two words for one group.
    static let looseCardsTitle = "Cards"

    /// In the order the shelf reads: the research, then a section per bound
    /// region, then the loose cards. Never empty of content — a section with
    /// nothing in it is omitted rather than drawn as bare chrome.
    let sections: [PinnedSection]

    /// The flat projection in section order — the value `pinned` returned before
    /// it was sectioned, and what the compiler's context listing and every other
    /// list-shaped reader takes.
    ///
    /// **The deduplication happened at assembly**, on the pin's id with the
    /// first section winning, so the sections are disjoint and this
    /// concatenation cannot reintroduce a duplicate. Deduplicating a second
    /// time here would not make the shelf safer — a duplicate would still be
    /// drawn twice by the pane, which reads `sections` — it would only hide a
    /// broken assembly from the one reader that could still see it.
    var references: [PinnedReference] { sections.flatMap(\.references) }
}

/// **The three sources**: the research a writer LINKED to a document, the
/// research their project type DERIVES for it, and the cards they clustered for
/// it on the planning canvas — the three ways something becomes context for a
/// piece — resolved to one ordered, deduplicated, sectioned `PinnedShelf`.
///
/// The derived source is the references-shelf design's §2.1. `linkedResearchIds`
/// is a *Novel* chapter's record only: a Collection routes a loose piece's
/// research by containment and a single-document project by derivation, and
/// neither writes a link. A projection reading links alone is complete for
/// Novels and silently short for every other project type — in all three of its
/// readers at once.
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
    ///   - links: `ProjectStore.linkedResearchIds(forDocumentId:)` — research
    ///     item ids the writer linked. **Not** `StructureItem.links`, which is
    ///     `InspectorLinksSection`'s unrelated document-to-document backlink
    ///     field; `linkResearch(researchId:toDocumentId:)` is the only write
    ///     path into `linkedResearchIds`, and it never touches `.links`
    ///     (found wiring this into the compiler, M2 Plan 2 Task 3 — the two
    ///     fields share no reader or writer despite the near-identical name).
    ///   - derived: `ProjectStore.derivedResearchItems(forDocumentId:)`'s ids —
    ///     the research the project TYPE associates with this document with no
    ///     link record (§2.1). Required rather than defaulted, for the reason
    ///     `scraps` is: a caller who forgot it would short every Collection and
    ///     every single-document project to their links — which is to say, to
    ///     nothing — with nothing red.
    ///   - scene: nil when the project's Plan side has never been opened, which
    ///     is a real state and not an error; the research still pins.
    ///   - scraps: `CanvasModel.scraps`. Required rather than defaulted: a
    ///     caller who forgot it would get a list of cards all reading
    ///     "Empty scrap" with nothing red.
    ///   - items: `CanvasItemIndex.over(research:)` — the canvas's own manifest
    ///     index, which answers both the title and the research-vs-palette
    ///     question. Built once per manifest change at the composition root.
    static func pinned(forDocId docId: String,
                       links: [String]?,
                       derived: [String],
                       scene: CanvasScene?,
                       scraps: [CanvasNodeID: String],
                       items: CanvasItemIndex) -> PinnedShelf {

        var sections: [PinnedSection] = []
        var out: [PinnedReference] = []
        var seen = Set<String>()

        // Deduplication is on the pin's id and spans the whole shelf, so an item
        // that is linked, derived AND on the canvas resolves to the same pin
        // three times and lands once — in the FIRST section that claims it. The
        // sources are several ways of saying one thing about one object, and
        // none wins on merit: they produce identical values, so the earliest
        // position is the only thing to decide.
        func take(_ pin: PinnedReference?) {
            guard let pin, seen.insert(pin.id).inserted else { return }
            out.append(pin)
        }

        /// Closes the section being accumulated. **An empty one is dropped**,
        /// which is what makes "a promoted region whose note was already linked"
        /// and "no loose cards" both come out as an absent heading rather than a
        /// heading over nothing.
        func close(titled title: String?) {
            defer { out = [] }
            guard !out.isEmpty else { return }
            sections.append(PinnedSection(title: title, references: out))
        }

        // Manifest order, which is the writer's order — never sorted, and one
        // untitled run: the shelf does not tell the writer which of their notes
        // arrived by a link and which by containment, because that is a fact
        // about the project type rather than about the note.
        for id in links ?? [] { take(projectPin(id, in: items)) }
        for id in derived { take(projectPin(id, in: items)) }
        close(titled: nil)

        guard let scene else { return PinnedShelf(sections: sections) }

        // **Region by region, and deliberately NOT through
        // `RegionBinding.references`**, whose unioned `Set` is exactly what
        // discards the grouping this shelf exists to keep. Its two rules are
        // still reached and not re-derived: residency through
        // `CanvasMembership.residents` — the same function that projection
        // calls, so a visitor is still cited rather than owned — and a card's
        // own association through its own `boundPieceID` below. The wrong
        // re-derivation that census guards against (`home ∪ appearances`) is
        // unreachable from here for that reason, and
        // `test_aVisitingCardIsNotPinned` is what says so.
        for region in boundRegions(toPiece: docId, in: scene) {
            if let itemID = region.promotedItemID,
               let promoted = projectPin(itemID, in: items) {
                // §2.3. The region BECAME that note; pinning the note beside the
                // cards it was made from is the seventh row Denver saw. A mark
                // naming an item the manifest cannot resolve falls through to
                // the cards instead — the fact is stale and the writer still
                // has the material.
                take(promoted)
            } else {
                for id in Promotion.readingOrder(
                    CanvasMembership.residents(of: region.id, in: scene), in: scene) {
                    take(pin(for: id, in: scene, scraps: scraps, items: items))
                }
            }
            close(titled: Promotion.regionTitle(region))
        }

        // A card the writer tied to the piece ITSELF. `seen` is what keeps one
        // that also lives in a bound region out of here: it belongs to the
        // section that already showed it, and this heading is for what belongs
        // to no region of the piece's.
        let loose = Set(scene.unorderedNodes.filter { $0.boundPieceID == docId }.map(\.id))
        for id in Promotion.readingOrder(loose, in: scene) {
            take(pin(for: id, in: scene, scraps: scraps, items: items))
        }
        close(titled: PinnedShelf.looseCardsTitle)

        return PinnedShelf(sections: sections)
    }

    /// The piece's regions in the order the shelf shows them: by the title the
    /// writer reads, then by id.
    ///
    /// The id tiebreak is not decoration — `unorderedRegions` is a
    /// `Dictionary`'s values, so two identically-labelled regions would
    /// otherwise swap between launches of the same binary. `RegionInspector.rows`
    /// takes the identical discipline.
    private static func boundRegions(toPiece docId: String,
                                     in scene: CanvasScene) -> [CanvasRegion] {
        scene.unorderedRegions
            .filter { $0.boundPieceID == docId }
            .sorted { a, b in
                let order = Promotion.regionTitle(a)
                    .localizedStandardCompare(Promotion.regionTitle(b))
                if order != .orderedSame { return order == .orderedAscending }
                return a.id.raw < b.id.raw
            }
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
