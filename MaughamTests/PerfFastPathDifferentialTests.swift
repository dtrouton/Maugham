import XCTest
@testable import Maugham
@testable import MaughamCore

/// Differential tests pinning the perf fix C fast paths to the exact behavior
/// of the Foundation implementations they replace:
///   C1 — `ParagraphParser.parse` (ASCII fast scan + `<!--` anchor pre-check)
///        vs a verbatim copy of the pre-fix implementation (`parseReference`).
///   C3 — `FountainTokenizer.fastTrimWhitespaces` vs
///        `String.trimmingCharacters(in: .whitespaces)`, and the underline
///        pre-check vs the unconditional `_…_` regex, over the same corpus.
///   Whole-tokenizer output equivalence is covered by the unmodified
///   `FountainTokenizerTests` etc.; here we additionally drive the corpus
///   through the real tokenizer to assert it doesn't crash / drift on the
///   pathological + unicode inputs.
final class PerfFastPathDifferentialTests: XCTestCase {

    // MARK: - Reference (pre-fix) ParagraphParser

    /// Verbatim copy of the ParagraphParser.parse implementation prior to the
    /// C1 fast path. Kept in the TEST target only as the differential oracle.
    private static func parseReference(_ markdown: String) -> [ParsedParagraph] {
        var result: [ParsedParagraph] = []
        var pendingId: String? = nil
        var buffer: [String] = []

        func flushParagraph() {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !text.isEmpty {
                result.append(ParsedParagraph(id: pendingId, text: text))
            }
            buffer.removeAll(keepingCapacity: true)
            pendingId = nil
        }

        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for line in lines {
            let s = String(line)
            if s.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }
            if let id = ParagraphID.parseComment(s) {
                flushParagraph()
                pendingId = id
                continue
            }
            buffer.append(s)
        }
        flushParagraph()
        return result
    }

    // MARK: - Corpus

    /// Build a deterministic-ish randomized corpus of documents exercising the
    /// fast paths: anchors, task anchors, unicode whitespace, emoji, CJK,
    /// pathological blank lines, comment-only docs, the empty doc, and the real
    /// probe chunks if present.
    private func corpus() -> [String] {
        var docs: [String] = []

        // Edge cases.
        docs.append("")
        docs.append("\n")
        docs.append("\n\n\n")
        docs.append("   \n\t\n  \t ")                       // pure ascii blanks
        docs.append("\u{00A0}\n\u{2003}\n\u{2009}")          // unicode-space-only lines (NBSP, em, thin)
        docs.append("<!-- ¶ab2c -->")                        // comment-only
        docs.append("<!-- ¶ab2c -->\n\nHello.")
        docs.append("  <!-- ¶ab2c -->  \n\nIndented anchor.")
        docs.append("<!-- not an anchor -->\n\nKept comment.")
        docs.append("line with <!-- ¶ab2c --> mid")         // not own-line → not stripped
        docs.append("Task line [[todo: x]]<!--t-ab2c3d--> rest")
        docs.append("\u{00A0}<!-- ¶ab2c -->\n\nNBSP before anchor.")
        docs.append("Naïve café résumé.\n\nSecond para 日本語 中文.\n\n🎉 emoji para 👩‍👩‍👧.")
        docs.append("First.\nSecond line same para.\n\nThird.")
        docs.append("\t\t<!-- ¶c4d5 -->\n\ntab-indented anchor")
        docs.append("trailing spaces here   \n\nand here\t\t")

        // Randomized assembly.
        var rng = SystemRandomNumberGenerator()
        let snippets = [
            "Plain action line.", "  leading space line", "trailing space   ",
            "<!-- ¶q9rs -->", "<!-- ¶0000 -->", "<!-- bogus -->",
            "INT. ROOM - DAY", "ALICE", "Some dialogue here.",
            "[[todo: do it]]<!--t-abc123-->", "café \u{00A0} résumé",
            "中文 line", "🎈 party", "", "\t", "   ", "\u{2003}",
            "# Section one", "= Synopsis", "> CUT TO:",
            "- [ ] a checkbox <!--t-9z8y7x-->",
        ]
        for _ in 0..<300 {
            let n = Int.random(in: 0...18, using: &rng)
            var lines: [String] = []
            for _ in 0..<n {
                lines.append(snippets.randomElement(using: &rng)!)
            }
            docs.append(lines.joined(separator: "\n"))
        }

        // Real probe chunks if available.
        let dir = URL(fileURLWithPath: "/tmp/maugham-perf-probe")
        for i in 1...10 {
            let name = String(format: "chunk-%02d.fountain", i)
            if let s = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) {
                docs.append(s)
            }
        }
        return docs
    }

    // MARK: - C1 differential

    func test_C1_paragraphParser_matchesReference_overCorpus() {
        for doc in corpus() {
            let got = ParagraphParser.parse(doc)
            let want = Self.parseReference(doc)
            XCTAssertEqual(got, want, "ParagraphParser diverged for doc:\n\(doc.debugDescription)")
        }
    }

    // MARK: - C3 differential

    func test_C3_fastTrimWhitespaces_matchesFoundation_overLines() {
        // Every distinct line across the corpus, plus targeted unicode-ws cases.
        var lines: Set<String> = [
            "", " ", "\t", "  \t  ", "x", " x ", "\tx\t", "x ",
            "\u{00A0}", "\u{00A0}x\u{00A0}", "café", " café ",
            "\u{2003}\u{2009}", "  \u{00A0}  ", "日本語", " 日本語 ",
            "🎉", " 🎉 ", "a\u{00A0}b", "\t café \t",
        ]
        for doc in corpus() {
            for line in doc.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                lines.insert(String(line))
            }
        }
        for line in lines {
            let got = FountainTokenizer.fastTrimWhitespaces(line)
            let want = line.trimmingCharacters(in: .whitespaces)
            XCTAssertEqual(got, want, "fastTrimWhitespaces diverged for \(line.debugDescription)")
        }
    }

    func test_C3_underlinePrecheck_agreesWithRegex_overLines() {
        // The pre-check (>=2 underscores) must be a sound gate: whenever the
        // unconditional regex would find a match, the gate must be open.
        let regex = try! NSRegularExpression(pattern: #"_([^_\n]+)_"#)
        func regexMatches(_ s: String) -> Bool {
            let ns = s as NSString
            return regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
        }
        func gateOpen(_ s: String) -> Bool {
            var c = 0
            for b in s.utf8 where b == 0x5F { c += 1; if c >= 2 { return true } }
            return false
        }
        var lines: Set<String> = [
            "_a_", "a_b_c", "no underscores", "_", "__", "_x", "x_",
            "_underline_ and _more_", "a_b", "___", "_ _",
        ]
        for doc in corpus() {
            for line in doc.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                lines.insert(String(line))
            }
        }
        for line in lines {
            if regexMatches(line) {
                XCTAssertTrue(gateOpen(line),
                    "underline gate closed but regex matches: \(line.debugDescription)")
            }
        }
    }

    func test_C3_tokenizer_runsCleanOverCorpus() {
        // Smoke: the real tokenizer parses every corpus doc without crashing.
        let tok = FountainTokenizer()
        for doc in corpus() {
            _ = tok.parse(doc)
        }
    }
}
