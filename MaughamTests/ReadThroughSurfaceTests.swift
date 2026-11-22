import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The way into a read-through, the line over the text and the tree's lock;
/// Manual Review Mode gone** (shell read-through Task 3).
///
/// The offer is pinned pure (its titles and the requests each route may
/// post); the routes and the key by source census; the receiver in a real
/// window (`KeyTestWindow`, the one OS fact a test host cannot produce); the
/// line's widths and its place over the editor, and the mark on each tree
/// host, as ink and frames read synchronously off a mounted window — never a
/// press and a wait (tripwire 33).
@MainActor
final class ReadThroughSurfaceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The offer, pure

    private func chapter(_ id: String = "Chapter-1") -> StructureItem {
        StructureItem(id: id, title: "Chapter One", type: .document, path: "manuscript/one.md")
    }

    private func offer(on: Bool = false, lacking: Bool = false, posture: Posture? = .author,
                       share: Bool = false, translation: Bool = false,
                       visible: Bool = true) -> ReadThroughOffer? {
        let item = chapter()
        return ReadThroughOffer.of(
            docId: item.id, item: item, posture: posture, shareIsReadOnly: share,
            isReadingTranslation: translation, isTextVisible: visible,
            pieces: on ? [item.id] : [], lackingCheckpoint: lacking ? [item.id] : [])
    }

    /// **The menu item's title and what it posts, per state.**
    func test_theOffersTitleAndRequestPerState() throws {
        let writing = try XCTUnwrap(offer())
        XCTAssertEqual(writing.menuTitle, "Start Read-through")
        XCTAssertEqual(writing.toggleRequest, ReadThrough.Request(docId: "Chapter-1", on: true))
        XCTAssertNil(writing.resumeRequest, "the line's Resume belongs to a piece in read-through")
        XCTAssertNil(writing.saveCheckpointRequest)

        let reading = try XCTUnwrap(offer(on: true))
        XCTAssertEqual(reading.menuTitle, "Resume Writing")
        XCTAssertEqual(reading.toggleRequest, ReadThrough.Request(docId: "Chapter-1", on: false))
        XCTAssertEqual(reading.resumeRequest, ReadThrough.Request(docId: "Chapter-1", on: false))
        XCTAssertNil(reading.saveCheckpointRequest, "its checkpoint was saved")

        for refused in [offer(posture: .settling), offer(share: true), offer(translation: true),
                        offer(visible: false)] {
            let refused = try XCTUnwrap(refused)
            XCTAssertEqual(refused.menuTitle, "Start Read-through")
            XCTAssertNil(refused.toggleRequest, "a refused Start posts nothing: \(String(describing: refused.reason))")
        }
        XCTAssertEqual(offer(translation: true)?.reason, "Read Source to start a read-through.")
        XCTAssertNil(ReadThroughOffer.of(docId: nil, item: nil, posture: .author, shareIsReadOnly: false,
                                         isReadingTranslation: false, isTextVisible: true,
                                         pieces: [], lackingCheckpoint: []),
                     "no piece open: the item is disabled under its Start title")
    }

    /// **You never enter a state you cannot see** (fix round M2): under an
    /// altitude, a cover or any centre that hides the piece's text, Start is
    /// refused with its reason; Resume stays wherever the piece is the open one.
    func test_startNeedsThePiecesTextOnScreen_resumeDoesNot() throws {
        let hidden = try XCTUnwrap(offer(visible: false))
        XCTAssertFalse(hidden.isEnabled)
        XCTAssertEqual(hidden.reason, ReadThroughOffer.hiddenTextRefusal)
        let resume = try XCTUnwrap(offer(on: true, visible: false))
        XCTAssertEqual(resume.toggleRequest, ReadThrough.Request(docId: "Chapter-1", on: false))

        // The window's answer, from its route (`ProjectWindow.manuscriptIsVisible`).
        let bare = facts(route: .editor(altitude: nil, cover: nil))
        XCTAssertEqual(ReadThroughModifier.offer(bare)?.isEnabled, true)
        for route: CentreRoute? in [.editor(altitude: .outline, cover: nil),
                                    .editor(altitude: nil, cover: .notice(.neverCompiled)),
                                    .canvas, nil] {
            XCTAssertEqual(ReadThroughModifier.offer(facts(route: route))?.isEnabled, false,
                           "Start under \(String(describing: route))")
            XCTAssertEqual(ReadThroughModifier.offer(facts(route: route, on: true))?.isEnabled, true,
                           "Resume under \(String(describing: route))")
        }
    }

    /// **The window's offer, as the menu reads it** (fix round M5): built from
    /// the facts the window gathers once — the item, the lacking set passed
    /// through, nothing for a reference piece.
    func test_theWindowsOfferIsBuiltFromItsFacts() throws {
        let reading = try XCTUnwrap(ReadThroughModifier.offer(facts(on: true, lacking: true)))
        XCTAssertTrue(reading.lacksCheckpoint)
        XCTAssertNotNil(reading.saveCheckpointRequest)
        let reference = StructureItem(id: "Chapter-1", title: "Linked", type: .document,
                                      path: "pieces/ref/.maugham-link.json", pieceKind: .reference)
        XCTAssertNil(ReadThroughModifier.offer(facts(item: reference)), "a reference piece is never offered")
        XCTAssertNil(ReadThroughModifier.offer(facts(item: nil)), "no piece open")
        let modifier = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ReadThroughModifier.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(modifier.contains(".focusedSceneValue(\\.readThroughOffer, Self.offer(facts))"),
                      "the modifier publishes the window's offer")
        let item = try SourceTree.declaration(named: "struct FocusedReadThroughItem", under: "Maugham")
        XCTAssertTrue(item.contains("@FocusedValue(\\.readThroughOffer) private var offer"),
                      "and the menu item reads it")
        let window = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ProjectWindow.swift"))
            .joined(separator: "\n")
        XCTAssertEqual(window.components(separatedBy: "let facts = readThroughFacts").count - 1, 1,
                       "the window gathers its facts once per pass")
        XCTAssertTrue(window.contains("facts: facts, treeState: treeState,"))
    }

    private func facts(item: StructureItem? = StructureItem(
                           id: "Chapter-1", title: "Chapter One", type: .document,
                           path: "manuscript/one.md"),
                       route: CentreRoute? = .editor(altitude: nil, cover: nil),
                       on: Bool = false, lacking: Bool = false,
                       posture: Posture? = .author) -> ReadThroughModifier.Facts {
        ReadThroughModifier.Facts(
            docId: item?.id, item: item, posture: posture, shareIsReadOnly: false,
            isReadingTranslation: false, route: route,
            pieces: on ? ["Chapter-1"] : [], lackingCheckpoint: lacking ? ["Chapter-1"] : [])
    }

    /// **On, but no checkpoint was saved** (carry B): Resume stays, and Save one
    /// posts the Start that takes the missing checkpoint — but only where that
    /// checkpoint could land (fix round I1). Under a refusing posture or a
    /// view-only share the line says none was saved and offers no button, and
    /// the notice names none.
    func test_saveOneIsOfferedOnlyWhereTheCheckpointCanLand() throws {
        for lacking in [offer(on: true, lacking: true),
                        offer(on: true, lacking: true, translation: true, visible: false)] {
            let lacking = try XCTUnwrap(lacking)
            XCTAssertTrue(lacking.lacksCheckpoint)
            XCTAssertEqual(lacking.menuTitle, "Resume Writing")
            XCTAssertEqual(lacking.saveCheckpointRequest, ReadThrough.Request(docId: "Chapter-1", on: true))
            XCTAssertEqual(lacking.resumeRequest, ReadThrough.Request(docId: "Chapter-1", on: false))
        }
        for refused in [offer(on: true, lacking: true, posture: .settling),
                        offer(on: true, lacking: true, posture: nil),
                        offer(on: true, lacking: true, share: true)] {
            let refused = try XCTUnwrap(refused)
            XCTAssertTrue(refused.lacksCheckpoint, "the line still says none was saved")
            XCTAssertNil(refused.saveCheckpointRequest, "but offers no Save one that would be refused")
            XCTAssertEqual(refused.resumeRequest, ReadThrough.Request(docId: "Chapter-1", on: false))
        }
        XCTAssertEqual(ReadThroughLine.fullText(lacksCheckpoint: true),
                       "In read-through · no checkpoint was saved")
        XCTAssertEqual(ReadThroughLine.saveTitle, "Save one")
        XCTAssertTrue(ReadThroughVerbs.unsavedCheckpointNotice(why: "it failed.", offersSaveOne: true)
            .hasSuffix("it failed. Press Save one over the text to save it."),
                      "the notice names the button that exists")
        XCTAssertEqual(ReadThroughVerbs.unsavedCheckpointNotice(why: "it failed.", offersSaveOne: false),
                       "Read-through is on, but no checkpoint was saved — it failed.",
                       "and names none where none is drawn")
    }

    /// **The line the editor draws, from the control**: only for its own
    /// document in read-through, never over a translation; Save one only
    /// where the control's posture and share let a checkpoint land.
    func test_theControlDrawsTheLineForItsOwnPieceOnly() {
        let control = EditorControl()
        control.posture = .author
        XCTAssertNil(control.readThroughLineOffer(docId: "Chapter-1"))
        control.readThroughDocIds = ["Chapter-1"]
        XCTAssertEqual(control.readThroughLineOffer(docId: "Chapter-1"),
                       .on(docId: "Chapter-1", lacksCheckpoint: false, mayTakeCheckpoint: true))
        XCTAssertNil(control.readThroughLineOffer(docId: "Chapter-2"), "another piece draws none")
        control.readThroughLackingCheckpoint = ["Chapter-1"]
        XCTAssertNotNil(control.readThroughLineOffer(docId: "Chapter-1")?.saveCheckpointRequest)
        control.shareIsReadOnly = true
        XCTAssertNil(control.readThroughLineOffer(docId: "Chapter-1")?.saveCheckpointRequest,
                     "a view-only share: no Save one")
        control.shareIsReadOnly = false
        control.posture = .settling
        XCTAssertEqual(control.readThroughLineOffer(docId: "Chapter-1")?.lacksCheckpoint, true)
        XCTAssertNil(control.readThroughLineOffer(docId: "Chapter-1")?.saveCheckpointRequest,
                     "a posture that may not write: no Save one")
        control.posture = .author
        control.translationLanguage = "sr"
        XCTAssertNil(control.readThroughLineOffer(docId: "Chapter-1"),
                     "over a translation the language's line stands, never both")
    }

    /// **`ReadThrough.post` builds the one payload** every route sends.
    func test_thePostBuildsTheOnePayload() {
        final class Heard { var requests: [ReadThrough.Request?] = [] }
        let heard = Heard()
        let token = MaughamEvent.observe(
            .maughamSetReadThrough,
            context: { EventReceiverContext(kind: .keyWindow, isWindowLive: true, isWindowKey: true) },
            handler: { note in heard.requests.append(ReadThrough.request(of: note.userInfo)) })
        defer { NotificationCenter.default.removeObserver(token) }
        ReadThrough.post(ReadThrough.Request(docId: "Chapter-1", on: true))
        ReadThrough.post(ReadThrough.Request(docId: "Chapter-1", on: false))
        XCTAssertEqual(heard.requests, [ReadThrough.Request(docId: "Chapter-1", on: true),
                               ReadThrough.Request(docId: "Chapter-1", on: false)])
        XCTAssertNil(ReadThrough.request(of: ["doc_id": "x"]), "a malformed post is no request")
    }

    /// VoiceOver hears one sentence; the mark says its state.
    func test_whatVoiceOverHears() {
        XCTAssertEqual(ReadThroughLine.accessibilityText(lacksCheckpoint: false),
                       "In read-through. Typing is off.")
        XCTAssertEqual(ReadThroughLine.fullText(lacksCheckpoint: false), "In read-through · typing is off")
        XCTAssertEqual(ReadThroughMark.label, "In read-through")
        XCTAssertEqual(ReadThroughMark.symbol, "lock.fill")
    }

    // MARK: - The routes, by census

    /// **The menu item is in View where Toggle Review Mode stood, and ⌘⌥⇧R is
    /// spelled once in the app.**
    func test_theMenuItemAndItsKeyAreOne() throws {
        let app = SourceScan.codeLines(of: try SourceTree.read("Maugham/MaughamApp.swift"))
            .joined(separator: "\n")
        XCTAssertEqual(app.components(separatedBy: "FocusedReadThroughItem()").count - 1, 1,
                       "View ▸ Start Read-through is mounted once")
        let view = try XCTUnwrap(app.range(of: "CommandGroup(after: .toolbar)"), "the View menu")
        let item = try XCTUnwrap(app.range(of: "FocusedReadThroughItem()"))
        XCTAssertGreaterThan(item.lowerBound, view.lowerBound, "the item is in View")

        var chords: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            for line in SourceScan.codeLines(of: try SourceTree.read(file))
            where line.contains(".keyboardShortcut(\"r\"") || line.contains(".keyboardShortcut(KeyEquivalent(\"r\")") {
                if line.contains(".option") && line.contains(".shift") && line.contains(".command") {
                    chords.append(file)
                }
            }
        }
        XCTAssertEqual(chords, ["Maugham/MaughamApp.swift"], "⌘⌥⇧R is spelled once")
        let declaration = try SourceTree.declaration(named: "struct FocusedReadThroughItem", under: "Maugham")
        XCTAssertTrue(declaration.contains(".keyboardShortcut(\"r\", modifiers: [.command, .option, .shift])"),
                      "and it is the read-through item's")
    }

    /// **Every route posts only what an offer gives it** (carry A): the menu
    /// item its `toggleRequest`, the line its `resumeRequest` and
    /// `saveCheckpointRequest`; and the event is posted in one place.
    func test_everyRoutePostsOnlyWhatTheOfferGives() throws {
        let item = try SourceTree.declaration(named: "struct FocusedReadThroughItem", under: "Maugham")
        XCTAssertTrue(item.contains("if let request = offer?.toggleRequest { ReadThrough.post(request) }"))
        XCTAssertTrue(item.contains(".disabled(offer?.toggleRequest == nil)"))
        let line = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ReadThroughLine.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(line.contains("if let save = offer.saveCheckpointRequest {"))
        XCTAssertTrue(line.contains("Button(Self.saveTitle) { ReadThrough.post(save) }"))
        XCTAssertTrue(line.contains("if let resume = offer.resumeRequest {"))
        XCTAssertTrue(line.contains("Button(Self.resumeTitle) { ReadThrough.post(resume) }"))

        var posters: [String] = []
        var postCalls: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let code = SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: "\n")
            if code.contains("MaughamEvent.post(.maughamSetReadThrough") { posters.append(file) }
            if code.contains("ReadThrough.post(") { postCalls.append(file) }
        }
        XCTAssertEqual(posters, ["Maugham/Views/ReadThrough.swift"], "one sender")
        XCTAssertEqual(Set(postCalls), ["Maugham/MaughamApp.swift", "Maugham/Views/ReadThroughLine.swift",
                                        "Maugham/Views/ReadThroughToggle.swift"],
                       "the routes: the menu item, the line and the padlock")
        let padlock = try SourceTree.declaration(named: "struct ReadThroughToggle", under: "Maugham")
        XCTAssertTrue(padlock.contains("static func request(_ offer: ReadThroughOffer?) -> ReadThrough.Request? {"))
        XCTAssertTrue(padlock.contains("offer?.toggleRequest"), "the padlock posts only what the offer gives")
    }

    /// **Manual Review Mode's names are gone from the app.**
    func test_noManualReviewNamesRemain() throws {
        let names = ["isManualReviewMode", "maughamToggleReviewMode", "isReviewModeOn",
                     "ReviewModeIndicator", "setManualReviewMode", "reviewModeChanged",
                     "manualReview:", "reviewModeAccept"]
        var found: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let text = try SourceTree.read(file)
            for name in names where text.contains(name) { found.append("\(file): \(name)") }
        }
        XCTAssertEqual(found, [], "Manual Review Mode is removed, comments included")
        let files = try SourceTree.swiftFiles(under: "Maugham").map { ($0 as NSString).lastPathComponent }
        XCTAssertFalse(files.contains("ReviewModeIndicator.swift"))
    }

    /// **Every capability Manual Review Mode had has a home, or is named as
    /// gone with its reason** (in the shape of `test_everyDeskCapabilityHasAHome`).
    func test_everyManualReviewCapabilityHasAHome() throws {
        let editor = "Maugham/Editor/"
        let views = "Maugham/Views/"
        let homes: [(capability: String, file: String, token: String)] = [
            ("text refuses typing", editor + "EditorCoordinator.swift",
             "!readOnlyRecovery && !bufferHoldsTranslation && !isInReadThrough"),
            ("the membrane's belt", editor + "EditorEditPolicy.swift",
             "!isReviewMode && !lockEditing && !isReadingTranslation && !isInReadThrough"),
            ("review render: marks, margin rail, selection toolbar", editor + "EditorCoordinator.swift",
             "setReviewMode(c.isReviewMode || isInReadThrough)"),
            ("focus-dim and typewriter centring off", editor + "EditorCoordinator.swift",
             "let target = (typewriterScroll && !isReviewMode && clipHeight > 0)"),
            ("the open-annotation mirror", editor + "EditorControl.swift",
             "isReviewMode || ReadThrough.isOn(docId, in: readThroughDocIds)"),
            ("remembered across quitting", "Maugham/Stores/ReadThroughStore.swift",
             "static func fileURL(projectRoot: URL, device: DeviceSlug) -> URL {"),
            ("visible feedback over the text", views + "EditorHost.swift",
             "ReadThroughLine(offer: offer, window: window)"),
            ("the figure grid is read-only, its notes answered", editor + "FigureGridGate.swift",
             "if isInReadThrough { return .readOnly(.readThrough) }"),
            ("Accept on a figure cell writes", editor + "FigureGridStrip.swift",
             "reason == nil || reason == .readThrough"),
            ("a figure window follows", editor + "FigureWindow.swift",
             "isInReadThrough: frame?.isInReadThrough() ?? false,"),
            ("the centre figure grid follows", views + "FigureSubjectColumns.swift",
             ".refusesEdits(.figure(figureID)),"),
            ("the Insert menu is off", views + "EditorControlMirror.swift",
             "&& !readThrough && !isReadingTranslation"),
            ("a menu item and a key", "Maugham/MaughamApp.swift", "FocusedReadThroughItem()"),
            ("the synchronous flip (Bug B)", editor + "EditorCoordinator.swift",
             "readThroughObserver = MaughamEvent.observe("),
            ("completion closes", editor + "EditorCoordinator.swift",
             "func setReadThrough(_ on: Bool, in mountingView: NSTextView? = nil) {"),
            ("the tree says so", views + "BinderRow.swift",
             "ReadThroughMark(isOn: readThroughPieces.contains(item.id))"),
        ]
        let gone: [String: String] = [
            "window-wide over every piece": "by design: read-through is per piece",
            "\"Reviewing · <name>\" pill": "the line names the state; notes still carry the author's name",
            "the figure inspector refused under it": "the share and Lock still refuse; Task 4 makes it per figure",
        ]
        XCTAssertEqual(homes.count + gone.count, 19, "one row per line of the brief's census")
        XCTAssertEqual(Set(homes.map(\.capability)).count, homes.count)
        XCTAssertTrue(Set(homes.map(\.capability)).isDisjoint(with: gone.keys))
        var lost: [String] = []
        var sources: [String: String] = [:]
        for home in homes {
            if sources[home.file] == nil {
                sources[home.file] = SourceScan.codeLines(of: try SourceTree.read(home.file))
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }
            if !(sources[home.file] ?? "").contains(home.token) {
                lost.append("\(home.capability): \(home.file) lacks \(home.token)")
            }
        }
        XCTAssertEqual(lost, [], "a review-mode capability lost its home:\n" + lost.joined(separator: "\n"))
    }

    // MARK: - The receiver, in a real window (carried M5)

    /// **The key window's receiver starts and resumes**, and a window that is
    /// not key does neither. The post is read synchronously: Start's state
    /// lands in the same turn (`ReadThroughStore.begin`), and each Start that
    /// runs says its one notice — so one notice is one receiver (fix round M5).
    func test_theKeyWindowsReceiverStartsAndResumes() async throws {
        let (store, ds) = try await novel()
        let item = try XCTUnwrap(store.manifest.structure.first { $0.type == .document })
        let docId = item.id
        // No project behind the document store: Start lands its state, then
        // says no checkpoint was saved — no capture task outlives the test.
        ds.projectStore = nil
        final class Heard { var notices: [String] = [] }
        let heard = Heard()
        let projectId = ProjectIdentifier.id(for: ds.projectURL)
        let token = MaughamEvent.observe(
            .maughamDocumentNotice,
            context: { EventReceiverContext(kind: .project(id: projectId), isWindowLive: true, isWindowKey: false) },
            handler: { note in
                if let message = note.userInfo?[MaughamEvent.noticeMessageKey] as? String {
                    heard.notices.append(message)
                }
            })
        defer { NotificationCenter.default.removeObserver(token) }
        let readThrough = ReadThroughStore(projectRoot: store.url,
                                           device: DeviceSlug.make(from: "surface-test"))
        let treeState = BinderTreeSectionsState()
        let key = mountReceiver(readThrough: readThrough, store: store, item: item,
                                documentStore: ds, treeState: treeState)
        let other = mountReceiver(readThrough: readThrough, store: store, item: item,
                                  documentStore: ds, treeState: BinderTreeSectionsState())
        other.reportsKey = false
        pump(0.2)

        ReadThrough.post(.init(docId: docId, on: true))
        XCTAssertEqual(readThrough.pieceIds, [docId], "the key window started it")
        XCTAssertEqual(heard.notices.count, 1, "one Start ran, not two: \(heard.notices)")
        XCTAssertEqual(heard.notices.first, ReadThroughVerbs.unsavedCheckpointNotice(
            why: "the project isn’t open.", offersSaveOne: false))
        pump(0.2)
        XCTAssertEqual(treeState.readThrough, [docId], "the tree's lock follows the store")

        ReadThrough.post(.init(docId: docId, on: false))
        XCTAssertEqual(readThrough.pieceIds, [], "Resume")

        key.reportsKey = false
        ReadThrough.post(.init(docId: docId, on: true))
        XCTAssertEqual(readThrough.pieceIds, [], "no key window: nothing acts")
        XCTAssertEqual(heard.notices.count, 1)
    }

    // MARK: - The line, mounted

    /// **Three widths**: the whole line, the lead, the lead cut short — and
    /// the Resume writing button whole at the trailing edge in each.
    func test_theLineShortensAndTheButtonStays() throws {
        let offer = ReadThroughOffer.on(docId: "Chapter-1", lacksCheckpoint: false, mayTakeCheckpoint: true)
        let callout = NSFont.preferredFont(forTextStyle: .callout)
        func width(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: callout]).width
        }
        let full = width(ReadThroughLine.fullText(lacksCheckpoint: false))
        let lead = width(ReadThroughLine.lead)
        let button = width(ReadThroughLine.resumeTitle)
        let chrome: CGFloat = 16 + 8 + 16

        let wide = chrome + full + button + 60
        let medium = chrome + lead + button + (full - lead) / 2
        let narrow = chrome + button + lead / 2
        var textEnds: [CGFloat] = []
        for w in [wide, medium, narrow] {
            let window = TestWindow.mount(ReadThroughLine(offer: offer).frame(width: w),
                                          size: CGSize(width: w, height: 40))
            windows.append(window)
            pump(0.2)
            let ink = try Ink(window)
            let runs = ink.runs(in: CGRect(x: 0, y: 0, width: w, height: 40))
            let last = try XCTUnwrap(runs.last, "width \(w): the line drew nothing")
            XCTAssertEqual(last.upperBound, w - 16, accuracy: 4,
                           "width \(w): the button ends at the trailing padding")
            let buttonStart = w - 16 - button
            let first = try XCTUnwrap(runs.first)
            XCTAssertEqual(first.lowerBound, 16, accuracy: 3, "width \(w): the words start at the padding")
            let text = runs.filter { $0.upperBound < buttonStart - 3 }
            textEnds.append(try XCTUnwrap(text.last, "width \(w): no words drawn").upperBound)
        }
        XCTAssertEqual(textEnds[0], 16 + full, accuracy: 4, "wide: the whole line")
        XCTAssertEqual(textEnds[1], 16 + lead, accuracy: 4, "medium: the lead alone")
        XCTAssertLessThan(textEnds[2], 16 + lead - 4, "narrow: the lead cut short, the button whole")
    }

    /// **Over the editor the line takes its own height only, and the text
    /// starts right under it** — the defect a `.frame(maxHeight: .infinity)`
    /// on a several-view builder would cause.
    func test_theLineSitsOverTheEditorAtItsOwnHeight() async throws {
        let fixture = try await StatementMountFixture.novel(named: "Line")
        addTeardownBlock { await fixture.closeAndTearDown() }
        let control = EditorControl()
        let window = await fixture.hostTheManuscriptEditor(control: control)
        let content = try XCTUnwrap(window.contentView)
        /// The editor's scroll view: its top in the content's own sense, and its height.
        func editor() throws -> (top: CGFloat, height: CGFloat) {
            let scroll = try XCTUnwrap(fixture.firstTextView(in: window)?.enclosingScrollView)
            let rect = scroll.convert(scroll.bounds, to: content)
            return (content.isFlipped ? rect.minY : content.bounds.height - rect.maxY, rect.height)
        }
        let writing = try editor()

        control.readThroughDocIds = [fixture.documentItemId]
        pump(0.3)
        let reading = try editor()
        let own = NSHostingView(rootView: ReadThroughLine(
            offer: .on(docId: fixture.documentItemId, lacksCheckpoint: false, mayTakeCheckpoint: true))).fittingSize.height
        XCTAssertGreaterThan(own, 10)
        XCTAssertLessThan(own, 60, "one line of callout text and its padding")
        XCTAssertEqual(reading.top - writing.top, own, accuracy: 1.5,
                       "the editor starts right under the line, which takes its own height only")
        XCTAssertEqual(writing.height - reading.height, own, accuracy: 1.5,
                       "the editor gives up the line's height alone")
    }

    // MARK: - The mark, on each tree host

    /// **A chapter in read-through carries the lock** in the novel's tree:
    /// right of its title, left of the presence dot, and nothing else moves.
    func test_theBinderRowCarriesTheLockBetweenTitleAndPresence() async throws {
        let (store, _) = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first { $0.type == .document })
        let state = BinderTreeSectionsState()
        let window = try await mountTree(AnyView(SurfaceBinderProbe(store: store, treeState: state)))
        try assertTheLock(on: chapter.id, in: window, state: state)
    }

    /// The same on a Collection's piece row (`PieceRow`).
    func test_theCollectionsPieceRowCarriesTheLock() async throws {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await furnish(try await ProjectStore.load(from: url))
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let state = BinderTreeSectionsState()
        let window = try await mountTree(AnyView(SurfaceCollectionProbe(store: store, treeState: state)))
        try assertTheLock(on: piece.id, in: window, state: state)
    }

    /// And on a screenplay's one script row in Scenes.
    func test_theScreenplaysScriptRowCarriesTheLock() async throws {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Script-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await furnish(try await ProjectStore.load(from: url))
        let script = try XCTUnwrap(TreeHostFixture.sceneDocumentID(in: store))
        let state = BinderTreeSectionsState()
        let window = try await mountTree(AnyView(SurfaceScenesProbe(store: store, treeState: state)))
        try assertTheLock(on: script, in: window, state: state)
    }

    /// No roll-up: a Part whose chapter is in read-through draws nothing new.
    func test_aPartDrawsNoRollUp() async throws {
        let (store, _) = try await novel()
        let part = try await store.addStructureItem(parentId: nil, title: "Part One", kind: .group)
        let chapter = try XCTUnwrap(store.manifest.structure.first { $0.type == .document })
        try await store.moveStructureItem(id: chapter.id, toParentId: part.id, atIndex: 0)
        let state = BinderTreeSectionsState()
        let window = try await mountTree(AnyView(SurfaceBinderProbe(store: store, treeState: state)))
        let before = try Ink(window).runs(in: try rowBand(drawing: .item(part.id), in: window))
        state.readThrough = [chapter.id]
        pump(0.3)
        let after = try Ink(window).runs(in: try rowBand(drawing: .item(part.id), in: window))
        XCTAssertEqual(after, before, "the Part's row is untouched")
    }

    /// **A chapter inside an expanded Part carries its own lock** (fix round
    /// M5), between its title and its presence dot.
    func test_aChapterInsideAnOpenPartCarriesTheLock() async throws {
        let (store, _) = try await novel()
        let part = try await store.addStructureItem(parentId: nil, title: "Part One", kind: .group)
        let chapter = try XCTUnwrap(store.manifest.structure.first { $0.type == .document })
        try await store.moveStructureItem(id: chapter.id, toParentId: part.id, atIndex: 0)
        let state = BinderTreeSectionsState()
        state.expandedStructureGroups.insert(part.id)
        let window = try await mountTree(AnyView(SurfaceBinderProbe(store: store, treeState: state)))
        try assertTheLock(on: chapter.id, in: window, state: state)
    }

    // MARK: - The lines over the centre, stacked (fix round M7)

    /// **Every line the window can stand over the text with read-through's**
    /// — the intent strip, the posture's standing line, the view-only notice,
    /// stood as `ProjectWindow.contentColumn` stands them (`CentreTopLines`)
    /// over the real `EditorHost` — moves the editor down by at least its own
    /// height and by no more than a gap: no two lines overlap, and the text
    /// starts right under the last.
    func test_theLinesOverTheCentreStackWithoutOverlap() async throws {
        let fixture = try await StatementMountFixture.novel(named: "Stack")
        addTeardownBlock { await fixture.closeAndTearDown() }
        let control = EditorControl()
        let lines = CentreLinesProbe()
        let window = await fixture.hostTheManuscriptEditor(control: control, lines: lines)
        let content = try XCTUnwrap(window.contentView)
        func editorTop() throws -> CGFloat {
            let scroll = try XCTUnwrap(fixture.firstTextView(in: window)?.enclosingScrollView)
            let rect = scroll.convert(scroll.bounds, to: content)
            return content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
        }
        func own(_ view: some View) -> CGFloat {
            NSHostingView(rootView: view.frame(width: 700)).fittingSize.height
        }
        let standing = PostureStandingLine.Line(kind: .reviewer, docId: fixture.documentItemId)
        let steps: [(name: String, height: CGFloat, add: () -> Void)] = [
            ("read-through's line",
             own(ReadThroughLine(offer: .on(docId: fixture.documentItemId, lacksCheckpoint: false,
                                            mayTakeCheckpoint: true))),
             { control.readThroughDocIds = [fixture.documentItemId] }),
            ("the intent strip",
             own(IntentStrip(line: "A book about tides.", mayTrailDraft: false)),
             { lines.intentLine = "A book about tides." }),
            ("the posture's standing line",
             own(PostureStandingLineView(line: standing, documentStore: fixture.documentStore)),
             { lines.standingLine = standing }),
            ("the view-only notice", own(ViewOnlyShareNotice()), { lines.shareIsReadOnly = true }),
        ]
        var top = try editorTop()
        for step in steps {
            step.add()
            pump(0.3)
            let next = try editorTop()
            XCTAssertGreaterThan(step.height, 8, "premise: \(step.name) draws")
            XCTAssertGreaterThanOrEqual(next - top, step.height - 1,
                                        "\(step.name) overlaps what stands under it")
            XCTAssertLessThanOrEqual(next - top, step.height + 12,
                                     "\(step.name) takes more than its own height")
            top = next
        }
    }

    // MARK: - Helpers

    private func assertTheLock(on id: String, in window: NSWindow, state: BinderTreeSectionsState,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        state.presence = ResolvePresence.Marks(pieces: [id], book: false, scenes: [])
        pump(0.3)
        let band = try rowBand(drawing: .item(id), in: window)
        let before = try Ink(window).runs(in: band)
        state.readThrough = [id]
        pump(0.3)
        let after = try Ink(window).runs(in: try rowBand(drawing: .item(id), in: window))

        let dot = try XCTUnwrap(before.last, "the row drew nothing", file: file, line: line)
        XCTAssertEqual(after.last, dot, "the presence dot keeps the trailing edge", file: file, line: line)
        let title = Array(before.dropLast())
        XCTAssertEqual(Array(after.prefix(title.count)), title, "no title moves", file: file, line: line)
        let added = after.dropFirst(title.count).dropLast()
        XCTAssertFalse(added.isEmpty, "the lock is drawn", file: file, line: line)
        let mark = try XCTUnwrap(added.first).lowerBound...(try XCTUnwrap(added.last).upperBound)
        XCTAssertGreaterThan(mark.lowerBound, try XCTUnwrap(title.last).upperBound,
                             "the lock is right of the title", file: file, line: line)
        XCTAssertLessThan(mark.upperBound, dot.lowerBound, "and left of the presence dot",
                          file: file, line: line)
        XCTAssertLessThan(mark.upperBound - mark.lowerBound, 14, "a 9 pt glyph", file: file, line: line)

        state.readThrough = []
        pump(0.3)
        XCTAssertEqual(try Ink(window).runs(in: try rowBand(drawing: .item(id), in: window)), before,
                       "Resume takes it away", file: file, line: line)
    }

    private func novel() async throws -> (ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await furnish(try await ProjectStore.load(from: url))
        return (store, try XCTUnwrap(store.documentStore))
    }

    private func furnish(_ store: ProjectStore) async throws -> ProjectStore {
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        ds.projectStore = store
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }

    private func mountTree(_ root: AnyView) async throws -> NSWindow {
        let window = TestWindow.mount(root, size: CGSize(width: 320, height: 600), as: SilentTestWindow.self)
        windows.append(window)
        await pumpUntil(deadline: 5) { Ink.table(in: window) != nil }
        pump(0.4)
        return window
    }

    private func mountReceiver(readThrough: ReadThroughStore, store: ProjectStore, item: StructureItem,
                               documentStore: DocumentStore,
                               treeState: BinderTreeSectionsState) -> KeyTestWindow {
        let window = TestWindow.make(KeyTestWindow.self,
                                     contentRect: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = NSHostingView(rootView: ReceiverProbe(
            readThrough: readThrough, store: store, item: item, documentStore: documentStore,
            window: window, treeState: treeState)
            .environment(BackupCoordinator()))
        windows.append(window)
        return window
    }

    /// The band of the row whose label carries `subject`'s travel mark.
    private func rowBand(drawing subject: BinderSubject, in window: NSWindow) throws -> CGRect {
        let content = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(Ink.table(in: window))
        table.deselectAll(nil)
        let index = try XCTUnwrap((0..<table.numberOfRows).first { row in
            guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return false }
            return Ink.descendants(of: view).contains { ($0 as? TreeTravelTargetView)?.subject == subject }
        }, "no row draws \(subject)")
        let row = try XCTUnwrap(table.rowView(atRow: index, makeIfNecessary: true))
        return row.convert(row.bounds, to: content)
    }
}

// MARK: - Measuring

/// One render of a window, read as runs of drawn columns in a band — the way
/// `TreeTopLevelAlignmentTests` measures a row (a SwiftUI row's text has no
/// frame to read, and no assistive client is attached to this host).
@MainActor
private struct Ink {
    let content: NSView
    let rep: NSBitmapImageRep
    let scale: CGFloat

    init(_ window: NSWindow) throws {
        content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        scale = CGFloat(rep.pixelsWide) / content.bounds.width
    }

    static func table(in window: NSWindow) -> NSTableView? {
        guard let content = window.contentView else { return nil }
        return descendants(of: content).compactMap { $0 as? NSTableView }.first
    }

    static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    /// Runs of drawn columns in `band` (content coordinates), as x ranges in
    /// points; the background is sampled at the band's left edge.
    func runs(in band: CGRect) -> [ClosedRange<CGFloat>] {
        func py(_ y: CGFloat) -> Int {
            Int(((content.isFlipped ? y : content.bounds.height - y) * scale).rounded())
        }
        let a = py(band.minY), b = py(band.maxY)
        let y0 = max(0, min(a, b) + 1), y1 = min(rep.pixelsHigh, max(a, b) - 1)
        guard y1 > y0, let bg = rep.colorAt(x: 2, y: (y0 + y1) / 2)?.usingColorSpace(.deviceRGB)
        else { return [] }
        func differs(_ c: NSColor) -> Bool {
            abs(c.redComponent - bg.redComponent) > 0.06 || abs(c.greenComponent - bg.greenComponent) > 0.06
                || abs(c.blueComponent - bg.blueComponent) > 0.06
                || abs(c.alphaComponent - bg.alphaComponent) > 0.06
        }
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for x in 0...rep.pixelsWide {
            let drawn = x < rep.pixelsWide && (y0..<y1).contains { y in
                rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB).map(differs) ?? false
            }
            if drawn, start == nil { start = x }
            if !drawn, let s = start {
                runs.append(CGFloat(s) / scale...CGFloat(x - 1) / scale)
                start = nil
            }
        }
        return runs
    }
}

// MARK: - Probes

@MainActor
private struct SurfaceBinderProbe: View {
    let store: ProjectStore
    let treeState: BinderTreeSectionsState
    @State private var subject = WindowSubject.book

    var body: some View {
        TreeHostFixture.binder(store: store, subject: $subject, treeState: treeState)
    }
}

@MainActor
private struct SurfaceCollectionProbe: View {
    let store: ProjectStore
    let treeState: BinderTreeSectionsState
    @State private var subject = WindowSubject.book
    @State private var renaming: String?

    var body: some View {
        TreeHostFixture.collection(store: store, subject: $subject,
                                   renamingItemId: $renaming, treeState: treeState)
    }
}

@MainActor
private struct SurfaceScenesProbe: View {
    let store: ProjectStore
    let treeState: BinderTreeSectionsState
    @State private var subject = WindowSubject.book

    var body: some View {
        TreeHostFixture.scenes(store: store,
                               script: FountainTokenizer().parse("INT. KITCHEN - DAY\n\nLarry sits.\n"),
                               subject: $subject, treeState: treeState, onSelect: { _ in })
    }
}

/// `ReadThroughModifier` with the facts the window gathers each pass, read
/// here from the store the probe observes — as `ProjectWindow.body` does.
@MainActor
private struct ReceiverProbe: View {
    let readThrough: ReadThroughStore
    let store: ProjectStore
    let item: StructureItem
    let documentStore: DocumentStore
    let window: NSWindow
    let treeState: BinderTreeSectionsState
    @State private var gate = ReadThroughGate.writing

    var body: some View {
        Color.clear.modifier(ReadThroughModifier(
            readThrough: readThrough, store: store, documentStore: documentStore, window: window,
            facts: ReadThroughModifier.Facts(
                docId: item.id, item: item, posture: .author, shareIsReadOnly: false,
                isReadingTranslation: false, route: .editor(altitude: nil, cover: nil),
                pieces: readThrough.pieceIds, lackingCheckpoint: readThrough.piecesLackingCheckpoint),
            treeState: treeState, figureRows: [], figureWindows: nil, gate: $gate, onSaveFlash: {}))
    }
}
