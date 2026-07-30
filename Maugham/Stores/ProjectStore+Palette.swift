import Foundation
import AppKit
import MaughamCore

/// Sensory-palette store seam. Palette cards are ordinary research `.document`
/// assets under the `research/palette/` group, so rename/move/trash ride the
/// existing typed-mover machinery (tripwire 14) and ResearchView affordances.
extension ProjectStore {

    public static let paletteFolderPath = PaletteConvention.folderPath
    public static let paletteGroupTitle = PaletteConvention.groupTitle

    /// The palette group in the research tree, if it exists. Role-first
    /// (survives rename/move); falls back to the legacy `research/palette` path.
    /// A fallback hit lazily heals the manifest — see `stampRole`.
    public func paletteGroup() -> ResearchItem? {
        guard let group = PaletteLookup.paletteGroup(in: manifest.research) else { return nil }
        healRole(of: group, to: .paletteGroup)
        return group
    }

    /// The palette group's live title, falling back to the default when no
    /// group exists yet. Pure read (no lazy stamp) so SwiftUI headers can call
    /// it every body pass without firing heal Tasks.
    public var paletteGroupDisplayTitle: String {
        PaletteLookup.paletteGroup(in: manifest.research)?.title ?? Self.paletteGroupTitle
    }

    /// Find-or-create the `research/palette/` group (idempotent). Stamps
    /// `role = .paletteGroup` on create, and heals a legacy path-identified
    /// group on find.
    @discardableResult
    public func ensurePaletteGroup() async throws -> ResearchItem {
        if let existing = paletteGroup() {
            if existing.role != .paletteGroup {
                try await stampRole(itemId: existing.id, role: .paletteGroup)
                return findResearchItem(id: existing.id, in: manifest.research) ?? existing
            }
            return existing
        }
        // addResearchItem(kind: nil) creates a group folder from the slugified
        // title — "Palette" → research/palette.
        let created = try await addResearchItem(
            parentId: nil, title: Self.paletteGroupTitle, kind: nil)
        try await stampRole(itemId: created.id, role: .paletteGroup)
        return findResearchItem(id: created.id, in: manifest.research) ?? created
    }

    /// Create a new palette card seeded from the template, under the palette group.
    @discardableResult
    public func addPaletteCard(title: String, kind: PaletteCard.Kind) async throws -> ResearchItem {
        let group = try await ensurePaletteGroup()
        let item = try await addResearchTextNote(parentId: group.id, title: title)
        if let rel = item.path {
            try await paletteCoordinatedWrite(
                PaletteCardParser.template(title: title, kind: kind), to: rel)
        }
        return item
    }

    /// Document assets under the palette group, in manifest (wall) order.
    /// Delegates to the shared `PaletteLookup.paletteCards` filter so the
    /// group-lookup-then-document-child predicate stays single-sourced across
    /// Mac + phone (tripwire 19). Role identity is stamped eagerly at load
    /// (`healPaletteRolesEagerly`) and by `paletteGroup()`, so this pure read
    /// needs no lazy heal of its own.
    public func paletteCardItems() -> [ResearchItem] {
        PaletteLookup.paletteCards(in: manifest.research)
    }

    /// Every palette card's swatches, flattened in card order then swatch
    /// order. The canvas ground washes itself 3–5% with these (spec §7.1).
    ///
    /// A FUNCTION, not a computed property: `loadPaletteCards()` reads every
    /// card off disk, and a property would invite a call from inside
    /// `ProjectWindow.body`. `CanvasView` calls it once, on appear.
    public func paletteSwatchHexes() -> [String] {
        loadPaletteCards().flatMap(\.swatches)
    }

    /// Read + parse every card. Unreadable files are skipped, not fatal.
    public func loadPaletteCards() -> [PaletteCard] {
        paletteCardItems().compactMap { item in
            guard let rel = item.path,
                  let md = try? String(
                      contentsOf: url.appendingPathComponent(rel),
                      encoding: .utf8) // adr-0018-ok: palette card read, not manuscript
            else { return nil }
            return PaletteCardParser.parse(
                markdown: md, itemId: item.id, fallbackTitle: item.title,
                cardDirectory: (rel as NSString).deletingLastPathComponent)
        }
    }

    /// Persist a palette card model back to its canonical `.md` file (the model
    /// owns the file — `parse(render(card)) == card`). A changed `title` first
    /// routes through `updateResearchItem(id:title:)` — the typed mover renames
    /// the file, migrates the sibling `<slug>_assets/` folder, and rewrites its
    /// `./<slug>_assets/` refs (tripwire 14). Title dedupe can alter the final
    /// slug, so the new path/slug is re-derived from the manifest after the
    /// rename, and `imagePaths` are remapped from the OLD/NEW paths (not titles).
    public func updatePaletteCard(_ card: PaletteCard) async throws {
        guard let oldItem = findResearchItem(id: card.researchItemId, in: manifest.research),
              let oldPath = oldItem.path else {
            throw ProjectStoreError.structureMissing
        }

        var writePath = oldPath
        var remapped = card
        if card.title != oldItem.title {
            try await updateResearchItem(id: card.researchItemId, title: card.title)
            // Re-fetch: dedupe may have altered the slug from the raw title.
            guard let newItem = findResearchItem(id: card.researchItemId, in: manifest.research),
                  let newPath = newItem.path else {
                throw ProjectStoreError.structureMissing
            }
            writePath = newPath
            let oldSlug = Self.paletteSlug(ofPath: oldPath)
            let newSlug = Self.paletteSlug(ofPath: newPath)
            if oldSlug != newSlug {
                let remappedPaths = card.imagePaths.map {
                    $0.replacingOccurrences(
                        of: "\(oldSlug)_assets/", with: "\(newSlug)_assets/")
                }
                remapped = PaletteCard(
                    researchItemId: card.researchItemId, title: card.title, kind: card.kind,
                    swatches: card.swatches, notes: card.notes,
                    imagePaths: remappedPaths, body: card.body)
            }
        }

        let cardDirectory = (writePath as NSString).deletingLastPathComponent
        let rendered = PaletteCardRenderer.render(remapped, cardDirectory: cardDirectory)
        try await paletteCoordinatedWrite(rendered, to: writePath)

        manifest.modified = Date()   // drives `.task(id:)` reloads
        try await saveManifest()
    }

    /// Save `image` into the card's `<slug>_assets/` folder, append the resolved
    /// project-relative path to the model, and persist. Returns the updated card.
    @discardableResult
    public func addImage(toPaletteCard cardId: String, image: NSImage) async throws -> PaletteCard {
        let (item, card) = try paletteCard(for: cardId)
        let ref = try ImagePasteHandler.saveAndReference(
            image: image, forNoteAt: item.path!, in: url)
        return try await appendImage(fromRef: ref, to: card, cardDirectory: item.path!)
    }

    /// Copy an existing image file into the card's `<slug>_assets/` folder
    /// (extension preserved), append it to the model, and persist.
    @discardableResult
    public func addImage(toPaletteCard cardId: String, fileURL: URL) async throws -> PaletteCard {
        let (item, card) = try paletteCard(for: cardId)
        let ref = try ImagePasteHandler.saveAndReferenceFile(
            from: fileURL, forNoteAt: item.path!, in: url)
        return try await appendImage(fromRef: ref, to: card, cardDirectory: item.path!)
    }

    // MARK: - Helpers

    /// Write `text` to the project-relative `path` through the same
    /// NSFileCoordinator path research-note saves use
    /// (`DocumentStore.performFileSave`), so palette card writes don't race
    /// iCloud sync on a cloud-synced project (tripwire 7 / A1-High). Falls
    /// back to a direct write when `documentStore` is nil (unit-test
    /// contexts with no store wiring) — mirrors `saveManifest`'s
    /// documentStore-present/absent split. This is the ONE allowed write
    /// spelling in this file; `TripwireGrepTests.test_noRawWriteInPaletteStore`
    /// enforces it.
    private func paletteCoordinatedWrite(_ text: String, to path: String) async throws {
        if let documentStore {
            try await documentStore.performFileSave(path: path, text: text)
            return
        }
        try text.write(  // palette-coordinated-write: fallback direct write for unit-test contexts (documentStore == nil)
            to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    /// Locate a palette card item and its parsed model, or throw `structureMissing`.
    private func paletteCard(for cardId: String) throws -> (ResearchItem, PaletteCard) {
        guard let item = findResearchItem(id: cardId, in: manifest.research), item.path != nil,
              let card = loadPaletteCards().first(where: { $0.researchItemId == cardId }) else {
            throw ProjectStoreError.structureMissing
        }
        return (item, card)
    }

    /// Resolve an `ImagePasteHandler` `![](./<assets>/<file>)` ref to a
    /// project-relative path, append it to `card`, and persist via `updatePaletteCard`.
    private func appendImage(
        fromRef ref: String, to card: PaletteCard, cardDirectory notePath: String
    ) async throws -> PaletteCard {
        let dir = (notePath as NSString).deletingLastPathComponent
        let projectRelative = Self.resolveImageRef(ref, relativeTo: dir)
        let updated = PaletteCard(
            researchItemId: card.researchItemId, title: card.title, kind: card.kind,
            swatches: card.swatches, notes: card.notes,
            imagePaths: card.imagePaths + [projectRelative], body: card.body)
        try await updatePaletteCard(updated)
        return updated
    }

    /// Extract the inner path from `![](...)` and resolve its leading `./`
    /// against the directory the ref was written *in*, yielding a
    /// project-relative path.
    ///
    /// **Shared with `ProjectStore+CanvasAssets`**, which needs the identical
    /// resolution over the identical saver — hence the neutral `relativeTo:`
    /// label rather than the card-shaped one it started with. Nothing here is
    /// palette-specific: it lives in this file because this is where it was
    /// first needed, not because it belongs to the palette. A second spelling
    /// of ref→path is the drift this is shared to prevent.
    static func resolveImageRef(_ ref: String, relativeTo directory: String) -> String {
        var inner = ref
        if let open = ref.range(of: "]("), let close = ref.range(of: ")", range: open.upperBound..<ref.endIndex) {
            inner = String(ref[open.upperBound..<close.lowerBound])
        }
        while inner.hasPrefix("./") { inner = String(inner.dropFirst(2)) }
        return directory.isEmpty ? inner : "\(directory)/\(inner)"
    }

    /// The file slug (basename without extension) of a card's project-relative path.
    static func paletteSlug(ofPath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: - Role healing (shared by palette + craft-intent lookups)

    /// Fire-and-forget lazy heal: when a role-first lookup fell back to
    /// path/filename identity (the found item's role isn't the durable marker
    /// yet), stamp it so the next lookup is role-first. Keeps the synchronous
    /// read-shaped lookup signature; the guard in `stampRole` makes repeated
    /// calls before the stamp lands idempotent. Mac only — the phone never
    /// writes the manifest.
    func healRole(of item: ResearchItem, to role: ResearchRole) {
        guard item.role != role else { return }
        Task { [weak self] in try? await self?.stampRole(itemId: item.id, role: role) }
    }

    /// One-shot EAGER role heal, run at PROJECT LOAD (`ProjectStore.load`)
    /// before any rename affordance is reachable. The lazy heal only fires when
    /// a role-first lookup runs; but renames happen from the Research binder,
    /// which never calls `paletteGroup()`/`craftIntentItem(...)`. So on a legacy
    /// (role == nil) project, renaming the palette group away from
    /// `research/palette` — or the craft-intent doc away from `craft-intent.md`
    /// — BEFORE the palette wall / craft-intent doc is ever opened would defeat
    /// BOTH the role check and the path/filename fallback, permanently orphaning
    /// the cards (a later `ensurePaletteGroup()` mints a fresh empty group).
    /// Stamping the durable role at load closes that window.
    ///
    /// Identifies legacy items by the same path/filename identity the lookups
    /// fall back to: the `research/palette` group, and every `craft-intent.md`
    /// research asset (all scopes — project + per-piece for collections).
    /// Idempotent and cheap: the `role != …` predicate makes it a pure
    /// in-memory scan with ZERO writes once every convention item is stamped.
    /// Mac-only (the phone never writes the manifest).
    func healPaletteRolesEagerly() async {
        let legacyGroups = TreeWalk.collect(in: manifest.research) {
            $0.type == .group
                && $0.role != .paletteGroup
                && $0.path == PaletteConvention.folderPath
        }
        for group in legacyGroups {
            try? await stampRole(itemId: group.id, role: .paletteGroup)
        }
        let legacyIntents = TreeWalk.collect(in: manifest.research) {
            $0.type == .asset
                && $0.role != .craftIntent
                && ($0.path as NSString?)?.lastPathComponent
                    == PaletteConvention.craftIntentFileName
        }
        for intent in legacyIntents {
            try? await stampRole(itemId: intent.id, role: .craftIntent)
        }
    }

    /// Persist a durable `role` onto a research item. Idempotent: a no-op when
    /// the item is gone or already carries `role`. Deliberately does NOT bump
    /// `manifest.modified` — healing is invisible and must not churn the wall.
    func stampRole(itemId: String, role: ResearchRole) async throws {
        guard let item = findResearchItem(id: itemId, in: manifest.research),
              item.role != role else { return }
        mutateResearchItem(id: itemId) { $0.role = role }
        try await saveManifest()
    }
}
