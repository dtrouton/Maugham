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
/// **The union has three sources, and none of them is optional.** A language
/// shows up as soon as a translator ASKS about it — the query-first workflow —
/// which is before any translation file exists for it, so file languages
/// alone would hide the edition the writer is being asked a question about.
/// And the questions are `.query` **plus language-tagged `.craftNote`**: a
/// whole-document question ("tú or usted throughout?") cannot be a `.query`,
/// because `addAnnotation` refuses an anchorless one, and counting only
/// `.query` reported `open_queries: 0` over a translator who was waiting.
///
/// **The third source is a stored translator role, and it is what lets the desk
/// START an edition** (cast-management, 2026-08-21). Before it, the only ways
/// into this union were a file somebody else had written and a question
/// somebody else had asked — so *Add Language* had nowhere to put its answer,
/// and a writer who named a Portuguese translator saw nothing at all until the
/// first paragraph of Portuguese existed. The role anchors the edition:
/// `ProjectManifest.productionRoles`' `.translator(language:)` rows join the
/// union, case-insensitively (`ES` and `es` are one person's language, exactly
/// as `storedTranslator(for:)` reads them), and a language that has only a role
/// derives no coverage — the query-first arm's own answer, for the query-first
/// arm's own reason: nothing has been translated, which is *not started* rather
/// than *every paragraph missing*.
///
/// **One derivation, so both readers widen together**: the desk's rows and
/// `translation_status`'s are this file, and a tool that could not see an
/// edition the desk had just started would be the disagreement this type exists
/// to prevent.
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

    /// A manuscript document the walk could not open. Its rows are missing
    /// from the report and this says so; nothing else about the book is
    /// affected (issue #43, F-D).
    struct UnreadableDocument: Equatable, Sendable {
        let documentId: String
        let title: String
        /// The underlying error's own sentence.
        ///
        /// **Not plain `localizedDescription`**, because the most likely error
        /// here is an `MCPError`, which conforms to `Error` and not to
        /// `LocalizedError` — so Foundation answers "The operation couldn't be
        /// completed. (Maugham.MCPError error 3.)" for it. A reason a writer
        /// cannot act on is the same silent skip with a label that F-D exists
        /// to stop, so the catch site asks `MCPError` for its own `message`
        /// first. See `documentRows`.
        let reason: String
    }

    /// **The desk's whole answer, degrades included** (issue #43, F-D).
    ///
    /// A pair rather than a bare array because the two halves are one reading:
    /// a caller holding `rows` alone cannot tell a book with one edition from a
    /// book with four whose other three chapters would not open, and that is
    /// exactly the false claim this milestone is about. Both readers take the
    /// whole value — the desk draws a line per entry above its rows, the tool
    /// reports `unreadable_documents` beside them — so the two cannot degrade
    /// differently.
    struct Report: Equatable, Sendable {
        var rows: [LanguageRow]
        var unreadable: [UnreadableDocument]
    }

    /// `documentRows`' own answer, in the per-`(document, language)` shape
    /// `translation_status` reports. The same pair for the same reason: the
    /// tool's wire form carries both halves, and folding to `Report` must not
    /// be the only way to learn a chapter was skipped.
    struct DocumentReport: Equatable, Sendable {
        var rows: [DocumentRow]
        var unreadable: [UnreadableDocument]
    }

    /// Every manuscript leaf — the same walk `ProjectStoreASTSource` does,
    /// skipping collection references, which are another project's documents.
    static func manuscriptDocumentIds(in manifest: ProjectManifest) -> [String] {
        ProjectStore.collectDocuments(in: manifest.structure)
            .filter { $0.pieceKind != .reference }
            .map(\.id)
    }

    /// The desk's whole answer for a project: every language it has an edition
    /// in, summed over every manuscript document — plus every document the walk
    /// could not open.
    ///
    /// **Nothing here throws** (issue #43, F-D). Every failure this derivation
    /// can meet is one document's, and one document's failure is recorded and
    /// stepped over inside `documentRows`; there is no work outside that loop
    /// left to fail. So a caller has no error arm to get wrong, which is what
    /// retired the desk's own — a `catch` that kept stale rows and said nothing.
    static func languageRows(
        in store: ProjectStore, projectURL: URL
    ) async -> Report {
        await languageRows(in: store, projectURL: projectURL,
                           documentIds: manuscriptDocumentIds(in: store.manifest))
    }

    /// **The same answer over a NAMED set of documents** (imprints P3 Task 5).
    ///
    /// An imprint whose `sections` block is an allowlist compiles a subset of
    /// the book, and a desk standing on that imprint must sum the subset: an
    /// edition is "3 missing" against the whole novel and complete against the
    /// pamphlet cut from it, and the writer about to press Compile is asking
    /// about the thing that will actually be compiled.
    ///
    /// Additive rather than a parameter with a default on the call above,
    /// because the two are different questions and the whole-book one has a
    /// caller (`translation_status`, the tool this desk must agree with) that
    /// must never accidentally acquire a scope.
    static func languageRows(
        in store: ProjectStore, projectURL: URL, documentIds: [String]
    ) async -> Report {
        let documents = await documentRows(
            documentIds: documentIds, store: store, projectURL: projectURL)
        return Report(
            rows: languageRows(from: documents.rows, in: store.manifest),
            unreadable: documents.unreadable)
    }

    /// One row per `(document, language)` over the documents named.
    ///
    /// **Reads the CURRENT paragraph state, never the `.md`** (tripwire 20):
    /// `currentParagraphState` prefers an open document's live `Document` and
    /// falls back to the op-log derivation, which is the same split every other
    /// translation path takes.
    ///
    /// **A document contributes nothing only when it has NO reason to** — no
    /// translation file, no open query, and no stored translator anywhere in the
    /// book (issue #43, F-E). The first two are facts about this document; the
    /// third is a fact about the project, so once the writer has named a single
    /// translator, every manuscript document contributes a zero row for that
    /// language and none of them is skipped. What the skip prevents is a row of
    /// zeroes for every untranslated chapter in a book that has named nobody at
    /// all. (For a single named document the skip is the same statement: its
    /// language set is empty, so the loop below emits nothing either way.)
    ///
    /// **The per-document open above is unconditional, and it dates from P2's
    /// QUERY widening rather than from the role union.** Reading open questions
    /// is what put a `withAnnotationDocument` load on every document, including
    /// the ones with nothing translated into them — before that, a document with
    /// no translation file was skipped before anything opened it. The role union
    /// (cast-management, 2026-08-21) widened which documents produce ROWS, not
    /// which ones are opened; a sweep that reads the two together concludes the
    /// wrong provenance, and issue #43 was filed carrying exactly that reading.
    ///
    /// **A document that will not open is recorded and stepped over** (F-D). Any
    /// error class degrades that one document — an `OpLogStore.ReadError` for a
    /// history file that is present and unreadable, an `MCPError.invalidArgument`
    /// for a manifest row with no path — and its rows are simply missing from the
    /// answer, with `unreadable` saying which chapter and why. Nothing is written
    /// here, so there is nothing a half-finished walk can damage; the only thing
    /// at stake is whether the two readers tell the writer the truth about the
    /// rest of the book.
    ///
    /// **This degrade is for documents the MANIFEST lists.** Every id reaching
    /// here comes from a manifest walk — `manuscriptDocumentIds` above, or the
    /// one id `translation_status` was asked for, which that tool checks against
    /// the manifest before calling. An id nobody's manifest holds is a caller's
    /// mistake rather than a damaged chapter, and it fails loudly at the tool;
    /// were it recorded here instead, a typo would be reported to its author as
    /// a chapter they should go and repair.
    static func documentRows(
        documentIds: [String], store: ProjectStore, projectURL: URL
    ) async -> DocumentReport {
        var rows: [DocumentRow] = []
        var unreadable: [UnreadableDocument] = []
        // A fact about the BOOK rather than about any one document, so it is
        // read once rather than per chapter — and it is why an edition the
        // writer has only just named reports a row for every manuscript
        // document instead of none at all.
        let roleLanguages = storedTranslatorLanguages(in: store.manifest)
        for documentId in documentIds {
            do {
                // All of this chapter's rows or none of them: a document that
                // failed halfway would otherwise leave the languages it got
                // through in the answer and the rest out of it, which reads as a
                // chapter PARTLY translated on the strength of where the failure
                // happened to land.
                rows += try await documentRows(
                    documentId: documentId, roleLanguages: roleLanguages,
                    store: store, projectURL: projectURL)
            } catch {
                unreadable.append(UnreadableDocument(
                    documentId: documentId,
                    // The writer's own name for the chapter. The id is what a
                    // desk line falls back to when the manifest holds no row to
                    // read a title off — itself one of the ways a document
                    // arrives here.
                    title: TreeWalk.find(id: documentId, in: store.manifest.structure)?
                        .title ?? documentId,
                    // **`MCPError` is not a `LocalizedError`**, so
                    // `localizedDescription` renders it as "The operation
                    // couldn't be completed. (Maugham.MCPError error 3.)" —
                    // and `MCPError.invalidArgument` is precisely what a
                    // manifest row with no path throws
                    // (`withAnnotationDocument`). Naming the chapter and then
                    // saying nothing usable about it is the labelled silent
                    // skip this degrade exists to replace, so its own `message`
                    // comes first; every other error class keeps
                    // `localizedDescription`, which for them is a real
                    // sentence (`OpLogStore.ReadError`).
                    reason: (error as? MCPError)?.message ?? error.localizedDescription))
            }
        }
        return DocumentReport(rows: rows, unreadable: unreadable)
    }

    /// One document's rows, throwing if either of its two reads refuses — the
    /// half of the walk that is allowed to fail, so the walk itself can be the
    /// half that never does.
    private static func documentRows(
        documentId: String, roleLanguages: [String],
        store: ProjectStore, projectURL: URL
    ) async throws -> [DocumentRow] {
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
        let languages = editionLanguages(
            files: fileLanguages, queries: queryLanguages, roles: roleLanguages)

        var rows: [DocumentRow] = []
        for language in languages {
            let openQueryCount = openQuestions.filter { $0.language == language }.count
            let translator = translatorName(for: language, in: store.manifest)
            guard fileLanguages.contains(language) else {
                // A language reached through a query or a role alone: no
                // translation file yet, so there is no coverage to derive —
                // report it absent rather than "every paragraph missing",
                // which would conflate "not started" with "started and
                // incomplete". The two file-less arms answer alike on
                // purpose; a role-only edition that reported the whole book
                // as missing would be a third coverage policy saying the
                // same thing in a more alarming way.
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
    /// **…and a book with no chapters yet still shows the editions it has
    /// named** (cast-management, 2026-08-21). The fold above can only produce
    /// what the document walk gave it, and the walk has nothing to walk in a
    /// project whose manuscript is still empty — so *Add Language* on a fresh
    /// project would have written a role to disk and changed nothing on screen.
    /// The manifest closes that one gap and no other: with a single chapter in
    /// the book, every stored translator already has a document row here.
    nonisolated static func languageRows(
        from rows: [DocumentRow], in manifest: ProjectManifest
    ) -> [LanguageRow] {
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
        for tag in storedTranslatorLanguages(in: manifest)
        where !byLanguage.keys.contains(where: {
            $0.caseInsensitiveCompare(tag) == .orderedSame
        }) {
            byLanguage[tag] = LanguageRow(
                language: tag, translator: translatorName(for: tag, in: manifest),
                fresh: 0, stale: 0, missing: 0, openQueries: 0)
        }
        return byLanguage.values.sorted { $0.language < $1.language }
    }

    /// Every language this book has a stored translator for — the union's third
    /// source, and the only one that is a fact about the project rather than
    /// about a document.
    ///
    /// `.designer` and `.unknown` rows are not editions and contribute nothing.
    /// A blank tag cannot reach here through the decoder (`"translator:"` reads
    /// back as `.unknown`, deliberately) but an in-memory role could carry one,
    /// and a blank language would put a nameless row on every desk.
    ///
    /// **Lowercased, and that is load-bearing rather than tidy.** A role's tag
    /// is whatever named the edition and `translatorRole(for:)` stores it
    /// verbatim, so a manifest can carry `ES` while every translation file for
    /// it is `es`. Left alone, the chapter with a file would report `es` and the
    /// chapter without one would report `ES` — one edition drawn as two rows,
    /// which no per-document fold can see. And the write pipeline's own
    /// `isValidLanguageTag` is lowercase-only, so a row spelled `ES` would offer
    /// a Run that could never write anything.
    nonisolated static func storedTranslatorLanguages(
        in manifest: ProjectManifest
    ) -> [String] {
        manifest.productionRoles.compactMap { role in
            guard case .translator(let tag) = role.role else { return nil }
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed.lowercased()
        }
    }

    /// **The union, as one pure function** — so the rule is assertable without a
    /// project on disk, and so the two callers above cannot spell it differently.
    ///
    /// Files and queries are unioned exactly as they always were (both arrive
    /// already lowercased in practice — a filename scan and an annotation tag).
    /// A ROLE joins only when no language already present matches it
    /// case-insensitively: `storedTranslator(for:)` reads `ES` and `es` as one
    /// person's language, so a manifest that spells the tag one way and a
    /// translation file that spells it the other must not draw the writer two
    /// rows for one edition.
    nonisolated static func editionLanguages(
        files: Set<String>, queries: Set<String>, roles: [String]
    ) -> [String] {
        var languages = files.union(queries)
        var seen = Set(languages.map { $0.lowercased() })
        for tag in roles where seen.insert(tag.lowercased()).inserted {
            languages.insert(tag)
        }
        return languages.sorted()
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
