import XCTest
import AppKit
import SwiftUI
import Observation
@testable import Maugham
@testable import MaughamCore

/// The window's stores and subject, outside the view, so a test can mount the
/// real `SubjectValidationModifier`, drive a real figure verb, and read what it
/// wrote.
@Observable
@MainActor
private final class FigureSubjectHarness {
    var store: ProjectStore?
    var documentStore: DocumentStore?
    var subject: BinderSubject?
    init(store: ProjectStore, documentStore: DocumentStore, subject: BinderSubject?) {
        self.store = store
        self.documentStore = documentStore
        self.subject = subject
    }
}

@MainActor
private struct FigureSubjectProbeView: View {
    let harness: FigureSubjectHarness

    var body: some View {
        Color.clear
            .modifier(SubjectValidationModifier(
                store: harness.store, documentStore: harness.documentStore,
                selectedSubject: Binding(get: { harness.subject },
                                         set: { harness.subject = $0 })))
    }
}

/// **A figure subject repairs to the project row when its figure is gone or
/// parked** (report plan 8a Task 3): `ProjectWindow.validSubject` over the
/// registry, and `SubjectValidationModifier` asking the stream, since parking
/// lives in the figure's stream and no manifest fingerprint can see it.
@MainActor
final class FigureSubjectValidationTests: XCTestCase {

    private var projectURL: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figuresubject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
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
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - The rule

    private let cash = FigureRecord(id: "fig-0a1b2c3d", name: "cash", kind: .table,
                                    piece: nil, path: "figures/cash.csv")

    func test_aListedFigureIsAValidSubject() {
        XCTAssertEqual(
            ProjectWindow.validSubject(.figure(cash.id), in: [], research: [],
                                       figures: [cash], parked: []),
            .figure(cash.id))
    }

    func test_aFigureTheRegistryNoLongerListsRepairsToTheProject() {
        XCTAssertEqual(
            ProjectWindow.validSubject(.figure(cash.id), in: [], research: [],
                                       figures: [], parked: []),
            .project)
    }

    func test_aParkedFigureRepairsToTheProject() {
        XCTAssertEqual(
            ProjectWindow.validSubject(.figure(cash.id), in: [], research: [],
                                       figures: [cash], parked: [cash.id]),
            .project)
        // Control: another figure parked leaves this one standing.
        XCTAssertEqual(
            ProjectWindow.validSubject(.figure(cash.id), in: [], research: [],
                                       figures: [cash], parked: ["fig-99999999"]),
            .figure(cash.id))
    }

    /// The trigger sees a figure leave and arrive, and is blind to a rename,
    /// which keeps the id.
    func test_theTriggerMovesWithTheRegistryIdsAndIsBlindToARename() {
        let base = SubjectValidationModifier.fingerprint(of: [], research: [], figures: [cash])
        var renamed = cash
        renamed.name = "cashflow"
        XCTAssertEqual(
            SubjectValidationModifier.fingerprint(of: [], research: [], figures: [renamed]), base)
        XCTAssertNotEqual(
            SubjectValidationModifier.fingerprint(of: [], research: [], figures: []), base)
    }

    // MARK: - Through the mounted modifier, on the real verbs

    /// **Removed here**: `removeFigure` takes the record out of the registry,
    /// and the sweep moves the window off it.
    func test_mounted_removingTheSelectedFigureMovesTheWindowOff() async throws {
        let (documentStore, store) = try await openBook()
        let figure = try await store.createFigure(kind: .table, name: "cash", piece: nil)
        let harness = FigureSubjectHarness(store: store, documentStore: documentStore,
                                           subject: .figure(figure.id))
        try await host(harness)
        XCTAssertEqual(harness.subject, .figure(figure.id), "precondition: a live figure stays")

        _ = try await store.removeFigure(id: figure.id)
        _ = await pumpUntil(deadline: 5) { harness.subject == .project }

        XCTAssertEqual(harness.subject, .project,
                       "the window was left naming a figure that no longer exists")
    }

    /// **Parked here**: Send to Research keeps the record, so the registry
    /// sweep alone keeps the subject; the stream's answer is what moves it.
    func test_mounted_sendingTheSelectedFigureToResearchMovesTheWindowOff() async throws {
        let (documentStore, store) = try await openBook()
        let figure = try await store.createFigure(kind: .table, name: "cash", piece: nil)
        let harness = FigureSubjectHarness(store: store, documentStore: documentStore,
                                           subject: .figure(figure.id))
        try await host(harness)

        _ = try await store.sendToResearch(figureId: figure.id, scope: .shared)
        XCTAssertTrue(store.manifest.figures?.contains(where: { $0.id == figure.id }) == true,
                      "fixture assumption: a parked figure keeps its record")
        _ = await pumpUntil(deadline: 5) { harness.subject == .project }

        XCTAssertEqual(harness.subject, .project,
                       "the window was left naming a figure that is now in Research")
    }

    /// Control: another figure's park leaves the selected one alone.
    func test_mounted_anotherFiguresParkLeavesTheSubjectAlone() async throws {
        let (documentStore, store) = try await openBook()
        let kept = try await store.createFigure(kind: .table, name: "kept", piece: nil)
        let sent = try await store.createFigure(kind: .table, name: "sent", piece: nil)
        let harness = FigureSubjectHarness(store: store, documentStore: documentStore,
                                           subject: .figure(kept.id))
        try await host(harness)

        _ = try await store.sendToResearch(figureId: sent.id, scope: .shared)
        await settle()

        XCTAssertEqual(harness.subject, .figure(kept.id))
    }

    // MARK: - Fixture

    /// One chapter bootstrapped into its op log, and a window over the book.
    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        let chapter = projectURL.appendingPathComponent("manuscript/a.md")
        try "Words.\n".write(to: chapter, atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document,
                                      path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(url: chapter, actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func host(_ harness: FigureSubjectHarness) async throws {
        let window = TestWindow.mount(
            AnyView(FigureSubjectProbeView(harness: harness)),
            size: CGSize(width: 320, height: 240))
        windows.append(window)
        await settle()
    }

    /// A fixed window, for the cases asserting the subject did NOT move.
    private func settle() async {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
