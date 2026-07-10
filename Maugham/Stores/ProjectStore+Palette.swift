import Foundation
import AppKit
import MaughamCore

/// Sensory-palette store seam. Palette cards are ordinary research `.document`
/// assets under the `research/palette/` group, so rename/move/trash ride the
/// existing typed-mover machinery (tripwire 14) and ResearchView affordances.
extension ProjectStore {

    public static let paletteFolderPath = "research/palette"
    public static let paletteGroupTitle = "Palette"

    /// The palette group in the research tree, if it exists.
    public func paletteGroup() -> ResearchItem? {
        manifest.research.first { $0.type == .group && $0.path == Self.paletteFolderPath }
    }

    /// Find-or-create the `research/palette/` group (idempotent).
    @discardableResult
    public func ensurePaletteGroup() async throws -> ResearchItem {
        if let existing = paletteGroup() { return existing }
        // addResearchItem(kind: nil) creates a group folder from the slugified
        // title — "Palette" → research/palette.
        return try await addResearchItem(parentId: nil, title: Self.paletteGroupTitle, kind: nil)
    }

    /// Create a new palette card seeded from the template, under the palette group.
    @discardableResult
    public func addPaletteCard(title: String, kind: PaletteCard.Kind) async throws -> ResearchItem {
        let group = try await ensurePaletteGroup()
        let item = try await addResearchTextNote(parentId: group.id, title: title)
        if let rel = item.path {
            let fileURL = url.appendingPathComponent(rel)
            try PaletteCardParser.template(title: title, kind: kind)
                .write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return item
    }

    /// Document assets under the palette group, in manifest (wall) order.
    public func paletteCardItems() -> [ResearchItem] {
        (paletteGroup()?.children ?? []).filter { $0.type == .asset && $0.kind == .document }
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
        try rendered.write(
            to: url.appendingPathComponent(writePath), atomically: true, encoding: .utf8)

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
        let projectRelative = Self.resolveImageRef(ref, cardDirectory: dir)
        let updated = PaletteCard(
            researchItemId: card.researchItemId, title: card.title, kind: card.kind,
            swatches: card.swatches, notes: card.notes,
            imagePaths: card.imagePaths + [projectRelative], body: card.body)
        try await updatePaletteCard(updated)
        return updated
    }

    /// Extract the inner path from `![](...)` and resolve its leading `./` against
    /// the card's directory, yielding a project-relative path.
    static func resolveImageRef(_ ref: String, cardDirectory: String) -> String {
        var inner = ref
        if let open = ref.range(of: "]("), let close = ref.range(of: ")", range: open.upperBound..<ref.endIndex) {
            inner = String(ref[open.upperBound..<close.lowerBound])
        }
        while inner.hasPrefix("./") { inner = String(inner.dropFirst(2)) }
        return cardDirectory.isEmpty ? inner : "\(cardDirectory)/\(inner)"
    }

    /// The file slug (basename without extension) of a card's project-relative path.
    static func paletteSlug(ofPath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
