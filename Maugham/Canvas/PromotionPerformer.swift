import Foundation
import MaughamCore

/// What a promotion produced.
struct PromotionResult: Equatable {
    /// The artifact's id — a research item's, or, since M1A, an intent
    /// `Statement`'s. Both are resolved through `ArtifactIndex`, which is what
    /// makes a mark carrying either one meaningful to every reader of it.
    let createdItemID: String?
    /// The artifact's title AS CREATED — `addResearchTextNote` dedupes, so this
    /// is not always the title the writer typed.
    let title: String
    /// The members whose own notes gained a link, when the offer was accepted.
    let writtenLinks: [CanvasNodeID]

    /// One sentence naming what was produced, and the link count when links
    /// were actually written.
    ///
    /// **The result used to be discarded at the only call site.** Every field
    /// here was built and thrown away by `CanvasPromotionModifier.commit`, while
    /// `writeOfferedLinks`'s own doc comment said the count "reaches the writer".
    /// It reached nobody — a rule whose stated reason is false, which this
    /// codebase treats as worse than no rule. It bites hardest on a line: a
    /// wiki-link promotion sets no mark by design, so without this the sheet
    /// closes and *nothing observable changes anywhere*.
    ///
    /// A pure function of two values, so the wording is pinned by a test that
    /// hosts no SwiftUI.
    ///
    /// **The craft-intent arm reads the plan's own destination rather than
    /// restating it**, and the second spelling is what let the two drift: this
    /// sentence was written while an intent was always the project's, and 1C-c2a
    /// taught `Promotion.craftIntentDestination` to scope one to a Collection
    /// loose piece. In a Collection the sheet then said *"Story A"'s craft
    /// intent* and the banner, a second later, said *Added to the project's
    /// craft intent* — sending the writer to look in the project's `research/`
    /// for a document sitting in `pieces/story-a/research/`. One value, read
    /// where it was resolved.
    func confirmation(for plan: PromotionPlan) -> String {
        let count = writtenLinks.count
        let links = count == 0 ? ""
            : " Linked \(count) note\(count == 1 ? "" : "s") to it."
        switch plan.producedKind {
        case .researchNote: return "Promoted to the note “\(title)”." + links
        case .paletteCard: return "Promoted to the palette card “\(title)”." + links
        case .intentStatement: return "Added to \(plan.destinationDescription)."
        case .wikiLink: return "Wrote the link into the note “\(title)”."
        // **Both say "a copy", because that is the fact a writer will test.**
        // The picture stays on the canvas and the original file stays in
        // `canvas_assets/` (§6.1's ruling 1) — a sentence reading "Moved" or
        // "Filed" would describe the variant this design rejected.
        case .researchAsset: return "Copied the picture into research as “\(title)”."
        case .paletteCardImage:
            return "Added a copy of the picture to the palette card “\(title)”."
        }
    }
}

enum PromotionFailure: LocalizedError, Equatable {
    case emptyTitle
    /// Nothing to promote. **It carries its source for the NOUN alone**: the
    /// sentence said "this card" for an empty region too, which is the wrong
    /// word on the row whose headline verb is now "a cluster of scraps is a
    /// note".
    case emptyBody(source: PromotionSource)
    case missingWikiLinkWrite
    case linkAlreadyPresent
    case artifactMissing(String)
    /// The mark names a real artifact of the WRONG kind — a palette card or a
    /// craft-intent doc where a research note was to be rewritten.
    case artifactIsADifferentKind(itemID: String, found: String)
    case itemHasNoFile(String)
    /// The destination exists on disk and could not be READ. Distinct from
    /// "no file there", which is legitimately empty — see `readBody`.
    case unreadableFile(String)
    /// The piece association names something a research note cannot be created
    /// under: the piece is gone (title nil), or it is a Collection reference
    /// piece, which keeps its research in its own project.
    ///
    /// **Three axes, because the fix half has to name a control that exists.**
    /// The title says what went wrong; `inherited` says *whose* association it
    /// is — a card that lives in a region whose piece was deleted carries nothing
    /// itself, so "clear the association" would name a Picker already reading
    /// None while the stale field sits on the region.
    ///
    /// **`canCarryItsOwnPiece` is the third, and it is the same rule failing one
    /// arm over** (1C-d Task 8, review M2). The inherited half offered *"or give
    /// this card a piece of its own"*, which is a real act for a scrap and names
    /// **nothing at all** for an owned picture: `ItemInspector` has no Piece
    /// picker, because there is nothing about a photograph to associate. Reached
    /// by promoting a picture whose home region's piece has since been deleted or
    /// converted. `Promotion.canCarryItsOwnPiece(_:in:)` is the one rule and both
    /// callers ask it.
    case pieceIsNotAResearchTarget(title: String?, inherited: Bool,
                                   canCarryItsOwnPiece: Bool)
    /// A picture row whose plan carries no `PromotedPicture` — the node stopped
    /// being an owned item between the sheet opening and Commit, or a caller
    /// hand-built the plan. It refuses rather than reaching into the scene for a
    /// substitute file.
    case nothingToCopy
    /// A file named by the plan is not on disk. Reachable: the well is content
    /// the writer can delete, and `canvas_assets/` and `research/` are ordinary
    /// folders in their project.
    ///
    /// **It carries its SOURCE, and that is `emptyBody`'s axis arriving for
    /// `emptyBody`'s reason** (1C-d Task 12a, review Minor 1). The sentence read
    /// "The picture this **card** shows…" and became reachable from a REGION in
    /// the same task — where the writer selected a region, has not selected any
    /// card, and the only identifier the sentence offers is a minted path that
    /// `CanvasItemFacts.ownedTitle` argues at length is "the clock reading at the
    /// moment they dropped it" rather than the writer's word for the picture. So
    /// it pointed at an unidentifiable card with a filename this codebase has
    /// already ruled meaningless.
    ///
    /// That is the class this area has now fixed three times: `emptyBody` gained
    /// `PromotionSource.noun` for "There is nothing in this **card** to promote"
    /// said over a region, `pieceIsNotAResearchTarget` gained its third axis for
    /// "a refusal may only name a control that is on the arm the writer is
    /// looking at", and this is the same rule on the same file's other sentence.
    case pictureIsGone(path: String, source: PromotionSource)
    /// The chosen palette card is no longer in the project. The picker was built
    /// from a snapshot taken when the sheet opened.
    case paletteCardIsGone

    var errorDescription: String? {
        switch self {
        case .emptyTitle: return "This needs a name before it can be promoted."
        case .emptyBody(let source):
            return "There is nothing in this \(source.noun) to promote."
        case .missingWikiLinkWrite: return "This line has nothing to link."
        case .linkAlreadyPresent: return "That link is already in the note."
        case .artifactMissing(let id):
            return "The artifact this card produced is no longer in the project (\(id))."
        case .artifactIsADifferentKind(_, let found):
            return "What this produced is \(found) now, not a research note, so "
                + "Maugham did not write over it."
        case .itemHasNoFile(let id): return "That artifact has no file on disk (\(id))."
        case .unreadableFile(let path):
            return "Maugham could not read what is already in \(path), so it did not "
                + "write over it."
        case .pieceIsNotAResearchTarget(let title, let inherited, let canCarryItsOwnPiece):
            // Composed from halves rather than written out six times: what is
            // wrong, then the act that fixes it. The second half is the one that
            // has to be right — a refusal naming a control the writer cannot use
            // leaves them stuck at it.
            let problem = title.map { "“\($0)” cannot keep research of its own" }
                ?? "The piece this is associated with is no longer in the project"
            let fix: String
            switch (inherited, canCarryItsOwnPiece) {
            case (true, true):
                fix = "That piece comes from the region this card lives in — change "
                    + "it there, or give this card a piece of its own."
            case (true, false):
                // An owned picture: the region's picker is the ONLY control, and
                // offering a second one it does not have is what this axis exists
                // to prevent.
                fix = "That piece comes from the region this lives in — change it there."
            case (false, _):
                fix = "Pick another piece in the inspector, or clear the association."
            }
            // **"it" rather than "the note", since 1C-d.** This sentence is
            // reached by a research ASSET as well now (`Promotion.scopedTargets`),
            // and a picture told its *note* has nowhere to go is a refusal
            // describing something the writer is not doing.
            return problem + ", so there is nowhere to file it. " + fix
        case .nothingToCopy:
            return "There is no picture on this card to promote."
        case .pictureIsGone(let path, let source):
            // The SUBJECT differs by source and the rest of the sentence does
            // not — `pieceIsNotAResearchTarget`'s halves, one failure over.
            let subject: String
            switch source {
            case .scrap:
                // A card the writer selected and is looking at, which is what
                // makes "this card" exact rather than sloppy: a card holds a
                // picture, and the two can be spoken of separately
                // (`PromotionSource.noun`'s ruling).
                subject = "The picture this card shows"
            case .region:
                // They selected a region and no card, so no card is "this" one.
                subject = "A picture in this region"
            case .line:
                // **Unreachable, and neutral rather than borrowing either
                // noun**: a line's plan carries no pictures, and a later row
                // that could reach this must not silently inherit a subject
                // that is wrong for it.
                subject = "A picture this would copy"
            }
            return subject + " is no longer in the project (\(path)), so there "
                + "is nothing to copy."
        case .paletteCardIsGone:
            return "That palette card is no longer in the project, so the picture "
                + "has nowhere to go."
        }
    }
}

extension PromotionPiece {

    /// Resolve a source's piece association against the LIVE manifest.
    ///
    /// **The one place the pure half meets the router**, and the reason it is one
    /// place rather than two: the sheet calls it when it opens and the performer
    /// calls it when it validates, so the destination the writer read and the
    /// destination they get cannot disagree about which row of §6.2's table this
    /// is.
    ///
    /// The piece itself comes from `Promotion.piece` — the precedence resolver —
    /// never from `node.boundPieceID`, or an inherited association would resolve
    /// to nothing here while the performer routed by it.
    @MainActor
    static func resolve(for source: PromotionSource, in scene: CanvasScene,
                        store: ProjectStore) -> PromotionPiece {
        guard let id = Promotion.piece(for: source, in: scene) else { return .none }
        // Nil for a piece that has been deleted — which is the case that gets its
        // own sentence, so it is resolved rather than defaulted to the raw id.
        let title = TreeWalk.collect(in: store.manifest.structure,
                                     where: { $0.id == id }).first?.title
        // Asked through `Promotion` rather than by reading the node's field, so
        // the refusal's "whose association is this" and the pane's
        // "(from its region)" are one answer.
        let inherited = Promotion.pieceIsInherited(for: source, in: scene)
        guard let routing = try? store.researchRouting(forDocumentId: id) else {
            return .unroutable(id: id, title: title, inherited: inherited)
        }
        switch routing {
        case .pieceFolder:
            return .routed(id: id, title: title ?? id, route: .ownResearch)
        case .sharedPlusLink:
            return .routed(id: id, title: title ?? id, route: .sharedPlusLink)
        case .sharedOnly:
            return .routed(id: id, title: title ?? id, route: .sharedOnly)
        }
    }
}

/// Performs a `PromotionPlan`.
///
/// **`@MainActor`, `async throws`, and no `inout` on this path.** `ProjectStore`
/// is `@MainActor` and every creation API is `async throws`; an
/// `inout CanvasScene` cannot cross an `await` in Swift 6. Scene changes go
/// through `CanvasModel`, synchronously, after the awaits.
///
/// **Tripwire 32: every scene change here is `mutateFromInspector`.** This is
/// not `CanvasView`, and `beginPromotion` can run while a focused scrap holds
/// "Edit Scrap" open — nested, the mark would register no undo step of its own
/// and would ride into the writer's next sentence, where a ⌘Z aimed at a
/// sentence takes the mark with it. `TripwireGrepTests` names this file.
///
/// **Validate first, write second.** A refused promotion leaves nothing behind;
/// a half-created artifact on a surface whose whole promise is predictability is
/// worse than a refusal.
///
/// **What ⌘Z takes back is the MARK, not the artifact.** The canvas's undo is
/// scene-scoped by design (ADR 0026 §5); the note it produced is a real file
/// with the research tree's own lifecycle. The guide says so, because a writer
/// will try it.
@MainActor
struct PromotionPerformer {

    let store: ProjectStore
    let model: CanvasModel

    /// The live index over BOTH artifact registries, read off the manifest at
    /// the moment it is asked.
    ///
    /// **A property rather than a value threaded in**, because a plan is a
    /// snapshot taken when the sheet opened and every reader here is deliberately
    /// re-reading the manifest at Commit — the artifact can have changed kind, or
    /// gone, in between.
    private var artifacts: ArtifactIndex {
        ArtifactIndex.over(research: store.manifest.research,
                           statements: store.manifest.statements,
                           structure: store.manifest.structure)
    }

    /// A manuscript document's title, for the one thing that needs it: naming a
    /// document-scoped statement (`ArtifactIndex.statementTitle`).
    private func documentTitle(_ id: String) -> String? {
        TreeWalk.collect(in: store.manifest.structure, where: { $0.id == id }).first?.title
    }

    func perform(_ plan: PromotionPlan) async throws -> PromotionResult {
        try validate(plan)
        switch plan.producedKind {
        case .researchNote: return try await performResearchNote(plan)
        case .paletteCard: return try await performPaletteCard(plan)
        case .intentStatement: return try await performCraftIntent(plan)
        case .wikiLink: return try await performWikiLink(plan)
        case .researchAsset: return try await performResearchAsset(plan)
        case .paletteCardImage: return try await performPaletteCardImage(plan)
        }
    }

    // MARK: - Validation

    private func validate(_ plan: PromotionPlan) throws {
        // **Every file this plan copies, whichever row planned it** — the two
        // picture rows plan one and a region's palette row plans as many as it
        // holds (1C-d Task 12a). One spelling rather than one per arm: the well
        // and `research/` are both ordinary folders in the writer's project, so
        // a node naming a file that is gone is a real state on every row that
        // copies one, and "validate first, write second" is what keeps a
        // half-furnished palette card off the wall. `Promotion` cannot
        // pre-filter these — it is the pure half and touches no disk — so a
        // refusal here is the only honest answer to a preview that named the
        // picture.
        //
        // **Above the switch, and that position is the refusal ORDER** (review
        // Minor 3). Below it, a `.paletteCardImage` plan whose file and whose
        // card had both gone met `paletteCardIsGone` first — so the writer
        // picked another card and met `pictureIsGone` on the next attempt, two
        // round trips for one dead promotion. A missing file kills the promotion
        // whatever card is chosen; a missing card does not. The more fundamental
        // refusal goes first, and `test_aPromotionWhosePictureAndCardAreBothGone
        // NamesThePictureFirst` pins it so the next hoist is a decision.
        for picture in plan.pictures
        where !FileManager.default.fileExists(atPath: assetURL(picture).path) {
            throw PromotionFailure.pictureIsGone(path: picture.assetPath,
                                                 source: plan.source)
        }
        switch plan.producedKind {
        case .researchNote, .paletteCard:
            guard !plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PromotionFailure.emptyTitle }
            guard !plan.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PromotionFailure.emptyBody(source: plan.source) }
        case .intentStatement:
            // **No title guard**, because `performCraftIntent` never reads one:
            // the intent doc is find-or-create at a fixed title and the body is
            // appended. Refusing a plan for a missing name would refuse it for
            // a field that changes nothing — and the sheet stopped asking for
            // one in the same edit, so the two agree.
            guard !plan.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PromotionFailure.emptyBody(source: plan.source) }
        case .wikiLink:
            guard plan.wikiLinkWrite != nil else { throw PromotionFailure.missingWikiLinkWrite }
            guard !plan.linkAlreadyPresent else { throw PromotionFailure.linkAlreadyPresent }
        case .researchAsset, .paletteCardImage:
            // **A FILE rather than a body, and that is why these are their own
            // arms.** A picture has no prose: routed through the arm above, every
            // owned promotion would refuse with `emptyBody` — "There is nothing
            // in this card to promote." — for the one thing that is not true of
            // it, and in the wrong noun besides
            // (`PromotionSource.noun`'s own reachability argument).
            let picture = try requirePicture(plan)
            if plan.producedKind == .paletteCardImage {
                // Read back off the live store, not off the plan: the picker was
                // built from a snapshot taken when the sheet opened, and
                // `addImage` would otherwise throw `structureMissing` — a
                // store-shaped sentence naming nothing the writer can act on —
                // AFTER the flush.
                guard let cardID = picture.paletteCardID,
                      store.loadPaletteCards().contains(where: { $0.researchItemId == cardID })
                else { throw PromotionFailure.paletteCardIsGone }
            }
        }
        // Asked of the index rather than of `manifest.research` directly, and
        // the difference is one case: since M1A a mark can name a STATEMENT, and
        // a research-only existence check would refuse that update as
        // `artifactMissing` — "no longer in the project", said of the writer's
        // intent, which is right there — instead of letting
        // `refuseIfNotAResearchNote` say what it actually is.
        if case .update(let itemID, _) = plan.mode, artifacts.title(of: itemID) == nil {
            throw PromotionFailure.artifactMissing(itemID)
        }
        // **A stale association, refused here rather than inside
        // `createResearchNote`.** The picker no longer offers a piece the router
        // throws on, but an association already made can go stale — the piece
        // deleted, or converted to a Collection reference piece. Without this the
        // writer met `ProjectStoreError`'s own sentence ("Referenced pieces keep
        // research in their own project: ref-1"), which names an id and describes
        // the store. And it belongs in `validate` because that is what makes it
        // write nothing: refused inside the creation call it would already have
        // been past the flush.
        if let failure = Promotion.pieceFailure(
            target: plan.producedKind, mode: plan.mode,
            piece: PromotionPiece.resolve(for: plan.source, in: model.scene, store: store),
            canCarryItsOwnPiece: Promotion.canCarryItsOwnPiece(plan.source, in: model.scene)) {
            throw failure
        }
    }

    /// Refuse an update whose target is not a plain research note.
    ///
    /// Read off the live manifest through the same index the sheet uses, so the
    /// performer and the preview cannot disagree about what an item *is*. The
    /// palette path needs no twin of this: `performPaletteCard`'s update branch
    /// reads the card back out of `loadPaletteCards()` and already throws
    /// `.artifactMissing` when the id is not a palette card, and craft intent is
    /// not updatable at all.
    private func refuseIfNotAResearchNote(_ itemID: String) throws {
        switch artifacts.kind(of: itemID) {
        case .researchNote, nil: return   // nil is `artifactMissing`'s case, thrown by `validate`
        case .paletteCard:
            throw PromotionFailure.artifactIsADifferentKind(itemID: itemID,
                                                            found: "a palette card")
        case .craftIntent:
            // "a craft intent" rather than "the project's": since M1A a chapter
            // has one of its own, so naming the project's would be wrong about
            // which artifact was spared.
            throw PromotionFailure.artifactIsADifferentKind(itemID: itemID,
                                                            found: "a craft intent")
        case .researchAsset:
            // Not reachable from the UI — nothing offers an Update against a
            // picture's mark — and the cheapest possible insurance against the
            // one thing below this line: `updateResearchItem` renames the backing
            // file and `writeBody` writes over it, which for an asset means a
            // `.png` renamed to a card's first line with prose inside it.
            throw PromotionFailure.artifactIsADifferentKind(itemID: itemID,
                                                            found: "a picture")
        }
    }

    // MARK: - The four targets

    private func performResearchNote(_ plan: PromotionPlan) async throws -> PromotionResult {
        let itemID: String
        switch plan.mode {
        case .new:
            // **The piece decides where, and the deciding is not done here**
            // (spec §6.2). `ResearchScope.route` has routed `.document(id)` by
            // project type since the 2026-07-07 scoped-research milestone — the
            // piece's own `research/` for a collection loose piece, shared plus
            // a `linkResearch` record for a novel chapter, shared alone for a
            // short story or screenplay — and it writes the link itself. A
            // `switch manifest.type` in this file would be a second copy of that
            // table, and a copy is how the two drift.
            itemID = try await store.createResearchNote(
                scope: scope(for: plan.source), title: plan.title).id
        case .update(let existing, _):
            // **No scope on this arm, deliberately.** The artifact already
            // exists where it exists; an update is about the body, and re-filing
            // the writer's note — or retrofitting a link — because they changed
            // a card's association is exactly the surprise §6.1 forbids.
            //
            // **The plan is a SNAPSHOT and the artifact can change under it**,
            // so the kind is checked here as well as in `Promotion`: the sheet
            // read the manifest when it opened, and between then and Commit the
            // writer can have converted the note, moved it into the palette
            // group, or stamped it. Everything below this line renames a file
            // and writes raw scrap text over its body — cheap insurance against
            // doing that to a palette card.
            try refuseIfNotAResearchNote(existing)
            // Renames the backing file through the typed mover when the title
            // moved (tripwire 14 is satisfied by using this API rather than a
            // raw move of our own).
            try await store.updateResearchItem(id: existing, title: plan.title)
            itemID = existing
        }
        try await writeBody(plan.body, toItem: itemID)
        let title = TreeWalk.find(id: itemID, in: store.manifest.research)?.title ?? plan.title
        // The mark BEFORE the offer: a link-write failure must not leave an
        // artifact the canvas has forgotten it produced, because the writer's
        // retry would then mint a second one.
        mark(itemID, for: plan.source,
             named: isRegion(plan.source) ? "Promote Region" : "Promote Scrap",
             contributors: plan.contributors)
        let written = try await writeOfferedLinks(plan, artifactTitle: title)
        return PromotionResult(createdItemID: itemID, title: title, writtenLinks: written)
    }

    private func performPaletteCard(_ plan: PromotionPlan) async throws -> PromotionResult {
        // **The flush is not optional here either**, and this is the path that
        // escaped it: `ProjectStore+Palette.paletteCoordinatedWrite` does not
        // flush, so a queued 750 ms `scheduleFileSave` for this card — the
        // writer was editing it in the research pane a moment ago — would fire
        // AFTER the promotion and restore the pre-promotion prose. It runs
        // before the `loadPaletteCards()` read-back too, or the swatches and
        // images carried across would themselves be stale.
        try? await store.documentStore?.flushPendingSave()
        let itemID: String
        switch plan.mode {
        case .new:
            // **A palette card is NEVER routed** (spec §6.2). The wall is
            // project-level and `addPaletteCard` has to put the card under the
            // palette group — a card filed into a piece's `research/` is off the
            // wall entirely. What the association buys the card is the LINK, and
            // only where the routing would have been `.sharedPlusLink`, read
            // from the same function the note path routes through so the
            // decision has one source.
            itemID = try await store.addPaletteCard(title: plan.title,
                                                    kind: plan.paletteKind).id
            if let documentID = linkTargetForCard(plan.source) {
                try await store.linkResearch(researchId: itemID, toDocumentId: documentID)
            }
        case .update(let existing, _):
            itemID = existing
        }
        // Read the card back and replace ONLY the title, kind and body. A card
        // the writer has since given swatches, sensory notes or images must not
        // lose them to an update that was always about the prose.
        guard let current = store.loadPaletteCards().first(where: { $0.researchItemId == itemID })
        else { throw PromotionFailure.artifactMissing(itemID) }
        try await store.updatePaletteCard(PaletteCard(
            researchItemId: itemID, title: plan.title, kind: plan.paletteKind,
            swatches: current.swatches, notes: current.notes,
            imagePaths: current.imagePaths, body: plan.body))
        // **The pictures in the region, AFTER that write and never before**
        // (spec §6's 2026-07-29 amendment, built 1C-d Task 12a). The line above
        // writes the whole card from `current`, which was read before any
        // append — so appending first and updating second would carry the stale
        // image list back over the new one and drop every picture this promotion
        // just added. `addImage` reads the card fresh and appends, so each of
        // these lands on top of everything already there: the card's own
        // pictures, and the ones before it in the region's reading order.
        //
        // **Append, never replace** — the 1C-c2 Critical's exact shape is a
        // promotion that rewrites a palette card's backing file and takes its
        // swatches, kind, sensory notes and image references with it, and ⌘Z
        // gives back only the mark. `PromotionPicturePerformerTests` and
        // `PromotionRegionPicturePerformerTests` both assert the card's earlier
        // images survive rather than assuming it.
        for picture in plan.pictures {
            _ = try await store.addImage(toPaletteCard: itemID,
                                         fileURL: assetURL(picture))
        }

        let title = TreeWalk.find(id: itemID, in: store.manifest.research)?.title ?? plan.title
        mark(itemID, for: plan.source,
             named: isRegion(plan.source) ? "Promote Region" : "Promote Scrap",
             contributors: plan.contributors)
        let written = try await writeOfferedLinks(plan, artifactTitle: title)
        return PromotionResult(createdItemID: itemID, title: title, writtenLinks: written)
    }

    /// Add this card's words to the end of an intent statement (M1A).
    ///
    /// **The statement is found by SCOPE, and the scope is the source's own
    /// document.** Nothing here reads a path prefix, which is what the old craft
    /// intent was located by and what forced its narrowing rule — see
    /// `intentScope` for the rule that replaced it.
    private func performCraftIntent(_ plan: PromotionPlan) async throws -> PromotionResult {
        // Find-or-create, idempotent: one statement per (kind, scope).
        let statement = try await store.createStatement(kind: .intent,
                                                        scope: intentScope(plan.source))
        try await append(plan.body, to: statement)
        // `plan.contributors` rather than `[]`, and it is not defensive padding:
        // only a scrap can reach an intent statement today (`Promotion.targets`
        // offers a region `.researchNote` and `.paletteCard` only), so this list
        // is always empty — but writing `[]` here would be a second rule about
        // who records, and if a region ever gains this target the second rule is
        // the one that would silently be wrong.
        mark(statement.id, for: plan.source, named: "Promote Scrap",
             contributors: plan.contributors)
        return PromotionResult(createdItemID: statement.id,
                               title: ArtifactIndex.statementTitle(
                                statement, documentTitle: documentTitle),
                               writtenLinks: [])
    }

    /// Put `text` at the end of a statement, **through its op log**.
    ///
    /// There is no read-back-from-disk and no flush dance here, and their
    /// absence is the point: the op log is the source of truth (ADR 0019), so
    /// the prior text is the `Document`'s own and a queued 750 ms save cannot
    /// race an append the way it races a whole-file write.
    ///
    /// **The live `Document` FIRST, and never a second one on the same path.**
    /// A statement's `Document` is deliberately in no `DocumentStore` registry
    /// (spec §8, `StatementEditorHost`), so `document(forDocId:)` cannot find an
    /// open statement — and `.intent` is a pane of the Plan persona, the persona
    /// the canvas lives in, so the writer really can have this statement open in
    /// the right column while promoting a card in the centre. Two `Document`s on
    /// one path each hold their own paragraph state and their own
    /// `PendingBuffer`; whichever writes last decides the sequence, so the
    /// promoted paragraph is written back out of the statement by the pane's
    /// next burst. `ProjectStore.openStatementDocument(id:)` is the seam both
    /// sides go through, and the lookup-plus-write below does not suspend, so
    /// the pane cannot close its `Document` between them.
    ///
    /// **The open pane redraws off the shared `Document` with no push from
    /// here, and that is measured rather than assumed** (2026-08-01). It is not
    /// obvious: `StatementEditorHost.body` deliberately reads no text, so the
    /// expectation was that nothing would invalidate it — the first cut of this
    /// added an out-of-band-change event for the pane to service. Instrumented,
    /// SwiftUI's observation reaches the binding's own `get` inside
    /// `EditorSurface.updateNSView`, so writing `displayText` re-renders the host
    /// and the buffer swaps through the one sanctioned `applyExternalText` site.
    /// The event was deleted as machinery nothing needed;
    /// `test_promotingWhileTheIntentPaneIsOpenDoesNotOpenASecondDocument` is what
    /// holds the OUTCOME — the writer's next keystroke does not write the
    /// promotion back out — so if that ever stops being true it goes red rather
    /// than the loss being silent.
    ///
    /// `Document.load` stays the only construction path (hard invariant;
    /// `BootstrapWiringTests`).
    private func append(_ text: String, to statement: Statement) async throws {
        if let live = store.openStatementDocument(id: statement.id) {
            live.setFullText(appending(text, to: live.displayText))
            // Durable now rather than on the pane's own debounce: a promotion is
            // an act the writer has committed to, and the banner says it landed.
            try? await live.flushBurstNow()
            return
        }
        let document = try await Document.load(
            url: store.url.appendingPathComponent(statement.path),
            device: MacDeviceID.current,
            session: Self.promotionSession,
            presenter: store.documentStore?.presenter)
        document.setFullText(appending(text, to: document.displayText))
        // Awaited, unlike `withAnnotationDocument`'s fire-and-forget close: that
        // path has already appended its ops itself, and this one's words are
        // still in the pending buffer until the close flushes it.
        await document.close()
    }

    /// A blank line between what is there and what is arriving, and nothing at
    /// all in front of the first promotion into an empty statement.
    private func appending(_ text: String, to existing: String) -> String {
        existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? text
            : existing + "\n\n" + text
    }

    /// Session id for the ops a promotion writes when no pane has the statement
    /// open. Stable for the launch, like every other session stamp.
    private static let promotionSession = "promotion-\(UUID().uuidString)"

    private func performWikiLink(_ plan: PromotionPlan) async throws -> PromotionResult {
        guard let link = plan.wikiLinkWrite else { throw PromotionFailure.missingWikiLinkWrite }
        guard let item = TreeWalk.find(id: link.intoItemID, in: store.manifest.research),
              let path = item.path else {
            throw PromotionFailure.artifactMissing(link.intoItemID)
        }
        try? await store.documentStore?.flushPendingSave()
        let body = try readBody(atPath: path)
        // The plan's own check was against a SNAPSHOT taken when the sheet
        // opened. This one is against the file.
        guard !body.contains(link.linkText) else { throw PromotionFailure.linkAlreadyPresent }
        try await write(body + link.appendedText, toPath: path)
        // No mark: a line's artifact is text inside somebody else's note, and a
        // flag on the line could disagree with the file.
        return PromotionResult(createdItemID: link.intoItemID, title: item.title, writtenLinks: [])
    }

    // MARK: - The picture (spec §6's 2026-07-30 amendment)

    /// File a COPY of the owned picture in `research/`.
    ///
    /// **A copy, and the node stays owned** (§6.1's ruling 1). Nothing here
    /// touches `canvas_assets/` or the node's kind: `createResearchAsset` copies
    /// through `DocumentStore.executeCopy`, so the canvas keeps its picture and
    /// research gets one of its own — exactly as promoting a scrap leaves the
    /// card's words on the canvas. Handing the file over instead would make this
    /// the one verb on the surface that moves, and a writer who promoted and
    /// then pressed ⌘Z would be relying on a file move to reverse.
    ///
    /// **The scope is `Promotion.piece`'s, unchanged.** `createResearchAsset` and
    /// `createResearchNote` are two arms of the same `ResearchScope.route`, so a
    /// picture in a region bound to a chapter is filed the way a note from that
    /// region would be — including the `linkResearch` record on a novel, which
    /// the router writes itself.
    private func performResearchAsset(_ plan: PromotionPlan) async throws -> PromotionResult {
        let picture = try requirePicture(plan)
        let item = try await store.createResearchAsset(scope: scope(for: plan.source),
                                                       fromURL: assetURL(picture))
        // The MARK, because this promotion produced an artifact of its own —
        // "I am this thing" is true of it, which is what `promotedItemID` means.
        mark(item.id, for: plan.source, named: Self.pictureStep,
             contributors: plan.contributors)
        return PromotionResult(createdItemID: item.id, title: item.title, writtenLinks: [])
    }

    /// Append a COPY of the owned picture to an existing palette card's image
    /// well.
    ///
    /// **It records a CONTRIBUTION and never the mark, and that is the whole of
    /// this method's design** (spec §6.3's rule, arriving on a new row).
    /// `promotedItemID` means *"I am this artifact"* and
    /// `Promotion.existingArtifact` reads it — only it — to offer **Rewrite**.
    /// A picture stamped with the palette card's id would therefore offer, on
    /// the second promotion, to rewrite a card holding swatches, sensory notes
    /// and other images with one photograph: the 1C-c2 Critical exactly, and the
    /// failure §6's amendment names. What is true is that the picture is *in*
    /// that card, alongside whatever else is, which is what the contribution
    /// record says.
    ///
    /// **The flush is not optional**, for `performPaletteCard`'s reason: the
    /// palette seam does not flush, and a queued 750 ms save for this card — the
    /// writer was editing it in the research pane a moment ago — would otherwise
    /// fire after the append and restore the pre-append image list.
    private func performPaletteCardImage(_ plan: PromotionPlan) async throws -> PromotionResult {
        let picture = try requirePicture(plan)
        guard let cardID = picture.paletteCardID else { throw PromotionFailure.paletteCardIsGone }
        try? await store.documentStore?.flushPendingSave()
        // `addImage(toPaletteCard:fileURL:)` — the ingestion pair §3.1's
        // amendment names, and the same call `InboxStore.promoteToPaletteCard`
        // makes for a photograph one hop earlier. It copies into the card's
        // `<slug>_assets/`, appends the path, and preserves everything else on
        // the card; the canvas is a caller here, never a storage decision.
        let card = try await store.addImage(toPaletteCard: cardID,
                                            fileURL: assetURL(picture))
        recordPicture(in: cardID, on: picture.node)
        return PromotionResult(createdItemID: cardID, title: card.title, writtenLinks: [])
    }

    /// The undo step both picture rows register. One name, because the writer
    /// took one action and reads this in the Edit menu.
    private static let pictureStep = "Promote Picture"

    /// The ONE picture the two picture rows promote.
    ///
    /// **`first` rather than an assertion that there is exactly one**, and the
    /// refusal is for an EMPTY list rather than a missing value since 1C-d Task
    /// 12a widened the field to a list for the region's row. Both of these rows
    /// are planned by `picturePlan`, which builds a single-element list, so a
    /// second element here is unreachable and a `count == 1` guard would be a
    /// rule with no failure behind it. What IS reachable is empty — the node
    /// stopped being an owned item between the sheet opening and Commit, or a
    /// caller hand-built the plan — and this refuses rather than reaching into
    /// the scene for a substitute file.
    private func requirePicture(_ plan: PromotionPlan) throws -> PromotedPicture {
        guard let picture = plan.pictures.first else { throw PromotionFailure.nothingToCopy }
        return picture
    }

    /// The owned file, absolute. The stored path is project-relative and stays
    /// that way — see `CanvasItemReference.owned(path:)` for what an absolute one
    /// costs — so this is the one place it is resolved against the project.
    private func assetURL(_ picture: PromotedPicture) -> URL {
        store.url.appendingPathComponent(picture.assetPath)
    }

    /// **Stamp WITHOUT clearing, and that is the difference from `record`.**
    /// A region's note is rewritten from its current members, so that path
    /// clears every record naming the artifact before it stamps; an image well
    /// is APPENDED to, and the card's earlier pictures are still in it. Routing
    /// this through `record` would make the second picture promoted onto a card
    /// erase the first one's record — a false sentence in a pane, which is the
    /// bug §6.3 exists to remove.
    ///
    /// One `mutateFromInspector` bracket, so one ⌘Z takes the record back
    /// (tripwire 32; the bracket cannot be `mutate`, and this can run while a
    /// focused scrap holds "Edit Scrap" open).
    private func recordPicture(in cardID: String, on node: CanvasNodeID) {
        model.mutateFromInspector(Self.pictureStep) {
            $0.setContributedItem(cardID, for: node)
        }
        model.bumpSceneRevision()
    }

    // MARK: - The offer (§6.1: may suggest, must never impose)

    /// Append `[[artifact]]` to each offered member's OWN note — the member
    /// pointing at what the region produced. Runs only when the writer accepted.
    ///
    /// **Returns what it actually WROTE, not what was offered.** Two members are
    /// skipped rather than written: one whose note already holds the link, and
    /// one whose item or path has since gone. "Linked 2 notes" when it linked
    /// none is a lie on a surface whose whole promise is that you can see what a
    /// command will do.
    ///
    /// **The count reaches the writer through `PromotionResult.confirmation(for:)`**,
    /// and this sentence used to be false: `CanvasPromotionModifier.commit`
    /// discarded the whole result, so every field here was built and thrown
    /// away. A rule whose stated reason is false is worse than no rule, and
    /// `PromotionCommandTests`' census now requires that call site by name.
    @discardableResult
    private func writeOfferedLinks(_ plan: PromotionPlan,
                                   artifactTitle: String) async throws -> [CanvasNodeID] {
        guard plan.linksAccepted, !plan.offeredLinks.isEmpty else { return [] }
        let link = Promotion.linkText(to: artifactTitle, label: nil)
        try? await store.documentStore?.flushPendingSave()
        var written: [CanvasNodeID] = []
        for offer in plan.offeredLinks {
            guard let item = TreeWalk.find(id: offer.itemID, in: store.manifest.research),
                  let path = item.path else { continue }
            let body = try readBody(atPath: path)
            guard !body.contains(link) else { continue }
            try await write(body + "\n\n" + link + "\n", toPath: path)
            written.append(offer.node)
        }
        return written
    }

    // MARK: - Disk

    /// Write a body to a research item's file.
    ///
    /// **The flush is not optional** (`AddNoteTool.swift:48-55`): a queued 750 ms
    /// `scheduleFileSave` for this path otherwise fires AFTER the write and
    /// overwrites it with stale content.
    private func writeBody(_ text: String, toItem id: String) async throws {
        guard let item = TreeWalk.find(id: id, in: store.manifest.research),
              let path = item.path else { throw PromotionFailure.itemHasNoFile(id) }
        try? await store.documentStore?.flushPendingSave()
        try await write(text, toPath: path)
    }

    /// Through the same `NSFileCoordinator` path research-note saves use, so a
    /// promotion into a cloud-synced project does not race iCloud. The direct
    /// write is the no-`DocumentStore` fallback (load-only contexts), mirroring
    /// `ProjectStore+Palette.paletteCoordinatedWrite`.
    private func write(_ text: String, toPath path: String) async throws {
        if let ds = store.documentStore {
            try await ds.performFileSave(path: path, text: text)
            return
        }
        try text.write(to: store.url.appendingPathComponent(path),
                       atomically: true, encoding: .utf8)
    }

    /// What is already in the destination, for the paths that APPEND to it and
    /// write the result back — `performWikiLink` and `writeOfferedLinks`.
    /// (`performCraftIntent` was a third until M1A; a statement is appended to
    /// through its op log, which has no read-back-and-rewrite step to be raced.)
    ///
    /// **"Absent" and "unreadable" are not the same answer, and a `try?` cannot
    /// tell them apart.** No file at that URL is legitimately empty — a
    /// just-created research note is a zero-byte file, and the craft intent is
    /// created empty by design. But a file that exists and will not read —
    /// manifest/disk drift, a decoding failure, an uncoordinated read racing an
    /// iCloud materialise — must REFUSE, because every caller appends to this
    /// return value and writes it back: swallowed, an unreadable note becomes
    /// the link and nothing else, and the writer's words are gone. That is
    /// constitution must #1 failing on an append path, so it throws.
    ///
    /// The `// adr-0018-ok:` annotation sits on the line the read STARTS on,
    /// which is what the whole-tree ADR 0018 guard scans for.
    private func readBody(atPath path: String) throws -> String {
        let url = store.url.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)  // adr-0018-ok: a research note is not manuscript — no op log, no second representation to drift from
        } catch {
            throw PromotionFailure.unreadableFile(path)
        }
    }

    // MARK: - The piece (spec §6.2)

    /// The scope a new research note is created in — the source's piece by
    /// `Promotion.piece`'s precedence (its own, else its home region's, else
    /// none), or the project's own research.
    ///
    /// It hands `ResearchScope` a piece id and nothing else. Which of the four
    /// rows of §6.2's table that is, and whether a link record gets written, is
    /// `route(_:shared:piece:)`'s answer and not this file's.
    private func scope(for source: PromotionSource) -> ResearchScope {
        Promotion.piece(for: source, in: model.scene).map(ResearchScope.document) ?? .shared
    }

    /// The document a `.sharedPlusLink` routing would have linked the new note
    /// to — the only case in which a palette card takes a link.
    ///
    /// **`try?` rather than `try`, and that is the whole of "nothing
    /// otherwise".** `researchRouting` throws for an id it cannot route (a
    /// collection reference piece, a group, an id since deleted). The card is
    /// created regardless — the wall is project-level — so a throw here would
    /// have to arrive AFTER `addPaletteCard`, leaving a card on the wall and
    /// reporting a failure: the half-created artifact this file's contract
    /// refuses to produce. A piece that cannot be routed buys the card no link,
    /// which is what §6.2 says it should.
    private func linkTargetForCard(_ source: PromotionSource) -> String? {
        guard let piece = Promotion.piece(for: source, in: model.scene),
              let routing = try? store.researchRouting(forDocumentId: piece),
              case .sharedPlusLink(let documentID) = routing else { return nil }
        return documentID
    }

    /// The scope an intent statement is found in: the source's own piece, on
    /// **every** routed row.
    ///
    /// **The narrowing rule died with the defect it existed for** (M1A). This
    /// returned a piece only where `researchRouting` answered `.pieceFolder` —
    /// a Collection loose piece — because `craftIntentItem(forPieceId:)` located
    /// an existing intent doc by that piece's research PATH PREFIX, which a
    /// novel chapter has none of: a chapter's intent doc would land in shared
    /// `research/` where the lookup never looked, and the next promotion would
    /// mint a second one. A statement is found by scope in the manifest, so
    /// there is no prefix to be nil and a chapter's intent is the chapter's.
    ///
    /// **What survives is the fallback, and it is a ruling rather than a
    /// leftover.** A piece the router refuses — deleted since, a group, a
    /// Collection *reference* piece whose research belongs to its own project —
    /// scopes to the project. `Promotion.pieceFailure` says so from the other
    /// side: `.intentStatement` is deliberately not a `scopedTarget`, "the craft
    /// intent falls back to project scope by design", so refusing here would
    /// make a stale association cost the writer a promotion that has always
    /// worked. `isResearchScopeTarget` is the exact predicate:
    /// `createStatement`'s own guard (a `.document` in this project's structure)
    /// is strictly weaker, so anything it accepts this has already accepted.
    private func intentScope(_ source: PromotionSource) -> Statement.Scope {
        guard let piece = Promotion.piece(for: source, in: model.scene),
              store.isResearchScopeTarget(piece) else { return .project }
        return .document(piece)
    }

    // MARK: - The mark

    private func isRegion(_ source: PromotionSource) -> Bool {
        if case .region = source { return true }
        return false
    }

    /// The one scene change a promotion makes, through the outside verb — the
    /// source's own mark **and** the contribution record on every card whose
    /// words went into the artifact (spec §6.3).
    ///
    /// **ONE bracket, and that is the whole reason this is one function.**
    /// §6.3's "one gesture, one undo step": a ⌘Z that took back the region's
    /// mark and left its members claiming a note the region no longer names is
    /// two truths on one screen, which is the defect §6.3 exists to fix
    /// arriving through the undo stack instead. A second
    /// `mutateFromInspector` would not merely split the step — nested inside
    /// this one it takes no snapshot and registers nothing, so the records
    /// would sit on no undo step at all and ride into the writer's next
    /// sentence (tripwire 32).
    ///
    /// `contributors` is empty for a scrap and a line, so the stamping is a
    /// no-op there and only a region's promotion writes records.
    private func mark(_ itemID: String, for source: PromotionSource, named: String,
                      contributors: [CanvasNodeID]) {
        switch source {
        case .scrap(let node):
            model.mutateFromInspector(named) {
                $0.setPromotedItem(itemID, for: node)
                Self.record(itemID, contributors: contributors, in: &$0)
            }
        case .region(let region):
            model.mutateFromInspector(named) {
                $0.updateRegion(region) { $0.promotedItemID = itemID }
                Self.record(itemID, contributors: contributors, in: &$0)
            }
        case .line:
            return   // nothing on a line to mark; no undo step either
        }
        model.bumpSceneRevision()
    }

    /// Rebuild the set of cards recording that their words are inside `itemID`.
    ///
    /// **Clear first, then stamp** (§6.3: "an update re-records"). An update
    /// rewrites the artifact from the region's CURRENT members, so the record
    /// has to follow the same set: a card that has left since must stop
    /// claiming the note, and one that joined must start. Stamping alone would
    /// leave the departed card pointing at a note its words are no longer in —
    /// the same false sentence in the inspector that §6.3 was written to
    /// remove, one promotion later.
    ///
    /// The clear is **scoped to this artifact**, so this promotion cannot wipe a
    /// record naming somebody else's note. On a `.new` promotion the id is
    /// freshly minted and the clear matches nothing.
    ///
    /// **But the record is SINGLE-VALUED, and the most recent contribution
    /// wins** — the scope limits the *clear*, not the *stamp*. Reachable, and
    /// intended: card X lives in region A, A is promoted so X records A's note;
    /// X is dragged into region B (`CanvasMembership.join` moves the home, and
    /// there is only ever one home), B is promoted, and the stamp **overwrites**
    /// X's record with B's note. A's note was never rewritten, so X's words
    /// really are in both and the inspector names only the later one. It is the
    /// honest cost of one field: recording a *set* would put a growing,
    /// never-collected list of ids on every node, each of which can dangle, to
    /// describe a snapshot the writer took once — and the field is provenance,
    /// which the most recent act is the most useful reading of. Pinned by
    /// `PromotionContributionPerformerTests`, so the next author reads it as a
    /// decision rather than as a bug to fix.
    ///
    /// **It runs on the scrap arm too, and that is the right answer rather than
    /// an oversight.** `contributors` is empty there, so nothing is stamped —
    /// but if a single card's promotion ever rewrote an artifact other cards
    /// claim, their words really would no longer be in it, and the clear is
    /// what keeps the record meaning what it says. Not reachable from the UI
    /// today: `existingArtifact` offers an Update off `promotedItemID` alone
    /// (§6.3), so a scrap can only rewrite an artifact it produced itself.
    /// **The clear is scoped to the artifact AND to what this path can have
    /// written** (1C-d Task 8, review M1). A palette card now has two producers
    /// with different semantics: a region rewrites one from its current members,
    /// and a picture is *appended* to one. Scoped to the id alone, the sequence
    /// is reachable and silent — promote region R to card P, promote an owned
    /// picture onto P, then re-promote R with **Update**, and the picture's
    /// record is cleared while its image is still in P's well. The pane then says
    /// nothing about a photograph that is demonstrably on that card, which is
    /// §6.3's own false-pane defect in its mild direction.
    ///
    /// **An item node is skipped, and 1C-d Task 12a changed the REASON without
    /// changing the predicate — which is worth reading before touching either.**
    /// It was "this path can never have stamped one": `contributors` came from
    /// `Promotion.regionBodies`, which reads the scrap table and cannot see a
    /// picture. That is now false — a region's palette promotion carries the
    /// pictures in it and records them (spec §6.3's 2026-07-31 amendment) — and
    /// the skip is nevertheless still right, for a stronger reason:
    ///
    /// **a picture's contribution is never undone by a rewrite, because the
    /// image well is append-only for every producer.** `performPaletteCard`'s
    /// update branch replaces the title, the kind and the BODY and carries
    /// `current.imagePaths` across untouched; `addImage` appends. So a picture
    /// that has since left the region still has its image on that card, and a
    /// card whose words have left really has had them written out of the body.
    /// The record follows what the artifact still CONTAINS, which is the rule
    /// this whole function is an expression of — the id scope is the same rule
    /// on the axis the kind cannot see.
    ///
    /// The stamp is deliberately not filtered: an item node in `contributors`
    /// is a picture this promotion just copied, and it must record that.
    private static func record(_ itemID: String, contributors: [CanvasNodeID],
                               in scene: inout CanvasScene) {
        for node in scene.unorderedNodes
        where node.contributedToItemID == itemID && node.kind.isScrap {
            scene.setContributedItem(nil, for: node.id)
        }
        for node in contributors { scene.setContributedItem(itemID, for: node) }
    }
}
