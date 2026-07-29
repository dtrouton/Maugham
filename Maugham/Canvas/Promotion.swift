import Foundation
import MaughamCore

/// What is being promoted.
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
    /// view's and covers only the two subjects that have a pane.)
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

    var id: String { rawValue }

    var writerFacingName: String {
        switch self {
        case .researchNote: return "Research note"
        case .paletteCard: return "Palette card"
        case .intentStatement: return "Craft intent"
        case .wikiLink: return "Wiki-link"
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
    var producedArtifactKind: ArtifactKind? {
        switch self {
        case .researchNote: return .researchNote
        case .paletteCard: return .paletteCard
        case .intentStatement: return .craftIntent
        case .wikiLink: return nil
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
    var namesItsArtifact: Bool {
        switch self {
        case .researchNote, .paletteCard: return true
        case .intentStatement, .wikiLink: return false
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

    static func over(research: [ResearchItem]) -> ArtifactIndex {
        // `PaletteLookup` is the ONE definition of "which research items are
        // palette cards" (tripwire 19) — a local predicate here would be the
        // fourth surface spelling it.
        let paletteCards = Set(PaletteLookup.paletteCards(in: research).map(\.id))
        return ArtifactIndex(entriesByID: Dictionary(
            TreeWalk.collect(in: research, where: { _ in true }).map { item in
                let kind: ArtifactKind
                if isCraftIntent(item) {
                    kind = .craftIntent
                } else if paletteCards.contains(item.id) {
                    kind = .paletteCard
                } else {
                    kind = .researchNote
                }
                return (item.id, Entry(title: item.title, kind: kind))
            },
            uniquingKeysWith: { _, later in later }))
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
    /// The destination artifact's body as read from disk when the target was
    /// chosen, for the wiki-link duplicate check. `nil` when not applicable or
    /// not read. **A snapshot** — the performer checks again against the live
    /// file, because this one can be stale by the time the writer commits.
    var destinationBody: String?
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
         destinationBody: String? = nil,
         piece: PromotionPiece = .none) {
        self.source = source
        self.target = target
        self.mode = mode
        self.scraps = scraps
        self.paletteKind = paletteKind
        self.artifacts = artifacts
        self.destinationBody = destinationBody
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
    var contributors: [CanvasNodeID] = []

    /// True when the link this plan would write is already in the destination.
    /// The sheet says so and refuses; the performer refuses too, against the
    /// live file.
    let linkAlreadyPresent: Bool
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
            // Only scraps promote. An item already exists as itself; promoting
            // it would duplicate it, and two editable copies of one note is
            // exactly what §4.3 rejects.
            guard case .scrap = scene.node(id)?.kind else { return [] }
            return [.researchNote, .paletteCard, .intentStatement]

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

    /// Why a source cannot be promoted, in words a writer can act on.
    ///
    /// **Three selections reach the sheet with nothing to offer, and for one
    /// slice only the line said why.** An empty scrap is offered all three
    /// targets by `targets(for:)` — emptiness is not a targets question — and
    /// then `plan(_:)` returns nil, so `preview`, `resolvedPlan` and `refusal`
    /// were all nil together and the writer met an empty Name field, no
    /// destination, no message and a dead button. An item node offered `[]` and
    /// said nothing at all. Both are answered here, where the sheet already
    /// looks.
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
            if case .item = node.kind { return itemNodeReason }
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

    /// Why an item node offers nothing. Held as a constant because three places
    /// now reason about it — the renderer's mark, the accessibility label and
    /// this — and the wording is what a writer reads.
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
            let body = text(of: id, in: request.scraps)
            guard !body.isEmpty else { return nil }
            return PromotionPlan(
                source: request.source, producedKind: request.target,
                title: title(from: body), body: body,
                destinationDescription: destination(request),
                discards: [], offeredLinks: [], wikiLinkWrite: nil,
                mode: request.mode, paletteKind: request.paletteKind,
                linkAlreadyPresent: false)

        case .region(let id):
            guard let region = scene.region(id) else { return nil }
            let bodies = regionBodies(region, in: scene, scraps: request.scraps)
            // The scrap arm's guard, one row down — and `blockedReason` reads
            // the same helper, so the preview and the refusal agree about what
            // "empty" means rather than agreeing by coincidence.
            guard !bodies.isEmpty else { return nil }
            return PromotionPlan(
                source: request.source, producedKind: request.target,
                title: regionTitle(region),
                body: bodies.map(\.1).joined(separator: "\n\n"),
                destinationDescription: destination(request),
                // The spatial work is not carried across, and the writer is told.
                discards: [.lines, .layout],
                offeredLinks: bodies.compactMap { nodeID, _ in
                    guard let itemID = resolvedArtifact(of: nodeID, in: scene,
                                                        artifacts: request.artifacts),
                          let title = request.artifacts.title(of: itemID) else { return nil }
                    return PromotionLinkOffer(node: nodeID, itemID: itemID, title: title)
                },
                wikiLinkWrite: nil, mode: request.mode,
                paletteKind: request.paletteKind,
                contributors: bodies.map(\.0), linkAlreadyPresent: false)

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
                linkAlreadyPresent: request.destinationBody?.contains(write.linkText) ?? false)
        }
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
    /// The piece appears on one row only, matching
    /// `PromotionPerformer.intentPiece`: an intent doc created under a novel
    /// chapter's shared+link routing lands where `craftIntentItem(forPieceId:)`
    /// never looks, so it is the project's — and the copy says the project's.
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
        if case .routed(_, let title, .ownResearch) = piece {
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
    /// **Only a NEW research note.** It is the one path that hands a scope to
    /// `createResearchNote`, and so the one that can throw. A palette card is
    /// created regardless and simply takes no link; the craft intent falls back
    /// to project scope by design; an update does not route at all. Refusing
    /// those would block promotions §6.2 says must work.
    ///
    /// The picker stopped offering unroutable pieces in the same slice, so this
    /// answers only for an association that has since gone stale — the piece
    /// deleted, or converted to a Collection reference piece. Before it existed
    /// the writer met `ProjectStoreError`'s own sentence, which names an id and
    /// describes the store rather than their situation.
    static func pieceFailure(target: PromotionTarget, mode: PromotionMode,
                             piece: PromotionPiece) -> PromotionFailure? {
        guard target == .researchNote, case .new = mode,
              case .unroutable(_, let title, let inherited) = piece else { return nil }
        return .pieceIsNotAResearchTarget(title: title, inherited: inherited)
    }
}
