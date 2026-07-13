import Foundation

/// Canonical palette/craft-intent conventions shared by Mac and phone
/// (tripwire 19). Path/filename are the LEGACY identity fallbacks; role
/// (`ResearchItem.role`) is the durable identity.
public enum PaletteConvention {
    public static let folderPath = "research/palette"
    public static let groupTitle = "Palette"
    public static let craftIntentFileName = "craft-intent.md"
    public static let craftIntentTitle = "Craft Intent"
}

/// Pure role-first lookups (no stamping — Mac wraps these with lazy healing;
/// the phone uses them read-only).
public enum PaletteLookup {
    public static func paletteGroup(in research: [ResearchItem]) -> ResearchItem? {
        if let byRole = research.first(where: { $0.type == .group && $0.role == .paletteGroup }) {
            return byRole
        }
        return research.first { $0.type == .group && $0.path == PaletteConvention.folderPath }
    }

    public static func craftIntentItem(
        in research: [ResearchItem], researchPrefix: String
    ) -> ResearchItem? {
        let prefix = researchPrefix.hasSuffix("/") ? researchPrefix : researchPrefix + "/"
        let scoped = TreeWalk.collect(in: research) { item in
            item.type == .asset && (item.path?.hasPrefix(prefix) ?? false)
        }
        if let byRole = scoped.first(where: { $0.role == .craftIntent }) { return byRole }
        return scoped.first { ($0.path as NSString?)?.lastPathComponent == PaletteConvention.craftIntentFileName }
    }

    /// The palette group's document cards, in manifest (wall) order — the direct
    /// `.asset`/`.document` children of the role-first palette group. Empty when
    /// no palette group exists. The single source of the "which research items
    /// are palette cards" filter, shared by the Mac
    /// (`ProjectStore.paletteCardItems`), the phone Read tab
    /// (`PaletteLoading.paletteCards`), and phone capture aim
    /// (`PaletteAimPicker.cardTitles`) so the predicate can't drift across the
    /// three surfaces (tripwire 19).
    public static func paletteCards(in research: [ResearchItem]) -> [ResearchItem] {
        guard let group = paletteGroup(in: research) else { return [] }
        return (group.children ?? []).filter { $0.type == .asset && $0.kind == .document }
    }
}
