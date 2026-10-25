import Foundation
import MaughamCore

// MARK: - A figure rename and the translation layer (report plan 6b final review I-2)
//
// A figure's caption is its line's text, so the paragraph-aligned translation
// layer holds the line — `](figures/old.csv){#tbl:old}` verbatim — and
// translated prose holds `@tbl:old`. A rename relabels those records in the
// same all-or-nothing step as the source text (Denver's ruling), through the
// translation layer's one write route (`TranslationWritePipeline.perform`)
// and its door, so a translated edition neither points at the moved file nor
// reads stale because of the rename.

extension ProjectStore {

    /// One translated paragraph a rename relabels: fresh before the rename,
    /// so the label is the only change and the record stays fresh after it.
    struct TranslationRelabel {
        let docId: String
        let language: String
        let paragraphId: String
        /// The record read at the hold: the one the relabel replaces. A
        /// different latest record at the write means it changed meanwhile.
        let opId: String
        /// The record's text before the rename, and after it.
        let oldText: String
        let newText: String
        let verbatim: Bool
    }

    /// **Phase one of a rename's translation change**: every fresh
    /// translated paragraph that holds a site of the rename, read and
    /// door-checked, with each document's source as it read then.
    struct HeldTranslationRelabel {
        let relabels: [TranslationRelabel]
        /// Each document's source (sequence and paragraphs) before the rename.
        let sources: [String: (sequence: [String], paragraphs: [String: String])]

        /// One write per (document, language), in a stable order.
        var batches: [(docId: String, language: String)] {
            var seen = Set<String>()
            return relabels.compactMap { each in
                seen.insert("\(each.docId)\u{0}\(each.language)").inserted ? (each.docId, each.language) : nil
            }
        }
    }

    /// **A rename's translation write that stopped part way**: `landed` are
    /// the batches written before `underlying` failed. The caller puts the
    /// source text back first, then those batches
    /// (`putBackTranslationRelabel`), so they are stamped fresh against it.
    struct TranslationRelabelIncomplete: Error {
        let landed: [(docId: String, language: String)]
        let underlying: Error
    }

    /// Test seam: documents whose translation door `holdTranslationsForRelabel`
    /// answers as refused. Empty in production.
    static var translationRelabelDoorRefusesForTesting: Set<String> = []

    /// Test seam: runs before each of a rename's translation batches, handed
    /// its language and whether it is a put-back — where a failed append, or a
    /// translation landing meanwhile, is put. Nil in production.
    static var beforeTranslationRelabelAppendForTesting: (@MainActor (String, _ puttingBack: Bool) async throws -> Void)?

    /// **Every translated paragraph a rename must relabel, held** — before
    /// anything changes. For each manuscript with translations, each
    /// language's records are read (`TranslationStore.loadMerged`, which
    /// refuses a file that is present and unreadable). A latest record that
    /// is fresh against its source paragraph and whose text holds the
    /// figure's line or a cross-reference to its label is kept, relabelled.
    /// A stale one is left: an edition never prints a stale paragraph's text
    /// (it falls back to the source, which the rename relabels), and its next
    /// translation replaces it. A document holding any is asked the
    /// translation door as this Mac's author, the key that will sign the
    /// batch (`TranslationWritePipeline.refuseUnlessTranslatable`). **A
    /// translation that will not read, or a door that refuses, refuses the
    /// whole rename** (`FigureRenameRefused.translationsNotWritable`), naming
    /// the languages, and nothing is written anywhere.
    func holdTranslationsForRelabel(_ change: FigureLabelChange) throws -> HeldTranslationRelabel {
        let identities = Document.loadIdentities
        let deviceState = Document.loadDeviceState
        // One verified registry read for every language; nil leaves each
        // read to resolve its own (and refuse alike).
        let trust = try? TrustResolution.resolve(projectURL: url, identities: identities)
        var relabels: [TranslationRelabel] = []
        var sources: [String: (sequence: [String], paragraphs: [String: String])] = [:]
        var refused = Set<String>()
        for item in Self.collectDocuments(in: manifest.structure) {
            guard let path = item.path, !DocumentFormat.ofManuscript(path: path).isScreenplay else { continue }
            let languages = TranslationStore.languages(forDocId: item.id, in: url).sorted()
            guard !languages.isEmpty else { continue }
            guard let source = sourceState(docId: item.id, path: path) else { continue }
            var found: [TranslationRelabel] = []
            for language in languages {
                let records: [TranslationRecord]
                do {
                    records = try TranslationStore.loadMerged(
                        forDocId: item.id, language: language, in: url,
                        identities: identities, state: deviceState, trust: trust)
                } catch {
                    projectStoreLog.error(
                        "renameFigure: the \(language, privacy: .public) translation of \(item.title, privacy: .public) did not read: \(error.localizedDescription, privacy: .public)")
                    refused.insert(language)
                    continue
                }
                let latest = TranslationStore.latestByParagraph(records)
                for paragraphId in source.sequence {
                    guard let record = latest[paragraphId], let text = record.text,
                          record.sourceHash == TranslationHash.hash(source.paragraphs[paragraphId] ?? ""),
                          let relabelled = Self.relabelled(text, change) else { continue }
                    found.append(TranslationRelabel(
                        docId: item.id, language: language, paragraphId: paragraphId,
                        opId: record.opId, oldText: text, newText: relabelled, verbatim: record.verbatim))
                }
            }
            guard !found.isEmpty else { continue }
            do {
                if Self.translationRelabelDoorRefusesForTesting.contains(item.id) {
                    throw FigureEditRefused(site: "holdTranslationsForRelabel")
                }
                try TranslationWritePipeline.refuseUnlessTranslatable(
                    documentId: item.id, actor: .author, identities: identities,
                    deviceState: deviceState, projectURL: url)
            } catch {
                refused.formUnion(found.map(\.language))
                continue
            }
            relabels += found
            sources[item.id] = source
        }
        guard refused.isEmpty else {
            throw FigureRenameRefused(reason: .translationsNotWritable(refused.sorted()))
        }
        return HeldTranslationRelabel(relabels: relabels, sources: sources)
    }

    /// **Phase two: the relabelled paragraphs written**, after the source
    /// text, one batch per (document, language), through the one write route
    /// (`TranslationWritePipeline.perform`, as this Mac's author), which
    /// stamps each against its source paragraph as it now reads
    /// (`documents`, the written manuscripts; a document the rename did not
    /// write keeps its source) — so each stays fresh. **A translation that
    /// changed since the hold is never overwritten**: each batch first
    /// re-reads its records, and a paragraph whose latest record is no longer
    /// the one held (a `write_translation` or the translator landing
    /// meanwhile) refuses the whole rename
    /// (`FigureRenameRefused.translationChangedMeanwhile`, naming the
    /// language). A batch that fails or is refused throws
    /// `TranslationRelabelIncomplete`, naming those that landed.
    func writeTranslationRelabel(_ held: HeldTranslationRelabel, after documents: [Document]) async throws {
        var landed: [(docId: String, language: String)] = []
        for batch in held.batches {
            do {
                try await Self.beforeTranslationRelabelAppendForTesting?(batch.language, false)
                try requireTranslationsUnchanged(held, batch)
                try await writeTranslations(held, batch: batch, documents: documents, text: \.newText)
            } catch {
                throw TranslationRelabelIncomplete(landed: landed, underlying: error)
            }
            landed.append(batch)
        }
    }

    /// **A failed rename's translations put back**, after its source text
    /// was: each batch that landed, written again with its old text and
    /// stamped against the source as it reads now. Answers the languages that
    /// could not be put back — they keep the new label against the restored
    /// source, so they now read stale, and the rename says so
    /// (`FigureRenameTranslationsNotRestored`).
    func putBackTranslationRelabel(
        _ held: HeldTranslationRelabel, landed: [(docId: String, language: String)], after documents: [Document]
    ) async -> [String] {
        var failed = Set<String>()
        for batch in landed {
            do {
                try await Self.beforeTranslationRelabelAppendForTesting?(batch.language, true)
                try await writeTranslations(held, batch: batch, documents: documents, text: \.oldText)
            } catch {
                projectStoreLog.error(
                    "renameFigure: the \(batch.language, privacy: .public) translation could not be put back after a failed relabel: \(error.localizedDescription, privacy: .public)")
                failed.insert(batch.language)
            }
        }
        return failed.sorted()
    }

    /// Each paragraph of `batch` still has the latest record the hold read,
    /// or the rename is refused naming the language.
    private func requireTranslationsUnchanged(
        _ held: HeldTranslationRelabel, _ batch: (docId: String, language: String)
    ) throws {
        let records: [TranslationRecord]
        do {
            records = try TranslationStore.loadMerged(
                forDocId: batch.docId, language: batch.language, in: url,
                identities: Document.loadIdentities, state: Document.loadDeviceState)
        } catch {
            throw FigureRenameRefused(reason: .translationsNotWritable([batch.language]))
        }
        let latest = TranslationStore.latestByParagraph(records)
        let changed = held.relabels.contains {
            $0.docId == batch.docId && $0.language == batch.language && latest[$0.paragraphId]?.opId != $0.opId
        }
        if changed { throw FigureRenameRefused(reason: .translationChangedMeanwhile([batch.language])) }
    }

    private func writeTranslations(
        _ held: HeldTranslationRelabel, batch: (docId: String, language: String),
        documents: [Document], text: KeyPath<TranslationRelabel, String>
    ) async throws {
        let byId = Dictionary(documents.map { ($0.docId, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = held.relabels.filter { $0.docId == batch.docId && $0.language == batch.language }.map {
            $0.verbatim
                ? TranslationWritePipeline.Entry(paragraphId: $0.paragraphId, verbatim: true)
                : TranslationWritePipeline.Entry(paragraphId: $0.paragraphId, text: $0[keyPath: text])
        }
        let source: TranslationWritePipeline.SourceState
        if let written = byId[batch.docId] {
            source = (written.sequence, written.paragraphs, url)
        } else {
            let before = held.sources[batch.docId]
            source = (before?.sequence ?? [], before?.paragraphs ?? [:], url)
        }
        _ = try await TranslationWritePipeline.perform(
            entries: entries, language: batch.language, documentId: batch.docId,
            state: source, actor: .author, identities: Document.loadIdentities,
            deviceState: Document.loadDeviceState)
    }
}

/// **A rename undone whose translations could not all be put back** (final
/// re-review): the source text, the record and the picture are as they
/// were, but these languages' translations keep the new label against it and
/// now read stale.
public struct FigureRenameTranslationsNotRestored: LocalizedError, Equatable {
    public let languages: [String]
    public var errorDescription: String? {
        "The rename was undone, but the " + languages.joined(separator: ", ")
            + " translation could not be put back and now reads stale."
    }
}

extension ProjectStore {

    /// A manuscript's sequence and paragraphs: the open document's where a
    /// window has it, else derived from its op log (never the `.md`).
    private func sourceState(docId: String, path: String) -> (sequence: [String], paragraphs: [String: String])? {
        if let open = documentStore?.document(for: path) { return (open.sequence, open.paragraphs) }
        guard let state = try? derivedCache.state(forDocId: docId, in: url) else { return nil }
        return (state.sequence, state.paragraphs)
    }
}
