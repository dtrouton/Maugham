import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **A margin mark's click, through the right column** (shell p5 Task 2, fix
/// round 1, I1 and I2): the click's request reaches To resolve as the window
/// hands it over — the column mounted through `RightColumnFixture`, the
/// request already waiting, as when the click revealed a hidden column — and
/// the list ends on the CLICKED paragraph's group, scrolled there, not on the
/// caret's. Read off the accessibility tree; nothing is pressed.
@MainActor
final class MarginClickResolveTests: XCTestCase {
    override class func setUp() { super.setUp(); FontWarmup.ensure() }

    private var projectURL: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("margin-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("manuscript"),
                                                withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
    }

    private static let docId = "doc-click"
    private static let count = 40

    private static func words(_ n: Int) -> String { "Paragraph number \(n) of the chapter." }

    /// A chapter of forty paragraphs, a note on each, open in the editor
    /// (registered) with the caret in the first.
    private func openChapter() async throws -> (ProjectStore, DocumentStore, Document) {
        let path = "manuscript/c1.md"
        try (1...Self.count).map(Self.words).joined(separator: "\n\n")
            .write(to: projectURL.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: Self.docId, title: "C1", type: .document, path: path)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        let documentStore = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: projectURL.appendingPathComponent(path), actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        documentStore.register(document: doc, for: path)
        for pid in doc.sequence {
            _ = try await doc.addReviewerAnnotation(kind: .comment, paragraphId: pid, span: nil,
                                                    body: "a note", authorName: "Denver")
        }
        await documentStore.postureSettled()
        doc.cursorLocation = 0
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = documentStore
        documentStore.projectStore = store
        return (store, documentStore, doc)
    }

    /// The column, mounted as the window builds it, with `request` already
    /// waiting — as when the act that asked revealed a hidden column.
    private func mount(_ request: ResolveRequest, subject: WindowSubject,
                       store: ProjectStore, documentStore: DocumentStore) -> (NSWindow, RightColumnFixture.Probe) {
        let probe = RightColumnFixture.Probe(position: .resolve, subject: subject)
        probe.resolveRequest = request
        let window = TestWindow.mount(
            RightColumnFixture.pane(store: store, documentStore: documentStore, probe: probe)
                .environment(UserPreferences(defaults: UserDefaults(suiteName: "MarginClick-\(UUID())")!)),
            size: CGSize(width: 340, height: 600))
        windows.append(window)
        return (window, probe)
    }

    /// Lands on `target` (a header label fragment), selected and on screen,
    /// and stays: the caret's group never takes it back.
    private func assertEndsOn(_ target: String, prefix: String = "Paragraph number",
                              in window: NSWindow, _ what: String) async throws {
        let landed = await pumpUntil(deadline: 5) {
            ((try? self.selectedHeaders(in: window, prefix: prefix)) ?? []).contains { $0.contains(target) }
        }
        XCTAssertTrue(landed, "\(what): the target's group is the list's caret group, on screen; drawn: "
                      + "\((try? headers(in: window, prefix: prefix)) ?? [])")
        await waitOut(0.5)   // an absence: the caret reader must not take it back
        let selected = try selectedHeaders(in: window, prefix: prefix)
        XCTAssertEqual(selected.count, 1, "\(what): \(selected)")
        XCTAssertTrue(selected.first?.contains(target) == true, "\(what): still the target: \(selected)")
    }

    /// The group headers VoiceOver reads as selected — the list's caret group.
    private func selectedHeaders(in window: NSWindow, prefix: String = "Paragraph number") throws -> [String] {
        try axElements(in: window).compactMap { element -> String? in
            guard let label = axAttribute(element, "accessibilityLabel") as? String,
                  label.hasPrefix(prefix),
                  let object = element as? NSObject,
                  object.responds(to: NSSelectorFromString("isAccessibilitySelected")) else { return nil }
            let selected = (object.value(forKey: "isAccessibilitySelected") as? NSNumber)?.boolValue ?? false
            return selected ? label : nil
        }
    }

    private func headers(in window: NSWindow, prefix: String = "Paragraph number") throws -> [String] {
        try axElements(in: window).compactMap { axAttribute($0, "accessibilityLabel") as? String }
            .filter { $0.hasPrefix(prefix) }
    }

    /// **A click that reveals a hidden column ends on the clicked paragraph**
    /// (I2): the caret is in ¶1, the click was on ¶36; the column mounts
    /// with the request waiting. ¶36's group is the caret group and on screen
    /// once the list has read, and stays so — the caret reader's first
    /// render (its groups arriving) does not take it back to ¶1.
    func test_aClickThatRevealsTheColumnEndsOnTheClickedParagraph() async throws {
        try requireAssistiveClient()
        let (store, documentStore, doc) = try await openChapter()
        let clicked = doc.sequence[35]
        let probe = RightColumnFixture.Probe(
            position: .resolve, subject: WindowSubject(open: .item(Self.docId), faces: .item(Self.docId)))
        probe.resolveRequest = .showParagraph(docId: Self.docId, paragraphId: clicked)
        let window = TestWindow.mount(
            RightColumnFixture.pane(store: store, documentStore: documentStore, probe: probe)
                .environment(UserPreferences(defaults: UserDefaults(suiteName: "MarginClick-\(UUID())")!)),
            size: CGSize(width: 340, height: 600))
        windows.append(window)

        let landed = await pumpUntil(deadline: 5) {
            ((try? self.selectedHeaders(in: window)) ?? []).contains { $0.contains("number 36 ") }
        }
        XCTAssertTrue(landed, "¶36's group became the caret group; drawn: \((try? headers(in: window)) ?? [])")
        await waitOut(0.5)   // an absence: the caret reader must not take it back
        let selected = try selectedHeaders(in: window)
        XCTAssertEqual(selected.count, 1, "\(selected)")
        XCTAssertTrue(selected.first?.contains("number 36 ") == true,
                      "still ¶36, not the caret's ¶1: \(selected)")
        XCTAssertNil(probe.resolveRequest, "the request was taken")
        await doc.close()
    }

    /// **The caret moving afterwards takes the list back to the caret** —
    /// the click's group holds only until the writer moves.
    func test_theCaretMovingAfterAClickTakesTheListBack() async throws {
        try requireAssistiveClient()
        let (store, documentStore, doc) = try await openChapter()
        let probe = RightColumnFixture.Probe(
            position: .resolve, subject: WindowSubject(open: .item(Self.docId), faces: .item(Self.docId)))
        probe.resolveRequest = .showParagraph(docId: Self.docId, paragraphId: doc.sequence[3])
        let window = TestWindow.mount(
            RightColumnFixture.pane(store: store, documentStore: documentStore, probe: probe)
                .environment(UserPreferences(defaults: UserDefaults(suiteName: "MarginClick-\(UUID())")!)),
            size: CGSize(width: 340, height: 600))
        windows.append(window)
        let landed = await pumpUntil(deadline: 5) {
            ((try? self.selectedHeaders(in: window)) ?? []).contains { $0.contains("number 4 ") }
        }
        XCTAssertTrue(landed, "premise: the click's group")

        let third = try XCTUnwrap(doc.displayRange(forParagraphId: doc.sequence[2])).location
        doc.cursorLocation = third + 1
        let back = await pumpUntil(deadline: 5) {
            ((try? self.selectedHeaders(in: window)) ?? []).contains { $0.contains("number 3 ") }
        }
        XCTAssertTrue(back, "the caret moved: its group is the list's again")
        await doc.close()
    }

    // MARK: - Fix round 2

    /// **N1 — a strain mark's jump** (`.focusFinding`, from Brief or the
    /// tree) revealing the column ends on the finding's group, not the
    /// caret's. The item named here is a note's (`ResolveItem.id`), which
    /// the jump finds the same way it finds a finding's.
    func test_aStrainJumpThatRevealsTheColumnEndsOnItsGroup() async throws {
        try requireAssistiveClient()
        let (store, documentStore, doc) = try await openChapter()
        let target = doc.sequence[35]
        let note = try XCTUnwrap(doc.annotations(filter: AnnotationFilter(statuses: [.open]))
            .first { $0.paragraphId == target })
        let itemId = ResolveItem.note(ProjectAnnotation(docId: Self.docId, annotation: note)).id
        let (window, _) = mount(.focusFinding(docId: Self.docId, itemId: itemId),
                                subject: WindowSubject(open: .item(Self.docId), faces: .item(Self.docId)),
                                store: store, documentStore: documentStore)
        try await assertEndsOn("number 36 ", in: window, ".focusFinding")
        await doc.close()
    }

    /// **N1 — a Status count's jump** (`.focus`) revealing the Book's list
    /// ends on that piece's group, not the open piece's.
    func test_aFocusThatRevealsTheColumnEndsOnItsPiece() async throws {
        try requireAssistiveClient()
        let (store, documentStore, open) = try await openBook(pieces: 40)
        let (window, _) = mount(.focus(groupOwnerId: "piece-36"),
                                subject: WindowSubject(open: .item("piece-01"), faces: .project),
                                store: store, documentStore: documentStore)
        try await assertEndsOn("Piece 36,", prefix: "Piece ", in: window, ".focus")
        await open.close()
    }

    /// **N2 — any caret move releases the pin**, even within the caret's
    /// own paragraph: a click back into the editor, or an arrow key.
    func test_aCaretMoveWithinItsParagraphReleasesThePin() async throws {
        try requireAssistiveClient()
        let (store, documentStore, doc) = try await openChapter()
        let (window, _) = mount(.showParagraph(docId: Self.docId, paragraphId: doc.sequence[3]),
                                subject: WindowSubject(open: .item(Self.docId), faces: .item(Self.docId)),
                                store: store, documentStore: documentStore)
        let landed = await pumpUntil(deadline: 5) {
            ((try? self.selectedHeaders(in: window)) ?? []).contains { $0.contains("number 4 ") }
        }
        XCTAssertTrue(landed, "premise: the click's group")
        doc.cursorLocation = 5   // still ¶1
        let back = await pumpUntil(deadline: 5) {
            ((try? self.selectedHeaders(in: window)) ?? []).contains { $0.contains("number 1 ") }
        }
        XCTAssertTrue(back, "the writer moved the caret: the list follows it again")
        await doc.close()
    }

    /// A Book of `pieces` chapters, one note each, the first open in the
    /// editor with its caret in its noted paragraph.
    private func openBook(pieces: Int) async throws -> (ProjectStore, DocumentStore, Document) {
        var structure: [StructureItem] = []
        for n in 1...pieces {
            let id = String(format: "piece-%02d", n), path = "manuscript/\(id).md"
            try "Words of piece \(n).".write(to: projectURL.appendingPathComponent(path),
                                              atomically: true, encoding: .utf8)
            structure.append(StructureItem(id: id, title: String(format: "Piece %02d", n), type: .document, path: path))
        }
        let manifest = ProjectManifest(type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
                                       structure: structure, research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        let documentStore = try await DocumentStore.open(url: projectURL)
        var open: Document?
        for item in structure {
            let doc = try await Document.load(
                url: projectURL.appendingPathComponent(item.path!), actor: .author, session: "s", presenter: nil,
                burstIdle: .seconds(3600), burstMax: .seconds(3600))
            _ = try await doc.addReviewerAnnotation(kind: .comment, paragraphId: try XCTUnwrap(doc.sequence.first),
                                                    span: nil, body: "a note", authorName: "Denver")
            if item.id == "piece-01" {
                documentStore.register(document: doc, for: item.path!)
                open = doc
            } else {
                await doc.close()
            }
        }
        await documentStore.postureSettled()
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = documentStore
        documentStore.projectStore = store
        return (store, documentStore, try XCTUnwrap(open))
    }
}
