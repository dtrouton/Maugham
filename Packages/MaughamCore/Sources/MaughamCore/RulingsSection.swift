import Foundation

/// A single writer-ruled decision, itemized under a statement's `## Rulings`
/// section: one plain markdown list item per ruling, dated, with provenance.
///
/// `id` is never stored in the file — it is derived at parse time from the
/// line's own text (a stable digest), so hand-editing the file never orphans
/// an id a caller was holding onto: reparse the same text, get the same id
/// back. Two lines with identical text are disambiguated by their position
/// among same-text lines (first occurrence keeps the bare digest; later
/// occurrences get `-<n>` appended) — see `RulingsSection.parse`.
public struct Ruling: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let ruledOn: Date?
    public let provenance: String?

    public init(id: String, text: String, ruledOn: Date?, provenance: String?) {
        self.id = id
        self.text = text
        self.ruledOn = ruledOn
        self.provenance = provenance
    }
}

/// The forgiving parser/renderer for a statement document's Rulings stratum
/// (spec `2026-08-07-compiler-second-draft-design.md` §3.2) — the palette-card
/// pattern (`PaletteCardParser`): derived rendering over writer-editable
/// markdown, one human-readable file, model owns the canonical form.
///
/// A statement document is `essay` (freeform intent prose, untouched) followed
/// optionally by one `## Rulings` section: a plain bulleted list, one ruling
/// per line, each optionally carrying a `— ruled <d MMM yyyy>, <provenance>`
/// suffix. Hand edits are legal — a bare `- Kelly never lies` line parses with
/// nil date/provenance — and the parser never requires the canonical suffix
/// shape to accept a line as a ruling.
///
/// **F-A avoided:** `PaletteCardParser`'s known footgun is that a body line
/// spelling a known section heading is claimed by section detection wherever
/// it appears. This parser only promotes a `## Rulings` line to the real
/// section boundary when it is **blank-delimited** — the start of the
/// document, or immediately preceded by a blank line — and otherwise keeps
/// scanning; an unqualified match (e.g. mid-paragraph, no blank line before
/// it) is left as ordinary essay prose.
///
/// **Byte fidelity:** for a document with no Rulings section, `essay` is the
/// entire input verbatim and `render(parse(x)) == x` trivially. For a
/// document this code wrote (via `appending`), the same holds exactly — the
/// single structural blank line the renderer places around the heading is
/// the one line `parse` strips back off `essay`, so nothing is lost or
/// gained. For a hand-edited file, round-tripping through `parse`/`render`
/// normalizes formatting (list-item spacing, item ordering of the suffix)
/// but **converges**: a second `parse`/`render` pass is idempotent, per the
/// palette convergence rule.
public enum RulingsSection {

    public static let heading = "## Rulings"

    /// Splits `markdown` into the untouched essay and the parsed rulings. No
    /// Rulings section (or none blank-delimited, per the F-A avoidance above)
    /// means the whole string is essay and `rulings` is empty.
    public static func parse(_ markdown: String) -> (essay: String, rulings: [Ruling]) {
        let lines = markdown.components(separatedBy: "\n")
        guard let headingIndex = findHeadingIndex(in: lines) else {
            return (markdown, [])
        }

        let essay: String
        if headingIndex == 0 {
            essay = ""
        } else {
            // The single blank line immediately before the heading is the
            // structural delimiter that qualified this as a real heading
            // (see `findHeadingIndex`) — strip exactly that one line back
            // off; any further leading blank lines the writer typed stay in
            // `essay` verbatim.
            essay = lines[0..<(headingIndex - 1)].joined(separator: "\n")
        }

        var rulings: [Ruling] = []
        var seenTextCounts: [String: Int] = [:]
        for raw in lines[(headingIndex + 1)...] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }
            let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }

            let (text, ruledOn, provenance) = parseItem(item)
            let count = seenTextCounts[text, default: 0]
            let digest = StableHash.fnv1a64Hex(text)
            let id = count == 0 ? digest : "\(digest)-\(count)"
            seenTextCounts[text] = count + 1

            rulings.append(Ruling(id: id, text: text, ruledOn: ruledOn, provenance: provenance))
        }
        return (essay, rulings)
    }

    /// The canonical rendering of `essay` + `rulings`. No rulings means no
    /// section at all — `essay` is returned verbatim, so a document that has
    /// never had a ruling (or has had its last one `removing`'d) stays a
    /// plain essay-only file rather than carrying a dangling empty heading.
    public static func render(essay: String, rulings: [Ruling]) -> String {
        guard !rulings.isEmpty else { return essay }
        var out = essay.isEmpty ? "" : essay + "\n\n"
        out += heading + "\n\n"
        for ruling in rulings {
            out += "- " + lineText(for: ruling) + "\n"
        }
        return out
    }

    /// Appends one new ruling, creating the blank-delimited section first if
    /// `markdown` doesn't have one yet. The essay is untouched either way.
    public static func appending(
        _ ruling: String, provenance: String, on date: Date, to markdown: String
    ) -> String {
        let (essay, rulings) = parse(markdown)
        // `id` is never read by `render` — only `parse` derives ids, from a
        // ruling's position and text in the file — so any placeholder here
        // is fine; the real id appears the next time this markdown is parsed.
        let newRuling = Ruling(id: "", text: ruling, ruledOn: date, provenance: provenance)
        return render(essay: essay, rulings: rulings + [newRuling])
    }

    /// Deletes exactly the one ruling whose derived id is `rulingId`. An
    /// unknown id is a no-op that returns `markdown` byte-for-byte unchanged
    /// — checked before any parse/render round trip runs, so a document this
    /// code never wrote is never silently reformatted by a miss.
    public static func removing(rulingId: String, from markdown: String) -> String {
        let (essay, rulings) = parse(markdown)
        guard rulings.contains(where: { $0.id == rulingId }) else { return markdown }
        let remaining = rulings.filter { $0.id != rulingId }
        return render(essay: essay, rulings: remaining)
    }

    // MARK: - Section detection

    /// The index of the first `## Rulings` line that is blank-delimited —
    /// the start of the document, or immediately preceded by a blank line.
    /// An unqualified match (spelled mid-paragraph) is skipped, not treated
    /// as the boundary — the F-A avoidance.
    private static func findHeadingIndex(in lines: [String]) -> Int? {
        for (i, raw) in lines.enumerated() {
            guard raw.trimmingCharacters(in: .whitespaces) == heading else { continue }
            if i == 0 || lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                return i
            }
        }
        return nil
    }

    // MARK: - Item line

    /// Splits an item's text on its right-most em-dash: `text — ruled <d MMM
    /// yyyy>, <provenance>`. Tolerant of hand edits — any em-dash suffix
    /// parses; a date is extracted only when the suffix actually starts with
    /// `ruled ` and the segment before the first comma parses as a date,
    /// else `ruledOn` is nil and the whole suffix (verbatim) is `provenance`.
    /// No em-dash at all means a bare hand-written line: text only, both nil.
    private static func parseItem(_ item: String) -> (text: String, ruledOn: Date?, provenance: String?) {
        guard let dashRange = item.range(of: "—", options: .backwards) else {
            return (item, nil, nil)
        }
        let text = item[..<dashRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let suffix = item[dashRange.upperBound...].trimmingCharacters(in: .whitespaces)

        let ruledPrefix = "ruled "
        if suffix.lowercased().hasPrefix(ruledPrefix), let comma = suffix.firstIndex(of: ",") {
            let dateStart = suffix.index(suffix.startIndex, offsetBy: ruledPrefix.count)
            let dateStr = suffix[dateStart..<comma].trimmingCharacters(in: .whitespaces)
            let provenanceStr = suffix[suffix.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if let date = dateFormatter.date(from: dateStr) {
                return (text, date, provenanceStr)
            }
        }
        return (text, nil, String(suffix))
    }

    /// The canonical line text for a ruling, inverse of `parseItem`.
    private static func lineText(for ruling: Ruling) -> String {
        switch (ruling.ruledOn, ruling.provenance) {
        case let (.some(date), .some(provenance)):
            return "\(ruling.text) — ruled \(formatted(date)), \(provenance)"
        case let (.some(date), .none):
            return "\(ruling.text) — ruled \(formatted(date))"
        case let (.none, .some(provenance)):
            return "\(ruling.text) — \(provenance)"
        case (.none, .none):
            return ruling.text
        }
    }

    // MARK: - Date formatting

    /// `d MMM yyyy` (e.g. "7 Aug 2026"), fixed to `en_US_POSIX`/UTC so
    /// formatting and parsing are stable regardless of the running device's
    /// locale or timezone.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    private static func formatted(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
