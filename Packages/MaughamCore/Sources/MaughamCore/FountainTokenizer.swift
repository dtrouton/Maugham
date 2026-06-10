import Foundation

/// Parses Fountain source text into a typed `FountainScript`. Pure logic;
/// no AppKit dependencies. Uses a line-based state machine because Fountain
/// element classification is fundamentally context-sensitive.
public struct FountainTokenizer: Sendable {
    public init() {}

    private enum BlockState {
        case normal
        case boneyard
        case noteBlock
    }

    /// One physical line of the source, located by a single buffer pass.
    ///
    /// INTENT (spec §5.1): this is the seam a future INCREMENTAL tokenizer
    /// re-derives from — it is a real, documented type, not an inlined
    /// implementation detail. An incremental pass would re-scan only the
    /// dirty `LineRecord`s and splice them back into the line array, re-running
    /// classification on the affected window. Keep the classification inputs
    /// explicit (range, content range, blank/ASCII flags, first code unit) so
    /// that future seam needs no re-derivation from the raw buffer.
    ///
    /// Ranges are UTF-16 (the token coordinate space, matching `NSRange` over
    /// `textView.string`). `range` includes the line's trailing terminator (so
    /// consecutive records are contiguous, exactly as `.byLines`'
    /// `enclosingRange` is); `contentRange` excludes it.
    struct LineRecord {
        /// UTF-16 range including the trailing terminator (\n, \r, \r\n as one,
        /// U+0085, U+2028, U+2029). Matches `.byLines` enclosingRange.
        let range: NSRange
        /// UTF-16 range excluding the terminator. Matches `.byLines` substring
        /// range. Length 0 for a blank line that is just a terminator.
        let contentRange: NSRange
        /// `contentRange` with leading/trailing ASCII space/tab removed — the
        /// classification input, equal to `fastTrimWhitespaces` over an ASCII
        /// line. For a NON-ASCII line this is left equal to `contentRange`
        /// (the line materializes-and-Foundation-trims in the fallback path).
        let trimmedRange: NSRange
        /// True when the content (terminator excluded) is entirely ASCII
        /// whitespace (space/tab) or empty — i.e. `fastTrimWhitespaces` would
        /// yield "". Pure-ASCII fast path; non-ASCII content is never flagged
        /// blank here (it defers to Foundation).
        let isBlank: Bool
        /// True when every content code unit is < 0x80 — enables the ASCII
        /// classification fast paths; false routes the line through the
        /// materialize-and-use-existing-logic Foundation fallback.
        let isASCII: Bool
        /// First non-whitespace ASCII code unit of the content, or 0 when the
        /// line is blank / non-ASCII. Cheap forced-marker dispatch input.
        let firstUnit: UInt16
        /// True when the content contains any `*`, `_`, or `[` — the only chars
        /// that can open an inline span. When false the inline-span scan is
        /// provably empty and is skipped. Computed in the single scan pass.
        let hasMarkup: Bool
    }

    /// Materialize a String from a UTF-16 buffer slice known to be pure ASCII
    /// (every code unit < 0x80, so each is its own Unicode scalar). Faster than
    /// the NSString substring bridge on the per-line hot path; identical result
    /// to `(nsText as String).substring(with: range)` for ASCII ranges.
    /// (Measured 2026-06-10: `String(utf16CodeUnits:)` beats a hand-rolled
    /// `String(unsafeUninitializedCapacity:)` UTF-8 fill in Debug, where the
    /// per-byte bounds-checked loop dominates.)
    @inline(__always)
    static func asciiString(_ buffer: [UInt16], _ range: NSRange) -> String {
        if range.length == 0 { return "" }
        return buffer[range.location ..< (range.location + range.length)]
            .withUnsafeBufferPointer { String(utf16CodeUnits: $0.baseAddress!, count: $0.count) }
    }

    /// Single pass over the UTF-16 buffer producing `LineRecord`s. Terminators
    /// are recognized EXACTLY as `NSString.enumerateSubstrings(.byLines)` does:
    /// `\n` (LF), `\r` (CR), `\r\n` (CRLF — ONE terminator, only when adjacent),
    /// U+0085 (NEL), U+2028 (LS), U+2029 (PS).
    ///
    /// Matches `.byLines` enclosingRange semantics verified empirically
    /// (2026-06-10): a trailing terminator does NOT yield a final empty record
    /// (the caller appends the trailing zero-length line for a trailing `\n`,
    /// preserving the production contract); an interior blank line yields a
    /// zero-content record covering its terminator.
    static func scanLines(_ buffer: [UInt16]) -> [LineRecord] {
        var records: [LineRecord] = []
        let n = buffer.count
        // Pre-reserve: line density floor of ~1 record per 16 units avoids most
        // growth reallocations on real screenplay text.
        records.reserveCapacity(n / 16 + 1)
        // Hot loop over an unsafe pointer — strips Array bounds checks (a
        // measurable Debug win on a buffer this size).
        buffer.withUnsafeBufferPointer { buf in
            var i = 0
            let CR: UInt16 = 0x0D
            let LF: UInt16 = 0x0A
            let NEL: UInt16 = 0x0085
            let LS: UInt16 = 0x2028
            let PS: UInt16 = 0x2029
            let SPACE: UInt16 = 0x20
            let TAB: UInt16 = 0x09

            while i < n {
                let lineStart = i
                // Walk to the next terminator.
                while i < n {
                    let u = buf[i]
                    if u == LF || u == CR || u == NEL || u == LS || u == PS { break }
                    i += 1
                }
                let contentEnd = i   // exclusive; excludes terminator
                // Determine terminator length (CRLF merges only when adjacent).
                var termLen = 0
                if i < n {
                    if buf[i] == CR && i + 1 < n && buf[i + 1] == LF {
                        termLen = 2
                    } else {
                        termLen = 1
                    }
                }
                let lineEnd = i + termLen   // exclusive; includes terminator

                // Characterize the content [lineStart, contentEnd) in ONE walk:
                // ASCII-purity AND inline-markup presence (`*` 0x2A, `_` 0x5F,
                // `[` 0x5B). Folding markup detection here removes the separate
                // per-line buffer walk `lineMayHaveInlineMarkup` did.
                var isASCII = true
                var hasMarkup = false
                var j = lineStart
                while j < contentEnd {
                    let u = buf[j]
                    if u >= 0x80 { isASCII = false }
                    else if u == 0x2A || u == 0x5F || u == 0x5B { hasMarkup = true }
                    j += 1
                }

                var trimLo = lineStart
                var trimHi = contentEnd   // exclusive
                var firstUnit: UInt16 = 0
                if isASCII {
                    // ASCII fast trim — leading/trailing space (0x20) / tab
                    // (0x09), identical to fastTrimWhitespaces over ASCII.
                    while trimLo < trimHi {
                        let u = buf[trimLo]
                        if u == SPACE || u == TAB { trimLo += 1 } else { break }
                    }
                    while trimHi > trimLo {
                        let u = buf[trimHi - 1]
                        if u == SPACE || u == TAB { trimHi -= 1 } else { break }
                    }
                    if trimLo < trimHi { firstUnit = buf[trimLo] }
                } else {
                    // Non-ASCII: leave trimmedRange == contentRange; the line is
                    // materialized and Foundation-trimmed in the fallback path.
                    trimLo = lineStart
                    trimHi = contentEnd
                }
                // isBlank: pure-ASCII fast path only (matches fastTrim, which
                // defers non-ASCII to Foundation; a non-ASCII line is never
                // treated as blank and routes through materialization).
                let isBlank = isASCII && (trimLo == trimHi)

                records.append(LineRecord(
                    range: NSRange(location: lineStart, length: lineEnd - lineStart),
                    contentRange: NSRange(location: lineStart, length: contentEnd - lineStart),
                    trimmedRange: NSRange(location: trimLo, length: trimHi - trimLo),
                    isBlank: isBlank,
                    isASCII: isASCII,
                    firstUnit: isASCII ? firstUnit : 0,
                    hasMarkup: hasMarkup))

                i = lineEnd
                if termLen == 0 { break }
            }
        }
        return records
    }

    /// Trim leading/trailing `CharacterSet.whitespaces` (space, tab, Unicode
    /// `Zs`). Hot path: this tokenizer trims every line once per keystroke on
    /// the whole document. A pure-ASCII line is trimmed by a manual byte scan
    /// that allocates a single `String` from the trimmed `Substring`; the
    /// moment any non-ASCII byte appears we defer to Foundation so Unicode
    /// whitespace (U+00A0 etc.) keeps EXACT semantics. The result is identical
    /// to `String(raw).trimmingCharacters(in: .whitespaces)`.
    @inline(__always)
    static func fastTrimWhitespaces(_ raw: String) -> String {
        let utf8 = raw.utf8
        // Reject (defer) on any non-ASCII byte: a multibyte scalar could be a
        // `Zs` separator that Foundation would trim and we must not mis-handle.
        for byte in utf8 where byte >= 0x80 {
            return raw.trimmingCharacters(in: .whitespaces)
        }
        // Pure ASCII: trim space (0x20) / tab (0x09) from both ends over the
        // String's own indices (1 scalar == 1 UTF-8 byte == 1 Character here).
        var lo = raw.startIndex
        let hi0 = raw.endIndex
        var hi = hi0
        while lo < hi {
            let c = raw[lo]
            if c == " " || c == "\t" { lo = raw.index(after: lo) } else { break }
        }
        while hi > lo {
            let before = raw.index(before: hi)
            let c = raw[before]
            if c == " " || c == "\t" { hi = before } else { break }
        }
        if lo == raw.startIndex && hi == hi0 { return raw }
        return String(raw[lo..<hi])
    }

    public func parse(_ text: String) -> FountainScript {
        guard !text.isEmpty else { return .empty }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Pre-pass: detect and parse title page block at document head.
        let (titlePage, titlePageEndOffset) = Self.parseTitlePage(
            nsText: nsText, fullRange: fullRange)

        // Single UTF-16 buffer pass: split the document into LineRecords once,
        // then drive the existing per-line state machine off them. Each line's
        // `raw` String is materialized exactly once from the record's content
        // range (replacing enumerateSubstrings' per-line String + thunk).
        let buffer = Array(text.utf16)
        let records = Self.scanLines(buffer)

        var lines: [FountainLine] = []
        lines.reserveCapacity(records.count + 1)
        var prevBlank = true
        var prevElement: ScreenplayElement = .action
        var prevWasDualSecond = false
        var blockState: BlockState = .normal

        for record in records {
            let enclosingRange = record.range

            // FACET: derive `trimmed` from the record's code-unit trimmed range
            // for ASCII lines (the common case) — one String materialization,
            // no `raw` substring + separate `fastTrimWhitespaces` pass. Non-
            // ASCII lines materialize the raw content and Foundation-trim it,
            // identical to the pre-rewrite path. `raw` (full content, untrimmed)
            // is materialized LAZILY below only when the inline-span scan needs
            // it (markup present).
            let trimmed: String
            if record.isASCII {
                // Materialize directly from the UTF-16 buffer slice (the line is
                // pure ASCII so every unit is a self-contained scalar) — avoids
                // the NSString substring bridge on the per-line hot path.
                trimmed = Self.asciiString(buffer, record.trimmedRange)
            } else {
                trimmed = nsText.substring(with: record.contentRange)
                    .trimmingCharacters(in: .whitespaces)
            }

            // If this line is inside the title page block, classify as .titlePage.
            // Don't update prevBlank/prevElement so body classification starts
            // from the same initial state regardless of title page close mode.
            if enclosingRange.location < titlePageEndOffset {
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .titlePage,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed),
                    inlineSpans: []))
                continue
            }

            // While inside a multi-line block, classify the line as that
            // block kind. Exit on the closing marker.
            switch blockState {
            case .boneyard:
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .boneyard,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                if trimmed.contains("*/") { blockState = .normal }
                prevBlank = false
                prevElement = .boneyard
                prevWasDualSecond = false
                continue
            case .noteBlock:
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .note,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                if trimmed.contains("]]") { blockState = .normal }
                prevBlank = false
                prevElement = .note
                prevWasDualSecond = false
                continue
            case .normal:
                break
            }

            if trimmed.isEmpty {
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .action,
                    content: "",
                    isForced: false,
                    sourceCase: .neutral))
                prevBlank = true
                prevElement = .action
                prevWasDualSecond = false
                continue
            }

            // Boneyard open on this line — single-line if "*/" appears,
            // otherwise enter .boneyard state. firstUnit gate: `/` (0x2F) or
            // non-ASCII (0 → must check).
            if (record.firstUnit == 0x2F || record.firstUnit == 0),
               trimmed.hasPrefix("/*") {
                let closesOnLine = trimmed.dropFirst(2).contains("*/")
                if !closesOnLine { blockState = .boneyard }
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .boneyard,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                prevBlank = false
                prevElement = .boneyard
                prevWasDualSecond = false
                continue
            }

            // Block note open: line starts with [[ and either lacks ]] (multi-
            // line) or is entirely [[...]] (single-line block note). firstUnit
            // gate: `[` (0x5B) or non-ASCII (0 → must check).
            if (record.firstUnit == 0x5B || record.firstUnit == 0),
               trimmed.hasPrefix("[[") {
                let closesOnLine = trimmed.contains("]]")
                if !closesOnLine { blockState = .noteBlock }
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .note,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                prevBlank = false
                prevElement = .note
                prevWasDualSecond = false
                continue
            }

            let classified = Self.classify(
                line: trimmed,
                prevBlank: prevBlank,
                prevElement: prevElement,
                firstUnit: record.firstUnit)

            // Inline span pass: locate notes, bold, italic, and underline spans
            // within the line, recorded relative to the enclosing line range.
            // FACET: gate on code units — only lines containing `*`, `_`, or
            // `[` can carry inline markup (emphasis, underline, or [[note]]).
            // The overwhelming majority of lines have none, so this skips the
            // NSString materialization + InlineEmphasisScanner + scanNotes +
            // regex entirely. Identical output to always-call by construction
            // (the scanners emit nothing when their trigger chars are absent),
            // pinned by the differential corpus' emphasis/note cases.
            let inlineSpans: [FountainInlineSpan]
            if record.hasMarkup {
                // Materialize the raw (untrimmed) line only here — the scanners
                // need positions relative to the full content range.
                let raw = nsText.substring(with: record.contentRange)
                inlineSpans = Self.inlineSpans(
                    in: trimmed,
                    lineRange: enclosingRange,
                    rawLine: raw,
                    nsText: nsText)
            } else {
                inlineSpans = []
            }

            // Compute isDualSecond for this line.
            var lineIsDualSecond = false
            var emittedContent = classified.content

            if classified.element == .character {
                // Detect trailing ^ on the cue, strip it from content.
                let (strippedCue, isDual) = Self.extractDualMarker(from: classified.content)
                if isDual {
                    lineIsDualSecond = true
                    emittedContent = strippedCue
                }
            } else if classified.element == .dialogue || classified.element == .parenthetical {
                // Inherit from the preceding line's dual-second state.
                lineIsDualSecond = prevWasDualSecond
            }

            lines.append(FountainLine(
                range: enclosingRange,
                element: classified.element,
                content: emittedContent,
                isForced: classified.isForced,
                sourceCase: Self.sourceCase(of: emittedContent),
                isDualSecond: lineIsDualSecond,
                inlineSpans: inlineSpans))
            prevBlank = false
            prevElement = classified.element
            prevWasDualSecond = lineIsDualSecond
        }

        // Trailing empty line: if the source text ends with "\n", emit a
        // zero-length FountainLine at the end so that a cursor at the very
        // end of the document lands on its own line rather than on the
        // previous line's range.
        if nsText.length > 0 && nsText.character(at: nsText.length - 1) == UInt16(("\n" as UnicodeScalar).value) {
            lines.append(FountainLine(
                range: NSRange(location: nsText.length, length: 0),
                element: .action,
                content: "",
                isForced: false,
                sourceCase: .neutral,
                inlineSpans: []))
        }

        return FountainScript(lines: lines, titlePage: titlePage)
    }

    // MARK: - Classification

    private struct Classified {
        let element: ScreenplayElement
        let content: String
        let isForced: Bool
    }

    /// Forced-marker first-character set, as ASCII code units:
    /// `=`(0x3D) page-break/synopsis, `#`(0x23) section, `.`(0x2E) forced
    /// scene, `!`(0x21) forced action, `>`(0x3E) centered/transition,
    /// `~`(0x7E) lyric, `@`(0x40) forced character. When the line's first
    /// non-whitespace code unit is ASCII and NOT in this set, the entire
    /// forced-marker dispatch is skipped — the line is action/scene/cue/
    /// dialogue, decided by the context-sensitive checks below.
    @inline(__always)
    private static func firstUnitMayBeForced(_ u: UInt16) -> Bool {
        // u == 0 means "non-ASCII / unknown" → must check everything.
        if u == 0 { return true }
        switch u {
        case 0x3D, 0x23, 0x2E, 0x21, 0x3E, 0x7E, 0x40: return true
        default: return false
        }
    }

    private static func classify(
        line: String,
        prevBlank: Bool,
        prevElement: ScreenplayElement,
        firstUnit: UInt16
    ) -> Classified {
        // FACET: skip every forced-marker check when the first ASCII code unit
        // rules them all out (the common action/dialogue case). Non-ASCII lines
        // (firstUnit == 0) fall through to the full check set unchanged.
        guard Self.firstUnitMayBeForced(firstUnit) else {
            return Self.classifyContextual(
                line: line, prevBlank: prevBlank, prevElement: prevElement)
        }

        // Page break: three or more = with no other content.
        if Self.isPageBreak(line) {
            return Classified(
                element: .pageBreak,
                content: line,
                isForced: false)
        }

        // Sections: 1 to 6 leading '#' followed by space then content.
        if let section = Self.parseSection(line) {
            return Classified(
                element: .section(level: section.level),
                content: section.content,
                isForced: true)
        }

        // Synopsis: leading '=' followed by space then content (and not a
        // page break — already handled above).
        if line.hasPrefix("= ") {
            return Classified(
                element: .synopsis,
                content: String(line.dropFirst(2)),
                isForced: true)
        }

        // Forced scene heading: leading "." but not "..".
        if line.hasPrefix(".") && !line.hasPrefix("..") {
            let stripped = String(line.dropFirst())
            return Classified(
                element: .sceneHeading,
                content: stripped,
                isForced: true)
        }

        // Forced action bang.
        if line.hasPrefix("!") {
            return Classified(
                element: .action,
                content: String(line.dropFirst()),
                isForced: true)
        }

        // Centered: line wrapped in >...<. Recognize before forced-transition
        // (which is bare leading >) so >X< doesn't get classified as a
        // transition with content "X<".
        if line.hasPrefix(">") && line.hasSuffix("<") && line.count >= 2 {
            let inner = line.dropFirst().dropLast()
                .trimmingCharacters(in: .whitespaces)
            return Classified(
                element: .centered,
                content: inner,
                isForced: true)
        }

        // Forced transition: leading >.
        if line.hasPrefix(">") {
            let stripped = String(line.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            return Classified(
                element: .transition,
                content: stripped,
                isForced: true)
        }

        // Lyric: leading ~.
        if line.hasPrefix("~") {
            return Classified(
                element: .lyric,
                content: String(line.dropFirst()),
                isForced: true)
        }

        // Forced character.
        if line.hasPrefix("@") {
            return Classified(
                element: .character,
                content: String(line.dropFirst()),
                isForced: true)
        }

        return Self.classifyContextual(
            line: line, prevBlank: prevBlank, prevElement: prevElement)
    }

    /// The non-forced (context-sensitive) classification tail: scene heading /
    /// contextual transition / cue / dialogue / parenthetical / action. Reached
    /// either when no forced marker matched, OR directly (forced-marker block
    /// skipped) when the first code unit cannot be a forced marker.
    private static func classifyContextual(
        line: String,
        prevBlank: Bool,
        prevElement: ScreenplayElement
    ) -> Classified {
        // Context-sensitive scene heading: starts with INT./EXT./EST./I/E./
        // INT/EXT., case-insensitive, and has a blank line above.
        if prevBlank && Self.isSceneHeadingPrefix(line) {
            return Classified(
                element: .sceneHeading,
                content: line,
                isForced: false)
        }

        // Context-sensitive transition: ALL-CAPS line ending in "TO:" with
        // a blank line above.
        if prevBlank && Self.isContextualTransition(line) {
            return Classified(
                element: .transition,
                content: line,
                isForced: false)
        }

        // Tentative Character: ALL-CAPS letters with blank line above.
        // The "followed by a non-blank line" requirement is enforced in a
        // post-pass (second loop), since enumerateSubstrings doesn't give
        // us forward lookahead cheaply.
        if prevBlank && Self.isAllCapsCueCandidate(line) {
            return Classified(
                element: .character,
                content: line,
                isForced: false)
        }

        // Inside a dialogue block: parenthetical or continued dialogue.
        if prevElement == .character || prevElement == .parenthetical || prevElement == .dialogue {
            if line.hasPrefix("(") && line.hasSuffix(")") {
                return Classified(
                    element: .parenthetical,
                    content: line,
                    isForced: false)
            }
            return Classified(
                element: .dialogue,
                content: line,
                isForced: false)
        }

        return Classified(
            element: .action,
            content: line,
            isForced: false)
    }

    /// Returns (cue, isDualSecond) — strips a single trailing `^` (and any
    /// spaces immediately before it) when present. The Fountain dual-dialogue
    /// marker is the LAST `^` on the cue line; double-caret `^^` is treated
    /// as one marker + a literal `^` left in the content.
    private static func extractDualMarker(from line: String) -> (cue: String, isDualSecond: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("^") else { return (line, false) }
        // Strip exactly one trailing ^ and any whitespace immediately before it.
        var stripped = String(trimmed.dropLast())
        while stripped.last == " " || stripped.last == "\t" {
            stripped = String(stripped.dropLast())
        }
        return (stripped, true)
    }

    private static func isAllCapsCueCandidate(_ line: String) -> Bool {
        var hasLetter = false
        for ch in line {
            if ch.isLetter {
                hasLetter = true
                if ch.isLowercase { return false }
            }
        }
        return hasLetter
    }

    /// True if every scalar in `line` is ASCII (< 0x80). A non-ASCII line can
    /// change LENGTH or fold unexpectedly under `uppercased()` (e.g. ß→SS,
    /// dotless ı→I), so the ASCII fast paths below MUST defer to the original
    /// `uppercased()` logic for it.
    @inline(__always)
    private static func isPureASCII(_ line: String) -> Bool {
        for b in line.utf8 where b >= 0x80 { return false }
        return true
    }

    private static func isContextualTransition(_ line: String) -> Bool {
        // FACET: case-insensitive "TO:" suffix check without allocating a full
        // uppercased copy — only the last 3 scalars matter — but ONLY for pure-
        // ASCII lines. Non-ASCII lines keep the exact `uppercased().hasSuffix`
        // path so locale-independent Unicode folding is preserved.
        if Self.isPureASCII(line) {
            guard Self.hasCaseInsensitiveASCIISuffix(line, "TO:") else { return false }
        } else {
            guard line.uppercased().hasSuffix("TO:") else { return false }
        }
        return Self.isAllCapsCueCandidate(line)
    }

    private static let sceneHeadingPrefixes = [
        "INT.", "EXT.", "EST.", "I/E.", "INT/EXT."
    ]

    private static func isSceneHeadingPrefix(_ line: String) -> Bool {
        // FACET: case-insensitive prefix match without allocating `uppercased()`
        // of the whole line — but ONLY for pure-ASCII lines. Non-ASCII lines
        // fall back to the exact original comparison.
        if Self.isPureASCII(line) {
            for prefix in sceneHeadingPrefixes {
                if Self.hasCaseInsensitiveASCIIPrefix(line, prefix, requireFollowingSpaceOrEnd: true) {
                    return true
                }
            }
            return false
        }
        let upper = line.uppercased()
        for prefix in sceneHeadingPrefixes {
            if upper.hasPrefix(prefix + " ") || upper == prefix {
                return true
            }
        }
        return false
    }

    /// True if `line` begins with `prefix` compared case-insensitively over
    /// ASCII, AND (when required) the next scalar is a space or the prefix is
    /// the entire line. `prefix` MUST be pure ASCII (the scene-heading
    /// prefixes are). Matches the original `uppercased().hasPrefix(prefix+" ")
    /// || uppercased() == prefix`.
    private static func hasCaseInsensitiveASCIIPrefix(
        _ line: String, _ prefix: String, requireFollowingSpaceOrEnd: Bool
    ) -> Bool {
        let lu = line.unicodeScalars
        let pu = prefix.unicodeScalars
        var li = lu.startIndex
        var pi = pu.startIndex
        while pi != pu.endIndex {
            guard li != lu.endIndex else { return false }
            let a = lu[li].value
            let b = pu[pi].value
            // ASCII-fold both to upper.
            let af = (a >= 0x61 && a <= 0x7A) ? a - 0x20 : a
            let bf = (b >= 0x61 && b <= 0x7A) ? b - 0x20 : b
            if af != bf { return false }
            li = lu.index(after: li)
            pi = pu.index(after: pi)
        }
        if !requireFollowingSpaceOrEnd { return true }
        // prefix matched; require a following space or end-of-line.
        if li == lu.endIndex { return true }
        return lu[li] == " "
    }

    /// True if `line` ends with `suffix` compared case-insensitively over
    /// ASCII. `suffix` MUST be pure ASCII.
    private static func hasCaseInsensitiveASCIISuffix(
        _ line: String, _ suffix: String
    ) -> Bool {
        let lu = line.unicodeScalars
        let su = suffix.unicodeScalars
        var li = lu.endIndex
        var si = su.endIndex
        while si != su.startIndex {
            guard li != lu.startIndex else { return false }
            li = lu.index(before: li)
            si = su.index(before: si)
            let a = lu[li].value
            let b = su[si].value
            let af = (a >= 0x61 && a <= 0x7A) ? a - 0x20 : a
            let bf = (b >= 0x61 && b <= 0x7A) ? b - 0x20 : b
            if af != bf { return false }
        }
        return true
    }

    private static func isPageBreak(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        return line.allSatisfy { $0 == "=" }
    }

    private static func parseSection(_ line: String) -> (level: Int, content: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
            if level > 6 { return nil }   // 7+ # is action
        }
        guard level >= 1, level <= 6 else { return nil }
        let after = line.dropFirst(level)
        guard after.first == " " else { return nil }
        let content = String(after.dropFirst())
        return (level, content)
    }

    static func sourceCase(of text: String) -> SourceCase {
        // FACET: ASCII fast path on UTF-8 bytes. The moment any non-ASCII byte
        // appears we restart on the Character loop so Unicode letters/casing
        // keep EXACT Foundation semantics (e.g. "É" is an uppercase letter,
        // CJK/emoji are non-letters). Pure-ASCII lines — the overwhelming
        // majority of screenplay text — never touch grapheme iteration.
        var hasUpper = false
        var hasLower = false
        var hasLetter = false
        for byte in text.utf8 {
            if byte >= 0x80 {
                // Non-ASCII: defer the WHOLE line to the grapheme path.
                return sourceCaseUnicode(of: text)
            }
            if byte >= 0x41 && byte <= 0x5A {        // A–Z
                hasLetter = true; hasUpper = true
            } else if byte >= 0x61 && byte <= 0x7A { // a–z
                hasLetter = true; hasLower = true
            }
        }
        if !hasLetter { return .neutral }
        if hasUpper && hasLower { return .mixed }
        if hasUpper { return .upper }
        return .lower
    }

    /// Foundation-semantics casing classification for lines containing any
    /// non-ASCII scalar. Identical to the pre-rewrite `sourceCase` body.
    private static func sourceCaseUnicode(of text: String) -> SourceCase {
        var hasUpper = false
        var hasLower = false
        var hasLetter = false
        for ch in text {
            if ch.isLetter {
                hasLetter = true
                if ch.isUppercase { hasUpper = true }
                if ch.isLowercase { hasLower = true }
            }
        }
        if !hasLetter { return .neutral }
        if hasUpper && hasLower { return .mixed }
        if hasUpper { return .upper }
        return .lower
    }

    /// Returns inline spans (notes, asterisk emphasis (via
    /// InlineEmphasisScanner), and underline) detected within a single line.
    private static func inlineSpans(
        in trimmed: String,
        lineRange: NSRange,
        rawLine: String,
        nsText: NSString
    ) -> [FountainInlineSpan] {
        var result: [FountainInlineSpan] = []
        let raw = rawLine as NSString

        // 1. Inline notes (existing behavior).
        result.append(contentsOf: scanNotes(in: raw, lineRange: lineRange))

        // 2. Asterisk emphasis (*, **, ***, nesting) via the shared scanner.
        let scan = InlineEmphasisScanner.scan(raw)
        for run in scan.runs {
            result.append(FountainInlineSpan(
                range: NSRange(location: lineRange.location + run.range.location,
                               length: run.range.length),
                kind: .emphasis(run.traits)))
        }
        for marker in scan.markers {
            result.append(FountainInlineSpan(
                range: NSRange(location: lineRange.location + marker.location,
                               length: marker.length),
                kind: .emphasisMarker))
        }

        // 3. Underline _text_. A line with fewer than two underscores cannot
        // contain a `_…_` span — skip the NSRegularExpression entirely (it runs
        // per line otherwise). Cheap byte count over UTF-8 (`_` is ASCII 0x5F).
        var underscoreCount = 0
        for b in rawLine.utf8 where b == 0x5F {
            underscoreCount += 1
            if underscoreCount >= 2 { break }
        }
        if underscoreCount >= 2 {
            result.append(contentsOf: scanRegex(
                pattern: #"_([^_\n]+)_"#,
                in: raw, lineRange: lineRange, kind: .underline))
        }

        return result
    }

    private static func scanNotes(
        in raw: NSString, lineRange: NSRange
    ) -> [FountainInlineSpan] {
        // We scan over the raw line (which retains leading whitespace and
        // any trailing whitespace before newline) so positions are correct
        // relative to lineRange.location.
        var result: [FountainInlineSpan] = []
        let rawLength = raw.length
        var search = NSRange(location: 0, length: rawLength)

        while search.length > 0 {
            let openRange = raw.range(of: "[[", options: [], range: search)
            guard openRange.location != NSNotFound else { break }
            let afterOpen = NSRange(
                location: openRange.location + 2,
                length: rawLength - (openRange.location + 2))
            let closeRange = raw.range(of: "]]", options: [], range: afterOpen)
            guard closeRange.location != NSNotFound else { break }
            let spanStart = lineRange.location + openRange.location
            let spanLength = (closeRange.location + 2) - openRange.location
            result.append(FountainInlineSpan(
                range: NSRange(location: spanStart, length: spanLength),
                kind: .note))
            let nextStart = closeRange.location + 2
            search = NSRange(
                location: nextStart,
                length: rawLength - nextStart)
        }
        return result
    }

    private static func scanRegex(
        pattern: String,
        in raw: NSString,
        lineRange: NSRange,
        kind: FountainInlineSpan.Kind
    ) -> [FountainInlineSpan] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        var result: [FountainInlineSpan] = []
        let fullRange = NSRange(location: 0, length: raw.length)
        regex.enumerateMatches(in: raw as String, options: [],
                               range: fullRange) { match, _, _ in
            guard let match else { return }
            let outer = match.range
            let spanStart = lineRange.location + outer.location
            result.append(FountainInlineSpan(
                range: NSRange(location: spanStart, length: outer.length),
                kind: kind))
        }
        return result
    }

    // MARK: - Title Page Pre-pass

    private static let titlePageKeyMap: [String: String] = [
        "title": "Title",
        "credit": "Credit",
        "author": "Author",
        "authors": "Author",
        "source": "Source",
        "notes": "Notes",
        "draft date": "Draft date",
        "contact": "Contact",
        "copyright": "Copyright",
    ]

    private static func canonicalTitlePageKey(_ raw: String) -> String? {
        let lower = raw.lowercased()
        return titlePageKeyMap[lower]
    }

    /// Parse the title page block at the document head, if present.
    /// Returns (fields, endByteOffset). endByteOffset is the offset where
    /// the body begins (after the title page block + closing blank line).
    /// If no title page is present, returns (nil, 0).
    private static func parseTitlePage(
        nsText: NSString,
        fullRange: NSRange
    ) -> (fields: [TitlePageField]?, endOffset: Int) {
        // Find the first non-empty line; check if it matches Key: Value with
        // a recognized key. If not, no title page.
        var firstNonEmpty: NSRange?
        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            sub, _, enclosing, stop in
            guard let s = sub else { return }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                firstNonEmpty = enclosing
                stop.pointee = true
            }
        }
        guard let firstLineRange = firstNonEmpty else {
            return (nil, 0)
        }
        let firstLineText = nsText.substring(with: firstLineRange)
            .trimmingCharacters(in: .whitespaces)
        guard let firstKey = parseKey(firstLineText),
              canonicalTitlePageKey(firstKey) != nil else {
            // First line doesn't match recognized title page key.
            return (nil, 0)
        }

        // Walk lines from the start, accumulating title page fields until
        // the close condition.
        var fields: [TitlePageField] = []
        var currentKey: String?
        var currentValue: [String] = []
        var currentRange: NSRange = NSRange(location: 0, length: 0)
        var endOffset = 0

        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            sub, _, enclosing, stop in
            guard let s = sub else { return }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            let leadingWhitespaceCount = s.prefix { $0 == " " || $0 == "\t" }.count
            let isIndentedContinuation = leadingWhitespaceCount >= 3
                || (s.hasPrefix("\t"))

            // Close on blank line.
            if trimmed.isEmpty {
                Self.flushField(currentKey: &currentKey,
                                currentValue: &currentValue,
                                currentRange: &currentRange,
                                fields: &fields)
                endOffset = NSMaxRange(enclosing)
                stop.pointee = true
                return
            }

            // Try to match Key: Value (top-level key).
            if let parsedKey = parseKey(trimmed),
               !isIndentedContinuation {
                // New field. Flush current.
                Self.flushField(currentKey: &currentKey,
                                currentValue: &currentValue,
                                currentRange: &currentRange,
                                fields: &fields)
                let canonical = canonicalTitlePageKey(parsedKey) ?? parsedKey
                currentKey = canonical
                let valueStart = (trimmed as NSString).range(of: ":").location + 1
                let valueText = (trimmed as NSString).substring(from: valueStart)
                    .trimmingCharacters(in: .whitespaces)
                currentValue = valueText.isEmpty ? [] : [valueText]
                currentRange = enclosing
            } else if currentKey != nil && isIndentedContinuation {
                // Continuation of previous field.
                currentValue.append(trimmed)
                currentRange = NSRange(
                    location: currentRange.location,
                    length: NSMaxRange(enclosing) - currentRange.location)
            } else {
                // Non-key non-indented line — closes the title page.
                Self.flushField(currentKey: &currentKey,
                                currentValue: &currentValue,
                                currentRange: &currentRange,
                                fields: &fields)
                endOffset = enclosing.location
                stop.pointee = true
                return
            }
        }

        // If we reached end of document without an explicit close, flush.
        Self.flushField(currentKey: &currentKey,
                        currentValue: &currentValue,
                        currentRange: &currentRange,
                        fields: &fields)
        if endOffset == 0 {
            endOffset = fullRange.length
        }

        return (fields.isEmpty ? nil : fields, endOffset)
    }

    private static func flushField(
        currentKey: inout String?,
        currentValue: inout [String],
        currentRange: inout NSRange,
        fields: inout [TitlePageField]
    ) {
        guard let key = currentKey else { return }
        let value = currentValue.joined(separator: "\n")
        fields.append(TitlePageField(
            key: key, value: value, range: currentRange))
        currentKey = nil
        currentValue = []
        currentRange = NSRange(location: 0, length: 0)
    }

    /// Parse "Key: ..." into the key (without trimming surrounding whitespace).
    /// Returns nil if the line doesn't have a colon or has invalid key format.
    private static func parseKey(_ line: String) -> String? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty,
              !key.contains("\n") else { return nil }
        return key
    }
}
