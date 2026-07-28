import Foundation
import MaughamCore

/// What a promotion produced.
struct PromotionResult: Equatable {
    /// The artifact's research-item id. Nil only for a piece binding, which
    /// creates no file.
    let createdItemID: String?
    /// The artifact's title AS CREATED — `addResearchTextNote` dedupes, so this
    /// is not always the title the writer typed.
    let title: String
    /// The members whose own notes gained a link, when the offer was accepted.
    let writtenLinks: [CanvasNodeID]
    let boundPieceID: String?
}

enum PromotionFailure: LocalizedError, Equatable {
    case emptyTitle
    case emptyBody
    case missingPiece
    case missingWikiLinkWrite
    case linkAlreadyPresent
    case artifactMissing(String)
    case itemHasNoFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyTitle: return "This needs a name before it can be promoted."
        case .emptyBody: return "There is nothing in this card to promote."
        case .missingPiece: return "Choose a piece to bind this region to."
        case .missingWikiLinkWrite: return "This line has nothing to link."
        case .linkAlreadyPresent: return "That link is already in the note."
        case .artifactMissing(let id):
            return "The artifact this card produced is no longer in the project (\(id))."
        case .itemHasNoFile(let id): return "That artifact has no file on disk (\(id))."
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
        case .pieceBinding: return performPieceBinding(plan)
        case .wikiLink: return try await performWikiLink(plan)
        }
    }

    // MARK: - Validation

    private func validate(_ plan: PromotionPlan) throws {
        switch plan.producedKind {
        case .researchNote, .paletteCard, .intentStatement:
            guard !plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PromotionFailure.emptyTitle }
            guard !plan.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PromotionFailure.emptyBody }
        case .pieceBinding:
            guard plan.pieceID != nil else { throw PromotionFailure.missingPiece }
        case .wikiLink:
            guard plan.wikiLinkWrite != nil else { throw PromotionFailure.missingWikiLinkWrite }
            guard !plan.linkAlreadyPresent else { throw PromotionFailure.linkAlreadyPresent }
        }
        if case .update(let itemID, _) = plan.mode,
           TreeWalk.find(id: itemID, in: store.manifest.research) == nil {
            throw PromotionFailure.artifactMissing(itemID)
        }
    }

    // MARK: - The five targets

    private func performResearchNote(_ plan: PromotionPlan) async throws -> PromotionResult {
        let itemID: String
        switch plan.mode {
        case .new:
            itemID = try await store.addResearchTextNote(parentId: nil, title: plan.title).id
        case .update(let existing, _):
            // Renames the backing file through the typed mover when the title
            // moved (tripwire 14 is satisfied by using this API rather than a
            // raw move of our own).
            try await store.updateResearchItem(id: existing, title: plan.title)
            itemID = existing
        }
        try await writeBody(plan.body, toItem: itemID)
        let title = TreeWalk.find(id: itemID, in: store.manifest.research)?.title ?? plan.title
        try await writeOfferedLinks(plan, artifactTitle: title)
        mark(itemID, for: plan.source, named: "Promote Scrap")
        return PromotionResult(createdItemID: itemID, title: title,
                               writtenLinks: writtenLinks(plan), boundPieceID: nil)
    }

    private func performPaletteCard(_ plan: PromotionPlan) async throws -> PromotionResult {
        let itemID: String
        switch plan.mode {
        case .new:
            itemID = try await store.addPaletteCard(title: plan.title,
                                                    kind: plan.paletteKind).id
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
        try await writeOfferedLinks(plan, artifactTitle: title)
        mark(itemID, for: plan.source,
             named: isRegion(plan.source) ? "Promote Region" : "Promote Scrap")
        return PromotionResult(createdItemID: itemID, title: title,
                               writtenLinks: writtenLinks(plan), boundPieceID: nil)
    }

    private func performCraftIntent(_ plan: PromotionPlan) async throws -> PromotionResult {
        // Find-or-create, idempotent: one intent doc per scope. Project scope —
        // a scrap belongs to the canvas, and the canvas belongs to the project.
        let item = try await store.createCraftIntent(forPieceId: nil)
        guard let path = item.path else { throw PromotionFailure.itemHasNoFile(item.id) }
        // AFTER the flush, so what we append to is what is on disk.
        try? await store.documentStore?.flushPendingSave()
        let existing = readBody(atPath: path)
        let joined = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? plan.body
            : existing + "\n\n" + plan.body
        try await write(joined, toPath: path)
        mark(item.id, for: plan.source, named: "Promote Scrap")
        return PromotionResult(createdItemID: item.id, title: item.title,
                               writtenLinks: [], boundPieceID: nil)
    }

    private func performPieceBinding(_ plan: PromotionPlan) -> PromotionResult {
        guard let pieceID = plan.pieceID, case .region(let regionID) = plan.source else {
            return PromotionResult(createdItemID: nil, title: plan.title,
                                   writtenLinks: [], boundPieceID: nil)
        }
        // The SAME undo name the region inspector's Picker uses, so one act
        // reads one way in the Edit menu however the writer reached it.
        model.mutateFromInspector("Bind Region") { scene in
            RegionBinding.bind(regionID, toPiece: pieceID, in: &scene)
        }
        model.bumpSceneRevision()
        return PromotionResult(createdItemID: nil, title: plan.title,
                               writtenLinks: [], boundPieceID: pieceID)
    }

    private func performWikiLink(_ plan: PromotionPlan) async throws -> PromotionResult {
        guard let link = plan.wikiLinkWrite else { throw PromotionFailure.missingWikiLinkWrite }
        guard let item = TreeWalk.find(id: link.intoItemID, in: store.manifest.research),
              let path = item.path else {
            throw PromotionFailure.artifactMissing(link.intoItemID)
        }
        try? await store.documentStore?.flushPendingSave()
        let body = readBody(atPath: path)
        // The plan's own check was against a SNAPSHOT taken when the sheet
        // opened. This one is against the file.
        guard !body.contains(link.linkText) else { throw PromotionFailure.linkAlreadyPresent }
        try await write(body + link.appendedText, toPath: path)
        // No mark: a line's artifact is text inside somebody else's note, and a
        // flag on the line could disagree with the file.
        return PromotionResult(createdItemID: link.intoItemID, title: item.title,
                               writtenLinks: [], boundPieceID: nil)
    }

    // MARK: - The offer (§6.1: may suggest, must never impose)

    private func writtenLinks(_ plan: PromotionPlan) -> [CanvasNodeID] {
        plan.linksAccepted ? plan.offeredLinks.map(\.node) : []
    }

    /// Append `[[artifact]]` to each offered member's OWN note — the member
    /// pointing at what the region produced. Runs only when the writer accepted.
    private func writeOfferedLinks(_ plan: PromotionPlan, artifactTitle: String) async throws {
        guard plan.linksAccepted, !plan.offeredLinks.isEmpty else { return }
        let link = Promotion.linkText(to: artifactTitle, label: nil)
        try? await store.documentStore?.flushPendingSave()
        for offer in plan.offeredLinks {
            guard let item = TreeWalk.find(id: offer.itemID, in: store.manifest.research),
                  let path = item.path else { continue }
            let body = readBody(atPath: path)
            guard !body.contains(link) else { continue }
            try await write(body + "\n\n" + link + "\n", toPath: path)
        }
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

    /// The annotation sits on the line the read STARTS on, which is what the
    /// whole-tree ADR 0018 guard scans for.
    private func readBody(atPath path: String) -> String {
        let url = store.url.appendingPathComponent(path)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""  // adr-0018-ok: a research note is not manuscript — no op log, no second representation to drift from
    }

    // MARK: - The mark

    private func isRegion(_ source: PromotionSource) -> Bool {
        if case .region = source { return true }
        return false
    }

    /// The one scene change a promotion makes, through the outside verb.
    private func mark(_ itemID: String, for source: PromotionSource, named: String) {
        switch source {
        case .scrap(let node):
            model.mutateFromInspector(named) { $0.setPromotedItem(itemID, for: node) }
        case .region(let region):
            model.mutateFromInspector(named) {
                $0.updateRegion(region) { $0.promotedItemID = itemID }
            }
        case .line:
            return   // nothing on a line to mark; no undo step either
        }
        model.bumpSceneRevision()
    }
}
