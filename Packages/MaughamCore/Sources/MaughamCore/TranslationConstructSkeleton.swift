import Foundation

/// Cheap structural fingerprint used to warn when a translation drops or adds
/// markdown constructs (a lost `**bold**` speaker label silently reclassifies
/// typography downstream). Warning tier only — never blocks a write.
public struct ConstructSkeleton: Equatable {
    public let blockKinds: [String]
    public let strongCount: Int
    public let emphCount: Int

    public static func of(_ text: String) -> ConstructSkeleton {
        let stripped = MarkdownDisplayFilter.stripAnchors(text)
        let blocks = MarkdownBlockParser.parse(stripped)
        // Block kind = the case name of each parsed block. MarkdownBlock has no
        // separate discriminator property, and every case name precedes its
        // first "(" in the mirror description (including the indirect
        // `blockquote` case), so this is stable without needing one.
        let kinds = blocks.map { String(describing: $0).components(separatedBy: "(")[0] }
        // Delimiter counting: "**"/"__" pairs = strong; leftover single "*"/"_"
        // flanked by non-space = emph. Deliberately dumb and deterministic.
        func counts(_ s: String) -> (strong: Int, emph: Int) {
            var strong = 0, emphMarkers = 0
            let chars = Array(s)
            var i = 0
            while i < chars.count {
                if chars[i] == "*" || chars[i] == "_" {
                    if i + 1 < chars.count, chars[i + 1] == chars[i] {
                        strong += 1; i += 2; continue
                    }
                    emphMarkers += 1
                }
                i += 1
            }
            return (strong / 2, emphMarkers / 2)
        }
        let c = counts(stripped)
        return ConstructSkeleton(blockKinds: kinds, strongCount: c.strong, emphCount: c.emph)
    }

    public static func warnings(source: String, translation: String,
                                paragraphId: String) -> [String] {
        let s = of(source), t = of(translation)
        var out: [String] = []
        if s.blockKinds != t.blockKinds {
            out.append("¶\(paragraphId): block structure changed (source \(s.blockKinds) → translation \(t.blockKinds))")
        }
        if s.strongCount != t.strongCount {
            out.append("¶\(paragraphId): **strong** run count changed (\(s.strongCount) → \(t.strongCount))")
        }
        if s.emphCount != t.emphCount {
            out.append("¶\(paragraphId): *emphasis* run count changed (\(s.emphCount) → \(t.emphCount))")
        }
        return out
    }
}
