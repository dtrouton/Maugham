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
        let font = NSFont.preferredFont(forTextStyle: .callout)
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
        // A pop-up's accessibility value is its (empty) selection, so the
        // Details menu is found by its identifier, not its words.
        XCTAssertEqual(try f.axFrames(identifiedBy: "brief.details", in: window).count, 1,
                       "nothing set: the Details menu")
        XCTAssertTrue(texts.contains(BriefFoot.historyTitle), "History is findable: \(texts)")
        for gone in ["What you answer in To resolve", "Nothing is attached", "Set a target", "Add tags",
                     "Publishing settings", BriefDecidedSection.heading] {
            XCTAssertFalse(texts.contains { $0.contains(gone) }, "a fresh chapter's Brief says \(gone): \(texts)")
        }
    }

    func test_aSetTargetAndTagsReadOnTheOneLineInTheNarrowestColumn() async throws {
        let f = try await StatementMountFixture.novel(named: "FootSet")
        fixtures.append(f)
        let tags = ["rome", "draft", "the long winter of the harbourmaster", "kelly", "second act"]
        try await f.store.updateInspector(id: f.documentItemId, wordTarget: 3000)
        try await f.store.updateInspector(id: f.documentItemId, tags: tags)
        let width = Self.narrowest
        let window = mountBrief(f, width: width)
        await pumpUntil(deadline: 5) { f.shows(BriefFoot.historyTitle, in: window) }

        let foot = try await footFrame(f, in: window)
        XCTAssertLessThanOrEqual(foot.height, Self.oneLine, "long tags never wrap the foot: \(foot)")
        let texts = try f.allStaticTexts(in: window)
        XCTAssertTrue(texts.contains("Word target: \(3000.formatted()) words"), "the target reads: \(texts)")
        XCTAssertTrue(texts.contains("Tags: " + tags.joined(separator: ", ")), "the tags read: \(texts)")
        XCTAssertTrue(try f.axFrames(identifiedBy: "brief.details", in: window).isEmpty,
                      "something is set: no Details menu")

        // History stays on screen: the tags gave way, not the door.
        let history = try XCTUnwrap(try f.axFrames(identifiedBy: "brief.history", in: window).first)
        let content = window.convertToScreen(try XCTUnwrap(window.contentView).frame)
        XCTAssertLessThanOrEqual(history.maxX, content.maxX + 0.5,
                                 "History runs off the \(width)pt column: \(history) in \(content)")
        XCTAssertGreaterThan(history.width, 0)
    }
}
