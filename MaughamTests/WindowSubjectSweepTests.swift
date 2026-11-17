import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// The window's whole subject, held outside the view so a test can mount the
/// real `SubjectValidationModifier` over it.
@Observable
@MainActor
final class WindowSubjectSweepHarness {
    var store: ProjectStore?
    var subject: WindowSubject
    init(store: ProjectStore, subject: WindowSubject) {
        self.store = store
        self.subject = subject
    }
}

@MainActor
private struct WindowSubjectSweepProbeView: View {
    let harness: WindowSubjectSweepHarness

    var body: some View {
        Color.clear
            .modifier(SubjectValidationModifier(
                store: harness.store, documentStore: nil,
                subject: Binding(get: { harness.subject }, set: { harness.subject = $0 })))
    }
}

/// **The runtime sweep repairs the WHOLE window subject, and never moves a part
/// that still lives** (shell p1 Task 2 review, Critical 1).
///
/// The sweep used to read only `beside ?? faces` and write `.project` back
/// through the click rule: deleting a note beside a chapter jumped the centre
/// to the Book and left the deleted id beside, every later structure change
/// pushed the centre back to the Book, a change anywhere took the canvas out of
/// the centre, and `open` itself was never checked. Each case below is that
/// defect's shape, through the real modifier and the real store.
@MainActor
final class WindowSubjectSweepTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The rule, as a value

    func test_aGoneBesideClearsAndEveryLivingPartStays() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let subject = WindowSubject(open: .item(chapter.id), faces: .item(chapter.id),
                                    beside: .research("gone"))
        XCTAssertEqual(ProjectWindow.validatedSubject(subject, in: store),
                       WindowSubject(open: .item(chapter.id), faces: .item(chapter.id)))
        for open in [BinderSubject.canvas, .inbox, .palette] {
            let living = WindowSubject(open: open, faces: .item(chapter.id))
            XCTAssertEqual(ProjectWindow.validatedSubject(living, in: store), living, "\(open)")
        }
        XCTAssertEqual(
            ProjectWindow.validatedSubject(
                WindowSubject(open: .research("gone"), faces: .research("gone")), in: store),
            .book, "a gone research item open falls back to the Book")
    }

    // MARK: - (a) a deleted beside item clears and leaves `open`

    func test_deletingTheNoteBesideClearsItAndLeavesTheChapterOpen() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "A Note")
        let harness = WindowSubjectSweepHarness(store: store, subject: WindowSubject(
            open: .item(chapter.id), faces: .item(chapter.id), beside: .research(note.id)))
        try await host(harness)

        try await store.deleteResearchItem(id: note.id)
        await settle(until: { harness.subject.beside == nil })

        XCTAssertEqual(harness.subject,
                       WindowSubject(open: .item(chapter.id), faces: .item(chapter.id)),
                       "the deleted note leaves beside; the chapter stays the centre")

        // …and a later structure change does not move the centre either.
        _ = try await store.addStructureItem(parentId: nil, title: "Chapter Two",
                                             kind: .document(.markdown))
        await settle()
        XCTAssertEqual(harness.subject.open, .item(chapter.id))
    }

    // MARK: - (b) a structure change with a place open keeps it open

    func test_aStructureChangeKeepsTheCanvasTheInboxAndAnEditionOpen() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        _ = try await store.translatorRole(for: "es")
        for open in [BinderSubject.canvas, .inbox, .edition(language: "es")] {
            let subject = WindowSubject(open: open, faces: .item(chapter.id))
            let harness = WindowSubjectSweepHarness(store: store, subject: subject)
            try await host(harness)

            _ = try await store.addStructureItem(parentId: nil, title: "Another",
                                                 kind: .document(.markdown))
            _ = try await store.addResearchTextNote(parentId: nil, title: "A capture")
            await settle()

            XCTAssertEqual(harness.subject, subject, "\(open) stays the centre")
        }
    }

    // MARK: - (c) a deleted research item in `open` falls back to the Book

    func test_deletingTheResearchItemOpenInTheCentreFallsBackToTheBook() async throws {
        let store = try await novel()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Open Note")
        let other = try await store.addResearchTextNote(parentId: nil, title: "Beside Note")
        let harness = WindowSubjectSweepHarness(store: store, subject: WindowSubject(
            open: .research(note.id), faces: .research(note.id), beside: .research(other.id)))
        try await host(harness)

        try await store.deleteResearchItem(id: note.id)
        await settle(until: { harness.subject.open == .project })

        XCTAssertEqual(harness.subject,
                       WindowSubject(open: .project, faces: .project, beside: .research(other.id)),
                       "the centre names nothing gone; what is beside still lives and stays")
    }

    // MARK: - Fixtures

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Sweep-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    private func host(_ harness: WindowSubjectSweepHarness) async throws {
        let window = TestWindow.mount(
            AnyView(WindowSubjectSweepProbeView(harness: harness)),
            size: CGSize(width: 320, height: 240))
        windows.append(window)
        await settle()
    }

    /// `until` ends the wait as soon as the asserted state holds; with none, a
    /// fixed window for the cases asserting that nothing moved.
    private func settle(until condition: (() -> Bool)? = nil) async {
        if let condition {
            await pumpUntil(deadline: 5, condition)
            return
        }
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
