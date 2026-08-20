import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// **What Publish's desk draws** (publish-department P4 Task 1) — the seat it
/// takes in the right column is `PersonaPaneRegistryTests`'; this file is about
/// the pane itself: its two sections, and the empty state it shows instead of
/// them.
///
/// **Nothing here needs a project on disk**, which is the point rather than a
/// convenience. `DepartmentPane` takes a title, a language list and a count —
/// no `ProjectStore`, no `DocumentStore` — so the whole surface is drivable
/// from literals, exactly as `ReviewBoardPane` is one persona over. That is
/// tripwire 4 satisfied by construction, and `test_theSourceReadsNoStoreAtAll`
/// is the census that keeps it so: the derivations the values come from (a walk
/// of every document's translation store, a read of the staged proposals) are
/// the mount's, and a `body` that could reach either would run it once per row.
///
/// **How the desk is observed while it has no controls.** Task 1 wires no
/// verbs, so there are no buttons to count the way the sibling suite counts
/// chips. The structural reading available instead is the sections' own
/// scroller: the desk puts them in a `ScrollView`, and the empty arm is a
/// `ContentUnavailableView`, which is not a scroller. Tasks 3 and 4 give the
/// rows buttons, at which point counting THOSE is the sharper reading and this
/// helper should be re-derived rather than leant on further.
@MainActor
final class DepartmentPaneTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // The parallel-worker fontd cold-start window (CLAUDE.md): this suite
        // mounts real text through production typography.
        FontWarmup.ensure()
    }

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    // MARK: - The empty state's truth table (no window)

    /// **Both halves must be missing before the desk says it is empty.** A book
    /// with editions and no design round is a working department, and so is one
    /// with a design round and a single language — telling either that there is
    /// nothing on the desk would be the surface contradicting what it holds.
    func test_theDeskIsOnlyEmptyWithNoLanguagesAndNoProposals() {
        XCTAssertNotNil(DepartmentDesk.emptiness(languageCount: 0, proposalCount: 0),
                        "neither half: the empty state is the honest answer")
        XCTAssertNil(DepartmentDesk.emptiness(languageCount: 1, proposalCount: 0),
                     "an edition is work for the department, design round or not")
        XCTAssertNil(DepartmentDesk.emptiness(languageCount: 0, proposalCount: 1),
                     "a staged design round is work for the department, "
                     + "editions or not")
        XCTAssertNil(DepartmentDesk.emptiness(languageCount: 3, proposalCount: 2))
    }

    /// The empty state says what is not here and what would fill it — never a
    /// bare heading, which reads as a pane that failed to load.
    func test_theEmptyStateNamesBothHalvesOfTheDepartment() throws {
        let emptiness = try XCTUnwrap(
            DepartmentDesk.emptiness(languageCount: 0, proposalCount: 0))

        XCTAssertFalse(emptiness.title.isEmpty)
        let description = emptiness.description.lowercased()
        XCTAssertTrue(description.contains("design"),
                      "the empty state must name the design half: \(emptiness.description)")
        XCTAssertTrue(description.contains("language"),
                      "…and the language half: \(emptiness.description)")
    }

    /// The Design section's line counts what is staged, and says nothing in a
    /// plural where there is one thing.
    func test_theDesignSummaryCountsWhatIsStaged() {
        XCTAssertEqual(DepartmentDesk.designSummary(proposalCount: 0),
                       "No design round yet.")
        XCTAssertEqual(DepartmentDesk.designSummary(proposalCount: 1),
                       "1 design round proposed.")
        XCTAssertEqual(DepartmentDesk.designSummary(proposalCount: 4),
                       "4 design rounds proposed.")
    }

    // MARK: - Mounted: which arm the pane is on

    /// The empty project shows the unavailable view and no desk at all.
    ///
    /// (That the arm chains tripwire 15's full frame is enforced for every pane
    /// under `Maugham/` by
    /// `TripwireGrepTests.test_contentUnavailableViewAlwaysChainsFullFrame`;
    /// what is asserted here is that the arm is REACHED.)
    func test_aProjectWithNeitherShowsNoDesk() async throws {
        let window = mount(languages: [], proposals: 0)
        pump(0.3)

        XCTAssertTrue(scrollViews(in: window).isEmpty,
                      "the pane is showing the unavailable view, which is not a "
                      + "scroller — a desk here would mean two empty headings")
    }

    /// The control for the test above, and the mounted half of the truth table:
    /// one language is enough to put the sections on screen.
    func test_oneLanguageGivesTheDeskItsSections() async throws {
        let window = mount(languages: ["es"], proposals: 0)
        let scrollers = try await scrollersSettling(in: window)

        XCTAssertEqual(scrollers.count, 1,
                       "the sections scroll in one scroller of the pane's own — "
                       + "a right-column pane may not grow the split view "
                       + "(DetailPaneColumnHeightCensusTests)")
    }

    /// And a design round with no editions at all does too, which is the arm a
    /// reading of "the desk is for translations" would get wrong.
    func test_aStagedDesignRoundAloneGivesTheDeskItsSections() async throws {
        let window = mount(languages: [], proposals: 1)
        let scrollers = try await scrollersSettling(in: window)

        XCTAssertEqual(scrollers.count, 1)
    }

    /// **A language row is named the way the rest of the app names one** —
    /// `TranslationReviewIndicator.displayLabel`, so the tag the writer reads in
    /// the translation indicator and the one they read on the desk are the same
    /// string. Read off the accessibility tree, and skipped by name where no
    /// assistive client can attach: a tree that was never built is not evidence
    /// about this view.
    func test_aLanguageRowIsNamedAsTheRestOfTheAppNamesIt() async throws {
        let window = mount(languages: ["es"], proposals: 0)
        _ = try await scrollersSettling(in: window)

        let texts = try axTexts(in: window)
        XCTAssertFalse(texts.isEmpty,
                       "the hosted desk published no text at all, so this test "
                       + "could not fail for the reason it exists")
        let expected = TranslationReviewIndicator.displayLabel(forLanguageTag: "es")
        XCTAssertTrue(texts.contains { $0.contains(expected) },
                      "no row reads \u{201C}\(expected)\u{201D}. Published: \(texts.sorted())")
    }

    // MARK: - Census

    /// **The desk reads no store** (tripwire 4). Its values are assembled by the
    /// mount precisely because assembling them is expensive — the language union
    /// walks every document's translation store and the proposal count reads
    /// `.maugham/design/proposals/` — and a `body` that could reach either would
    /// pay for it once per row. Tasks 2–4 add the rows' contents and their
    /// verbs: the verbs arrive as closures, the contents as values, and neither
    /// makes this census stale.
    func test_theSourceReadsNoStoreAtAll() throws {
        let code = try Self.codeLines(of: "Views/Publish/DepartmentPane.swift")

        for forbidden in ["ProjectStore", "DocumentStore", "TranslationStore",
                          "DesignProposalStore", "FileManager", "contentsOf"] {
            XCTAssertFalse(code.contains { $0.contains(forbidden) },
                           "`\(forbidden)` appears on the pane's path — the desk "
                           + "takes values so nothing per-row can reach the disk "
                           + "(tripwire 4)")
        }
    }

    // MARK: - Hosting

    private func mount(languages: [String], proposals: Int,
                       width: CGFloat = 340) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: width, height: 600)
        let hosting = NSHostingView(rootView: AnyView(
            DepartmentPane(title: "The Project",
                           languages: languages,
                           designProposalCount: proposals)
                .frame(maxWidth: .infinity, maxHeight: .infinity)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.1)
        return window
    }

    private func scrollViews(in window: NSWindow) -> [NSScrollView] {
        collect(NSScrollView.self, in: window)
    }

    private func scrollersSettling(in window: NSWindow,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async throws -> [NSScrollView] {
        var found: [NSScrollView] = []
        _ = await pumpUntil(deadline: 5) {
            found = self.scrollViews(in: window)
            return !found.isEmpty
        }
        pump(0.2)
        found = scrollViews(in: window)
        XCTAssertFalse(found.isEmpty,
                       "the desk mounted no sections at all", file: file, line: line)
        return found
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    /// Every string the mounted desk publishes — a static text's value, plus any
    /// label an element carries. `ReviewBoardPaneTests.axButtonLabels`' shape,
    /// widened to text because this pane has no buttons yet.
    private func axTexts(in window: NSWindow) throws -> [String] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process "
                + "(AXUIElementCopyAttributeValue -> \(error.rawValue)), so "
                + "SwiftUI never builds the tree this test reads")
        }
        let root = try XCTUnwrap(window.contentView)
        return axElements(under: root).flatMap { element -> [String] in
            [axAttribute(element, "accessibilityValue") as? String,
             axAttribute(element, "accessibilityLabel") as? String]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        }
    }

    private func collect<T: NSView>(_ type: T.Type, in window: NSWindow) -> [T] {
        guard let root = window.contentView else { return [] }
        var found: [T] = []
        collect(type, in: root, into: &found)
        return found
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func pumpUntil(deadline: TimeInterval,
                           _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            pump(0.05)
        }
        return condition()
    }

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = appSourceDir.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }
}
