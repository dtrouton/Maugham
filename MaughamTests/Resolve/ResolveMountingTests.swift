import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

/// **To resolve takes the right column** (shell plan 2 Task 7; the first of
/// its three positions since shell plan 3 Task 9): ⌘1, the three old pane
/// keys, where it is offered, the unread dot, a retired segment's decode, and
/// the censuses that the three panes are gone and that a run has one delivery
/// path. Pure functions and source censuses; nothing is pressed
/// (tripwire 33).
@MainActor
final class ResolveMountingTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        try SourceTree.read(relative)
    }

    /// The shortcut text of the first View-menu item after `item`.
    private func shortcut(after item: String, in app: String) throws -> String {
        let at = try XCTUnwrap(app.range(of: item), "no View-menu item contains \(item)")
        let after = app[at.upperBound...]
        let key = try XCTUnwrap(after.range(of: ".keyboardShortcut("),
                                "the item \(item) carries no shortcut at all")
        return String(after[key.lowerBound...].prefix(60))
    }

    // MARK: - Keys

    func test_commandOneSelectsToResolve() throws {
        let app = try source("Maugham/MaughamApp.swift")
        XCTAssertTrue(try shortcut(after: "MaughamEvent.postPosition(.resolve)", in: app)
                        .hasPrefix(#".keyboardShortcut("1", modifiers: .command)"#),
                      "⌘1 is To resolve's, bound on its View-menu item")
        // A plain position post carries no filter: ⌘1 opens To resolve as it
        // stands.
        XCTAssertNil(ProjectWindow.resolveFilter(
            in: [MaughamEvent.positionKey: RightColumnPosition.resolve.rawValue]))
        XCTAssertEqual(RightColumnPosition.allCases.first, .resolve, "To resolve leads the column")
    }

    func test_eachOldPaneKeyOpensToResolveWithItsFilter() throws {
        let app = try source("Maugham/MaughamApp.swift")
        let expected: [(ResolveKeyFilter, String)] = [(.rounds, "a"), (.checks, "d"), (.mine, "t")]
        for (filter, letter) in expected {
            XCTAssertTrue(
                try shortcut(after: "MaughamEvent.postResolve(.\(filter.rawValue))", in: app)
                    .hasPrefix(#".keyboardShortcut("\#(letter)", modifiers: [.command, .option])"#),
                "⌘⌥\(letter.uppercased()) opens To resolve on \(filter)")
        }
        for gone in ["postSegment(.annotations)", "postSegment(.diagnostics)", "postSegment(.tasks)"] {
            XCTAssertFalse(app.contains(gone), "\(gone) names a deleted pane")
        }
        // The receiver reads the filter the post carries, on the one key.
        for filter in [ResolveKeyFilter.rounds, .checks, .mine, .questions] {
            XCTAssertEqual(ProjectWindow.resolveFilter(in: [
                MaughamEvent.positionKey: RightColumnPosition.resolve.rawValue,
                MaughamEvent.resolveFilterKey: filter.rawValue]), filter)
            XCTAssertEqual(ProjectWindow.position(in: [
                MaughamEvent.positionKey: RightColumnPosition.resolve.rawValue,
                MaughamEvent.resolveFilterKey: filter.rawValue]), .resolve,
                "the same post names the position the filter is for")
        }
        // `postResolve` spells both halves on the one event.
        let post = try SourceTree.declaration(named: "static func postResolve(", under: "Maugham")
        let postFlat = SourceScan.codeLines(of: post).joined(separator: " ")
        for token in ["post(.maughamSetRightColumn, to: .keyWindow,",
                      "positionKey: RightColumnPosition.resolve.rawValue,",
                      "resolveFilterKey: filter.rawValue"] {
            XCTAssertTrue(postFlat.contains(token), "postResolve lost \(token)")
        }
        // The translation round's Open queue opens the round's piece, then
        // asks for Questions (review I3; `ResolveNavigationTests` pins the order).
        let report = try source("Maugham/Views/Publish/TranslationRoundReport.swift")
        XCTAssertTrue(report.contains("MaughamEvent.postResolve(.questions)"))
        // The receiver: the one selection act, then the request.
        let receiver = try SourceTree.declaration(
            named: "onKeyWindowCommand(.maughamSetRightColumn, window: window)", under: "Maugham")
        let select = try XCTUnwrap(receiver.range(of: "ProjectWindow.selectPosition("))
        let request = try XCTUnwrap(receiver.range(of: "resolveRequest = .filter(filter)"))
        XCTAssertLessThan(select.lowerBound, request.lowerBound,
                          "the column is revealed before the filter is asked for")
    }

    // MARK: - Where it is offered

    func test_toResolveIsOfferedWhenTheFacesPieceIsNotOpen() {
        // The canvas in the centre, the faces on a piece no editor holds.
        let canvasOverPiece = WindowSubject(open: .canvas, faces: .item("doc-a"), beside: nil)
        let structure = [StructureItem(id: "doc-a", title: "A", type: .document, path: "a.md")]
        XCTAssertEqual(RightColumnContent.of(
            position: .resolve, subject: canvasOverPiece, translationLanguage: nil,
            structure: structure, projectType: .novel), .resolve,
            "To resolve reads a piece without loading it")
        // …and it is the first segment on every subject: it says itself what
        // it is about.
        for subject in [WindowSubject.book, canvasOverPiece,
                        WindowSubject(open: .item("doc-a"), faces: .item("doc-a"), beside: nil),
                        WindowSubject(open: .canvas, faces: .canvas, beside: nil)] {
            for selected in RightColumnPosition.allCases {
                XCTAssertEqual(RightColumnControl.segments(
                    offersPulledUp: RightColumnContent.offersPulledUp(
                        subject, structure: structure, projectType: .novel),
                    selected: selected).first, .resolve)
            }
        }
        // History and what a piece is pinned to no longer wait for the piece
        // to be open (plan 1's stopgap, closed in shell plan 3): History pulls
        // up for a piece that is not open, and the pins are its fold.
        XCTAssertEqual(RightColumnContent.pulledUp(
            for: .historyOfTheFaces, subject: canvasOverPiece, structure: structure),
            .history(docId: "doc-a"))
        // Translation review alone needs the piece open: it IS the editor's.
        XCTAssertEqual(RightColumnContent.of(
            position: .resolve, subject: canvasOverPiece, translationLanguage: "es",
            structure: structure, projectType: .novel), .resolve)
    }

    // MARK: - The unread dot

    func test_theUnreadDotLandsOnToResolve() throws {
        XCTAssertTrue(RightColumnControl.showsDot(on: .resolve, checksUnread: true, proposalPending: false))
        XCTAssertFalse(RightColumnControl.showsDot(on: .brief, checksUnread: true, proposalPending: false))
        XCTAssertFalse(RightColumnControl.showsDot(on: .pulledUp, checksUnread: true, proposalPending: false))
        XCTAssertTrue(UnreadDot.shows(unreadChecks: 3))
        XCTAssertFalse(UnreadDot.shows(unreadChecks: 0))
        // The picker's dot and the list's clear key on ONE doc id
        // (`ResolvePane.unreadDocId`): the faces' piece at a `.piece` scope,
        // else none — so a dot never stands where nothing can clear it.
        XCTAssertEqual(ResolvePane.unreadDocId(scope: .piece(docId: "doc-a", includesBookLevel: false)), "doc-a")
        for none in [ResolveScope.elsewhere(docId: "ref-1"), .outside, .figure(id: "fig-1"),
                     .pieces(docIds: ["doc-a"], includesBookLevel: true)] {
            XCTAssertNil(ResolvePane.unreadDocId(scope: none), "\(none)")
        }
        let picker = try source("Maugham/Views/RightColumnControl.swift")
        XCTAssertTrue(picker.contains("ResolvePane.unreadDocId(scope: ResolveScope.of("),
                      "the control's dot asks the list's own doc id")
        // The chip: Checks wears it, nothing else does.
        XCTAssertTrue(ResolveFilterBar.wearsUnreadDot(.checks, checksUnread: true))
        XCTAssertFalse(ResolveFilterBar.wearsUnreadDot(.checks, checksUnread: false))
        for other in [ResolveSource.mine, .questions, .others, .pass("line")] {
            XCTAssertFalse(ResolveFilterBar.wearsUnreadDot(other, checksUnread: true))
        }
        // A dot, never a number: the control draws `UnreadDot` over a
        // segment, by `showsDot`, and draws no count anywhere.
        let toggle = try source("Maugham/Views/RightColumnControl.swift")
        XCTAssertTrue(toggle.contains("UnreadDot()"))
        XCTAssertTrue(toggle.contains("Self.showsDot(on: segment, checksUnread: checksUnread,"))
        XCTAssertFalse(toggle.contains("99+"), "no counted badge")
        XCTAssertFalse(toggle.contains("diagnosticsUnreadCount"))
        XCTAssertFalse(toggle.contains("Text(\"\\("), "no number is drawn on the control")
        let bar = try source("Maugham/Views/Resolve/ResolveFilterBar.swift")
        XCTAssertTrue(bar.contains("UnreadDot()"))
        // The clearing rule the Diagnostics pane kept: showing the checks'
        // items reads them — on appear, on a filter change, and when notes
        // land while they are on screen.
        XCTAssertTrue(ResolveFilter.clearsUnreadChecks(selection: []))
        XCTAssertTrue(ResolveFilter.clearsUnreadChecks(selection: [.checks, .mine]))
        XCTAssertFalse(ResolveFilter.clearsUnreadChecks(selection: [.mine]))
        let pane = try source("Maugham/Views/Resolve/ResolvePane.swift")
        XCTAssertTrue(pane.contains(".onChange(of: diagnostics?.version) { _, _ in markChecksRead() }"))
        XCTAssertTrue(pane.contains("let docId = Self.unreadDocId(scope: scope)"),
                      "the clear asks the same doc id the picker's dot does")
    }

    // MARK: - UIState

    func test_aRetiredSegmentDecodesToToResolve() throws {
        for retired in ["annotations", "diagnostics", "tasks", "inbox", "outline", "research", "palette"] {
            let raw = #"{"schemaVersion": 5, "detailSegment": "\#(retired)", "isNoChromeOn": true}"#
            let decoded = try JSONDecoder().decode(UIState.self, from: Data(raw.utf8))
            XCTAssertEqual(decoded.rightColumnPosition, .resolve, "\(retired) opens on To resolve")
            XCTAssertTrue(decoded.isNoChromeOn, "the rest of the file still decodes")
        }
        let missing = try JSONDecoder().decode(UIState.self, from: Data(#"{"schemaVersion": 5}"#.utf8))
        XCTAssertEqual(missing.rightColumnPosition, .resolve)
        // The old key is ignored whatever it holds (shell plan 3 Task 9); the
        // position is what is remembered.
        let kept = try JSONDecoder().decode(
            UIState.self,
            from: Data(#"{"schemaVersion": 5, "detailSegment": "history", "rightColumnPosition": "brief"}"#.utf8))
        XCTAssertEqual(kept.rightColumnPosition, .brief, "the remembered position is kept")
        XCTAssertEqual(UIState().rightColumnPosition, .resolve, "a new window opens on To resolve")
    }

    // MARK: - The callers that used to select a deleted pane

    func test_theBoardsOpenNotesAndAFiguresShowNotesSelectToResolve() throws {
        let centre = try SourceTree.sourceOfType("CentreColumn", under: ["Maugham"])
        XCTAssertTrue(centre.contains("position = .resolve"))
        XCTAssertTrue(centre.contains("resolveRequest = .focus(groupOwnerId: pieceId)"))
        let right = try SourceTree.sourceOfType("RightColumn", under: ["Maugham"])
        XCTAssertTrue(right.contains("onShowNotes: { _ in position = .resolve }"),
                      "a figure's Show notes selects To resolve")
        XCTAssertTrue(right.contains("script: lastParsedScript"),
                      "the window's parse reaches the list for scene grouping")
        for wired in ["onTravel:", "drawsFigure: drawsFigure", "revealFigure: revealFigure",
                      "revealFigureCell:", "request: $resolveRequest",
                      "onOpenBrief: openBrief"] {
            XCTAssertTrue(right.contains(wired), "the mount passes \(wired)")
        }
    }

    // MARK: - A row's click (re-made from `AnnotationScopeTests`)

    /// A row of the piece already centred jumps; any other piece travels; a
    /// figure travels to the figure only where the tree draws it, else stays.
    func test_aRowOfThePieceAlreadyCentredJumpsAndAnyOtherTravels() {
        let never: (String) -> Bool = { _ in false }
        XCTAssertEqual(FigureNoteClick.click(rowDocId: "doc-a", activeDocId: "doc-a", drawsFigure: never), .jump)
        XCTAssertEqual(FigureNoteClick.click(rowDocId: "doc-b", activeDocId: "doc-a", drawsFigure: never),
                       .travel(.item("doc-b")))
        XCTAssertEqual(FigureNoteClick.click(rowDocId: "doc-b", activeDocId: nil, drawsFigure: never),
                       .travel(.item("doc-b")))
    }

    func test_aNoteOnAFigureTheTreeDoesNotDrawStays() {
        let figure = "fig-aaaa1111"
        XCTAssertEqual(FigureNoteClick.click(rowDocId: figure, activeDocId: "doc-a", drawsFigure: { _ in false }),
                       .stay, "a parked figure: nothing moves")
        XCTAssertEqual(FigureNoteClick.click(rowDocId: figure, activeDocId: figure, drawsFigure: { _ in false }),
                       .stay, "never a jump: no editor shows a figure's paragraphs")
        XCTAssertEqual(FigureNoteClick.click(rowDocId: figure, activeDocId: "doc-a", drawsFigure: { $0 == figure }),
                       .travel(.figure(figure)))
    }

    /// **The mount's travel writes the window's subject and nothing else**
    /// (`ManuscriptNavigation`'s ruling) — a figure note's travel. A paragraph
    /// row's click in a Book or Part list keeps the list by opening the piece
    /// inside the faces (`ClickRule.openInsideTheFaces`, review I1).
    func test_theMountsTravelClosureWritesTheSubjectAndNothingElse() throws {
        let mount = try SourceTree.declaration(named: "private var resolvePane: some View {", under: "Maugham")
        let start = try XCTUnwrap(mount.range(of: "onTravel: { subject in"))
        let end = try XCTUnwrap(mount.range(of: "drawsFigure: drawsFigure", range: start.upperBound..<mount.endIndex))
        let closure = SourceScan.codeLines(of: String(mount[start.upperBound..<end.lowerBound]))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        XCTAssertEqual(closure, ["selectedSubject = subject", "},"],
                       "the travel is a subject write and nothing else")
    }

    // MARK: - Settled's archived to-dos (controller ruling)

    func test_anArchivedTodoOffersUnarchiveOnlyWhereItCanRestoreIt() {
        func task(_ kind: TaskKind, _ status: TaskStatus) -> WriterTask {
            WriterTask(id: "t", kind: kind, anchor: TaskAnchor(docId: "doc-a", paragraphId: nil),
                       body: "b", status: status, priority: 0, parentTaskId: nil,
                       createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil)
        }
        let all = TaskRowVerbs.unrestricted
        let none = TaskRowVerbs(toggle: false, archive: false, delete: false, move: false)
        XCTAssertTrue(ResolveTaskVerbs.offersUnarchive(task(.paneCreated, .archived), verbs: all))
        XCTAssertFalse(ResolveTaskVerbs.offersUnarchive(task(.paneCreated, .archived), verbs: none),
                       "hidden where the posture refuses a status change")
        XCTAssertFalse(ResolveTaskVerbs.offersUnarchive(task(.inlineMarkdown, .archived), verbs: all),
                       "an inline to-do's words are gone from the text: a status change cannot restore them")
        XCTAssertFalse(ResolveTaskVerbs.offersUnarchive(task(.paneCreated, .done), verbs: all),
                       "only an archived to-do unarchives")
    }

    // MARK: - Censuses

    private static let deletedNames = #"\b(AnnotationsPane|TasksPane|DiagnosticsPane|AnnotationScope|closedPieceReason)\b"#

    /// Every line under `root` naming a deleted pane type.
    private static func offenders(under root: URL) throws -> [String] {
        let regex = try NSRegularExpression(pattern: deletedNames)
        var found: [String] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard ["swift", "md"].contains(url.pathExtension),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    found.append("\(url.lastPathComponent):\(n + 1): \(line)")
                }
            }
        }
        return found
    }

    func test_noDeletedPaneTypeSurvives() throws {
        let maugham = SourceTree.repoRoot.appendingPathComponent("Maugham", isDirectory: true)
        let found = try Self.offenders(under: maugham)
        XCTAssertEqual(found, [], "a deleted pane type is still named under Maugham/")
    }

    func test_theDeletedPaneCensusFiresOnAPlantedOffender() throws {
        let root = TestTemp.root.appendingPathComponent("census", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "struct Fine { let scope: ResolveScope }\n// CheckNarrative, DiagnosticsPaneHeader\n"
            .write(to: root.appendingPathComponent("Fine.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.offenders(under: root), [],
                       "a name that merely starts with a deleted one is not an offender")
        try "/// the queue (`AnnotationsPane.jump`)\n"
            .write(to: root.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.offenders(under: root).count, 1)
    }

    /// The files under `Maugham/Views/` allowed to call `runRequested(`:
    /// the command's receiver, and the window's deferred delivery of a board
    /// chip's round (`runRoundWhenPieceOpens`).
    private static let runRequestedCallers: [String: Int] = [
        "CompilerRunModifier.swift": 1,
        "ProjectWindow.swift": 1,
    ]

    private static func runRequestedCalls(under root: URL) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let masked = String(decoding: SourceTree.mask(text), as: UTF8.self)
            let n = masked.components(separatedBy: "runRequested(").count - 1
            if n > 0 { counts[url.lastPathComponent, default: 0] += n }
        }
        return counts
    }

    /// **One delivery path for a run** (shell plan 2 Task 7): a view asks for
    /// a run through the `MaughamEvent` command (`postRun`), whose receiver
    /// reads the window's open piece — never the orchestrator directly.
    func test_noViewCallsRunRequestedDirectly() throws {
        let views = SourceTree.repoRoot.appendingPathComponent("Maugham/Views", isDirectory: true)
        XCTAssertEqual(try Self.runRequestedCalls(under: views), Self.runRequestedCallers)
        let offer = try SourceTree.sourceOfType("DiagnosticsColdStartOffer", under: ["Maugham"])
        XCTAssertTrue(offer.contains("MaughamEvent.postRun(.checkWriting)"),
                      "the cold-start offer's Read asks the way ⌘R asks")
    }

    func test_theRunRequestedCensusFiresOnAPlantedOffender() throws {
        let root = TestTemp.root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// orchestrator.runRequested(docId: id, kind: .check) in a comment\nlet s = \"runRequested(\"\n"
            .write(to: root.appendingPathComponent("Quiet.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.runRequestedCalls(under: root), [:],
                       "a comment or a string is not a call")
        try "Button(\"Read\") { orchestrator.runRequested(docId: id, kind: .check) }\n"
            .write(to: root.appendingPathComponent("Offer.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.runRequestedCalls(under: root), ["Offer.swift": 1])
    }
}
