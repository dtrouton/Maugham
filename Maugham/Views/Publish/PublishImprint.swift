import Foundation
import MaughamCore

/// **Which imprint the window stands on, and what that makes of the book**
/// (imprints P3 Task 5; moved off the Department desk in shell p4 Task 7).
///
/// The edition's compile bar picks an imprint; Run Whole Book, the edition's
/// Status, the tree's Source row and the translation pipeline all read the
/// book through it. One home, so none of them can disagree about which
/// chapters an imprint holds or which language is the book's own.
enum PublishImprint {

    /// **Remember which imprint the window stands on**, per project. `nil`
    /// clears it back to the book, which is what the picker's first row sets.
    @MainActor
    static func select(imprint: String?, in documentStore: DocumentStore) {
        documentStore.updateUIState { $0.publishImprint = imprint }
    }

    /// **The book's own language, as the compile will read it.**
    ///
    /// Resolved through `PublishConfig.resolved(imprint:pieceIDs:)` — the ONE
    /// place imprint-awareness lives — because `PublishOrchestrator` builds its
    /// `LanguageSet` with `sourceTag: config.metadata.language` off the
    /// resolved config: an imprint whose metadata carries `"language": "es"`
    /// has `es` as its source tag. Anything `resolved` refuses falls back to
    /// the book's own tag, `scopedDocumentIds`' fallback for the same case.
    static func sourceLanguage(imprint: String?, in config: PublishConfig?,
                               pieceIDs: [String]) -> String {
        guard let config else { return PublishConfig.Metadata().language }
        let resolved = (try? config.resolved(imprint: imprint,
                                             pieceIDs: pieceIDs)) ?? config
        return resolved.metadata.language
    }

    /// Every imprint the project declares, sorted — the picker's rows; empty
    /// for a config with none or a project with no config at all.
    static func imprintNames(in config: PublishConfig?) -> [String] {
        (config?.imprints.keys).map { $0.sorted() } ?? []
    }

    /// **Which imprint the picker stands on, given what was persisted.** An
    /// imprint is declared by editing `config.json`, so one can be deleted out
    /// from under a `UIState.publishImprint` naming it; `nil` (the book) is
    /// then the honest answer, and the one `scopedDocumentIds` and
    /// `sourceLanguage` reach on their own. The persisted value is not
    /// rewritten: a writer who renames an imprint back gets the choice back.
    static func selection(persisted: String?, among imprints: [String]) -> String? {
        guard let persisted, imprints.contains(persisted) else { return nil }
        return persisted
    }

    /// **Which documents an imprint holds.** Its `sections` block is an
    /// ALLOWLIST, filtered against `all` so the manifest's order stands and a
    /// stale id names nothing. No `sections`, no imprint, or a name the config
    /// does not define: the whole book.
    static func scopedDocumentIds(_ all: [String], imprint: String?,
                                  in config: PublishConfig?) -> [String] {
        guard let imprint,
              let sections = config?.imprints[imprint]?.sections else { return all }
        return all.filter { sections.keys.contains($0) }
    }

    /// The publish config's modification date, or nil when there is no config
    /// yet — a value a reload key can compare, so writing the first one
    /// re-reads. One `stat`.
    static func configModified(in projectURL: URL) -> Date? {
        let url = PublishConfigStore.fileURL(in: projectURL)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }
}
