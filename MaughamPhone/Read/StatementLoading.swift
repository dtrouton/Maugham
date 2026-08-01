import Foundation
import MaughamCore

/// Pure Read-tab statement logic (M1A Task 11, spec §6.2): what the binder's
/// Craft Intent row shows, and where its content lives.
///
/// **Statement-first with the legacy note as fallback — deliberately not a
/// swap.** Adoption (`ProjectStore+StatementAdoption.swift`) is Mac-only: it
/// runs from `ProjectStore.load`, and the phone has no `ProjectStore` and never
/// writes a manifest, so it cannot migrate anything itself. A writer who has
/// updated the phone but has not yet opened the project on the Mac still holds
/// a schema-3 manifest, a `research/craft-intent.md` note, and no `statements`
/// section at all. Reading only the statements section shows that writer
/// *nothing*, which is the second of the two reasons M1A ships Mac and phone
/// together (spec §2.5) re-created by the fix for it. Pinned by
/// `PhoneStatementReadTests.test_theReadTabStillShowsAnUnadoptedNote`.
///
/// Both arms go through a shared `MaughamCore` lookup and neither reimplements
/// one (tripwire 19): `StatementLookup.statement(in:kind:scope:)` for the
/// statement, `PaletteLookup.craftIntentItem(in:researchPrefix:)` — role-first,
/// filename as the legacy tier — for the note. There is no phone-local path
/// constant, filename test or scope parser here; a stricter local doc-id parser
/// is exactly what shipped phone-v0.1.1's "No open annotations".
enum StatementLoading {

    /// What the row is CALLED. A `Statement` carries no title — its identity is
    /// the manifest entry — so the statement arm composes one, and the writer's
    /// word for this thing did not change with the storage underneath it
    /// (the Mac's `Promotion.intentTitle` reads identically for that reason).
    ///
    /// Deliberately NOT `PaletteConvention.craftIntentTitle`: that constant is
    /// the legacy *research note's* title and belongs to the seam M1A replaces.
    /// The legacy arm doesn't need it either — a note has its own title, and
    /// showing it keeps an un-adopted project reading exactly as it shipped,
    /// including for a writer who renamed theirs.
    static let intentRowTitle = "Craft Intent"

    /// Everything the binder's intent row needs: where its content came from,
    /// what to call it, and the project-relative path to open.
    ///
    /// `relativePath` is non-optional because both arms resolve one before this
    /// exists — a statement's `path` is non-optional, and a note the shared
    /// lookup returns already had one (see `intentRow`).
    struct IntentRow: Equatable {

        /// Which arm produced this row. Carried rather than
        /// inferred: the Research-section exclusion has to know whether the
        /// legacy note is the thing on screen, and re-deriving that from the
        /// path would be a second answer to the same question.
        enum Origin: Equatable {
            /// The project's intent statement, at the project root.
            case statement
            /// The legacy craft-intent research note, in a project the Mac has
            /// not opened since statements shipped.
            case legacyNote(id: String)
        }

        let origin: Origin
        let title: String
        /// Project-relative — a statement lives at the project ROOT
        /// (`intent.md`), not under `research/`.
        let relativePath: String
    }

    /// The row for the PROJECT's intent, or nil when there is none.
    ///
    /// Project scope only, as the Read tab has always been: a document-scoped
    /// intent is a Mac surface in this milestone, and drawing a chapter's as
    /// the project's would misattribute the writer's own words.
    ///
    /// **Absence is valid** and returns nil with no side effect — the same
    /// promise `StatementLookup` makes and `read_craft_intent` already ships.
    static func intentRow(statements: [Statement], research: [ResearchItem]) -> IntentRow? {
        if let statement = StatementLookup.statement(
            in: statements, kind: .intent, scope: .project) {
            return IntentRow(
                origin: .statement, title: intentRowTitle, relativePath: statement.path)
        }
        // The unwrap is the compiler's (`ResearchItem.path` is optional) and its
        // else branch is unreachable: `craftIntentItem` only returns items whose
        // path already starts with the prefix, so a pathless note is filtered
        // out before it gets here. That is what lets `relativePath` be a plain
        // `String` and retires the row's old `path ?? ""`, which resolved a
        // pathless note to the project FOLDER and opened a directory in the
        // reader. No test asserts the unreachable branch — it could not fail.
        guard let note = PaletteLookup.craftIntentItem(in: research, researchPrefix: "research"),
              let path = note.path else { return nil }
        return IntentRow(
            origin: .legacyNote(id: note.id), title: note.title, relativePath: path)
    }
}
