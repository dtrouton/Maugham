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

    func test_probe_typingLatencyAt70PageScale() async throws {
        let chunkDir = URL(fileURLWithPath: "/tmp/maugham-perf-probe")
        guard let t1 = try? String(
                contentsOf: chunkDir.appendingPathComponent("chunk-01.fountain"),
                encoding: .utf8),
              let t2 = try? String(
                contentsOf: chunkDir.appendingPathComponent("chunk-02.fountain"),
                encoding: .utf8) else {
            throw XCTSkip("probe chunks missing at /tmp/maugham-perf-probe")
        }
        let body = t1 + "\n\n" + t2

        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typing-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let url = projectURL.appendingPathComponent("manuscript/script.fountain")
        try body.write(to: url, atomically: true, encoding: .utf8)

        let clock = ContinuousClock()

        var start = clock.now
        let doc = try await Document.load(
            url: url, device: "probe-mac", session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        let loadTime = clock.now - start

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
        Document.load (incl. bootstrap): \(loadTime)
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
        let chunkDir = URL(fileURLWithPath: "/tmp/maugham-perf-probe")
        var bodies: [String] = []
        for n in 1...10 {
            let name = String(format: "chunk-%02d.fountain", n)
            guard let s = try? String(
                    contentsOf: chunkDir.appendingPathComponent(name),
                    encoding: .utf8) else {
                throw XCTSkip("probe chunk \(name) missing at /tmp/maugham-perf-probe")
            }
            bodies.append(s)
        }
        let body = bodies.joined(separator: "\n\n")

        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typing-probe-full-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let url = projectURL.appendingPathComponent("manuscript/script.fountain")
        try body.write(to: url, atomically: true, encoding: .utf8)

        let clock = ContinuousClock()

        var start = clock.now
        let doc = try await Document.load(
            url: url, device: "probe-mac", session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        let loadTime = clock.now - start

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
        Document.load (incl. bootstrap): \(loadTime)
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
}
