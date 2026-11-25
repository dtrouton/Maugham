import Foundation
import MaughamCore

/// **The book's editions, with the removed ones hidden — the one question**
/// (shell p4 closing round, fix round 1). Every place that lists a language
/// the book is translated into, an edition, or something raised in one (a
/// translator's question, an edition brief's decisions) asks here, with the
/// manifest's `removedEditions`; nothing else reads that list
/// (`BookEditionsTests.test_everyLanguageListingGoesThroughBookEditions`).
///
/// **Hidden means hidden** (controller's ruling, 2026-11-22): a removed
/// edition is absent from the tree, Status, the language switch, the
/// translator's-note picker, the figure inspector, MCP's status, the Book's
/// Brief and the Book's To resolve; its files stay, and every one of those
/// lists shows it again the moment the language is added back.
enum BookEditions {

    /// Whether `language` is listed — nil (no language: the source) always is.
    nonisolated static func lists(_ language: String?, removed: [String]?) -> Bool {
        guard let language else { return true }
        return !ProjectManifest.isEdition(language, removedIn: removed)
    }

    /// `languages`, in their order, without the removed ones.
    nonisolated static func listed<S: Sequence>(_ languages: S, removed: [String]?) -> [String]
        where S.Element == String {
        languages.filter { lists($0, removed: removed) }
    }

    /// A walk of the book's notes without the questions raised in a removed
    /// edition's language — what the Book's, a Part's and a piece's To resolve
    /// read, and the tree's marks with them.
    nonisolated static func hiding(_ walk: ProjectAnnotationsSnapshot,
                                   removed: [String]?) -> ProjectAnnotationsSnapshot {
        guard let removed, !removed.isEmpty else { return walk }
        return ProjectAnnotationsSnapshot(
            annotations: walk.annotations.filter { lists($0.annotation.language, removed: removed) },
            unreadableDocIds: walk.unreadableDocIds, sequences: walk.sequences,
            figureCells: walk.figureCells)
    }

    /// What a door into a removed edition says in the app.
    nonisolated static func removedLine(language: String) -> String {
        let name = LanguageName.title(language)
        return "The \(name) edition was removed. Add \(name) again (Add Language\u{2026}) to bring it back "
            + "with its translations."
    }

    /// What MCP tells Claude of a removed edition: the writer's act, and
    /// the writer's way back (shell p5 Task 5) — Claude has no Add Language.
    nonisolated static func removedLineForClaude(language: String) -> String {
        let name = LanguageName.title(language)
        return "The writer removed the \(name) edition; it comes back when they add \(name) again."
    }

    /// **MCP's refusal**: a tool asked to write, compile, preview or propose
    /// into a removed edition's language throws, naming the way back. `nil`
    /// and the `"source"` sentinel are the source and never refused.
    nonisolated static func refuseIfRemoved(_ languages: [String?], removed: [String]?) throws {
        for language in languages.compactMap({ $0 }) where language != "source" {
            if !lists(language, removed: removed) {
                throw MCPError.invalidArgument(removedLineForClaude(language: language))
            }
        }
    }
}
