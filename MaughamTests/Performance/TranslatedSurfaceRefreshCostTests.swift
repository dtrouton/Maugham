import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// **What a source burst costs a window reading the same chapter in a
/// language** (shell p4 Task 8, fix I4). A long chapter (300 paragraphs, about
/// 25,000 words) has a Serbian translation of every paragraph, and the source
/// is shown under each.
///
/// - **before** (727a1296): every burst flush bumped `annotationsVersion`,
///   and EditorHost re-derived synchronously on the main actor — the
///   translation read from disk, the derive, the surface — then swapped the
///   whole buffer and restyled it. Per burst: `read + derive` + `swap`.
/// - **after**: the read and the derive run detached on a 400 ms trailing
///   edge, so a run of bursts inside one pause costs one refresh, and the main
///   actor pays only the swap (and nothing when the surface is unchanged).
///
/// Each figure is a median of five on the main actor. Nothing is asserted
/// about a duration. Env-gated and kept, `EditionStatusCostTests`' rule:
///
///     TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 ./scripts/test.sh only TranslatedSurfaceRefreshCostTests
@MainActor
final class TranslatedSurfaceRefreshCostTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    func test_whatASourceBurstCostsAReadingWindow() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAUGHAM_PERF_FIXTURE"] == "1",
                          "perf fixture: run with TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1")
        let project = TestTemp.root.appendingPathComponent("refresh-cost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let ids = (0..<300).map { String(format: "p%03d", $0) }
        let sentence = "The harbour lights came on one by one as the ferry turned toward the quay, "
            + "and nobody on the deck said what each of them was thinking. "
        var paragraphs: [String: String] = [:]
        for id in ids { paragraphs[id] = sentence + sentence + id }
        let records = ids.map {
            TranslationRecord(paragraphId: $0, language: "sr",
                              text: "Svetla luke su se palila jedno po jedno dok je trajekt skretao. " + $0,
                              sourceHash: TranslationHash.hash(paragraphs[$0]!))
        }
        try await TranslationStore.appendBatch(records, forDocId: "doc-cost", language: "sr",
                                               identity: LocalIdentities.current.translator,
                                               identities: .current, in: project)
        let clock = ContinuousClock()

        // read + derive, as the main actor paid it per burst before.
        var readDerive: [Double] = []
        var surface = ""
        for _ in 0..<5 {
            let start = clock.now
            let derived = EditorHost.derivedSurface(
                records: Result { try TranslationStore.loadMerged(forDocId: "doc-cost", language: "sr", in: project) },
                sequence: ids, paragraphs: paragraphs, language: "sr",
                showsSourceUnder: true, isScreenplay: false)
            readDerive.append(ms(clock.now - start))
            surface = derived.text
        }

        // The swap: the whole buffer replaced and restyled.
        let harness = EditorIntegrationHarness(initialText: ids.map { paragraphs[$0]! }.joined(separator: "\n\n"))
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: harness.coordinator,
                                          translationLanguage: "sr", text: surface, undoCoherentApply: false)
        var swap: [Double] = []
        for i in 0..<5 {
            let edited = surface + " " + String(i)        // a source edit changes a source line
            let start = clock.now
            EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: harness.coordinator,
                                              translationLanguage: "sr", text: edited, undoCoherentApply: false)
            swap.append(ms(clock.now - start))
        }
        // An unchanged surface: nothing.
        var unchanged: [Double] = []
        for _ in 0..<5 {
            let text = harness.textView.string
            let start = clock.now
            EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: harness.coordinator,
                                              translationLanguage: "sr", text: text, undoCoherentApply: false)
            unchanged.append(ms(clock.now - start))
        }

        let bursts = 10   // a typing run of ten flushes inside one pause
        let before = (median(readDerive) + median(swap)) * Double(bursts)
        let after = median(swap)
        let line = String(format: """
            TranslatedSurfaceRefreshCost (300 paragraphs, source under):
              read+derive %.1f ms | swap+restyle %.1f ms | unchanged %.2f ms
              before: per burst %.1f ms on the main actor; %d bursts in a pause = %.1f ms
              after:  read+derive off the main actor; %d bursts in a pause = one swap, %.1f ms
            """, median(readDerive), median(swap), median(unchanged),
                          median(readDerive) + median(swap), bursts, before, bursts, after)
        print(line)
        XCTContext.runActivity(named: line) { _ in }
    }
}
