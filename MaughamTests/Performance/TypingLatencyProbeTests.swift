import XCTest
@testable import Maugham
@testable import MaughamCore

/// Typing-latency perf harness (2026-06-10 investigation): per-keystroke
/// `Document.setFullText` + editor styling/tokenization cost attribution at
/// 70-page (2-chunk) and ~250-page (10-chunk) single-file screenplay scale.
/// Auto-skips unless fixture chunks are staged at /tmp/maugham-perf-probe
/// (any large .fountain split into chunk-01…chunk-10 works). Used to
/// diagnose and fix the 325 ms/keystroke latency (windowed typography,
/// setFullText parse-once + indexed matching, scanner fast paths) and to
/// re-baseline before the future FountainTokenizer buffer rewrite.
@MainActor
final class TypingLatencyProbeTests: XCTestCase {

    // MARK: - Shared helpers

    private static let chunkDir = URL(fileURLWithPath: "/tmp/maugham-perf-probe")

    /// Loads chunk-01…chunk-NN.fountain from the staged probe directory,
    /// joined with "\n\n". Throws `XCTSkip` when the fixtures are absent so the
    /// probe stays a no-op on machines without the corpus (the file's contract).
    private func loadChunks(count: Int) throws -> String {
        var bodies: [String] = []
        for n in 1...count {
            let name = String(format: "chunk-%02d.fountain", n)
            guard let s = try? String(
                    contentsOf: Self.chunkDir.appendingPathComponent(name),
                    encoding: .utf8) else {
                throw XCTSkip("probe chunk \(name) missing at /tmp/maugham-perf-probe")
            }
            bodies.append(s)
        }
        return bodies.joined(separator: "\n\n")
    }

    /// Writes `body` into a throwaway temp project and loads it through the real
    /// `Document.load` path (Bootstrap mints the ¶id anchors). Returns the doc
    /// and the project URL the caller is responsible for removing.
    private func makeDoc(body: String, ext: String) async throws
        -> (doc: Document, projectURL: URL) {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typing-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let url = projectURL
            .appendingPathComponent("manuscript/script.\(ext)")
        try body.write(to: url, atomically: true, encoding: .utf8)
        let doc = try await Document.load(
            url: url, device: "probe-mac", session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        return (doc, projectURL)
    }

    /// Deterministic prose generator (~`bytes` of `.md`): paragraphs drawn from
    /// a fixed lexicon, every 7th carrying a `[[Linked Note]]` wiki link and
    /// every 11th a `- [ ] task` checkbox line — the prose facets the scanner
    /// pays for. Seeded so the corpus is identical across machines/runs.
    static func generateProse(bytes: Int) -> String {
        let lexicon = [
            "morning", "harbour", "the", "she", "remembered", "a", "letter",
            "between", "them", "quietly", "and", "then", "nothing", "moved",
            "across", "water", "gulls", "circled", "above", "the", "pier",
            "he", "had", "not", "spoken", "since", "the", "funeral", "rain",
        ]
        var rng = SplitMix64(seed: 0xC0FFEE)
        var out = ""
        var paragraphIndex = 0
        while out.utf8.count < bytes {
            let wordCount = 18 + Int(rng.next() % 40)
            var words: [String] = []
            for _ in 0..<wordCount {
                words.append(lexicon[Int(rng.next() % UInt64(lexicon.count))])
            }
            if paragraphIndex % 7 == 0 { words.append("[[Linked Note]]") }
            var paragraph = words.joined(separator: " ") + "."
            if paragraphIndex % 11 == 0 {
                paragraph += "\n- [ ] task \(paragraphIndex)"
            }
            out += paragraph + "\n\n"
            paragraphIndex += 1
        }
        return out
    }

    func test_probe_typingLatencyAt70PageScale() async throws {
        let body = try loadChunks(count: 2)
        let (doc, projectURL) = try await makeDoc(body: body, ext: "fountain")
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let clock = ContinuousClock()
        var start = clock.now

        // Simulate 15 keystrokes through the editor's real entry point:
        // whole displayText, one inserted char mid-document each time.
        var latencies: [Duration] = []
        for _ in 0..<15 {
            var text = doc.displayText
            let mid = text.index(text.startIndex, offsetBy: text.count / 2)
            text.insert(contentsOf: "x", at: mid)
            start = clock.now
            doc.setFullText(text)
            latencies.append(clock.now - start)
        }
        latencies.sort()

        // Pure-function attribution at the same scale.
        let stored = doc.materialize()
        start = clock.now
        _ = Materializer.materialize(paragraphs: doc.paragraphs, sequence: doc.sequence)
        let tMaterialize = clock.now - start

        start = clock.now
        let parsed = ParagraphParser.parse(stored)
        let tParse = clock.now - start

        var display = doc.displayText
        let mid2 = display.index(display.startIndex, offsetBy: display.count / 2)
        display.insert(contentsOf: "y", at: mid2)
        start = clock.now
        _ = RenderFilter.restoreComments(stored: stored, displayEdited: display)
        let tRestore = clock.now - start

        // Editor-side per-keystroke costs (retokenizeAndStyle path):
        // whole-doc Fountain parse + token derivation + applyTypography
        // against a real NSTextStorage (no window needed).
        let displayNow = doc.displayText
        start = clock.now
        let script = FountainTokenizer().parse(displayNow)
        let tTokenize = clock.now - start

        let screenplayMode = ScreenplayMode()
        start = clock.now
        let tokens = screenplayMode.tokens(from: script, text: displayNow)
        let tTokens = clock.now - start

        let storage = NSTextStorage(string: displayNow)
        start = clock.now
        screenplayMode.applyTypography(
            in: storage, theme: .light, typography: .screenplayDefaults,
            tokens: tokens, parsedScript: script)
        let tTypography = clock.now - start

        // Windowed path: simulate a 1-char mid-document insertion. Style the
        // OLD text whole-doc once (storage already holds displayNow), apply the
        // edit so attributes shift, then run the WINDOWED restyle (old→new
        // tokens) — exactly what the textDidChange fast path does.
        let editNS = displayNow as NSString
        let editLoc = editNS.length / 2
        let editedText = editNS.replacingCharacters(
            in: NSRange(location: editLoc, length: 0), with: "x")
        let newScript = FountainTokenizer().parse(editedText)
        let newTokens = screenplayMode.tokens(from: newScript, text: editedText)
        let windowStorage = NSTextStorage(string: displayNow)
        screenplayMode.applyTypography(
            in: windowStorage, theme: .light, typography: .screenplayDefaults,
            tokens: tokens, parsedScript: script)
        windowStorage.replaceCharacters(
            in: NSRange(location: editLoc, length: 0), with: "x")
        let decision = TokenRestyleWindow.decide(
            oldTokens: tokens, newTokens: newTokens,
            storageLength: windowStorage.length)
        let window: NSRange?
        switch decision {
        case .noChange:      window = NSRange(location: 0, length: 0)
        case .window(let r): window = r
        case .fullDocument:  window = nil
        }
        start = clock.now
        screenplayMode.applyTypography(
            in: windowStorage, theme: .light, typography: .screenplayDefaults,
            tokens: newTokens, parsedScript: newScript, restyleWindow: window)
        let tWindowed = clock.now - start

        // applyFocusDim cost at scale (paragraph-focus on): O(doc) enumerate +
        // re-color of the dimmed region. Measured but NOT optimized here
        // (called from three paths intentionally — see Editor AREA.md).
        let dimStorage = NSTextStorage(string: displayNow)
        screenplayMode.applyTypography(
            in: dimStorage, theme: .light, typography: .screenplayDefaults,
            tokens: tokens, parsedScript: script)
        let cursorMid = (displayNow as NSString).length / 2
        let para = FocusFinder.paragraphRange(in: displayNow, cursor: cursorMid)
        start = clock.now
        let full = NSRange(location: 0, length: dimStorage.length)
        dimStorage.beginEditing()
        if para.location > 0 {
            dimStorage.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: para.location), options: []
            ) { value, sub, _ in
                if let c = value as? NSColor {
                    dimStorage.addAttribute(.foregroundColor,
                        value: c.withAlphaComponent(0.4), range: sub)
                }
            }
        }
        let after = NSMaxRange(para)
        if after < full.length {
            dimStorage.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: after, length: full.length - after),
                options: []
            ) { value, sub, _ in
                if let c = value as? NSColor {
                    dimStorage.addAttribute(.foregroundColor,
                        value: c.withAlphaComponent(0.4), range: sub)
                }
            }
        }
        dimStorage.endEditing()
        let tFocusDim = clock.now - start
        let windowDesc: String = window.map { "\($0)" } ?? "FULL-DOC fallback"

        print("""
        ===== TYPING LATENCY PROBE =====
        paragraphs: \(doc.sequence.count) (parsed: \(parsed.count)), display bytes: \(doc.displayText.utf8.count)
        setFullText per keystroke: median \(latencies[latencies.count / 2]), min \(latencies.first!), max \(latencies.last!)
        attribution at this scale:
          Materializer.materialize:                 \(tMaterialize)
          ParagraphParser.parse:                    \(tParse)
          RenderFilter.restoreComments (1-char edit): \(tRestore)
        editor styling path (per keystroke, whole doc):
          FountainTokenizer.parse:   \(tTokenize)
          ScreenplayMode.tokens:     \(tTokens)
          applyTypography (storage): \(tTypography)
        WINDOWED applyTypography (1-char mid-doc edit):
          window:                    \(windowDesc)
          applyTypography (windowed): \(tWindowed)
          applyFocusDim (paragraph):  \(tFocusDim)
        ================================
        """)
        await doc.close()
    }

    /// FULL-SCALE probe (~500 KB, ~2,900 paragraphs): all 10 chunks from
    /// /tmp/maugham-perf-probe. Reports Document.load, setFullText median
    /// keystroke, the residual whole-doc scanners (ParagraphParser.parse,
    /// FountainTokenizer.parse), windowed applyTypography, and a
    /// total-per-keystroke estimate. Run BEFORE and AFTER the C-series fix.
    func test_probe_typingLatencyAtFullScale() async throws {
        let body = try loadChunks(count: 10)
        let (doc, projectURL) = try await makeDoc(body: body, ext: "fountain")
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let clock = ContinuousClock()
        var start = clock.now

        func median(_ xs: [Duration]) -> Duration {
            let s = xs.sorted(); return s[s.count / 2]
        }

        // setFullText median over 10 keystrokes (real editor entry point).
        var setLatencies: [Duration] = []
        for _ in 0..<10 {
            var text = doc.displayText
            let mid = text.index(text.startIndex, offsetBy: text.count / 2)
            text.insert(contentsOf: "x", at: mid)
            start = clock.now
            doc.setFullText(text)
            setLatencies.append(clock.now - start)
        }

        let stored = doc.materialize()

        // ParagraphParser.parse — median over 10 (whole-doc, once per keystroke).
        var parseLat: [Duration] = []
        var parsedCount = 0
        for _ in 0..<10 {
            start = clock.now
            let parsed = ParagraphParser.parse(stored)
            parseLat.append(clock.now - start)
            parsedCount = parsed.count
        }

        // FountainTokenizer.parse — median over 10 (whole-doc, once per keystroke).
        let displayNow = doc.displayText
        var tokLat: [Duration] = []
        for _ in 0..<10 {
            start = clock.now
            _ = FountainTokenizer().parse(displayNow)
            tokLat.append(clock.now - start)
        }
        let script = FountainTokenizer().parse(displayNow)

        // Windowed applyTypography (1-char mid-doc edit) — the realistic restyle.
        let screenplayMode = ScreenplayMode()
        let tokens = screenplayMode.tokens(from: script, text: displayNow)
        let editNS = displayNow as NSString
        let editLoc = editNS.length / 2
        let editedText = editNS.replacingCharacters(
            in: NSRange(location: editLoc, length: 0), with: "x")
        let newScript = FountainTokenizer().parse(editedText)
        let newTokens = screenplayMode.tokens(from: newScript, text: editedText)
        let windowStorage = NSTextStorage(string: displayNow)
        screenplayMode.applyTypography(
            in: windowStorage, theme: .light, typography: .screenplayDefaults,
            tokens: tokens, parsedScript: script)
        windowStorage.replaceCharacters(
            in: NSRange(location: editLoc, length: 0), with: "x")
        let decision = TokenRestyleWindow.decide(
            oldTokens: tokens, newTokens: newTokens,
            storageLength: windowStorage.length)
        let window: NSRange?
        switch decision {
        case .noChange:      window = NSRange(location: 0, length: 0)
        case .window(let r): window = r
        case .fullDocument:  window = nil
        }
        var winLat: [Duration] = []
        for _ in 0..<10 {
            start = clock.now
            screenplayMode.applyTypography(
                in: windowStorage, theme: .light, typography: .screenplayDefaults,
                tokens: newTokens, parsedScript: newScript, restyleWindow: window)
            winLat.append(clock.now - start)
        }

        let mSet = median(setLatencies)
        let mParse = median(parseLat)
        let mTok = median(tokLat)
        let mWin = median(winLat)
        // setFullText already includes ParagraphParser.parse internally; the
        // per-keystroke editor total is setFullText + tokenizer + windowed
        // typography (tokenizer + typography run in the editor's restyle path,
        // NOT inside setFullText).
        let total = mSet + mTok + mWin

        print("""
        ===== TYPING LATENCY PROBE (FULL SCALE) =====
        paragraphs: \(doc.sequence.count) (parsed: \(parsedCount)), display bytes: \(doc.displayText.utf8.count)
        setFullText per keystroke:       median \(mSet)
        ParagraphParser.parse:           median \(mParse)
        FountainTokenizer.parse:         median \(mTok)
        windowed applyTypography:        median \(mWin)  window: \(window.map { "\($0)" } ?? "FULL-DOC")
        ----
        per-keystroke total estimate (setFullText + tokenize + windowed typo): \(total)
        =============================================
        """)
        await doc.close()
    }

    /// M0 of the typing-perf milestone (spec §4): per-item costs at 120 pp
    /// (5 chunks ≈ 250 KB) and 250 pp (10 chunks ≈ 500 KB), plus the
    /// pause-edge batch, plus a single-file PROSE case. Numbers land in
    /// docs/superpowers/notes/2026-06-10-typing-perf-baseline.md.
    func test_probe_typingPerfBaseline() async throws {
        for chunkCount in [5, 10] {
            let body = try loadChunks(count: chunkCount)
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
            _ = tokens

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
        bytes: \(pdoc.displayText.utf8.count), paragraphs: \(pdoc.sequence.count)
        ProseMode.tokenize: \(tProseTok)
        setFullText median: \(plat[plat.count / 2])
        ==============================================
        """)
        await pdoc.close()
    }
}

/// Tiny seeded RNG (SplitMix64) — Date/seedless RNG are banned in probes
/// that must reproduce a deterministic prose corpus across machines.
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
