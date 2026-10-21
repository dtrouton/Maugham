import Foundation
import MaughamCore

/// **A Word export is a draft, not a version** (report plan 4, R-4-1).
///
/// A `.docx` compile never reads or moves `next_version`. It takes the draft
/// number `SentCopyStore.drafts(book:).count + 1` (skipping a number a sent
/// copy or a catalog row already holds), and its `Publication.version` is
/// `draft-N`, so the four-part identity `(imprint, version, language, format)`
/// stays unique. The filename spells it `{title}-draft{N}.docx`; the file's
/// custom properties and its sent copy carry the export label, "Draft N, sent
/// <date>", in the book's language.
///
/// This type is the one spelling of the `draft-N` version, its filename
/// token, the label and the custom properties.
public enum WordDraft {

    // MARK: the version

    private static let prefix = "draft-"

    /// The `Publication.version` a Word export mints.
    static func version(_ draft: Int) -> String { prefix + String(draft) }

    /// The draft a version names: `draft-3` → 3, and a republish of it,
    /// `draft-3-r1a2b3c4d`, → 3 too (the same draft, re-rendered). Nil for a
    /// book version (`0.1`) or anything else.
    static func number(ofVersion version: String) -> Int? {
        guard version.hasPrefix(prefix) else { return nil }
        let digits = version.dropFirst(prefix.count).prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = version.dropFirst(prefix.count + digits.count)
        guard rest.isEmpty || rest.hasPrefix("-") else { return nil }
        return Int(digits)
    }

    /// True for an original draft's version (`draft-3`), false for its
    /// republish (`draft-3-r…`) and for a book version.
    static func isOriginalDraft(_ version: String) -> Bool {
        number(ofVersion: version).map { version == self.version($0) } ?? false
    }

    /// How a surface names a draft version: `draft-3` → "Draft 3", its
    /// republish `draft-3-r1a2b3c4d` → "Draft 3-r1a2b3c4d". Nil for a book
    /// version, which is named "v0.1" as it always has been.
    static func displayName(ofVersion version: String) -> String? {
        guard let draft = number(ofVersion: version) else { return nil }
        return "Draft \(draft)" + version.dropFirst(prefix.count + String(draft).count)
    }

    /// How a draft version is spelled in a filename: `draft-3` → `draft3`,
    /// `draft-3-r1a2b3c4d` → `draft3-r1a2b3c4d`. Nil for a book version, which
    /// the filename spells as it always has.
    static func filenameToken(forVersion version: String) -> String? {
        guard let draft = number(ofVersion: version) else { return nil }
        let rest = version.dropFirst(prefix.count + String(draft).count)
        return "draft\(draft)" + rest
    }

    /// Where a book's drafts are counted and kept: the imprint's name, or
    /// `book` for what no imprint compiled (the catalogue's own sentinel).
    static func book(imprint: String?) -> String { imprint ?? "book" }

    /// The draft a new export takes: the count of the book's sent copies plus
    /// one, moved past any number already held — by a sent copy this device
    /// can read, or by a catalog row — so a lost sent copy or a gap never
    /// hands out a number twice.
    static func next(sentCopies count: Int, taken: Set<Int>) -> Int {
        var draft = count + 1
        while taken.contains(draft) { draft += 1 }
        return draft
    }

    // MARK: the label

    /// "Draft N, sent <date>" — the words and the date in the book's
    /// language.
    public struct Label: Equatable, Sendable {
        public let draft: Int
        public let sentAt: Date
        /// `WordDraft.book(imprint:)`.
        public let book: String

        public init(draft: Int, sentAt: Date, book: String) {
            self.draft = draft
            self.sentAt = sentAt
            self.book = book
        }

        /// The label's text for a body's folded metadata: `ElementWords`'
        /// draft and sent words, and the export's UTC date in the language's
        /// long style.
        func text(metadata: PublishConfig.Metadata) -> String {
            let words = ElementWords.forBody(metadata)
            return "\(words.draft) \(draft), \(words.sent) "
                + WordDraft.date(sentAt, language: metadata.language)
        }

        /// The file's custom properties (`docProps/custom.xml`).
        func customProperties(metadata: PublishConfig.Metadata) -> [DOCXPackage.CustomProperty] {
            [.init(name: "MaughamExportLabel", value: text(metadata: metadata)),
             .init(name: "MaughamDraft", integer: draft),
             .init(name: "MaughamBook", value: book)]
        }
    }

    /// `date`'s UTC day in `language`'s long date style. A tag Foundation
    /// cannot place falls back to `en_US_POSIX`; Serbian without a script is
    /// written in Latin script, as `ElementWords` writes it.
    static func date(_ date: Date, language: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale(for: language)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func locale(for language: String) -> Locale {
        let tag = language.replacingOccurrences(of: "_", with: "-")
        let subtags = tag.lowercased().split(separator: "-")
        guard let primary = subtags.first, !primary.isEmpty,
              Locale.LanguageCode(String(primary)).isISOLanguage else {
            return Locale(identifier: "en_US_POSIX")
        }
        let hasScript = subtags.dropFirst().contains { $0.count == 4 && $0.allSatisfy(\.isLetter) }
        if primary == "sr" && !hasScript {
            return Locale(identifier: (["sr-Latn"] + tag.split(separator: "-").dropFirst().map(String.init))
                .joined(separator: "-"))
        }
        return Locale(identifier: tag)
    }
}
