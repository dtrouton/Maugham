import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Brief's foot, mounted** (shell p4 Task 6a; Denver, 2026-11-21: "I agree
/// on dropping clutter"). A brand-new chapter's Brief is the line, Going for
/// and ONE quiet foot line — no how-to sentence, no empty Decided heading —
/// and a chapter with a target and tags shows them on that one line, even in
/// the narrowest column. Built through the right column's one host builder
/// (`RightColumnFixture`); measured, never pressed (tripwire 33).
@MainActor
final class BriefFootMountedTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { await fixture.closeAndTearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    /// The narrowest column a writer can be shown (`PulledUpFitsTheColumnTests`').
    private static var narrowest: Double {
        ProjectWindow.effectiveDetailColumnWidth(
            persisted: UIState.detailColumnWidthRange.lowerBound,
            containerWidth: Double(ProjectWindow.windowFloor))
    }

    /// The tallest a single line of the foot's callout type can be laid out.
    private static var oneLine: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .callout)  // at least the foot's subheadline
        return ceil(font.ascender - font.descender + font.leading) * 1.5
    }

    private func mountBrief(_ f: StatementMountFixture, width: Double) -> NSWindow {
        let piece = WindowSubject(open: .item(f.documentItemId), faces: .item(f.documentItemId))
        let probe = RightColumnFixture.Probe(position: .brief, subject: piece)
        let column = RightColumnFixture.column(store: f.store, documentStore: f.documentStore,
                                               probe: probe, width: width)
        return f.hostView(AnyView(column), width: CGFloat(width))
    }

    /// The foot's one frame, once Brief has read.
    private func footFrame(_ f: StatementMountFixture, in window: NSWindow) async throws -> NSRect {
        await pumpUntil(deadline: 5) { (try? f.axFrames(identifiedBy: "brief.foot", in: window).isEmpty) == false }
        await waitOut(0.3)
        let frames = try f.axFrames(identifiedBy: "brief.foot", in: window)
        XCTAssertEqual(frames.count, 1, "one foot")
        return try XCTUnwrap(frames.first)
    }

    func test_aFreshChaptersBriefIsTheLineGoingForAndOneFootLine() async throws {
        let f = try await StatementMountFixture.novel(named: "FootFresh")
        fixtures.append(f)
        let window = mountBrief(f, width: UIState.defaultDetailColumnWidth)
        await pumpUntil(deadline: 5) { f.shows(BriefFoot.historyTitle, in: window) }

        let foot = try await footFrame(f, in: window)
        XCTAssertLessThanOrEqual(foot.height, Self.oneLine, "the foot is one line: \(foot)")
        let texts = try f.allStaticTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(GoingForView.heading) }, "premise: Brief has read: \(texts)")
        // The Details menu is found by its identifier, not its words.
        XCTAssertEqual(try f.axFrames(identifiedBy: "brief.details", in: window).count, 1,
                       "nothing set: the Details menu")
        XCTAssertTrue(texts.contains(BriefFoot.historyTitle), "History is findable: \(texts)")
        // VoiceOver reads the menu's offers as its value, never an empty one
        // (shell p5 Task 5).
        let spoken = try XCTUnwrap(try f.axValues(identifiedBy: "brief.details", in: window).first)
        let offers = spoken.components(separatedBy: ", ")
        let names = PieceRowMenus.Item.allCases.map { BriefFoot.spokenName($0) }
        XCTAssertFalse(spoken.isEmpty, "the Details menu reads its offers")
        XCTAssertTrue(offers.allSatisfy(names.contains), "every offer is a row-menu sheet: \(spoken)")
        for gone in ["What you answer in To resolve", "Nothing is attached", "Set a target", "Add tags",
                     "Publishing settings", BriefDecidedSection.heading] {
            XCTAssertFalse(texts.contains { $0.contains(gone) }, "a fresh chapter's Brief says \(gone): \(texts)")
        }
    }

    /// Which `BriefFoot.Fit` the foot drew, read off its target's identifier.
    private func drawnFit(_ f: StatementMountFixture, in window: NSWindow) throws -> [String] {
        try BriefFoot.Fit.allCases.compactMap { fit in
            try f.axFrames(identifiedBy: "brief.value.target.\(fit)", in: window).isEmpty ? nil : "\(fit)"
        }
    }

    /// **Everything set, at the narrowest column**: the target, five tags and
    /// two links, then Details and History — one line, the tags gave way, and
    /// both doors lie whole inside the column. At the default width the same
    /// foot keeps more of its tags.
    func test_aSetTargetAndTagsReadOnTheOneLineInTheNarrowestColumn() async throws {
        let f = try await StatementMountFixture.novel(named: "FootSet")
        fixtures.append(f)
        let tags = ["rome", "draft", "the long winter of the harbourmaster", "kelly", "second act"]
        try await f.store.updateInspector(id: f.documentItemId, wordTarget: 3000)
        try await f.store.updateInspector(id: f.documentItemId, tags: tags)
        let other = try await f.store.addStructureItem(parentId: nil, title: "Two", kind: .document(.markdown))
        let third = try await f.store.addStructureItem(parentId: nil, title: "Three", kind: .document(.markdown))
        try await f.store.updateInspector(id: f.documentItemId, links: [other.id, third.id])

        var drawn: [Double: [String]] = [:]
        for width in [Self.narrowest, UIState.defaultDetailColumnWidth] {
            let window = mountBrief(f, width: width)
            await pumpUntil(deadline: 5) { f.shows(BriefFoot.historyTitle, in: window) }

            let foot = try await footFrame(f, in: window)
            XCTAssertLessThanOrEqual(foot.height, Self.oneLine, "the foot wrapped at \(width)pt: \(foot)")
            let texts = try f.allStaticTexts(in: window)
            XCTAssertTrue(texts.contains("Word target: \(3000.formatted()) words"), "the target reads: \(texts)")

            // Details and History are on screen, whole: the tags gave way.
            let content = window.convertToScreen(try XCTUnwrap(window.contentView).frame)
            for door in ["brief.details", "brief.history"] {
                let frame = try XCTUnwrap(try f.axFrames(identifiedBy: door, in: window).first,
                                          "\(door) is missing at \(width)pt")
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertLessThanOrEqual(frame.maxX, content.maxX + 0.5,
                                         "\(door) runs off the \(width)pt column: \(frame) in \(content)")
            }
            drawn[width] = try drawnFit(f, in: window)
        }
        // Each width draws exactly one step, and the narrowest gives way
        // at least as far as the default.
        let order = BriefFoot.Fit.allCases.map { "\($0)" }
        let narrow = try XCTUnwrap(drawn[Self.narrowest]?.first, "\(drawn)")
        let wide = try XCTUnwrap(drawn[UIState.defaultDetailColumnWidth]?.first, "\(drawn)")
        XCTAssertEqual(drawn.values.map(\.count), [1, 1], "\(drawn)")
        XCTAssertGreaterThanOrEqual(order.firstIndex(of: narrow)!, order.firstIndex(of: wide)!, "\(drawn)")
    }
}
