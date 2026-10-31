import Foundation
import MaughamCore

/// **One table figure's cell translations in one language** (report plan
/// 9e-1 Task 8): the figure, the table its state holds, and the derivation
/// (`FigureTranslationDeriver`) of its translation records over that table —
/// what the Translation pane's Cells list and the figure inspector's
/// Translations lines show.
struct FigureCellTranslationRead: Sendable {
    let record: FigureRecord
    let table: FigureTable
    let derived: FigureTranslatedTable
}

extension DocumentStore {

    /// **A table figure's cell translations, for the surfaces that inspect
    /// them** (report plan 9e-1 Task 8): by language, each of `languages`
    /// derived over the figure's state (an open host's fold, else the
    /// cache's — never `figures/<name>.csv`, tripwire 20), read off the main
    /// actor; a language with no file derives every text cell `missing`.
    ///
    /// Nil when there is nothing to inspect: the registry no longer lists the
    /// figure (removed — its translations are inert, R4, and surface
    /// nowhere until a restore brings the record back), it is parked in
    /// Research, it is not a table, or its state will not read. Throws for a
    /// present translation file that will not read (P2a D0).
    func figureCellTranslations(
        figureId: String, languages: [String]
    ) async throws -> [String: FigureCellTranslationRead]? {
        // The registry first, from memory: an image, a removed figure or no
        // language asks for no trust and reads no state.
        guard let listed = projectStore?.manifest.figures?.first(where: { $0.id == figureId })
        else { return nil }
        switch listed.kind {
        case .table: break
        case .image, .unknown: return nil
        }
        guard !languages.isEmpty else { return [:] }
        let figures = await translationFigures()
        guard let record = figures.records.first(where: { $0.id == figureId }),
              !figures.isParked(figureId), let state = figures.states[figureId],
              state.kind == .table else { return nil }
        let trust = try await figureTrust()
        let projectURL = self.projectURL
        let use = FigureUse.Table(record: record, table: state.table)
        return try await Task.detached(priority: .userInitiated) {
            var out: [String: FigureCellTranslationRead] = [:]
            for language in languages {
                let derived = try FigureUse.coverage(
                    of: use, language: language, projectURL: projectURL, trust: trust).derived
                out[language] = FigureCellTranslationRead(record: record, table: state.table, derived: derived)
            }
            return out
        }.value
    }

    /// The languages the book has a translation layer in — a file of one of
    /// `manifest`'s manuscript documents or registered tables names it —
    /// sorted. What the figure inspector lists a table's coverage for: a
    /// table nobody has begun reads "0 of N" in a language the book is being
    /// translated into (untouched counts as missing, as the gate counts it).
    /// A removed figure's file names no language (inert, R4).
    nonisolated static func bookTranslationLanguages(in projectURL: URL, manifest: ProjectManifest) -> [String] {
        let byDoc = TranslationStore.languagesByDocId(in: projectURL)
        var listed = Set(TreeWalk.collect(in: manifest.structure) { $0.type == .document }.map(\.id))
        listed.formUnion((manifest.figures ?? []).filter { $0.kind == .table }.map(\.id))
        return listed.reduce(into: Set<String>()) { $0.formUnion(byDoc[$1] ?? []) }.sorted()
    }
}
