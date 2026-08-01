import Foundation
import MaughamCore

/// What is being promoted.
///
/// **`.scrap` names a NODE, and since 1C-d that node may be an owned item**
/// (spec §6's 2026-07-30 amendment: an owned item node promotes, a referenced
/// one does not). There is deliberately no fourth case for it, and the reason is
/// `CanvasItemReference`'s own — stated there for the kind and true again here:
/// everything this enum reaches wants the two to behave *identically* (the
/// piece precedence in `piece(for:in:)`, the mark written onto
/// `CanvasNode.promotedItemID`, `existingArtifact`'s read of it), and a case of
/// its own would leave every one of those arms looking right while silently
/// ceasing to cover a photograph. The sites that genuinely differ destructure
/// the node's kind, and there are four of them: `targets`, `blockedReason`,
/// `plan` and `PromotionSheetModel.sourceDescription`.
enum PromotionSource: Equatable, Hashable {
    case scrap(CanvasNodeID)
    case region(CanvasRegionID)
    case line(CanvasLineID)

    /// The word a refusal calls this thing — **the writer's word, not the
    /// model's**: a `.scrap` is a *card* on the canvas, and every other sentence
    /// they read says card.
    ///
    /// It exists because `PromotionFailure.emptyBody` said "There is nothing in
    /// this **card** to promote." for an empty REGION. (The other spelling of
    /// the same two words is `PromotedArtifactSection.Subject.noun`, which is a
    /// view's and covers the subjects that mount that SECTION — the two that
    /// have a *pane* was this sentence's own error, corrected in 1C-d: all of
    /// them have a pane, and what `Subject` enumerates is who renders the
    /// promotion section inside one.)
    ///
    /// **"card" survives 1C-d because no sentence built from it can reach an
    /// owned item node**, which is a picture and not a card. The only sentence
    /// this noun composes is `PromotionFailure.emptyBody`'s, and two independent
    /// guards keep a picture away from it: `blockedReason` answers **nil** for an
    /// owned node rather than falling through to the empty-text check, and
    /// `PromotionPerformer.validate` tests the two picture targets for a FILE
    /// rather than for a body. `targets` is a third — an owned node is never
    /// offered a target whose `validate` arm throws `emptyBody` at all.
    /// `PromotionTests.test_noRefusalAnOwnedNodeCanReachCallsItACard` is the
    /// assertion; if a later slice gives a picture a sentence of its own, this
    /// noun is what has to move first.
    ///
    /// **"card" and "picture" are not two words for one thing, and the split is
    /// worth stating once** (1C-d Task 8, review M4). **A card is the NODE** —
    /// the thing on the canvas the writer clicked, which is what
    /// `PromotionFailure.nothingToCopy` ("There is no picture on this card") and
    /// `ItemInspector.promoteFooter` mean, and what makes those sentences exact
    /// rather than sloppy: a card holds a picture, and the two can be spoken of
    /// separately. **A picture is the FILE** — what a promotion copies, which is
    /// why `PromotionSheetModel.sourceDescription` says *This picture* over a
    /// sheet whose whole subject is where that file is going. What this noun
    /// must never do is compose a sentence about an owned node's *words*, which
    /// is `emptyBody`'s, and that is what the two guards above prevent.
    var noun: String {
        switch self {
        case .scrap: return "card"
        case .region: return "region"
        case .line: return "line"
        }
    }
}

/// What it becomes. **This list IS spec §6's table** and must not grow without
/// amending the spec — every entry is a new durable artifact the writer can
/// create, and the whole design rests on that set being small and predictable.
enum PromotionTarget: String, Equatable, Hashable, CaseIterable, Identifiable {
    case researchNote
    case paletteCard
    case intentStatement
    case wikiLink
    /// A copy of an owned item node's file, filed in `research/` (spec §6's
    /// 2026-07-30 amendment — the fourth row of §6's table).
    case researchAsset
    /// The same file, appended to an existing palette card's image well.
    ///
    /// **There is no `.intentStatement` twin of these two, and that is a
    /// ruling rather than an omission**: an intent is prose about how a piece is
    /// written, and a photograph is not a sentence.
    case paletteCardImage

    var id: String { rawValue }

    var writerFacingName: String {
        switch self {
        case .researchNote: return "Research note"
        case .paletteCard: return "Palette card"
        case .intentStatement: return "Craft intent"
        case .wikiLink: return "Wiki-link"
        case .researchAsset: return "Research picture"
        case .paletteCardImage: return "Picture on a palette card"
        }
    }

    /// What KIND of artifact this target produces — nil for the one that
    /// produces no research item at all (`.wikiLink`, whose product is text
    /// inside somebody else's note). It read "the two" while the piece binding
    /// was still on the row.
    ///
    /// **This is what makes a mark checkable.** A mark records an item id and
    /// nothing else, so without a kind on each side every mark resolves for
    /// every updatable target: promote a card to a palette card, promote it
    /// again as a research note, and "Rewrite “Act II fog”" would rename the
    /// palette card's backing file and write raw scrap text over it — swatches,
    /// kind, sensory notes and image references gone, with ⌘Z taking back only
    /// the mark.
    /// **The two 1C-d rows answer differently, and neither answer is a
    /// convenience.** `.researchAsset` really does produce a research item — a
    /// file in `research/` with an id of its own — and it says so, because a
    /// `nil` there would be the 1C-c2 Critical's premise re-established: a mark
    /// naming an image asset would then resolve for `.researchNote` the moment
    /// anyone made either target updatable, and `performResearchNote`'s update
    /// branch renames the backing file and writes plan text over it. That is a
    /// `.png` overwritten with a card's prose. `.paletteCardImage` produces **no
    /// research item at all** — the product is a file inside somebody else's
    /// card, which is `.wikiLink`'s shape exactly — so it is the second nil, and
    /// the palette card's id therefore never reaches `existingArtifact` through
    /// this comparison OR through the mark (`PromotionPerformer` records that
    /// promotion as a *contribution*, never as the mark; see spec §6.3).
    var producedArtifactKind: ArtifactKind? {
        switch self {
        case .researchNote: return .researchNote
        case .paletteCard: return .paletteCard
        case .intentStatement: return .craftIntent
        case .wikiLink: return nil
        case .researchAsset: return .researchAsset
        case .paletteCardImage: return nil
        }
    }

    /// Whether the writer NAMES the artifact this target produces.
    ///
    /// **Two of the four do not, and both were asked anyway.**
    /// `performWikiLink` never reads `plan.title` and neither does
    /// `performCraftIntent` — the intent doc is find-or-create at a fixed title
    /// and the body is appended — so a `Name` field for either showed an
    /// editable box that changed nothing, seeded with the *source note's* title,
    /// and clearing it disabled Promote with "This needs a name." for an act
    /// that names nothing.
    ///
    /// Deliberately not spelled `updatableTargets.contains(self)`, which happens
    /// to be the same set today: one is about whether a second promotion may
    /// rewrite the first artifact, the other about whether the writer types its
    /// name. Joining them would make a later change to one silently move the
    /// other.
    /// **The two picture rows name nothing either.** `createResearchAsset`
    /// titles the item from the file it copies, and appending an image to a
    /// palette card touches no title at all — so a `Name` field on either would
    /// be the editable box that changes nothing this property exists to stop.
    var namesItsArtifact: Bool {
        switch self {
        case .researchNote, .paletteCard: return true
        case .intentStatement, .wikiLink, .researchAsset, .paletteCardImage: return false
        }
    }
}

/// What an item id names, as the MANIFEST says it is now.
///
/// **Now, rather than at the moment the mark was written** — which is why this
/// lives on the index rather than beside `promotedItemID` in the sidecar. A card
/// promoted to a palette card and later converted, moved out of the palette
/// group or given a craft-intent role answers with what it *is*, and a stored
/// target would answer with what it was.
enum ArtifactKind: Equatable, Hashable {
    case researchNote
    case paletteCard
    case craftIntent
    /// A research item that is a FILE rather than prose — the picture
    /// `.researchAsset` produces, and the PDFs and recordings that were already
    /// in `research/` before any of this.
    ///
    /// **Added in 1C-d because a promotion can produce one now, and until then
    /// every one of these answered `.researchNote`.** That was harmless while no
    /// target produced a file: nothing could mark a card with an asset's id. It
    /// stops being harmless the moment `.researchAsset` exists — a mark naming a
    /// `.png` matching the `.researchNote` row is `performResearchNote`'s update
    /// branch renaming that file and writing a card's prose into it, which is
    /// the 1C-c2 Critical in a new extension. `refuseIfNotAResearchNote` is the
    /// second reader and refuses on it too.
    case researchAsset
}

/// New artifact, or rewrite the one this source produced last time.
///
/// **Neither is a default, and that is the ruling** (spec §6.1, 2026-07-28).
/// "Always update" eats edits the writer made in `research/`; "always new"
/// leaves `The falls at night 2`, `… 3` and two orphans nobody asked for. The
/// choice is one sentence of preview, which is what §6.1 already requires of
/// everything else here.
enum PromotionMode: Equatable, Hashable, Identifiable {
    case new
    case update(itemID: String, title: String)

    var id: String {
        switch self {
        case .new: return "new"
        case .update(let itemID, _): return "update:\(itemID)"
        }
    }
}

/// What promoting will throw away. Promotion is ALLOWED to be lossy and that is
/// a feature (§6.1) — the spatial work was thinking; it earned its keep by
/// producing the artifact. Scapple → Scrivener keeps notes and drops
/// connections, deliberately. The writer is told which, in the preview.
enum PromotionDiscard: Equatable, Hashable {
    case lines
    case layout
    /// The pictures a region holds, on the rows that cannot take them (1C-d
    /// Task 12a). **Conditional, unlike the two above** — a region's lines and
    /// layout are always dropped, and its pictures are dropped only where the
    /// artifact has nowhere to put one: a research note is prose, and a palette
    /// card being REWRITTEN keeps the image well it already has
    /// (`PromotionPerformer.performPaletteCard`'s update branch is about the
    /// prose and nothing else). It is a discard rather than a second notice
    /// because §6.1 already has one machine for "promotion is allowed to be
    /// lossy and the writer is told which parts", and a region holding a
    /// photograph that silently does not travel is exactly what that machine is
    /// for.
    case pictures
}

/// The specifics of an OWNED item node's promotion: which node, which file, and
/// — on the palette row — which card the file is appended to.
///
/// **One value rather than three optionals on the plan**, so the three facts
/// cannot be assembled half-way: a plan carrying a path and no node is not a
/// state the performer should have to have an opinion about.
///
/// **It carries the path so the performer never goes back to the scene for it.**
/// A plan is a snapshot — `PromotionPerformer` re-reads the manifest deliberately
/// (a piece can go stale, an artifact can change kind) but the file this
/// promotion COPIES is the one the writer previewed, and reading `model.scene`
/// at Commit would quietly promote whatever the node points at by then.
struct PromotedPicture: Equatable, Hashable {
    let node: CanvasNodeID
    /// **PROJECT-RELATIVE** — `CanvasItemReference.owned(path:)`'s own string,
    /// carried across unchanged. Never absolute and never a `file://` URL; see
    /// that case's doc comment for what each of those breaks.
    let assetPath: String
    /// The palette card the picture is appended to, for `.paletteCardImage` and
    /// **nil for `.researchAsset`** — which files a copy under `research/` and
    /// has no existing artifact to be appended to.
    ///
    /// **Nil on the REGION's palette row too, and for a third reason** (1C-d
    /// Task 12a): the card that picture is going onto is the one this plan
    /// produces, which on a `.new` promotion does not exist yet and has no id to
    /// carry. `PromotionPerformer.performPaletteCard` appends to the card it
    /// just created or resolved, so the id is never guessed at here.
    let paletteCardID: String?
}

/// An offer to link an already-promoted member to the artifact being produced.
/// An OFFER — see `PromotionPlan.linksAccepted`.
struct PromotionLinkOffer: Equatable, Hashable, Identifiable {
    let node: CanvasNodeID
    /// The member's own artifact. Only promoted members can be offered: a link
    /// into a scrap has nowhere to be written.
    let itemID: String
    let title: String
    var id: CanvasNodeID { node }
}

/// The one durable write a line promotion makes.
struct WikiLinkWrite: Equatable {
    let intoNode: CanvasNodeID
    let intoItemID: String
    /// `[[Artifact title]] — the line's name`. The link names the ARTIFACT and
    /// never the card's first line: `[[X]]` resolves against the manifest, and a
    /// scrap is not in it.
    let linkText: String

    /// A blank line before, a newline after — so appending twice never runs two
    /// links together, and a note that did not end in a newline still parses.
    var appendedText: String { "\n\n" + linkText + "\n" }
}

/// Item id → what it is called and what it IS, for every research item in the
/// project.
///
/// **This exists because the sidecar cannot validate a mark and never could.**
/// `CanvasNode.promotedItemID` is written by a promotion and read much later; a
/// writer who deletes the note leaves an id that resolves to nothing. Passing an
/// index rather than a `ProjectStore` keeps this whole file pure and testable,
/// and means the manifest is walked ONCE, when the sheet opens, rather than per
/// query.
///
/// **It carries a kind as well as a title, and that is not decoration.** A mark
/// is an item id with no kind on it, and palette cards and craft-intent docs are
/// ordinary `.document` research items — so a title-only index makes every mark
/// resolve for every updatable target, and "Rewrite “Act II fog”" offered on a
/// Research-note promotion would overwrite the writer's palette card. The
/// manifest is what knows the difference: palette cards are the documents under
/// the palette group, and the craft intent carries `role == .craftIntent`.
struct ArtifactIndex: Equatable {

    struct Entry: Equatable {
        let title: String
        let kind: ArtifactKind

        init(title: String, kind: ArtifactKind = .researchNote) {
            self.title = title
            self.kind = kind
        }
    }

    private let entriesByID: [String: Entry]

    init(entriesByID: [String: Entry]) { self.entriesByID = entriesByID }

    /// Titles alone — every entry an ordinary research note. The shape a test
    /// that is not about kinds wants.
    init(titlesByID: [String: String]) {
        self.init(entriesByID: titlesByID.mapValues { Entry(title: $0) })
    }

    /// Every artifact a mark can name — **both registries, because since M1A
    /// there are two.**
    ///
    /// A promotion to craft intent writes a `Statement` id into
    /// `CanvasNode.promotedItemID`, and a statement is in `manifest.statements`
    /// and never in `manifest.research`. Built over research alone this index
    /// answers nil for such a mark, and three readers then say something false:
    /// `PromotedArtifactSection` renders `.artifactMissing` — telling the writer
    /// their intent was deleted, over prose that is right there —
    /// `Promotion.hasDanglingMark` answers true so a line promotion between two
    /// such cards is refused and the writer is told to promote again something
    /// that worked, and `ArtifactKind.craftIntent` becomes unreachable, which
    /// costs `PromotionPerformer.refuseIfNotAResearchNote` the one refusal that
    /// keeps a research-note update off an intent statement.
    ///
    /// **The alternative was writing no mark at all, and it is a trap**: the
    /// mark is what draws the stripe on the card and what `CanvasAccessibility`
    /// speaks, so removing it makes a promoted card look and sound un-promoted.
    ///
    /// `structure` is here to NAME a document-scoped statement — see
    /// `statementTitle`. It is the third value rather than a `ProjectStore`
    /// because this index is pure by design, and it is walked once here rather
    /// than per statement.
    static func over(research: [ResearchItem],
                     statements: [Statement],
                     structure: [StructureItem]) -> ArtifactIndex {
        // `PaletteLookup` is the ONE definition of "which research items are
        // palette cards" (tripwire 19) — a local predicate here would be the
        // fourth surface spelling it.
        let paletteCards = Set(PaletteLookup.paletteCards(in: research).map(\.id))
        var entries = Dictionary(
            TreeWalk.collect(in: research, where: { _ in true }).map { item in
                (item.id, Entry(title: item.title,
                                kind: kind(of: item, paletteCards: paletteCards)))
            },
            uniquingKeysWith: { _, later in later })
        let titlesByDocument = Dictionary(
            TreeWalk.collect(in: structure, where: { _ in true })
                .map { ($0.id, $0.title) },
            uniquingKeysWith: { _, later in later })
        for statement in statements {
            // **`.intent` only.** Nothing produces a mark naming any other kind
            // — `performCraftIntent` is the one writer and it creates `.intent`
            // — and an entry claiming a visual-language statement is a craft
            // intent would be a false answer to `refuseIfNotAResearchNote`,
            // which is the reader that decides whether a file gets written over.
            guard case .intent = statement.kind else { continue }
            entries[statement.id] = Entry(
                title: statementTitle(statement, documentTitle: { titlesByDocument[$0] }),
                kind: .craftIntent)
        }
        return ArtifactIndex(entriesByID: entries)
    }

    /// What a mark naming an intent statement is CALLED.
    ///
    /// **A statement carries no title** — its identity is the manifest entry and
    /// its path is derived once from the document's name — so this composes one,
    /// and it is the ONE definition: the sheet's index and the inspector's own
    /// deferred lookup both read it, or a card could say two different things
    /// about what it became.
    ///
    /// **It names the document, and that is what M1A made necessary.** Until
    /// this milestone an intent was the project's on every row but a Collection
    /// loose piece, so "Craft Intent" was unambiguous; a chapter's intent is now
    /// the ordinary case, and a pane saying `Became “Craft Intent”` on cards
    /// belonging to three different chapters describes none of them. The `·`
    /// separator is this surface's own (`Missing piece · ref-1`).
    static func statementTitle(_ statement: Statement,
                               documentTitle: (String) -> String?) -> String {
        guard case .document(let id) = statement.scope,
              let title = documentTitle(id) else { return intentTitle }
        return "\(intentTitle) · \(title)"
    }

    /// The bare name, and the project's scope answers with it alone.
    ///
    /// Deliberately NOT `PaletteConvention.craftIntentTitle`: that constant is
    /// the *research note's* title and belongs to the seam M1A replaces, so
    /// borrowing it would tie a live sentence to a value the next task deletes.
    /// It reads identically to what shipped, which is the point — the writer's
    /// word for this thing did not change.
    static let intentTitle = "Craft Intent"

    /// Position first (a palette card is an ordinary document that happens to
    /// live under the palette group), then the role, then the manifest's own
    /// asset kind. `CanvasItemIndex.kind(of:paletteCards:)` is the same order for
    /// the same reason, one vocabulary over — the two indexes stay separate
    /// because that one answers "what glyph" and this one answers "may this mark
    /// be overwritten, and by what".
    private static func kind(of item: ResearchItem,
                             paletteCards: Set<String>) -> ArtifactKind {
        if isCraftIntent(item) { return .craftIntent }
        if paletteCards.contains(item.id) { return .paletteCard }
        switch item.kind {
        case .image, .pdf, .audio: return .researchAsset
        // `.document`, `.link` and a nil kind alike: prose, or a URL with no file
        // at all. Nil is the legacy manifest's spelling, and `AssetKind`'s
        // forward-tolerance degrades an unknown kind to `.document` (ADR 0015),
        // so both land where the manifest would put them today.
        case .document, .link, .none: return .researchNote
        }
    }

    /// Role first, filename second — the same order `PaletteLookup` takes, and
    /// for the same reason: the role is the durable identity and the filename is
    /// the legacy fallback for a project written before roles were stamped.
    private static func isCraftIntent(_ item: ResearchItem) -> Bool {
        if item.role == .craftIntent { return true }
        return (item.path as NSString?)?.lastPathComponent
            == PaletteConvention.craftIntentFileName
    }

    func title(of itemID: String) -> String? { entriesByID[itemID]?.title }

    func kind(of itemID: String) -> ArtifactKind? { entriesByID[itemID]?.kind }

    /// Every palette card in the project, by title then id.
    ///
    /// **The sheet's picker is built from this rather than from
    /// `ProjectStore.loadPaletteCards()`, and that is what keeps `Promotion`
    /// pure**: `.paletteCardImage` needs a destination the writer chooses, and
    /// the plan has to be buildable — and previewable — in a test that owns no
    /// store. The index already walked the manifest once when the sheet opened
    /// and already knows which items are cards, so this costs one filter of a
    /// dictionary it holds.
    ///
    /// **Sorted, and the id tiebreak is not decoration**: `Dictionary` iteration
    /// order is seeded per process, so an unsorted list would put a different
    /// card under the writer's cursor on each launch, and two cards sharing a
    /// title would swap places between renders of one sheet.
    var paletteCards: [(id: String, title: String)] {
        entriesByID
            .filter { $0.value.kind == .paletteCard }
            .map { (id: $0.key, title: $0.value.title) }
            .sorted { $0.title == $1.title ? $0.id < $1.id : $0.title < $1.title }
    }
}

/// Where a promotion's piece association sends it: the piece's title, and the
/// route `ResearchScope` will take for it (spec §6.2).
///
/// **Resolved outside this file, for `ArtifactIndex`'s reason.** The routing
/// table is `ProjectStore.researchRouting(forDocumentId:)`'s and has been since
/// the 2026-07-07 scoped-research milestone — §6.2 *adopts* it rather than
/// restating it, and a `switch manifest.type` here would be the second copy that
/// drifts. `PromotionPiece.resolve(for:in:store:)`, over in
/// `PromotionPerformer.swift`, is the one place the pure half meets the router,
/// and both the sheet and the performer call it.
enum PromotionPiece: Equatable {

    /// One case per row of §6.2's table, minus the row that throws — that is
    /// `.unroutable`.
    enum Route: Equatable {
        /// Collection loose piece: the note is created in the piece's own
        /// `research/`. Containment, so it travels with the piece.
        case ownResearch
        /// Novel chapter: shared `research/` plus a `linkResearch` record, which
        /// `route(_:shared:piece:)` writes itself.
        case sharedPlusLink
        /// Short story or screenplay: shared `research/` and no link, because
        /// derivation already surfaces everything as that document's.
        case sharedOnly
    }

    /// No association at all — and **not an error**. In a novel the writer is
    /// not thinking in pieces, so this is the ordinary case (§6.2), and the copy
    /// that describes it must not read as a fallback with an apology.
    case none

    /// **The `id` is read by no production caller, and is kept deliberately.** It
    /// is what makes these values comparable in the tests that pin the resolver
    /// against a real manifest — the seam this type exists to hold — so a tidy-up
    /// that removes it as dead weight would take the assertions with it.
    case routed(id: String, title: String, route: Route)

    /// The association names something the router refuses. **The picker cannot
    /// create one of these as of 1C-c2a** — an association already made can still
    /// go stale, by the piece being deleted or a Collection loose piece being
    /// converted to a reference. The title is nil for the first of those, and the
    /// two need different sentences because the act that fixes them differs.
    ///
    /// **`inherited` is what stops the refusal pointing at the wrong control.**
    /// A card that lives in a region whose piece was deleted carries nothing
    /// itself, so "clear the association" names a Picker already reading None —
    /// the stale field is the region's. See `PromotionFailure`.
    case unroutable(id: String, title: String?, inherited: Bool)
}

/// Everything `Promotion.plan` needs. A struct rather than eight parameters,
/// because the sheet builds one and holds it, editing its fields as the writer
/// works.
struct PromotionRequest {
    let source: PromotionSource
    let target: PromotionTarget
    var mode: PromotionMode = .new
    var scraps: [CanvasNodeID: String]
    var paletteKind: PaletteCard.Kind = .other
    var artifacts: ArtifactIndex
    /// The index every item node on the canvas resolves through — needed here
    /// for one question only: **where does a REFERENCED picture's file live?**
    ///
    /// A region's palette-card promotion carries the pictures in it, and a
    /// referenced one exists as a research item whose path only the manifest
    /// knows (`CanvasItemIndex.Entry.thumbnailPath`). An owned one carries its
    /// own path in its kind and needs nothing.
    ///
    /// **Not `ArtifactIndex`, which is right beside it and deliberately holds no
    /// paths** — see its doc comment: a path on *that* `Entry` is an invitation
    /// to resolve a promotion TARGET by filename. Two indexes over one manifest
    /// is the cost, and `ProjectWindow` already builds both at one site.
    ///
    /// **Defaulted to `.empty`, and `PromotionSheetModel.init`'s copy is not** —
    /// `PromotionPiece`'s split exactly, for its reason. `.empty` is a real
    /// state (a canvas hosted without a window) and it is what the dozens of
    /// tests reaching this initialiser genuinely mean; the value that must never
    /// go missing by accident is the one on the production path, so the sheet
    /// demands it and `PromotionCommandTests`' census names the argument.
    var items: CanvasItemIndex = .empty
    /// The destination artifact's body as read from disk when the target was
    /// chosen, for the wiki-link duplicate check. `nil` when not applicable or
    /// not read. **A snapshot** — the performer checks again against the live
    /// file, because this one can be stale by the time the writer commits.
    var destinationBody: String?
    /// The palette card `.paletteCardImage` appends to — the writer's choice in
    /// the sheet's picker, and meaningless on every other row.
    ///
    /// **Defaulted to nil and that is a refusal rather than a fallback**: a
    /// `.paletteCardImage` request with no card produces **no plan**, so Promote
    /// is disabled rather than the picture landing on whichever card sorted
    /// first. The sheet seeds it the moment that target is selected, so the state
    /// is reachable only from a hand-built request.
    var paletteCardID: String?
    /// Where the source's piece association sends this, resolved once against
    /// the live manifest when the sheet opened.
    ///
    /// **Defaulted to `.none`, and that default is a truth rather than a
    /// placeholder** — "no association" is a real state a great many promotions
    /// are in. The value that must never go missing by accident is the one on
    /// `PromotionSheetModel.init`, which has no default for exactly that reason.
    var piece: PromotionPiece = .none

    init(source: PromotionSource,
         target: PromotionTarget,
         mode: PromotionMode = .new,
         scraps: [CanvasNodeID: String],
         paletteKind: PaletteCard.Kind = .other,
         artifacts: ArtifactIndex,
         items: CanvasItemIndex = .empty,
         destinationBody: String? = nil,
         paletteCardID: String? = nil,
         piece: PromotionPiece = .none) {
        self.source = source
        self.target = target
        self.mode = mode
        self.scraps = scraps
        self.paletteKind = paletteKind
        self.artifacts = artifacts
        self.items = items
        self.destinationBody = destinationBody
        self.paletteCardID = paletteCardID
        self.piece = piece
    }
}

/// The preview. The writer sees what will be produced, and where, before
/// committing — Scrivener's Commit is the model: a named command with a stated
/// rule and a predictable outcome (§6.1).
///
/// Building a plan NEVER mutates anything. That is what makes the preview
/// honest, and `test_planningNeverMutatesTheScene` pins it.
struct PromotionPlan: Equatable {
    let source: PromotionSource
    let producedKind: PromotionTarget
    /// The writer may edit this in the sheet before committing.
    var title: String
    let body: String
    /// Human-readable, shown verbatim: "research/", "the palette wall",
    /// "the note “The falls at night.”".
    let destinationDescription: String
    let discards: Set<PromotionDiscard>

    /// §6.1's "may suggest, must never impose". Promoting a region may *offer*
    /// to link its already-promoted members to the artifact it produced. That
    /// sits inside Shipman & Marshall's licence precisely BECAUSE the writer
    /// sees it and can decline it cheaply.
    let offeredLinks: [PromotionLinkOffer]

    /// Defaults to FALSE, always. The same inference applied silently is
    /// forbidden: membership is n-ary and vague, wiki-links are binary and
    /// specific, and a silent conversion manufactures precision the writer never
    /// claimed — into a layer with backlinks and rename propagation, where it is
    /// expensive to undo.
    var linksAccepted = false

    let wikiLinkWrite: WikiLinkWrite?
    let mode: PromotionMode
    let paletteKind: PaletteCard.Kind

    /// Home members whose text is now inside the artifact this plan would
    /// produce — recorded at promotion time, not derived from live
    /// membership, so a card added to the region *afterwards* has no words in
    /// that note and must not claim it (spec §6.3). Populated only for a
    /// region source, from `regionBodies` — the same function the body and
    /// the refusal already read, so "who contributed" and "what the note
    /// says" cannot drift apart. Empty for a scrap or a line: only a region's
    /// promotion has more than one card behind a single artifact.
    ///
    /// **This is NOT the promotion mark, and must never be conflated with
    /// one.** See `CanvasNode.contributedToItemID`'s doc comment — a
    /// contributor's words are IN the artifact alongside others', and reading
    /// this list where `promotedItemID` is read would let one member's
    /// re-promotion offer to rewrite the whole joint note with its own single
    /// card's text.
    ///
    /// **No memberwise default, deliberately.** Every arm of `plan` names its own
    /// list, so a fifth `PromotionSource` cannot record nobody by inheriting an
    /// empty one — which is the reported §6.3 bug returning through the door
    /// nothing is watching. `RegionInspector.provenance` names
    /// `contribution: .none` for the identical reason, and `performCraftIntent`
    /// refuses to write a literal `[]` for it too; a default here would be the
    /// same rule enforced by hand twice and given away in the third place.
    let contributors: [CanvasNodeID]

    /// True when the link this plan would write is already in the destination.
    /// The sheet says so and refuses; the performer refuses too, against the
    /// live file.
    let linkAlreadyPresent: Bool

    /// The files this promotion copies, in the order they will be copied, and
    /// empty on every row that copies none (spec §6's 2026-07-30 amendment for
    /// the two picture rows; its 2026-07-29 amendment for the region's palette
    /// row, built in 1C-d Task 12a).
    ///
    /// **A LIST rather than an optional plus a list, and that is the shape
    /// decision this field carries.** It was `PromotedPicture?` while only the
    /// two picture rows could carry one, and a region can hold several — so the
    /// alternative on the table was a second field beside this one. Two fields
    /// for one fact is the smear this file spends its length refusing: every
    /// reader (`validate`'s file check, the sheet's notice, the performer's
    /// copy loop) would have to remember to consult both, and the one that
    /// forgot would be silently right on four rows out of six.
    ///
    /// **No memberwise default, for `contributors`' reason**: every arm of
    /// `plan` names its own value, so a later source cannot silently promote
    /// nothing by inheriting an empty list. `PromotionPerformer.validate`
    /// refuses a picture row that arrives EMPTY rather than reaching into the
    /// scene for a substitute.
    let pictures: [PromotedPicture]
}

enum Promotion {

    /// The targets whose artifact is a single rewritable document. The craft
    /// intent is deliberately absent: it ACCUMULATES — one doc per scope — so an
    /// "update" would mean replacing the writer's whole intent statement.
    static let updatableTargets: Set<PromotionTarget> = [.researchNote, .paletteCard]

    // MARK: - §6's table

    static func targets(for source: PromotionSource,
                        in scene: CanvasScene,
                        artifacts: ArtifactIndex) -> [PromotionTarget] {
        switch source {
        case .scrap(let id):
            guard let kind = scene.node(id)?.kind else { return [] }
            switch kind {
            case .scrap:
                return [.researchNote, .paletteCard, .intentStatement]
            case .item(let reference):
                return targets(forOwned: reference, artifacts: artifacts)
            }

        case .region(let id):
            guard scene.region(id) != nil else { return [] }
            return [.researchNote, .paletteCard]

        case .line(let id):
            guard let line = scene.line(id),
                  resolvedArtifact(of: line.from, in: scene, artifacts: artifacts) != nil,
                  resolvedArtifact(of: line.to, in: scene, artifacts: artifacts) != nil
            else { return [] }
            return [.wikiLink]
        }
    }

    /// §6's fourth row (2026-07-30): **an owned item node promotes and a
    /// referenced one does not.**
    ///
    /// A *referenced* item already exists in the project — it is already the
    /// artifact, with nothing left to produce — and promoting it would put a
    /// second editable copy of something the project already has beside it,
    /// which is what §4.3 rejects. That refusal was never about an owned
    /// capture: a photograph from the phone's inbox exists nowhere but the
    /// canvas, and the entry it came from is `.promoted` and gone, so refusing it
    /// strands the picture the writer just sent there.
    ///
    /// **Its two destinations are the inbox's own, because it is the same object
    /// one hop later**: a research asset (`ProjectStore.createResearchAsset`) or
    /// an image on a palette card (`addImage(toPaletteCard:fileURL:)`) — the
    /// pair §3.1's amendment already names, with the canvas as one more caller
    /// rather than a storage decision of its own.
    ///
    /// **The palette row is withheld when the project has no palette cards**,
    /// which is the line arm's rule arriving on another row: a target that can
    /// only ever produce "there is nowhere to put this" is not an offer. It
    /// costs the writer nothing — the research row is always there — and it is
    /// why this reads `artifacts` at all.
    private static func targets(forOwned reference: CanvasItemReference,
                                artifacts: ArtifactIndex) -> [PromotionTarget] {
        guard case .owned = reference else { return [] }
        var offered: [PromotionTarget] = [.researchAsset]
        if !artifacts.paletteCards.isEmpty { offered.append(.paletteCardImage) }
        return offered
    }

    /// Why a source cannot be promoted, in words a writer can act on.
    ///
    /// **Three selections reach the sheet with nothing to offer, and for one
    /// slice only the line said why.** An empty scrap is offered all three
    /// targets by `targets(for:)` — emptiness is not a targets question — and
    /// then `plan(_:)` returns nil, so `preview`, `resolvedPlan` and `refusal`
    /// were all nil together and the writer met an empty Name field, no
    /// destination, no message and a dead button. An item node offered `[]` and
    /// said nothing at all. Both are answered here, where the sheet already
    /// looks. **Since 1C-d that second one is the REFERENCED item node** — an
    /// owned picture is offered two targets and blocked by nothing, and the arm
    /// below says nil for it explicitly rather than by falling through.
    ///
    /// It takes `scraps` for the empty case, which is the one fact about a card
    /// the scene does not hold.
    static func blockedReason(for source: PromotionSource,
                              in scene: CanvasScene,
                              scraps: [CanvasNodeID: String],
                              artifacts: ArtifactIndex) -> String? {
        switch source {
        case .scrap(let id):
            guard let node = scene.node(id) else { return nil }
            if case .item(let reference) = node.kind {
                // **The provenance decides, and the owned arm returns nil
                // EXPLICITLY** (spec §6, 2026-07-30). This read
                // `if case .item = node.kind { return itemNodeReason }` and
                // refused both; the failure mode of relaxing it carelessly is
                // that an owned node falls through to the empty-text check
                // below, has no scrap text by construction, and is refused with
                // "There is nothing in this card to promote." — a picture, in
                // the wrong noun, for a reason that is not true of it.
                guard case .project = reference else { return nil }
                return itemNodeReason
            }
            guard text(of: id, in: scraps).isEmpty else { return nil }
            // The performer's own sentence rather than a second wording of it:
            // a refusal the writer meets before committing and one they meet
            // after must be the same words. It was unreachable from the UI
            // until this call.
            return PromotionFailure.emptyBody(source: source).errorDescription

        case .region(let id):
            // **The scrap arm's defect, on the other row.** This returned nil
            // unconditionally and `plan` had no emptiness guard, so a region
            // holding nothing (no residents, or residents that are all empty
            // scraps) previewed an empty body with Promote enabled and threw
            // `emptyBody` at Commit — in the wrong noun, at that. Pre-existing,
            // and 1C-c2a is what made it matter: `.researchNote` is the headline
            // verb on this row now, so "a cluster of scraps is a note" is the
            // thing a writer tries on a region they have only just drawn.
            guard let region = scene.region(id) else { return nil }
            guard regionBodies(region, in: scene, scraps: scraps).isEmpty else { return nil }
            return PromotionFailure.emptyBody(source: source).errorDescription

        case .line(let id):
            guard let line = scene.line(id),
                  targets(for: source, in: scene, artifacts: artifacts).isEmpty
            else { return nil }
            guard isScrap(line.from, in: scene) && isScrap(line.to, in: scene) else {
                return "A line becomes a wiki-link only between two cards of text."
            }
            // **Two states, two acts.** A card that was never promoted needs
            // promoting; a card whose note has been DELETED since has already
            // been promoted, and telling that writer to "promote both cards
            // first" tells them to do the thing they did. `ScrapInspector`
            // already distinguishes the two, and the conditions are the ones
            // `resolvedArtifact` reads.
            if [line.from, line.to].contains(where: { hasDanglingMark($0, in: scene,
                                                                      artifacts: artifacts) }) {
                return "What one of these cards produced is no longer in the "
                    + "project, so there is nothing left for a link to point at. "
                    + "Promote that card again first."
            }
            // The precedence rule, taught at the moment it costs something: the
            // durable layer is reached by promoting the things first.
            return "Promote both cards first. A wiki-link has to point at something "
                + "that exists outside the canvas — a canvas line is scratch."
        }
    }

    /// Why a **referenced** item node offers nothing. Held as a constant because
    /// several places reason about it — the renderer's mark, the accessibility
    /// label and this — and the wording is what a writer reads.
    ///
    /// **It became the referenced node's sentence in 1C-d rather than being
    /// deleted** (spec §6's amendment says exactly that). A reference is already
    /// in the project, so the honest answer is to open it — which is what the
    /// item arm's **Open in Research** button is for — and the sentence stays
    /// true of it word for word. An owned capture is the case this was never
    /// about.
    static let itemNodeReason =
        "A reference card already exists as itself. Promoting one would put a "
        + "second editable copy of something the project already has beside it."

    /// A mark that names an artifact the project no longer holds.
    private static func hasDanglingMark(_ id: CanvasNodeID,
                                        in scene: CanvasScene,
                                        artifacts: ArtifactIndex) -> Bool {
        guard let mark = scene.node(id)?.promotedItemID else { return false }
        return artifacts.title(of: mark) == nil
    }

    // MARK: - Update or New

    /// The artifact this source produced last time, when it still exists, the
    /// target is one that can be rewritten, AND the artifact is still the same
    /// KIND of thing the target produces.
    ///
    /// **The kind term is the one that stops a promotion destroying an
    /// artifact.** Without it every mark resolves for every updatable target,
    /// because a mark records an id and the index knew only titles: promote a
    /// card to a palette card, then promote the same card as a research note,
    /// and the sheet offered "Rewrite “Act II fog”" and previewed "Goes to: the
    /// existing “Act II fog”" — both sentences true — and committing renamed the
    /// palette card's backing file and wrote raw scrap text over it. The
    /// swatches, the kind, the sensory notes and the `<slug>_assets/` image
    /// references all went, and ⌘Z takes back only the mark. The craft-intent
    /// variant replaces the writer's whole accumulated intent statement with one
    /// card, which is precisely what excluding `.intentStatement` from
    /// `updatableTargets` exists to prevent.
    ///
    /// A kind that no longer matches declines the update rather than refusing
    /// the promotion: the writer gets a new artifact and keeps the old one,
    /// which costs a duplicate note in the worst case and cannot cost them work.
    static func existingArtifact(for source: PromotionSource,
                                 target: PromotionTarget,
                                 in scene: CanvasScene,
                                 artifacts: ArtifactIndex) -> PromotionMode? {
        guard updatableTargets.contains(target) else { return nil }
        let markedID: String?
        switch source {
        // **`promotedItemID` ONLY, and never `contributedToItemID`** (spec §6.3).
        // This function is what offers **Rewrite**, and a contributor is not the
        // artifact's producer: falling back to the contribution record here
        // would let the writer promote one member of a six-card region note and
        // replace the whole note with that card's text. That is 1C-c2's Critical
        // — a mark that did not record the artifact's KIND — returning as a mark
        // that does not record its CARDINALITY.
        //
        // `PromotionContributionTests`' no-Update test is the guard, and it was
        // falsified by planting exactly that fallback here.
        //
        // **This arm reads an OWNED item node's mark too, and three independent
        // guards keep a picture from ever being offered a Rewrite** — the
        // failure §6's 2026-07-30 amendment names by name (promote a photograph
        // twice, be offered to rewrite the palette card it went into, and lose
        // that card's other images). Neither picture row is in
        // `updatableTargets`, so the guard above answers first; a picture's mark
        // names a `.researchAsset` and no updatable target's
        // `producedArtifactKind` is that; and the palette row writes no mark at
        // all — it records a *contribution*, which has no route into this
        // function (spec §6.3).
        case .scrap(let id): markedID = scene.node(id)?.promotedItemID
        case .region(let id): markedID = scene.region(id)?.promotedItemID
        case .line: markedID = nil
        }
        guard let markedID, let title = artifacts.title(of: markedID),
              artifacts.kind(of: markedID) == target.producedArtifactKind else { return nil }
        return .update(itemID: markedID, title: title)
    }

    /// `.new` first, always — so a sheet that renders these in order cannot make
    /// "rewrite the writer's note" the thing sitting under the cursor.
    static func modes(for target: PromotionTarget, existing: PromotionMode?) -> [PromotionMode] {
        guard let existing, updatableTargets.contains(target) else { return [.new] }
        return [.new, existing]
    }

    // MARK: - The plan

    static func plan(_ request: PromotionRequest, in scene: CanvasScene) -> PromotionPlan? {
        guard targets(for: request.source, in: scene, artifacts: request.artifacts)
                .contains(request.target) else { return nil }

        switch request.source {
        case .scrap(let id):
            // The picture rows first: the guard above has already established
            // that this node is an owned item (nothing else is offered
            // `.researchAsset` or `.paletteCardImage`), so this destructures to
            // read the path rather than to decide anything.
            if case .item(.owned(let path)) = scene.node(id)?.kind {
                return picturePlan(request, node: id, assetPath: path)
            }
            let body = text(of: id, in: request.scraps)
            guard !body.isEmpty else { return nil }
            return PromotionPlan(
                source: request.source, producedKind: request.target,
                title: title(from: body), body: body,
                destinationDescription: destination(request),
                discards: [], offeredLinks: [], wikiLinkWrite: nil,
                mode: request.mode, paletteKind: request.paletteKind,
                // Nobody: one card behind one artifact is the card itself, and
                // its own mark is what records that. Named rather than inherited
                // (see `PromotionPlan.contributors`).
                contributors: [], linkAlreadyPresent: false,
                // A scrap's words are in `canvas.md`; there is no file to copy.
                pictures: [])

        case .region(let id):
            guard let region = scene.region(id) else { return nil }
            let bodies = regionBodies(region, in: scene, scraps: request.scraps)
            // The scrap arm's guard, one row down — and `blockedReason` reads
            // the same helper, so the preview and the refusal agree about what
            // "empty" means rather than agreeing by coincidence.
            guard !bodies.isEmpty else { return nil }
            // **The palette card is the one row that can hold a picture** (spec
            // §6's 2026-07-29 amendment: "a palette card is worth making from a
            // region that holds an image"). A research note is prose and gains
            // nothing, and a REWRITE of an existing card keeps the image well it
            // already has — `performPaletteCard`'s update branch is about the
            // prose, and appending on every update would stack another copy of
            // every photograph on the writer's card each time they re-promoted.
            let held = regionPictures(region, in: scene, items: request.items)
            let carried = request.target == .paletteCard && !isUpdate(request.mode)
                ? held : []
            // Whoever's CONTENT went in, words or picture (spec §6.3's
            // 2026-07-31 amendment), in the one reading order the body already
            // uses. A picture the plan does not carry contributed nothing and is
            // not recorded.
            let contributed = Set(bodies.map(\.0)).union(carried.map(\.node))
            return PromotionPlan(
                source: request.source, producedKind: request.target,
                title: regionTitle(region),
                body: bodies.map(\.1).joined(separator: "\n\n"),
                destinationDescription: destination(request),
                // The spatial work is not carried across, and the writer is told
                // — and since 1C-d so are the pictures, on the rows that cannot
                // take one. `held` rather than `carried`: what is discarded is
                // what the region HAS and this artifact will not get.
                discards: carried.isEmpty && !held.isEmpty
                    ? [.lines, .layout, .pictures] : [.lines, .layout],
                offeredLinks: bodies.compactMap { nodeID, _ in
                    guard let itemID = resolvedArtifact(of: nodeID, in: scene,
                                                        artifacts: request.artifacts),
                          let title = request.artifacts.title(of: itemID) else { return nil }
                    return PromotionLinkOffer(node: nodeID, itemID: itemID, title: title)
                },
                wikiLinkWrite: nil, mode: request.mode,
                paletteKind: request.paletteKind,
                contributors: readingOrder(region.homeMembers, in: scene)
                    .filter(contributed.contains),
                linkAlreadyPresent: false,
                pictures: carried)

        case .line(let id):
            guard let line = scene.line(id),
                  let fromItem = resolvedArtifact(of: line.from, in: scene,
                                                  artifacts: request.artifacts),
                  let toItem = resolvedArtifact(of: line.to, in: scene,
                                                artifacts: request.artifacts),
                  let fromTitle = request.artifacts.title(of: fromItem),
                  let toTitle = request.artifacts.title(of: toItem) else { return nil }
            let write = WikiLinkWrite(intoNode: line.from, intoItemID: fromItem,
                                      linkText: linkText(to: toTitle, label: line.label))
            return PromotionPlan(
                source: request.source, producedKind: request.target,
                title: fromTitle, body: write.linkText,
                destinationDescription: "the note “\(fromTitle)”",
                discards: [], offeredLinks: [], wikiLinkWrite: write,
                mode: .new, paletteKind: request.paletteKind,
                // Nobody: a line's artifact is text inside somebody else's note,
                // so no card's words are folded into anything new. Named rather
                // than inherited (see `PromotionPlan.contributors`).
                contributors: [],
                linkAlreadyPresent: request.destinationBody?.contains(write.linkText) ?? false,
                // A line's product is text inside somebody else's note.
                pictures: [])
        }
    }

    /// §6's fourth row, planned: a copy of an owned node's file, either filed in
    /// `research/` or appended to a palette card the writer picked.
    ///
    /// **It is a SNAPSHOT and the file is COPIED** (§6.1's ruling 1, restated in
    /// the 2026-07-30 amendment). Promoting does not hand the file to research
    /// and turn the node into a reference: the alternative leaves no duplicate on
    /// disk and makes promotion the one verb on this surface that MOVES, so a
    /// writer who promotes and then undoes would be relying on a file move to
    /// reverse. A duplicate photograph is the cost §6 already accepts everywhere
    /// else.
    ///
    /// **Nothing is discarded and the body is empty**, and neither is an
    /// oversight: there is nothing spatial to lose (no lines, no layout are
    /// carried into a file copy) and a picture has no prose to excerpt. The
    /// preview's `body` block is hidden by its own `!plan.body.isEmpty` guard,
    /// so the sheet shows the destination and the two acts.
    private static func picturePlan(_ request: PromotionRequest,
                                    node: CanvasNodeID,
                                    assetPath: String) -> PromotionPlan? {
        let cardID: String?
        let title: String
        let destination: String
        switch request.target {
        case .researchAsset:
            cardID = nil
            // What the CARD is called, which is what the writer is looking at.
            // The created item's title is the copied file's stem and is read back
            // off the manifest by the performer, so this is never mistaken for
            // it — `namesItsArtifact` is false, so nothing here is editable.
            title = CanvasItemFacts.ownedTitle
            // The same sentence a research NOTE gets, because it is the same
            // routing: `createResearchAsset` and `createResearchNote` are two
            // arms of one `ResearchScope.route`.
            destination = researchNoteDestination(request.piece)
        case .paletteCardImage:
            // No plan at all without a card. See `PromotionRequest.paletteCardID`
            // — a picture must not land on whichever card sorted first.
            guard let chosen = request.paletteCardID,
                  let cardTitle = request.artifacts.title(of: chosen),
                  request.artifacts.kind(of: chosen) == .paletteCard else { return nil }
            cardID = chosen
            title = cardTitle
            destination = "the palette card “\(cardTitle)”"
        case .researchNote, .paletteCard, .intentStatement, .wikiLink:
            // Unreachable through `plan`'s own targets guard, and enumerated
            // rather than defaulted so a new row arrives here as a compile
            // error.
            return nil
        }
        return PromotionPlan(
            source: request.source, producedKind: request.target,
            title: title, body: "", destinationDescription: destination,
            discards: [], offeredLinks: [], wikiLinkWrite: nil,
            // **`.new`, always.** Neither row is in `updatableTargets`, so
            // `existingArtifact` offers no Update and the sheet has no picker to
            // set one — and a `.update` arriving from a hand-built request must
            // not reach a performer that would honour it.
            mode: .new, paletteKind: request.paletteKind,
            // Nobody: what an appended picture records about the palette card is
            // written by the performer as a CONTRIBUTION, and deliberately not
            // through this list — `PromotionPerformer.record` clears before it
            // stamps, because a region's note is rewritten from its current
            // members, and an image well is appended to. Routed through here, the
            // second picture on a card would erase the first one's record.
            contributors: [], linkAlreadyPresent: false,
            pictures: [PromotedPicture(node: node, assetPath: assetPath,
                                       paletteCardID: cardID)])
    }

    /// Whether this plan rewrites an artifact rather than making one.
    ///
    /// Spelled once because two decisions read it and they must not drift: the
    /// region's palette row carries pictures on `.new` only, and the discard it
    /// declares instead is the same condition inverted.
    private static func isUpdate(_ mode: PromotionMode) -> Bool {
        if case .update = mode { return true }
        return false
    }

    // MARK: - Pieces

    /// Which piece a promotion belongs to — **by precedence, never by
    /// overwriting** (spec §6.2). The scrap's own association wins; failing
    /// that it inherits from the region it LIVES in; failing that there is none
    /// and the artifact is the project's.
    ///
    /// Home only, deliberately: a citation is not luggage (§4.3's rule for
    /// dragging, applied to destination), and a card cited in two regions bound
    /// to different pieces must not take whichever the writer touched last —
    /// that is §4.2's rejected bug class wearing a new hat.
    ///
    /// A region answers with its own and nothing else: it has no home to
    /// inherit from. A line answers nil — its artifact is text inside somebody
    /// else's note.
    ///
    /// **An owned item node inherits and never carries.** Its inspector arm has
    /// no Piece picker — there is nothing about a photograph to associate — so
    /// `node.boundPieceID` is always nil for one and the second clause is the
    /// whole rule: a picture living in the region bound to Chapter Three is
    /// filed in Chapter Three's research, which is §6.2's precedence unchanged
    /// rather than a rule of its own.
    static func piece(for source: PromotionSource, in scene: CanvasScene) -> String? {
        switch source {
        case .scrap(let id):
            guard let node = scene.node(id) else { return nil }
            if let own = node.boundPieceID { return own }
            guard let home = CanvasMembership.homeRegion(of: id, in: scene) else { return nil }
            return scene.region(home)?.boundPieceID
        case .region(let id):
            return scene.region(id)?.boundPieceID
        case .line:
            return nil
        }
    }

    /// Whether `piece(for:in:)`'s answer came from the source ITSELF or was
    /// inherited from the region it lives in.
    ///
    /// **One rule, two readers**, for the reason everything else in this file is:
    /// `ScrapInspector.association` shows it to the writer and
    /// `PromotionPiece.resolve` puts it in the refusal, and a second spelling of
    /// "is this inherited" is how the pane and the sentence come to disagree.
    ///
    /// False when there is no piece at all — nothing was inherited — and false
    /// for a region, which has no home to inherit from.
    static func pieceIsInherited(for source: PromotionSource, in scene: CanvasScene) -> Bool {
        guard case .scrap(let id) = source, piece(for: source, in: scene) != nil else {
            return false
        }
        return scene.node(id)?.boundPieceID == nil
    }

    static func title(from body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// `[[Title]]`, plus the line's own name when it has one. An em dash rather
    /// than a colon, matching the guide's prose voice.
    static func linkText(to title: String, label: String?) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "[[\(title)]]" }
        return "[[\(title)]] — \(trimmed)"
    }

    private static func isScrap(_ id: CanvasNodeID, in scene: CanvasScene) -> Bool {
        if case .scrap = scene.node(id)?.kind { return true }
        return false
    }

    /// The node's artifact, when it is a scrap, HAS a mark, and that mark still
    /// names something in the project. All three conditions matter — the third
    /// is the dangling mark, and it is the only one the scene cannot see.
    private static func resolvedArtifact(of id: CanvasNodeID,
                                         in scene: CanvasScene,
                                         artifacts: ArtifactIndex) -> String? {
        guard let node = scene.node(id), case .scrap = node.kind,
              let itemID = node.promotedItemID,
              artifacts.title(of: itemID) != nil else { return nil }
        return itemID
    }

    /// The member bodies a region's promotion would join — reading order,
    /// empties dropped.
    ///
    /// **One spelling, because `plan` and `blockedReason` must agree about what
    /// an empty region IS.** A second walk in either place is how a region comes
    /// to preview an empty body with Promote enabled and then refuse at Commit,
    /// which is exactly what the scrap arm did before `blockedReason` learned to
    /// answer for it.
    private static func regionBodies(_ region: CanvasRegion, in scene: CanvasScene,
                                     scraps: [CanvasNodeID: String])
        -> [(CanvasNodeID, String)] {
        readingOrder(region.homeMembers, in: scene).compactMap { nodeID in
            let t = text(of: nodeID, in: scraps)
            return t.isEmpty ? nil : (nodeID, t)
        }
    }

    /// The pictures a region's promotion would carry — **home members, in
    /// `regionBodies`' reading order, on both provenances** (spec §6's
    /// 2026-07-29 amendment, built 1C-d Task 12a).
    ///
    /// **Home only, and a visitor is not luggage.** That is §4.3's rule for
    /// dragging applied to destination, and it is already this file's rule for
    /// the words — a photograph merely *cited* in two regions must not be copied
    /// into whichever was promoted last.
    ///
    /// **Both provenances, and `CanvasItemFacts.resolve` is why there is one
    /// branch here rather than two.** Its own doc comment states the rule: "one
    /// entry point for both provenances, so no caller can pick the wrong one".
    /// An **owned** picture carries its path in its kind and must be carried
    /// across because it exists nowhere else; a **referenced** one resolves to
    /// the research item's file through `thumbnailPath`, which is set for a
    /// picture and nil for everything else — so a note, a PDF, a recording or a
    /// dangling reference in a region contributes nothing and is skipped by the
    /// same `nil` that skips an empty scrap above.
    ///
    /// This is emphatically **not** a promotion OF the referenced node — §6's
    /// refusal of that stands, and nothing here produces a second artifact
    /// beside the one the project already has. The artifact is the region's
    /// card; the picture is content going into it, exactly as a referenced
    /// card's text would be if it had any.
    private static func regionPictures(_ region: CanvasRegion, in scene: CanvasScene,
                                       items: CanvasItemIndex) -> [PromotedPicture] {
        readingOrder(region.homeMembers, in: scene).compactMap { nodeID in
            guard case .item(let reference)? = scene.node(nodeID)?.kind,
                  let path = CanvasItemFacts.resolve(reference, in: items).thumbnailPath
            else { return nil }
            return PromotedPicture(node: nodeID, assetPath: path, paletteCardID: nil)
        }
    }

    private static func text(of id: CanvasNodeID, in scraps: [CanvasNodeID: String]) -> String {
        (scraps[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Regions are created unlabelled and named in the inspector, so this is the
    /// common case for the first minute of a region's life. An untitled palette
    /// card is unfindable on the wall.
    private static func regionTitle(_ region: CanvasRegion) -> String {
        let trimmed = region.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? CanvasRegion.untitledLabel : trimmed
    }

    /// Top to bottom, then left to right, then by id.
    ///
    /// **Spatial and not id order**, because the writer arranged these cards and
    /// the joined text should read the way the region reads. The id tiebreak is
    /// not decoration: two cards at the same origin would otherwise let a `Set`'s
    /// iteration order decide, and that differs between runs of the same binary.
    private static func readingOrder(_ ids: Set<CanvasNodeID>,
                                     in scene: CanvasScene) -> [CanvasNodeID] {
        ids.compactMap { scene.node($0) }
            .sorted { a, b in
                if a.origin.y != b.origin.y { return a.origin.y < b.origin.y }
                if a.origin.x != b.origin.x { return a.origin.x < b.origin.x }
                return a.id.raw < b.id.raw
            }
            .map(\.id)
    }

    /// **The update arm answers before the target switch, and that is what keeps
    /// the copy and the performer together.** `performResearchNote` and
    /// `performPaletteCard` both route (and both take a link) on their `.new`
    /// arm ONLY — an update is about the body, and re-filing the writer's note
    /// because they changed a card's association is exactly the surprise §6.1
    /// forbids. So a sentence naming a piece or promising a link cannot reach an
    /// update, structurally, rather than by a second guard somebody has to
    /// remember.
    private static func destination(_ request: PromotionRequest) -> String {
        if case .update(_, let title) = request.mode,
           updatableTargets.contains(request.target) {
            return "the existing “\(title)”"
        }
        switch request.target {
        case .researchNote: return researchNoteDestination(request.piece)
        case .paletteCard: return paletteCardDestination(request.piece)
        case .intentStatement: return craftIntentDestination(request.piece)
        case .wikiLink: return ""   // replaced per-plan above
        // Both resolved in `picturePlan`, for `.wikiLink`'s reason: the palette
        // row's sentence names the card the writer picked, which is a fact about
        // the request that this switch would have to re-derive.
        case .researchAsset, .paletteCardImage: return ""
        }
    }

    /// §6.2's four rows, in one line each.
    ///
    /// **The two shared-research rows have to read differently**, or a writer
    /// cannot tell a note that will be filed under their chapter from one that
    /// will not — the routing is the whole of the difference and it is invisible
    /// otherwise. And `.none` says nothing extra at all: in a novel the writer is
    /// not thinking in pieces, so an apology there would invent a problem.
    static func researchNoteDestination(_ piece: PromotionPiece) -> String {
        switch piece {
        case .none:
            return "research/"
        case .routed(_, let title, .ownResearch):
            return "“\(title)”’s own research/"
        case .routed(_, let title, .sharedPlusLink):
            return "research/, linked to “\(title)”"
        case .routed(_, let title, .sharedOnly):
            return "research/, which is already “\(title)”’s"
        case .unroutable:
            // Refused before Commit — see `pieceFailure`, whose sentence is what
            // the writer actually reads. Naming `research/` here would promise a
            // silent redirect §6.2 forbids.
            return "nowhere, until the association is fixed"
        }
    }

    /// **A palette card is never routed** — the wall is project-level and a card
    /// filed into a piece's `research/` is off the wall entirely. What the
    /// association buys it is the LINK, and only on the row that writes one:
    /// `PromotionPerformer.linkTargetForCard` tests `.sharedPlusLink` and nothing
    /// else, so this names a link on that row and nothing else.
    static func paletteCardDestination(_ piece: PromotionPiece) -> String {
        if case .routed(_, let title, .sharedPlusLink) = piece {
            return "the palette wall, linked to “\(title)”"
        }
        return "the palette wall"
    }

    /// **It APPENDS, and §6.1 requires the writer see what will be produced and
    /// where.** One intent doc per scope, added to rather than replaced — so two
    /// cards promoted to craft intent stack, and a destination reading only "the
    /// project's craft intent" left that discoverable by doing it.
    ///
    /// **The piece appears on EVERY routed row, matching
    /// `PromotionPerformer.intentScope`** (M1A). It appeared on `.ownResearch`
    /// alone while an intent doc was located by the piece's research path
    /// prefix — a chapter's would have landed where that lookup never looked —
    /// and a statement is found by scope, so the narrowing went with the defect.
    /// Left as it was, this sentence would promise a novel chapter the project's
    /// intent while the performer wrote the chapter's: a preview that is wrong
    /// about where the writer's words are going, which is what §6.1 forbids.
    /// `.none` and `.unroutable` are the project's, which is exactly the
    /// fallback the performer takes.
    ///
    /// **It reads as the object of a sentence, because it is one twice over.**
    /// The sheet puts it after "Goes to" and
    /// `PromotionResult.confirmation(for:)` puts it after "Added to" — the
    /// confirmation used to spell "the project's craft intent" out for itself,
    /// and the moment this function learned about pieces the two contradicted
    /// each other within a second on screen. "at the end of what is already
    /// there" rather than "added to the end of", so one phrase serves both
    /// without the verb arriving twice; it still says plainly that this appends,
    /// which is what §6.1 requires of it.
    static func craftIntentDestination(_ piece: PromotionPiece) -> String {
        if case .routed(_, let title, _) = piece {
            return "“\(title)”’s craft intent, at the end of what is already there"
        }
        return "the project's craft intent, at the end of what is already there"
    }

    // MARK: - A stale association

    /// The failure a piece association would cause, or nil.
    ///
    /// **One rule, two readers.** The sheet refuses before Commit with this
    /// value's own sentence and the performer throws this value after, so a
    /// refusal the writer meets before committing and one they meet after cannot
    /// be two wordings of the same fact — `blockedReason`'s rule, applied again.
    ///
    /// **Only the two rows that hand a scope to a `create…` call**, which is
    /// where a bad scope throws: a new research note, and — since 1C-d — a new
    /// research *asset*, whose `createResearchAsset` routes through the same
    /// `ResearchScope.route`. A palette card is created regardless and simply
    /// takes no link, an appended image is not routed at all (the card is where
    /// it is), the craft intent falls back to project scope by design, and an
    /// update does not route. Refusing those would block promotions §6.2 says
    /// must work.
    ///
    /// The picker stopped offering unroutable pieces in the same slice, so this
    /// answers only for an association that has since gone stale — the piece
    /// deleted, or converted to a Collection reference piece. Before it existed
    /// the writer met `ProjectStoreError`'s own sentence, which names an id and
    /// describes the store rather than their situation.
    ///
    /// **`canCarryItsOwnPiece` has no default** (1C-d Task 8): both call sites
    /// resolve it from the scene, because the value that is wrong for a picture
    /// is `true`, and a defaulted `true` is how the refusal would come to name a
    /// Piece picker the item arm does not have with nothing red.
    static func pieceFailure(target: PromotionTarget, mode: PromotionMode,
                             piece: PromotionPiece,
                             canCarryItsOwnPiece: Bool) -> PromotionFailure? {
        guard scopedTargets.contains(target), case .new = mode,
              case .unroutable(_, let title, let inherited) = piece else { return nil }
        return .pieceIsNotAResearchTarget(title: title, inherited: inherited,
                                          canCarryItsOwnPiece: canCarryItsOwnPiece)
    }

    /// Whether this source has a Piece picker of its own — **which is a fact
    /// about the INSPECTOR, asked here so a refusal cannot name a control that is
    /// not on screen.**
    ///
    /// A scrap has one (`ScrapInspector`) and so does a region
    /// (`RegionInspector`). An **owned item node does not**: there is nothing
    /// about a photograph to associate, which is why `piece(for:in:)`'s second
    /// clause is the whole rule for one. A line has no piece at all.
    ///
    /// **One rule, two readers** — `PromotionSheetModel.pieceRefusal` and
    /// `PromotionPerformer.validate` — for `pieceIsInherited`'s reason: a second
    /// spelling is how the sentence the writer reads before Commit and the one
    /// they read after come to disagree.
    static func canCarryItsOwnPiece(_ source: PromotionSource,
                                    in scene: CanvasScene) -> Bool {
        switch source {
        case .scrap(let id):
            guard let kind = scene.node(id)?.kind else { return false }
            if case .item = kind { return false }
            return true
        case .region: return true
        case .line: return false
        }
    }

    /// The targets that hand a `ResearchScope` to a creation call — the ones a
    /// stale association can break. **Not a synonym for `updatableTargets`**: a
    /// palette card is updatable and is never routed, and a research asset is
    /// routed and can never be updated.
    static let scopedTargets: Set<PromotionTarget> = [.researchNote, .researchAsset]
}
