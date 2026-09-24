import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

/// **F7 final round, C1: a piece closed out from under the editor comes back
/// as a live document, never as a husk.**
///
/// The store can close the `Document` an `EditorHost` is holding without the
/// host doing anything: the adoption of a manifest another device wrote that
/// no longer holds the piece (`letGoOfPiecesMovedElsewhere`), or this Mac's
/// own trash (`closeFlushAndUnregister`). The host keeps the closed instance
/// with `loadedItemId`/`priorLoadedPath` unchanged. When the piece comes back
/// at the SAME path, nothing about the id or the path used to ask for a
/// reload, so the editor bound the husk: blank text, and every keystroke went
/// to `setFullText` on a closed document and was dropped.
///
/// Driven through the store and the host directly — no control is pressed
/// (tripwire 33). What is asserted is where the writer's words go: typed after
/// the return, they must be in the op log.
@MainActor
final class EditorHostClosedDocumentTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Mounts `EditorHost`, which styles through production typography.
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []
    private var defaultsSuites: [String] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        for suite in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        defaultsSuites.removeAll()
        temp.cleanup()
        temp = nil
    }

    private struct Mounted {
        let url: URL
        let store: ProjectStore
        let ds: DocumentStore
        let item: StructureItem
        let path: String
        let window: NSWindow
    }

    private static let seed = "The sentence the chapter began with."

    /// A novel whose first chapter carries a sentence, open in a real
    /// `EditorHost`, wired both ways as `ProjectWindow` wires the two stores.
    private func mountFirstChapter() async throws -> Mounted {
        let url = try await ProjectFactory.createNovelProject(
            named: "Husk-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let item = try XCTUnwrap(ProjectStore.collectDocuments(
            in: store.manifest.structure).first)
        let path = try XCTUnwrap(item.path)
        try (Self.seed + "\n").write(
            to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        await store.wordCountPopulationTask?.value
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        ds.projectStore = store
        documentStores.append(ds)

        let suite = "editor-host-closed-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let root = EditorHost(store: store, documentStore: ds,
                              selectedItemId: item.id, control: EditorControl())
            .environment(preferences)
        let window = TestWindow.mount(AnyView(root),
                                      size: CGSize(width: 800, height: 600),
                                      as: SilentTestWindow.self)
        windows.append(window)
        let opened = await pumpUntil(deadline: 5) {
            self.textView(in: window)?.string.contains(Self.seed) ?? false
        }
        XCTAssertTrue(opened, "precondition: the chapter opened in the editor")
        return Mounted(url: url, store: store, ds: ds, item: item, path: path, window: window)
    }

    private func textView(in window: NSWindow) -> MaughamTextView? {
        guard let root = window.contentView else { return nil }
        var found: [MaughamTextView] = []
        func walk(_ view: NSView) {
            if let hit = view as? MaughamTextView { found.append(hit) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.first
    }

    private func manifestURL(_ url: URL) -> URL {
        url.appendingPathComponent(ProjectManifest.fileName)
    }

    /// Another device's manifest, written to disk and announced the way the
    /// presenter announces one.
    private func anotherDeviceWrites(_ manifest: ProjectManifest, _ m: Mounted) throws {
        try ProjectManifest.makeEncoder().encode(manifest)
            .write(to: manifestURL(m.url), options: [.atomic])
        m.ds.presenterDidChangeSubitem(at: manifestURL(m.url))
    }

    /// Type at the end of whatever the editor shows, then let the Document
    /// the store now holds for the path go, so what it took is in the op log.
    private func typeAndSettle(_ words: String, _ m: Mounted) async throws {
        let bound = await pumpUntil(deadline: 5) {
            self.textView(in: m.window)?.string.contains(Self.seed) ?? false
        }
        XCTAssertTrue(bound, "the returning chapter must show its words, not the "
                      + "blank text of a closed husk")
        let editor = try XCTUnwrap(textView(in: m.window))
        editor.insertText(words, replacementRange: NSRange(
            location: (editor.string as NSString).length, length: 0))
        pump(0.05)
        let live = try XCTUnwrap(m.ds.document(for: m.path),
                                 "the returning chapter was never re-opened: the editor "
                                 + "is still holding the Document the store closed")
        await live.close()
    }

    private func opLogWords(_ m: Mounted) throws -> String {
        let state = try DerivedManuscript.derivedState(forDocId: m.item.id, in: m.url)
        return state.paragraphs.values.joined(separator: " ")
    }

    /// Another device's outline drops the chapter open here (the adoption
    /// closes it), then another device's outline has it back at the SAME path.
    func test_aPieceRemovedElsewhereThatReturnsAtTheSamePathTakesTyping() async throws {
        let m = try await mountFirstChapter()
        let withIt = m.store.manifest
        let open = try XCTUnwrap(m.ds.document(for: m.path))

        var without = withIt
        without.structure = TreeWalk.remove(id: m.item.id, in: without.structure)
        try anotherDeviceWrites(without, m)
        await pumpUntil(deadline: 5) { open.isClosed }
        XCTAssertTrue(open.isClosed, "precondition: the adoption closed the open piece")

        try anotherDeviceWrites(withIt, m)
        XCTAssertEqual(TreeWalk.find(id: m.item.id, in: m.store.manifest.structure)?.path,
                       m.path, "precondition: it came back at the same path")

        try await typeAndSettle(" Typed after it came back.", m)
        XCTAssertTrue(try opLogWords(m).contains("Typed after it came back."),
                      "the keystrokes went to a closed Document and were dropped")
    }

    /// This Mac's own delete closes the open piece through the typed mover;
    /// Restore from Trash puts it back at the same path with the same id.
    func test_aPieceTrashedHereAndRestoredTakesTyping() async throws {
        let m = try await mountFirstChapter()
        let open = try XCTUnwrap(m.ds.document(for: m.path))

        try await m.store.deleteStructureItem(id: m.item.id)
        XCTAssertTrue(open.isClosed, "precondition: the trash closed the open piece")
        // The writer sees the chapter gone before restoring it: the host
        // renders with no item, as it does between two real gestures.
        pump(0.1)
        let entry = try XCTUnwrap(m.store.trashEntries.first)
        _ = try await m.store.restoreTrashEntry(id: entry.id)
        XCTAssertEqual(TreeWalk.find(id: m.item.id, in: m.store.manifest.structure)?.path,
                       m.path, "precondition: it came back at the same path")

        try await typeAndSettle(" Typed after the restore.", m)
        XCTAssertTrue(try opLogWords(m).contains("Typed after the restore."),
                      "the keystrokes went to a closed Document and were dropped")
    }
}
