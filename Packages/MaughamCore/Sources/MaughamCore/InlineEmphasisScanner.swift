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
    public init(runs: [Run], markers: [NSRange]) {
        self.runs = runs; self.markers = markers
    }
}

/// The single source of truth for what asterisk emphasis means
/// (`*italic*`, `**bold**`, `***both***`, plus nesting). Asterisk-only by
/// design: underscore is emphasis in Markdown but underline in Fountain, so it
/// is each grammar's own concern. Unbalanced/pathological runs render literal.
public enum InlineEmphasisScanner {

    public static func scan(_ text: NSString) -> EmphasisScan {
        let n = text.length
        let star = UInt16(UnicodeScalar("*").value)

        // 1. Collect asterisk runs.
        struct AsteriskRun { let location: Int; let length: Int }
        var astRuns: [AsteriskRun] = []
        var i = 0
        while i < n {
            if text.character(at: i) == star {
                let start = i
                while i < n && text.character(at: i) == star { i += 1 }
                astRuns.append(AsteriskRun(location: start, length: i - start))
            } else {
                i += 1
            }
        }
        if astRuns.isEmpty { return EmphasisScan(runs: [], markers: []) }

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
        }
        var delims: [Delim] = astRuns.map { r in
            let leftFlanking = !isSpace(r.location + r.length) // non-space after
            let rightFlanking = !isSpace(r.location - 1)       // non-space before
            return Delim(location: r.location, original: r.length,
                         remaining: r.length,
                         canOpen: leftFlanking, canClose: rightFlanking)
        }

        // 3. Delimiter-stack matching. Emit nested emphasis spans (content may
        //    cover inner markers — that is fine, they are excluded at flatten
        //    time) and collect every consumed asterisk as a marker.
        struct Emph { let range: NSRange; let bold: Bool }
        var emphases: [Emph] = []
        var markerRanges: [NSRange] = []

        var closerIdx = 0
        while closerIdx < delims.count {
            guard delims[closerIdx].canClose, delims[closerIdx].remaining > 0 else {
                closerIdx += 1; continue
            }
            var openerIdx = closerIdx - 1
            var matchedThisCloser = false
            while openerIdx >= 0 {
                if delims[openerIdx].canOpen, delims[openerIdx].remaining > 0 {
                    let use = (delims[openerIdx].remaining >= 2
                               && delims[closerIdx].remaining >= 2) ? 2 : 1
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
                            bold: use == 2))
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
        for e in emphases {
            let trait: EmphasisTraits = e.bold ? .bold : .italic
            for idx in e.range.location ..< (e.range.location + e.range.length) {
                perIndex[idx].insert(trait)
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

        return EmphasisScan(runs: runs, markers: markers)
    }
}
