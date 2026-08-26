import AppKit
import CoreGraphics
import SwiftUI
import MaughamCore

/// **The shelf** (M2 spec §6.2, ⌘⌥E): what this piece is pinned to — the
/// research the writer linked to it, unioned with the cards they clustered for
/// it on the planning canvas — as a thumbnail, a kind glyph and a title.
///
/// *A shelf, not a browser.* It offers no search, no tree and no filter: the
/// list is short by construction, and a writer who wants to browse research has
/// ⌘⌥R two segments away. What one click does is promote a pin into the
/// assistant column beside the prose.
///
/// **The sections arrive already built.** `sections(for:in:)` is pure and the
/// shelf comes from `PinnedReferenceResolver` — a manifest walk, a canvas read
/// and a link lookup are all things a `body` may not do (tripwire 4), and the
/// mounting site does them in a `.task`. The GROUPING is the projection's too
/// (spec §2.2): this view draws the headings and never decides them.
struct ReferencesPane: View {

    /// One shelf row: what to draw, resolved once.
    struct Row: Identifiable, Equatable {
        let reference: PinnedReference
        /// An SF Symbol name, taken from `CanvasItemFacts` so the shelf and the
        /// canvas name a research kind identically.
        let glyph: String
        /// **Project-relative**, which is what `CanvasThumbnails` takes
        /// (tripwire 22 — the cache is keyed on a path and never an id). Nil
        /// for everything that is not a picture; a path here for a note would
        /// queue a decode that can only fail, and failures are memoised.
        let thumbnailPath: String?

        var id: String { reference.id }
    }

    /// One run of rows under an optional heading — a `PinnedShelf.sections`
    /// element, resolved for drawing.
    ///
    /// The projection decides the grouping and this type only carries it: a
    /// pane that re-derived "which region did this come from" would be the
    /// second answer to a question `PinnedReferences.pinned` already answers,
    /// and the two would disagree the first time a region was promoted.
    struct Section: Identifiable, Equatable {

        /// The writer's own word for the group — a bound region's label (or
        /// `Promotion.regionTitle`'s fallback), or `PinnedShelf.looseCardsTitle`.
        /// **Nil draws no heading**: the research at the top of the shelf is not
        /// a group the writer named, and a heading invented for it would claim a
        /// distinction the projection deliberately does not draw.
        let title: String?
        let rows: [Row]

        /// **Derived from the section's contents, never minted.**
        ///
        /// `PinnedReferenceResolver.pins` is a pure function this pane's host
        /// re-runs on every manifest change and every structural canvas change,
        /// so a `UUID()` here would make two runs over an unchanged project
        /// unequal and `ForEach` would tear the shelf down and rebuild it under
        /// the writer's cursor — the argument `PinnedReference.id`'s own doc
        /// comment makes for the rows, one level up.
        ///
        /// The title alone would not do: two regions the writer labelled
        /// identically are a real state, which is why `PinnedReferences`' own
        /// region ordering breaks that tie on the region's id. The first row's
        /// id separates them, and *can*, because the shelf's sections are
        /// disjoint — deduplication happened at assembly, so no pin appears in
        /// two sections.
        var id: String { (title ?? "") + "\u{1}" + (rows.first?.id ?? "") }
    }

    /// **A scrap is not an item and has no `CanvasItemKind`** — it is loose
    /// words the writer typed on the board, and its text lives in `canvas.md`
    /// rather than in the manifest. So it is the one glyph this file names, and
    /// it is deliberately outside the item table:
    /// `test_aScrapRowUsesTheScrapGlyphAndNeverAnItemKind` asserts it is not any
    /// item kind's, because a shared glyph would make the two unreadable apart.
    static let scrapGlyph = "quote.opening"

    static let emptyTitle = "Nothing pinned yet."

    /// **Both ways in, and naming only one would be worse than naming neither**
    /// — it would read as the only way.
    ///
    /// It says *add* and never *link*. Linking is a **Novel** chapter's spelling
    /// of adding research and nothing else's: `ResearchScope.researchRouting`
    /// answers `.sharedPlusLink` for a novel, `.pieceFolder` for a Collection's
    /// loose piece and `.sharedOnly` for a short story or a screenplay, and only
    /// the first writes a link record. Research reaches this shelf from all
    /// three since §2.1, so an instruction to link would send every writer but
    /// the novelist after a command their project type does not offer. "Add
    /// research to this document" is what all three of them actually do.
    static let emptyDescription =
        "Add research to this document, or cluster its cards inside a region on "
        + "the planning canvas."

    /// **Author and Review, as of Denver's 2026-08-14 ruling (spec §9).**
    /// `.references` stays reachable from every persona, but the assistant
    /// column it promotes into presents only where
    /// `Persona.studiesPinnedReferences` is true (`AssistantColumn.isPresented`)
    /// — Author and Review now, Plan and Publish still not. Rather than a
    /// dead click — a row that looks pressable and silently does nothing — a
    /// non-studying mount renders every row inert and says where studying
    /// happens instead.
    static let nonStudyingFooter = "Studying a pin opens here in Author or Review."

    /// How many pixels a row's thumbnail is decoded at. The drawn box is
    /// `thumbnailSize` points; `CanvasThumbnails.assumedPixelScale` is the
    /// points→pixels allowance, and the bucket ladder snaps it up from there.
    static let thumbnailSize: CGFloat = 32

    let sections: [Section]
    let projectRoot: URL
    /// **Whether a row's click can reach the assistant column.** The same
    /// predicate as `AssistantColumn.isPresented`'s persona veto
    /// (`Persona.studiesPinnedReferences`) — Author and Review now, Plan and
    /// Publish still not — so a Plan or Publish mount draws the same rows
    /// inert rather than a click that promotes into a column nobody sees.
    let persona: Persona
    @Bindable var assistant: AssistantColumnModel

    private var isInteractive: Bool { persona.studiesPinnedReferences }

    /// Every row on the shelf, in section order.
    ///
    /// The thumbnail pass and the empty state are about the shelf's CONTENTS,
    /// which the sections partition rather than change. One flatMap over a list
    /// that is short by construction is not tripwire 4's per-row manifest walk —
    /// what that tripwire forbids is work *inside* a row's body, and the work
    /// this shelf could get wrong that way (a manifest walk, a canvas read)
    /// happens in the host's `.task` and arrives here already done.
    private var allRows: [Row] { sections.flatMap(\.rows) }

    /// Thumbnails decoded for this shelf, by project-relative path.
    ///
    /// **The cache is `CanvasThumbnails` and the instance is this pane's.**
    /// Reusing the TYPE is what the contract asks for — one `CGImageSource`
    /// downsampling path, one path-keyed bound — and reusing an INSTANCE is not
    /// available: the canvas's lives in `CanvasView`'s `@State`, which is a
    /// different column and often not mounted at all. Two caches over the same
    /// files cost bytes; two decoders would cost a second answer about what a
    /// picture looks like.
    @State private var thumbnails = CanvasThumbnails()
    @State private var images: [String: CGImage] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if allRows.isEmpty {
                    // Tripwire 15: without the full frame chain SwiftUI sizes to
                    // the intrinsic content and the enclosing stack collapses,
                    // floating the pane's picker to the window's centre.
                    ContentUnavailableView(
                        Self.emptyTitle,
                        systemImage: "pin",
                        description: Text(Self.emptyDescription))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // **A `ScrollView` of `Button`s and not a `List`, and the
                    // reason is not styling.** These rows are a shelf of chunky
                    // picture tiles rather than a browser's outline, and a
                    // `List` renders them as an `AXOutline` whose row elements
                    // expose no role at all — measured 2026-08-05: the mounted
                    // shelf produced `AXGroup > AXScrollArea > AXOutline >
                    // (three roleless children)` and a click test could not find
                    // a single button to press. That is the same family as
                    // tripwire 9 (hit-testing inside a `List` is unreliable),
                    // and here it also makes the behaviour untestable, which is
                    // worse: the test skips and the suite reads green.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                if let title = section.title {
                                    sectionHeader(title)
                                }
                                ForEach(section.rows) { row in
                                    rowView(row)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // **Outside Author and Review the rows above are inert** — see
            // `isInteractive` — and this line is the whole of what replaces
            // the click: nothing on the shelf is a dead control.
            if !isInteractive {
                Divider()
                Text(Self.nonStudyingFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Decoding happens HERE and never in a row's body: `resolved` is a
        // dictionary lookup by contract and `servicePending` is `async` so that
        // it cannot be called from a draw pass. Re-run when the shelf's contents
        // change, which is the only time a new picture can be wanted.
        .task(id: allRows.map(\.id).joined(separator: "\u{1}")) {
            await loadThumbnails()
        }
    }

    /// **A caption over a titled run** — the weight the window's other lists
    /// give their section headers, so the shelf reads as one of them rather than
    /// as a form. It is a plain `Text` and never a control: a section is not a
    /// thing to study, and nothing on this shelf may look pressable without
    /// being so (the same rule the non-studying footer exists to keep).
    ///
    /// **The header trait is load-bearing, not decoration.** Caption grey says
    /// "these belong together" to a writer who looks and to nobody else; with
    /// `.isHeader` the caption reads as a heading and a listener can move
    /// section by section, instead of hearing the flat shelf §2.2 exists to
    /// end. The same argument the canvas makes for `CanvasAccessibility`'s
    /// spoken term, where a lean is what is inaudible.
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }

    /// One row, interactive or not. **Never a disabled `Button`** — a disabled
    /// control still reads to VoiceOver as "button, dimmed", which restates the
    /// affordance the footer just took away; a plain row reads as what it is.
    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let highlighted = assistant.isStudying(row.reference)
        if isInteractive {
            Button {
                assistant.study(row.reference)
            } label: {
                rowLabel(row)
            }
            .buttonStyle(.plain)
            .background(highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        } else {
            rowLabel(row)
                .background(highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        }
    }

    @ViewBuilder
    private func rowLabel(_ row: Row) -> some View {
        HStack(spacing: 8) {
            thumbnail(row)
            Text(row.reference.title)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityLabel(row.reference.title)
    }

    /// The picture if one has landed, else the kind glyph. **Both occupy the
    /// same box**, so a thumbnail arriving does not reflow the shelf under the
    /// writer's cursor.
    @ViewBuilder
    private func thumbnail(_ row: Row) -> some View {
        ZStack {
            if let path = row.thumbnailPath, let image = images[path] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: row.glyph)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
        .clipped()
    }

    private func loadThumbnails() async {
        let wanted = allRows.compactMap(\.thumbnailPath)
        guard !wanted.isEmpty else {
            if !images.isEmpty { images = [:] }
            return
        }
        let pixels = Self.thumbnailSize * CanvasThumbnails.assumedPixelScale
        // Ask once to RECORD the misses, drain them off the frame path, then ask
        // again for what landed. `resolved` never decodes — that split is the
        // whole design of the cache.
        for path in wanted { _ = thumbnails.resolved(path, in: projectRoot, fitting: pixels) }
        await thumbnails.servicePending()
        var resolved: [String: CGImage] = [:]
        for path in wanted {
            if let image = thumbnails.resolved(path, in: projectRoot, fitting: pixels) {
                resolved[path] = image
            }
        }
        images = resolved
    }

    // MARK: - Rows, as a pure derivation

    /// Resolve each pin's glyph and thumbnail path **through
    /// `CanvasItemFacts`**, which is the canvas's own table.
    ///
    /// Not a switch of this file's own: `CanvasItemKind` already records that
    /// the research glyph table has been spelled four times, and a fifth here
    /// would drift the day someone gave PDFs a different symbol on the board.
    /// The TITLE is the pin's own — `PinnedReferences.pinned` guarantees a real
    /// one and drops anything it could not resolve, so the shelf never has to
    /// decide what to call something.
    static func rows(for pins: [PinnedReference], in items: CanvasItemIndex) -> [Row] {
        pins.map { pin in
            switch pin.kind {
            // One arm for both, because the index tells them apart already: a
            // palette card IS a research item, distinguished by position, and
            // `CanvasItemFacts` reads that off the same entry.
            case .research(let id), .palette(let id):
                let facts = CanvasItemFacts.resolve(.project(id: id), in: items)
                return Row(reference: pin, glyph: facts.glyph,
                           thumbnailPath: facts.thumbnailPath)
            case .photo(let path):
                let facts = CanvasItemFacts.resolve(.owned(path: path), in: items)
                return Row(reference: pin, glyph: facts.glyph,
                           thumbnailPath: facts.thumbnailPath)
            case .scrap:
                return Row(reference: pin, glyph: scrapGlyph, thumbnailPath: nil)
            }
        }
    }

    /// The shelf resolved for drawing: each section's title carried across
    /// untouched, its references through `rows(for:in:)`.
    ///
    /// A wrapper and not a second derivation — the grouping is
    /// `PinnedReferences.pinned`'s and the glyphs are `CanvasItemFacts`', and
    /// this function's whole job is to put one inside the other.
    static func sections(for shelf: PinnedShelf, in items: CanvasItemIndex) -> [Section] {
        shelf.sections.map {
            Section(title: $0.title, rows: rows(for: $0.references, in: items))
        }
    }
}

// MARK: - Assembling the shelf

/// **Where the shelf's contents come from**, kept off `ReferencesPane` so that
/// view stays a pure function of its rows and can be mounted in a test with no
/// project on disk.
///
/// The assembly is `PinnedReferenceResolver`'s — one spelling shared with the
/// compiler's context listing, so the writer's shelf and Claude's briefing
/// cannot disagree about what this piece is pinned to.
struct ReferencesPaneHost: View {
    let store: ProjectStore
    let projectURL: URL
    let docId: String
    let persona: Persona
    @Bindable var assistant: AssistantColumnModel

    @State private var sections: [ReferencesPane.Section] = []

    /// **Three signals, and each is needed** — the same argument
    /// `CanvasItemIndex.fingerprint` makes for its own two-part key:
    ///
    /// - the **document**, obviously: the shelf is per-piece;
    /// - the **manifest's `modified`**, because linking research, renaming a
    ///   note or deleting one changes what is pinned and moves nothing on the
    ///   canvas;
    /// - the canvas's **structural** revision, because clustering a card into a
    ///   bound region changes what is pinned and touches no manifest. It is
    ///   `sceneRevision` and never `CanvasView.revision`, which is the per-frame
    ///   redraw counter (tripwire 30) — keying a manifest walk on that would run
    ///   it at 120 Hz for the length of every drag.
    ///
    /// Read as an `Equatable` value so `.task(id:)` re-runs on a change and on
    /// nothing else.
    private struct ReloadKey: Equatable {
        let docId: String
        let manifestModified: Date
        let sceneRevision: Int
    }

    private var reloadKey: ReloadKey {
        ReloadKey(docId: docId,
                  manifestModified: store.manifest.modified,
                  sceneRevision: store.liveCanvas?.sceneRevision ?? 0)
    }

    var body: some View {
        ReferencesPane(sections: sections, projectRoot: projectURL, persona: persona,
                       assistant: assistant)
            .task(id: reloadKey) {
                let shelf = PinnedReferenceResolver.pins(
                    forDocId: docId, store: store, projectRoot: projectURL)
                sections = ReferencesPane.sections(
                    for: shelf,
                    in: CanvasItemIndex.over(research: store.manifest.research))
            }
    }
}
