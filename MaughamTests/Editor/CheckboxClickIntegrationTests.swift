import XCTest
import AppKit
@testable import Maugham

/// Regression net for the markdown-checkbox click flow.
///
/// The flow under test:
/// 1. The editor paints a `MaughamCheckboxAttr` on the `[ ]`/`[x]` glyph.
/// 2. `EditorSurface.mouseDown` asks the coordinator for a hit-test.
/// 3. The coordinator reads the attribute, maps to (paragraphId, offset)
///    via `paragraphLocator`, returns it.
/// 4. The host's `checkboxToggleHandler` calls `flipBracket` + `setParagraph`.
///
/// Tripwire #7 is the headline assertion: the flip must NOT route through
/// `applyExternalText` — that closure is reserved for cloud-conflict
/// resolution. We assert this by inspecting
/// `coordinator.applyExternalTextCallCount` before and after the simulated
/// click.
@MainActor
final class CheckboxClickIntegrationTests: XCTestCase {

    func test_simulatedClick_flipsBracket_andEmitsTypingBurst_notTaskOp() async throws {
        // Build a real Document with one paragraph holding an unchecked box.
        let realHarness = try await EditorIntegrationHarness.withRealDocument(
            initialText: "- [ ] thing")
        let doc = realHarness.document
        let coord = realHarness.harness.coordinator

        // Apply a tokenizer pass against the harness's NSTextStorage so the
        // bracket region carries MaughamCheckboxAttr. The withRealDocument
        // harness initializes the text view at construction time but the
        // coordinator's retokenize fires only from applyExternalText /
        // applyAppearance / text-change paths; force one via applyAppearance
        // which retokenizes without touching the binding.
        coord.applyAppearance(theme: .light, typography: .defaults)

        // Wire the production-equivalent paragraph locator that EditorSurface
        // would install via updateNSView from EditorHost.
        coord.paragraphLocator = { location in
            guard let pid = doc.paragraphId(at: location),
                  let range = doc.displayRange(forParagraphId: pid)
            else { return nil }
            return (paragraphId: pid,
                    offsetWithinParagraph: location - range.location)
        }

        // Find the paragraph id (the only one).
        let pid = doc.paragraphId(at: 0)
        XCTAssertNotNil(pid)
        guard let pid else { return }

        // Snapshot pre-click state.
        let opCountBefore = doc.opLogMirrorCount
        let externalCountBefore = coord.applyExternalTextCallCount

        // Hit-test the bracket region. Bracket starts at offset 2 in
        // "- [ ] thing"; effective range covers locations 2,3,4.
        let hit = coord.checkboxHitTest(atCharacterIndex: 3)
        XCTAssertNotNil(hit, "hit-test should detect bracket at offset 3")
        guard let hit else { return }
        XCTAssertEqual(hit.paragraphId, pid)
        XCTAssertEqual(hit.offsetWithinParagraph, 2)
        XCTAssertEqual(hit.kind, .markdown)

        // Invoke the toggle handler the way EditorSurface.mouseDown would.
        // Wire the handler the same way EditorHost does so we're testing
        // the production path, not a synthetic flip.
        coord.checkboxToggleHandler = { paragraphId, offset, kind in
            guard let para = doc.paragraph(id: paragraphId) else { return }
            let flipped: String
            switch kind {
            case .markdown:
                flipped = MarkdownCheckboxScanner.flipBracket(
                    in: para, atUTF16Offset: offset)
            case .fountain:
                flipped = FountainBoneyardScanner.flipTodoDone(
                    in: para, atUTF16Offset: offset)
            }
            doc.setParagraph(id: paragraphId, text: flipped)
        }
        coord.checkboxToggleHandler?(
            hit.paragraphId, hit.offsetWithinParagraph, hit.kind)

        // Tripwire #7: applyExternalText must NOT have fired.
        XCTAssertEqual(
            coord.applyExternalTextCallCount, externalCountBefore,
            "applyExternalText fired during a checkbox click — tripwire #7")

        // Paragraph text flipped.
        XCTAssertEqual(doc.paragraph(id: pid), "- [x] thing")
        // displayText reflects the new state (single-paragraph doc).
        XCTAssertTrue(doc.displayText.contains("- [x] thing"))

        // The op emitted is the standard typing-burst path. Burst flushes
        // are scheduled async; force-flush so the op materializes on the
        // mirror.
        try await doc.flushBurstNow()
        let kindsAfter = doc.opLogSnapshot.suffix(from: opCountBefore).map(\.kind)
        XCTAssertTrue(
            kindsAfter.contains(.typingBurst),
            "expected .typingBurst from setParagraph; got kinds: \(kindsAfter)")
        XCTAssertFalse(
            kindsAfter.contains(.taskStatusChange),
            "checkbox click must NOT emit .taskStatusChange; inline status rides .typingBurst")
    }

    func test_clickOutsideBracket_returnsNilHit() async throws {
        let realHarness = try await EditorIntegrationHarness.withRealDocument(
            initialText: "- [ ] thing")
        let coord = realHarness.harness.coordinator
        coord.applyAppearance(theme: .light, typography: .defaults)

        // Wire the production-equivalent paragraph locator.
        // (withRealDocument doesn't pre-wire it because the coordinator's
        // paragraphLocator is set by EditorSurface.updateNSView in real use.)
        // The hit-test should also return nil even with no locator wired,
        // because the bracket region isn't where the click landed.
        XCTAssertNil(coord.checkboxHitTest(atCharacterIndex: 0))
        XCTAssertNil(coord.checkboxHitTest(atCharacterIndex: 8))
    }
}
