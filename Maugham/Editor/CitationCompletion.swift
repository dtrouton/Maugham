import Foundation
import MaughamCore

/// **The citation picker** (report foundations plan 3b Task 3, rulings R-3b-5
/// and R-3b-6): a `CompletionSource` over the window's cached
/// `ReferenceIndex.sources`.
///
/// - **Trigger.** `[@` (or `[-@`) opens it; `;` inside an open citation
///   bracket reopens it for the next key, and the space and `@` after the `;`
///   keep it open. The query is the key characters before the caret, any
///   letter included, so "Mü" can find Müller.
/// - **What an accept writes** (`insertion(for:trigger:)`):
///   - a fresh `[@` whose bracket is not closed: `key]`;
///   - inside a closed bracket: the key only, replacing the whole key the
///     caret sat in, so a locator after it (`, p. 12`) survives a re-pick;
///   - after a `;`: ` @key`, from just after the `;`.
/// - **Filter.** Key, label ("Smith 2026"), authors and title, each by prefix
///   or word prefix, ignoring case and accents. An exact key ranks first, then
///   a key or label prefix, then the rest, each in the index's order.
///
/// The trigger reads only the caret's line; the rows read the cached index,
/// so nothing walks the project per keystroke (the plan's review focus 1).
@MainActor
final class CitationCompletion: CompletionSource {
    /// Which opening the trigger is, and so what an accept writes.
    enum Context: Hashable {
        /// After `[@`. `closed`: a `]` already ends the bracket on the line.
        case fresh(closed: Bool)
        /// After a `;` inside a citation bracket.
        case continuation
    }

    /// R-3b-6's empty result, with the citation version's pointer.
    static let emptyResultMessage = "No matching sources — add citation details in the research inspector"

    let emptyMessage = CitationCompletion.emptyResultMessage
    let actionName = "Insert Citation"

    private let index: () -> ReferenceIndex
    /// The folded fields of the last index read, by version (an index with
    /// version 0 is a fresh build no host published, never cached).
    private var folded: (version: Int, sources: [Folded])?

    /// `index` returns the window's cached index (`EditorCoordinator.referenceIndex`).
    init(index: @escaping () -> ReferenceIndex) {
        self.index = index
    }

    func trigger(in text: NSString, caret: Int) -> CompletionTrigger? {
        Self.locate(in: text, caret: caret)
    }

    func items(for trigger: CompletionTrigger) -> [CompletionItem] {
        let current = index()
        let sources: [Folded]
        if let folded, folded.version == current.version, current.version != 0 {
            sources = folded.sources
        } else {
            sources = current.sources.map(Folded.init)
            folded = (current.version, sources)
        }
        return Self.matching(sources, query: trigger.query).map(Self.row(for:))
    }

    func insertion(for item: CompletionItem, trigger: CompletionTrigger) -> String {
        switch trigger.context as? Context {
        case .fresh(closed: false)?: return item.insertion + "]"
        case .continuation?: return " @" + item.insertion
        default: return item.insertion
        }
    }

    /// A row: "Author Year — Title", the key muted beside it (R-3b-6). An
    /// accept writes the key, shaped by the trigger.
    nonisolated static func row(for source: ReferenceIndex.Source) -> CompletionItem {
        CompletionItem(title: source.title.isEmpty ? source.label : "\(source.label) — \(source.title)",
                       subtitle: source.key, insertion: source.key)
    }

    // MARK: - The filter

    /// A source with its fields folded once (case and accents dropped).
    struct Folded: Sendable {
        let source: ReferenceIndex.Source
        let key: String
        let label: String
        let others: [String]

        init(_ source: ReferenceIndex.Source) {
            self.source = source
            key = CompletionMatch.fold(source.key)
            label = CompletionMatch.fold(source.label)
            others = [CompletionMatch.fold(source.authorsLine), CompletionMatch.fold(source.title)]
        }
    }

    /// The sources `query` matches, best first: an exact key, then a key or
    /// label prefix, then a word prefix anywhere in the key, label, authors or
    /// title; each tier in the index's order. An empty query keeps them all.
    nonisolated static func matching(_ sources: [ReferenceIndex.Source],
                                     query: String) -> [ReferenceIndex.Source] {
        matching(sources.map(Folded.init), query: query)
    }

    nonisolated static func matching(_ sources: [Folded], query: String) -> [ReferenceIndex.Source] {
        let q = CompletionMatch.fold(query)
        guard !q.isEmpty else { return sources.map(\.source) }
        var tiers: [[ReferenceIndex.Source]] = [[], [], []]
        for s in sources {
            if s.key == q {
                tiers[0].append(s.source)
            } else if s.key.hasPrefix(q) || s.label.hasPrefix(q) {
                tiers[1].append(s.source)
            } else if ([s.key, s.label] + s.others).contains(where: { CompletionMatch.matches($0, q) }) {
                tiers[2].append(s.source)
            }
        }
        return tiers.flatMap { $0 }
    }

    // MARK: - The trigger

    /// The citation completion at `caret`, or nil (R-3b-5). Reads the caret's
    /// line only. Code spans and fences are the coordinator's to refuse.
    nonisolated static func locate(in text: NSString, caret: Int) -> CompletionTrigger? {
        guard caret >= 0, caret <= text.length else { return nil }
        var queryStart = caret
        while queryStart > 0, CompletionMatch.isQueryUnit(text.character(at: queryStart - 1)) {
            queryStart -= 1
        }
        let query = text.substring(with: NSRange(location: queryStart, length: caret - queryStart))
        let keyEnd: (Bool) -> Int = { closed in
            // Through the rest of a key the caret sits in, only when a `]`
            // closes the bracket: an unclosed `[@` typed before a word must
            // never claim the word.
            guard closed else { return caret }
            var end = caret
            while end < text.length, CompletionMatch.isQueryUnit(text.character(at: end)) { end += 1 }
            return end
        }

        if queryStart > 0, text.character(at: queryStart - 1) == PickerUnit.at {
            let at = queryStart - 1
            // A fresh `[@` or `[-@`.
            var open = at - 1
            if open >= 0, text.character(at: open) == PickerUnit.minus { open -= 1 }
            if open >= 0, text.character(at: open) == PickerUnit.openBracket {
                guard isCitationBracketOpening(text, open) else { return nil }
                let closed = isClosed(text, after: caret)
                let end = keyEnd(closed)
                return CompletionTrigger(
                    replaceRange: NSRange(location: queryStart, length: end - queryStart),
                    query: query, context: Context.fresh(closed: closed))
            }
            // `; @key` inside a citation bracket.
            guard let semicolon = semicolonBefore(text, at),
                  isInsideCitationBracket(text, semicolon) else { return nil }
            let end = keyEnd(isClosed(text, after: caret))
            return CompletionTrigger(
                replaceRange: NSRange(location: semicolon + 1, length: end - semicolon - 1),
                query: query, context: Context.continuation)
        }

        // Just after the `;` (and its spaces), before the `@`.
        guard query.isEmpty, let semicolon = semicolonBefore(text, caret),
              isInsideCitationBracket(text, semicolon) else { return nil }
        return CompletionTrigger(
            replaceRange: NSRange(location: semicolon + 1, length: caret - semicolon - 1),
            query: "", context: Context.continuation)
    }

    /// The `;` before `location` with only spaces or tabs between, or nil.
    private nonisolated static func semicolonBefore(_ text: NSString, _ location: Int) -> Int? {
        var i = location - 1
        while i >= 0, text.character(at: i) == PickerUnit.space
                || text.character(at: i) == PickerUnit.tab { i -= 1 }
        return i >= 0 && text.character(at: i) == PickerUnit.semicolon ? i : nil
    }

    /// A `[` that may open a citation: not escaped, not a wiki link's second
    /// `[`, not an image's `![`.
    private nonisolated static func isCitationBracketOpening(_ text: NSString, _ open: Int) -> Bool {
        guard open > 0 else { return true }
        let before = text.character(at: open - 1)
        return before != PickerUnit.backslash && before != PickerUnit.openBracket && before != PickerUnit.bang
    }

    /// Whether `location` (a `;`) sits inside a bracket that is a citation:
    /// the nearest `[` before it on the line, with no `]` between, opens a
    /// citation and holds an `@key` before the `;`.
    private nonisolated static func isInsideCitationBracket(_ text: NSString, _ location: Int) -> Bool {
        var i = location - 1
        while i >= 0 {
            let c = text.character(at: i)
            if c == PickerUnit.newline || c == PickerUnit.closeBracket { return false }
            if c == PickerUnit.openBracket { break }
            i -= 1
        }
        guard i >= 0, isCitationBracketOpening(text, i) else { return false }
        // An `@` at an item's start, followed by a key character.
        var j = i + 1
        while j < location {
            if text.character(at: j) == PickerUnit.at, j + 1 < location,
               CompletionMatch.isQueryUnit(text.character(at: j + 1)) {
                let before = text.character(at: j - 1)
                if [PickerUnit.openBracket, PickerUnit.minus, PickerUnit.space, PickerUnit.tab,
                    PickerUnit.semicolon].contains(before) { return true }
            }
            j += 1
        }
        return false
    }

    /// Whether a `]` closes the bracket after `location` on its line, before
    /// any other `[`.
    private nonisolated static func isClosed(_ text: NSString, after location: Int) -> Bool {
        var i = location
        while i < text.length {
            let c = text.character(at: i)
            if c == PickerUnit.closeBracket { return true }
            if c == PickerUnit.newline || c == PickerUnit.openBracket { return false }
            i += 1
        }
        return false
    }
}

/// The matching and character rules the reference pickers share (plan 3b
/// Tasks 3 and 4).
enum CompletionMatch {
    /// `s` with case and accents dropped.
    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whether folded `field` starts with folded `query`, or one of its words
    /// (runs of letters and digits) does. Never a match inside a word.
    nonisolated static func matches(_ field: String, _ query: String) -> Bool {
        if field.hasPrefix(query) { return true }
        return field.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { $0.hasPrefix(query) }
    }

    /// A character a query may hold: any letter, a digit, `_` or `-` (a
    /// key's characters, plus the letters a name is searched by).
    nonisolated static func isQueryUnit(_ unit: unichar) -> Bool {
        if unit == PickerUnit.underscore || unit == PickerUnit.minus { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }
}

/// The UTF-16 units the pickers' triggers read.
enum PickerUnit {
    static let at = unichar(UInt8(ascii: "@"))
    static let openBracket = unichar(UInt8(ascii: "["))
    static let closeBracket = unichar(UInt8(ascii: "]"))
    static let semicolon = unichar(UInt8(ascii: ";"))
    static let colon = unichar(UInt8(ascii: ":"))
    static let minus = unichar(UInt8(ascii: "-"))
    static let underscore = unichar(UInt8(ascii: "_"))
    static let backslash = unichar(UInt8(ascii: "\\"))
    static let bang = unichar(UInt8(ascii: "!"))
    static let openParen = unichar(UInt8(ascii: "("))
    static let space = unichar(UInt8(ascii: " "))
    static let tab = unichar(UInt8(ascii: "\t"))
    static let newline = unichar(UInt8(ascii: "\n"))
}
