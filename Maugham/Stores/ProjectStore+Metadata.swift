import Foundation
import MaughamCore

// MARK: - Inspector + project metadata

extension ProjectStore {

    /// Update an item's inspector fields. `nil` arguments mean "leave unchanged";
    /// to explicitly clear a field, pass an empty string for synopsis, an empty
    /// array for tags/links, or `0` for wordTarget.
    ///
    /// **There is no `status:` argument, and its absence is the point** (M3 P1
    /// Task 4). `StructureItem.status` — the free-string draft/revising/final
    /// field — was written from here by the two inspector status pickers, and
    /// those pickers are now the per-pass ladder writing through
    /// ``setPassState(id:passId:_:)``. The field survives as a LEGACY READ:
    /// `ReviewStatus.derived` falls back to it for a project that has no pass
    /// states yet, and the promotion seam carries it. Nothing writes it, and
    /// re-adding the argument here would put a second, un-derived answer back
    /// beside the ladder's — pinned by `PersonaPaneRegistryTests`' census.
    public func updateInspector(
        id: String,
        synopsis: String? = nil,
        tags: [String]? = nil,
        wordTarget: Int? = nil,
        pageTarget: Int? = nil,
        links: [String]? = nil
    ) async throws {
        guard findItem(id: id, in: manifest.structure) != nil else {
            throw ProjectStoreError.structureMissing
        }
        mutateItem(id: id) { item in
            if let synopsis { item.synopsis = synopsis }
            if let tags { item.tags = tags.isEmpty ? nil : tags }
            if let wordTarget {
                // Treat 0 as "clear the target."
                item.wordTarget = wordTarget == 0 ? nil : wordTarget
            }
            if let pageTarget {
                item.pageTarget = pageTarget == 0 ? nil : pageTarget
            }
            if let links { item.links = links.isEmpty ? nil : links }
        }
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Set — or clear — where one piece stands on ONE named review pass (M3 P1
    /// Task 4). The verb behind the inspector's pass ladder, and the one
    /// channel every future writer of `StructureItem.passStates` goes through
    /// (`PersonaPaneRegistryTests`' census).
    ///
    /// **Deliberately a verb of its own rather than a `passStates:` argument on
    /// ``updateInspector(id:synopsis:tags:wordTarget:pageTarget:links:)``.**
    /// That call's convention is whole-field replacement — pass the new array,
    /// get the new array — and a ladder row knows only about its own pass. A
    /// whole-map argument would make every row read-modify-write the dictionary
    /// at the call site, so two rows set in the same runloop turn (or a board
    /// cell and an inspector row on the same piece) would each write the map
    /// they read before the other landed, and the later save would silently
    /// drop the earlier pass. Naming the pass makes that impossible.
    ///
    /// `nil` REMOVES the key rather than storing a "not started" value —
    /// `PassState` has no such case on purpose, and an absent key is what
    /// `ReviewStatus.derived` scores as untouched. An emptied map is stored as
    /// `nil`, never `[:]`: both read the same, and absence is what keeps a
    /// cleared pass from leaving `"passStates": {}` in the manifest forever.
    public func setPassState(id: String, passId: String, _ state: PassState?) async throws {
        guard findItem(id: id, in: manifest.structure) != nil else {
            throw ProjectStoreError.structureMissing
        }
        mutateItem(id: id) { item in
            var states = item.passStates ?? [:]
            if let state {
                states[passId] = state
            } else {
                states.removeValue(forKey: passId)
            }
            item.passStates = states.isEmpty ? nil : states
        }
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Update project-level targets. Currently surfaces 3a's page target;
    /// future expansion can add total-words / deadline editing through the
    /// same path. Treat 0 as "clear the target" — mirrors per-document word
    /// target convention.
    public func updateProjectTargets(pageTarget: Int) async throws {
        var targets = manifest.targets ?? ProjectTargets()
        targets.pageTarget = pageTarget == 0 ? nil : pageTarget
        manifest.targets = targets
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Replace the project's whole review-pass list (M3 P1 Task 9 — the pass
    /// editor's one write path). An empty array is a valid, intentional
    /// value: `ProjectManifest.effectiveReviewPasses` reads an absent-or-empty
    /// `reviewPasses` as "not customized" and falls back to `ReviewPass.presets`
    /// (Task 1's rule) — so deleting every configured pass here doesn't strand
    /// the project without a ladder, it restores the four defaults.
    ///
    /// This verb never touches `StructureItem.passStates`. A pass removed
    /// from the list leaves every piece's recorded state for that id sitting
    /// untouched in the manifest — never swept — and if the same id is added
    /// back later (same slug, same name), those states are simply visible
    /// again. Documented behaviour, not a bug: sweeping on delete would need
    /// a second reader of every structure item just to throw away data a
    /// re-add would want back.
    ///
    /// Deliberately NOT a member of `PersonaPaneRegistryTests.passStateWritingFiles`
    /// — that census tracks writers of `setPassState(` (per-piece, per-pass
    /// state); this verb writes the pass LIST itself and the two never
    /// collide on the same substring.
    public func setReviewPasses(_ passes: [ReviewPass]) async throws {
        manifest.reviewPasses = passes
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Vacate or restore the coach's seat (editorial letter P1, spec §4.1).
    ///
    /// The seat is a project-level declaration of what kind of writer this
    /// is, not a per-piece setting: vacated, an unassigned piece goes back to
    /// the all-altitudes reader signed "Claude", and Le Guin's past rounds
    /// stay in the diagnostics sidecar as history — nothing here sweeps them.
    ///
    /// Deliberately separate from `setReviewPasses`: the coach is never in
    /// the ladder's array, so writing her through the pass-list verb would be
    /// the one thing spec §4.1 forbids.
    public func setCoachVacated(_ vacated: Bool) async throws {
        manifest.coachVacated = vacated
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Toggle the per-project element gutter. nil = default (show); false =
    /// hide. The screenplay editor reads this on each layout pass.
    public func setShowElementGutter(_ value: Bool?) async throws {
        manifest.showElementGutter = value
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Set or clear the per-project typography override.
    /// Pass `nil` to clear (fall back to user-level defaults).
    public func setProjectTypography(_ override: TypographySettings?) async throws {
        manifest.typography = override
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Resolve the effective typography for an editor: prefer the
    /// project-level override, otherwise fall back to the user default.
    public static func effectiveTypography(
        override: TypographySettings?,
        userDefault: TypographySettings
    ) -> TypographySettings {
        override ?? userDefault
    }

}
