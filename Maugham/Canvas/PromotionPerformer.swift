import Foundation
import MaughamCore

/// What a promotion produced.
struct PromotionResult: Equatable {
    /// The artifact's research-item id.
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
    /// **Two axes, because four different acts fix it.** The title says what went
    /// wrong; `inherited` says *whose* association it is, and that is the term
    /// that stops the sentence pointing at a control the writer cannot use — a
    /// card that lives in a region whose piece was deleted carries nothing
    /// itself, so "clear the association" names a Picker already reading None
    /// while the stale field sits on the region.
    case pieceIsNotAResearchTarget(title: String?, inherited: Bool)
    /// A picture row whose plan carries no `PromotedPicture` — the node stopped
    /// being an owned item between the sheet opening and Commit, or a caller
    /// hand-built the plan. It refuses rather than reaching into the scene for a
    /// substitute file.
    case nothingToCopy
    /// The owned file named by the plan is not on disk. Reachable: the well is
    /// content the writer can delete, and `canvas_assets/` is an ordinary folder
    /// in their project.
    case pictureIsGone(path: String)
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
        case .pieceIsNotAResearchTarget(let title, let inherited):
            // Composed from two halves rather than written out four times: what
            // is wrong, then the act that fixes it. The second half is the one
            // that has to be right — a refusal naming a control the writer
            // cannot use leaves them stuck at it.
            let problem = title.map { "“\($0)” cannot keep research of its own" }
                ?? "The piece this is associated with is no longer in the project"
            let fix = inherited
                ? "That piece comes from the region this card lives in — change "
                    + "it there, or give this card a piece of its own."
                : "Pick another piece in the inspector, or clear the association."
            // **"it" rather than "the note", since 1C-d.** This sentence is
            // reached by a research ASSET as well now (`Promotion.scopedTargets`),
            // and a picture told its *note* has nowhere to go is a refusal
            // describing something the writer is not doing.
            return problem + ", so there is nowhere to file it. " + fix
        case .nothingToCopy:
            return "There is no picture on this card to promote."
        case .pictureIsGone(let path):
            return "The picture this card shows is no longer in the project "
                + "(\(path)), so there is nothing to copy."
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
            guard FileManager.default.fileExists(atPath: assetURL(picture).path) else {
                throw PromotionFailure.pictureIsGone(path: picture.assetPath)
            }
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
        if case .update(let itemID, _) = plan.mode,
           TreeWalk.find(id: itemID, in: store.manifest.research) == nil {
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
            piece: PromotionPiece.resolve(for: plan.source, in: model.scene, store: store)) {
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
        switch ArtifactIndex.over(research: store.manifest.research).kind(of: itemID) {
        case .researchNote, nil: return   // nil is `artifactMissing`'s case, thrown by `validate`
        case .paletteCard:
            throw PromotionFailure.artifactIsADifferentKind(itemID: itemID,
                                                            found: "a palette card")
        case .craftIntent:
            throw PromotionFailure.artifactIsADifferentKind(itemID: itemID,
                                                            found: "the project's craft intent")
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

        let title = TreeWalk.find(id: itemID, in: store.manifest.research)?.title ?? plan.title
        mark(itemID, for: plan.source,
             named: isRegion(plan.source) ? "Promote Region" : "Promote Scrap",
             contributors: plan.contributors)
        let written = try await writeOfferedLinks(plan, artifactTitle: title)
        return PromotionResult(createdItemID: itemID, title: title, writtenLinks: written)
    }

    private func performCraftIntent(_ plan: PromotionPlan) async throws -> PromotionResult {
        // Find-or-create, idempotent: one intent doc per scope — and the scope
        // takes the piece ONLY where the routing is `.pieceFolder`.
        //
        // **Not a shrug at the other rows: the lookup cannot find them.**
        // `craftIntentItem(forPieceId:)` locates an existing intent doc by the
        // piece's research PREFIX (`ResearchScope.pieceResearchPrefix`), which is
        // nil for anything that is not a collection loose piece. An intent doc
        // created under a novel chapter's `.sharedPlusLink` would land in shared
        // `research/` where that lookup never looks, so the next promotion would
        // find nothing and mint a second one — the writer's intent statement
        // silently split in two. And the intent takes the scope and never the
        // link (§6.2): linking the PROJECT's intent to one chapter misrepresents
        // what it is.
        let item = try await store.createCraftIntent(forPieceId: intentPiece(plan.source))
        guard let path = item.path else { throw PromotionFailure.itemHasNoFile(item.id) }
        // AFTER the flush, so what we append to is what is on disk.
        try? await store.documentStore?.flushPendingSave()
        let existing = try readBody(atPath: path)
        let joined = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? plan.body
            : existing + "\n\n" + plan.body
        try await write(joined, toPath: path)
        // `plan.contributors` rather than `[]`, and it is not defensive padding:
        // only a scrap can reach an intent statement today (`Promotion.targets`
        // offers a region `.researchNote` and `.paletteCard` only), so this list
        // is always empty — but writing `[]` here would be a second rule about
        // who records, and if a region ever gains this target the second rule is
        // the one that would silently be wrong.
        mark(item.id, for: plan.source, named: "Promote Scrap",
             contributors: plan.contributors)
        return PromotionResult(createdItemID: item.id, title: item.title, writtenLinks: [])
    }

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

    private func requirePicture(_ plan: PromotionPlan) throws -> PromotedPicture {
        guard let picture = plan.picture else { throw PromotionFailure.nothingToCopy }
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

    /// What is already in the destination, for the three paths that APPEND to it
    /// and write the result back.
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

    /// The piece a craft intent is scoped to: the source's, but only where it
    /// routes to `.pieceFolder`. See `performCraftIntent` for why the other rows
    /// must be project scope rather than a piece the lookup could never find
    /// again.
    private func intentPiece(_ source: PromotionSource) -> String? {
        guard let piece = Promotion.piece(for: source, in: model.scene),
              let routing = try? store.researchRouting(forDocumentId: piece),
              case .pieceFolder(let pieceID) = routing else { return nil }
        return pieceID
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
    private static func record(_ itemID: String, contributors: [CanvasNodeID],
                               in scene: inout CanvasScene) {
        for node in scene.unorderedNodes where node.contributedToItemID == itemID {
            scene.setContributedItem(nil, for: node.id)
        }
        for node in contributors { scene.setContributedItem(itemID, for: node) }
    }
}
