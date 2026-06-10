# Typing Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-keystroke total ≤ 16 ms at 120 pp and ≤ 50 ms at 250 pp (Debug), pause-edge hitch ≤ 30 ms — by rewriting the two whole-doc scanners as single UTF-16/UTF-8 buffer passes, deleting the pause-edge re-parse, and bounding gutter draws to the visible range.

**Architecture:** Spec `docs/superpowers/specs/2026-06-10-typing-perf-design.md` (decisions §2 are binding: C-bar, no editor-contract changes, UTF-16 buffer for the tokenizer, metrics from the existing parse). Every scanner rewrite is pinned by a verbatim-reference differential oracle — **for the two rewrites (Tasks 3, 5) the oracle + porting procedure IS the spec; this plan deliberately does not pre-write the ported grammar code** (a blind 500-line port in a plan document maximizes drift risk; the harness arbitrates). All other tasks carry complete code as usual.

**Tech Stack:** Swift, XCTest, the committed probe (`MaughamTests/Performance/TypingLatencyProbeTests`), `sample <pid>` live verification.

**Ground truth (verified 2026-06-10 at `e87da55`):**
- `FountainTokenizer.parse` (`Packages/MaughamCore/Sources/MaughamCore/FountainTokenizer.swift`, 690 lines) drives a per-line state machine (`prevBlank`, `prevElement`, `prevWasDualSecond`, `blockState` ∈ {normal, boneyard, noteBlock}) via `nsText.enumerateSubstrings(in:options:.byLines)` — the live profile's hot frames are the enumerator thunk + per-line `String` materialization + `sourceCase`/`classify`/`inlineSpans`. Title page is a pre-pass (`parseTitlePage`) yielding `titlePageEndOffset`.
- `FountainLine` carries `range: NSRange` (UTF-16, includes trailing newline), `element`, `content` (trimmed, marker-stripped), `isForced`, `isDualSecond`, `sourceCase`, `inlineSpans` — all `Equatable`.
- `NSString` `.byLines` recognizes `\n`, `\r`, `\r\n`, U+0085 NEL, U+2028 LS, U+2029 PS. `Character.isNewline` (used by `ParagraphParser`) recognizes the same set. **The buffer scanners must reproduce this exactly; the differential corpora must include all six.**
- `ElementGutterView.draw` (`Maugham/Editor/ElementGutterView.swift:85-129`) iterates **every** `script.lines` per redraw — no dirty-rect/visible-range bound — calling `layoutManager.glyphRange` + `boundingRect` + `NSString.size` per labeled line. Spec OQ2 answered: M4 = visible-range bound + caches.
- `ProseMode.tokenize` delegates to the prose `Tokenizer` (`Maugham/Editor/Tokenizer/`); never measured at single-file scale. `ProseMode.metrics` is parse-free (cheap).
- Metrics plumbing today: `EditorHost.onTextChange` (debounced 350 ms via `metricsMirrorTask`, EditorHost.swift:45-54, cancel-on-doc-switch at `loadDocumentIfNeeded`) → `ProjectWindow.updateMetrics(for:)` (`ProjectWindow.swift:840-848`) → full `mode.metrics(text)` incl. Fountain re-parse. The coordinator already holds `lastParsedScript` per keystroke and already debounces the script broadcast (`scriptUpdateNotifyTask`, EditorCoordinator.swift:86-96).
- `makeContiguousUTF8` runs twice per keystroke: `textDidChange` (~:621) and `retokenizeAndStyle` (~:401).
- Build: `./gen.sh` after adding files. Test: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO [-only-testing:…]`; core: `cd Packages/MaughamCore && swift test`. MaughamCore changes ⇒ run the phone scheme too. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Milestone gates (spec §10):**

| Phase | Gate to start | Exit |
|---|---|---|
| M0 (Task 1) | — | per-item table at 120/250 pp + prose verdict recorded in `docs/superpowers/notes/2026-06-10-typing-perf-baseline.md` |
| M1 (Tasks 2–3) | M0 recorded | differential green; tokenizer ≤ 15 ms @ 250 pp Debug; all suites green both schemes |
| M2 (Tasks 4–6) | M1 | parser differential green; setFullText ≤ 8 ms @ 120 pp / ≤ 18 ms @ 250 pp |
| M3 (Task 7) | parallel-safe after M0 | zero non-keystroke whole-doc parses; pause-edge ≤ 30 ms |
| M4 (Task 8) | after M0 | gutter equivalence green; ≤ 1 ms/redraw @ 250 pp |
| Final (Task 9) | all | live `sample` at 120 + 250 pp within budgets; user smoke |

---

## Task 1: M0 — probe extension + recorded baseline

**Files:**
- Modify: `MaughamTests/Performance/TypingLatencyProbeTests.swift`
- Create: `docs/superpowers/notes/2026-06-10-typing-perf-baseline.md` (from real output only)

- [ ] **Step 1: Stage fixture inputs.** The screenplay chunks live at `~/Desktop/maugham-smoke-screenplay/chunk-*.fountain`; copy all ten to `/tmp/maugham-perf-probe/` (the probe skips when absent — keep that contract).

- [ ] **Step 2: Add the per-item baseline test.** Append to `TypingLatencyProbeTests`:

```swift
    /// M0 of the typing-perf milestone (spec §4): per-item costs at 120 pp
    /// (5 chunks ≈ 250 KB) and 250 pp (10 chunks ≈ 500 KB), plus the
    /// pause-edge batch, plus a single-file PROSE case. Numbers land in
    /// docs/superpowers/notes/2026-06-10-typing-perf-baseline.md.
    func test_probe_typingPerfBaseline() async throws {
        for chunkCount in [5, 10] {
            let body = try loadChunks(count: chunkCount)   // helper below
            let (doc, projectURL) = try await makeDoc(body: body, ext: "fountain")
            defer { try? FileManager.default.removeItem(at: projectURL) }
            let clock = ContinuousClock()
            let text = doc.displayText

            // Tokenizer + token derivation (the keystroke's own parse).
            var t = clock.now
            let script = FountainTokenizer().parse(text)
            let tTok = clock.now - t
            let mode = ScreenplayMode()
            t = clock.now
            let tokens = mode.tokens(from: script, text: text)
            let tTokens = clock.now - t

            // setFullText median over 10 mid-doc single-char edits.
            var lat: [Duration] = []
            for _ in 0..<10 {
                var edited = doc.displayText
                let mid = edited.index(edited.startIndex, offsetBy: edited.count / 2)
                edited.insert("x", at: mid)
                t = clock.now
                doc.setFullText(edited)
                lat.append(clock.now - t)
            }
            lat.sort()

            // Display parse alone.
            t = clock.now
            _ = ParagraphParser.parse(doc.displayText)
            let tParse = clock.now - t

            // The double copy (one leg).
            var copyMe = doc.displayText
            t = clock.now
            copyMe.makeContiguousUTF8()
            let tCopy = clock.now - t

            // Pause-edge batch as it exists today: footer metrics (full
            // parse) + sceneSummaries + script deep-== (equal case).
            t = clock.now
            _ = mode.metrics(text)
            let tMetrics = clock.now - t
            t = clock.now
            _ = script.sceneSummaries()
            let tSummaries = clock.now - t
            let script2 = FountainTokenizer().parse(text)
            t = clock.now
            _ = (script == script2)
            let tEq = clock.now - t

            // Gutter per-line work proxy: the abbreviation + size lookups the
            // draw loop pays per labeled line (layout-manager cost excluded —
            // headless — which UNDERSTATES the real win; noted in the doc).
            t = clock.now
            var labelCount = 0
            for line in script.lines {
                if ElementGutterView.abbreviation(for: line.element) != nil {
                    labelCount += 1
                }
            }
            let tGutterScan = clock.now - t

            print("""
            ===== TYPING-PERF BASELINE — \(chunkCount) chunks =====
            bytes: \(text.utf8.count), lines: \(script.lines.count), labeled: \(labelCount)
            FountainTokenizer.parse:   \(tTok)
            ScreenplayMode.tokens:     \(tTokens)
            setFullText median:        \(lat[lat.count / 2])
            ParagraphParser.parse:     \(tParse)
            makeContiguousUTF8 (×1):   \(tCopy)
            pause-edge: metrics \(tMetrics) + summaries \(tSummaries) + script== \(tEq)
            gutter line scan (no layout): \(tGutterScan)
            ==============================================
            """)
            await doc.close()
        }

        // PROSE single-file case (~250 KB .md with wiki links + checkboxes).
        let prose = Self.generateProse(bytes: 250_000)
        let (pdoc, purl) = try await makeDoc(body: prose, ext: "md")
        defer { try? FileManager.default.removeItem(at: purl) }
        let clock = ContinuousClock()
        let pmode = ProseMode()
        var t = clock.now
        _ = pmode.tokenize(pdoc.displayText)
        let tProseTok = clock.now - t
        var plat: [Duration] = []
        for _ in 0..<10 {
            var edited = pdoc.displayText
            let mid = edited.index(edited.startIndex, offsetBy: edited.count / 2)
            edited.insert("x", at: mid)
            t = clock.now
            pdoc.setFullText(edited)
            plat.append(clock.now - t)
        }
        plat.sort()
        print("""
        ===== TYPING-PERF BASELINE — prose 250KB =====
        ProseMode.tokenize: \(tProseTok)
        setFullText median: \(plat[plat.count / 2])
        ==============================================
        """)
        await pdoc.close()
    }
```

Add the helpers (`loadChunks(count:)` reading `/tmp/maugham-perf-probe/chunk-NN.fountain` 1…count joined with `"\n\n"`, throwing `XCTSkip` when absent; `makeDoc(body:ext:)` extracting the temp-project + `Document.load` boilerplate the existing tests repeat; `static generateProse(bytes:)` building paragraphs from a lexicon with every 7th paragraph containing `[[Linked Note]]` and every 11th a `- [ ] task` line, until the byte budget is met). Reuse the existing file's patterns verbatim — read them first.

- [ ] **Step 3: Run.** `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/TypingLatencyProbeTests 2>&1 | tee /tmp/typing-perf-baseline.log` — expect PASS with three printed tables.

- [ ] **Step 4: Record.** Write `docs/superpowers/notes/2026-06-10-typing-perf-baseline.md`: tables verbatim; the spec-§4 budgets confirmed/adjusted; **the prose verdict** (spec §9 — if prose meets budgets, record "prose scanner work dropped" explicitly); spec OQ1 (utf16 shape) deferred to Task 3's first step; OQ2 answered (gutter has no visible-range bound — recorded as fact from code reading, `ElementGutterView.swift:110`).

- [ ] **Step 5: Commit.** `git add MaughamTests/Performance/TypingLatencyProbeTests.swift docs/superpowers/notes/2026-06-10-typing-perf-baseline.md && git commit -m "test(perf): typing-perf M0 — per-item baseline at 120/250pp + prose verdict"`

## Task 2: M1 differential oracle (the rewrite's real spec)

**Files:**
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/FountainTokenizerReference.swift`
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/FountainTokenizerDifferentialTests.swift`

- [ ] **Step 1: Freeze the oracle.** Copy the ENTIRE current `FountainTokenizer.swift` into `FountainTokenizerReference.swift` in the TEST target, renaming the type `FountainTokenizerReference` (and its private helpers' type prefix). Header comment: *"Verbatim copy of FountainTokenizer at e87da55 — the differential oracle for the M1 buffer rewrite. NEVER edit logic here; if the grammar must change, change BOTH and record why in the test."* It can reference `FountainScript`/`FountainLine`/`ScreenplayElement` etc. from the production module (those types are not being rewritten).

- [ ] **Step 2: Write the differential suite (complete code):**

```swift
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
                switch rng.next() % 14 {
                case 0: lines.append("INT. LOC\(rng.next() % 50) - DAY")
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
```

(`FountainScript`/`FountainLine` are `Equatable` — verified. If `titlePage`'s type isn't directly comparable, compare its fields; adapt minimally.)

- [ ] **Step 3: Run — green against the UNCHANGED tokenizer** (new == reference == same code): `cd Packages/MaughamCore && swift test --filter FountainTokenizerDifferential`. Expect PASS. This proves the harness; its value activates in Task 3.

- [ ] **Step 4: Commit.** `git add Packages/MaughamCore/Tests && git commit -m "test(core): M1 differential oracle — frozen reference tokenizer + grammar/separator/unicode/random corpus"`

## Task 3: M1 buffer rewrite of FountainTokenizer

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/FountainTokenizer.swift`

**This is the oracle-arbitrated task.** The deliverable is defined by: (a) the Task 2 suite green, (b) every existing Fountain/screenplay/windowed-typography test green UNMODIFIED, (c) the probe's tokenizer line ≤ 15 ms at 250 pp Debug. The implementation shape below is binding; the line-by-line grammar port is the implementer's job with the oracle as judge.

- [ ] **Step 1: Decide spec OQ1 with a 10-minute micro-bench** (in a scratch test, not committed): compare scanning `Array(text.utf16)` vs `text.utf16` direct indexing on a contiguous string at 500 KB. Pick the faster; record the numbers in the Task 6 baseline-note update.

- [ ] **Step 2: Introduce `LineRecord` + the line scanner, keeping classification untouched.** Shape:

```swift
    /// One physical line of the source, located by a single buffer pass.
    /// INTENT (spec §5.1): this is the seam a future INCREMENTAL tokenizer
    /// re-derives from — keep it a real type with explicit classification
    /// inputs, not an inlined implementation detail.
    struct LineRecord {
        let range: NSRange          // UTF-16, includes trailing terminator
        let contentRange: NSRange   // UTF-16, excludes terminator
        let trimmedRange: NSRange   // contentRange minus ASCII ws (or Foundation-trimmed)
        let isBlank: Bool
        let isASCII: Bool           // pure-ASCII content → fast classification paths
        let firstUnit: UInt16       // first trimmed code unit (0 when blank)
    }

    /// Single pass over the UTF-16 buffer producing LineRecords. Terminators
    /// recognized EXACTLY as NSString .byLines does: \n, \r, \r\n (one line),
    /// U+0085, U+2028, U+2029.
    static func scanLines(_ buffer: <chosen utf16 view>) -> [LineRecord]
```

First commit-able increment: `parse` builds `[LineRecord]` and uses it ONLY to drive the existing per-line logic (materializing the line `String` from the record's range exactly once, replacing `enumerateSubstrings`). Differential suite green at this point proves line-splitting parity in isolation — **run it before proceeding**.

- [ ] **Step 3: Port classification onto code units, facet by facet, oracle-green after EACH facet.** Order (each its own commit-able checkpoint, squashed or not at the implementer's discretion): blank/trim (use `trimmedRange` instead of string trim where ASCII) → forced-marker dispatch on `firstUnit` → `sourceCase` on code units (ASCII fast path, Foundation fallback per fix-C pattern) → scene-heading/transition prefix checks on code units → boneyard/note block states → dual `^` detection → `inlineSpans`/`scanNotes` (keep NSRange math; these already take `nsText` — they may keep NSString access where regex-bound, ONLY if the probe still meets the ≤ 15 ms exit; otherwise port their pre-checks too) → title-page pre-pass last (it's once-per-parse, port only if it shows up in the profile). Non-ASCII lines take the materialize-and-use-existing-logic fallback — semantics identical by construction, and the corpus' unicode cases pin it.

- [ ] **Step 4: Verify.** Differential suite + full core (`swift test`) + full Mac scheme + full phone scheme (core changed) + windowed-typography equivalence unmodified. Probe: tokenizer ≤ 15 ms @ 250 pp Debug (was ~89–96 ms).

- [ ] **Step 5: Commit.** `git add Packages/MaughamCore && git commit -m "perf(core): M1 FountainTokenizer buffer rewrite — single UTF-16 pass via LineRecord (oracle-pinned, ~6x)"` — include before/after numbers in the body.

## Task 4: M2a — ParagraphParser buffer pass

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ParagraphParser.swift`
- Modify: `MaughamTests/PerfFastPathDifferentialTests.swift` (corpus extension)

- [ ] **Step 1: Extend the existing differential corpus** (it already holds a verbatim `parseReference` from fix C — verify it still matches `git show 743cea6^:…/ParagraphParser.swift`-era semantics, i.e. the CURRENT behavior, since fix C was semantics-preserving): add the six-separator zoo (as in Task 2), mixed separators, NEL/LS/PS around anchor comments, and a 1,000-paragraph generated doc. Run — green against current.

- [ ] **Step 2: Rewrite `parse` as a single UTF-8 byte-buffer pass** (paragraph splitting is byte-friendly: blank-line detection + `<!--` anchor pre-check are ASCII; **the newline SET must match `Character.isNewline`** — \n \r \r\n NEL LS PS, where NEL/LS/PS are multi-byte UTF-8 sequences to match explicitly). Non-ASCII lines: same defer-to-existing-logic fallback pattern. Output `[ParsedParagraph]` strings materialized once per paragraph from byte ranges (`String(decoding:as: UTF8.self)` on the slice).

- [ ] **Step 3: Verify.** Differential + full core + Mac + phone (`ParagraphParser` feeds Bootstrap/RenderFilter/phone readers). Probe: display-parse line at 250 pp ≤ 4 ms (was ~37 ms post-fix-C at 500 KB).

- [ ] **Step 4: Commit.** `perf(core): M2 ParagraphParser single-buffer pass (oracle-pinned)`

## Task 5: M2b — single nativization

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`

- [ ] **Step 1:** Change `retokenizeAndStyle(windowedTyping: Bool = false)` → `retokenizeAndStyle(windowedTyping: Bool = false, nativizedText: String? = nil)`:

```swift
        // One nativization per keystroke: textDidChange nativizes once and
        // threads the SAME string here (it is byte-identical to
        // textView.string — assigned in the same MainActor slice with no
        // intervening edit). Other callers (attach, applyExternalText, theme)
        // pass nil and self-nativize. The windowed-diff storageLength guard
        // still falls back to whole-doc on any mismatch.
        var text: String
        if let nativizedText {
            text = nativizedText
        } else {
            text = textView.string
            text.makeContiguousUTF8()
        }
```

and in `textDidChange`, pass the already-nativized `editedText`: `retokenizeAndStyle(windowedTyping: true, nativizedText: editedText)`.

- [ ] **Step 2:** Run `EditorIntegrationHarnessTests`, `WindowedTypographyEquivalenceTests`, `ScreenplaySingleParseTests`, then the full Mac scheme. Commit: `perf(editor): M2 single nativization per keystroke`.

## Task 6: M2 close-out — probe re-run + baseline note update

- [ ] Re-run the Task 1 probe; append "## After M1+M2" tables to the baseline note (plus the OQ1 micro-bench numbers from Task 3). Verify gates: setFullText ≤ 8 ms @ 120 pp / ≤ 18 ms @ 250 pp; tokenizer ≤ 15 ms @ 250 pp. Commit the note update.

## Task 7: M3 — metrics from the existing parse + coalesced pause-edge

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`
- Modify: `Maugham/Views/EditorHost.swift`
- Modify: `Maugham/Views/ProjectWindow.swift` (helper + call site ONLY — not `body`; if `body` must change shape, run a local Release build before commit per CLAUDE.md)
- Modify: `Packages/MaughamCore/Sources/MaughamCore/FountainScript.swift` (Equatable pre-check)
- Create: `MaughamTests/Editor/CoordinatorMetricsTests.swift`

- [ ] **Step 1: Coordinator computes + delivers metrics on the EXISTING debounced trailing edge.** Add to `EditorCoordinator`:

```swift
    /// Fired with precomputed metrics on the same debounced trailing edge as
    /// the script broadcast (typing path), and immediately on attach /
    /// applyExternalText. Consumers (ProjectWindow inspector + goal
    /// indicator) do ZERO parsing — the page count comes from the keystroke's
    /// own parse (`lastParsedScript`), the word count from one whitespace
    /// split of the already-nativized text (spec §7; supersedes the
    /// EditorHost metrics mirror, which this replaces).
    var onMetricsChanged: ((EditorMetrics) -> Void)?

    private func computeMetrics(text: String) -> EditorMetrics {
        if let script = lastParsedScript {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = trimmed.isEmpty
                ? 0 : trimmed.split(whereSeparator: \.isWhitespace).count
            return EditorMetrics(
                wordCount: words,
                characterCount: (text as NSString).length,
                readingMinutes: words / ScreenplayMode.wordsPerMinute,
                pageCount: script.estimatedPageCount)
        }
        return mode.metrics(text)   // prose: parse-free already
    }
```

(Check `ScreenplayMode.wordsPerMinute` visibility — make it `static let` internal if needed; check `EditorMetrics`'s memberwise init labels against the real type and adapt.) Deliver: inside the debounced `scriptUpdateNotifyTask` firing AND the immediate (non-debounced) post path, call `onMetricsChanged?(computeMetrics(text: <the text that produced lastParsedScript>))` — thread the text through rather than re-reading `textView.string` on the trailing edge (capture it where the task is armed).

- [ ] **Step 2: Replace the plumbing.** `EditorSurface` gains `onMetricsChanged` wired to the coordinator (mirror how `onElementChanged` is plumbed — read it first). `EditorHost`: replace `onTextChange: ((String) -> Void)?` with `onMetricsChanged: ((EditorMetrics) -> Void)?` (SAME name at every layer — coordinator, surface, host, window — to keep the plumbing greppable) forwarded into `EditorSurface`; DELETE `metricsMirrorTask`, its `.onChange(of: document?.displayText)` block, and the doc-switch cancel in `loadDocumentIfNeeded` (all superseded — the coordinator's pipeline owns timing now; doc-load delivery happens via the attach-path immediate post). `ProjectWindow`: the `onTextChange: { text in updateMetrics(for: text) }` call site (`:669`) becomes `onMetricsChanged: { metrics = $0 }` (keep the no-doc-selected zeroing where `updateMetrics`'s guard did it — check what clears `metrics` on selection change and preserve that behavior; `updateMetrics(for:)` is then dead — delete it).

- [ ] **Step 3: FountainScript `==` pre-check.** Replace derived conformance:

```swift
extension FountainScript {   // adjust to declaration site; keep Sendable
    public static func == (lhs: FountainScript, rhs: FountainScript) -> Bool {
        // O(1) rejection gates before the elementwise compare: typing always
        // changes one of these, so the per-pause deep compare collapses to a
        // few integer checks in the common case. The gates are REJECTION-only
        // — equal gates still fall through to the full compare (pinned by
        // test_precheckEqualButContentUnequal_comparesUnequal).
        guard lhs.lines.count == rhs.lines.count,
              lhs.lines.last?.range == rhs.lines.last?.range,
              lhs.titlePage == rhs.titlePage else { return false }
        return lhs.lines == rhs.lines
    }
}
```

(Read the actual `FountainScript` declaration first — if `Equatable` is derived on a struct with exactly `lines` + `titlePage` (+ scalars), the custom `==` must compare ALL stored properties; enumerate them. If `estimatedPageCount` is stored not computed, include it.)

- [ ] **Step 4: Tests** (`CoordinatorMetricsTests.swift`): (a) typing-path metrics arrive once per debounce window with pageCount from the parsed script and correct word count (drive the coordinator headlessly with an NSTextView the way `EditorIntegrationHarnessTests` does — read its setup and mirror); (b) attach delivers immediately; (c) doc-switch mid-debounce delivers nothing stale (cancel still covered by the script-task cancel — assert via a flag); (d) prose mode delivers `mode.metrics` equivalent; (e) the `==` pre-check pin: two scripts with equal counts/last-range/titlePage but one differing middle line compare UNEQUAL.

- [ ] **Step 5: Verify + commit.** Targeted suites + full Mac scheme. Probe assertion: pause-edge batch now ≤ 30 ms at 120 pp (metrics term ≈ word-count split only). Commit: `perf(editor): M3 metrics from the keystroke's own parse — pause-edge re-parse deleted; script == gains O(1) rejection gates`.

## Task 8: M4 — gutter visible-range draw + caches

**Files:**
- Modify: `Maugham/Editor/ElementGutterView.swift`
- Create: `MaughamTests/Editor/ElementGutterDrawTests.swift`

- [ ] **Step 1: Write the failing tests** — extract the line-selection + label logic into a testable pure function first (TDD on the extraction):

```swift
import XCTest
@testable import Maugham
@testable import MaughamCore

@MainActor
final class ElementGutterDrawTests: XCTestCase {

    private func script(_ text: String) -> FountainScript {
        FountainTokenizer().parse(text)
    }

    // The visible-range selector returns exactly the labeled lines whose
    // ranges intersect the visible character range — equivalence vs the
    // brute-force full scan.
    func test_visibleSelection_matchesBruteForce() {
        let s = script((0..<400).map { i in
            i % 5 == 0 ? "INT. SCENE \(i) - DAY" : "Action line \(i)."
        }.joined(separator: "\n\n"))
        let full = s.lines.enumerated().filter {
            ElementGutterView.abbreviation(for: $0.element.element) != nil   // (enumerated: $0.element is the FountainLine)
        }.map(\.offset)
        // Several visible windows, incl. empty, head, tail, and all.
        let totalLen = s.lines.last.map { NSMaxRange($0.range) } ?? 0
        for window in [NSRange(location: 0, length: 0),
                       NSRange(location: 0, length: totalLen / 10),
                       NSRange(location: totalLen / 2, length: totalLen / 10),
                       NSRange(location: max(0, totalLen - 50), length: 50),
                       NSRange(location: 0, length: totalLen)] {
            let selected = ElementGutterView.labeledLineIndices(
                in: s, intersecting: window)
            let expected = full.filter {
                NSIntersectionRange(s.lines[$0].range, window).length > 0
                    || (window.length == 0 && false)
            }
            XCTAssertEqual(selected, expected, "window \(window)")
        }
    }

    // Binary-search bounds: first/last line exactly at window edges included.
    func test_visibleSelection_edgeLines() {
        let s = script("INT. A - DAY\n\nAction.\n\nINT. B - DAY\n\nAction.")
        let second = s.lines.first { $0.content.contains("B") }!
        let window = NSRange(location: second.range.location, length: 1)
        let selected = ElementGutterView.labeledLineIndices(in: s, intersecting: window)
        XCTAssertTrue(selected.contains(s.lines.firstIndex(of: second)!))
    }

    // Label-size cache: same (element, pointSize) never recomputes; the
    // cached size equals a fresh computation.
    func test_labelSizeCache() {
        let cache = ElementGutterView.LabelCache()
        let a1 = cache.attributedLabel(for: .sceneHeading, pointSize: 13,
                                       color: .black)
        let a2 = cache.attributedLabel(for: .sceneHeading, pointSize: 13,
                                       color: .black)
        XCTAssertTrue(a1 === a2, "second lookup must be the cached instance")
        let fresh = cache.attributedLabel(for: .sceneHeading, pointSize: 14,
                                          color: .black)
        XCTAssertFalse(a1 === fresh, "different pointSize is a different entry")
    }
}
```

(In the enumerated filter, `$0.element` is the tuple's FountainLine member, so `$0.element.element` is the ScreenplayElement — correct as written. The brute-force assertion defines the contract; adapt spellings to the real API you build in Step 2 — semantics binding, names flexible.)

- [ ] **Step 2: Implement.**

```swift
    /// Indices of lines that carry a gutter label AND intersect `window`.
    /// Binary search on the sorted, contiguous line ranges (lines are
    /// documentwise-ordered and contiguous by construction) then filter by
    /// label — O(log n + visible) instead of the previous O(all lines)
    /// full-document walk per redraw (tripwire 4; 2026-06-10 live profile).
    static func labeledLineIndices(
        in script: FountainScript, intersecting window: NSRange
    ) -> [Int] { … binary search lowerBound on range.location, walk while
                 range.location < NSMaxRange(window), filter abbreviation != nil … }

    /// Cached attributed labels keyed by (element, pointSize); NSColor
    /// changes (theme/appearance) flush via a palette-stamp key component.
    final class LabelCache { … NSCache or dictionary; returns NSAttributedString … }
```

`draw(_:)` then: compute the visible character range ONCE (`layoutManager.glyphRange(forBoundingRect: visibleRect/dirtyRect, in: container)` → `characterRange(forGlyphRange:)`), call `labeledLineIndices`, and per selected line do the (unavoidable, now ~40×-fewer) `boundingRect` query + cached-label draw. Keep `needsDisplay = true` triggers as-is.

- [ ] **Step 3: Verify.** New tests + full Mac scheme green. Manual check happens in Task 9's smoke (scroll fast, labels correct). Commit: `perf(editor): M4 gutter — visible-range binary search + label cache (tripwire 4)`.

## Task 9: Final — live verification + docs + smoke handoff

- [ ] **Step 1:** Re-run the probe (both scales + prose); append "## After M1–M4" to the baseline note; all spec-§4 budgets must hold (or the miss is investigated, not papered over).
- [ ] **Step 2:** Build the Debug dev app, open the 250 pp fixture project, and run `sample <pid> 30` while typing continuously (the session's established method): confirm no frame with the old hot stacks (tokenizer enumerator, metrics parse, gutter full walk); record the sample summary in the note.
- [ ] **Step 3:** Docs: roadmap perf item → shipped status with numbers; `Maugham/Editor/AREA.md` → note the LineRecord seam + gutter caching + metrics pipeline (one bullet each); memory addendum.
- [ ] **Step 4:** USER SMOKE (spec §10): type mid-doc and at end at 250 pp — no lag, no pause stutter; Scenes captions correct after pauses; gutter correct while scrolling fast; prose single-file doc types clean. STOP for the user before any tag.

## Conditional Task 10: prose scanner (ONLY if Task 1's prose verdict demands it)

Mirror Task 2+3 for the prose `Tokenizer` (`Maugham/Editor/Tokenizer/`): frozen reference copy in the test target, differential corpus (wiki links, checkboxes, emphasis, separator zoo), buffer pass, probe gate ≤ 8 ms @ 250 KB Debug. If Task 1 recorded "dropped", this task does not run.
