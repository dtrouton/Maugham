import Foundation

/// Citation details a research item may carry so manuscripts can cite it
/// with `[@key]`. The source URL stays `ResearchItem.url`.
public struct CitationInfo: Codable, Equatable, Sendable {
    public var key: String
    public var authors: [String]
    public var sourceTitle: String?
    public var publisher: String?
    public var year: Int?
    public var accessed: Date?
    public var pages: String?

    public init(
        key: String,
        authors: [String] = [],
        sourceTitle: String? = nil,
        publisher: String? = nil,
        year: Int? = nil,
        accessed: Date? = nil,
        pages: String? = nil
    ) {
        self.key = key
        self.authors = authors
        self.sourceTitle = sourceTitle
        self.publisher = publisher
        self.year = year
        self.accessed = accessed
        self.pages = pages
    }
}

public enum CitationKey {
    /// `[A-Za-z0-9][A-Za-z0-9_-]*`: the label-name rule, not spelled twice.
    public static func isValid(_ key: String) -> Bool {
        ManuscriptLabel.isValidName(key)
    }

    /// A free key: surname (or a title word) folded to ASCII, plus the year,
    /// with `a`, `b`, … `z`, `aa` … appended until it is not in `existing`.
    public static func suggest(authors: [String], year: Int?, title: String, existing: Set<String>) -> String {
        var raw: String?
        if let author = authors.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            raw = author.split(whereSeparator: \.isWhitespace).last.map(String.init)
        } else {
            raw = title.split(whereSeparator: { !$0.isLetter }).map(String.init).first { $0.count > 3 }
        }
        var stem = fold(raw ?? "")
        if stem.isEmpty { stem = "source" }
        let base = stem + (year.map(String.init) ?? "")
        if !existing.contains(base) { return base }
        var n = 1
        while true {
            let candidate = base + suffix(n)
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// 1 → a, 26 → z, 27 → aa, 28 → ab …
    private static func suffix(_ n: Int) -> String {
        var n = n, out = ""
        while n > 0 {
            n -= 1
            out = String(UnicodeScalar(UInt8(97 + n % 26))) + out
            n /= 26
        }
        return out
    }

    private static func fold(_ s: String) -> String {
        let latin = s.applyingTransform(.toLatin, reverse: false) ?? s
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return String(plain.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0)
        }.map(Character.init))
    }
}

extension Array where Element == ResearchItem {
    /// Every citation key in the tree, recursively (groups included).
    public var citationKeys: Set<String> {
        var keys = Set<String>()
        for item in self {
            if let key = item.citation?.key { keys.insert(key) }
            if let kids = item.children { keys.formUnion(kids.citationKeys) }
        }
        return keys
    }
}

extension ResearchItem {
    /// A copy whose citations (this item's and every descendant's) carry
    /// fresh keys, each suggested against `existing` plus the keys assigned so
    /// far in this copy. Every other citation field is kept.
    public func rekeyingCitations(existing: Set<String>) -> ResearchItem {
        var taken = existing
        return rekeyed(taken: &taken)
    }

    /// A copy in which only the citations whose key is in `existing`, or
    /// repeats an earlier key in this copy, get fresh keys; every other key is
    /// kept. A fresh key avoids `existing` and every key in this copy.
    public func rekeyingCollidingCitations(existing: Set<String>) -> ResearchItem {
        var taken = existing.union([self].citationKeys)
        var kept = Set<String>()
        return rekeyedIfColliding(existing: existing, taken: &taken, kept: &kept)
    }

    private func rekeyedIfColliding(
        existing: Set<String>, taken: inout Set<String>, kept: inout Set<String>
    ) -> ResearchItem {
        var copy = self
        if var info = copy.citation {
            if existing.contains(info.key) || kept.contains(info.key) {
                info.key = CitationKey.suggest(
                    authors: info.authors, year: info.year, title: info.sourceTitle ?? title, existing: taken)
                taken.insert(info.key)
                copy.citation = info
            } else {
                kept.insert(info.key)
            }
        }
        copy.children = children?.map {
            $0.rekeyedIfColliding(existing: existing, taken: &taken, kept: &kept)
        }
        return copy
    }

    private func rekeyed(taken: inout Set<String>) -> ResearchItem {
        var copy = self
        if var info = copy.citation {
            info.key = CitationKey.suggest(
                authors: info.authors, year: info.year, title: info.sourceTitle ?? title, existing: taken)
            taken.insert(info.key)
            copy.citation = info
        }
        copy.children = children?.map { $0.rekeyed(taken: &taken) }
        return copy
    }
}
