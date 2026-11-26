import Foundation
import Observation
import MaughamCore

/// **The language the window reads in** (shell p4 Task 8). Pure: what the
/// faces are read in, and what the switch keeps when the open piece changes.
/// The language itself lives in one place, `EditorControl.translationLanguage`;
/// these only answer questions about it.
enum ReadingLanguage {

    /// **The language the faces are read in**: an edition open in the centre
    /// (not the Source) gives its tag; a piece open and faced gives the
    /// switched language; anything else is read in the source (nil).
    static func of(subject: WindowSubject, switched: String?, sourceLanguage: String) -> String? {
        switch subject.open {
        case .edition(let language):
            return language.caseInsensitiveCompare(sourceLanguage) == .orderedSame ? nil : language
        case .item:
            return subject.faces == subject.open ? switched : nil
        case .project, .research, .figure, .inbox, .canvas, .palette:
            return nil
        }
    }

    /// **What the switch keeps when the open piece changes** (Denver,
    /// 2026-11-21, answer 2): a chapter read in a language stays in that
    /// language on the next chapter when it has the translation, else Source.
    /// The piece's own spelling of the tag is the one kept.
    static func carried(_ switched: String?, toPieceWith languages: [String]) -> String? {
        guard let switched else { return nil }
        return languages.first { $0.caseInsensitiveCompare(switched) == .orderedSame }
    }

    /// **What an edition's removal does to the reading language**: a piece
    /// read in a removed edition's language is read in Source. Pure over the
    /// window's model.
    @MainActor
    static func readsInSourceAfterRemoval(_ current: String?, reading: ReadingLanguageModel) -> Bool {
        current != nil && !reading.admits(current)
    }

    /// **What a promotion leaves of the reading language** (closing review
    /// M1): a piece promoted away is a reference here — it loads as no
    /// manuscript and reads in nothing — so the language goes; a piece the
    /// promotion gave back keeps it. Pure.
    static func kept(_ switched: String?, openItem: StructureItem?) -> String? {
        guard let switched, let openItem, EditorHost.loadsAsAManuscript(openItem) else { return nil }
        return switched
    }

    /// **⌃⌘L, Read In Next Language**: Source, then each language in the
    /// switch's order, then Source again. A language the piece no longer has
    /// starts the cycle from Source.
    static func next(after current: String?, in languages: [String]) -> String? {
        guard !languages.isEmpty else { return nil }
        guard let current,
              let i = languages.firstIndex(where: { $0.caseInsensitiveCompare(current) == .orderedSame })
        else { return languages[0] }
        return i + 1 < languages.count ? languages[i + 1] : nil
    }

    /// **The piece a find match is in**, when it is a manuscript piece — the
    /// piece read in Source when the match is chosen (fix I2: a match is a
    /// range of the source text).
    static func findMatchPiece(_ match: SearchMatch, structure: [StructureItem]) -> String? {
        guard case .manuscript = match.documentSource else { return nil }
        return TreeWalk.first(in: structure) { $0.path == match.documentPath }?.id
    }

    /// The languages a piece is offered in, in the order the switch lists
    /// them: by name, then by tag.
    static func ordered(_ languages: Set<String>) -> [String] {
        languages.sorted {
            let a = LanguageName.title($0), b = LanguageName.title($1)
            return a == b ? $0 < $1 : a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}

/// **A language, by name — the one spelling** (shell p4 Task 8: the tree's
/// `TreeEditionRows.title(forLanguage:)` and the old review pill's label were
/// two). `title` is the name ("Serbian"); `labelled` adds the tag
/// ("Serbian (sr)") where two editions could otherwise read alike in a
/// sentence. A tag with no name is itself.
enum LanguageName {
    nonisolated static func title(_ tag: String) -> String {
        guard let name = Locale.current.localizedString(forLanguageCode: tag), !name.isEmpty else {
            return tag
        }
        return name.capitalized(with: Locale.current)
    }

    nonisolated static func labelled(_ tag: String) -> String {
        let name = title(tag)
        return name == tag ? tag : "\(name) (\(tag))"
    }
}

/// **The window's reading state that is not the language** (shell p4 Task
/// 8): which languages each piece has (read once per translation change, off
/// the main actor, so a chapter change is a dictionary lookup), whether that
/// read failed, and a language waiting for the piece a click is opening.
/// Owned by `ProjectWindow`; written by `ReadingLanguageModifier` alone. The
/// source-under setting is not here: its home is `UIState`, mirrored to
/// `EditorControl.showsSourceUnder` (fix M6).
@MainActor @Observable
final class ReadingLanguageModel {
    /// What a listing of the translations folder found.
    struct Listing: Equatable, Sendable {
        var languagesByDocId: [String: Set<String>] = [:]
        /// Why the folder could not be read; nil when it was, or is absent.
        var unreadable: String?
    }

    /// Every piece's languages, from one listing of the translations folder.
    private(set) var languagesByDocId: [String: Set<String>] = [:]
    /// The folder is there and could not be read: the switch says so.
    private(set) var unreadable: String?
    /// Whether that listing has come back since the window opened.
    private(set) var hasRead = false
    /// A language a click asked for on the piece it is opening (the running
    /// round's indicator): taken on that piece's arrival only (fix M7).
    var pending: (docId: String, language: String?)?

    /// The manifest's removed editions (`BookEditions`): never offered, never
    /// read in.
    var removedEditions: [String]?

    /// The languages `docId` can be read in, in the switch's order — a
    /// removed edition's never (shell p4 closing round).
    func languages(for docId: String) -> [String] {
        ReadingLanguage.ordered(Set(BookEditions.listed(languagesByDocId[docId] ?? [], removed: removedEditions)))
    }

    /// **The door**: whether a piece may be read in `language` now — Source
    /// (nil) always; a removed edition's language never (closing review
    /// IM2: a reveal or a choice into it is refused and said).
    func admits(_ language: String?) -> Bool {
        BookEditions.lists(language, removed: removedEditions)
    }

    func adopt(_ listing: Listing) {
        if languagesByDocId != listing.languagesByDocId { languagesByDocId = listing.languagesByDocId }
        if unreadable != listing.unreadable { unreadable = listing.unreadable }
        hasRead = true
    }

    /// **The listing, telling absent from unreadable** (RULING-54). An absent
    /// folder is a book with no translations; one that is there but will not
    /// list is a failure the writer is told about, by the folder's name.
    nonisolated static func list(in projectURL: URL) -> Listing {
        let dir = TranslationStore.directoryURL(in: projectURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) else {
            return Listing()
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch {
            return Listing(unreadable: unreadableSentence(folder: dir.lastPathComponent, error: error))
        }
        return Listing(languagesByDocId: TranslationStore.languagesByDocId(in: projectURL))
    }

    nonisolated static func unreadableSentence(folder: String, error: Error) -> String {
        "The translations couldn\u{2019}t be read (\u{201C}\(folder)\u{201D}: "
            + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) + ")."
    }
}
