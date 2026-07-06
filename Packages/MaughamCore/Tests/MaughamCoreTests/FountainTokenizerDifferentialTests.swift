import XCTest
@testable import MaughamCore

/// M1 differential oracle: the buffer-rewritten FountainTokenizer must
/// produce EXACTLY the FountainScript the pre-rewrite tokenizer produced,
/// over a corpus chosen to stress every grammar facet and every line-break
/// form NSString's .byLines recognizes. The reference is a verbatim frozen
/// copy — see FountainTokenizerReference.swift.
final class FountainTokenizerDifferentialTests: XCTestCase {

    private func assertParity(_ text: String, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let new = FountainTokenizer().parse(text)
        let ref = FountainTokenizerReference().parse(text)
        // Compare field-by-field on first divergence for a debuggable failure.
        XCTAssertEqual(new.titlePage, ref.titlePage, "titlePage [\(label)]",
                       file: file, line: line)
        XCTAssertEqual(new.lines.count, ref.lines.count, "line count [\(label)]",
                       file: file, line: line)
        for (i, (n, r)) in zip(new.lines, ref.lines).enumerated() where n != r {
            XCTFail("""
            line \(i) diverged [\(label)]
              new: \(n)
              ref: \(r)
            """, file: file, line: line)
            return
        }
        XCTAssertEqual(new, ref, "whole-script equality [\(label)]",
                       file: file, line: line)
    }

    // -- Grammar-facet corpus (hand-built, deterministic) --

    func test_grammarFacets() {
        let cases: [(String, String)] = [
            ("empty", ""),
            ("blank-only", "\n\n  \n\t\n"),
            ("single line", "Just one action line."),
            ("scene + action + cue + dialogue", """
            INT. KITCHEN - DAY

            She pours the coffee.

            MIRANDA
            (quietly)
            It's cold.
            """),
            ("dual dialogue", """
            BARRY
            I said wait.

            MIRANDA ^
            (overlapping)
            And I said no.
            """),
            ("forced elements", """
            @lowercase character
            !FORCED ACTION
            .forced scene
            > FORCED TRANSITION
            ~lyric line
            > centered text <
            """),
            ("sections + synopsis", "# Act One\n## Sequence\n= the gist\n"),
            ("transitions", "CUT TO:\n\nSMASH CUT TO:\n"),
            ("boneyard block", "Action.\n/* cut this\nstill cut\n*/ tail\nAfter."),
            ("note block", "Action.\n[[note opens\nstill note]]\nAfter."),
            ("inline emphasis + notes", "He *runs* and **jumps** _hard_ [[beat]] now."),
            ("title page", """
            Title: Operation Midnight
            Author: D. T.
            Draft date: 2026

            FADE IN:

            INT. LAB - NIGHT
            """),
            ("page break", "Action.\n\n===\n\nMore action."),
            ("uppercase action vs cue ambiguity", "DOOR SLAMS.\n\nBARRY\nWhat?"),
            ("trailing-^ same-length overtype shape", "BARRY X\nDialogue line."),
            ("whitespace-indented anchors", "   INT. PAD - DAY\n\n\tAction tab-led."),
        ]
        for (label, text) in cases { assertParity(text, label) }
    }

    // -- Held blank line (Task 13): two-space line inside a dialogue block --

    func test_heldBlankInDialogue() {
        let cases: [(String, String)] = [
            ("basic held blank", "DAN\nThen.\n  \nWhaddya want?\n"),
            ("empty line still ends dialogue", "DAN\nThen.\n\nAction now.\n"),
            ("held blank after parenthetical", "DAN\n(beat)\nThen.\n  \nMore."),
            ("held blank then scene-heading-shaped line stays dialogue",
             "DAN\nThen.\n  \nINT. HOUSE - DAY"),
            ("held blank then all-caps-shaped line stays dialogue",
             "DAN\nThen.\n  \nSTEVE"),
            ("held blank across dual-second block",
             "BRICK\nHi.\n\nSTEVE ^\nThen.\n  \nMore."),
            ("held blank outside dialogue is plain blank action",
             "Action one.\n  \nAction two."),
            ("tab-only held line", "DAN\nThen.\n\t\nMore."),
            ("multiple held blanks in a row", "DAN\nThen.\n  \n  \nMore."),
            ("held blank immediately after cue", "DAN\n  \nThen."),
        ]
        for (label, text) in cases { assertParity(text, label) }
    }

    // -- Line-separator zoo: .byLines recognizes \n \r \r\n NEL LS PS --

    func test_lineSeparatorZoo() {
        let seps = ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"]
        let body = ["INT. HALL - DAY", "", "Action one.", "BARRY", "Hi.", ""]
        for sep in seps {
            assertParity(body.joined(separator: sep), "sep \(sep.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined())")
        }
        // Mixed separators in one document.
        assertParity("INT. A - DAY\r\nAction.\rBARRY\u{2028}Hi.\u{0085}Bye.\n", "mixed seps")
    }

    // -- Unicode content: non-ASCII must defer to Foundation identically --

    func test_unicodeContent() {
        let cases: [(String, String)] = [
            ("NBSP padding", "\u{00A0}INT. CAFÉ - DAY\u{00A0}\n\nÉmile sips.\n"),
            ("emoji + CJK", "她说 🎬\n\nBARRY\n你好 *世界*\n"),
            ("ZWSP in cue", "BAR\u{200B}RY\nLine.\n"),
            ("combining marks", "Cafe\u{0301} scene description.\n"),
            // dotless ı (U+0131) uppercases to "I" — a non-ASCII line whose
            // uppercased() form matches a scene-heading prefix. Pins that the
            // ASCII fast paths defer to uppercased() for non-ASCII lines.
            ("dotless-i scene prefix", "\u{0131}nt. room - day\n\nAction.\n"),
            ("dotless-i transition suffix", "\n\nCU\u{0131} TO:\n"),
        ]
        for (label, text) in cases { assertParity(text, label) }
    }

    // -- Scene numbers (Task 11): trailing `#<id>#` on scene headings --

    func test_sceneNumbers() {
        let cases: [(String, String)] = [
            ("contextual + number", "INT. HOUSE - DAY #4A#\n\nAction.\n"),
            ("forced + number", ".ROOFTOP #12#\n\nAction.\n"),
            ("alnum-dot-dash id", "EXT. STREET - NIGHT #1.A-2#\n"),
            ("trailing spaces after marker", "INT. HOUSE - DAY #7#   \n"),
            ("no number", "INT. HOUSE - DAY\n"),
            ("empty bracket ##", "INT. HOUSE - DAY ##\n"),
            ("space in bracket", "INT. HOUSE - DAY #1 #\n"),
            ("marker not at end", "INT. HOUSE #4A# - DAY\n"),
            ("hash section not scene number", "# Act One\n"),
            ("action hash suffix", "He wrote #1# on the wall.\n"),
            ("non-ascii heading + number", "INT. CAFÉ - DAY #4A#\n"),
            ("number + emphasis in heading", "INT. HOUSE - *DAY* #4A#\n"),
            ("CRLF + number", "INT. HALL - DAY #9#\r\nAction.\r\n"),
        ]
        for (label, text) in cases { assertParity(text, label) }
    }

    // -- Dot-less scene stems (Task 12): stem + `.`-or-space delimiter --

    func test_dotlessSceneStems() {
        let cases: [(String, String)] = [
            ("space form INT", "INT ROOM - DAY\n\nAction.\n"),
            ("space form I/E", "I/E CAR - NIGHT\n\nAction.\n"),
            ("dotted EXT/INT", "EXT/INT. HOUSE\n\nAction.\n"),
            ("space form INT/EXT", "INT/EXT WAREHOUSE - DAWN\n"),
            ("dot alone", "INT.\n\nAction.\n"),
            ("bare stem (not heading)", "INT\n\nAction.\n"),
            ("space nothing after", "INT \n\nAction.\n"),
            ("longer word INTERIOR", "INTERIOR SHOT\n\nAction.\n"),
            ("mixed case Int room", "Int room\n\nAction.\n"),
            ("lowercase int room", "int room\n\nAction.\n"),
            ("lowercase interesting prose", "Interesting things happened.\n"),
            ("mid-paragraph not heading", "He yelled.\nINT ROOM - DAY\n"),
            ("non-ascii dotless stem", "INT CAFÉ - DAY\n\nÉmile sips.\n"),
            ("EST space form", "EST MEADOW - DAWN\n"),
            ("tab after dot not heading", "INT.\tROOM\n"),
        ]
        for (label, text) in cases { assertParity(text, label) }
    }

    // -- Randomized generative corpus (seeded; catches what we didn't think of) --

    func test_randomizedScripts() {
        var rng = SplitMix64(seed: 0xF0DA)
        for round in 0..<60 {
            var lines: [String] = []
            let n = 20 + Int(rng.next() % 180)
            for _ in 0..<n {
                switch rng.next() % 15 {
                case 0:
                    // Sometimes a trailing scene-number bracket (Task 11),
                    // occasionally malformed so the non-match paths get exercised.
                    // Vary the slugline opener across dotted and dot-less stem
                    // forms (Task 12) so both delimiter paths are stressed.
                    let opener = ["INT.", "EXT.", "INT", "EXT", "I/E", "INT/EXT",
                                  "EXT/INT.", "EST", "INTERIOR"][Int(rng.next() % 9)]
                    let stem = "\(opener) LOC\(rng.next() % 50) - DAY"
                    switch rng.next() % 5 {
                    case 0: lines.append(stem + " #\(rng.next() % 200)#")
                    case 1: lines.append(stem + " #\(rng.next() % 20)A-\(rng.next() % 9)#")
                    case 2: lines.append(stem + " ##")
                    case 3: lines.append(stem + " #\(rng.next() % 10) #")
                    default: lines.append(stem)
                    }
                case 1: lines.append("")
                case 2: lines.append("CHARACTER\(rng.next() % 9)" + (rng.next() % 4 == 0 ? " ^" : ""))
                case 3: lines.append("(beat)")
                case 4: lines.append("Some dialogue or action text \(rng.next() % 1000).")
                case 5: lines.append("CUT TO:")
                case 6: lines.append("> centered <")
                case 7: lines.append("!Forced action \(rng.next() % 10)")
                case 8: lines.append("# Section \(rng.next() % 5)")
                case 9: lines.append("/* bone \(rng.next() % 10)")
                case 10: lines.append("*/")
                case 11: lines.append("[[note \(rng.next() % 10)]]")
                case 12: lines.append("Text with *emph\(rng.next() % 10)* inline.")
                case 13: lines.append("  ")   // two-space held-blank candidate
                default: lines.append("   indented action \(rng.next() % 10)")
                }
            }
            let sep = ["\n", "\r\n", "\n", "\n"][Int(rng.next() % 4)]
            assertParity(lines.joined(separator: sep), "random round \(round)")
        }
    }

    // -- The real fixture chunks, when staged --

    func test_probeChunksParity() throws {
        let dir = URL(fileURLWithPath: "/tmp/maugham-perf-probe")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              !names.filter({ $0.hasSuffix(".fountain") }).isEmpty else {
            throw XCTSkip("probe chunks not staged")
        }
        var combined = ""
        for n in names.sorted() where n.hasSuffix(".fountain") {
            combined += (try String(contentsOf: dir.appendingPathComponent(n),
                                    encoding: .utf8)) + "\n\n"
        }
        assertParity(combined, "10-chunk fixture")
    }
}

/// Tiny seeded RNG (SplitMix64) — Date/seedless RNG are banned in tests
/// that must reproduce across machines.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
