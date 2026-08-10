import Foundation
import MaughamCore

/// Pure Read-tab palette logic (Task 6): which research items are palette cards,
/// which leaves to hide from the ordinary Research section, and how sensory
/// notes group for display. All pure + unit-tested; the views are build-verified
/// and smoke-tested on device.
enum PaletteLoading {

    /// The palette group's document cards, in manifest (wall) order. Mirrors the
    /// Mac's `ProjectStore.paletteCardItems()` — `.asset` children with
    /// `kind == .document` directly under the palette group. Empty when there's
    /// no palette group.
    static func paletteCards(in research: [ResearchItem]) -> [ResearchItem] {
        PaletteLookup.paletteCards(in: research)
    }

    /// Filters the palette group's descendants — and the legacy craft-intent
    /// note when that note is what the Craft Intent row shows — out of the
    /// ordinary Research leaves. They get their own `Section("Palette")`, so
    /// leaving them in Research duplicates them (the pre-existing bug the
    /// palette task fixed — palette cards were flattened into the Research
    /// section). Ordinary research passes through untouched.
    ///
    /// **The intent exclusion follows the ROW, not the note's existence** (M1A
    /// Task 11). An adopted project draws the statement, and its legacy note —
    /// left behind by an adoption that could not read it, or written since —
    /// is then on screen nowhere else, so hiding it here would cost the writer
    /// a research row for nothing. `statements` is taken rather than a resolved
    /// row so there is one decision, made once, in `StatementLoading.intentRow`.
    static func excludingPalette(
        _ leaves: [ResearchItem], research: [ResearchItem], statements: [Statement]
    ) -> [ResearchItem] {
        var excluded = Set<String>()
        if let group = PaletteLookup.paletteGroup(in: research) {
            excluded.formUnion(TreeWalk.collectIds(in: group.children ?? []))
        }
        if case .legacyNote(let id)? = StatementLoading.intentRow(
            statements: statements, research: research)?.origin {
            excluded.insert(id)
        }
        return leaves.filter { !excluded.contains($0.id) }
    }

    /// Groups sensory notes for display: one group per `Sense` in `allCases`
    /// order (non-empty only), untagged notes last. The phone-local twin of the
    /// Mac's app-target `PaletteCardReadView.groupedNotes` — that static lives
    /// in the Mac target and can't cross the module boundary, so it's mirrored
    /// + tested here (tripwire 19: shared shape, separately-owned code,
    /// guarded by tests).
    static func groupedNotes(
        _ notes: [PaletteCard.SensoryNote]
    ) -> [(sense: PaletteCard.Sense?, notes: [PaletteCard.SensoryNote])] {
        var groups: [(sense: PaletteCard.Sense?, notes: [PaletteCard.SensoryNote])] = []
        for sense in PaletteCard.Sense.allCases {
            let matching = notes.filter { $0.sense == sense }
            if !matching.isEmpty { groups.append((sense, matching)) }
        }
        let untagged = notes.filter { $0.sense == nil }
        if !untagged.isEmpty { groups.append((nil, untagged)) }
        return groups
    }
}
