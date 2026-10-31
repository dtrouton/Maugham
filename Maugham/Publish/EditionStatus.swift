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

    /// One `(table figure, language)` pair — `translation_status`'s `figures`
    /// rows (report plan 9e-1): the text-cell counts of a table the documents
    /// use (`FigureUse`), by `documentRows`' layer rule.
    struct FigureRow: Equatable {
        let figureId: String
        let name: String
        let language: String
        let fresh: Int
        let stale: Int
        let missing: Int
        let verbatim: Int
        let orphans: Int
    }

    /// `figureRows`' answer; a used table whose state or translations would
    /// not read is an `UnreadableDocument` titled "Table: <name>".
    struct FigureReport: Equatable, Sendable {
        var rows: [FigureRow]
        var unreadable: [UnreadableDocument]
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
        /// The table rows folded into `rows`, kept so a desk pass that need
        /// not recount the tables (a round is running) can fold them again.
        var figures = FigureReport(rows: [], unreadable: [])
    }

    /// `documentRows`' own answer, in the per-`(document, language)` shape
    /// `translation_status` reports. The same pair for the same reason: the
    /// tool's wire form carries both halves, and folding to `Report` must not
    /// be the only way to learn a chapter was skipped.
    struct DocumentReport: Equatable, Sendable {
        var rows: [DocumentRow]
        var unreadable: [UnreadableDocument]
        /// The documents whose text this walk read, by id — handed to
        /// `figureRows` so no document is read twice.
        var texts: [String: FigureUse.Piece] = [:]
        /// The languages this walk's edition has a translation layer in
        /// (`layerLanguages`, over its `layerScope`) — handed to `figureRows`
        /// so one status pass lists and reads the layer once.
        var layer: Set<String> = []
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
    ///
    /// `reusingFigures`: the table rows a previous pass counted, folded in
    /// again instead of recounting them — the desk passes them while a round
    /// is running, whose per-ingest events would otherwise recount every
    /// table per event (`DepartmentPaneHost.refillsBudgets`' precedent; the
    /// round's end re-derives).
    static func languageRows(
        in store: ProjectStore, projectURL: URL, documentIds: [String],
        reusingFigures: FigureReport? = nil
    ) async -> Report {
        let documents = await documentRows(
            documentIds: documentIds, store: store, projectURL: projectURL)
        // The tables those documents use count too (report plan 9e-1 Task 6):
        // the coverage gate refuses an edition over an untranslated cell, so a
        // desk that left them out would read "done" over a compile that fails.
        let figures: FigureReport
        if let reusingFigures {
            figures = reusingFigures
        } else {
            figures = await figureRows(
                documentIds: documentIds, languages: Set(documents.rows.map(\.language)),
                layer: documents.layer, texts: documents.texts, store: store,
                projectURL: projectURL)
        }
        return Report(
            rows: languageRows(from: documents.rows, figures: figures.rows, in: store.manifest),
            unreadable: documents.unreadable + figures.unreadable,
            figures: figures)
    }

    /// **Which languages this book has a translation layer in** — any
    /// translation file for a manuscript document, or for a table the book
    /// prints (used in a manuscript piece and not parked, `FigureUse` — the
    /// gate counts no other table's records), read off one listing
    /// (`TranslationStore.languagesByDocId`). Which tables are used is asked
    /// only when a table's file names a language no document has.
    ///
    /// It is the coverage gate's own distinction (`TranslationCoverage.check`'s
    /// zero-layer guard): in a language with a layer, a document or table with
    /// no file of its own is untranslated, and the gate refuses the edition
    /// over every one of its paragraphs or cells — so the status counts them
    /// `missing` (report plan 9e-1 Task 6, ruling: status agrees with the
    /// gate). In a language with no layer anywhere (a translator named or a
    /// question asked, nothing written yet) the gate refuses as "no
    /// translation layer", and the status reports the edition *not started*:
    /// zero counts, not "every paragraph missing".
    ///
    /// **Over the edition the caller describes** (`scope`), as the gate's
    /// guard is over the pieces it compiles: the desk standing on an imprint
    /// passes that imprint's documents (a layer only outside them is, for
    /// that compile, no layer), the whole-book desk and `translation_status`
    /// every manuscript document — a `document_id` filter narrows the report,
    /// not the edition.
    static func layerLanguages(in store: ProjectStore, projectURL: URL, scope: [String]) async -> Set<String> {
        let byDoc = TranslationStore.languagesByDocId(in: projectURL)
        let inScope = Set(scope)
        let manuscript = manuscriptDocumentIds(in: store.manifest).filter(inScope.contains)
        var layer = manuscript.reduce(into: Set<String>()) { $0.formUnion(byDoc[$1] ?? []) }
        let tables = (store.manifest.figures ?? []).filter { $0.kind == .table }.map(\.id)
        let onlyTables = tables.reduce(into: Set<String>()) { $0.formUnion(byDoc[$1] ?? []) }
            .subtracting(layer)
        guard !onlyTables.isEmpty else { return layer }
        let figures = await store.translationFigures()
        let used = FigureUse.tables(
            in: manuscript.compactMap { text(of: $0, store: store, projectURL: projectURL) },
            figures: figures).readable
        for use in used { layer.formUnion((byDoc[use.record.id] ?? []).intersection(onlyTables)) }
        return layer
    }

    /// A manuscript document's current text (an open `Document`, else the
    /// derived state — tripwire 20), or nil when it has no path or will not
    /// read (`documentRows` names that document).
    private static func text(of documentId: String, store: ProjectStore, projectURL: URL) -> FigureUse.Piece? {
        guard let path = TreeWalk.find(id: documentId, in: store.manifest.structure)?.path,
              let state = try? currentParagraphState(
                documentId: documentId, store: store, documentStore: store.documentStore,
                projectURL: projectURL) else { return nil }
        return FigureUse.Piece(path: path, sequence: state.sequence, paragraphs: state.paragraphs)
    }

    /// One row per `(document, language)` over the documents named.
    ///
    /// **Reads the CURRENT paragraph state, never the `.md`** (tripwire 20):
    /// `currentParagraphState` prefers an open document's live `Document` and
    /// falls back to the op-log derivation, which is the same split every other
    /// translation path takes.
    ///
    /// **A document contributes nothing only when it has NO reason to** — no
    /// translation file, no open query, no stored translator anywhere in the
    /// book (issue #43, F-E), and no translation layer anywhere in the book in
    /// that language (`layerLanguages`, report plan 9e-1: such a row counts
    /// the document's paragraphs `missing`, as the gate does). The first two
    /// are facts about this document; the last two are facts about the
    /// project, so once the writer has named a single
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
    ///
    /// `layerScope`: the edition `layerLanguages` is asked over — nil for the
    /// documents named; `translation_status` passes the whole book.
    static func documentRows(
        documentIds: [String], layerScope: [String]? = nil, store: ProjectStore, projectURL: URL
    ) async -> DocumentReport {
        var rows: [DocumentRow] = []
        var unreadable: [UnreadableDocument] = []
        // A fact about the BOOK rather than about any one document, so it is
        // read once rather than per chapter — and it is why an edition the
        // writer has only just named reports a row for every manuscript
        // document instead of none at all.
        let roleLanguages = storedTranslatorLanguages(in: store.manifest)
        let layer = await layerLanguages(
            in: store, projectURL: projectURL, scope: layerScope ?? documentIds)
        var texts: [String: FigureUse.Piece] = [:]
        // ONE trust resolution for the whole book (whole-branch review, I1).
        // `TranslationStore.loadMerged` resolves its own when handed none, and
        // that is a verified read of the registry folder plus a reconcile — a
        // sixty-chapter book in three languages paid 180 of them, several on
        // the main actor. Held as a `Result` rather than resolved inside the
        // loop so a registry this Mac cannot read still degrades exactly as it
        // did: every chapter is recorded in `unreadable` with the registry
        // error's own file-naming sentence, and the walk itself never fails.
        let resolved = Result {
            try TrustResolution.resolve(projectURL: projectURL, identities: .current)
        }
        for documentId in documentIds {
            do {
                // All of this chapter's rows or none of them: a document that
                // failed halfway would otherwise leave the languages it got
                // through in the answer and the rest out of it, which reads as a
                // chapter PARTLY translated on the strength of where the failure
                // happened to land.
                let read = try await documentRows(
                    documentId: documentId, roleLanguages: roleLanguages, layer: layer,
                    store: store, projectURL: projectURL, trust: try resolved.get())
                rows += read.rows
                if let text = read.text { texts[documentId] = text }
            } catch {
                unreadable.append(UnreadableDocument(
                    documentId: documentId,
                    // The writer's own name for the chapter. The id is what a
                    // desk line falls back to when the manifest holds no row to
                    // read a title off — itself one of the ways a document
                    // arrives here.
                    title: TreeWalk.find(id: documentId, in: store.manifest.structure)?
                        .title ?? documentId,
                    // `MCPError` is a `LocalizedError`, so this is its own
                    // sentence ("Invalid argument: …") for a manifest row with
                    // no path, rather than a silent labelled skip.
                    reason: error.localizedDescription))
            }
        }
        return DocumentReport(rows: rows, unreadable: unreadable, texts: texts, layer: layer)
    }

    /// **The tables the named documents use, one row per (table, language)**
    /// (report plan 9e-1 Task 6) — `translation_status`'s `figures` and the
    /// desk's cell counts, by the coverage gate's own reader (`FigureUse`)
    /// over the book's table states (`ProjectStore.translationFigures()`:
    /// the states a publish snapshot holds, none of its costs). Languages:
    /// `languages` (the document rows') plus each table's own file languages;
    /// counted by `documentRows`' layer rule (`layerLanguages`) — derived
    /// where the book has a layer, zero (not started) where it has none.
    ///
    /// `layer` is `documentRows`' own (`DocumentReport.layer`), asked once
    /// per pass over the edition's scope. `texts` are the documents
    /// `documentRows` already read; only the rest are read here. The translation reads and derivations run off the main
    /// actor. Never throws: a document whose text will not read is already in
    /// `documentRows`' unreadable and is skipped; a table whose state or
    /// translations will not read is named.
    static func figureRows(
        documentIds: [String], languages: Set<String>, layer: Set<String>,
        texts: [String: FigureUse.Piece] = [:], store: ProjectStore, projectURL: URL
    ) async -> FigureReport {
        guard (store.manifest.figures ?? []).contains(where: { $0.kind == .table })
        else { return FigureReport(rows: [], unreadable: []) }
        let pieces = documentIds.compactMap { texts[$0] ?? text(of: $0, store: store, projectURL: projectURL) }
        let figures = await store.translationFigures()
        let used = FigureUse.tables(in: pieces, figures: figures)
        let unreadable = used.unreadable.map {
            UnreadableDocument(documentId: $0.id, title: "Table: \($0.name)",
                               reason: "its op log would not fold")
        }
        guard !used.readable.isEmpty else { return FigureReport(rows: [], unreadable: unreadable) }
        let tables = used.readable
        let counted = await Task.detached(priority: .userInitiated) {
            countRows(tables: tables, languages: languages, layer: layer, projectURL: projectURL)
        }.value
        return FigureReport(rows: counted.rows, unreadable: unreadable + counted.unreadable)
    }

    /// `figureRows`' counting half, off the main actor: one trust resolution,
    /// then each table's records read and derived per language.
    nonisolated private static func countRows(
        tables: [FigureUse.Table], languages: Set<String>, layer: Set<String>, projectURL: URL
    ) -> FigureReport {
        let byDoc = TranslationStore.languagesByDocId(in: projectURL)
        let resolved = Result {
            try TrustResolution.resolve(projectURL: projectURL, identities: .current)
        }
        var rows: [FigureRow] = []
        var unreadable: [UnreadableDocument] = []
        for use in tables {
            do {
                var perLanguage: [FigureRow] = []
                for language in languages.union(byDoc[use.record.id] ?? []).sorted() {
                    guard layer.contains(language) else {
                        perLanguage.append(FigureRow(
                            figureId: use.record.id, name: use.record.name, language: language,
                            fresh: 0, stale: 0, missing: 0, verbatim: 0, orphans: 0))
                        continue
                    }
                    let derived = try FigureUse.coverage(
                        of: use, language: language, projectURL: projectURL,
                        trust: try resolved.get()).derived
                    perLanguage.append(FigureRow(
                        figureId: use.record.id, name: use.record.name, language: language,
                        fresh: derived.freshCount, stale: derived.staleCount,
                        missing: derived.missingCount,
                        verbatim: derived.entries.filter(\.verbatim).count,
                        orphans: derived.orphans.count))
                }
                rows += perLanguage
            } catch {
                unreadable.append(UnreadableDocument(
                    documentId: use.record.id, title: "Table: \(use.record.name)",
                    reason: error.localizedDescription))
            }
        }
        return FigureReport(rows: rows, unreadable: unreadable)
    }

    /// One document's rows, throwing if either of its two reads refuses — the
    /// half of the walk that is allowed to fail, so the walk itself can be the
    /// half that never does.
    private static func documentRows(
        documentId: String, roleLanguages: [String], layer: Set<String>,
        store: ProjectStore, projectURL: URL, trust: TrustTable
    ) async throws -> (rows: [DocumentRow], text: FigureUse.Piece?) {
        // The document's text, read at most once across its languages.
        var state: (sequence: [String], paragraphs: [String: String], projectURL: URL)?
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
        // A language with a layer anywhere in the book reaches every
        // document: one with no file of its own is untranslated into it.
        let languages = editionLanguages(
            files: fileLanguages.union(layer), queries: queryLanguages, roles: roleLanguages)

        var rows: [DocumentRow] = []
        for language in languages {
            let openQueryCount = openQuestions.filter { $0.language == language }.count
            let translator = translatorName(for: language, in: store.manifest)
            guard fileLanguages.contains(language) || layer.contains(language) else {
                // A language reached through a query or a role alone, with
                // no translation file anywhere in the book: nothing to derive
                // — report it absent rather than "every paragraph missing",
                // which would conflate "not started" with "started and
                // incomplete" (the gate's zero-layer answer). The two
                // file-less arms answer alike on purpose. A language with a
                // layer elsewhere derives below over no records, so this
                // document's paragraphs read `missing` — what the gate
                // refuses the edition over (`layerLanguages`).
                rows.append(DocumentRow(
                    documentId: documentId, language: language,
                    translator: translator,
                    fresh: 0, stale: 0, missing: 0, verbatim: 0, orphans: 0,
                    openQueries: openQueryCount))
                continue
            }
            let read = try state ?? currentParagraphState(
                documentId: documentId, store: store,
                documentStore: store.documentStore, projectURL: projectURL)
            state = read
            let derived = TranslationDeriver.derive(
                // P2a D0: an unreadable actor file throws, and the walk
                // above records this whole chapter in `unreadable` with the
                // error's own file-naming sentence — the degrade both the desk
                // and `translation_status` already draw.
                records: try TranslationStore.loadMerged(
                    forDocId: documentId, language: language, in: projectURL,
                    trust: trust),
                sequence: read.sequence,
                paragraphs: read.paragraphs,
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
        guard let state, let path = TreeWalk.find(id: documentId, in: store.manifest.structure)?.path
        else { return (rows, nil) }
        return (rows, FigureUse.Piece(path: path, sequence: state.sequence, paragraphs: state.paragraphs))
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
    /// The tables' cell counts (`figures`) add into their language's row the
    /// same way, so a desk row's missing is the paragraphs and cells the gate
    /// would refuse over.
    nonisolated static func languageRows(
        from rows: [DocumentRow], figures: [FigureRow] = [], in manifest: ProjectManifest
    ) -> [LanguageRow] {
        var byLanguage: [String: LanguageRow] = [:]
        for row in figures {
            let running = byLanguage[row.language]
            byLanguage[row.language] = LanguageRow(
                language: row.language,
                translator: running?.translator ?? translatorName(for: row.language, in: manifest),
                fresh: (running?.fresh ?? 0) + row.fresh,
                stale: (running?.stale ?? 0) + row.stale,
                missing: (running?.missing ?? 0) + row.missing,
                openQueries: running?.openQueries ?? 0)
        }
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
    /// **Lowercased on read — a legacy tolerance (#46).** `translatorRole(for:)`
    /// now mints lowercase, but a manifest written by an earlier build stored the
    /// tag verbatim, so it can still carry `ES` while every translation file for
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

    /// The reader's name for a language — `translatorName`'s rule: the stored
    /// role's `effectiveName`, else the preset, else nil (nobody yet). Read-only.
    nonisolated static func readerName(for language: String, in manifest: ProjectManifest) -> String? {
        if let stored = manifest.storedReader(for: language) { return stored.effectiveName }
        return ProductionRole.defaultReaderName(language: language)
    }

    nonisolated static func collatorName(for language: String, in manifest: ProjectManifest) -> String? {
        if let stored = manifest.storedCollator(for: language) { return stored.effectiveName }
        return ProductionRole.defaultCollatorName(language: language)
    }
}
