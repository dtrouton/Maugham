import Foundation
import MaughamCore

/// **Where a book's language editions stand** (publish-department P4 Task 2) —
/// the one derivation behind `translation_status`'s rows and the department
/// desk's language rows.
///
/// It was `TranslationStatusTool.handle`'s own body until the desk needed the
/// same figures, and the desk is exactly the surface that must not disagree
/// with the tool: a writer reading "3 stale" on the desk and a Claude session
/// reading four from `translation_status` have no way to find out which of them
/// is wrong. So the union, the coverage derivation and the open-query filter
/// live here once, and both readers are callers.
///
/// **The union has two sources, and the second is not optional.** A language
/// shows up as soon as a translator ASKS about it — the query-first workflow —
/// which is before any translation file exists for it, so file languages
/// alone would hide the edition the writer is being asked a question about.
/// And the questions are `.query` **plus language-tagged `.craftNote`**: a
/// whole-document question ("tú or usted throughout?") cannot be a `.query`,
/// because `addAnnotation` refuses an anchorless one, and counting only
/// `.query` reported `open_queries: 0` over a translator who was waiting.
///
/// **Nothing here mints.** `translatorName` is a lookup plus the preset table,
/// never `ProjectStore.translatorRole(for:)` — see that file's own doc comment,
/// which names "a desk row" as one of the read paths this rule exists for.
@MainActor
enum EditionStatus {

    /// One `(document, language)` pair — the shape `translation_status` reports.
    struct DocumentRow: Equatable {
        let documentId: String
        let language: String
        let translator: String?
        let fresh: Int
        let stale: Int
        let missing: Int
        let verbatim: Int
        let orphans: Int
        let openQueries: Int
    }

    /// One language, summed across the book — the shape the desk draws.
    ///
    /// `verbatim` and `orphans` are deliberately absent: they are per-paragraph
    /// diagnostics a translator acts on inside one document, and a project-wide
    /// total of either tells the writer nothing they can do anything about from
    /// a desk row. The tool still reports both.
    struct LanguageRow: Equatable, Identifiable {
        let language: String
        let translator: String?
        let fresh: Int
        let stale: Int
        let missing: Int
        let openQueries: Int

        var id: String { language }
    }

    /// Every manuscript leaf — the same walk `ProjectStoreASTSource` does,
    /// skipping collection references, which are another project's documents.
    static func manuscriptDocumentIds(in manifest: ProjectManifest) -> [String] {
        ProjectStore.collectDocuments(in: manifest.structure)
            .filter { $0.pieceKind != .reference }
            .map(\.id)
    }

    /// The desk's whole answer for a project: every language it has an edition
    /// in, summed over every manuscript document.
    static func languageRows(
        in store: ProjectStore, projectURL: URL
    ) async throws -> [LanguageRow] {
        languageRows(from: try await documentRows(
            documentIds: manuscriptDocumentIds(in: store.manifest),
            store: store, projectURL: projectURL))
    }

    /// One row per `(document, language)` over the documents named.
    ///
    /// **Reads the CURRENT paragraph state, never the `.md`** (tripwire 20):
    /// `currentParagraphState` prefers an open document's live `Document` and
    /// falls back to the op-log derivation, which is the same split every other
    /// translation path takes.
    ///
    /// A document with neither a translation file nor an open query for any
    /// language contributes nothing — the project-wide walk would otherwise
    /// report a row of zeroes for every untranslated chapter in the book. (For
    /// a single named document the skip is the same statement: its language set
    /// is empty, so the loop below emits nothing either way. An unknown id
    /// still fails loudly, in `withAnnotationDocument`.)
    static func documentRows(
        documentIds: [String], store: ProjectStore, projectURL: URL
    ) async throws -> [DocumentRow] {
        var rows: [DocumentRow] = []
        for documentId in documentIds {
            // Languages with an actual translation file — a cheap filename scan.
            let fileLanguages = Set(
                TranslationStore.languages(forDocId: documentId, in: projectURL))

            // Open translator questions for this document, resolved the
            // open/closed way `list_annotations` (and `TranslationReviewPane`'s
            // own filter) do, so every surface's count matches. Fetched once
            // per document; also the source of query-first languages.
            let openQuestions = try await withAnnotationDocument(
                store: store, projectURL: projectURL, documentId: documentId
            ) { document in
                document.annotations(filter: AnnotationFilter(
                    kinds: [.query, .craftNote], statuses: [.open]))
            }
            // The tag does the discriminating: an untagged craft note has a nil
            // `language` and belongs to no edition.
            let queryLanguages = Set(openQuestions.compactMap(\.language))
            let languages = fileLanguages.union(queryLanguages).sorted()
            if languages.isEmpty { continue }

            for language in languages {
                let openQueryCount = openQuestions.filter { $0.language == language }.count
                let translator = translatorName(for: language, in: store.manifest)
                guard fileLanguages.contains(language) else {
                    // Query-only language: no translation file yet, so there is
                    // no coverage to derive — report it absent rather than
                    // "every paragraph missing", which would conflate "not
                    // started" with "started and incomplete".
                    rows.append(DocumentRow(
                        documentId: documentId, language: language,
                        translator: translator,
                        fresh: 0, stale: 0, missing: 0, verbatim: 0, orphans: 0,
                        openQueries: openQueryCount))
                    continue
                }
                let state = try currentParagraphState(
                    documentId: documentId, store: store,
                    documentStore: store.documentStore, projectURL: projectURL)
                let derived = TranslationDeriver.derive(
                    records: TranslationStore.loadMerged(
                        forDocId: documentId, language: language, in: projectURL),
                    sequence: state.sequence,
                    paragraphs: state.paragraphs,
                    language: language)
                rows.append(DocumentRow(
                    documentId: documentId, language: language,
                    translator: translator,
                    fresh: derived.freshCount,
                    stale: derived.staleCount,
                    missing: derived.missingCount,
                    verbatim: derived.verbatimCount,
                    orphans: derived.orphans.count,
                    openQueries: openQueryCount))
            }
        }
        return rows
    }

    /// The per-document rows folded into one row per language.
    ///
    /// Pure and `nonisolated` so the fold is assertable on its own, without a
    /// project on disk — the shape `CanvasMembership` and `DepartmentDesk` both
    /// take for the same reason.
    ///
    /// The translator is a fact about the LANGUAGE rather than about any one
    /// document, so every row for a language already carries the same name and
    /// the first one is as good as the last; a first non-nil rather than a
    /// blind `first` only because the fold should not depend on that being
    /// true.
    nonisolated static func languageRows(from rows: [DocumentRow]) -> [LanguageRow] {
        var byLanguage: [String: LanguageRow] = [:]
        for row in rows {
            let running = byLanguage[row.language]
            byLanguage[row.language] = LanguageRow(
                language: row.language,
                translator: running?.translator ?? row.translator,
                fresh: (running?.fresh ?? 0) + row.fresh,
                stale: (running?.stale ?? 0) + row.stale,
                missing: (running?.missing ?? 0) + row.missing,
                openQueries: (running?.openQueries ?? 0) + row.openQueries)
        }
        return byLanguage.values.sorted { $0.language < $1.language }
    }

    /// The translator's display name for `language`, read **without minting**.
    ///
    /// **A read must not mint** (the rule stated in
    /// `ProjectStore+ProductionRoles.swift`'s doc comment): this is a pure
    /// lookup over `manifest.productionRoles` plus the preset table, never
    /// `ProjectStore.translatorRole(for:)`, which finds-or-creates and would
    /// stamp the manifest merely because a tool was called or a pane was
    /// looked at. Resolution order: the stored role's `effectiveName` when this
    /// language has one already (a rename or a prior mint both count), else the
    /// preset name, else nil — an unlisted, unminted language has no honest
    /// name to report, and `translation_status` omits the field while the desk
    /// row says so in words.
    ///
    /// Matching is `ProjectManifest.storedTranslator(for:)`'s — the one
    /// spelling of the case-insensitive tag compare, shared with the mint's own
    /// find-half, so no reader can disagree with the writer about which row is
    /// this language's.
    nonisolated static func translatorName(
        for language: String, in manifest: ProjectManifest
    ) -> String? {
        if let stored = manifest.storedTranslator(for: language) { return stored.effectiveName }
        return ProductionRole.defaultTranslatorName(language: language)
    }
}
