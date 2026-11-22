import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **A piece's research and figures follow its read-through** (shell
/// read-through Task 4), re-made from the window's Lock (`LockTests`,
/// `LockedResearchSurfaceTests`, deleted with it).
///
/// A piece in read-through: its own folder's note reads in the centre and
/// beside, an image paste into it lands no file, its table and its figures
/// refuse. Shared research, a book-wide figure, the palette wall's card and
/// New Table refuse nothing. Read-through only adds refusals: the posture and
/// the share refuse with it off, and it never permits what they refuse.
///
/// Pure rows ask the production functions; mounted rows build the views as
/// production does (`ResearchCentreFixture`, `PulledUpFixture`) and read
/// what they drew — nothing is pressed and waited on (tripwire 33). The
/// censuses: every capability Lock had has a home or a named reason; every
/// file asking the one answer is counted (tripwire 50's shape); no Lock name
/// remains.
@MainActor
final class ReadThroughResearchSurfaceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Mounts `EditorSurface` (the note) and the grid, which style text
        // through production typography.
        FontWarmup.ensure()
    }

    private var folder: URL!
    private var stores: [DocumentStore] = []
    private var windows: [NSWindow] = []
    private var defaultsSuites: [String] = []

    override func setUp() async throws {
        folder = TestTemp.root.appendingPathComponent("read-through-research-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: folder.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: folder.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: folder.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for store in stores { await store.close() }
        stores.removeAll()
        for suite in defaultsSuites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaultsSuites.removeAll()
        pasteboard.releaseGlobally()
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private typealias G = ReadThroughGateFixture

    // MARK: - The one answer, pure

    /// **A piece in read-through reads its own folder's research; shared
    /// research and the other piece's stay editable** — in the centre (the
    /// `CentreColumn` arm's `readOnly`), pulled up, and in the centre's own
    /// details. The gate's one rule, asked three ways.
    func test_aPieceInReadThroughReadsItsFoldersResearch_sharedStaysEditable() {
        let reading = G.gate(pieces: [G.pieceA])
        for id in [G.folder, G.nestedNote] {
            XCTAssertTrue(reading.refusesEdits(.research(id)), "\(id): A's folder reads")
            XCTAssertTrue(PulledUp.research(id).refusesEdits(readThrough: reading))
            XCTAssertTrue(PulledUpView.centreResearchIsReadOnly(id, readThrough: reading))
        }
        XCTAssertFalse(reading.refusesEdits(.research(G.sharedNote)), "shared research is the book's")
        XCTAssertFalse(PulledUp.research(G.sharedNote).refusesEdits(readThrough: reading))
        XCTAssertFalse(G.gate(pieces: [G.pieceB]).refusesEdits(.research(G.nestedNote)),
                       "control: another piece's read-through leaves A's folder editable")
        XCTAssertFalse(ReadThroughGate.writing.refusesEdits(.research(G.nestedNote)), "control: writing")
        let refusal = reading.refusal(.research(G.nestedNote))
        XCTAssertEqual(ResearchVersionsModel.restoreRefusal(shareIsReadOnly: false, readThrough: refusal),
                       .readThrough(refusal), "its Versions list, with Restore off")
        XCTAssertEqual(ResearchVersionsModel.restoreRefusal(shareIsReadOnly: false, readThrough: refusal)?
            .sentence(noun: "note"),
            "\u{201C}piece-a\u{201D} is in read-through \u{2014} resume writing it to change this note.",
            "Restore's reason names the piece")
    }

    /// **One rule for which piece owns a figure** (carry A): the piece it
    /// was made in AND every piece holding one of its lines. A figure made in
    /// A whose line moved to B is refused while EITHER is in read-through —
    /// by the gate, the figure windows (a ⤢ window, an editor's grid in
    /// place), the inspector's and the tree's verbs, and what is pulled up.
    /// So a read-only grid in B's text can never open an editable window.
    func test_aFigureWhoseLineMovedIsRefusedWhileEitherPieceIsInReadThrough() async throws {
        let moved = [G.line(G.figureA, in: G.pieceB)]
        let store = try await collection()
        for (pieces, refused) in [([G.pieceA], true), ([G.pieceB], true), ([], false)] as [(Set<String>, Bool)] {
            let gate = G.gate(pieces: pieces, figureLines: moved)
            XCTAssertEqual(gate.refusesEdits(.figure(G.figureA)), refused, "the gate, \(pieces)")
            if !pieces.isEmpty {
                XCTAssertEqual(gate.owners(of: .figure(G.figureA)), [G.pieceA, G.pieceB], "both its pieces")
            }
            let windows = FigureWindows()
            windows.setReadThrough(gate, from: UUID())
            XCTAssertEqual(windows.isInReadThrough(G.figureA), refused, "a figure window and ⤢, \(pieces)")
            XCTAssertEqual(PulledUp.figure(G.figureA).refusesEdits(readThrough: gate), refused,
                           "pulled up, \(pieces)")
            let actions = FigureActions(store: store, figureWindows: nil, typography: .defaults,
                                        windowRefusesWrites: { false }, readThrough: { gate },
                                        report: { _ in })
            XCTAssertEqual(actions.refusesWrites(to: G.figureA), refused, "the inspector and the tree, \(pieces)")
        }
        XCTAssertFalse(G.gate(pieces: [G.pieceA, G.pieceB], figureLines: moved).refusesEdits(.figure(G.bookFigure)),
                       "a book-wide figure no line places is no piece's")
    }

    /// **Every surface asks the window's one gate for a figure**: the
    /// centre's grid is handed `readThrough.refusal(.figure(id))`, a figure
    /// window asks `FigureWindows.readThroughRefusal` and an editor's grid in
    /// place the same gate's `refusal(among:)` (the gate the windows hand
    /// over), and the window builds that gate once from the listing's lines.
    func test_everyFigureGateAsksTheOneRule() throws {
        func flat(_ file: String) throws -> String {
            SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: " ")
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        XCTAssertTrue(try flat("Maugham/Views/FigureSubjectColumns.swift")
            .contains("readThrough: readThrough.refusal(.figure(figureID)),"), "the centre's grid")
        XCTAssertTrue(try flat("Maugham/Editor/FigureWindow.swift").contains(
            "readThrough: { [weak windows] in windows?.readThroughRefusal(figureId) },"),
            "a figure window")
        XCTAssertTrue(try flat("Maugham/Editor/EditorCoordinator+FigureGrid.swift").contains(
            "let refusal = gate.refusal(among: gate.owners(of: .figure(figureId)).union(own))"),
            "an editor's grid in place")
        XCTAssertTrue(try flat("Maugham/Views/ReadThroughModifier.swift").contains(
            "figureWindows?.setReadThrough(next, from: gateKey)"), "the window hands its gate to the figure windows")
        XCTAssertTrue(try flat("Maugham/Views/ProjectWindow.swift").contains(
            "figureRows: figureListing.rows, figureWindows: session?.figureWindows, gate: $ownReadThroughGate,"),
            "built from the window's listing")
    }

    // MARK: - Read-through only adds

    /// **A posture that refuses still refuses with read-through off**, and a
    /// view-only share too: the writer's own hand writing is the control.
    func test_postureAndShareRefusalsHoldWithReadThroughOff() async throws {
        let store = try await collection()
        let writing = FigureActions(store: store, figureWindows: nil, typography: .defaults,
                                    windowRefusesWrites: { false }, readThrough: { .writing },
                                    report: { _ in })
        XCTAssertFalse(writing.refusesWrites(to: G.figureA), "premise: nothing of the window's own")
        let refused = writing.refusesWrites(to: G.figureA)
        for posture in [Posture(.unrestricted, yieldingTo: "Sam"), .settling] {
            XCTAssertFalse(posture.allows(.editFigure), "premise: \(posture) refuses a figure write")
            XCTAssertFalse(FigureActions.mayEdit(windowRefusesWrites: refused, posture: posture),
                           "\(posture) refuses with read-through off")
        }
        XCTAssertFalse(FigureActions.mayEdit(windowRefusesWrites: refused, posture: nil), "no posture refuses")
        XCTAssertTrue(FigureActions.mayEdit(windowRefusesWrites: refused, posture: .author),
                      "control: the writer's own hand edits")

        let share = FigureActions(store: store, figureWindows: nil, typography: .defaults,
                                  windowRefusesWrites: { true }, readThrough: { .writing },
                                  report: { _ in })
        XCTAssertTrue(share.refusesWrites(to: G.figureA), "a view-only share refuses with read-through off")
        XCTAssertFalse(BinderTreeSectionsState.offersNewTable(shareIsReadOnly: true), "…and offers no New Table")
        XCTAssertEqual(ResearchVersionsModel.restoreRefusal(shareIsReadOnly: true, readThrough: nil),
                       .viewOnlyShare)
    }

    /// **Read-through never permits what the posture or the share refuses**:
    /// over every share and posture, turning it on only turns a permit into
    /// a refusal — and New Table is the share's alone.
    func test_readThroughNeverPermitsWhatPostureOrShareRefuses() async throws {
        let store = try await collection()
        for share in [false, true] {
            for posture in [Posture.author, .settling, Posture(.unrestricted, yieldingTo: "Sam")] {
                func mayEdit(_ gate: ReadThroughGate) -> Bool {
                    let actions = FigureActions(store: store, figureWindows: nil, typography: .defaults,
                                                windowRefusesWrites: { share }, readThrough: { gate },
                                                report: { _ in })
                    return FigureActions.mayEdit(windowRefusesWrites: actions.refusesWrites(to: G.figureA),
                                                 posture: posture)
                }
                let off = mayEdit(.writing), on = mayEdit(G.gate(pieces: [G.pieceA]))
                XCTAssertFalse(on, "in read-through a figure is never edited (share \(share), \(posture))")
                XCTAssertFalse(on && !off, "read-through permitted a refusal (share \(share), \(posture))")
            }
            for readThrough in [nil, G.gate(pieces: [G.pieceA]).refusal(.research(G.nestedNote))] {
                let refusal = ResearchVersionsModel.restoreRefusal(shareIsReadOnly: share,
                                                                   readThrough: readThrough)
                if share { XCTAssertEqual(refusal, FigureGridGate.Reason.viewOnlyShare, "the share is said first") }
                XCTAssertEqual(refusal == nil, !share && readThrough == nil)
            }
            XCTAssertEqual(BinderTreeSectionsState.offersNewTable(shareIsReadOnly: share), !share,
                           "New Table answers to the share alone")
        }
    }

    // MARK: - The padlock

    /// **The padlock's look, words and press follow the offer** (carry D):
    /// closed in read-through, open while writing; Start only where the offer
    /// allows, Resume wherever the piece is open; with no piece, disabled,
    /// saying why — never a dead press.
    func test_thePadlockSaysWhatAPressDoes() {
        let start = ReadThroughOffer(docId: "ch-1", isOn: false, isEnabled: true, reason: nil)
        let resume = ReadThroughOffer.on(docId: "ch-1", lacksCheckpoint: false, mayTakeCheckpoint: true)
        let refused = ReadThroughOffer(docId: "ch-1", isOn: false, isEnabled: false,
                                       reason: ReadThroughOffer.translationRefusal)

        XCTAssertEqual(ReadThroughToggle.symbol(start), "lock.open")
        XCTAssertEqual(ReadThroughToggle.symbol(resume), "lock")
        XCTAssertEqual(ReadThroughToggle.symbol(nil), "lock.open")
        XCTAssertEqual(ReadThroughToggle.tooltip(start),
                       "Start a read-through: typing is off; comments and decisions stay on. "
                       + "Saves a checkpoint. (\u{2318}\u{2325}\u{21E7}R)")
        XCTAssertEqual(ReadThroughToggle.tooltip(resume), "Resume writing (\u{2318}\u{2325}\u{21E7}R)")
        XCTAssertEqual(ReadThroughToggle.tooltip(refused), ReadThroughOffer.translationRefusal)
        XCTAssertEqual(ReadThroughToggle.tooltip(nil), "Open a piece to start a read-through.")
        XCTAssertEqual(ReadThroughToggle.label(start), "Start read-through")
        XCTAssertEqual(ReadThroughToggle.label(resume), "Resume writing")
        XCTAssertEqual(ReadThroughToggle.value(start), "Writing")
        XCTAssertEqual(ReadThroughToggle.value(resume), "In read-through")

        XCTAssertEqual(ReadThroughToggle.request(start), .init(docId: "ch-1", on: true))
        XCTAssertEqual(ReadThroughToggle.request(resume), .init(docId: "ch-1", on: false))
        XCTAssertNil(ReadThroughToggle.request(refused), "a refused Start posts nothing")
        XCTAssertNil(ReadThroughToggle.request(nil), "no piece open: nothing to post")
    }

    /// **Drawn but disabled where it would post nothing**, the press posting
    /// through `ReadThrough.post` — the menu's sender — and it sits in the
    /// `.navigation` item Lock held.
    func test_thePadlockIsDisabledWhereItWouldPostNothing() throws {
        let code = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ReadThroughToggle.swift"))
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(code.contains(".disabled(Self.request(offer) == nil)"), code)
        XCTAssertTrue(code.contains("if let request = Self.request(offer) { ReadThrough.post(request) }"))
        XCTAssertTrue(code.contains(".accessibilityIdentifier(\"readThrough\")"))
        let window = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ProjectWindow.swift"))
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(window.contains(
            "ToolbarItem(placement: .navigation) { ReadThroughToggle(offer: readThroughOffer) }"))
    }

    /// The window toolbar — the padlock's — hides under `⌘\`.
    func test_theToolbarIsHiddenInNoChromeFocusMode() {
        XCTAssertFalse(ProjectWindow.windowToolbarIsVisible(isNoChromeOn: true))
        XCTAssertTrue(ProjectWindow.windowToolbarIsVisible(isNoChromeOn: false))
    }

    // MARK: - An old project opens writing

    /// **Nothing an old project stored makes anything read-only** (carry E):
    /// a `ui-state.json` that carries a Lock and the old review mode opens
    /// with no piece in read-through and a gate that refuses nothing.
    func test_anOldProjectsStoredLockOpensWriting() async throws {
        let store = try await collection()
        let uiState = store.url.appendingPathComponent(".maugham/ui-state.json")
        try FileManager.default.createDirectory(at: uiState.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // An old window's ui-state: a real one, plus Lock's and Review Mode's keys.
        var old = UIState()
        old.detailColumnWidth = 333
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(old)) as? [String: Any])
        json["isLocked"] = true
        json["isReviewModeOn"] = true
        json["windowLock"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: uiState)

        let loaded = UIState.loadOrEmpty(from: uiState)
        XCTAssertEqual(loaded.detailColumnWidth, 333, "premise: the stored file was read, not replaced by empty")
        XCTAssertEqual(loaded, old, "the old keys change nothing the window restores")
        let reencoded = String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self)
        XCTAssertFalse(reencoded.lowercased().contains("lock"), "and nothing of Lock survives: \(reencoded)")
        XCTAssertFalse(reencoded.contains("ReviewMode"))
        let readThrough = ReadThroughStore(projectRoot: store.url, device: DeviceSlug.make(from: "old-project"))
        XCTAssertEqual(readThrough.pieceIds, [], "no piece is in read-through")
    }

    // MARK: - Every refusal names the piece (fix round 1: I1, I2)

    /// **The refusal names the first refusing piece in tree order, and how
    /// many more** — the one function every refusing surface asks.
    func test_theRefusalNamesTheFirstPieceInTreeOrder_andHowManyMore() {
        let moved = [G.line(G.figureA, in: G.pieceB)]
        let both = G.gate(pieces: [G.pieceA, G.pieceB], figureLines: moved).refusal(.figure(G.figureA))
        XCTAssertEqual(both, ReadThroughRefusal(pieceId: G.pieceA, title: G.pieceA, others: 1))
        XCTAssertEqual(both?.named, "\u{201C}piece-a\u{201D} and 1 more")
        XCTAssertEqual(both?.sentence, "\u{201C}piece-a\u{201D} and 1 more are in read-through")
        let onlyB = G.gate(pieces: [G.pieceB], figureLines: moved).refusal(.figure(G.figureA))
        XCTAssertEqual(onlyB?.pieceId, G.pieceB, "the piece in read-through, not the one it was made in")
        XCTAssertEqual(onlyB?.sentence, "\u{201C}piece-b\u{201D} is in read-through")
        XCTAssertNil(G.gate(pieces: [G.pieceB]).refusal(.research(G.nestedNote)), "control: A's research")
        XCTAssertEqual(G.gate(pieces: [G.pieceA]).refusal(.research(G.nestedNote))?.pieceId, G.pieceA)
        XCTAssertEqual(G.gate(pieces: [G.pieceA]).refusal(researchPath: "pieces/01-a/research/x.md")?.pieceId,
                       G.pieceA, "a research file's path, by the same rule")
        XCTAssertNil(G.gate(pieces: [G.pieceA]).refusal(researchPath: "research/x.md"), "shared")
    }

    /// **Every union refusal names the piece that caused it** (I2): a figure
    /// made in A whose line moved into B, with only B in read-through, is
    /// refused naming B — by the grid's reason (centre, window, in place),
    /// the inspector, the tree's row menu and the send-drop.
    func test_everyFigureRefusalNamesThePieceThatCausedIt() async throws {
        let store = try await collection()
        let gate = G.gate(pieces: [G.pieceB], figureLines: [G.line(G.figureA, in: G.pieceB)])
        let refusal = try XCTUnwrap(gate.refusal(.figure(G.figureA)))
        let b = "\u{201C}piece-b\u{201D}"
        // The grid: the centre's, a figure window's and an editor's in place
        // all build their reason from this refusal.
        let grid = FigureGridGate.mode(figureMayEdit: true, parked: false, hostClosed: false,
                                       shareIsReadOnly: false, isInReadThrough: true, naming: refusal,
                                       isReadingTranslation: false)
        XCTAssertTrue(grid.readOnlyReason?.sentence.contains(b) == true, "\(String(describing: grid))")
        let windows = FigureWindows()
        windows.setReadThrough(gate, from: UUID())
        XCTAssertEqual(windows.readThroughRefusal(G.figureA), refusal, "a figure window's frame asks this")
        // The inspector.
        let actions = FigureActions(store: store, figureWindows: windows, typography: .defaults,
                                    windowRefusesWrites: { false }, readThrough: { gate }, report: { _ in })
        XCTAssertEqual(actions.readThroughRefusal(of: G.figureA), refusal)
        XCTAssertTrue(FigureInspector.refusal(mayEdit: false, reach: .here, readThrough: refusal)?
            .contains(b) == true)
        // The tree: the row menu and the send-drop.
        let tree = BinderTreeSectionsState()
        tree.figureReadThrough = gate
        let verbs = FigureSectionVerbs(store: store, state: tree)
        let row = FigureTreeRow(listing: G.line(G.figureA, in: G.pieceB), readsResearch: false, changed: false)
        XCTAssertTrue(verbs.actions(for: row).refusal()?.contains(b) == true, "the row's menu says why")
        XCTAssertTrue(FigureSectionVerbs.readThroughSendsNoFigures(refusal).contains(b))
        XCTAssertNil(FigureSectionVerbs(store: store, state: BinderTreeSectionsState())
            .actions(for: row).refusal(), "control: writing, the menu says nothing")
    }

    /// **The files that ask for the named refusal** (`ReadThroughGate
    /// .refusal`), and how many times each — every refusing surface. A
    /// surface that refused without asking would refuse in silence.
    static let refusalSites: [String: Int] = [
        "Maugham/Views/ReadThrough.swift": 2,               // the gate: a target, a path
        "Maugham/Views/CentreColumn.swift": 1,              // research in the centre
        "Maugham/Views/PulledUpView.swift": 1,              // research pulled up
        "Maugham/Views/ProjectWindow.swift": 1,             // the padlock over research
        "Maugham/Views/FigureSubjectColumns.swift": 1,      // the centre's grid
        "Maugham/Views/FigureActions.swift": 4,             // the figure's, Bring Back's verb and reason, Move's
        "Maugham/Views/FigureInspector.swift": 2,           // Compare's and the actions' refusal
        "Maugham/Views/FigureSection.swift": 2,             // the row menu, the send-drop
        "Maugham/Editor/FigureWindow.swift": 2,             // the session's gate, a figure window's frame
        "Maugham/Editor/EditorCoordinator+FigureGrid.swift": 2, // an editor's grid in place, its visit's ⌘Z
        "Maugham/Stores/ProjectStore+Search.swift": 2,      // Replace's research arm: an item, a file
        "Maugham/Stores/ProjectStore+FigureResearch.swift": 1, // the store's retarget (Move into Figures)
    ]

    /// The ways to ask: a gate's `refusal(.target)`, `refusal(researchPath:)`
    /// and `refusal(among:)`, and `readThroughRefusal(…)` (the figure
    /// windows' and `FigureActions`' forwarding of it).
    static let refusalTokens = [".refusal(.", "refusal(researchPath:", "refusal(among:", "readThroughRefusal("]

    static func refusalCounts(_ text: String) -> Int {
        SourceScan.codeLines(of: text).reduce(0) { count, line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("func "), !code.contains(" func ") else { return count }
            return count + refusalTokens.reduce(0) { $0 + code.components(separatedBy: $1).count - 1 }
        }
    }

    func test_everyRefusingSurfaceAsksTheNamedRefusal() throws {
        var counts: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let n = Self.refusalCounts(try SourceTree.read(file))
            if n > 0 { counts[file] = n }
        }
        XCTAssertEqual(counts, Self.refusalSites)
        XCTAssertEqual(Self.refusalCounts("let r = gate.refusal(.figure(id))"), 1, "planted offender")
        XCTAssertEqual(Self.refusalCounts("// gate.refusal(.figure(id))"), 0, "control: a comment")
    }

    /// **A read-through piece's research carries one quiet line naming the
    /// piece, whose Resume writing resumes THAT piece** (I1), and the padlock
    /// over it names the piece and acts on it, where "Open a piece…" would
    /// point the wrong way.
    func test_aReadThroughPiecesResearchNamesThePieceAndResumesIt() {
        let alpha = ReadThroughRefusal(pieceId: "alpha", title: "Alpha", others: 0)
        let offer = alpha.resumeOffer
        XCTAssertEqual(ReadThroughLine.lead(for: offer), "\u{201C}Alpha\u{201D} is in read-through")
        XCTAssertEqual(ReadThroughLine.fullText(for: offer), "\u{201C}Alpha\u{201D} is in read-through")
        XCTAssertEqual(offer.resumeRequest, ReadThrough.Request(docId: "alpha", on: false), "the line's Resume")
        XCTAssertNil(offer.saveCheckpointRequest)
        let text = ReadThroughOffer.on(docId: "ch-1", lacksCheckpoint: false, mayTakeCheckpoint: true)
        XCTAssertEqual(ReadThroughLine.fullText(for: text), ReadThroughLine.fullText(lacksCheckpoint: false),
                       "control: over the text the line is unchanged")

        func facts(_ refusal: ReadThroughRefusal?) -> ReadThroughModifier.Facts {
            ReadThroughModifier.Facts(docId: nil, item: nil, posture: .author, shareIsReadOnly: false,
                                      isReadingTranslation: false, route: nil, pieces: ["alpha"],
                                      lackingCheckpoint: [], researchRefusal: refusal)
        }
        let padlock = ReadThroughModifier.offer(facts(alpha))
        XCTAssertEqual(ReadThroughToggle.symbol(padlock), "lock")
        XCTAssertEqual(ReadThroughToggle.tooltip(padlock),
                       "Resume writing \u{201C}Alpha\u{201D} (\u{2318}\u{2325}\u{21E7}R)")
        XCTAssertEqual(ReadThroughToggle.label(padlock), "Resume writing \u{201C}Alpha\u{201D}")
        XCTAssertEqual(ReadThroughToggle.request(padlock), ReadThrough.Request(docId: "alpha", on: false))
        XCTAssertNil(ReadThroughModifier.offer(facts(nil)), "control: shared research, no offer")
        XCTAssertEqual(ReadThroughToggle.tooltip(nil), ReadThroughToggle.noPieceTooltip)
    }

    /// **The panel's own fields read for a read-through piece's research**
    /// (M2): Title, Caption, Tags, URL and Citation, as the item does.
    func test_thePanelsFieldsReadForAReadThroughPiecesResearch() throws {
        XCTAssertTrue(InspectorResearchPanel.fieldsRead(
            readThrough: ReadThroughRefusal(pieceId: "a", title: "A", others: 0)))
        XCTAssertFalse(InspectorResearchPanel.fieldsRead(readThrough: nil), "control: writing")
        let panel = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/InspectorResearchPanel.swift"))
            .joined(separator: "\n")
        XCTAssertEqual(panel.components(separatedBy: ".disabled(Self.fieldsRead(readThrough: readThrough))").count - 1,
                       2, "the fields' group and the citation section")
    }

    /// **Bring Back to Figures is refused over a figure whose piece is in
    /// read-through, saying which piece** (M3), as Send to Research is; Use
    /// in Document (creation) is not.
    func test_bringBackIsRefusedOverAFigureInReadThrough_namingThePiece() async throws {
        let store = try await collection()
        let table = try await store.addResearchTable(parentId: nil, title: "Copy")
        XCTAssertTrue(FigureActions.makesAFigure(table), "premise: a table makes a figure")
        func actions(_ gate: ReadThroughGate) -> FigureActions {
            FigureActions(store: store, figureWindows: nil, typography: .defaults,
                          windowRefusesWrites: { false }, readThrough: { gate }, report: { _ in })
        }
        let reading = G.gate(pieces: [G.pieceA])
        XCTAssertNil(actions(reading).researchVerb(for: table, returning: G.figureA), "not offered")
        XCTAssertTrue(actions(reading).bringBackRefusal(returning: G.figureA)?
            .contains("\u{201C}piece-a\u{201D}") == true, "and says which piece")
        XCTAssertEqual(actions(reading).researchVerb(for: table, returning: nil), .use,
                       "making a new figure is creation, refused by nothing")
        XCTAssertEqual(actions(.writing).researchVerb(for: table, returning: G.figureA),
                       .bringBack(figureId: G.figureA), "control: writing")
        // The drop onto Figures says it too.
        let tree = BinderTreeSectionsState()
        tree.figureReadThrough = reading
        tree.figureReturns = [table.id: G.figureA]
        XCTAssertNil(FigureSectionVerbs(store: store, state: tree).dropToUse(researchId: table.id))
        XCTAssertTrue(tree.pendingError?.contains("\u{201C}piece-a\u{201D}") == true)
    }

    /// **One gate per session** (M6): a window just opened, whose figure
    /// listing has not built, cannot unrefuse a figure owned through a line;
    /// the gates every open window handed over are combined.
    func test_aWindowWithAnEmptyListingCannotUnrefuseAFigure() {
        let full = G.gate(pieces: [G.pieceA], figureLines: [G.line(G.bookFigure, in: G.pieceA)])
        let empty = G.gate(pieces: [G.pieceA], figureLines: [])
        let windows = FigureWindows()
        let first = UUID(), second = UUID()
        windows.setReadThrough(full, from: first)
        XCTAssertTrue(windows.isInReadThrough(G.bookFigure), "premise: owned through its line")
        windows.setReadThrough(empty, from: second)
        XCTAssertTrue(windows.isInReadThrough(G.bookFigure), "the newer window's empty listing unrefuses nothing")
        windows.dropReadThrough(from: first)
        XCTAssertFalse(windows.isInReadThrough(G.bookFigure),
                       "control: with only the window that has not built its listing, the line is unknown")
        windows.setReadThrough(.writing, from: second)
        XCTAssertFalse(windows.isInReadThrough(G.figureA), "Resume: the newest gate's set decides")
    }

    // MARK: - Closing fixes (branch review)

    /// **Every door-checked manuscript writer is classified** (I1): each
    /// production call of `openManuscriptForWriting` or
    /// `holdManuscriptsForFigureText`, by the function it sits in, is a
    /// deliberate sweep (which writes into a piece in read-through, ADR 0039
    /// §4) or refused for one. A new caller fails until it is classified.
    static let doorCheckedWriters: [String: String] = [
        "Maugham/Stores/ProjectStore+Search.swift#replaceInManuscript":
            "refused: Replace asks `pieceInReadThrough` before it holds the piece",
        "Maugham/Stores/ProjectStore+Search.swift#holdManuscriptsForFigureText":
            "the hold itself: classified by its callers below",
        "Maugham/Stores/ProjectStore+Figures.swift#renameFigure":
            "deliberate sweep: a figure rename's cross-reference relabel",
        "Maugham/Stores/ProjectStore+FigureResearch.swift#sendToResearch":
            "refused: the line it removes is in one of the figure's own pieces, so the gate refuses Send",
        "Maugham/Stores/ProjectStore+FigureResearch.swift#retargetFigureLine":
            "refused: Move into Figures edits that piece's own line (`readThroughGate().refusal(.piece)`)",
    ]

    /// The call sites of the two door-checked writers in `text`, by the
    /// function each sits in.
    static func doorCheckedCallers(in text: String) -> [String] {
        var current = ""
        var found: [String] = []
        for line in SourceScan.codeLines(of: text) {
            if let range = line.range(of: #"func [A-Za-z_]+"#, options: .regularExpression) {
                current = String(line[range].dropFirst(5))
            }
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.contains("func openManuscriptForWriting("),
                  !code.contains("func holdManuscriptsForFigureText(") else { continue }
            if code.contains("openManuscriptForWriting(") || code.contains("holdManuscriptsForFigureText(") {
                found.append(current)
            }
        }
        return found
    }

    func test_everyDoorCheckedManuscriptWriterIsClassified() throws {
        var sites: Set<String> = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            for caller in Self.doorCheckedCallers(in: try SourceTree.read(file)) {
                sites.insert("\(file)#\(caller)")
            }
        }
        XCTAssertEqual(sites, Set(Self.doorCheckedWriters.keys),
                       "classify a new writer as a deliberate sweep or refused for a piece in read-through")
        XCTAssertEqual(Self.doorCheckedCallers(in: """
            func planted() {
                let held = try await openManuscriptForWriting(path: p)
            }
            """), ["planted"], "a planted offender is found")
        XCTAssertEqual(Self.doorCheckedCallers(in: "// openManuscriptForWriting(path: p)"), [], "control: a comment")
    }

    /// **Move into Figures is refused for a piece in read-through, naming it**
    /// (I1): offered nowhere, said in the menu and by the verb, and refused
    /// by the store's own retarget.
    func test_moveIntoFiguresIsRefusedForAPieceInReadThrough() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let line = FigureListing.LegacyRow(
            id: "l1", docId: piece.id, lineIndex: 0, path: "../research/t.csv", caption: "",
            kind: .table, number: "Table 1", label: nil, researchItemId: "item")
        let gate = ReadThroughModifier.gate(gateInputs(store, pieces: [piece.id]))
        var said: [String] = []
        let actions = FigureActions(store: store, figureWindows: nil, typography: .defaults,
                                    windowRefusesWrites: { false }, readThrough: { gate },
                                    report: { said.append($0) })
        XCTAssertFalse(actions.mayMove(line), "not offered")
        let refusal = try XCTUnwrap(actions.moveRefusal(line))
        XCTAssertTrue(refusal.contains("\u{201C}Alpha\u{201D} is in read-through"), refusal)
        let writing = FigureActions(store: store, figureWindows: nil, typography: .defaults,
                                    windowRefusesWrites: { false }, readThrough: { .writing },
                                    report: { _ in })
        XCTAssertNil(writing.moveRefusal(line), "control: writing")

        store.readThroughPieceIds = { [piece.id] }
        do {
            try await store.retargetFigureLine(piece: piece.id, lineIndex: 0, oldPath: "a", newPath: "b",
                                               label: nil)
            XCTFail("the store refuses the retarget itself")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .inReadThrough(title: "Alpha"))
        }
    }

    /// **A new window's own surfaces ask the session's gate** (M1): a window
    /// whose listing has not built reads the figures every other window knows.
    func test_aNewWindowsSurfacesAskTheSessionsGate() throws {
        let full = G.gate(pieces: [G.pieceA], figureLines: [G.line(G.bookFigure, in: G.pieceA)])
        let unbuilt = G.gate(pieces: [G.pieceA], figureLines: [])
        let windows = FigureWindows()
        windows.setReadThrough(full, from: UUID())          // the first window
        windows.setReadThrough(unbuilt, from: UUID())       // the new one, its listing unbuilt
        XCTAssertFalse(unbuilt.refusesEdits(.figure(G.bookFigure)), "premise: its own gate would let it edit")
        let seen = ProjectWindow.sessionGate(figureWindows: windows, own: unbuilt)
        XCTAssertTrue(seen.refusesEdits(.figure(G.bookFigure)), "its centre, inspector and tree refuse it")
        XCTAssertEqual(seen.refusal(.figure(G.bookFigure))?.pieceId, G.pieceA)
        XCTAssertEqual(ProjectWindow.sessionGate(figureWindows: nil, own: unbuilt), unbuilt, "no session yet")
        let window = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ProjectWindow.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(window.contains(
            "Self.sessionGate(figureWindows: session?.figureWindows, own: ownReadThroughGate)"),
            "the surfaces read the session's gate")
    }

    /// **Typing into a read-through piece's research note pulses its line**
    /// (M4), as the text's does: the key lands nothing and is answered.
    func test_typingIntoAPiecesNotePulsesItsLine() async throws {
        let f = try await collectionWithNotes()
        let window = mountCentre(f, itemID: f.pieceNote.id, gate: f.gate)
        let note = try await editor(showing: Self.noteText, in: window)
        var pulses = 0
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post
            forName: .maughamTypingRefused, object: nil, queue: nil) { _ in pulses += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "x",
            charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        note.keyDown(with: key)
        XCTAssertEqual(pulses, 1, "the refused key is answered")
        XCTAssertEqual(note.string, Self.noteText, "and lands nothing")

        let writing = try await editor(showing: Self.noteText,
                                       in: mountCentre(f, itemID: f.sharedNote.id, gate: f.gate))
        writing.keyDown(with: key)
        XCTAssertEqual(pulses, 1, "control: a shared note takes the key, no pulse")
    }

    /// **The assistant's research writes are not refused** (ruling M1,
    /// ADR 0039 §4): read-through stops the writer's own accidental edits on
    /// this Mac; it is not a permission. No MCP tool asks it.
    func test_noMCPToolAsksReadThrough() throws {
        var found: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham/MCP") {
            let code = SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: "\n")
            if code.contains("ReadThrough") || code.contains("readThrough") { found.append(file) }
        }
        XCTAssertEqual(found, [], "deliberately left open: an assistant's research write is no accident")
    }
    // MARK: - Mounted: a Collection piece's research

    private static let noteText = "Ships at anchor, unhurried."

    /// **Its folder's note reads in the centre and beside; a shared note
    /// edits** — the mounted editor's coordinator carries the refusal
    /// (`lockEditing`, what `shouldChangeTextIn` asks), selection survives.
    func test_aPieceFoldersNoteReadsInTheCentreAndBeside_aSharedNoteEdits() async throws {
        let f = try await collectionWithNotes()
        let gate = f.gate

        let centre = mountCentre(f, itemID: f.pieceNote.id, gate: gate)
        let pieceEditor = try await editor(showing: Self.noteText, in: centre)
        XCTAssertEqual(pieceEditor.coordinator?.lockEditing, true, "the piece's note reads in the centre")
        XCTAssertFalse(pieceEditor.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x"))
        XCTAssertTrue(pieceEditor.isSelectable, "read, not hidden")

        let shared = mountCentre(f, itemID: f.sharedNote.id, gate: gate)
        let sharedEditor = try await editor(showing: Self.noteText, in: shared)
        XCTAssertEqual(sharedEditor.coordinator?.lockEditing, false, "a shared note edits while the piece reads")

        let beside = mountBeside(f, pulled: .research(f.pieceNote.id), gate: gate)
        let besideEditor = try await editor(showing: Self.noteText, in: beside)
        XCTAssertFalse(besideEditor.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x"),
                       "pulled up, it reads as in the centre")

        let writing = mountCentre(f, itemID: f.pieceNote.id, gate: .writing)
        let writingEditor = try await editor(showing: Self.noteText, in: writing)
        XCTAssertEqual(writingEditor.coordinator?.lockEditing, false, "control: Resume, and it edits")
    }

    /// **The line over a read-through piece's note takes its own height
    /// only** (I1): the note's editor starts right under it and gives up
    /// exactly that height, measured mounted against the same note writing.
    func test_theLineOverAPiecesNoteTakesItsOwnHeight() async throws {
        let f = try await collectionWithNotes()
        func editor(in window: NSWindow) async throws -> (top: CGFloat, height: CGFloat) {
            let text = try await self.editor(showing: Self.noteText, in: window)
            let content = try XCTUnwrap(window.contentView)
            let scroll = try XCTUnwrap(text.enclosingScrollView)
            let rect = scroll.convert(scroll.bounds, to: content)
            return (content.isFlipped ? rect.minY : content.bounds.height - rect.maxY, rect.height)
        }
        let writing = try await editor(in: mountCentre(f, itemID: f.pieceNote.id, gate: .writing))
        let reading = try await editor(in: mountCentre(f, itemID: f.pieceNote.id, gate: f.gate))
        let refusal = try XCTUnwrap(f.gate.refusal(.research(f.pieceNote.id)))
        XCTAssertEqual(refusal.title, "Alpha", "premise: the line names the piece")
        let own = NSHostingView(rootView: ReadThroughLine(offer: refusal.resumeOffer)).fittingSize.height
        XCTAssertGreaterThan(own, 10)
        XCTAssertLessThan(own, 60, "one line of callout text and its padding")
        XCTAssertEqual(reading.top - writing.top, own, accuracy: 1.5, "the note starts right under the line")
        XCTAssertEqual(writing.height - reading.height, own, accuracy: 1.5, "and gives up its height alone")
    }

    /// **An image paste into the piece's note lands no file** — the paste
    /// handler is not wired while read-only, so `ImagePasteHandler` never
    /// writes the PNG before the refused text. The control: writing, the
    /// paste saves and references.
    func test_anImagePasteIntoThePiecesNoteLandsNoFile() async throws {
        let f = try await collectionWithNotes()
        let assets = try assetsWell(for: f.pieceNote, in: f.store)

        let reading = try await editor(showing: Self.noteText,
                                       in: mountCentre(f, itemID: f.pieceNote.id, gate: f.gate))
        try putImageOnThePasteboard()
        reading.paste(from: pasteboard)
        // Negative assertion: outlast the synchronous write path.
        await waitOut(0.5)
        XCTAssertTrue(files(in: assets).isEmpty, "in read-through no file lands: \(files(in: assets))")
        XCTAssertEqual(reading.string, Self.noteText)

        for window in windows { window.contentView = NSView(frame: .zero) }
        windows.removeAll()
        let writing = try await editor(showing: Self.noteText,
                                       in: mountCentre(f, itemID: f.pieceNote.id, gate: .writing))
        try putImageOnThePasteboard()
        writing.paste(from: pasteboard)
        await pumpUntil(deadline: 5) { !self.files(in: assets).isEmpty }
        XCTAssertEqual(files(in: assets).count, 1, "control: writing, the paste saves")
    }

    /// **The piece's Research table reads** — its grid opens read-only with
    /// read-through's reason; a shared table's grid edits.
    func test_thePiecesTableReads_aSharedTableEdits() async throws {
        let f = try await collectionWithNotes()
        let table = try await f.store.addPieceResearchTable(pieceId: f.piece.id, title: "Tides")
        let sharedTable = try await f.store.addResearchTable(parentId: nil, title: "Shared")
        let gate = ReadThroughModifier.gate(gateInputs(f.store, pieces: [f.piece.id]))

        let reading = mountCentre(f, itemID: table.id, gate: gate)
        let readingGrid = try await grid(in: reading)
        let alpha = ReadThroughRefusal(pieceId: f.piece.id, title: "Alpha", others: 0)
        XCTAssertEqual(readingGrid.mode, .readOnly(.readThrough(alpha)))
        XCTAssertEqual(readingGrid.bars.reasonMessage,
                       "\u{201C}Alpha\u{201D} is in read-through \u{2014} resume writing it to change this table.",
                       "the grid's reason names the piece")

        let shared = mountCentre(f, itemID: sharedTable.id, gate: gate)
        let sharedGrid = try await grid(in: shared)
        XCTAssertEqual(sharedGrid.mode, .editable, "control: shared research edits")
    }

    /// **The tree's verbs stay live**: a rename of the piece's own note lands
    /// while its piece is in read-through and the note reads in the centre.
    func test_treeVerbsStayLive_aRenameLands() async throws {
        let f = try await collectionWithNotes()
        _ = try await editor(showing: Self.noteText, in: mountCentre(f, itemID: f.pieceNote.id, gate: f.gate))
        let state = BinderTreeSectionsState()
        var subject: BinderSubject? = .research(f.pieceNote.id)
        let binding = Binding(get: { subject }, set: { subject = $0 })
        BinderTreeVerbs(store: f.store, state: state, subject: .tree(binding)).bundle
            .rename(f.pieceNote.id, "Tides")
        await pumpUntil(deadline: 5) {
            TreeWalk.find(id: f.pieceNote.id, in: f.store.manifest.research)?.title == "Tides"
        }
        XCTAssertEqual(TreeWalk.find(id: f.pieceNote.id, in: f.store.manifest.research)?.title, "Tides")
    }

    // MARK: - The censuses

    /// Where each thing Lock did lives now, or why it is gone (carry E).
    enum Home {
        /// The capability's new answer, by a token in a file.
        case code(file: String, token: String)
        /// Dropped on purpose, and why.
        case dropped(String)
    }

    /// **Lock's capability census** — every reader of the window's Lock, as
    /// `LockTests.lockSites` / `pulledUpLockSites` listed them, plus its
    /// toggle, key and storage.
    static let lockCapabilities: [(lock: String, home: Home)] = [
        ("Research in the centre (CentreColumn → ResearchSubjectCentre)",
         .code(file: "Maugham/Views/CentreColumn.swift", token: "readThrough: readThrough.refusal(.research(id)),")),
        ("A pulled-up research item or figure (PulledUp.refusesEdits)",
         .code(file: "Maugham/Models/PulledUp.swift", token: "func refusesEdits(readThrough: ReadThroughGate) -> Bool")),
        ("The centre's research details",
         .code(file: "Maugham/Views/PulledUpView.swift",
               token: "static func centreResearchIsReadOnly(_ id: String, readThrough: ReadThroughGate) -> Bool")),
        ("A figure's writes (FigureActions.windowRefusesWrites)",
         .code(file: "Maugham/Views/FigureActions.swift", token: "func refusesWrites(to figureId: String) -> Bool")),
        ("The centre figure grid (FigureSubjectColumns, FigureCentreGrid)",
         .code(file: "Maugham/Editor/FigureGridGate.swift", token: "if isInReadThrough { return .readOnly(.readThrough(refusal)) }")),
        ("A figure window",
         .code(file: "Maugham/Editor/FigureWindow.swift", token: "windows?.readThroughRefusal(figureId)")),
        ("Research versions' Restore",
         .code(file: "Maugham/Views/ResearchVersionsSection.swift",
               token: "static func restoreRefusal(shareIsReadOnly: Bool, readThrough: ReadThroughRefusal?)")),
        ("A Research table's grid",
         .code(file: "Maugham/Editor/ResearchTableGrid.swift", token: "isInReadThrough: readThrough != nil, naming: readThrough,")),
        ("A palette card on the wall", .dropped("no piece owns a palette card; it is the book's")),
        ("New Table", .dropped("creation is not an accidental edit; the share alone refuses it")),
        ("Accept on a figure cell", .dropped("a decision, on in read-through (Task 2)")),
        ("The padlock and ⌘⌥⇧L",
         .code(file: "Maugham/Views/ReadThroughToggle.swift", token: "struct ReadThroughToggle: View")),
        ("Per window, never stored, every window opens unlocked",
         .dropped("gone by design: read-through is per piece and remembered on this Mac (ReadThroughStore)")),
    ]

    func test_everyLockCapabilityHasAHome() throws {
        XCTAssertEqual(Self.lockCapabilities.count, 13, "every row of the brief's table")
        for (lock, home) in Self.lockCapabilities {
            switch home {
            case .code(let file, let token):
                let text = SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: "\n")
                XCTAssertTrue(text.contains(token), "\(lock): \(file) no longer holds `\(token)`")
            case .dropped(let reason):
                XCTAssertFalse(reason.isEmpty, "\(lock): dropped without a reason")
            }
        }
    }

    /// **The files that ask read-through's one answer** — `ReadThrough.isOn(`
    /// or `.refusesEdits(` on a gate or a pulled-up item — and how many times
    /// each. A surface that stopped asking would pass every mounted test that
    /// happens not to visit it; one that asked a second way is a second rule.
    static let readThroughSites: [String: Int] = [
        "Maugham/Views/ReadThrough.swift": 3,           // the gate's rule, its refusal, the offer
        "Maugham/Views/ReadThroughModifier.swift": 2,   // Start's guard, the facts
        "Maugham/Models/PulledUp.swift": 2,             // a research item, a figure
        "Maugham/Views/PulledUpView.swift": 2,          // the face, the centre's details
        "Maugham/Views/FigureActions.swift": 1,         // a figure's writes
        "Maugham/Editor/FigureWindow.swift": 1,         // figure windows, grids in place
        "Maugham/Stores/ProjectStore+Search.swift": 1,  // Replace: a piece (its folder asks the refusal)
        "Maugham/Views/EditorHost.swift": 1,            // a refused key's answer
        "Maugham/Editor/EditorSurface.swift": 1,        // the mount
        "Maugham/Editor/EditorCoordinator.swift": 1,    // the mirror
        "Maugham/Editor/EditorControl.swift": 2,        // the review render, the line
    ]

    static func readThroughCounts(_ text: String) -> Int {
        SourceScan.codeLines(of: text).reduce(0) { count, line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("func refusesEdits("), !code.hasPrefix("static func isOn(") else { return count }
            return count + code.components(separatedBy: "ReadThrough.isOn(").count - 1
                + code.components(separatedBy: ".refusesEdits(").count - 1
        }
    }

    func test_everyReadThroughSiteAsksTheOneAnswer() throws {
        var counts: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let n = Self.readThroughCounts(try SourceTree.read(file))
            if n > 0 { counts[file] = n }
        }
        XCTAssertEqual(counts, Self.readThroughSites)
    }

    /// The counter sees a planted offender, and passes over a comment and the
    /// rule's own declarations (the control).
    func test_theReadThroughCensusSeesAPlantedOffender() {
        XCTAssertEqual(Self.readThroughCounts("let x = gate.refusesEdits(.figure(id))"), 1)
        XCTAssertEqual(Self.readThroughCounts("if ReadThrough.isOn(doc, in: ids) {}"), 1)
        XCTAssertEqual(Self.readThroughCounts("// gate.refusesEdits(.figure(id))"), 0, "a comment")
        XCTAssertEqual(Self.readThroughCounts("func refusesEdits(_ target: ReadThroughTarget) -> Bool {"), 0,
                       "the declaration")
        XCTAssertEqual(Self.readThroughCounts("let y = 1"), 0)
    }

    /// **No Lock name remains** in the app's sources.
    func test_noLockNamesRemain() throws {
        let names = ["WindowLock", "LockToggle", "isLocked", "lockApplies", "maughamToggleLock"]
        var found: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let text = try SourceTree.read(file)
            for name in names where text.contains(name) { found.append("\(file): \(name)") }
        }
        XCTAssertEqual(found, [])
        // Control: the names are still the test target's to read here.
        XCTAssertTrue(try SourceTree.read("MaughamTests/ReadThroughResearchSurfaceTests.swift").contains("WindowLock"))
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: ProjectStore
        let documentStore: DocumentStore
        let piece: StructureItem
        let pieceNote: ResearchItem
        let sharedNote: ResearchItem
        let gate: ReadThroughGate
        let preferences: UserPreferences
    }

    private func open(_ url: URL) async throws -> ProjectStore {
        let documentStore = try await DocumentStore.open(url: url)
        stores.append(documentStore)
        let store = try await ProjectStore.load(from: url)
        store.documentStore = documentStore
        documentStore.projectStore = store
        await store.wordCountPopulationTask?.value
        return store
    }

    private func collection() async throws -> ProjectStore {
        try await open(try await ProjectFactory.createCollectionProject(named: "Stories", in: folder))
    }

    private func gateInputs(_ store: ProjectStore, pieces: Set<String>) -> ReadThroughModifier.GateInputs {
        .init(pieces: pieces, structure: store.manifest.structure, research: store.manifest.research,
              figures: store.manifest.figures ?? [], figureRows: [])
    }

    /// A Collection with one loose piece, a note in its own folder and a
    /// shared note, both holding `noteText`; the gate with the piece in
    /// read-through, built by the window's own function.
    private func collectionWithNotes() async throws -> Fixture {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let own = try await store.addResearchTextNote(parentId: nil, title: "Tide")
        try await store.moveResearchItems(ids: [own.id], to: .piece(piece.id))
        let shared = try await store.addResearchTextNote(parentId: nil, title: "Ships")
        let pieceNote = try XCTUnwrap(TreeWalk.find(id: own.id, in: store.manifest.research))
        XCTAssertEqual(store.researchScopePieceId(ofPath: pieceNote.path), piece.id,
                       "premise: the note is in the piece's own folder")
        for note in [pieceNote, shared] {
            try Data(Self.noteText.utf8).write(to: store.url.appendingPathComponent(try XCTUnwrap(note.path)))
        }
        await store.wordCountPopulationTask?.value
        let suite = "read-through-research-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        return Fixture(store: store, documentStore: try XCTUnwrap(store.documentStore), piece: piece,
                       pieceNote: pieceNote, sharedNote: shared,
                       gate: ReadThroughModifier.gate(gateInputs(store, pieces: [piece.id])),
                       preferences: UserPreferences(defaults: UserDefaults(suiteName: suite)!))
    }

    private func mountCentre(_ f: Fixture, itemID: String, gate: ReadThroughGate) -> NSWindow {
        let window = TestWindow.mount(AnyView(
            ResearchCentreFixture.centre(store: f.store, documentStore: f.documentStore,
                                         itemID: itemID, readThrough: gate)
                .environment(f.preferences)),
            size: CGSize(width: 700, height: 600), as: SilentTestWindow.self)
        windows.append(window)
        pump(0.3)
        return window
    }

    private func mountBeside(_ f: Fixture, pulled: PulledUp, gate: ReadThroughGate) -> NSWindow {
        var subject = WindowSubject(open: .item(f.piece.id), faces: .item(f.piece.id))
        subject.beside = pulled
        let window = TestWindow.mount(AnyView(
            PulledUpFixture.view(
                store: f.store, documentStore: f.documentStore, subject: .constant(subject),
                readThrough: gate, figureTree: BinderTreeSectionsState(),
                onOpenInCentre: { _ in }, memory: PulledUpMemory(), onShowNotes: { _ in },
                canvasDetails: PulledUpFixture.markerDetails)
                .environment(f.preferences)),
            size: CGSize(width: 360, height: 600), as: SilentTestWindow.self)
        windows.append(window)
        pump(0.3)
        return window
    }

    private func editor(showing text: String, in window: NSWindow) async throws -> MaughamTextView {
        await pumpUntil(deadline: 5) { self.textViews(in: window).contains { $0.string.contains(text) } }
        await waitOut(0.2)
        return try XCTUnwrap(textViews(in: window).first { $0.string.contains(text) }, "the note's text is drawn")
    }

    private func grid(in window: NSWindow) async throws -> FigureGridController {
        await pumpUntil(deadline: 5) { Self.find(FigureGridView.self, in: window.contentView).first != nil }
        await waitOut(0.2)
        let view = try XCTUnwrap(Self.find(FigureGridView.self, in: window.contentView).first, "the grid mounted")
        return try XCTUnwrap(view.delegate as? FigureGridController)
    }

    private func textViews(in window: NSWindow) -> [MaughamTextView] {
        Self.find(MaughamTextView.self, in: window.contentView)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        let here: [T] = (view as? T).map { [$0] } ?? []
        return here + view.subviews.flatMap { find(type, in: $0) }
    }

    private func assetsWell(for note: ResearchItem, in store: ProjectStore) throws -> URL {
        let file = store.url.appendingPathComponent(try XCTUnwrap(note.path))
        return file.deletingLastPathComponent()
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)_assets")
    }

    /// This test's own pasteboard, never `.general`.
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("maugham-test-\(UUID().uuidString)"))

    private func putImageOnThePasteboard() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.addRepresentation(rep)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([image]))
    }

    private func files(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }
}
