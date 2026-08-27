import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The window's three columns, composed the way `ProjectWindow.body` composes
/// them: a real binder tree on the left, the writing column in the middle, and
/// the right column pinned to one width by
/// `ProjectWindow.effectiveDetailColumnWidth` — with the whole split view under
/// the window's own `.frame(minWidth:minHeight:)`.
///
/// The centre is a marker rather than a real `EditorHost`: the defect this file
/// is about is a HEIGHT demand travelling from the right column through
/// `NSSplitView` to every other column, and the editor was measured to make no
/// difference to it either way (both were reproduced, 2026-08-08). A marker
/// keeps the mount cheap and keeps the failure legible — a centre column pushed
/// out of the window is what the writer saw as "nothing rendered".
@MainActor
private struct ThreeColumnHarness<Detail: View>: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let detailWidth: Double
    @ViewBuilder let detail: () -> Detail
    @State private var renaming: String?
    let treeState = BinderTreeSectionsState()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            CollectionPiecesPane(
                store: store,
                selectedSubject: Binding(get: { probe.subject },
                                         set: { probe.subject = $0 }),
                renamingItemId: $renaming,
                treeState: treeState)
                .navigationSplitViewColumnWidth(
                    min: ProjectWindow.binderColumnFloor, ideal: 240)
        } content: {
            Color.white
                .overlay { Text("CENTRE").font(.largeTitle) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(
                    min: ProjectWindow.centreColumnFloor, ideal: 720)
        } detail: {
            detail()
                .navigationSplitViewColumnWidth(detailWidth)
        }
        .frame(minWidth: ProjectWindow.windowFloor, minHeight: 540)
    }
}

/// **The planted offender**: the right column as it was, carrying the modifier
/// this fix removed at both of the two places it stood — the header's sentence
/// and the offer's. It is the pane's SHAPE rather than the pane, so restoring
/// either site in production cannot quietly make this test the only thing still
/// reproducing the bug; and it takes both sentences from production, so a
/// rewording moves the offender with it.
///
/// If this stops overflowing, AppKit's sizing has changed and every assertion in
/// this file is passing for a reason nobody has checked.
@MainActor
private struct UnbreakableSentencePane: View {
    var body: some View {
        VStack(spacing: 0) {
            Text(DiagnosticsPane.headerCopy(for: .failed(.cliNotFound, at: Date())))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            VStack(spacing: 12) {
                Text(DiagnosticsPane.coldStartOfferSentence)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// **A pane may not grow the window's columns.**
///
/// Denver, 2026-08-08, in the Playlist collection in Author: *"if I click into a
/// piece that triggers the 'I haven't read this' UI, the tree gets dragged to
/// the bottom, I can't scroll up, and the centre piece isn't rendered."*
///
/// **Three symptoms, one mechanism, measured before anything was changed**
/// (macOS 26.5, 2026-08-08 — CLAUDE.md's runner-parity rule applies: these mount
/// real AppKit views, so a green run here says nothing about a runner on a
/// different major). `Text.fixedSize(horizontal: false, vertical: true)` does
/// not merely let a sentence wrap; it makes the wrapped height an **unbreakable
/// minimum**, and AppKit resolves that minimum at a probe width far narrower
/// than the column the text is actually drawn in. The cold-start offer's
/// sentence came back ~818pt tall and the header's failure line ~400pt, so the
/// right column claimed a minimum height of 1334.5pt inside a 732pt window.
/// `NSSplitView` sizes itself to its tallest column, so **all three columns**
/// were laid out 1334.5pt tall and every one of them overflowed:
///
/// | column | what the writer saw |
/// |---|---|
/// | binder | the tree laid out 1285pt tall in a 732pt window, showing a band scrolled 208pt down that could not be scrolled back |
/// | centre | the editor's text view 1334pt tall, its content above the visible region — "nothing rendered" |
/// | right | the offer itself, centred in the overflowing column, which is why it was the one thing still legible |
///
/// It fails differently from the WIDTH conflict `DetailColumnWidthTests`
/// documents, and that difference is why nothing caught it: horizontally the
/// column carries an `NSSplitViewItem.MaxSize` constraint for AppKit to break,
/// and vertically there is no maximum at all — so the demand is simply granted.
///
/// **What no pane-level test could have seen.** `DiagnosticsPaneTests` mounts
/// this pane alone in a 420x700 window and presses its buttons; every one of
/// those assertions was green throughout. The demand only becomes a defect when
/// the pane is one column of a split view inside a window it can outgrow.
@MainActor
final class DiagnosticsPaneColumnHeightTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    /// The window the measurements are made in. 700pt of content is a laptop
    /// window, and every number below is relative to what this window actually
    /// reports rather than to this constant.
    private let windowHeight: CGFloat = 700

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        await waitOut(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The mechanism

    /// **The headline.** With the cold-start offer on screen the split view must
    /// be exactly as tall as the window's content, because everything the writer
    /// lost followed from its not being.
    func test_theOfferDoesNotGrowTheColumnsPastTheWindow() async throws {
        let (window, split, _) = try await mountWithTheOffer()
        let content = try XCTUnwrap(window.contentView).frame.height

        XCTAssertEqual(split.frame.height, content, accuracy: 1,
                       "the split view must fit the window it is in — it "
                       + "measured \(split.frame.height) against \(content)pt "
                       + "of window, which is the whole of this bug")
        for (i, column) in split.arrangedSubviews.enumerated() {
            XCTAssertLessThanOrEqual(
                column.frame.height, content + 1,
                "column \(i) is \(column.frame.height)pt tall in a \(content)pt "
                + "window: a pane that cannot be broken vertically takes every "
                + "other column with it")
        }
    }

    /// **The tree half.** Clicking a piece must leave the top of the binder on
    /// screen. The writer's complaint was not that the tree scrolled — it was
    /// that it could not be scrolled back, because the rows above were not
    /// scrolled off, they were laid out past the window's edge.
    func test_theTreeKeepsItsTopOnScreenWhenAPieceIsClicked() async throws {
        let (window, split, table) = try await mountWithTheOffer()
        let content = try XCTUnwrap(window.contentView).frame.height

        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        await waitOut(0.8)
        XCTAssertEqual(table.selectedRow, 3, "premise: the click landed")

        let scroll = try XCTUnwrap(enclosingScrollView(of: table),
                                   "the tree must be inside a scroll view or "
                                   + "there is nothing here to measure")
        XCTAssertLessThanOrEqual(
            scroll.frame.height, content + 1,
            "the tree's scroll view is \(scroll.frame.height)pt inside a "
            + "\(content)pt window: what is past the edge cannot be reached by "
            + "scrolling, which is why the writer was stuck at the bottom")
        XCTAssertEqual(
            scroll.documentVisibleRect.origin.y, 0, accuracy: 1,
            "and it is showing the top of the tree, not a band \(scroll.documentVisibleRect.origin.y)pt down")
        XCTAssertEqual(split.arrangedSubviews.first?.frame.height ?? -1,
                       content, accuracy: 1)
    }

    /// **The centre half.** The writing column must be inside the window, and
    /// what it draws must be inside it too — "nothing rendered across its full
    /// width" was a centre column whose content had been pushed above the top of
    /// the window.
    func test_theCentreColumnAndWhatItDrawsStayInsideTheWindow() async throws {
        let (window, split, _) = try await mountWithTheOffer()
        let contentView = try XCTUnwrap(window.contentView)

        XCTAssertEqual(split.arrangedSubviews.count, 3, "premise: three columns")
        let centre = split.arrangedSubviews[1]
        XCTAssertEqual(centre.frame.height, contentView.frame.height, accuracy: 1,
                       "the writing column is \(centre.frame.height)pt tall in a "
                       + "\(contentView.frame.height)pt window")

        let drawn = centre.convert(centre.bounds, to: contentView)
        XCTAssertTrue(contentView.bounds.contains(drawn.insetBy(dx: 0, dy: 1)),
                      "what the centre column draws must land inside the "
                      + "window: measured \(drawn) against \(contentView.bounds)")
    }

    // MARK: - What the removed modifier was there for

    /// **The fix must not have traded a layout bug for a truncation one.**
    ///
    /// **Measured on the sentence, not on the mounted pane, and the reason is a
    /// wrong instrument this file used first.** The obvious test — mount the
    /// pane in a narrow column and in a wide one and assert it is taller in the
    /// narrow one — reported *the same 140.5pt at both widths*, because
    /// `NSView.fittingSize` on a hosting view resolves SwiftUI's IDEAL size, and
    /// a `Text`'s ideal is its single-line size whatever width the column
    /// happens to be. It cannot see wrapping at all, so it would have gone green
    /// over a truncated sentence exactly as readily.
    ///
    /// So the question is put to the words themselves, at the column's width,
    /// with no `fixedSize` anywhere: `Text` reports its wrapped height as its
    /// ideal for the width it is PROPOSED, which is the whole of what the
    /// removed modifier was believed to be providing.
    func test_theOffersSentenceStillWrapsRatherThanTruncating() {
        assertWraps(DiagnosticsPane.coldStartOfferSentence,
                    font: .callout, at: 280)
    }

    /// **The header's own claim.** `cliNotFound`'s sentence names the Settings
    /// path that fixes it, and a writer who cannot read the end of it has been
    /// told nothing — so it must wrap rather than truncate. It does, without the
    /// modifier: same measurement, same reasoning, the longer sentence.
    func test_theHeadersFailureSentenceStillWraps() {
        assertWraps(DiagnosticsPane.headerCopy(for: .failed(.cliNotFound, at: Date())),
                    font: .caption, at: 240)
    }

    /// `sentence` takes more than one line at `width`, drawn with no `fixedSize`
    /// of any kind — and the premise that it does not FIT on one line, without
    /// which the assertion is about nothing.
    ///
    /// `font` is the pane's own for that sentence, and it is a parameter rather
    /// than a default because the premise turns on it: `.callout` and `.caption`
    /// are both narrower than the body font, so measuring the premise at the
    /// default would be asking whether a WIDER sentence fits and answering for a
    /// narrower one.
    private func assertWraps(_ sentence: String, font: Font, at width: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        let oneLine = NSHostingView(
            rootView: AnyView(Text(sentence).font(font))).fittingSize
        XCTAssertGreaterThan(
            oneLine.width, width,
            "premise: \u{201c}\(sentence.prefix(30))…\u{201d} must not fit "
            + "\(width)pt on one line, or nothing below is a question",
            file: file, line: line)

        let wrapped = NSHostingView(
            rootView: AnyView(Text(sentence).font(font).frame(width: width))).fittingSize
        XCTAssertGreaterThan(
            wrapped.height, oneLine.height * 1.5,
            "it must take more than one line at \(width)pt — measured "
            + "\(wrapped.height)pt against a single line's \(oneLine.height)pt",
            file: file, line: line)
    }

    // MARK: - The planted offender

    /// **The diagnosis, kept measurable.** The same three columns with a pane
    /// carrying the removed modifier: every column grows past the window. If
    /// this goes green, AppKit's behaviour has changed and the tests above are
    /// no longer protecting anything.
    func test_plantedOffender_anUnbreakableSentenceGrowsEveryColumn() async throws {
        let store = try await collection(pieces: 8)
        let (window, split, _) = try await mount(store: store, detailWidth: 280) {
            UnbreakableSentencePane()
        }
        let content = try XCTUnwrap(window.contentView).frame.height

        XCTAssertGreaterThan(
            split.frame.height, content + 50,
            "the offender must still reproduce: a sentence with an unbreakable "
            + "vertical demand grows the split view past the window "
            + "(measured \(split.frame.height) against \(content))")
        XCTAssertEqual(split.arrangedSubviews.first?.frame.height ?? -1,
                       split.frame.height, accuracy: 1,
                       "and it takes the binder column with it, which is the "
                       + "part the writer felt")
    }

    // MARK: - Fixtures

    /// The three columns with the REAL `DiagnosticsPane` on the right, showing
    /// the cold-start offer: a never-run document with more than a stub of prose
    /// and no refusal on record (`DiagnosticsPane.showsColdStartOffer`).
    private func mountWithTheOffer() async throws -> (NSWindow, NSSplitView, NSTableView) {
        let store = try await collection(pieces: 8)
        let document = try await twoParagraphDocument(in: store)
        let diagnostics = DiagnosticsStore(
            projectRoot: store.url, device: DeviceSlug.make(from: "test-mac"))
        XCTAssertTrue(
            DiagnosticsPane.showsColdStartOffer(
                state: .neverRun, liveParagraphCount: document.sequence.count,
                hasRefused: diagnostics.hasRefusedColdStart(docId: document.docId)),
            "premise: this document is one the offer is made for")

        let (window, split, table) = try await mount(store: store, detailWidth: 280) {
            DiagnosticsPane(
                orchestrator: CompilerOrchestrator(), diagnostics: diagnostics,
                docId: document.docId, currentText: { _ in nil },
                compilerModel: .standard, activeDocument: { document })
        }
        return (window, split, table)
    }

    private func collection(pieces: Int) async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Cold-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        for i in 1...pieces {
            _ = try await store.addLoosePiece(title: "Piece \(i)", mode: .prose)
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    /// A real, on-disk, multi-paragraph manuscript inside the collection — the
    /// offer's `liveParagraphCount` discriminator reads the same `sequence` the
    /// pane's `promote()` does, so a stand-in would not answer the question.
    private func twoParagraphDocument(in store: ProjectStore) async throws -> Document {
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let path = try XCTUnwrap(piece.path)
        let url = store.url.appendingPathComponent(path)
        try "First paragraph, with some words in it.\n\nSecond paragraph, with more."
            .write(to: url, atomically: true, encoding: .utf8)
        return try await Document.load(url: url, device: "macA", session: "s1",
                                       presenter: nil)
    }

    private func mount<Detail: View>(
        store: ProjectStore, detailWidth: Double,
        @ViewBuilder detail: @escaping () -> Detail
    ) async throws -> (NSWindow, NSSplitView, NSTableView) {
        let window = TestWindow.mount(
            AnyView(ThreeColumnHarness(store: store, probe: BinderSubjectProbe(),
                                       detailWidth: detailWidth, detail: detail)
                .environment(UserPreferences())),
            size: CGSize(width: 1200, height: windowHeight),
            styleMask: [.titled, .resizable])
        windows.append(window)
        _ = await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        await waitOut(0.8)

        var splits: [NSSplitView] = []
        collect(NSSplitView.self, in: try XCTUnwrap(window.contentView), into: &splits)
        let split = try XCTUnwrap(splits.first,
                                  "the NavigationSplitView never reached the "
                                  + "hierarchy — nothing below measures anything")
        XCTAssertEqual(split.arrangedSubviews.count, 3,
                       "premise: three columns, which is the window this bug is about")
        let table = try XCTUnwrap(firstTableView(in: window),
                                  "the binder tree never reached the hierarchy")
        return (window, split, table)
    }

    private func enclosingScrollView(of view: NSView) -> NSScrollView? {
        var next: NSView? = view
        while let current = next {
            if let scroll = current as? NSScrollView { return scroll }
            next = current.superview
        }
        return nil
    }

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}
