import Foundation
import MaughamCore

/// **Where an item in To resolve came from** — the filter chips (shell plan 2).
/// The first matching row of the column's table wins: Questions, Checks, Mine,
/// the item's pass, Others.
///
/// `.others` is one case on purpose: removing it later is deleting this case
/// and the switch arms the compiler then names.
enum ResolveSource: Hashable {
    case pass(String)
    case mine
    case checks
    case questions
    case others
}

/// **What a key asks To resolve to show** (the old panes' shortcuts, now
/// requests for a source).
enum ResolveKeyFilter: String, Sendable {
    case rounds, checks, mine, questions
}

/// **To resolve's filters, density, and which groups are open** (shell plan 2,
/// Task 3). Pure: every function takes values the list already holds. The
/// caret's function in particular takes groups already built — per caret move
/// nothing here walks the project or groups anything (tripwire 4).
enum ResolveFilter {

    /// Past this many items in scope (unfiltered) the list is **dense**: the
    /// filters are single-choice and only the caret's group is open. At or
    /// below it, any subset of filters and every group open.
    static let singleChoiceThreshold = 12

    // MARK: - Sources

    /// The item's one source, by the column's table, first match winning.
    static func source(of item: ResolveItem, localName: String) -> ResolveSource {
        switch item {
        case .finding: return .checks
        case .todo: return .mine
        case .note(let note):
            let annotation = note.annotation
            if annotation.language != nil { return .questions }
            if annotation.compilerRunId != nil && annotation.compilerRound == nil { return .checks }
            if AnnotationOwnership.isOwn(annotation, localName: localName) { return .mine }
            if let pass = annotation.reviewPassId { return .pass(pass) }
            return .others
        }
    }

    /// The chips: only sources with items in scope, in the column's order —
    /// each pass in `passes` (`effectiveReviewPasses`) order, Mine, Checks,
    /// Questions, Others. A pass id the manifest no longer lists still gets a
    /// chip, after the listed passes in first-appearance order, so its notes
    /// are never unreachable behind a single choice.
    static func chips(_ items: [ResolveItem], passes: [ReviewPass], localName: String) -> [ResolveSource] {
        var present = Set<ResolveSource>()
        var unlisted: [ResolveSource] = []
        let listed = Set(passes.map { ResolveSource.pass($0.id) })
        for item in items {
            let source = source(of: item, localName: localName)
            if present.insert(source).inserted, case .pass = source, !listed.contains(source) {
                unlisted.append(source)
            }
        }
        let order = passes.map { ResolveSource.pass($0.id) } + unlisted
            + [.mine, .checks, .questions, .others]
        return order.filter { present.contains($0) }
    }

    // MARK: - Density and selection

    /// Counted over the scope's items, unfiltered.
    static func isDense(_ items: [ResolveItem]) -> Bool {
        items.count > singleChoiceThreshold
    }

    /// The selection as it may stand. Small: any subset of the chips (a chip
    /// whose items have gone drops out); empty means everything. Dense:
    /// exactly one — the first selected chip in chip order, else the first
    /// chip (empty only when there are no chips).
    static func normalized(_ selection: Set<ResolveSource>, chips: [ResolveSource],
                           dense: Bool) -> Set<ResolveSource> {
        guard dense else { return selection.intersection(chips) }
        guard let pick = chips.first(where: selection.contains) ?? chips.first else { return [] }
        return [pick]
    }

    /// A chip pressed. Small: toggles it. Dense: it becomes the one choice
    /// (pressing the chosen chip keeps it — a dense list never has none).
    static func toggled(_ selection: Set<ResolveSource>, _ chip: ResolveSource,
                        dense: Bool) -> Set<ResolveSource> {
        if dense { return [chip] }
        var next = selection
        if next.remove(chip) == nil { next.insert(chip) }
        return next
    }

    /// The items the selection shows, in their order. Empty shows everything.
    static func visible(_ items: [ResolveItem], selection: Set<ResolveSource>,
                        localName: String) -> [ResolveItem] {
        guard !selection.isEmpty else { return items }
        return items.filter { selection.contains(source(of: $0, localName: localName)) }
    }

    /// What a key asks for. `.rounds` is every pass chip (dense: the active
    /// pass's chip when present, else the first pass chip); the others select
    /// their chip. **A request whose chip is absent is inert: nil**, and the
    /// view leaves the writer's selection exactly as it was — a key never
    /// swaps her filter to an unrelated source.
    static func selection(for key: ResolveKeyFilter, chips: [ResolveSource],
                          activePassId: String?, dense: Bool) -> Set<ResolveSource>? {
        let requested: [ResolveSource]
        switch key {
        case .rounds:
            let passChips = chips.filter { if case .pass = $0 { return true } else { return false } }
            if dense, let active = activePassId, passChips.contains(.pass(active)) {
                requested = [.pass(active)]
            } else {
                requested = dense ? Array(passChips.prefix(1)) : passChips
            }
        case .checks: requested = chips.contains(.checks) ? [.checks] : []
        case .mine: requested = chips.contains(.mine) ? [.mine] : []
        case .questions: requested = chips.contains(.questions) ? [.questions] : []
        }
        guard !requested.isEmpty else { return nil }
        return Set(requested)
    }

    /// Whether `key` has anything to select here (its chip is present).
    static func canRequest(_ key: ResolveKeyFilter, chips: [ResolveSource]) -> Bool {
        selection(for: key, chips: chips, activePassId: nil, dense: false) != nil
    }

    /// Showing the checks' items reads them: the unread count clears when the
    /// selection is everything or includes Checks.
    static func clearsUnreadChecks(selection: Set<ResolveSource>) -> Bool {
        selection.isEmpty || selection.contains(.checks)
    }

    // MARK: - The caret and the open groups

    /// The caret's group among groups ALREADY BUILT: its paragraph's group, or
    /// in a screenplay (`sceneIndex != nil`) its scene's (Before the first
    /// scene when it precedes every slugline). `docId` is the editor's open
    /// piece; a group about another piece is never the caret's. In a Book or
    /// Part list (groups by piece) the open piece's own group is the caret's
    /// (review I1). Nil with no caret, or when the caret's paragraph has
    /// nothing raised. O(groups) per caret move; no walk.
    static func cursorGroup(paragraphId: String?, docId: String, sceneIndex: [String: Int]?,
                            groups: [ResolveGroup]) -> ResolveGroup.Key? {
        guard let paragraphId else { return nil }
        if let sceneIndex {
            guard let scene = sceneIndex[paragraphId] else {
                let before = ResolveGroup.Key.beforeFirstScene(docId: docId)
                return groups.contains { $0.key == before } ? before : nil
            }
            for group in groups {
                if case .scene(let groupDoc, let heading) = group.key,
                   groupDoc == docId, sceneIndex[heading] == scene {
                    return group.key
                }
            }
            return nil
        }
        let paragraph = ResolveGroup.Key.paragraph(docId: docId, paragraphId: paragraphId)
        let piece = ResolveGroup.Key.piece(docId: docId)
        for group in groups {
            if group.key == paragraph { return paragraph }
            // A Book or Part list groups by piece: the open piece's group is
            // the caret's (review I1).
            if group.key == piece { return piece }
            if case .unplaced(let groupDoc) = group.key, groupDoc == docId,
               group.items.contains(where: { $0.paragraphId == paragraphId }) {
                return group.key
            }
        }
        return nil
    }

    /// The groups open by default. Small: every group. Dense: the caret's
    /// group only, or none when there is no caret group (the writer opens what
    /// she wants).
    static func expanded(_ groups: [ResolveGroup], cursor: ResolveGroup.Key?,
                         dense: Bool) -> Set<ResolveGroup.Key> {
        expanded(groups, cursor: cursor, dense: dense, choices: [:])
    }

    /// The groups open, with the writer's own choices (key → open), kept per
    /// group key for the life of the view, overriding the default. A choice
    /// about a group not in `groups` opens nothing.
    static func expanded(_ groups: [ResolveGroup], cursor: ResolveGroup.Key?, dense: Bool,
                         choices: [ResolveGroup.Key: Bool]) -> Set<ResolveGroup.Key> {
        var open = Set<ResolveGroup.Key>()
        for group in groups {
            let byDefault = !dense || group.key == cursor
            if choices[group.key] ?? byDefault { open.insert(group.key) }
        }
        return open
    }
}
