import Foundation
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
}
