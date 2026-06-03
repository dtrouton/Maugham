import XCTest
@testable import MaughamCore

/// CONTRACT: the shared `InlineEmphasisScanner` must agree with Apple's
/// CommonMark parser (which the phone markdown reader uses) on the canonical
/// cases. If a future macOS changes Apple's parser, this fails — telling us the
/// phone reader has drifted from the contract.
final class InlineEmphasisAppleParityTests: XCTestCase {

    /// Traits Apple assigns to each character of `s`, by inline presentation
    /// intent, with marker characters removed (Apple strips them).
    private func appleTraitsPerVisibleChar(_ s: String) -> [EmphasisTraits] {
        let attr = try! AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        var out: [EmphasisTraits] = []
        for run in attr.runs {
            let intent = run.inlinePresentationIntent ?? []
            var t: EmphasisTraits = []
            if intent.contains(.emphasized) { t.insert(.italic) }
            if intent.contains(.stronglyEmphasized) { t.insert(.bold) }
            let count = attr[run.range].characters.count
            out.append(contentsOf: Array(repeating: t, count: count))
        }
        return out
    }

    /// Traits our scanner assigns to each non-marker character of `s`.
    private func scannerTraitsPerVisibleChar(_ s: String) -> [EmphasisTraits] {
        let ns = s as NSString
        let scan = InlineEmphasisScanner.scan(ns)
        var perIndex = [EmphasisTraits?](repeating: EmphasisTraits(), count: ns.length)
        var markerSet = Set<Int>()
        for m in scan.markers {
            for i in m.location ..< (m.location + m.length) { markerSet.insert(i); perIndex[i] = nil }
        }
        for r in scan.runs {
            for i in r.range.location ..< (r.range.location + r.range.length) {
                if perIndex[i] != nil { perIndex[i] = r.traits }
            }
        }
        return perIndex.compactMap { $0 }
    }

    func testParityOnCanonicalCases() {
        for s in ["*x*", "**x**", "***x***", "*a **b** a*", "**a *b* a**", "plain words"] {
            XCTAssertEqual(scannerTraitsPerVisibleChar(s), appleTraitsPerVisibleChar(s),
                           "scanner and Apple disagree on \(s)")
        }
    }
}
