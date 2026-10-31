import Foundation
import MaughamCore

/// The one place a batch of translated paragraphs is validated, built into
/// `TranslationRecord`s, and persisted.
///
/// Extracted from `WriteTranslationTool.handle` so the MCP tool and the
/// translator-loop ingest path cannot drift. Everything that makes a batch
/// safe lives here and nowhere else: exactly one form per entry, no
/// intra-batch duplicate ids, the unknown-id all-or-nothing rule that `delete`
/// is exempt from, the server-stamped source hash no caller may supply, the
/// advisory warnings, and the single coordinated append that makes "nothing is
/// written" hold for an I/O failure and not only for a validation failure.
/// `TripwireGrepTests.test_theTranslationWritePipelineIsTheOnlyPlaceAWriteBatchIsAppended`
/// is the census.
///
/// It lives beside the tool it was extracted from rather than in
/// `MaughamCore`: it throws `MCPError` and speaks the tool's vocabulary, and
/// its second consumer is app-side too.
@MainActor
public enum TranslationWritePipeline {

    /// One paragraph's instruction, mirroring `WriteTranslationTool.Params.Entry`:
    /// exactly one of `text` (the translated paragraph), `verbatim` (copy the
    /// current source unchanged) or `delete` (tombstone this paragraph's
    /// translation). The three-optionals shape is deliberate — the wire form
    /// can express "none" and "two", and rejecting those is a validation the
    /// pipeline owns rather than a case the type forbids, so a malformed MCP
    /// call gets the same worded error it always got.
    public struct Entry: Equatable {
        public let paragraphId: String
        public let text: String?
        public let verbatim: Bool?
        public let delete: Bool?

        public init(paragraphId: String, text: String? = nil,
                    verbatim: Bool? = nil, delete: Bool? = nil) {
            self.paragraphId = paragraphId
            self.text = text
            self.verbatim = verbatim
            self.delete = delete
        }
    }

    /// The current-paragraph snapshot the batch is validated and hashed
    /// against — what `currentParagraphState` returns (tripwire 20: the live
    /// `Document` for an open doc, the op-log-derived state for a closed one,
    /// never the on-disk `.md`).
    public typealias SourceState = (
        sequence: [String], paragraphs: [String: String], projectURL: URL)

    /// The language-tag gate. Called by the pipeline itself, so no caller can
    /// mint a translation file named after a tag the readers will not parse —
    /// and callable ahead of time by a caller that wants to reject before it
    /// does the more expensive work of resolving a project.
    public static func validate(language: String) throws {
        guard TranslationRecord.isValidLanguageTag(language) else {
            throw MCPError.invalidArgument("invalid language tag: \(language)")
        }
    }

    /// Validate `entries`, build every record, and persist the whole batch in
    /// one append. Returns the advisory warnings — structural drift and
    /// equals-source reminders — which never block the write.
    ///
    /// `actor` is who is writing, and it decides both the file and the key that
    /// signs it: `.translator` for `write_translation` and the pipeline's own
    /// ingest, which is what a translation IS. The signer is taken out of
    /// `identities` rather than passed beside it, so the key a line is signed
    /// with and the keys the file is read back under cannot disagree.
    ///
    /// Throws `MCPError.invalidArgument` and writes nothing if the language
    /// tag is malformed, an entry supplies other than exactly one form, the
    /// batch repeats a paragraph id, or a `text`/`verbatim` entry names an id
    /// outside the current sequence.
    @discardableResult
    public static func perform(
        entries: [Entry],
        language: String,
        documentId: String,
        state: SourceState,
        actor: DeviceActor,
        identities: LocalIdentities = .current,
        deviceState: OpLogDeviceState = .shared
    ) async throws -> [String] {
        let known = Set(state.sequence)
        return try await write(
            Batch(
                lines: entries.map {
                    Line(id: $0.paragraphId, label: $0.paragraphId, text: $0.text,
                         verbatim: $0.verbatim, delete: $0.delete)
                },
                singular: "paragraph", duplicates: "paragraph ids",
                // 3. All-or-nothing: every id a `text` or `verbatim` entry names
                // must be in the current sequence. A `delete` entry is exempt —
                // an orphaned translation names a paragraph the document no
                // longer has, which is exactly the one a writer needs to purge,
                // and tombstoning an id that was never translated is an
                // idempotent no-op. The exemption is per entry, not per batch: a
                // text entry's unknown id still rejects the whole call, its
                // delete siblings included.
                refuseTargets: { writes in
                    let unknown = writes.map(\.id).filter { !known.contains($0) }
                    return unknown.isEmpty
                        ? nil : "unknown paragraph ids: \(unknown.joined(separator: ", "))"
                },
                source: { state.paragraphs[$0.id] ?? "" },
                advise: { line, source, translation in
                    var warnings = ConstructSkeleton.warnings(
                        source: source, translation: translation, paragraphId: line.id)
                    // Both sides in display form, normalized through the same
                    // stripper the freshness hash normalizes with: against the
                    // raw source this comparison could never fire on an anchored
                    // paragraph — a slugline or a numeral, the very lines the
                    // advisory exists for.
                    if MarkdownDisplayFilter.stripAnchors(translation)
                        == MarkdownDisplayFilter.stripAnchors(source) {
                        warnings.append(
                            "¶\(line.id): translated text equals source — mark " +
                            "verbatim: true if deliberate")
                    }
                    return warnings
                }),
            language: language, documentId: documentId, projectURL: state.projectURL,
            actor: actor, identities: identities, deviceState: deviceState)
    }

    // MARK: - A table's text cells (report plan 9e-1 Task 3)

    /// One text cell's instruction: `perform`'s three forms, addressed by the
    /// cell's row and column ids (stored; ruling R8 — a caller that speaks A1
    /// resolves it against the current table first, as `write_translation`
    /// does).
    public struct CellEntry: Equatable {
        public let key: CellKey
        public let text: String?
        public let verbatim: Bool?
        public let delete: Bool?

        public init(key: CellKey, text: String? = nil,
                    verbatim: Bool? = nil, delete: Bool? = nil) {
            self.key = key
            self.text = text
            self.verbatim = verbatim
            self.delete = delete
        }
    }

    /// **Translate a table figure's text cells** — the same door, forms,
    /// duplicate rule, server-stamped source hash and single append as
    /// `perform`, over `table` (the figure's state as the op log folds it —
    /// an open host or the figure cache, never the rendered `figures/<name>.csv`, tripwire 20).
    ///
    /// A `text`/`verbatim` entry must name a live TEXT cell
    /// (`FigureTextCells.isTextCell`, ruling R1): an id the table no longer
    /// holds is refused as unknown, and a number, date, formula or blank cell
    /// as not text — those are shared across languages. A `delete` entry is
    /// exempt from both, per entry, so a cell orphan (a deleted row or column,
    /// a label turned into a number) can be purged.
    ///
    /// Posts `maughamTranslationDidUpdate` naming `figure_id` and `language`
    /// once the batch is on disk, whoever wrote it, so a card or pane showing
    /// the figure refreshes.
    ///
    /// `briefedSources` (report plan 9e-2, Review Focus 2) is the translator
    /// round's snapshot: each cell's source text as the model was SHOWN it. A
    /// cell named there is hashed (and copied, for `verbatim`) against that
    /// text rather than the table's current one, so a label the writer edited
    /// while the round was out lands stale over the new wording instead of
    /// reading fresh forever. The target rule still asks the CURRENT table —
    /// a cell whose row or column is gone is refused, as for every caller.
    @discardableResult
    public static func performCells(
        entries: [CellEntry],
        language: String,
        figureId: String,
        table: FigureTable,
        projectURL: URL,
        actor: DeviceActor,
        briefedSources: [CellKey: String] = [:],
        identities: LocalIdentities = .current,
        deviceState: OpLogDeviceState = .shared
    ) async throws -> [String] {
        func label(_ key: CellKey) -> String {
            FigureGridAddress.string(for: key, in: table)
                ?? FigureCellTranslationKey.paragraphId(for: key)
        }
        let keys = Dictionary(
            entries.map { (FigureCellTranslationKey.paragraphId(for: $0.key), $0.key) },
            uniquingKeysWith: { first, _ in first })
        let warnings = try await write(
            Batch(
                lines: entries.map {
                    Line(id: FigureCellTranslationKey.paragraphId(for: $0.key),
                         label: label($0.key), text: $0.text,
                         verbatim: $0.verbatim, delete: $0.delete)
                },
                singular: "cell", duplicates: "cells",
                refuseTargets: { writes in
                    let unknown = writes.filter {
                        guard let key = keys[$0.id] else { return true }
                        return table.rowIndex(of: key.row) == nil
                            || table.columnIndex(of: key.column) == nil
                    }
                    if !unknown.isEmpty {
                        return "unknown cells in this table: "
                            + unknown.map(\.label).joined(separator: ", ")
                    }
                    let notText = writes.filter {
                        !FigureTextCells.isTextCell(keys[$0.id].flatMap { table[$0] })
                    }
                    if !notText.isEmpty {
                        return "not text cells: " + notText.map(\.label).joined(separator: ", ")
                            + " — only a cell holding typed text translates; numbers, "
                            + "dates and formulas are shared by every language"
                    }
                    return nil
                },
                source: { line in
                    if let key = keys[line.id], let briefed = briefedSources[key] { return briefed }
                    return FigureTextCells.sourceText(keys[line.id].flatMap { table[$0] }) ?? ""
                },
                advise: { line, source, translation in
                    translation == source
                        ? ["\(line.label): translated text equals source — mark "
                            + "verbatim: true if deliberate"]
                        : []
                }),
            language: language, documentId: figureId, projectURL: projectURL,
            actor: actor, identities: identities, deviceState: deviceState)
        MaughamEvent.post(
            .maughamTranslationDidUpdate,
            to: .project(for: projectURL),
            payload: ["figure_id": figureId, "language": language])
        return warnings
    }

    // MARK: - The shared core

    /// One entry as the core sees it: `id` is the record's key on disk,
    /// `label` how a refusal names it to the writer.
    private struct Line {
        let id: String
        let label: String
        let text: String?
        let verbatim: Bool?
        let delete: Bool?
    }

    /// What differs between a paragraph batch and a cell batch: the words a
    /// refusal uses, which targets a `text`/`verbatim` entry may name
    /// (`refuseTargets` answers the refusal sentence, nil when every one is
    /// known), the source a record is hashed against, and the advisories.
    private struct Batch {
        let lines: [Line]
        let singular: String
        let duplicates: String
        let refuseTargets: ([Line]) -> String?
        let source: (Line) -> String
        let advise: (Line, _ source: String, _ translation: String) -> [String]
    }

    /// **The one body both kinds of batch run through**: the language gate,
    /// the permit, exactly one form per entry, no repeated target, the target
    /// rule, record building, and the single append.
    private static func write(
        _ batch: Batch, language: String, documentId: String, projectURL: URL,
        actor: DeviceActor, identities: LocalIdentities, deviceState: OpLogDeviceState
    ) async throws -> [String] {
        // 1. Valid language tag.
        try validate(language: language)

        // 1a. **May this device's `actor` write a translation of this piece at
        // all?** (signed op log P3c Task 8.) Asked before anything is built or
        // appended, so a refusal writes nothing — a line a reader would set
        // aside is never signed in the first place.
        try refuseUnlessTranslatable(
            documentId: documentId, actor: actor, identities: identities,
            deviceState: deviceState, projectURL: projectURL)

        // 2. Each entry supplies exactly one of `text` / `verbatim: true` /
        // `delete: true`. A `text` that is empty or whitespace is read as
        // ABSENT (#77 F9) — `ReportJSON.nonEmptyString`, the discipline the
        // pipeline's own ingest (`TranslatorReport.parseEntry`) already
        // applies — so it meets this same refusal rather than storing `""`,
        // which coverage and publishing would read as translated. An empty
        // source paragraph's right form is `verbatim: true`.
        for e in batch.lines {
            let hasText = ReportJSON.nonEmptyString(e.text) != nil
            let forms = [hasText, e.verbatim == true, e.delete == true]
            if forms.filter({ $0 }).count != 1 {
                throw MCPError.invalidArgument(
                    "entry for \(batch.singular) \(e.label) must supply exactly one of " +
                    "`text`, `verbatim: true` or `delete: true`")
            }
        }

        // 2a. Reject intra-batch duplicate targets (a client bug).
        let ids = batch.lines.map(\.id)
        let repeated = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })
        if !repeated.isEmpty {
            var named: [String] = []
            for line in batch.lines where repeated.contains(line.id) && !named.contains(line.label) {
                named.append(line.label)
            }
            throw MCPError.invalidArgument(
                "duplicate \(batch.duplicates) in batch: \(named.sorted().joined(separator: ", "))")
        }

        // 3. The target rule, over the entries that write text (a `delete` is
        // exempt per entry).
        if let refusal = batch.refuseTargets(batch.lines.filter { $0.delete != true }) {
            throw MCPError.invalidArgument(refusal)
        }

        // 4-6. Build every record first, then persist the whole batch in one
        // write, so "nothing is written" holds for an I/O failure and not only
        // for a validation failure. Every record carries `language` — one call
        // is one language, the invariant the batch append takes the tag as a
        // parameter for and does not re-check per record.
        var warnings: [String] = []
        var records: [TranslationRecord] = []
        for e in batch.lines {
            let source = batch.source(e)
            let isVerbatim = e.verbatim == true
            let isDelete = e.delete == true
            // `text == nil` is the tombstone `TranslationStore.latestByParagraph`
            // already honors — the delete form is what finally mints one.
            let text: String? = isDelete ? nil : (isVerbatim ? source : (e.text ?? ""))
            records.append(TranslationRecord(
                paragraphId: e.id,
                language: language,
                text: text,
                sourceHash: TranslationHash.hash(source),
                verbatim: isVerbatim))
            if !isVerbatim, !isDelete, let translation = text {
                warnings.append(contentsOf: batch.advise(e, source, translation))
            }
        }
        try await TranslationStore.appendBatch(
            records, forDocId: documentId, language: language,
            identity: identities[actor], identities: identities,
            state: deviceState, in: projectURL)

        return warnings
    }

    // MARK: - The permit (signed op log P3c Task 8)

    /// **Refuse, before anything is written, a translation this device's
    /// `actor` may not sign.**
    ///
    /// Judged as the ACTOR that signs the lines — `.translator` for
    /// `write_translation` and the pipeline's ingest — never as the writer's
    /// own hand: the actor is what the reader judges (`PermitJudge
    /// .translation`), so a refusal here is exactly a line the next read would
    /// have set aside. And in the class the reader CONSTRUCTS for a
    /// translation stream (`DocumentClass.translationClass(ofDocId:facts:)`) —
    /// `.translation(piece:)` for a piece's id, which reads no manifest, and
    /// a figure's id judged by the figure's piece (report plan 9e-1, ruling
    /// R2) — rather than one resolved as a stream.
    ///
    /// **Built through Core's posture door, over the one builder**
    /// (`PostureDoor`, `OpLogStore.localWritePermit` — tripwire 46; controller
    /// ruling A; P3c plan 2 Task 1): the pipeline is reached from MCP and
    /// from the translator's ingest with a project URL and no window, and its
    /// callers inject the identities and the device memory the lines are
    /// signed with — the permit is asked over the SAME ones, so the key that
    /// would sign and the key that was judged cannot come apart. A book with
    /// no register asks nothing and answers yes.
    static func refuseUnlessTranslatable(
        documentId: String, actor: DeviceActor, identities: LocalIdentities,
        deviceState: OpLogDeviceState, projectURL: URL
    ) throws {
        let store = OpLogStore(
            projectURL: projectURL, presenter: nil, identities: identities,
            state: deviceState, cache: Document.loadRegistryCache)
        let posture = PostureDoor.posture(as: actor, using: store) {
            DocumentClass.translationClass(ofDocId: documentId) {
                OpLogStore.manifestFacts(in: projectURL)
            }
        }
        guard posture.allows(.translate) else {
            let refused = refusedThing(documentId, in: projectURL)
            throw MCPError.toolError(payload: .init(
                error: "translation_not_permitted",
                message: notPermittedSentence(refused),
                hint: refused.hint,
                fields: ["document_id": .string(documentId)]))
        }
    }

    /// What a refused translation names, as the writer knows it.
    enum RefusedThing: Equatable {
        /// A piece, by its title where the manifest names it, else its id.
        case piece(title: String)
        /// A figure, by its kind and name ("Table: cash"), and the title of
        /// the piece it belongs to — nil for a whole-book figure.
        case figure(name: String, pieceTitle: String?)
        /// A figure whose record has not reached this Mac.
        case unknownFigure

        var hint: String {
            switch self {
            case .piece:
                return "This Mac's part in the book does not reach that piece. "
                    + "Nothing was written; the piece's author can translate it."
            case .figure:
                return "This Mac's part in the book does not reach that table. "
                    + "Nothing was written; an author whose part reaches it can translate it."
            case .unknownFigure:
                return "The figure's record has not arrived on this Mac yet. "
                    + "Nothing was written; try again once the book has synced."
            }
        }
    }

    /// The sentence a refused translation is told in — never "that piece"
    /// with a figure's id (report plan 9e-1).
    static func notPermittedSentence(_ refused: RefusedThing) -> String {
        switch refused {
        case .piece(let title):
            return "This Mac may not translate \u{201C}\(title)\u{201D} \u{2014} your part in "
                + "this book doesn\u{2019}t reach that piece, so nothing was written."
        case .figure(let name, let pieceTitle?):
            return "This Mac may not translate \(name) \u{2014} it belongs to "
                + "\u{201C}\(pieceTitle)\u{201D}, which your part in this book doesn\u{2019}t "
                + "reach, so nothing was written."
        case .figure(let name, nil):
            return "This Mac may not translate \(name) \u{2014} it belongs to the whole book, "
                + "which your part in this book doesn\u{2019}t reach, so nothing was written."
        case .unknownFigure:
            return "This Mac can\u{2019}t translate that figure yet \u{2014} its record "
                + "hasn\u{2019}t reached this Mac, so nothing was written."
        }
    }

    /// The piece or figure `documentId` names, read off the manifest on disk.
    static func refusedThing(_ documentId: String, in projectURL: URL) -> RefusedThing {
        let url = projectURL.appendingPathComponent(ProjectManifest.fileName)
        let manifest = (try? Data(contentsOf: url)).flatMap {  // adr-0018-ok: project manifest JSON read for a title, not manuscript
            try? ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: $0)
        }
        if let record = manifest?.figures?.first(where: { $0.id == documentId }) {
            let noun: String
            switch record.kind {
            case .table: noun = "Table"
            case .image, .unknown: noun = "Figure"
            }
            let pieceTitle = record.piece.map { piece in
                manifest.flatMap { TreeWalk.find(id: piece, in: $0.structure)?.title } ?? piece
            }
            return .figure(name: "\(noun): \(record.name)", pieceTitle: pieceTitle)
        }
        if DocumentClass.isFigureDocId(documentId) { return .unknownFigure }
        let title = manifest.flatMap { TreeWalk.find(id: documentId, in: $0.structure)?.title }
        return .piece(title: title ?? documentId)
    }
}
