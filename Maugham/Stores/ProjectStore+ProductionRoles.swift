import Foundation
import MaughamCore

/// The publish department's store seam: the project's named translators and its
/// designer, found or minted against `ProjectManifest.productionRoles`.
///
/// **The retroactive mint is LAZY, and that is the whole design.** A project
/// that has been publishing a Spanish edition since long before this milestone
/// has no translator row on disk; the spec's answer is not a scan at load but
/// the first caller that asks for `es`. Nothing walks the publish config when a
/// project opens, so "retroactive" costs nothing and project load is untouched.
///
/// **Read paths must NOT come through `translatorRole(for:)`.** A surface that
/// only *displays* who translated an edition — `translation_status`, a desk row,
/// a briefing header — looks the language up in `manifest.productionRoles` and
/// falls back to `ProductionRole.defaultTranslatorName(language:)` for a name.
/// This is the difference between a read tool and a write tool: a read that
/// mints stamps a manifest (and shifts `modified`, and reshuffles the project
/// wall) merely because somebody looked, and it does it from surfaces that have
/// no business writing at all.
///
/// `designerRole()` is on the read side of that line by construction: it answers
/// with `ProductionRole.presetDesigner` and never writes it back —
/// `effectiveReviewPasses`' posture, and tripwire 11's (no migrations). The
/// preset lives in the *merge* (`ProjectManifest.effectiveProductionRoles`),
/// not on disk.
extension ProjectStore {

    // MARK: - Translators

    /// The translator into `language`, minting one the first time anybody asks.
    ///
    /// **Idempotent**: called twice for one language it returns the same role,
    /// mints no second person, and writes nothing on the second call. Identity
    /// (`ProductionRole.id`) is what an annotation byline is signed with, so a
    /// second row for one language would split one person's work in two.
    ///
    /// Matching is **case-insensitive on the tag**, because the tag arrives from
    /// whatever named the edition and `ES` and `es` are one person's language. It
    /// is otherwise exact: `es-MX` is a language of its own here, exactly as it
    /// is in `defaultTranslatorName`'s deliberately small table — the writer
    /// naming their own regional translator beats a guess.
    ///
    /// The mint carries `defaultTranslatorName(language:)`, which is nil for an
    /// unlisted language: an un-named translator is a real state, and
    /// `effectiveName` has a last resort so no surface has to print a blank
    /// while the writer has yet to say who this is.
    ///
    /// Throws `.productionRoleLanguageEmpty` for a blank tag, and that refusal
    /// is load-bearing rather than tidy: `Role.translator(language: "")` encodes
    /// as `"translator:"`, which the decoder deliberately reads back as
    /// `.unknown` — so a row minted from a blank tag stops matching any language
    /// on the next load and the next ask mints another one, for ever.
    ///
    /// Throws `.languageTagInvalid` for a tag that is not a language tag even
    /// once lowercased (issue #43, F-F). **Tested lowercased, stored verbatim,
    /// matched case-insensitively** — the three are one posture, not a
    /// compromise: `ES` and `es-MX` are this seam's own well-formed tags (see
    /// the case-insensitivity note above) and both still mint, while `../evil`
    /// or `a b` is refused. The tag travels on into `editions/<lang>.md`, so
    /// what this actually withholds is a path segment; the *canonical-spelling*
    /// question belongs to the choke point that builds that filename
    /// (`createStatement`), which is stricter on purpose.
    ///
    /// Every shipped caller lowercases and validates before it gets here
    /// (`DepartmentPaneHost.addLanguage`, `DepartmentCastSheet`), so this is a
    /// guard the surfaces make unreachable rather than one they depend on —
    /// which is the reason for putting it at the store: the next caller
    /// inherits it instead of having to remember it.
    func translatorRole(for language: String) async throws -> ProductionRole {
        let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { throw ProjectStoreError.productionRoleLanguageEmpty }
        guard TranslationRecord.isValidLanguageTag(tag.lowercased()) else {
            throw ProjectStoreError.languageTagInvalid(language)
        }
        if let existing = manifest.storedTranslator(for: tag) { return existing }

        let minted = ProductionRole(
            id: Self.newId(prefix: "role"),
            role: .translator(language: tag),
            name: ProductionRole.defaultTranslatorName(language: tag))
        try await commitProductionRoles(manifest.productionRoles + [minted])
        return minted
    }

    // The find-half of the verb above is `ProjectManifest.storedTranslator(for:)`
    // — one spelling of the case-insensitive tag match, shared with the
    // read-only lookups that must never mint.

    // MARK: - The designer

    /// The book's designer: the stored one if the writer has named or briefed
    /// them, else `ProductionRole.presetDesigner`.
    ///
    /// **A read. It mints nothing, stamps nothing and saves nothing** — every
    /// project has a designer from the moment it exists, and writing the preset
    /// back the first time a surface asked who it was would be a migration
    /// performed by a getter (tripwire 11). The one row only appears on disk
    /// when the writer actually customizes it (`renameProductionRole`).
    ///
    /// The "is there a stored designer" question is asked of
    /// `effectiveProductionRoles`, which is where Task 3 spells the merge —
    /// re-deriving it here is the second copy that drifts. That property
    /// guarantees a designer is present, so the `??` below is a total-function
    /// belt rather than a reachable branch.
    func designerRole() -> ProductionRole {
        manifest.effectiveProductionRoles.first { role in
            if case .designer = role.role { return true }
            return false
        } ?? ProductionRole.presetDesigner
    }

    // MARK: - The writer's rename

    /// Rename a role. Trimmed; a name that is empty once trimmed is refused
    /// (`.productionRoleNameEmpty`) rather than stored — `effectiveName` promises
    /// never-empty, and a blank byline reads as a bug rather than as an unnamed
    /// person.
    ///
    /// **Renaming the preset designer materializes them**, and this is the one
    /// place the preset reaches disk. The designer every project has is not in
    /// `productionRoles` until something customizes them, so the writer's very
    /// first act on the designer would otherwise throw "no such role" — a hole
    /// under the one role every project is guaranteed to have. What gets stored
    /// is the id, the role and the typed name; **`brief` stays nil**, so
    /// `effectiveBrief` keeps resolving the preset doctrine and a later revision
    /// of it still reaches a project whose designer has been renamed. Freezing a
    /// copy of the brief into the manifest is the migration this seam is at
    /// pains not to perform.
    ///
    /// Any other unknown id throws `.productionRoleMissing` rather than
    /// no-opping: a rename that silently changes nothing is the writer typing a
    /// name into a surface that keeps showing the old one.
    func renameProductionRole(id: String, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectStoreError.productionRoleNameEmpty }

        var roles = manifest.productionRoles
        if let row = roles.firstIndex(where: { $0.id == id }) {
            roles[row].name = trimmed
        } else if id == ProductionRole.designerPresetID {
            roles.append(ProductionRole(
                id: ProductionRole.designerPresetID, role: .designer, name: trimmed))
        } else {
            throw ProjectStoreError.productionRoleMissing(id: id)
        }
        try await commitProductionRoles(roles)
    }

    // MARK: - Committing

    /// Write a new department to the manifest, **restoring the old one if the
    /// save fails**.
    ///
    /// **This is where it departs from `setReviewPasses`, which mutates and lets
    /// the throw propagate — and the difference is idempotency, not taste.**
    /// That verb writes the whole list from an explicit Save the writer pressed;
    /// a throw reaches an alert and the writer presses it again, against the
    /// same list. `translatorRole(for:)` is find-or-create, so nobody presses
    /// anything a second time: a role left standing in memory after a failed
    /// save is never re-attempted, because the *next* call finds it and returns
    /// it. The caller gets a translator whose id signs an annotation and which
    /// no reload will ever produce — silent until the project is reopened and
    /// the translator is gone.
    ///
    /// `ProductionRoleStoreTests.test_aFailedSaveLeavesNoPhantomTranslatorBehind`
    /// holds the consequence rather than the mechanism: after a refused write,
    /// the next ask MINTS again and that role reaches disk.
    private func commitProductionRoles(_ roles: [ProductionRole]) async throws {
        let previousRoles = manifest.productionRoles
        let previouslyModified = manifest.modified
        manifest.productionRoles = roles
        // `setReviewPasses`' posture: naming the people who work on the book is
        // a change to the project, not a backfilled identifier.
        manifest.modified = Date()
        do {
            try await saveManifest()
        } catch {
            manifest.productionRoles = previousRoles
            manifest.modified = previouslyModified
            throw error
        }
    }
}
