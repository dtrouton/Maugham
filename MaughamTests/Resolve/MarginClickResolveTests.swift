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

    /// The group headers VoiceOver reads as selected — the list's caret group.
    private func selectedHeaders(in window: NSWindow) throws -> [String] {
        try axElements(in: window).compactMap { element -> String? in
            guard let label = axAttribute(element, "accessibilityLabel") as? String,
                  label.hasPrefix("Paragraph number"),
                  let object = element as? NSObject,
                  object.responds(to: NSSelectorFromString("isAccessibilitySelected")) else { return nil }
            let selected = (object.value(forKey: "isAccessibilitySelected") as? NSNumber)?.boolValue ?? false
            return selected ? label : nil
        }
    }

    private func headers(in window: NSWindow) throws -> [String] {
        try axElements(in: window).compactMap { axAttribute($0, "accessibilityLabel") as? String }
            .filter { $0.hasPrefix("Paragraph number") }
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
}
