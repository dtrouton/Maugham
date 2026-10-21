// MaughamTests/Editor/ReferenceLabelOverlayTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The resolved labels beside markers (R-3b-1) and the problem underlines
/// (R-3b-4), mounted on a real text view and coordinator: the install and its
/// layering, the empty draw, the fit and no-fit draws, the underline
/// temporaries beside the translation dimming, the tooltips, and the settle
/// hook's cadence. No pixel snapshots; no synthesised events, and nothing
/// presses a control and waits (tripwire 33) — the settle is awaited as a task.
@MainActor
final class ReferenceLabelOverlayTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // the labels measure through the editor's fonts
    }

    private static let library: [ResearchItem] = [
        ResearchItem(id: "1", title: "Item 1", type: .asset, kind: .link, url: "https://example.com/1",
                     citation: CitationInfo(key: "smith2026", authors: ["Smith, Jane"],
                                            sourceTitle: "Markets", year: 2026)),
    ]

    nonisolated private static func index(version: Int = 1) -> ReferenceIndex {
        ReferenceIndex.build(
            pieces: [("other", ReferenceIndex.PieceSummary(text: "![Chart](c.png){#fig:chart}"))],
            research: library, words: .english).versioned(version)
    }

    /// A manuscript surface as `EditorHost` wires one: it answers the Insert
    /// menu and has the window's index and the project's profile.
    private func mounted(_ text: String, manuscript: Bool = true, profile: ProjectProfile? = .report,
                         index: ReferenceIndex = ReferenceLabelOverlayTests.index(),
                         typography: TypographySettings = .defaults,
                         mode: ProseMode = ProseMode()) -> EditorIntegrationHarness {
        let harness = EditorIntegrationHarness(mode: mode, initialText: text, cursorLocation: 0)
        if manuscript {
            harness.coordinator.answersInsertCommands = true
            harness.coordinator.referenceIndex = { index }
            harness.coordinator.projectProfile = { profile }
        }
        harness.coordinator.typography = typography
        harness.coordinator.attach(to: harness.textView)   // the production install point
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        harness.textView.layoutManager?.ensureLayout(for: harness.textView.textContainer!)
        return harness
    }

    private func underline(_ harness: EditorIntegrationHarness, at location: Int)
        -> (style: Int?, color: NSColor?) {
        let lm = harness.textView.layoutManager!
        let style = lm.temporaryAttribute(.underlineStyle, atCharacterIndex: location,
                                          effectiveRange: nil) as? NSNumber
        let color = lm.temporaryAttribute(.underlineColor, atCharacterIndex: location,
                                          effectiveRange: nil) as? NSColor
        return (style?.intValue, color)
    }

    private let dotted = NSUnderlineStyle.single.union(.patternDot).rawValue

    // MARK: - Install, layering, empty draw

    func test_theOverlayInstallsOnAManuscriptAboveTheThumbnailsAndTakesNoClick() throws {
        let harness = EditorIntegrationHarness(mode: ProseMode(reservesFigureThumbnails: true),
                                               initialText: "See [@smith2026].", cursorLocation: 0)
        harness.coordinator.answersInsertCommands = true
        harness.coordinator.referenceIndex = { Self.index() }
        harness.coordinator.figureImageResolver = { _ in .notLocal }
        harness.coordinator.attach(to: harness.textView)
        let labels = try XCTUnwrap(harness.coordinator.referenceLabelOverlay)
        let thumbnails = try XCTUnwrap(harness.coordinator.figureThumbnailOverlay)
        XCTAssertTrue(labels.superview === harness.textView)
        XCTAssertNil(labels.hitTest(NSPoint(x: 10, y: 10)), "it never takes a click")
        let order = harness.textView.subviews
        XCTAssertGreaterThan(try XCTUnwrap(order.firstIndex(of: labels)),
                             try XCTUnwrap(order.firstIndex(of: thumbnails)),
                             "labels draw above the thumbnails")
        harness.coordinator.attach(to: harness.textView)
        XCTAssertEqual(harness.textView.subviews.filter { $0 is ReferenceLabelOverlay }.count, 1,
                       "installing is idempotent")
    }

    /// A research note or a statement (no Insert menu, no index) gets neither
    /// labels nor underlines.
    func test_aResearchNoteGetsNoLabelsAndNoUnderlines() {
        let harness = mounted("See [@ghost] and @fig:missing.[^1]", manuscript: false)
        XCTAssertNil(harness.coordinator.referenceLabelOverlay)
        XCTAssertNil(underline(harness, at: 6).style)
        XCTAssertEqual(harness.coordinator.problemCheckCount, 0)
    }

    func test_aMarkerFreeManuscriptDrawsNothingAndNeverRepaints() throws {
        let harness = mounted("Just prose.\n\nMore prose.")
        let overlay = try XCTUnwrap(harness.coordinator.referenceLabelOverlay)
        overlay.display()
        XCTAssertEqual(overlay.lastBeneathCount + overlay.lastTagCount, 0)
        let before = overlay.repaintRequests
        harness.textView.didChangeText()
        XCTAssertEqual(overlay.repaintRequests, before, "no marker, no repaint")
    }

    // MARK: - Fit and no fit (R-3b-1)

    func test_atTheDefaultSpacingTheLabelIsDrawnBeneath() throws {
        let harness = mounted("See [@smith2026] and @fig:chart today.")
        let overlay = try XCTUnwrap(harness.coordinator.referenceLabelOverlay)
        overlay.display()
        XCTAssertEqual(overlay.lastBeneathCount, 2)
        XCTAssertEqual(overlay.lastTagCount, 0)
        XCTAssertTrue(overlay.hoverTargets.isEmpty)
    }

    func test_anUnresolvedMarkerDrawsNoLabel() throws {
        let harness = mounted("See [@ghost] here.")
        let overlay = try XCTUnwrap(harness.coordinator.referenceLabelOverlay)
        overlay.display()
        XCTAssertEqual(overlay.lastBeneathCount + overlay.lastTagCount, 0)
    }

    /// Tight spacing: no room beneath, so the label waits for the caret or
    /// the pointer, and then shows as a tag above the line.
    func test_whenItDoesNotFitItShowsOnlyForTheCaretOrThePointer() throws {
        var tight = TypographySettings.defaults
        tight.lineHeightMultiplier = 1.0
        let text = "Plain words first. See [@smith2026] now."
        let harness = mounted(text, typography: tight)
        let overlay = try XCTUnwrap(harness.coordinator.referenceLabelOverlay)
        overlay.display()
        XCTAssertEqual(overlay.lastBeneathCount, 0)
        XCTAssertEqual(overlay.lastTagCount, 0, "the caret is elsewhere and nothing hovers")
        XCTAssertEqual(overlay.hoverTargets.count, 1)

        let marker = (text as NSString).range(of: "[@smith2026]")
        harness.textView.setSelectedRange(NSRange(location: marker.location + 3, length: 0))
        overlay.display()
        XCTAssertEqual(overlay.lastTagCount, 1, "the caret is inside the marker")

        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let target = try XCTUnwrap(overlay.hoverTargets.first)
        overlay.hover(at: CGPoint(x: target.rect.midX, y: target.rect.midY))
        overlay.display()
        XCTAssertEqual(overlay.lastTagCount, 1, "the pointer is over the marker")
        overlay.hover(at: nil)
        overlay.display()
        XCTAssertEqual(overlay.lastTagCount, 0)
    }

    // MARK: - Underlines (R-3b-4)

    func test_problemsAreDottedRedInAReportAndAmberElsewhere() {
        let text = "See [@ghost] here."
        let at = (text as NSString).range(of: "@ghost").location
        let report = mounted(text, profile: .report)
        XCTAssertEqual(underline(report, at: at).style, dotted)
        XCTAssertEqual(underline(report, at: at).color, .systemRed)
        XCTAssertNil(underline(report, at: 0).style, "only the problem is marked")
        let novel = mounted(text, profile: nil)
        XCTAssertEqual(underline(novel, at: at).color, .systemOrange)
    }

    /// The index not built yet (version 0): no key is called unknown, but a
    /// footnote with no definition is still this document's own problem.
    func test_anUnbuiltIndexMarksOnlyWhatTheDocumentKnows() {
        let text = "See [@ghost] here.[^1]"
        let harness = mounted(text, index: Self.index(version: 0))
        let ns = text as NSString
        XCTAssertNil(underline(harness, at: ns.range(of: "@ghost").location).style)
        XCTAssertEqual(underline(harness, at: ns.range(of: "[^1]").location).style, dotted)
    }

    func test_theTooltipsAreRebuiltWithTheUnderlines() throws {
        let harness = mounted("See [@ghost] here.")
        let tooltips = try XCTUnwrap(harness.coordinator.problemTooltips)
        XCTAssertEqual(Array(tooltips.messages.values),
                       ["No research source has the citation key ghost."])
        // A rebuild on its own (a resize) replaces the rects, never adds to them.
        harness.coordinator.rebuildProblemTooltips()
        XCTAssertEqual(tooltips.messages.count, 1)
        // Fix the key; the next check drops the old tooltip and its underline.
        harness.textView.string = "See [@smith2026] here."
        harness.coordinator.retokenizeAndStyle()
        XCTAssertTrue(tooltips.messages.isEmpty)
        XCTAssertNil(underline(harness, at: 5).style)
    }

    /// The underlines and the translation dimming share the layout manager's
    /// temporaries and never clear each other's.
    func test_underlinesAndTranslationDimmingCoexist() {
        let text = "See [@ghost] here.\n\nMissing paragraph."
        let ns = text as NSString
        let harness = mounted(text)
        let coordinator = harness.coordinator
        let lm = harness.textView.layoutManager!
        let key = ns.range(of: "@ghost").location
        let missing = ns.range(of: "Missing paragraph.")
        coordinator.setTranslationReview(true)
        coordinator.resolvedTranslationBadges = [
            .init(paragraphId: "a", range: missing, status: .missing),
        ]
        coordinator.applyTranslationDimming()
        XCTAssertEqual(underline(harness, at: key).style, dotted, "dimming leaves the underline")

        coordinator.refreshProblemMarks()
        XCTAssertEqual(lm.temporaryAttribute(.foregroundColor, atCharacterIndex: missing.location,
                                             effectiveRange: nil) as? NSColor,
                       .tertiaryLabelColor, "the check leaves the dimming")
        XCTAssertEqual(underline(harness, at: key).style, dotted)

        coordinator.setTranslationReview(false)
        coordinator.applyTranslationDimming()   // leaving: the dimming clears
        XCTAssertNil(lm.temporaryAttribute(.foregroundColor, atCharacterIndex: missing.location,
                                           effectiveRange: nil))
        XCTAssertEqual(underline(harness, at: key).style, dotted)
    }

    // MARK: - Cadence

    /// The checks run on the settle edge: a burst of keystrokes runs none,
    /// its settle runs one.
    func test_theChecksRunAtTheSettleNotPerKeystroke() async {
        let harness = mounted("See [@ghost] here.")
        harness.coordinator.restyleSettleDelayMs = 0
        harness.setCursor(to: (harness.currentText as NSString).length)
        let before = harness.coordinator.problemCheckCount
        await harness.typeString(" and [@other] too")
        XCTAssertEqual(harness.coordinator.problemCheckCount, before, "no check per keystroke")
        let settle = harness.coordinator.deferredRestyleTask
        XCTAssertNotNil(settle)
        await settle?.value
        XCTAssertEqual(harness.coordinator.problemCheckCount, before + 1, "one check at the settle")
        let other = (harness.currentText as NSString).range(of: "@other").location
        XCTAssertEqual(underline(harness, at: other).style, dotted)
    }

    /// A new index version re-checks (temporaries only); the same one doesn't.
    func test_aNewIndexVersionRechecks() {
        let harness = mounted("See [@ghost] here.")
        let before = harness.coordinator.problemCheckCount
        harness.coordinator.setReferenceIndexVersion(7)
        XCTAssertEqual(harness.coordinator.problemCheckCount, before + 1)
        harness.coordinator.setReferenceIndexVersion(7)
        XCTAssertEqual(harness.coordinator.problemCheckCount, before + 1)
    }

    /// The footnote numbers the labels draw come from the check, in this
    /// document's order.
    func test_footnoteNumbersFollowThisDocument() throws {
        let harness = mounted("Late[^z], early[^a].\n\n[^a]: A.\n\n[^z]: Z.\n")
        XCTAssertEqual(harness.coordinator.footnoteNumbers, ["z": 1, "a": 2])
        let overlay = try XCTUnwrap(harness.coordinator.referenceLabelOverlay)
        overlay.display()
        XCTAssertEqual(overlay.lastBeneathCount, 2)
    }
}
