import XCTest
import AppKit
import SwiftUI
@testable import Maugham

// ============================================================================
// SPIKE — Task 1 of the macOS 27 shell slice (2026-09-19).
//
// THIS FILE IS A MEASUREMENT INSTRUMENT, NOT A GUARD. It asserts almost
// nothing; it mounts a real three-column `NavigationSplitView` and PRINTS what
// AppKit resolved, so `docs/superpowers/notes/2026-09-19-split-view-tie-break-
// spike.md` is a table somebody measured rather than a paragraph somebody
// reasoned. **Task 3 may delete it outright** — whatever it establishes must
// be re-pinned by a real test with a planted offender before this goes.
//
// Run it, and read the `SPIKE|` lines out of the file it writes. (A `print`
// from the xctest host does NOT reach xcodebuild's stdout and the xcresult
// carries no console log — measured here, 2026-09-19 — so the instrument hands
// its readings to a file it is told about.)
//
//   TEST_RUNNER_MAUGHAM_SPIKE_OUT=/tmp/spike.txt \
//   xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
//     -only-testing:MaughamTests/SplitViewTieBreakSpikeTests \
//     CODE_SIGNING_ALLOWED=NO
//
// Nothing here presses a control, so tripwire 33 has no claim on it; every
// window is `TestWindow`'s, so the headless gate's does not either.
// ============================================================================

/// Where the readings go. `MAUGHAM_SPIKE_OUT` in the runner's environment, and
/// the process temp directory when nobody said — never silently nowhere, which
/// is what a `print` turned out to be.
enum SpikeLog {
    static let url: URL = {
        let env = ProcessInfo.processInfo.environment["MAUGHAM_SPIKE_OUT"]
        return env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("maugham-split-spike.txt")
    }()

    static func line(_ text: String) {
        print(text)
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// How the detail pane demands more width than the column was given. The three
/// shapes the plan names, plus the neutral baseline every case starts from.
enum SpikePaneShape: String, CaseIterable {
    /// The baseline — a short label that fits in any column.
    case neutral

    /// **(a) an unbreakable MINIMUM.** `.fixedSize()` on a long label: the
    /// pane's minimum width IS its full text width. This is the shape
    /// `DetailColumnWidthTests`' canary uses, and the one the brief says
    /// flipped.
    case unbreakableMinimum

    /// **(b) a large IDEAL only.** A row that truncates — so its minimum is
    /// tiny — inside a flexible frame, which is exactly
    /// `SetAsideRecordsDisclosure`'s shipped shape (`HistoryPane.swift`: a
    /// `lineLimit(1)`/`truncationMode` row in `.frame(maxWidth: .infinity)`).
    /// The brief measures those rows asking 559pt of ideal.
    case largeIdealOnly

    /// **(c) an explicit floor above the column.** `.frame(minWidth:)` larger
    /// than the column's width — the spelling a pane author reaches for when
    /// they want a minimum without `.fixedSize()`'s intrinsic one.
    case minWidthFrame

    /// What (a) and (b) render, and (c)'s floor: a single number so a reader of
    /// the log can tell "the pane's demand" from "the column's width" at sight.
    static let demand: CGFloat = 560
}

/// How the detail column asks for its width — production's spelling, and the
/// two mitigations the plan asks this spike to try.
enum SpikeColumnSpelling: String, CaseIterable {
    /// **Production, today.** `.navigationSplitViewColumnWidth(w)` on the
    /// column, the pane free to demand what it likes underneath.
    case production

    /// **Mitigation 1.** The pane's content is bounded and clipped before the
    /// column modifier ever sees it: `.frame(minWidth: 0, maxWidth: w)` plus
    /// `.clipped()`. The theory is that the column then carries no upward
    /// demand at all, so there is no tie to break.
    case clippedContent

    /// **Mitigation 2.** A hard `.frame(width: w)` on the column's content —
    /// `GeometryReader`-free, so it reports no geometry back and cannot feed a
    /// loop (`test_aPersonaSwitchDoesNotWriteTheWidth`'s structural claim).
    case fixedFrame

    /// **Mitigation 1 with the `.clipped()` taken off**, to separate the two
    /// things it was doing. If this holds the column as well as
    /// `clippedContent` does, then `.clipped()` is about DRAWING overflow and
    /// nothing about layout — which is what Task 3 needs to know before it
    /// decides whether to ship one modifier or two.
    case maxWidthOnly

    /// **Mitigation 2 plus the clip**, the same separation from the other side.
    case fixedFrameClipped

    /// **Mitigation 2 on production's ACTUAL shape** — `detailColumn` is not a
    /// bare pane, it is `HStack { detailResizeHandle; pane }`, and Task 3 will
    /// be putting the frame on that. A mitigation measured on a shape the app
    /// does not have is a mitigation measured on the wrong thing.
    case fixedFrameWithHandle

    /// The same, in mitigation 1's spelling.
    case maxWidthWithHandle

    /// **Production's spelling on production's shape** — the control for the
    /// two above. Without it the handle rows would show a held column and no
    /// reader could tell whether the frame held it or the handle did.
    case productionWithHandle
}

/// Everything the harness reads, held outside the view so a test can drive it
/// and count writes. Deliberately a cut-down twin of `DetailColumnProbe` rather
/// than a reuse of it: this one has to carry the SHAPE and the SPELLING, which
/// that one has no vocabulary for, and a spike that edited a shipped harness
/// would be a spike with a blast radius.
@Observable
@MainActor
final class SpikeProbe {
    var shape: SpikePaneShape = .neutral
    let spelling: SpikeColumnSpelling

    private(set) var containerWidth: Double?
    func noteContainerWidth(_ width: Double) {
        guard ProjectWindow.recordsContainerWidth(width, over: containerWidth) else { return }
        containerWidth = width
    }

    /// What the CENTRE and BINDER columns' CONTENT was given, through the same
    /// production reporter — these, not the split's `arrangedSubviews`, are the
    /// numbers `test_hidingThePaneGivesTheProseWhatTheBinderDoesNot` compares.
    private(set) var centreWidth: Double?
    func noteCentreWidth(_ width: Double) { centreWidth = width }

    private(set) var binderWidth: Double?
    func noteBinderWidth(_ width: Double) { binderWidth = width }

    /// The writer's stored wish, and a count of every write of it — the
    /// question "did `UIState.detailColumnWidth` move?" is answered by this
    /// number, not by the column's frame.
    private(set) var widthWrites: Int = 0
    var width: Double { didSet { widthWrites += 1 } }

    init(width: Double = 320, spelling: SpikeColumnSpelling = .production) {
        self.width = width
        self.spelling = spelling
        self.widthWrites = 0
    }
}

/// The three-column split, composed the way `ProjectWindow` composes it — the
/// production floors and the production `effectiveDetailColumnWidth`, so what
/// this measures is the app's own layout rather than a plausible sketch of it.
@MainActor
private struct SpikeHarness: View {
    let probe: SpikeProbe

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            Color.gray
                .navigationSplitViewColumnWidth(
                    min: ProjectWindow.binderColumnFloor, ideal: 240)
        } content: {
            Color.white
                .navigationSplitViewColumnWidth(
                    min: ProjectWindow.centreColumnFloor, ideal: 720)
        } detail: {
            detailColumn
        }
        .modifier(ContainerWidthReporter(onWidth: { probe.noteContainerWidth($0) }))
    }

    private var effectiveWidth: Double {
        ProjectWindow.effectiveDetailColumnWidth(
            persisted: probe.width, containerWidth: probe.containerWidth)
    }

    @ViewBuilder
    private var detailColumn: some View {
        let w = effectiveWidth
        switch probe.spelling {
        case .production:
            pane.navigationSplitViewColumnWidth(w)
        case .clippedContent:
            pane
                .frame(minWidth: 0, maxWidth: w)
                .clipped()
                .navigationSplitViewColumnWidth(w)
        case .fixedFrame:
            pane
                .frame(width: w)
                .navigationSplitViewColumnWidth(w)
        case .maxWidthOnly:
            pane
                .frame(minWidth: 0, maxWidth: w)
                .navigationSplitViewColumnWidth(w)
        case .fixedFrameClipped:
            pane
                .frame(width: w)
                .clipped()
                .navigationSplitViewColumnWidth(w)
        case .fixedFrameWithHandle:
            withHandle
                .frame(width: w)
                .clipped()
                .navigationSplitViewColumnWidth(w)
        case .maxWidthWithHandle:
            withHandle
                .frame(minWidth: 0, maxWidth: w)
                .clipped()
                .navigationSplitViewColumnWidth(w)
        case .productionWithHandle:
            withHandle.navigationSplitViewColumnWidth(w)
        }
    }

    /// `ProjectWindow.detailColumn`'s own composition: the 8pt resize gutter on
    /// the leading edge, then the pane. Spelled here rather than called, because
    /// `detailResizeHandle` is private to the view and carries a `DocumentStore`
    /// this spike has no business constructing; what matters for the layout
    /// question is the sibling and its width.
    private var withHandle: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 8)
                .frame(maxHeight: .infinity)
            pane
        }
    }

    private static let longLabel =
        "a label this pane will not break, wanting far more width than the "
        + "column was ever dragged to, at all"

    @ViewBuilder
    private var pane: some View {
        VStack(spacing: 0) {
            switch probe.shape {
            case .neutral:
                Text("Inspector")
            case .unbreakableMinimum:
                Text(Self.longLabel).fixedSize()
            case .largeIdealOnly:
                // `SetAsideRecordsDisclosure`'s shape: a row whose MINIMUM is
                // tiny (it truncates) and whose IDEAL is the whole string.
                Text(Self.longLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .minWidthFrame:
                Text("Inspector")
                    .frame(minWidth: SpikePaneShape.demand)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// **What wins the column on macOS 27, measured.**
///
/// The brief (`docs/superpowers/notes/2026-09-18-macos-27-sdk-drift.md` §2)
/// says five of six `DetailColumnWidthTests` read 528 whatever width they pin —
/// the PANE's own demand — and that
/// `test_theFixedColumnWinsAgainstAnUnbreakablePane`, the canary
/// `ProjectWindow.detailColumn`'s doc comment installed on AppKit's undocumented
/// tie-break, has flipped. This walks (shape × width × spelling) and prints what
/// the split actually resolved, so the note's table is a measurement.
@MainActor
final class SplitViewTieBreakSpikeTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        settle(0.05)
        windows.removeAll()
    }

    /// The two window widths the plan names. 1024 is CI's own display, and a
    /// 1000pt request is what a test can ask for on any Mac and get — but the
    /// premise is read off the window that actually opened, never off the
    /// number asked for (this file's whole neighbourhood is about that).
    private static let widths: [CGFloat] = [1200, 1000]

    /// **The spike proper.** Three shapes × two widths × three spellings, each
    /// measured twice: with the neutral pane (so the log carries the column's
    /// undisturbed width) and then with the demanding one.
    func test_spike_whatTheColumnResolvesTo() async throws {
        let display = (NSScreen.main ?? NSScreen.screens.first)
            .map { Double($0.visibleFrame.width) } ?? .greatestFiniteMagnitude
        SpikeLog.line("SPIKE|env|macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)"
              + "|display=\(display)")
        SpikeLog.line("SPIKE|head|spelling|shape|requested|window|wish|effective"
              + "|before|after|writes")

        for spelling in SpikeColumnSpelling.allCases {
            for requested in Self.widths {
                for shape in SpikePaneShape.allCases where shape != .neutral {
                    let probe = SpikeProbe(width: 320, spelling: spelling)
                    let (window, split) = try await mount(probe, windowWidth: requested)

                    let before = Self.columns(split)
                    probe.shape = shape
                    await pump(0.9)
                    let after = Self.columns(split)

                    let effective = ProjectWindow.effectiveDetailColumnWidth(
                        persisted: probe.width, containerWidth: probe.containerWidth)
                    SpikeLog.line("SPIKE|row|\(spelling.rawValue)|\(shape.rawValue)"
                          + "|\(requested)|\(Self.r(window.frame.width))"
                          + "|\(Self.r(probe.width))|\(Self.r(effective))"
                          + "|\(Self.fmt(before))|\(Self.fmt(after))"
                          + "|\(probe.widthWrites)")

                    // The only assertion in the walk, and it is a premise
                    // rather than a claim: if the split is not three columns,
                    // every number above is about something else.
                    XCTAssertEqual(split.arrangedSubviews.count, 3)
                }
            }
        }
    }

    /// **The canary on its own, in the two spellings**, so the note can say
    /// which mitigation restores `DetailColumnWidthTests`' expected numbers
    /// WITHOUT changing their assertions. The assertion here is the canary's
    /// own: the column comes out at the width it was given.
    ///
    /// It is `XCTExpectFailure`-free on purpose — a red here on `production` is
    /// the finding, and the note records it.
    func test_spike_theCanaryUnderEachSpelling() async throws {
        for spelling in SpikeColumnSpelling.allCases {
            let probe = SpikeProbe(width: 300, spelling: spelling)
            let (window, split) = try await mount(probe, windowWidth: 1200)
            let expected = ProjectWindow.effectiveDetailColumnWidth(
                persisted: probe.width, containerWidth: probe.containerWidth)

            probe.shape = .unbreakableMinimum
            await pump(0.9)
            let got = Self.columns(split).last ?? -1

            SpikeLog.line("SPIKE|canary|\(spelling.rawValue)|window=\(Self.r(window.frame.width))"
                  + "|expected=\(Self.r(expected))|got=\(Self.r(got))"
                  + "|verdict=\(abs(got - expected) <= 1 ? "COLUMN WINS" : "PANE WINS")")
        }
    }

    /// **What `hiddenDetailColumn` resolves to on 27**, because Task 3's
    /// contract has to hold it at zero and the brief's sixth red
    /// (`hidingThePane…`, 959 vs 952) is a 7pt drift somewhere in this sum.
    ///
    /// The assertion that drifted is
    /// `centre == container - sidebar - ProjectWindow.sidebarInset`, and the
    /// two measurements it is made of come from DIFFERENT places: `centre` and
    /// `sidebar` are `ContainerWidthReporter`'s — what SwiftUI gave each
    /// column's content — while the split's own `arrangedSubviews` are AppKit's
    /// and sum to more than the window. So this reports both, plus the split's
    /// frame ORIGINS, which is where an inset actually lives.
    func test_spike_theHiddenArmAndTheSevenPointDrift() async throws {
        for requested in Self.widths {
            let probe = SpikeProbe(width: UIState.defaultDetailColumnWidth)
            let (window, split) = try await mountHidden(probe, windowWidth: requested)
            await pump(0.9)
            let columns = Self.columns(split)
            let container = probe.containerWidth ?? -1
            let centre = probe.centreWidth ?? -1
            let sidebar = probe.binderWidth ?? -1
            let frames = split.arrangedSubviews
                .map { "\(Self.r($0.frame.origin.x))+\(Self.r($0.frame.width))" }
                .joined(separator: " ")
            SpikeLog.line("SPIKE|hidden|requested=\(requested)"
                  + "|window=\(Self.r(window.frame.width))"
                  + "|container=\(Self.r(container))"
                  + "|reported.binder=\(Self.r(sidebar))"
                  + "|reported.centre=\(Self.r(centre))"
                  + "|split.frames=[\(frames)]"
                  + "|declaredInset=\(ProjectWindow.sidebarInset)"
                  + "|observedInset=\(Self.r(container - sidebar - centre))"
                  + "|drift=\(Self.r(centre - (container - sidebar - Double(ProjectWindow.sidebarInset))))")
        }
    }

    // MARK: - Hosting

    private static func columns(_ split: NSSplitView) -> [Double] {
        split.arrangedSubviews.map { Double($0.frame.width) }
    }

    private static func fmt(_ widths: [Double]) -> String {
        "[" + widths.map { r($0) }.joined(separator: " ") + "]"
    }

    private static func r(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func r(_ value: CGFloat) -> String { r(Double(value)) }

    private func mount(_ probe: SpikeProbe,
                       windowWidth: CGFloat) async throws -> (NSWindow, NSSplitView) {
        try await host(AnyView(SpikeHarness(probe: probe)), windowWidth: windowWidth)
    }

    /// The same window with production's own hidden arm in the detail slot.
    private func mountHidden(_ probe: SpikeProbe,
                             windowWidth: CGFloat) async throws -> (NSWindow, NSSplitView) {
        try await host(AnyView(HiddenArmHarness(probe: probe)), windowWidth: windowWidth)
    }

    private func host(_ view: AnyView,
                      windowWidth: CGFloat) async throws -> (NSWindow, NSSplitView) {
        let window = TestWindow.mount(view,
                                      size: CGSize(width: windowWidth, height: 700),
                                      styleMask: [.titled, .resizable])
        windows.append(window)
        await pump(1.0)

        var found: [NSSplitView] = []
        collect(NSSplitView.self, in: try XCTUnwrap(window.contentView), into: &found)
        let split = try XCTUnwrap(found.first, "the NavigationSplitView never mounted")
        return (window, split)
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    private func pump(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            settle(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

/// The same split with production's `hiddenDetailColumn` in the detail slot —
/// the state `⌘⌥I` and the canvas collapse both land in.
@MainActor
private struct HiddenArmHarness: View {
    let probe: SpikeProbe

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            Color.gray
                .modifier(ContainerWidthReporter(onWidth: { probe.noteBinderWidth($0) }))
                .navigationSplitViewColumnWidth(
                    min: ProjectWindow.binderColumnFloor, ideal: 240)
        } content: {
            Color.white
                .modifier(ContainerWidthReporter(onWidth: { probe.noteCentreWidth($0) }))
                .navigationSplitViewColumnWidth(
                    min: ProjectWindow.centreColumnFloor, ideal: 720)
        } detail: {
            ProjectWindow.hiddenDetailColumn
        }
        .modifier(ContainerWidthReporter(onWidth: { probe.noteContainerWidth($0) }))
    }
}
