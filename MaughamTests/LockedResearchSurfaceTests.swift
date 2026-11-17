import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A locked window reads research and palette cards; it doesn't edit them
/// from its own columns** (shell p1 Task 5) — what Review's adjudicating
/// columns did before the personas went (Denver's ruling, shell-finish stage
/// 3b Task 6), now the window's Lock (`WindowLock`).
///
/// One answer, `WindowLock.refusesEdits(isLocked:)`, read by both mounts:
/// `ResearchSubjectCentre`'s own `readOnly` and `PaletteWallCentre`'s card
/// arm. This suite mounts the two surfaces directly — the way
/// `PaletteWallDoorTests` already mounts `PaletteWallCentre` alone — because
/// the contract under test is what ONE column draws while locked or not, not
/// how a tree click gets there (`ResearchSubjectRoutingTests`).
@MainActor
final class LockedResearchSurfaceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // This suite mounts EditorSurface and the palette editor/read view,
        // all of which style text through production typography.
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []
    private var defaultsSuites: [String] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

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
        NSPasteboard.general.clearContents()
        temp.cleanup()
        temp = nil
    }

    /// `ResearchNoteEditor` reads `@Environment(UserPreferences.self)`
    /// (ADR 0017) — absent here, `ResearchSubjectRoutingTests.host()`'s own
    /// mount injects it on the root. A direct mount of `ResearchSubjectCentre`
    /// needs the same environment object or the note arm crashes on the
    /// missing `@Environment` (measured: `EnvironmentValues.subscript.getter`
    /// assertion, `AG::Graph::update_attribute`).
    private func makePreferences() -> UserPreferences {
        let suite = "locked-research-surface-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        return UserPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    private static let noteText = "Ships at anchor, unhurried."
    private static let cardBody = "Salt air, gulls overhead."

    // MARK: - ResearchSubjectCentre: the note

    /// **Locked, not hidden** — §4's "reference view". The note's own text
    /// must still be the centre column, and the mounted editor's own
    /// coordinator — the thing `EditorEditPolicy.allowsTextMutation` actually
    /// gates every keystroke on (`EditorCoordinator.shouldChangeTextIn`) — must
    /// carry the lock.
    func test_aLockedWindowLocksTheNoteEditorInTheCentre() async throws {
        let (store, note) = try await storeWithNote(text: Self.noteText)
        let window = try await hostCentre(store: store, itemID: note.id, isLocked: true)

        await pumpUntil(deadline: 5) {
            self.textViews(in: window).contains { $0.string.contains(Self.noteText) }
        }
        let editor = try XCTUnwrap(
            textViews(in: window).first { $0.string.contains(Self.noteText) },
            "the note's own text must still be in the centre column — locked, not hidden")
        XCTAssertEqual(editor.coordinator?.lockEditing, true,
                       "the Lock's readOnly must reach the coordinator's hard floor")
        XCTAssertFalse(
            EditorEditPolicy.allowsTextMutation(
                isReviewMode: editor.coordinator?.isReviewMode ?? false,
                lockEditing: editor.coordinator?.lockEditing ?? false),
            "…and the membrane the coordinator gates keystrokes on must actually refuse them")
        XCTAssertTrue(editor.isSelectable, "selection must survive the lock")
    }

    /// **The control: an unlocked window is unaffected.** Without this, a
    /// `readOnly` wired backwards (locking every window) would still pass the
    /// test above.
    func test_anUnlockedWindowLeavesTheNoteEditorEditable() async throws {
        let (store, note) = try await storeWithNote(text: Self.noteText)
        let window = try await hostCentre(store: store, itemID: note.id, isLocked: false)

        await pumpUntil(deadline: 5) {
            self.textViews(in: window).contains { $0.string.contains(Self.noteText) }
        }
        let editor = try XCTUnwrap(
            textViews(in: window).first { $0.string.contains(Self.noteText) })
        XCTAssertEqual(editor.coordinator?.lockEditing, false,
                       "an unlocked window must reach the centre with its editor editable")
    }

    /// **A locked note must not write a file to disk on paste** (review
    /// finding on this task). `EditorSurface.paste(_:)` calls the image-paste
    /// handler SYNCHRONOUSLY and BEFORE `insertText` —
    /// `ImagePasteHandler.saveAndReference` writes the PNG to
    /// `<slug>_assets/` on disk first, and only THEN does the locked
    /// `shouldChangeTextIn` refuse the markdown ref. The write is not text
    /// mutation, so `lockEditing` never gated it on its own — the fix is
    /// `ResearchNoteEditor` not wiring the handler at all while locked
    /// (`imagePasteHandler: locked ? nil : makeImagePasteHandler()`),
    /// which this test pins from the outside: drive the REAL paste path
    /// (`MaughamTextView.paste(_:)`, not a hand call into the store) and
    /// assert nothing landed in the well.
    func test_aLockedNoteRefusesAnImagePaste_noFileLands() async throws {
        let (store, note) = try await storeWithNote(text: Self.noteText)
        let assets = try assetsWell(for: note, in: store)
        let window = try await hostCentre(store: store, itemID: note.id, isLocked: true)

        await pumpUntil(deadline: 5) {
            self.textViews(in: window).contains { $0.string.contains(Self.noteText) }
        }
        let editor = try XCTUnwrap(
            textViews(in: window).first { $0.string.contains(Self.noteText) })
        XCTAssertTrue(files(in: assets).isEmpty, "precondition: nothing in the well yet")

        try putImageOnTheClipboard()
        editor.paste(nil)
        // Negative assertion: a fixed wait outlasting the synchronous write
        // path this bug used, rather than a `pumpUntil` with nothing to wait
        // for — `waitOut`'s own documented use.
        await waitOut(0.5)

        XCTAssertTrue(
            files(in: assets).isEmpty,
            "a locked note must never write a file to disk on paste — found \(files(in: assets))")
        XCTAssertEqual(editor.string, Self.noteText,
                       "…and the note's text must be unchanged too")
    }

    /// **The control: an unlocked window's paste still saves and references.** Without
    /// this, a handler wired backwards (nil for everyone) would still pass
    /// the test above.
    func test_anUnlockedNoteStillSavesAndReferencesAnImagePaste() async throws {
        let (store, note) = try await storeWithNote(text: Self.noteText)
        let assets = try assetsWell(for: note, in: store)
        let window = try await hostCentre(store: store, itemID: note.id, isLocked: false)

        await pumpUntil(deadline: 5) {
            self.textViews(in: window).contains { $0.string.contains(Self.noteText) }
        }
        let editor = try XCTUnwrap(
            textViews(in: window).first { $0.string.contains(Self.noteText) })

        try putImageOnTheClipboard()
        editor.paste(nil)
        await pumpUntil(deadline: 5) { !self.files(in: assets).isEmpty }

        let landed = files(in: assets)
        XCTAssertEqual(landed.count, 1, "found \(landed)")
        XCTAssertTrue(landed.first?.hasSuffix(".png") == true, "found \(landed)")
        await pumpUntil(deadline: 5) { editor.string.contains("![](./") }
        XCTAssertTrue(editor.string.contains("![](./\(assets.lastPathComponent)/"),
                      "the ref must land in the editor text too, got: \(editor.string)")
    }

    // MARK: - ResearchSubjectCentre: the palette card

    /// **No editable field, no mutation verb reachable.** `PaletteCardEditor`'s
    /// Kind picker is a segmented control and nothing else in this mount draws
    /// one (`ResearchSubjectRoutingTests`' own precedent); its absence plus no
    /// editable `NSTextField` anywhere rules the editor out. The card's own
    /// body text (via accessibility, skipped where no assistive client is
    /// attached — `DiagnosticsPaneTests`' guard) is the positive half: this is
    /// `PaletteCardReadView` actually drawing the card, not an empty/missing
    /// state that happens to have no segmented control either.
    func test_aLockedWindowShowsTheReadOnlyCardNotTheEditor() async throws {
        let (store, card) = try await storeWithCard(title: "Harbour", body: Self.cardBody)
        let window = try await hostCentre(store: store, itemID: card.id, isLocked: true)

        await pumpUntil(deadline: 5) { !self.allStringsIgnoringSkip(in: window).isEmpty }
        XCTAssertTrue(
            segmentedControls(in: window).isEmpty,
            "PaletteCardEditor's Kind picker must not be reachable from a locked centre")
        XCTAssertTrue(
            textFields(in: window).filter(\.isEditable).isEmpty,
            "no editable field of any kind — a locked window's card is a reference view")

        do {
            let strings = try axStrings(in: window)
            XCTAssertTrue(
                strings.contains { $0.contains(Self.cardBody) },
                "the card's own body must be drawn — otherwise the absence above could just as "
                + "easily be the empty/missing state, found: \(strings)")
        } catch { throw error }  // XCTSkip when no assistive client is attached
    }

    /// The control: an unlocked window's card in the centre is still the
    /// visual editor — pinned so nothing above (segmented-control /
    /// editable-field absence) is read as "the card mounts nothing editable
    /// in ANY window".
    func test_anUnlockedWindowShowsTheCardEditor() async throws {
        let (store, card) = try await storeWithCard(title: "Harbour", body: Self.cardBody)
        let window = try await hostCentre(store: store, itemID: card.id, isLocked: false)

        await pumpUntil(deadline: 5) { !self.segmentedControls(in: window).isEmpty }
        XCTAssertFalse(
            segmentedControls(in: window).isEmpty,
            "an unlocked window must still reach PaletteCardEditor's Kind picker")
    }

    // MARK: - PaletteWallCentre: the wall's own card click

    /// **The wall's card click in a locked window shows the read view under
    /// the existing back-chevron header** — never the editor.
    func test_aLockedWallCardClickShowsTheReadOnlyCardUnderTheChevron() async throws {
        let (store, card) = try await storeWithCard(title: "Harbour", body: Self.cardBody)
        let window = try await hostWall(store: store, selectedCardId: card.id, isLocked: true)

        await pumpUntil(deadline: 5) { !self.allStringsIgnoringSkip(in: window).isEmpty }
        XCTAssertTrue(
            segmentedControls(in: window).isEmpty,
            "the wall's card click in a locked window must not reach PaletteCardEditor's Kind picker")
        XCTAssertTrue(
            textFields(in: window).filter(\.isEditable).isEmpty,
            "no editable field on the wall's card in a locked window")

        do {
            let strings = try axStrings(in: window)
            XCTAssertTrue(strings.contains { $0.contains("Wall") },
                          "the back-chevron header must still be there, found: \(strings)")
            XCTAssertTrue(strings.contains { $0.contains(Self.cardBody) },
                          "…over the card's own read-only content, found: \(strings)")
        } catch { throw error }
    }

    /// The control: the wall's card click in an unlocked window is still the editor.
    func test_anUnlockedWallCardClickShowsTheEditor() async throws {
        let (store, card) = try await storeWithCard(title: "Harbour", body: Self.cardBody)
        let window = try await hostWall(store: store, selectedCardId: card.id, isLocked: false)

        await pumpUntil(deadline: 5) { !self.segmentedControls(in: window).isEmpty }
        XCTAssertFalse(
            segmentedControls(in: window).isEmpty,
            "an unlocked wall card click must still reach the visual editor")
    }

    // MARK: - Control: the tree's verbs stay live in a locked window

    /// **Creation/rename/delete belong to the tree, locked or not** — stage
    /// 2a's rule. Pinned here because the Lock is about the CENTRE column and
    /// the wall's card arm; nothing should couple it to the tree's own verbs.
    /// Driven through `BinderTreeVerbs`, the one wiring every tree row's Rename
    /// menu item and inline commit already goes through — a rename that lands
    /// through it is the same rename a row's own affordance produces.
    func test_treeVerbsStayLiveInALockedWindow_renameLands() async throws {
        let (store, note) = try await storeWithNote(text: Self.noteText)
        // Mount a locked centre alongside, so the scenario is genuinely a
        // locked window's rather than a bare store call.
        _ = try await hostCentre(store: store, itemID: note.id, isLocked: true)

        let state = BinderTreeSectionsState()
        var subject: BinderSubject? = .research(note.id)
        let binding = Binding(get: { subject }, set: { subject = $0 })
        let verbs = BinderTreeVerbs(store: store, state: state, subject: .tree(binding))

        verbs.bundle.rename(note.id, "Tides")

        await pumpUntil(deadline: 5) {
            store.manifest.research.first(where: { $0.id == note.id })?.title == "Tides"
        }
        XCTAssertEqual(
            store.manifest.research.first(where: { $0.id == note.id })?.title, "Tides",
            "the tree's rename verb must still land while a locked centre shows the note")
    }

    // MARK: - Fixtures

    private func storeWithNote(text: String) async throws -> (ProjectStore, ResearchItem) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Ships")
        let path = try XCTUnwrap(note.path)
        try Data(text.utf8).write(to: store.url.appendingPathComponent(path))
        await store.wordCountPopulationTask?.value
        return (store, note)
    }

    private func storeWithCard(title: String, body: String) async throws -> (ProjectStore, ResearchItem) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        let item = try await store.addPaletteCard(title: title, kind: .location)
        var card = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == item.id })
        card = PaletteCard(researchItemId: card.researchItemId, title: card.title, kind: card.kind,
                           swatches: card.swatches, notes: card.notes,
                           imagePaths: card.imagePaths, body: body)
        try await store.updatePaletteCard(card)
        await store.wordCountPopulationTask?.value
        return (store, item)
    }

    // MARK: - Image paste fixtures

    /// The well beside a note, derived from the note's own path —
    /// `ImagePasteHandler.destination` builds `<slug>_assets` from the note's
    /// filename, mirrored here rather than spelled as a literal.
    /// `StatementImageIngestTests.well(beside:in:)`'s shape, over a
    /// `ResearchItem` instead of a `Statement`.
    private func assetsWell(for note: ResearchItem, in store: ProjectStore) throws -> URL {
        let path = try XCTUnwrap(note.path)
        let file = store.url.appendingPathComponent(path)
        return file.deletingLastPathComponent()
            .appendingPathComponent(
                "\(file.deletingPathExtension().lastPathComponent)_assets")
    }

    /// `StatementImageIngestTests.makeImage(_:)`'s shape — a tiny real bitmap
    /// so `NSBitmapImageRep`/PNG encoding has something to work with.
    private func makeImage(_ side: Int = 12) throws -> NSImage {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    /// Put a picture where `MaughamTextView.paste(_:)` will find one — the
    /// same pasteboard the writer's own ⌘V uses.
    private func putImageOnTheClipboard() throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([try makeImage()])
    }

    private func files(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    // MARK: - Hosting

    /// The centre as `CentreColumn` mounts it: `readOnly` is the window's Lock.
    private func hostCentre(store: ProjectStore, itemID: String, isLocked: Bool) async throws -> NSWindow {
        let documentStore = try XCTUnwrap(store.documentStore)
        let window = TestWindow.mount(AnyView(
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: itemID, previewVisible: false,
                                  readOnly: WindowLock.refusesEdits(isLocked: isLocked))
                .environment(makePreferences())),
            size: CGSize(width: 700, height: 600),
            as: SilentTestWindow.self)
        windows.append(window)
        pump(0.3)
        return window
    }

    private func hostWall(store: ProjectStore, selectedCardId: String,
                          isLocked: Bool) async throws -> NSWindow {
        let window = TestWindow.mount(AnyView(
            PaletteWallCentre(store: store, selectedPaletteCardId: .constant(selectedCardId),
                              onClose: {}, isLocked: isLocked)),
            size: CGSize(width: 700, height: 600),
            as: SilentTestWindow.self)
        windows.append(window)
        pump(0.3)
        return window
    }

    // MARK: - Reading the mounted window

    private func textViews(in window: NSWindow) -> [MaughamTextView] {
        collect(MaughamTextView.self, in: window)
    }

    private func textFields(in window: NSWindow) -> [NSTextField] {
        collect(NSTextField.self, in: window)
    }

    private func segmentedControls(in window: NSWindow) -> [NSSegmentedControl] {
        collect(NSSegmentedControl.self, in: window)
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

    // MARK: - Accessibility (positive content checks)

    /// `axStrings` swallowed into an empty array — used only to decide when a
    /// `pumpUntil` predicate should stop waiting; the real assertion always
    /// goes through `axStrings(in:)` directly, which throws `XCTSkip` rather
    /// than silently passing when no assistive client is attached.
    private func allStringsIgnoringSkip(in window: NSWindow) -> [String] {
        (try? axStrings(in: window)) ?? []
    }

    private func axStrings(in window: NSWindow) throws -> [String] {
        let tree = try axTree(in: window)
        return tree.flatMap { element -> [String] in
            [axAttribute(element, "accessibilityLabel") as? String,
             axAttribute(element, "accessibilityValue") as? String,
             axAttribute(element, "accessibilityTitle") as? String].compactMap { $0 }
        }
    }

    /// SwiftUI only builds an accessibility tree when an assistive client is
    /// attached to the process — `DiagnosticsPaneTests`' guard, verbatim.
    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so SwiftUI "
                + "never built the tree this test presses through")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }
}
