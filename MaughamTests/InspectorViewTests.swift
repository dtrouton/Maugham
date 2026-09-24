import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **A real book on disk with a scoped author in it** — the fixture P3b Task
/// 9's two surfaces need and nothing else had.
///
/// Every earlier surface in this milestone could be pinned as a value, because
/// each one is a pure model over a registry a test could hand it. These two
/// cannot be: the row and the column read a `PieceWriters` the VIEW resolved,
/// off a folder, in a `.task` — so the only honest question to ask of them is
/// whether the thing is drawn over a book that really is narrowed.
///
/// **It injects all four of `Document`'s process-wide seams and clears them.**
/// An admission writes this Mac's own memory of what it has verified and what
/// it calls the devices it has let in; a suite that admitted a throwaway key
/// without injecting those would leave the writer's real memory holding a
/// label for a key that will never exist again.
@MainActor
enum PieceWriterFixture {

    struct Book {
        let url: URL
        let store: ProjectStore
        let documentStore: DocumentStore
        /// Every document id in the book, in binder order.
        let pieceIDs: [String]
    }

    /// A project nobody has ever been admitted to — every book written before
    /// P3, and every book with one writer in it.
    static func oneAuthor(named name: String, in directory: URL) async throws -> Book {
        try await open(named: name, in: directory)
    }

    /// The same project, with one other person in it whose permit names
    /// `scopedTo` and nothing else. Driven through the production verbs, so
    /// the record, the event and the manifest's schema gate all move the way
    /// they move for a writer.
    static func narrowed(
        named name: String, in directory: URL, scopedTo pieces: (Book) -> [String],
        label: String = "Sam"
    ) async throws -> Book {
        let book = try await open(named: name, in: directory)
        let sam = DeviceIdentity.softwareForTesting()
        _ = try await book.documentStore.admit(
            device: sam.fingerprint, label: label,
            ownName: "\(label)\u{2019}s Mac")
        _ = try await book.documentStore.changePermit(
            everyRecordOf: sam.fingerprint,
            to: .author(.pieces(Set(pieces(book)))))
        return book
    }

    private static func open(named name: String, in directory: URL) async throws -> Book {
        Document.localIdentitiesForTesting =
            .forTesting(author: .softwareForTesting())
        let url = try await ProjectFactory.createNovelProject(
            named: "\(name)-\(UUID().uuidString.prefix(6))", in: directory)
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: url.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: url.appendingPathComponent("registry-cache.json"),
            identity: "test")
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: url.appendingPathComponent("admission-memory.json"),
            identity: "test")
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        return Book(
            url: url, store: store, documentStore: documentStore,
            pieceIDs: TreeWalk.collect(
                in: store.manifest.structure, where: { $0.type == .document })
                .map(\.id))
    }

    /// Clear the four seams. Every caller `defer`s it.
    static func reset() {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
    }
}

/// **Whose piece is whose, on the Inspector** (signed op log P3b Task 9,
/// spec §7.5).
///
/// The row is drawn in one case and absent in every other, and the absence is
/// the harder half to pin: a *Written by* line on every chapter of a book with
/// one writer in it would be noise the eye learns to skip, which is exactly
/// what would make it useless on the day it mattered.
///
/// **Nothing here presses anything** (tripwire 33). The row's decision is
/// pinned as a value in `PieceWritersTests`; what these mounts answer is only
/// whether the surface draws what the value says.
@MainActor
final class InspectorViewTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        PieceWriterFixture.reset()
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    private func mount(_ view: AnyView) -> NSWindow {
        let window = TestWindow.mount(view, size: CGSize(width: 420, height: 700))
        windows.append(window)
        pump()
        return window
    }

    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func hostInspector(_ book: PieceWriterFixture.Book) -> NSWindow {
        mount(AnyView(InspectorView(
            store: book.store,
            selectedItemId: book.pieceIDs[0],
            metrics: EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0),
            onOpenProjectSettings: {}, posture: .author)))
    }

    private func hostPieceInspector(_ book: PieceWriterFixture.Book) -> NSWindow {
        mount(AnyView(PieceInspector(
            store: book.store, pieceId: book.pieceIDs[0], kind: .prose, posture: .author)))
    }

    /// Did the row ever appear? A bounded poll because the read is a `.task`
    /// that detaches — not a press, and nothing here waits on one.
    private func rowAppeared(in window: NSWindow) async -> Bool {
        await pumpUntil(deadline: 5) {
            ((try? self.axIdentifiers(in: window)) ?? [])
                .contains(PieceWriters.rowIdentifier)
        }
    }

    // MARK: - A book with one writer in it draws no row at all

    func test_aBookWithOneWriterInItDrawsNoWrittenByRow() async throws {
        defer { PieceWriterFixture.reset() }
        let book = try await PieceWriterFixture.oneAuthor(named: "Alone", in: temp.url)
        let window = hostInspector(book)

        // A fixed wait: this asserts that nothing arrives, so there is no
        // condition whose arrival could end it early.
        await waitOut(1.0)

        let identifiers = try axIdentifiers(in: window)
        XCTAssertFalse(
            identifiers.contains(PieceWriters.rowIdentifier),
            "a book nobody else writes in put a Written by row on a chapter. "
            + "Identifiers on the surface: \(identifiers)")
    }

    /// The Collection arm, same book, same answer — the two inspectors must
    /// not disagree about whether this book says anything about authorship.
    func test_theLoosePieceInspectorDrawsNoRowEither() async throws {
        defer { PieceWriterFixture.reset() }
        let book = try await PieceWriterFixture.oneAuthor(named: "AloneToo", in: temp.url)
        let window = hostPieceInspector(book)

        await waitOut(1.0)

        XCTAssertFalse(
            try axIdentifiers(in: window).contains(PieceWriters.rowIdentifier))
    }

    // MARK: - A book with a scoped author in it says whose piece is whose

    func test_ascopedAuthorsNameIsDrawnOnHerOwnPiece() async throws {
        defer { PieceWriterFixture.reset() }
        let book = try await PieceWriterFixture.narrowed(
            named: "Shared", in: temp.url, scopedTo: { [$0.pieceIDs[0]] })
        let window = hostInspector(book)

        let appeared = await rowAppeared(in: window)

        let identifiers = try axIdentifiers(in: window)
        XCTAssertTrue(
            appeared,
            "the chapter Sam may write drew no Written by row. Identifiers on "
            + "the surface: \(identifiers)")
    }

    func test_theLoosePieceInspectorDrawsItToo() async throws {
        defer { PieceWriterFixture.reset() }
        let book = try await PieceWriterFixture.narrowed(
            named: "SharedToo", in: temp.url, scopedTo: { [$0.pieceIDs[0]] })
        let window = hostPieceInspector(book)

        let appeared = await rowAppeared(in: window)
        XCTAssertTrue(appeared)
    }

    /// And a chapter her permit does NOT name draws nothing, in the same book
    /// — the column's whole point is that it distinguishes between rows.
    func test_apieceHerPermitDoesNotNameDrawsNoRowInTheSameBook() async throws {
        defer { PieceWriterFixture.reset() }
        let book = try await PieceWriterFixture.narrowed(
            named: "Split", in: temp.url, scopedTo: { [$0.pieceIDs[0]] })
        _ = try await book.store.addStructureItem(
            parentId: nil, title: "Chapter 2", kind: .document(extension: "md"))
        let other = try XCTUnwrap(
            TreeWalk.collect(in: book.store.manifest.structure,
                             where: { $0.type == .document })
                .first { !book.pieceIDs.contains($0.id) })

        let window = mount(AnyView(InspectorView(
            store: book.store, selectedItemId: other.id,
            metrics: EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0),
            onOpenProjectSettings: {}, posture: .author)))
        await waitOut(1.0)

        XCTAssertFalse(
            try axIdentifiers(in: window).contains(PieceWriters.rowIdentifier),
            "a chapter nobody but the writer may touch was labelled with "
            + "somebody else\u{2019}s name")
    }

    // MARK: - C15: a chosen pass state survives the view that carried it

    /// What a fixture leaves behind once the test lets go of it — the three
    /// values the C15 tests still need after the store is out of their hands.
    private struct Ladder {
        let url: URL
        let pieceId: String
        let passId: String
    }

    /// Build a book, hand its store to `makeView`, and give back only the
    /// strings beside it. The `Book` — and with it this test's own strong
    /// reference to the store — dies at the end of this call, so from here the
    /// view the caller is holding has the only one.
    private func makeLadder<V>(
        named name: String, into makeView: (ProjectStore, String) -> V
    ) async throws -> (Ladder, V) {
        let book = try await PieceWriterFixture.oneAuthor(named: name, in: temp.url)
        let pieceId = book.pieceIDs[0]
        let passId = try XCTUnwrap(
            book.store.manifest.effectiveReviewPasses.first?.id)
        return (Ladder(url: book.url, pieceId: pieceId, passId: passId),
                makeView(book.store, pieceId))
    }

    /// The state on disk, read off the manifest file itself — never through
    /// the store under test, which by then is nobody's, and synchronously so
    /// it can be a poll predicate.
    private func passOnDisk(_ ladder: Ladder) -> PassState? {
        let url = ladder.url.appendingPathComponent(ProjectManifest.fileName)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? ProjectManifest.makeDecoder()
                  .decode(ProjectManifest.self, from: data)
        else { return nil }
        return manifest.structure
            .first { $0.id == ladder.pieceId }?.passStates?[ladder.passId]
    }

    /// **The premise, so the two tests below mean something.** Nothing but the
    /// view holds the store: released, it goes. Without this, a `setPass` that
    /// dropped the store could still land its write — kept alive by something
    /// else entirely — and the C15 pin would be green for the wrong reason.
    func test_premise_nothingButTheViewHoldsTheStore() async throws {
        defer { PieceWriterFixture.reset() }
        weak var observed: ProjectStore?
        var inspector: InspectorView?
        // The tuple is scoped: it holds the view too, and a `let` kept to the
        // end of the test would be the second reference this is about.
        do {
            let made = try await makeLadder(named: "C15premise") { store, pieceId in
                observed = store
                return InspectorView(
                    store: store, selectedItemId: pieceId,
                    metrics: EditorMetrics(wordCount: 0, characterCount: 0,
                                           readingMinutes: 0),
                    onOpenProjectSettings: {}, posture: .author)
            }
            inspector = made.1
        }
        XCTAssertNotNil(observed, "premise: the view is holding it")

        inspector = nil
        _ = await pumpUntil(deadline: 5) { observed == nil }

        XCTAssertNil(observed,
                     "something other than the view retains the store, so the "
                     + "C15 tests below cannot tell a strong capture from a weak one")
    }

    /// **The ladder's write holds the store until it lands** (P3b carry C15).
    ///
    /// Both `setPass` copies used to capture `[weak store]`. The window
    /// closing, the persona switching and the subject moving all tear the
    /// inspector down, and all three can land in the same turn as the click —
    /// so a `guard let store else { return }` reached after the view went away
    /// is a pass state the writer chose and Maugham dropped, with nothing red
    /// anywhere.
    ///
    /// The view here holds the only strong reference (the premise above), and
    /// it is released in the same main-actor turn as the call — before the
    /// task's body can have run at all.
    func test_theLadderWriteLandsWhenTheViewHeldTheOnlyReferenceToTheStore() async throws {
        defer { PieceWriterFixture.reset() }
        var inspector: InspectorView?
        var ladder: Ladder!
        do {
            let made = try await makeLadder(named: "C15") { store, pieceId in
                InspectorView(
                    store: store, selectedItemId: pieceId,
                    metrics: EditorMetrics(wordCount: 0, characterCount: 0,
                                           readingMinutes: 0),
                    onOpenProjectSettings: {}, posture: .author)
            }
            ladder = made.0
            inspector = made.1
        }
        XCTAssertNil(passOnDisk(ladder), "premise: no pass state yet")

        inspector?.setPass(ladder.passId, to: .done, on: ladder.pieceId)
        // Same turn, no await in between: the task cannot have started, so
        // what keeps the store alive from here is its capture and nothing else.
        inspector = nil

        _ = await pumpUntil(deadline: 5) { self.passOnDisk(ladder) == .done }

        XCTAssertEqual(passOnDisk(ladder), .done,
            "the pass the writer chose never reached disk — the task let the "
            + "store go before its own write")
    }

    /// `PieceInspector`'s copy, which must not differ.
    func test_theLoosePieceLadderWriteLandsTheSameWay() async throws {
        defer { PieceWriterFixture.reset() }
        var inspector: PieceInspector?
        var ladder: Ladder!
        do {
            let made = try await makeLadder(named: "C15b") { store, pieceId in
                PieceInspector(store: store, pieceId: pieceId, kind: .prose, posture: .author)
            }
            ladder = made.0
            inspector = made.1
        }

        inspector?.setPass(ladder.passId, to: .done, on: ladder.pieceId)
        inspector = nil

        _ = await pumpUntil(deadline: 5) { self.passOnDisk(ladder) == .done }

        XCTAssertEqual(passOnDisk(ladder), .done)
    }
}
