import Foundation
import MaughamCore

/// The languages a compile renders, in order — the one place the legacy
/// `language`, the new `languages` list and the "source" sentinel are
/// reconciled.
public struct LanguageSet: Equatable, Sendable {

    /// A `language`/`languages` combination that cannot resolve to a body
    /// list: the two disagree, a tag repeats after the `"source"`/`sourceTag`
    /// substitution, or a tag fails `TranslationRecord.isValidLanguageTag`.
    public struct Invalid: Error, LocalizedError, Equatable {
        public let message: String

        public var errorDescription: String? { message }
    }

    /// Ordered body tags; the source body is `nil`. Never empty.
    public let bodies: [String?]
    /// `metadata.language` — how the source is spelled in a joined identity.
    public let sourceTag: String

    /// - `language` (legacy) and `languages` both nil/empty → `[nil]`.
    /// - both given → must agree (`languages == [language]`) else Invalid.
    /// - "source" in the list → nil body; a tag equal to `sourceTag` → nil body.
    /// - duplicates (after that mapping) → Invalid; a tag failing
    ///   `TranslationRecord.isValidLanguageTag` → Invalid.
    public init(language: String?, languages: [String]?, sourceTag: String) throws {
        self.sourceTag = sourceTag

        func substitute(_ tag: String) -> String? {
            (tag == "source" || tag == sourceTag) ? nil : tag
        }

        let hasLanguage = !(language ?? "").isEmpty
        let hasLanguages = !(languages ?? []).isEmpty

        guard hasLanguage || hasLanguages else {
            self.bodies = [nil]
            return
        }

        let mapped: [String?]
        if hasLanguage, hasLanguages {
            let fromLanguage = [substitute(language!)]
            let fromLanguages = languages!.map(substitute)
            guard fromLanguage == fromLanguages else {
                let listDisplay = "[" + languages!.joined(separator: ", ") + "]"
                throw Invalid(message:
                    "language '\(language!)' and languages \(listDisplay) disagree")
            }
            mapped = fromLanguages
        } else if hasLanguages {
            mapped = languages!.map(substitute)
        } else {
            mapped = [substitute(language!)]
        }

        var seen = Set<String?>()
        for tag in mapped {
            guard seen.insert(tag).inserted else {
                throw Invalid(message: "duplicate language '\(tag ?? sourceTag)'")
            }
        }

        for tag in mapped {
            guard let tag else { continue }
            guard TranslationRecord.isValidLanguageTag(tag) else {
                throw Invalid(message: "invalid language tag '\(tag)'")
            }
        }

        self.bodies = mapped
    }

    /// Whether one of the rendered bodies is the source (untranslated) body.
    public var isSourceCompile: Bool { bodies.contains(nil) }
    /// Non-nil bodies, in order.
    public var translatedTags: [String] { bodies.compactMap { $0 } }
    /// nil for `[nil]`; the tag for a single translated body; else the
    /// `+`-joined list in order with nil spelled as sourceTag.
    public var identity: String? {
        guard bodies.count > 1 else { return bodies[0] }
        return bodies.map { $0 ?? sourceTag }.joined(separator: "+")
    }
    /// The tag `LanguageSuffixedFile.resolve` should see for the template and
    /// for single-body filename/metadata decisions: the sole translated tag
    /// when `bodies.count == 1`, else nil.
    public var singleTag: String? {
        bodies.count == 1 ? bodies[0] : nil
    }
}
