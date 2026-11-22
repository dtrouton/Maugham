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
/// the main actor, so a chapter change is a dictionary lookup), whether the
/// source is drawn under each paragraph, and a language waiting for the piece
/// a click is opening. Owned by `ProjectWindow`; written by
/// `ReadingLanguageModifier` alone.
@MainActor @Observable
final class ReadingLanguageModel {
    /// Every piece's languages, from one listing of the translations folder.
    private(set) var languagesByDocId: [String: Set<String>] = [:]
    /// Whether that listing has come back since the window opened.
    private(set) var hasRead = false
    /// The writer's View ▸ Show Source Under Translation, mirrored from
    /// `UIState.showsSourceUnderTranslation`.
    var showsSourceUnder = true
    /// A language a click asked for on a piece it is opening (the running
    /// round's indicator): taken by the next open-piece change.
    var pending: String?

    /// The languages `docId` can be read in, in the switch's order.
    func languages(for docId: String) -> [String] {
        ReadingLanguage.ordered(languagesByDocId[docId] ?? [])
    }

    func adopt(_ listing: [String: Set<String>]) {
        if languagesByDocId != listing { languagesByDocId = listing }
        hasRead = true
    }
}
