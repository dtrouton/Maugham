import Foundation

/// The project's citable sources, read from the research tree. Trashed items
/// are the caller's concern: publishing passes only live items.
public struct CitationLibrary: Sendable {
    public struct Entry: Sendable, Equatable {
        public let info: CitationInfo
        public let itemTitle: String
        public let url: String?
    }

    private let entries: [String: Entry]

    /// Walks children too; the first entry wins for a duplicate key.
    public init(items: [ResearchItem]) {
        var found: [String: Entry] = [:]
        func walk(_ items: [ResearchItem]) {
            for item in items {
                if let info = item.citation, found[info.key] == nil {
                    found[info.key] = Entry(info: info, itemTitle: item.title, url: item.url)
                }
                if let kids = item.children { walk(kids) }
            }
        }
        walk(items)
        entries = found
    }

    public func entry(for key: String) -> Entry? { entries[key] }
    public var keys: Set<String> { Set(entries.keys) }
}

/// Author–date citations (R-P2-4) and the References order (R-P2-5).
public enum CitationStyle {
    public struct Run: Sendable, Equatable {
        public let text: String
        public let italic: Bool
        public init(text: String, italic: Bool) { self.text = text; self.italic = italic }
    }

    /// "(Smith 2026, p. 12; Lee and Wu n.d.)". `labels` comes from
    /// `disambiguated(_:)`; nil when any key is unknown or `items` is empty.
    public static func inText(_ items: [CitationItem], labels: [String: String]) -> String? {
        guard !items.isEmpty else { return nil }
        var parts: [String] = []
        for item in items {
            guard let label = labels[item.key] else { return nil }
            if let locator = item.locator, !locator.isEmpty {
                parts.append("\(label), \(locator)")
            } else {
                parts.append(label)
            }
        }
        return "(" + parts.joined(separator: "; ") + ")"
    }

    /// Cited entries in References order, each with its in-text label.
    public static func disambiguated(
        _ cited: [CitationLibrary.Entry]
    ) -> [(entry: CitationLibrary.Entry, label: String)] {
        let sorted = cited.sorted { a, b in
            let (na, nb) = (name(a), name(b))
            if let order = order(na, nb) { return order }
            let (ya, yb) = (a.info.year ?? Int.max, b.info.year ?? Int.max)
            if ya != yb { return ya < yb }
            if let t = order(a.itemTitle, b.itemTitle) { return t }
            return a.info.key < b.info.key
        }
        func base(_ e: CitationLibrary.Entry) -> String {
            name(e) + " " + (e.info.year.map(String.init) ?? "n.d.")
        }
        func folded(_ e: CitationLibrary.Entry) -> String {
            base(e).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        var counts: [String: Int] = [:]
        for e in sorted { counts[folded(e), default: 0] += 1 }
        var seen: [String: Int] = [:]
        return sorted.map { e in
            let b = base(e), f = folded(e)
            guard counts[f]! > 1 else { return (e, b) }
            let n = seen[f, default: 0]
            seen[f] = n + 1
            // "2026a", but "n.d.-a": a letter straight after "n." reads as
            // part of the abbreviation (Chicago's form).
            return (e, b + (e.info.year == nil ? "-" : "") + letters(n))
        }
    }

    /// "Author(s). Year. *Title*. Publisher. URL (accessed 3 March 2026)."
    /// Omitted parts drop with their punctuation. The year is the label's own
    /// (`disambiguated`'s), letter and all — "2026a.", "n.d.-a." — so an
    /// in-text "(Smith 2026a)" finds its entry.
    public static func referenceEntry(_ entry: CitationLibrary.Entry, label: String) -> [Run] {
        let info = entry.info
        var runs: [Run] = []
        func sentence(_ text: String) {
            if !runs.isEmpty { runs.append(Run(text: " ", italic: false)) }
            runs.append(Run(text: text, italic: false))
        }
        let authors = info.authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !authors.isEmpty { sentence(ensurePeriod(authors.joined(separator: "; "))) }
        sentence(ensurePeriod(yearPart(of: label, entry: entry)))
        if !runs.isEmpty { runs.append(Run(text: " ", italic: false)) }
        runs.append(Run(text: titleText(entry), italic: true))
        runs.append(Run(text: ".", italic: false))
        if let publisher = info.publisher, !publisher.isEmpty { sentence(ensurePeriod(publisher)) }
        var tail: [String] = []
        if let url = entry.url, !url.isEmpty { tail.append(url) }
        if let accessed = info.accessed { tail.append("(accessed \(format(accessed)))") }
        if !tail.isEmpty { sentence(tail.joined(separator: " ") + ".") }
        return runs
    }

    // MARK: - Private

    /// The label after its name: "2026a" from "Smith 2026a". A label that is
    /// not this entry's (never, from `disambiguated`) falls back to the year.
    private static func yearPart(of label: String, entry: CitationLibrary.Entry) -> String {
        let head = name(entry) + " "
        if label.hasPrefix(head), label.count > head.count {
            return String(label.dropFirst(head.count))
        }
        return entry.info.year.map(String.init) ?? "n.d."
    }

    private static func titleText(_ e: CitationLibrary.Entry) -> String {
        if let t = e.info.sourceTitle, !t.isEmpty { return t }
        return e.itemTitle
    }

    private static func name(_ e: CitationLibrary.Entry) -> String {
        let authors = e.info.authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map(surname)
        switch authors.count {
        case 0: return titleText(e)
        case 1: return authors[0]
        case 2: return "\(authors[0]) and \(authors[1])"
        default: return "\(authors[0]) et al."
        }
    }

    private static func surname(_ author: String) -> String {
        guard let comma = author.firstIndex(of: ",") else { return author }
        let head = author[..<comma].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? author : head
    }

    /// nil when equal.
    private static func order(_ a: String, _ b: String) -> Bool? {
        switch a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return nil
        }
    }

    private static func ensurePeriod(_ s: String) -> String {
        s.hasSuffix(".") ? s : s + "."
    }

    /// 0 → a, 25 → z, 26 → aa.
    private static func letters(_ index: Int) -> String {
        var n = index + 1, out = ""
        while n > 0 {
            n -= 1
            out = String(UnicodeScalar(UInt8(97 + n % 26))) + out
            n /= 26
        }
        return out
    }

    private static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: date)
    }
}
