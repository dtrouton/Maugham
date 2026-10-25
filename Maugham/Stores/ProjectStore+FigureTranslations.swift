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

    /// Test seam: thrown from before each of a rename's translation batches,
    /// handed its language — where a failed append is put. Nil in production.
    static var beforeTranslationRelabelAppendForTesting: ((String) throws -> Void)?

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
                        oldText: text, newText: relabelled, verbatim: record.verbatim))
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
    /// write keeps its source) — so each stays fresh. A batch that fails
    /// throws `TranslationRelabelIncomplete`, naming those that landed.
    func writeTranslationRelabel(_ held: HeldTranslationRelabel, after documents: [Document]) async throws {
        try await writeTranslations(held, batches: held.batches, documents: documents, text: \.newText)
    }

    /// **A failed rename's translations put back**, after its source text
    /// was: each batch that landed, written again with its old text and
    /// stamped against the source as it reads now. Best-effort, logged.
    func putBackTranslationRelabel(
        _ held: HeldTranslationRelabel, landed: [(docId: String, language: String)], after documents: [Document]
    ) async {
        do {
            try await writeTranslations(held, batches: landed, documents: documents, text: \.oldText)
        } catch {
            projectStoreLog.error(
                "renameFigure: a translation could not be put back after a failed relabel: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeTranslations(
        _ held: HeldTranslationRelabel, batches: [(docId: String, language: String)],
        documents: [Document], text: KeyPath<TranslationRelabel, String>
    ) async throws {
        let identities = Document.loadIdentities
        let deviceState = Document.loadDeviceState
        let byId = Dictionary(documents.map { ($0.docId, $0) }, uniquingKeysWith: { first, _ in first })
        var landed: [(docId: String, language: String)] = []
        for batch in batches {
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
            do {
                try Self.beforeTranslationRelabelAppendForTesting?(batch.language)
                _ = try await TranslationWritePipeline.perform(
                    entries: entries, language: batch.language, documentId: batch.docId,
                    state: source, actor: .author, identities: identities, deviceState: deviceState)
            } catch {
                throw TranslationRelabelIncomplete(landed: landed, underlying: error)
            }
            landed.append(batch)
        }
    }

    /// A manuscript's sequence and paragraphs: the open document's where a
    /// window has it, else derived from its op log (never the `.md`).
    private func sourceState(docId: String, path: String) -> (sequence: [String], paragraphs: [String: String])? {
        if let open = documentStore?.document(for: path) { return (open.sequence, open.paragraphs) }
        guard let state = try? derivedCache.state(forDocId: docId, in: url) else { return nil }
        return (state.sequence, state.paragraphs)
    }
}
