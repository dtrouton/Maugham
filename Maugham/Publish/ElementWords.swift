import Foundation
import MaughamCore

/// **The words a body prints for its report elements** (R-S16): "Figure",
/// "Table", "Section", "References", "List of Figures", "List of Tables" —
/// in the body's own language.
///
/// One source: the built-in `table` (en, es, sr in Latin script, fr, de, it,
/// pt), over which the publish config's `metadata.element_words` wins key by
/// key; any other language reads English. `forBody` is the one resolution,
/// called once per body by `PublishProblemGate.resolve` with that body's
/// language-folded metadata, and the result rides `PublishResolution.words`:
/// the resolution's target texts, the PDF's caption names and References
/// heading, and the EPUB's captions, References and nav lists all read that
/// one value, so a caption and its cross-reference never disagree.
public struct ElementWords: Sendable, Equatable {
    public var figure: String
    public var table: String
    public var section: String
    public var references: String
    public var listOfFigures: String
    public var listOfTables: String

    public init(figure: String, table: String, section: String, references: String,
                listOfFigures: String, listOfTables: String) {
        self.figure = figure
        self.table = table
        self.section = section
        self.references = references
        self.listOfFigures = listOfFigures
        self.listOfTables = listOfTables
    }

    public static let english = ElementWords(
        figure: "Figure", table: "Table", section: "Section", references: "References",
        listOfFigures: "List of Figures", listOfTables: "List of Tables")

    /// The built-in words, keyed by lowercase primary language subtag. All
    /// Latin script: a tag naming another script (`sr-Cyrl`) is not in it.
    public static let table: [String: ElementWords] = [
        "en": .english,
        "es": .init(figure: "Figura", table: "Tabla", section: "Sección", references: "Referencias",
                    listOfFigures: "Índice de figuras", listOfTables: "Índice de tablas"),
        "sr": .init(figure: "Slika", table: "Tabela", section: "Odeljak", references: "Literatura",
                    listOfFigures: "Spisak slika", listOfTables: "Spisak tabela"),
        "fr": .init(figure: "Figure", table: "Tableau", section: "Section", references: "Références",
                    listOfFigures: "Table des figures", listOfTables: "Liste des tableaux"),
        "de": .init(figure: "Abbildung", table: "Tabelle", section: "Abschnitt", references: "Literatur",
                    listOfFigures: "Abbildungsverzeichnis", listOfTables: "Tabellenverzeichnis"),
        "it": .init(figure: "Figura", table: "Tabella", section: "Sezione", references: "Riferimenti",
                    listOfFigures: "Elenco delle figure", listOfTables: "Elenco delle tabelle"),
        "pt": .init(figure: "Figura", table: "Tabela", section: "Seção", references: "Referências",
                    listOfFigures: "Lista de figuras", listOfTables: "Lista de tabelas"),
    ]

    /// The table's words for a language tag: its primary subtag, case
    /// ignored (`pt-BR` → `pt`); English for a language the table lacks, or
    /// for a tag that names a script other than Latin.
    public static func builtIn(language: String) -> ElementWords {
        let subtags = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let primary = subtags.first else { return .english }
        let script = subtags.dropFirst().first { $0.count == 4 && $0.allSatisfy(\.isLetter) }
        guard script == nil || script == "latn" else { return .english }
        return table[String(primary)] ?? .english
    }

    /// A body's words: its language's built-in words, with each word its
    /// folded config names instead (`metadata.element_words`; a blank word is
    /// no word). `metadata` is the body's language-folded metadata
    /// (`BodyPlan.Body.config.metadata`), whose `language` is the body's.
    public static func forBody(_ metadata: PublishConfig.Metadata) -> ElementWords {
        var words = builtIn(language: metadata.language)
        guard let override = metadata.elementWords else { return words }
        func pick(_ value: String?, _ word: inout String) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            word = value
        }
        pick(override.figure, &words.figure)
        pick(override.table, &words.table)
        pick(override.section, &words.section)
        pick(override.references, &words.references)
        pick(override.listOfFigures, &words.listOfFigures)
        pick(override.listOfTables, &words.listOfTables)
        return words
    }

    /// The word a numbered element or a reference to one prints before its
    /// number.
    public func word(for kind: ManuscriptLabel.Kind) -> String {
        switch kind {
        case .fig: return figure
        case .tbl: return table
        case .sec: return section
        }
    }
}
