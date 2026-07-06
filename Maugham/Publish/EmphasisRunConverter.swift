import Foundation
import MaughamCore

/// A span the surrounding grammar has already resolved into a finished inline
/// node (inline code, a wiki link, a hard break, a Fountain underline). The
/// converter treats these as opaque: it masks the range so the emphasis scanner
/// can't reach inside it, and re-emits `node` verbatim at the range's start.
struct ProtectedSpan {
    let range: NSRange
    let node: ProjectAST.Inline
}

/// Turns a block of source text into `[ProjectAST.Inline]` by delegating all
/// asterisk (and optional GFM tilde) emphasis to the shared
/// `InlineEmphasisScanner` — the single source of truth for what emphasis means
/// — and layering the grammar-specific protected spans on top.
///
/// The scanner reports FLATTENED cumulative-trait runs, so the output is flat
/// too: a `*em **bold** em*` span becomes sibling runs each wrapped by its own
/// cumulative traits rather than a nested tree. Emitters flatten anyway, so the
/// rendered result is identical.
enum EmphasisRunConverter {

    /// Mask each protected range with length-preserving `x` placeholders (so
    /// flanking around code spans / wiki links stays stable), scan the masked
    /// text, then walk every index emitting: the protected node at its start,
    /// nothing for marker/escape-backslash indices, and grouped trait runs for
    /// the rest. Escaped delimiters emit WITHOUT the backslash (publish strips
    /// it).
    static func inlines(for text: String,
                        options: InlineEmphasisScanner.Options,
                        protected: [ProtectedSpan]) -> [ProjectAST.Inline] {
        let ns = text as NSString
        let n = ns.length
        if n == 0 { return [] }

        let masked = NSMutableString(string: ns)
        for span in protected {
            masked.replaceCharacters(in: span.range,
                                     with: String(repeating: "x", count: span.range.length))
        }

        let scan = InlineEmphasisScanner.scan(masked, options: options)

        var traitsAt = [EmphasisTraits](repeating: [], count: n)
        for run in scan.runs {
            for idx in run.range.location ..< (run.range.location + run.range.length) {
                traitsAt[idx] = run.traits
            }
        }
        var skip = Set<Int>()            // marker + escape-backslash indices
        for r in scan.markers + scan.escapes {
            for idx in r.location ..< (r.location + r.length) { skip.insert(idx) }
        }
        var protectedAt = [Int: ProtectedSpan]()
        for span in protected { protectedAt[span.range.location] = span }

        var out: [ProjectAST.Inline] = []
        // The buffer is accumulated as UTF-16 sub-ranges rather than by
        // appending length-1 substrings: a skipped marker/escape index between
        // two same-trait chars leaves a gap (a new sub-range), and — crucially —
        // extracting whole sub-ranges never splits a surrogate pair the way
        // char-by-char slicing would (emoji / non-BMP text stays intact).
        var bufferRanges: [NSRange] = []
        var bufferTraits: EmphasisTraits = []

        func flush() {
            guard !bufferRanges.isEmpty else { return }
            let text = bufferRanges.map { ns.substring(with: $0) }.joined()
            out.append(materialize(text, traits: bufferTraits))
            bufferRanges = []
        }

        func appendIndex(_ i: Int, _ traits: EmphasisTraits) {
            if !bufferRanges.isEmpty && traits != bufferTraits { flush() }
            if bufferRanges.isEmpty { bufferTraits = traits }
            if var last = bufferRanges.last, last.location + last.length == i {
                last.length += 1
                bufferRanges[bufferRanges.count - 1] = last
            } else {
                bufferRanges.append(NSRange(location: i, length: 1))
            }
        }

        var i = 0
        while i < n {
            if let span = protectedAt[i] {
                flush()
                out.append(span.node)
                i = span.range.location + span.range.length
                continue
            }
            if skip.contains(i) { i += 1; continue }
            appendIndex(i, traitsAt[i])
            i += 1
        }
        flush()
        return out
    }

    /// Wrap `text` in the cumulative traits, innermost-first so the finished
    /// nesting is `.strikethrough` outermost, then `.strong`, then `.emphasis`.
    private static func materialize(_ text: String, traits: EmphasisTraits) -> ProjectAST.Inline {
        var node: ProjectAST.Inline = .text(text)
        if traits.contains(.italic)        { node = .emphasis([node]) }
        if traits.contains(.bold)          { node = .strong([node]) }
        if traits.contains(.strikethrough) { node = .strikethrough([node]) }
        return node
    }
}
