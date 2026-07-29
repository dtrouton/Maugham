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
    func confirmation(for plan: PromotionPlan) -> String {
        let count = writtenLinks.count
        let links = count == 0 ? ""
            : " Linked \(count) note\(count == 1 ? "" : "s") to it."
        switch plan.producedKind {
        case .researchNote: return "Promoted to the note “\(title)”." + links
        case .paletteCard: return "Promoted to the palette card “\(title)”." + links
        case .intentStatement: return "Added to the project's craft intent."
        case .wikiLink: return "Wrote the link into the note “\(title)”."
        }
    }
}

enum PromotionFailure: LocalizedError, Equatable {
    case emptyTitle
    case emptyBody
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

    var errorDescription: String? {
        switch self {
        case .emptyTitle: return "This needs a name before it can be promoted."
        case .emptyBody: return "There is nothing in this card to promote."
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
        }
    }

    // MARK: - Validation

    private func validate(_ plan: PromotionPlan) throws {
        switch plan.producedKind {
        case .researchNote, .paletteCard:
            guard !plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PromotionFailure.emptyTitle }
            guard !plan.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PromotionFailure.emptyBody }
        case .intentStatement:
            // **No title guard**, because `performCraftIntent` never reads one:
            // the intent doc is find-or-create at a fixed title and the body is
            // appended. Refusing a plan for a missing name would refuse it for
            // a field that changes nothing — and the sheet stopped asking for
            // one in the same edit, so the two agree.
            guard !plan.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PromotionFailure.emptyBody }
        case .wikiLink:
            guard plan.wikiLinkWrite != nil else { throw PromotionFailure.missingWikiLinkWrite }
            guard !plan.linkAlreadyPresent else { throw PromotionFailure.linkAlreadyPresent }
        }
        if case .update(let itemID, _) = plan.mode,
           TreeWalk.find(id: itemID, in: store.manifest.research) == nil {
            throw PromotionFailure.artifactMissing(itemID)
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
        }
    }

    // MARK: - The five targets

    private func performResearchNote(_ plan: PromotionPlan) async throws -> PromotionResult {
        let itemID: String
        switch plan.mode {
        case .new:
            itemID = try await store.addResearchTextNote(parentId: nil, title: plan.title).id
        case .update(let existing, _):
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
             named: isRegion(plan.source) ? "Promote Region" : "Promote Scrap")
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
        mark(itemID, for: plan.source,
             named: isRegion(plan.source) ? "Promote Region" : "Promote Scrap")
        let written = try await writeOfferedLinks(plan, artifactTitle: title)
        return PromotionResult(createdItemID: itemID, title: title, writtenLinks: written)
    }

    private func performCraftIntent(_ plan: PromotionPlan) async throws -> PromotionResult {
        // Find-or-create, idempotent: one intent doc per scope. Project scope —
        // a scrap belongs to the canvas, and the canvas belongs to the project.
        let item = try await store.createCraftIntent(forPieceId: nil)
        guard let path = item.path else { throw PromotionFailure.itemHasNoFile(item.id) }
        // AFTER the flush, so what we append to is what is on disk.
        try? await store.documentStore?.flushPendingSave()
        let existing = try readBody(atPath: path)
        let joined = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? plan.body
            : existing + "\n\n" + plan.body
        try await write(joined, toPath: path)
        mark(item.id, for: plan.source, named: "Promote Scrap")
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
