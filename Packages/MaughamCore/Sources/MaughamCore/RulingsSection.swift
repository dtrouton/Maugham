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
/// **A heading is only a boundary once something is itemized under it**
/// (whole-branch review C1). A blank-delimited heading with zero parseable
/// items is left in the essay verbatim, and so is everything below it. The
/// reason is not tidiness: the Intent pane binds `StatementEssay.half` — the
/// prefix this parser calls the essay — so anything this function moves out of
/// the essay leaves the writer's editor. A heading-only section therefore used
/// to yank the heading out from under the caret on the keystroke that finished
/// it, clear the pane's typing undo stack (`applyExternalText`'s
/// `!preserveUndoStack` branch) and show **no** stratum in its place, because
/// the stratum mounts only when a ruling exists — and prose under that hidden
/// heading was deleted by the next verb's parse/render convergence. Requiring
/// an item makes the empty-section state unrepresentable instead of guarded.
/// `render`'s no-rulings arm has always agreed with this reading: it emits no
/// heading for zero rulings, so no file this code writes has one.
///
/// One heading is enough to check: the item scan runs to the end of the
/// document, so if the first blank-delimited heading has no items under it,
/// no later one can either.
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
    /// Rulings section — none blank-delimited (the F-A avoidance) or none with
    /// anything itemized under it (C1) — means the whole string is essay and
    /// `rulings` is empty.
    public static func parse(_ markdown: String) -> (essay: String, rulings: [Ruling]) {
        let lines = markdown.components(separatedBy: "\n")
        guard let headingIndex = findHeadingIndex(in: lines) else {
            return (markdown, [])
        }
        let rulings = items(under: headingIndex, in: lines)
        // A heading with nothing under it is a heading the writer is still
        // typing, or one a paste left behind — not a boundary. See the type
        // doc: everything this function takes out of `essay` leaves the
        // writer's editor.
        guard !rulings.isEmpty else { return (markdown, []) }

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
        return (essay, rulings)
    }

    /// The canonical rendering of `essay` + `rulings`. No rulings means no
    /// section at all — `essay` is returned verbatim, so a document that has
    /// never had a ruling (or has had its last one `removing`'d) stays a
    /// plain essay-only file rather than carrying a dangling empty heading.
    ///
    /// **A heading the writer already typed is ADOPTED rather than duplicated**
    /// (whole-branch review C1). Since a heading-only section is essay, an essay
    /// can now legitimately contain a `## Rulings` line — and appending the
    /// canonical section below it would leave two, of which `parse` reads the
    /// first and the *next* render deletes everything between them. So every
    /// blank-delimited heading is lifted out of the essay before the one
    /// canonical heading is written; the words that were under it stay, above
    /// the section, where the pane's editor shows them.
    public static func render(essay: String, rulings: [Ruling]) -> String {
        guard !rulings.isEmpty else { return essay }
        let prose = essayAdoptingAnyHeadingItCarries(essay)
        var out = prose.isEmpty ? "" : prose + "\n\n"
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
        lines.indices.first { isSectionHeading(at: $0, in: lines) }
    }

    /// Whether `lines[i]` is a blank-delimited `## Rulings` line — the shape
    /// that CAN be a section boundary, asked in one place so `parse`'s search
    /// and `render`'s adoption cannot drift into two spellings of it.
    private static func isSectionHeading(at i: Int, in lines: [String]) -> Bool {
        guard lines[i].trimmingCharacters(in: .whitespaces) == heading else { return false }
        return i == 0 || lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Every parseable list item below `headingIndex`, in file order.
    ///
    /// The scan runs to the end of the document rather than to the next
    /// heading, which is what lets `parse` decide the whole question from the
    /// first blank-delimited heading it finds.
    private static func items(under headingIndex: Int, in lines: [String]) -> [Ruling] {
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
        return rulings
    }

    /// `essay` with every heading it carries lifted out, so `render` can write
    /// exactly one.
    ///
    /// Only the heading LINE goes, together with the blank line that delimited
    /// it — never anything the writer wrote under it. The prose that was below
    /// the heading closes up above the canonical section instead, which is the
    /// difference between adopting a heading and deleting a paragraph.
    ///
    /// **All of them, not just the last.** `parse` takes the FIRST
    /// blank-delimited heading as its boundary, so one left behind higher up
    /// would become the boundary of the section this render is writing, and
    /// everything between the two would fall into the tail and be deleted by
    /// the render after this one.
    ///
    /// Returns `essay` untouched — byte for byte, trailing blank lines and all
    /// — when there is no heading in it, which is every document this code has
    /// ever written.
    private static func essayAdoptingAnyHeadingItCarries(_ essay: String) -> String {
        let lines = essay.components(separatedBy: "\n")
        guard lines.indices.contains(where: { isSectionHeading(at: $0, in: lines) })
        else { return essay }

        var kept: [String] = []
        for i in lines.indices {
            guard isSectionHeading(at: i, in: lines) else {
                kept.append(lines[i])
                continue
            }
            // The blank delimiter goes with the heading it qualified —
            // otherwise removing the heading leaves the paragraph above it and
            // the one below it two blank lines apart.
            if !kept.isEmpty { kept.removeLast() }
        }
        // Only when a heading was actually taken out: the trailing blank lines
        // are what was between it and its (absent) items, and `render` supplies
        // its own separator. Untouched essays keep their bytes, above.
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            kept.removeLast()
        }
        return kept.joined(separator: "\n")
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
