import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **The typing loop's standing census** (typing loop plan 1, Task 3).
///
/// Two tests. The ungated one pins the count: a burst of keystrokes runs no
/// whole-document word count, and one settle runs exactly one. The gated one
/// is a probe: it types 40 mid-document keystrokes through the production
/// binding setter (`EditorIntegrationHarness.withRealDocument`) and reports
/// the stage costs. It asserts nothing about time.
///
/// Run the probe with (Release-like numbers need `SWIFT_OPTIMIZATION_LEVEL=-O`):
///   TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 TEST_RUNNER_MAUGHAM_PERF_OUT=/some/file.txt \
///   xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
///     -only-testing:MaughamTests/TypingLoopCensusTests
/// Parallel test workers swallow stdout, so the report is also written to the
/// file `MAUGHAM_PERF_OUT` names. Headless: it does not time glyph layout and
/// drawing, spell checking, overlays or SwiftUI invalidation.
@MainActor
final class TypingLoopCensusTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    // MARK: - The count (ungated)

    func test_aBurstRunsNoWordCount_andOneSettleRunsOne() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument(
            initialText: TypingLatencyProbeTests.generateProse(bytes: 30_000))
        let tv = h.harness.textView
        let mid = (tv.string as NSString).range(
            of: " ", options: [],
            range: NSRange(location: tv.string.utf16.count / 2, length: 200)).location
        h.harness.setCursor(to: mid)
        h.documentStore.settleWordCount()
        let before = h.documentStore.wordCountRunCount

        for i in 0..<40 { h.harness.typeCharacter(i % 6 == 5 ? " " : "x") }
        XCTAssertEqual(h.documentStore.wordCountRunCount - before, 0,
            "40 keystrokes count no whole document")

        h.documentStore.settleWordCount()
        XCTAssertEqual(h.documentStore.wordCountRunCount - before, 1,
            "one settle counts the burst once")

        await h.documentStore.close()
    }

    // MARK: - The probe (gated)

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func time(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let t = clock.now
        body()
        return ms(clock.now - t)
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    private static func f(_ x: Double) -> String { String(format: "%7.2f", x) }

    static func generateFountain(bytes: Int) -> String {
        var out = ""
        var i = 0
        let names = ["ANNA", "MARCUS", "THE DOCTOR", "ELSPETH"]
        while out.utf8.count < bytes {
            if i % 6 == 0 { out += "INT. HOUSE \(i) - NIGHT\n\n" }
            out += "She crosses the room slowly and stops at the window, watching the harbour lights come on one by one.\n\n"
            out += "\(names[i % names.count])\n"
            if i % 3 == 0 { out += "(quietly)\n" }
            out += "I had not thought of the letter since the funeral, and then nothing moved for a year.\n\n"
            i += 1
        }
        return out
    }

    func test_probe_typingLoopStages() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAUGHAM_PERF_FIXTURE"] == "1",
            "perf probe: run with TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1")

        let corpora: [(String, Bool, String)] = [
            ("prose 30 KB", false, TypingLatencyProbeTests.generateProse(bytes: 30_000)),
            ("prose 250 KB", false, TypingLatencyProbeTests.generateProse(bytes: 250_000)),
            ("report prose 250 KB", false, TypingLatencyProbeTests.generateProse(bytes: 250_000, report: true)),
            ("fountain 60 KB", true, Self.generateFountain(bytes: 60_000)),
            ("fountain 250 KB", true, Self.generateFountain(bytes: 250_000)),
        ]
        var report = ""
        for (label, screenplay, body) in corpora {
            do { report += try await measure(label: label, screenplay: screenplay, body: body) }
            catch { XCTFail("\(label) threw \(error)"); throw error }
        }
        print(report)
        if let path = ProcessInfo.processInfo.environment["MAUGHAM_PERF_OUT"], !path.isEmpty {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func measure(label: String, screenplay: Bool, body: String) async throws -> String {
        let mode: any WritingMode = screenplay ? ScreenplayMode() : ProseMode()
        let h = try await EditorIntegrationHarness.withRealDocument(
            mode: mode, initialText: body, screenplay: screenplay)
        let rig = h.harness
        let tv = rig.textView
        let coordinator = rig.coordinator
        coordinator.restyleSettleDelayMs = 3_600_000
        h.documentStore.wordCountSettleDelay = .seconds(3600)

        let length = (tv.string as NSString).length
        let mid = (tv.string as NSString).range(
            of: " ", options: [], range: NSRange(location: length / 2, length: length / 2)).location
        rig.setCursor(to: mid)
        tv.scrollRangeToVisible(NSRange(location: mid, length: 0))
        tv.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: mid + 1))

        for _ in 0..<5 { rig.typeCharacter("x") }
        var keystroke: [Double] = []
        for i in 0..<40 {
            keystroke.append(Self.time { rig.typeCharacter(i % 6 == 5 ? " " : "x") })
        }

        // Stages in isolation, on the text as it now stands.
        var native = tv.string
        let tCopy = Self.time { native = tv.string; native.makeContiguousUTF8() }
        let tSetFullText = Self.median((0..<5).map { _ in
            Self.time { h.document.setFullText(native) } })
        var tTokenize = 0.0
        if let screenplayMode = mode as? ScreenplayMode {
            var script: FountainScript?
            let tParse = Self.time { script = FountainTokenizer().parse(native) }
            let tTok = Self.time { _ = screenplayMode.tokens(from: script!, text: native) }
            tTokenize = tParse + tTok
        } else {
            tTokenize = Self.median((0..<5).map { _ in Self.time { _ = mode.tokenize(native) } })
        }

        let tSettle = Self.time { h.documentStore.settleWordCount() }

        let clock = ContinuousClock()
        let t = clock.now
        do { try await h.document.performAutosave() } catch { XCTFail("autosave threw \(error)"); throw error }
        let tAutosave = Self.ms(clock.now - t)

        let tWhole = Self.time { coordinator.retokenizeAndStyle() }

        let out = """
        ===== TYPING LOOP — \(label) =====
        utf16 length: \(length), paragraphs: \(h.document.sequence.count)
        keystroke end-to-end   median \(Self.f(Self.median(keystroke))) ms   max \(Self.f(keystroke.max() ?? 0)) ms
          setFullText (isolated)      \(Self.f(tSetFullText)) ms
          tokenize whole doc          \(Self.f(tTokenize)) ms
          string copy + nativize      \(Self.f(tCopy)) ms
        settle (word count)           \(Self.f(tSettle)) ms
        autosave                      \(Self.f(tAutosave)) ms
        whole-doc paint               \(Self.f(tWhole)) ms

        """
        await h.documentStore.close()
        return out
    }
}
