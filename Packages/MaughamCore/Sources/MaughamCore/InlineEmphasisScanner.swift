import Foundation

/// Flattened result of scanning asterisk emphasis in one string.
/// `runs` are non-overlapping content ranges (markers excluded), each carrying
/// the CUMULATIVE traits active there. `markers` are the asterisk ranges to
/// fade/hide. Doing the flattening here — once, centrally — means no renderer
/// needs composition logic or marker-length arithmetic.
public struct EmphasisScan: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        public let range: NSRange
        public let traits: EmphasisTraits
        public init(range: NSRange, traits: EmphasisTraits) {
            self.range = range; self.traits = traits
        }
    }
    public let runs: [Run]
    public let markers: [NSRange]
    /// Each entry is the 1-char range of a backslash that escaped a following
    /// delimiter (`*`, `~`, `_`, `` ` ``, or `\`). The escaped char renders
    /// literal; callers strip/fade the backslash uniformly. Defaulted so
    /// existing constructions keep compiling.
    public let escapes: [NSRange]
    public init(runs: [Run], markers: [NSRange], escapes: [NSRange] = []) {
        self.runs = runs; self.markers = markers; self.escapes = escapes
    }
}

/// The single source of truth for what asterisk emphasis means
/// (`*italic*`, `**bold**`, `***both***`, plus nesting). Asterisk-only by
/// design: underscore is emphasis in Markdown but underline in Fountain, so it
/// is each grammar's own concern. Unbalanced/pathological runs render literal.
///
/// Opt-in `~~strikethrough~~` (GFM) is enabled per call via `Options` — prose
/// surfaces pass it; Fountain does NOT (`~` is a lyric marker there). Backslash
/// escapes (`\*`, `\~`, …) are always honored: an escaped delimiter is literal.
public enum InlineEmphasisScanner {

    public struct Options: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Recognize `~~x~~` as `.strikethrough`. Prose surfaces pass this;
        /// Fountain surfaces do NOT (tildes stay literal there — `~` is lyric).
        public static let strikethrough = Options(rawValue: 1 << 0)
    }

    public static func scan(_ text: NSString, options: Options = []) -> EmphasisScan {
        let n = text.length
        let star: UInt16 = 42     // '*'
        let tilde: UInt16 = 126   // '~'
        let backslash: UInt16 = 92
        // Chars a backslash can escape for this grammar. `*`/`~` matter to the
        // scanner directly; `_`/`` ` ``/`\` are reported so callers strip
        // escapes uniformly even though the scanner ignores those delimiters.
        let escapable: Set<UInt16> = [42, 126, 95, 96, 92] // * ~ _ ` \

        // 0. Escape pre-pass. A `\` immediately before an escapable char
        //    neutralizes that char (records the backslash, marks the following
        //    index as consumed, skips both). `\` before anything else is plain.
        var escapes: [NSRange] = []
        var escaped = Set<Int>()
        var e = 0
        while e < n {
            if text.character(at: e) == backslash,
               e + 1 < n, escapable.contains(text.character(at: e + 1)) {
                escapes.append(NSRange(location: e, length: 1))
                escaped.insert(e + 1)
                e += 2
            } else {
                e += 1
            }
        }

        // 1. Collect delimiter runs (contiguous same-char, escaped chars excluded
        //    so an escaped delimiter breaks the run). Tildes only when enabled,
        //    and only runs of length >= 2 participate (GFM `~~`).
        struct DelimRun { let location: Int; let length: Int; let kind: UInt16 }
        var delimRuns: [DelimRun] = []
        func collect(_ ch: UInt16, minLength: Int) {
            var i = 0
            while i < n {
                if text.character(at: i) == ch && !escaped.contains(i) {
                    let start = i
                    while i < n && text.character(at: i) == ch && !escaped.contains(i) { i += 1 }
                    if i - start >= minLength {
                        delimRuns.append(DelimRun(location: start, length: i - start, kind: ch))
                    }
                } else {
                    i += 1
                }
            }
        }
        collect(star, minLength: 1)
        if options.contains(.strikethrough) { collect(tilde, minLength: 2) }
        if delimRuns.isEmpty {
            return EmphasisScan(runs: [], markers: [], escapes: escapes)
        }
        delimRuns.sort { $0.location < $1.location }

        // 2. Flanking (whitespace-based; punctuation-adjacent emphasis is
        //    out of scope). A string edge counts as whitespace.
        func isSpace(_ idx: Int) -> Bool {
            guard idx >= 0 && idx < n else { return true }
            let c = text.character(at: idx)
            return c == 32 || c == 9 || c == 10 || c == 13
        }
        struct Delim {
            let location: Int
            let original: Int
            var remaining: Int
            let canOpen: Bool
            let canClose: Bool
            let kind: UInt16
        }
        var delims: [Delim] = delimRuns.map { r in
            let leftFlanking = !isSpace(r.location + r.length) // non-space after
            let rightFlanking = !isSpace(r.location - 1)       // non-space before
            return Delim(location: r.location, original: r.length,
                         remaining: r.length,
                         canOpen: leftFlanking, canClose: rightFlanking,
                         kind: r.kind)
        }

        // 3. Delimiter-stack matching. Closers only match openers of the SAME
        //    kind. Asterisk pairing consumes 1 or 2 (italic/bold); tilde pairing
        //    always consumes exactly 2 and requires >= 2 on both sides
        //    (strikethrough). Emit nested spans (content may cover inner markers
        //    — excluded at flatten time) and collect every consumed delimiter.
        struct Emph { let range: NSRange; let trait: EmphasisTraits }
        var emphases: [Emph] = []
        var markerRanges: [NSRange] = []

        var closerIdx = 0
        while closerIdx < delims.count {
            guard delims[closerIdx].canClose, delims[closerIdx].remaining > 0 else {
                closerIdx += 1; continue
            }
            let closerKind = delims[closerIdx].kind
            var openerIdx = closerIdx - 1
            var matchedThisCloser = false
            while openerIdx >= 0 {
                let kindMatch = delims[openerIdx].kind == closerKind
                // Tilde needs >= 2 remaining on both sides; asterisk needs >= 1.
                let tildeOK = closerKind != tilde
                    || (delims[openerIdx].remaining >= 2 && delims[closerIdx].remaining >= 2)
                if delims[openerIdx].canOpen, delims[openerIdx].remaining > 0,
                   kindMatch, tildeOK {
                    let use: Int
                    let trait: EmphasisTraits
                    if closerKind == tilde {
                        use = 2
                        trait = .strikethrough
                    } else {
                        use = (delims[openerIdx].remaining >= 2
                               && delims[closerIdx].remaining >= 2) ? 2 : 1
                        trait = use == 2 ? .bold : .italic
                    }
                    // Opener consumes its RIGHTMOST `use`; closer its LEFTMOST.
                    let openMarkerLoc =
                        delims[openerIdx].location + delims[openerIdx].remaining - use
                    markerRanges.append(NSRange(location: openMarkerLoc, length: use))
                    let closerConsumed =
                        delims[closerIdx].original - delims[closerIdx].remaining
                    let closeMarkerLoc = delims[closerIdx].location + closerConsumed
                    markerRanges.append(NSRange(location: closeMarkerLoc, length: use))

                    // Content spans from the opener run's far-right edge to the
                    // closer run's far-left edge (full-run edges — inner markers
                    // get excluded when we flatten).
                    let contentStart = delims[openerIdx].location + delims[openerIdx].original
                    let contentEnd = delims[closerIdx].location
                    if contentEnd > contentStart {
                        emphases.append(Emph(
                            range: NSRange(location: contentStart,
                                           length: contentEnd - contentStart),
                            trait: trait))
                    }
                    delims[openerIdx].remaining -= use
                    delims[closerIdx].remaining -= use
                    matchedThisCloser = true
                    if delims[closerIdx].remaining == 0 { break }
                } else {
                    openerIdx -= 1
                }
            }
            if !matchedThisCloser { closerIdx += 1 }
        }

        // 4. Flatten: accumulate cumulative traits per index, drop marker
        //    indices, coalesce into runs.
        var perIndex = [EmphasisTraits](repeating: [], count: n)
        for em in emphases {
            for idx in em.range.location ..< (em.range.location + em.range.length) {
                perIndex[idx].insert(em.trait)
            }
        }
        var markerSet = Set<Int>()
        for m in markerRanges {
            for idx in m.location ..< (m.location + m.length) { markerSet.insert(idx) }
        }

        var runs: [EmphasisScan.Run] = []
        var idx = 0
        while idx < n {
            if markerSet.contains(idx) || perIndex[idx].isEmpty { idx += 1; continue }
            let start = idx
            let traits = perIndex[idx]
            while idx < n, !markerSet.contains(idx), perIndex[idx] == traits { idx += 1 }
            runs.append(EmphasisScan.Run(
                range: NSRange(location: start, length: idx - start), traits: traits))
        }

        // Coalesce adjacent marker indices into clean ranges (e.g. *** -> one span).
        let sortedMarkers = markerSet.sorted()
        var markers: [NSRange] = []
        var m = 0
        while m < sortedMarkers.count {
            let start = sortedMarkers[m]
            var end = start
            while m + 1 < sortedMarkers.count, sortedMarkers[m + 1] == end + 1 {
                end = sortedMarkers[m + 1]; m += 1
            }
            markers.append(NSRange(location: start, length: end - start + 1))
            m += 1
        }

        return EmphasisScan(runs: runs, markers: markers, escapes: escapes)
    }
}
