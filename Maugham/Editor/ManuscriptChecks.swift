import AppKit
import MaughamCore

/// **The editor's per-document reference checks** (report foundations plan 3b
/// Task 6, R-3b-4): an unknown citation key, a cross-reference to nothing, a
/// label defined here and again (here or elsewhere), a footnote that is
/// missing, defined twice or never used, and a figure line whose path or label
/// is wrong (report plan 7b Task 7). Each is a `PublishProblem.Kind`, so
/// its severity is publishing's one table (`PublishProblem.isError(_:profile:)`)
/// and its sentence publishing's (`PublishProblem.sentence(for:)`): the editor
/// and the publishing desk say the same thing.
///
/// Pure, over this document's tokens and text and the window's cached
/// `ReferenceIndex`; never the project's text. The coordinator runs it on the
/// settle edge and on a new index version, never per keystroke
/// (`EditorCoordinator.refreshProblemMarks`).
enum ManuscriptChecks {

    /// One marker as publishing reads it: a bracket mixing keys and labels is
    /// ONE group over the whole bracket (`ManuscriptInlineScanner.scanGroups`),
    /// every other marker a group of one. Ranges are the document's UTF-16.
    struct Group: Equatable {
        enum Part: Equatable {
            case citation([CitationItem])
            case crossRef(ManuscriptLabel)
            case footnoteRef(String)
        }
        let range: NSRange
        let parts: [Part]

        func shifted(by offset: Int) -> Group {
            Group(range: NSRange(location: range.location + offset, length: range.length),
                  parts: parts)
        }
    }

    /// What the checks found, and the footnote numbers they derived.
    struct Analysis: Equatable {
        /// Sorted by location.
        let problems: [Problem]
        /// Footnote label → its number in this document: the order publishing
        /// numbers a piece's footnotes in (first reference in the text, then
        /// the references inside the definitions used, to a fixed point). A
        /// label with no definition has none.
        let footnoteNumbers: [String: Int]
    }

    struct Problem: Equatable {
        let range: NSRange
        let kind: PublishProblem.Kind
    }

    // MARK: - The checks

    /// Every problem in this document, sorted by location. With `index` nil
    /// (the window's index not built yet) the three checks that need it —
    /// unknown key, unresolved cross-reference, a label also defined elsewhere
    /// — are skipped rather than reporting every marker; the footnote checks
    /// and a label defined twice here need only this document.
    static func problems(in tokens: [Token], text: NSString, index: ReferenceIndex?,
                         labelsElsewhere: Set<ManuscriptLabel>) -> [(range: NSRange, kind: PublishProblem.Kind)] {
        analyse(tokens: tokens, text: text, index: index, labelsElsewhere: labelsElsewhere)
            .problems.map { ($0.range, $0.kind) }
    }

    /// - Parameters:
    ///   - figureLineStatus: a figure line's path as written → what it names
    ///     in the window's registry (`FigureCardCache.status`, memory only).
    ///     Nil (another surface), or nil for a line (the cache not filled
    ///     yet), skips that line's path checks, as `index == nil` skips the
    ///     index's; the label-kind checks read the line alone.
    ///   - blockGroups: reads one block's text into its groups; the
    ///     coordinator passes its per-block cache, so a settle re-scans only
    ///     blocks whose text changed.
    static func analyse(tokens: [Token], text: NSString, index: ReferenceIndex?,
                        labelsElsewhere: Set<ManuscriptLabel>,
                        figureLineStatus: ((String) -> FigureLineResolution.Status?)? = nil,
                        blockGroups: (String) -> [Group] = groups(inBlockText:)) -> Analysis {
        var problems: [Problem] = []
        let notes = footnotes(in: tokens, text: text)
        problems += notes.problems
        problems += figureLineProblems(in: tokens, text: text, status: figureLineStatus)
        problems += gluedFigureLineProblems(in: tokens, text: text)

        // Labels defined here: twice here, or here and in another piece.
        var seen = Set<ManuscriptLabel>()
        // Labels this document's LIVE text defines on their own kind of
        // element: a reference to one resolves even before the index's
        // rebuild has caught up (no red flicker for a label and its reference
        // typed in one burst).
        var targetsHere = Set<ManuscriptLabel>()
        for token in tokens where token.kind == .attributeBlock {
            guard let label = definedLabel(token.range, in: text) else { continue }
            if elementKind(ofLineAt: token.range.location, in: text) == label.kind {
                targetsHere.insert(label)
            }
            let again = !seen.insert(label).inserted
            if again || (index != nil && labelsElsewhere.contains(label)) {
                problems.append(Problem(range: token.range, kind: .duplicateLabel(label)))
            }
        }

        if let index {
            for group in groups(in: tokens, text: text, blockGroups: blockGroups) {
                for part in group.parts {
                    switch part {
                    case .citation(let items):
                        for item in items where index.source(forKey: item.key) == nil {
                            problems.append(Problem(
                                range: itemRange("@" + item.key, in: group.range, text: text),
                                kind: .unknownCitationKey(item.key)))
                        }
                    case .crossRef(let label):
                        if index.target(for: label) == nil, !targetsHere.contains(label) {
                            problems.append(Problem(
                                range: itemRange("@" + label.reference, in: group.range, text: text),
                                kind: .unresolvedCrossRef(label)))
                        }
                    case .footnoteRef:
                        continue
                    }
                }
            }
        }
        problems.sort { $0.range.location < $1.range.location }
        return Analysis(problems: problems, footnoteNumbers: notes.numbers)
    }

    // MARK: - Figure lines (report plan 7b Task 7)

    /// At most one problem per figure line, on its `](path)` token: the path
    /// first — not local (F9), no figure there, two figures there (lexical
    /// and registry only, R7b-4: no disk, so a missing image file stays
    /// Publish's `.imageUnreadable`) — then the label's kind (R7b-3): an
    /// image labelled `tbl:` is Publish's `.labelOnWrongElement`, a table
    /// figure labelled `fig:` the editor's own warning.
    static func figureLineProblems(in tokens: [Token], text: NSString,
                                   status: ((String) -> FigureLineResolution.Status?)?) -> [Problem] {
        var out: [Problem] = []
        for token in tokens {
            guard let path = FigureThumbnailLayout.figurePath(closing: token, in: text) else { continue }
            if let kind = figureLineProblem(path: path, label: figureLabel(ofLineAt: token.range.location, in: text),
                                            status: status?(path)) {
                out.append(Problem(range: token.range, kind: kind))
            }
        }
        return out
    }

    /// A line that alone would be a figure line but is glued to text
    /// (merged from another device, an old file): it shares a paragraph, so
    /// the parser reads it as an inline image and it has no figure token; or
    /// it directly follows a list item or a blockquote, which Publish reads
    /// as that block's lazy continuation (whole-branch review M6). The editor
    /// keeps a line it is typed beside apart (`FigureLineSeparation`); this
    /// says the ones that arrived glued. Never in code — inline code, a
    /// fence or an indented line (`FigureLineSeparation.isInCode`).
    static func gluedFigureLineProblems(in tokens: [Token], text: NSString) -> [Problem] {
        var figureLines = Set<Int>()
        var code: [NSRange] = []
        for token in tokens {
            if token.kind == .code { code.append(token.range) }
            if FigureThumbnailLayout.figurePath(closing: token, in: text) != nil {
                figureLines.insert(text.lineRange(for: NSRange(location: token.range.location, length: 0)).location)
            }
        }
        var out: [Problem] = []
        var search = 0
        while search < text.length {
            let found = text.range(of: "![", range: NSRange(location: search, length: text.length - search))
            guard found.location != NSNotFound else { break }
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: found.location, length: 0))
            search = max(end, NSMaxRange(found))
            let line = NSRange(location: start, length: contentsEnd - start)
            guard case .figure(_, let path, _)? = ManuscriptBlocks.parse(
                      text.substring(with: line).trimmingCharacters(in: .whitespaces)).first?.block,
                  !code.contains(where: { NSIntersectionRange($0, line).length > 0 }),
                  !FigureLineSeparation.isInCode(lineAt: start, in: text),
                  isGlued(line, isAFigure: figureLines.contains(start), in: text)
            else { continue }
            out.append(Problem(range: line, kind: .figureLineSharesParagraph(path)))
        }
        return out
    }

    /// True when the parser reads `line` inside a paragraph of more than one
    /// line, or — read as a figure — directly under a list item or a
    /// blockquote: the run of non-blank lines around it, parsed alone.
    private static func isGlued(_ line: NSRange, isAFigure: Bool, in text: NSString) -> Bool {
        func isBlank(_ r: NSRange) -> Bool {
            text.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var first = line.location, last = NSMaxRange(text.lineRange(for: line))
        while first > 0 {
            let above = text.lineRange(for: NSRange(location: first - 1, length: 0))
            if isBlank(above) { break }
            first = above.location
        }
        guard first < line.location || !isAFigure else { return false }
        while last < text.length {
            let below = text.lineRange(for: NSRange(location: last, length: 0))
            if isBlank(below) { break }
            last = NSMaxRange(below)
        }
        let run = text.substring(with: NSRange(location: first, length: last - first))
        let index = text.substring(with: NSRange(location: first, length: line.location - first))
            .components(separatedBy: "\n").count - 1
        let blocks = ManuscriptBlocks.parse(run)
        guard let block = blocks.first(where: { $0.lines.contains(index) }) else { return false }
        switch block.block {
        case .other(.paragraph(let lines)):
            return lines.count > 1
        case .figure:
            guard let above = blocks.first(where: { $0.lines.contains(index - 1) }) else { return false }
            switch above.block {
            case .other(.list), .other(.blockquote): return true
            default: return false
            }
        default:
            return false
        }
    }

    /// The one problem of a figure line with `path` and `label` whose
    /// registry status is `status` (nil: not known), or nil.
    static func figureLineProblem(path: String, label: ManuscriptLabel?,
                                  status: FigureLineResolution.Status?) -> PublishProblem.Kind? {
        switch status {
        case .notLocal?: return .figurePathNotLocal(path)
        case .missing?: return .figureNotFound(path)
        case .ambiguous?: return .figureAmbiguous(path)
        case .figure?, .outsideFigures?, nil: break
        }
        guard let label else { return nil }
        let isTable = ManuscriptLabel.Kind.isTableFigurePath(path)
        switch label.kind {
        case .tbl where !isTable: return .labelOnWrongElement(label)
        case .fig where isTable: return .tableFigureLabelledFig(label)
        case .sec: return .labelOnWrongElement(label)
        case .tbl, .fig: return nil
        }
    }

    /// The label of the figure line holding `location`, by the rule the
    /// tokenizer's figure tokens come from (`ManuscriptBlocks.parse`).
    private static func figureLabel(ofLineAt location: Int, in text: NSString) -> ManuscriptLabel? {
        let line = text.substring(with: text.lineRange(for: NSRange(location: location, length: 0)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .figure(_, _, let label)? = ManuscriptBlocks.parse(line).first?.block else { return nil }
        return label
    }

    // MARK: - Footnotes

    /// Publishing's per-piece footnote rule (`PublishResolution.resolveInlines`)
    /// over this document's tokens: a reference outside every definition is
    /// read first; a definition it reaches is walked in turn, to a fixed point,
    /// and the order they are reached in is their number. A definition nothing
    /// walked reaches is unused, and the references inside it are never read;
    /// a second definition of a label is a duplicate, and is never read either.
    static func footnotes(in tokens: [Token], text: NSString)
        -> (problems: [Problem], numbers: [String: Int]) {
        var heads: [(range: NSRange, label: String)] = []
        var refs: [(range: NSRange, label: String)] = []
        for token in tokens {
            switch token.kind {
            case .footnoteLabel:
                if let label = footnoteLabel(token.range, in: text, closer: "]:") {
                    heads.append((token.range, label))
                }
            case .footnoteReference:
                if let label = footnoteLabel(token.range, in: text, closer: "]") {
                    refs.append((token.range, label))
                }
            default:
                continue
            }
        }
        guard !heads.isEmpty || !refs.isEmpty else { return ([], [:]) }
        heads.sort { $0.range.location < $1.range.location }
        refs.sort { $0.range.location < $1.range.location }

        // Each definition runs from its head to the next head in its block,
        // or to the block's end (`ManuscriptBlocks`' footnote rule).
        var problems: [Problem] = []
        var extents: [(range: NSRange, owner: String?)] = []   // nil owner: a duplicate
        var definitions: [String: NSRange] = [:]               // the first one, its head
        for (i, head) in heads.enumerated() {
            let block = enclosingBlock(of: head.range.location, in: text)
            var end = NSMaxRange(block)
            if i + 1 < heads.count, heads[i + 1].range.location < end {
                end = heads[i + 1].range.location
            }
            let extent = NSRange(location: head.range.location, length: end - head.range.location)
            if definitions[head.label] == nil {
                definitions[head.label] = head.range
                extents.append((extent, head.label))
            } else {
                extents.append((extent, nil))
                problems.append(Problem(range: head.range,
                                        kind: .duplicateFootnoteDefinition(head.label)))
            }
        }
        // The extents are sorted and never overlap: a binary search finds the
        // one that may hold `location`.
        func owner(of location: Int) -> (inside: Bool, label: String?) {
            var lo = 0, hi = extents.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if extents[mid].range.location <= location { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0, NSLocationInRange(location, extents[lo - 1].range) else { return (false, nil) }
            return (true, extents[lo - 1].owner)
        }
        var top: [(range: NSRange, label: String)] = []
        var inside: [String: [(range: NSRange, label: String)]] = [:]
        for ref in refs {
            let o = owner(of: ref.range.location)
            if !o.inside { top.append(ref) } else if let label = o.label { inside[label, default: []].append(ref) }
        }

        var used: [String] = []
        var referenced = Set<String>()
        func visit(_ found: [(range: NSRange, label: String)]) {
            for ref in found {
                referenced.insert(ref.label)
                if definitions[ref.label] == nil {
                    problems.append(Problem(range: ref.range,
                                            kind: .missingFootnoteDefinition(ref.label)))
                } else if !used.contains(ref.label) {
                    used.append(ref.label)
                }
            }
        }
        visit(top)
        var next = 0
        while next < used.count {
            let label = used[next]
            next += 1
            visit(inside[label] ?? [])
        }
        for head in heads where definitions[head.label] == head.range
            && !referenced.contains(head.label) {
            problems.append(Problem(range: head.range, kind: .unusedFootnoteDefinition(head.label)))
        }
        var numbers: [String: Int] = [:]
        for (i, label) in used.enumerated() { numbers[label] = i + 1 }
        return (problems, numbers)
    }

    // MARK: - Markers

    /// Every marker group in the document whose range holds a citation,
    /// cross-reference or footnote-reference token, read per blank-line block
    /// as the tokenizer reads it (each block scanned once).
    static func groups(in tokens: [Token], text: NSString,
                       blockGroups: (String) -> [Group] = groups(inBlockText:)) -> [Group] {
        let markers = tokens.filter { isMarker($0.kind) }.map(\.range)
            .sorted { $0.location < $1.location }
        var out: [Group] = []
        var i = 0
        while i < markers.count {
            let block = enclosingBlock(of: markers[i].location, in: text)
            var inBlock: [NSRange] = []
            while i < markers.count, markers[i].location < NSMaxRange(block) {
                inBlock.append(markers[i])
                i += 1
            }
            // A scanned marker the tokenizer never claimed (inside a link, say)
            // is not the editor's marker, so it is neither checked nor labelled.
            out += blockGroups(text.substring(with: block))
                .map { $0.shifted(by: block.location) }
                .filter { group in inBlock.contains { NSIntersectionRange($0, group.range).length > 0 } }
        }
        return out
    }

    /// The groups of a block's text, relative to it (what the label overlay
    /// caches by the block's text).
    static func groups(inBlockText blockText: String) -> [Group] {
        ManuscriptInlineScanner.scanGroups(blockText).map { found in
            Group(range: found.range, parts: found.markers.map { marker in
                switch marker {
                case .citation(let items): return .citation(items)
                case .crossRef(let label): return .crossRef(label)
                case .footnoteRef(let label): return .footnoteRef(label)
                }
            })
        }
    }

    static func isMarker(_ kind: Token.Kind) -> Bool {
        switch kind {
        case .citation, .crossReference, .footnoteReference: return true
        default: return false
        }
    }

    // MARK: - Labels beside markers (R-3b-1, R-3b-2)

    /// The faint text drawn beside `group`: a citation as publishing prints
    /// it ("(Smith 2026a, p. 12)"), a cross-reference's "Figure 3" or section
    /// title, a footnote's number in this document. A mixed bracket joins its
    /// parts with "; ". Nil when nothing in it resolves — the problem
    /// underline speaks instead.
    static func labelText(for group: Group, index: ReferenceIndex,
                          footnoteNumbers: [String: Int]) -> String? {
        let parts = group.parts.compactMap { part -> String? in
            switch part {
            case .citation(let items): return index.citationText(items)
            case .crossRef(let label): return index.target(for: label)?.text
            case .footnoteRef(let label): return footnoteNumbers[label].map(String.init)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    // MARK: - Reading the text

    /// The blank-line block holding `location` (`BlankLineBlocks`' rule: a
    /// line of only spaces and tabs is blank), without the blank lines around
    /// it. Costs one paragraph, never the document.
    static func enclosingBlock(of location: Int, in text: NSString) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let here = text.lineRange(for: NSRange(location: min(location, length - 1), length: 0))
        var start = here.location
        while start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(previous, in: text) { break }
            start = previous.location
        }
        var end = NSMaxRange(here)
        while end < length {
            let following = text.lineRange(for: NSRange(location: end, length: 0))
            if isBlank(following, in: text) || following.length == 0 { break }
            end = NSMaxRange(following)
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isBlank(_ line: NSRange, in text: NSString) -> Bool {
        for i in line.location..<NSMaxRange(line) {
            switch text.character(at: i) {
            case 0x20, 0x09, 0x0A, 0x0D: continue
            default: return false
            }
        }
        return true
    }

    /// Which kind of element the line holding `location` is, as a label
    /// must name it: a heading (`sec`), a table caption (`tbl`) or a figure
    /// line (`fig`, or `tbl` for a table figure's line not labelled `fig:`, the
    /// shared rule `ManuscriptLabel.Kind.ofFigureLine`); nil for any other line.
    static func elementKind(ofLineAt location: Int, in text: NSString) -> ManuscriptLabel.Kind? {
        let line = text.substring(with: text.lineRange(for: NSRange(location: location, length: 0)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("#") { return .sec }
        if line.hasPrefix("Table: ") { return .tbl }
        if line.hasPrefix("![") {
            guard case .figure(_, let path, let label)? = ManuscriptBlocks.parse(line).first?.block
            else { return .fig }
            return .ofFigureLine(path: path, label: label)
        }
        return nil
    }

    /// The label of a `{#kind:name}` token.
    static func definedLabel(_ range: NSRange, in text: NSString) -> ManuscriptLabel? {
        let raw = text.substring(with: range)
        guard raw.hasPrefix("{#"), raw.hasSuffix("}"), raw.count > 3 else { return nil }
        return ManuscriptLabel(reference: String(raw.dropFirst(2).dropLast()))
    }

    /// The label of `[^label]` (closer `]`) or `[^label]:` (closer `]:`).
    private static func footnoteLabel(_ range: NSRange, in text: NSString, closer: String) -> String? {
        let raw = text.substring(with: range)
        guard raw.hasPrefix("[^"), raw.hasSuffix(closer) else { return nil }
        let label = String(raw.dropFirst(2).dropLast(closer.count))
        return label.isEmpty ? nil : label
    }

    /// Where `@key` (or `@kind:name`) sits inside `group`, so a bracket of
    /// several items underlines the one at fault; the whole group if it can't
    /// be found.
    static func itemRange(_ needle: String, in group: NSRange, text: NSString) -> NSRange {
        var search = group
        while search.length > 0 {
            let found = text.range(of: needle, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            let after = NSMaxRange(found)
            if after >= NSMaxRange(group) || !continuesName(text.character(at: after)) {
                return found
            }
            search = NSRange(location: after, length: NSMaxRange(group) - after)
        }
        return group
    }

    /// Whether `c` could continue a key or a label's name — the ASCII name
    /// characters `[A-Za-z0-9_-]`, or the colon of a label — so `@smith` is
    /// not found inside `@smith2026`.
    private static func continuesName(_ c: unichar) -> Bool {
        guard c < 128, let scalar = Unicode.Scalar(c) else { return false }
        return ManuscriptLabel.isValidName(String(Character(scalar))) || c == 0x5F || c == 0x2D
            || c == 0x3A
    }
}

// MARK: - Painting the problems (the coordinator's side)

/// Answers the problem underlines' tooltips (`NSView.addToolTip`): the
/// sentence for each rect's tag. The text view does not retain a tooltip's
/// owner, so the coordinator holds this.
final class ProblemTooltips: NSObject, NSViewToolTipOwner {
    private(set) var messages: [NSView.ToolTipTag: String] = [:]
    /// The column width and container origin the rects were laid out at; a
    /// resize that changes either (a new width re-wraps, a new inset moves
    /// every line) rebuilds them.
    var width: CGFloat = 0
    var origin: CGPoint = .zero

    func add(_ message: String, rect: CGRect, to view: NSView) {
        let tag = view.addToolTip(rect, owner: self, userData: nil)
        messages[tag] = message
    }

    func removeAll(from view: NSView?) {
        for tag in messages.keys { view?.removeToolTip(tag) }
        messages.removeAll()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        messages[tag] ?? ""
    }
}

extension EditorCoordinator {
    /// The dotted underline every problem mark draws (R-3b-4).
    static let problemUnderlineStyle = NSUnderlineStyle.single.union(.patternDot)

    /// Red for a problem the project's profile refuses to publish on, amber
    /// otherwise — publishing's one severity table. System colours, so both
    /// read in light and dark.
    static func problemColor(_ kind: PublishProblem.Kind, profile: ProjectProfile?) -> NSColor {
        PublishProblem.isError(kind, profile: profile) ? .systemRed : .systemOrange
    }

    /// **The settle hook** (R-3b-4): run this document's checks and repaint
    /// their underlines and tooltips. Called on the typing burst's settle
    /// edge (`performDeferredRestyle`), after a whole-document paint (attach,
    /// an external replace, a theme or posture change), on a new index
    /// version and on a new figure-card version outside a burst
    /// (`setFigureCardVersion`) — never per keystroke (`problemCheckCount`).
    ///
    /// Display-only: layout-manager temporaries on `.underlineStyle` and
    /// `.underlineColor` alone, cleared first. Nothing else sets those
    /// temporaries, so a whole-range removal is exact; it never touches
    /// `.foregroundColor` — whose temporaries the translation dimming and the
    /// caption bar's un-fade share — nor the text or the paint inputs.
    func refreshProblemMarks() {
        guard let textView, let layoutManager = textView.layoutManager,
              let storage = textView.textStorage else { return }
        // Tokens that describe an earlier text place nothing; the next settle will.
        guard !tokensDescribeAnEarlierText else { return }
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        problemTooltips?.removeAll(from: textView)
        guard showsReferenceMarks else {
            problemMarks = []
            footnoteNumbers = [:]
            return
        }
        problemCheckCount += 1
        // An index not yet built (version 0) would call every key unknown.
        let index = referenceIndex.map { $0() }.flatMap { $0.version > 0 ? $0 : nil }
        let analysis = ManuscriptChecks.analyse(
            tokens: lastTokens, text: textView.string as NSString, index: index,
            labelsElsewhere: index == nil ? [] : (projectLabelsElsewhere?() ?? []),
            figureLineStatus: figureLineStatus,
            blockGroups: { self.cachedReferenceGroups(blockText: $0) })
        problemMarks = analysis.problems
        if footnoteNumbers != analysis.footnoteNumbers {
            footnoteNumbers = analysis.footnoteNumbers
        }
        let profile = projectProfile?()
        let style = NSNumber(value: Self.problemUnderlineStyle.rawValue)
        for problem in problemMarks {
            let range = NSIntersectionRange(problem.range, full)
            guard range.length > 0 else { continue }
            layoutManager.addTemporaryAttributes(
                [.underlineStyle: style,
                 .underlineColor: Self.problemColor(problem.kind, profile: profile)],
                forCharacterRange: range)
        }
        rebuildProblemTooltips()
        referenceLabelOverlay?.needsDisplay = true
    }

    /// One tooltip rect per line fragment of each problem, its sentence
    /// publishing's (`PublishProblem.sentence(for:)`). The old ones go first.
    func rebuildProblemTooltips() {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let tooltips = problemTooltips ?? ProblemTooltips()
        problemTooltips = tooltips
        tooltips.removeAll(from: textView)
        tooltips.width = container.size.width
        let length = textView.textStorage?.length ?? 0
        let origin = textView.textContainerOrigin
        tooltips.origin = origin
        for problem in problemMarks where NSMaxRange(problem.range) <= length {
            let message = PublishProblem.sentence(for: problem.kind)
            let glyphs = layoutManager.glyphRange(forCharacterRange: problem.range,
                                                  actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container) { rect, _ in
                tooltips.add(message, rect: rect.offsetBy(dx: origin.x, dy: origin.y), to: textView)
            }
        }
    }
}
