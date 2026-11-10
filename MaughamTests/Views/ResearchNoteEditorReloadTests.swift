import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// Which note the hosted editor shows, settable so a test can switch notes
/// on one live editor the way a click in the tree does.
@Observable
@MainActor
final class NoteEditorProbe {
    var itemId: String
    var path: String
    var shareIsReadOnly = false
    init(itemId: String, path: String) {
        self.itemId = itemId
        self.path = path
    }
}

@MainActor
private struct NoteEditorProbeView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let probe: NoteEditorProbe

    var body: some View {
        ResearchNoteEditor(
            store: store, documentStore: documentStore,
            path: probe.path, itemId: probe.itemId,
            previewVisible: false, lockEditing: false,
            shareIsReadOnly: probe.shareIsReadOnly)
    }
}

/// **A note open in the editor takes text written behind its back** (note
/// versions plan 2, Task 3; Review Focus 1 and 2): the editor saves through
/// the note door, a door write for anyone else moves the note's reload count,
/// and the editor re-reads the file — so its next keystroke builds on the new
/// text instead of putting the old text back. Saves are driven by
/// `flushPendingSave`, reloads by awaiting the door call; nothing waits on the
/// debounce clock.
@MainActor
final class ResearchNoteEditorReloadTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var root: URL!
    private var store: ProjectStore!
    private var documentStore: DocumentStore!
    private var preferences: UserPreferences!
    private var defaultsSuite = ""
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        root = TestTemp.root.appendingPathComponent("note-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectURL = try await ProjectFactory.createNovelProject(named: "Reload", in: root)
        store = try await ProjectStore.load(from: projectURL)
        await store.wordCountPopulationTask?.value
        documentStore = try await DocumentStore.open(url: projectURL)
        store.documentStore = documentStore
        documentStore.projectStore = store
        defaultsSuite = "note-reload-\(UUID().uuidString)"
        preferences = UserPreferences(defaults: UserDefaults(suiteName: defaultsSuite)!)
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows = []
        await documentStore?.close()
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    private func note(_ text: String, title: String = "Notes") async throws -> ResearchItem {
        let item = try await store.createResearchNote(scope: .shared, title: title)
        try Data(text.utf8).write(to: file(of: item))
        return item
    }

    private func file(of item: ResearchItem) throws -> URL {
        let now = try XCTUnwrap(store.findResearchItem(id: item.id, in: store.manifest.research))
        return store.url.appendingPathComponent(try XCTUnwrap(now.path))
    }

    private func onDisk(_ item: ResearchItem) throws -> String {
        String(decoding: try Data(contentsOf: file(of: item)), as: UTF8.self)
    }

    private func versionTexts(_ item: ResearchItem) throws -> [String] {
        let versions = ResearchVersionStore(projectURL: store.url)
        return try versions.versions(itemId: item.id).map {
            String(decoding: try versions.read($0).0, as: UTF8.self)
        }
    }

    /// The editor on `item`, mounted, its text view showing the file.
    private func mount(_ item: ResearchItem) async throws -> (NoteEditorProbe, MaughamTextView) {
        let probe = NoteEditorProbe(itemId: item.id, path: try XCTUnwrap(item.path))
        let window = TestWindow.mount(
            NoteEditorProbeView(store: store, documentStore: documentStore, probe: probe)
                .environment(preferences),
            size: CGSize(width: 700, height: 600))
        windows.append(window)
        let expected = try onDisk(item)
        await pumpUntil(deadline: 5) { self.textView(in: window)?.string == expected }
        let textView = try XCTUnwrap(self.textView(in: window),
                                     "the note editor never mounted a text view")
        XCTAssertEqual(textView.string, expected, "premise: the editor shows the file")
        return (probe, textView)
    }

    private func textView(in window: NSWindow) -> MaughamTextView? {
        guard let root = window.contentView else { return nil }
        var found: [MaughamTextView] = []
        collect(in: root, into: &found)
        return found.first
    }

    private func collect(in view: NSView, into out: inout [MaughamTextView]) {
        if let hit = view as? MaughamTextView { out.append(hit) }
        for sub in view.subviews { collect(in: sub, into: &out) }
    }

    /// Type at the end through AppKit's own `shouldChangeText` →
    /// `didChangeText`, which is what reaches the binding. Synchronous: the
    /// binding's setter runs before this returns.
    private func typeAtEnd(_ text: String, into textView: NSTextView) {
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        for character in text {
            let s = String(character)
            let range = textView.selectedRange()
            guard textView.shouldChangeText(in: range, replacementString: s) else { continue }
            textView.textStorage?.replaceCharacters(in: range, with: s)
            textView.setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
            textView.didChangeText()
        }
    }

    private func coordinator(of textView: MaughamTextView) throws -> EditorCoordinator {
        try XCTUnwrap(textView.delegate as? EditorCoordinator)
    }

    // MARK: - Review Focus 1

    func test_aDoorWriteBehindTheEditorIsShown_andTheNextKeystrokeKeepsIt() async throws {
        let item = try await note("A")
        let (_, textView) = try await mount(item)

        let saved = await documentStore.saveResearchNote(itemId: item.id, text: "B", by: .assistant)
        XCTAssertEqual(saved, .saved(keptAVersion: true))
        await pumpUntil(deadline: 5) { textView.string == "B" }
        XCTAssertEqual(textView.string, "B", "the editor shows what was written behind it")
        XCTAssertFalse(documentStore.researchNoteHasPendingSave(itemId: item.id),
                       "the reload schedules no save")

        typeAtEnd("x", into: textView)
        try await documentStore.flushPendingSave()
        XCTAssertEqual(try onDisk(item), "Bx", "the keystroke built on the new text")
    }

    func test_theEditorsOwnSaveDoesNotReloadIt() async throws {
        let item = try await note("Own.")
        let (_, textView) = try await mount(item)
        let coordinator = try coordinator(of: textView)
        let reloads = documentStore.researchNoteReloadCount(itemId: item.id)
        let externals = coordinator.applyExternalTextCallCount

        typeAtEnd(" More.", into: textView)
        try await documentStore.flushPendingSave()
        pump(0.1)

        XCTAssertEqual(try onDisk(item), "Own. More.")
        XCTAssertEqual(documentStore.researchNoteReloadCount(itemId: item.id), reloads,
                       "the editor's own save moves no reload")
        XCTAssertEqual(coordinator.applyExternalTextCallCount, externals,
                       "no applyExternalText for the writer's own typing")
    }

    /// The spec's "a pending unsaved edit is saved first (and so becomes the
    /// version the write replaces)".
    func test_aPendingEditIsSavedBeforeADoorWriteReplacesIt() async throws {
        let item = try await note("A")
        let (_, textView) = try await mount(item)

        typeAtEnd("1", into: textView)
        XCTAssertTrue(documentStore.researchNoteHasPendingSave(itemId: item.id), "premise: unflushed")
        await documentStore.saveResearchNote(itemId: item.id, text: "B")

        XCTAssertEqual(try versionTexts(item).first, "A1",
                       "the newest version is the edit the write replaced")
        XCTAssertEqual(try onDisk(item), "B")
        await pumpUntil(deadline: 5) { textView.string == "B" }
        XCTAssertEqual(textView.string, "B")
    }

    /// **`restoreResearchNote` itself, with the note open and an edit pending**:
    /// the edit is saved first and is the version the restore replaces, the
    /// editor shows the restored text, and its next keystroke builds on it.
    func test_restoringANoteOpenWithAPendingEditKeepsTheEdit_showsTheRestore_andTheNextKeystrokeBuildsOnIt() async throws {
        let item = try await note("A")
        let (_, textView) = try await mount(item)
        await documentStore.saveResearchNote(itemId: item.id, text: "B")
        await pumpUntil(deadline: 5) { textView.string == "B" }
        let kept = try XCTUnwrap(ResearchVersionStore(projectURL: store.url).versions(itemId: item.id)
            .first { (try? String(decoding: ResearchVersionStore(projectURL: store.url).read($0).0, as: UTF8.self)) == "A" })

        typeAtEnd("1", into: textView)
        XCTAssertTrue(documentStore.researchNoteHasPendingSave(itemId: item.id), "premise: unflushed")
        try await documentStore.restoreResearchNote(itemId: item.id, to: kept, shareIsReadOnly: false)

        XCTAssertEqual(try onDisk(item), "A")
        XCTAssertTrue(try versionTexts(item).contains("B1"), "the pending edit was saved and kept")
        await pumpUntil(deadline: 5) { textView.string == "A" }
        XCTAssertEqual(textView.string, "A", "the editor shows the restored text")
        typeAtEnd("x", into: textView)
        try await documentStore.flushPendingSave()
        XCTAssertEqual(try onDisk(item), "Ax", "the next keystroke did not put the old text back")
    }

    /// Typing that lands between the door's write and the editor's reload:
    /// the writer's text stands (it is what they see), and its save keeps what
    /// was written behind it — nothing is lost either way. Made deterministic
    /// by typing from the door's own post-write hook, before the reload
    /// count moves.
    func test_typingBeforeTheReloadLandsKeepsTheWritersText_andWhatWasWrittenBehindIt() async throws {
        let item = try await note("A")
        let (_, textView) = try await mount(item)
        documentStore.researchNoteDoor.wroteForTesting = { [self] id, text in
            guard id == item.id, text == "B" else { return }
            self.typeAtEnd("x", into: textView)   // the editor still shows "A"
        }

        await documentStore.saveResearchNote(itemId: item.id, text: "B")
        documentStore.researchNoteDoor.wroteForTesting = nil
        pump(0.2)
        XCTAssertEqual(textView.string, "Ax", "the writer's newer typing is not replaced")

        try await documentStore.flushPendingSave()
        XCTAssertEqual(try onDisk(item), "Ax")
        XCTAssertTrue(try versionTexts(item).contains("B"),
                      "what was written behind the editor is kept")
    }

    // MARK: - Review Focus 2

    func test_twoNotesEditedInsideOneWindowAreBothSaved_eachUnderItsOwnId() async throws {
        let first = try await note("First.", title: "One")
        let second = try await note("Second.", title: "Two")
        let (probe, textView) = try await mount(first)
        typeAtEnd(" One.", into: textView)

        probe.itemId = second.id
        probe.path = try XCTUnwrap(second.path)
        await pumpUntil(deadline: 5) { self.windows.last.flatMap(self.textView(in:))?.string == "Second." }
        let secondView = try XCTUnwrap(windows.last.flatMap(textView(in:)))
        XCTAssertEqual(secondView.string, "Second.", "premise: the editor switched notes")
        typeAtEnd(" Two.", into: secondView)
        try await documentStore.flushPendingSave()

        XCTAssertEqual(try onDisk(first), "First. One.")
        XCTAssertEqual(try onDisk(second), "Second. Two.")
        XCTAssertEqual(try versionTexts(first), ["First."])
        XCTAssertEqual(try versionTexts(second), ["Second."])
    }

    /// The same, by construction: each note has its own pending slot, so a
    /// schedule for one never drops the other's, flush or no flush between.
    func test_aScheduleForAnotherNoteDoesNotDropTheFirstNotesEdit() async throws {
        let first = try await note("First.", title: "One")
        let second = try await note("Second.", title: "Two")
        documentStore.researchNoteWasRead(itemId: first.id, bytes: Data("First.".utf8))
        documentStore.researchNoteWasRead(itemId: second.id, bytes: Data("Second.".utf8))

        documentStore.scheduleNoteSave(itemId: first.id, text: "First, edited.")
        documentStore.scheduleNoteSave(itemId: second.id, text: "Second, edited.")
        try await documentStore.flushPendingSave()

        XCTAssertEqual(try onDisk(first), "First, edited.")
        XCTAssertEqual(try onDisk(second), "Second, edited.")
    }

    // MARK: - View-only share

    func test_aViewOnlyShareLocksTheNoteEditor() async throws {
        let item = try await note("Shared to read.")
        let (probe, textView) = try await mount(item)
        probe.shareIsReadOnly = true
        let coordinator = try coordinator(of: textView)
        await pumpUntil(deadline: 5) { coordinator.lockEditing }
        XCTAssertTrue(coordinator.lockEditing, "the share's lock reached the editor")

        typeAtEnd("x", into: textView)
        XCTAssertEqual(textView.string, "Shared to read.", "typing is refused")
        XCTAssertFalse(documentStore.researchNoteHasPendingSave(itemId: item.id), "no save is scheduled")
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 6), "selection survives")
    }
}
