import XCTest
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **Brief's appraisal wave** (2026-11-20 appraisal items 6, 7, 10, 11, 12
/// and the empty fold): History is findable, a piece's details are visible,
/// Brief says what its dot means, Going for grows, Decided exists before
/// anything is filed, and an empty fold says how to fill it. Pure decisions
/// and source censuses only; nothing is mounted or pressed (tripwire 33).
@MainActor
final class BriefAppraisalTests: XCTestCase {

    private let structure: [StructureItem] = [
        StructureItem(id: "part-1", title: "Part One", type: .group, children: [
            StructureItem(id: "ch-1", title: "One", type: .document, path: "manuscript/one.md"),
        ]),
        StructureItem(id: "ch-2", title: "Two", type: .document, path: "manuscript/two.md"),
    ]

    private func ws(_ open: BinderSubject, _ faces: BinderSubject? = nil) -> WindowSubject {
        WindowSubject(open: open, faces: faces ?? open, beside: nil)
    }

    // MARK: - 6. History

    /// A tree row's History is of THAT row's piece, not the faces'; a name
    /// that is not a piece falls back to the key's own rule.
    func test_aRowsHistoryIsOfThatRowsPiece() {
        let facesOne = ws(.item("ch-1"))
        XCTAssertEqual(RightColumnContent.pulledUp(for: .historyOfTheFaces, subject: facesOne,
                                                   structure: structure, piece: "ch-2"),
                       .history(docId: "ch-2"))
        XCTAssertEqual(RightColumnContent.pulledUp(for: .historyOfTheFaces, subject: facesOne,
                                                   structure: structure),
                       .history(docId: "ch-1"), "premise: the key's History is the faces'")
        XCTAssertEqual(RightColumnContent.pulledUp(for: .historyOfTheFaces, subject: facesOne,
                                                   structure: structure, piece: "part-1"),
                       .history(docId: "ch-1"), "a Part has no History of its own")
        XCTAssertEqual(RightColumnContent.pulledUp(for: .lessons, subject: facesOne,
                                                   structure: structure, piece: "ch-2"),
                       .lessons, "a piece names only a History")

        // The post and the receiver spell the payload the same way.
        let userInfo: [AnyHashable: Any] = [
            MaughamEvent.pullUpKey: PullUpRequest.historyOfTheFaces.rawValue,
            MaughamEvent.pullUpPieceKey: "ch-2",
        ]
        XCTAssertEqual(ProjectWindow.pullUpRequest(in: userInfo), .historyOfTheFaces)
        XCTAssertEqual(ProjectWindow.pullUpPiece(in: userInfo), "ch-2")
        XCTAssertNil(ProjectWindow.pullUpPiece(in: [MaughamEvent.pullUpKey: "lessons"]))

        // Through the one pull-up act, on the column.
        var subject = facesOne
        var shown = false
        var position = RightColumnPosition.brief
        ProjectWindow.pullUp(
            .historyOfTheFaces,
            subject: Binding(get: { subject }, set: { subject = $0 }),
            showInspector: Binding(get: { shown }, set: { shown = $0 }),
            position: Binding(get: { position }, set: { position = $0 }),
            structure: structure, piece: ProjectWindow.pullUpPiece(in: userInfo))
        XCTAssertEqual(subject.beside, .history(docId: "ch-2"))
        XCTAssertEqual(subject.faces, .item("ch-1"), "the faces stay where they were")
        XCTAssertEqual(position, .pulledUp)
        XCTAssertTrue(shown)
    }

    func test_theRowMenuOffersHistoryOnEveryPieceWithOne() throws {
        XCTAssertTrue(PieceRowMenus.offersHistory(for: structure[1]))
        XCTAssertFalse(PieceRowMenus.offersHistory(for: structure[0]), "a group has none")
        var reference = StructureItem(id: "rf01", title: "R", type: .document, path: "r.md")
        reference.pieceKind = .reference
        XCTAssertFalse(PieceRowMenus.offersHistory(for: reference), "another project's piece")
        XCTAssertEqual(PieceRowMenus.historyTitle, "History")

        // The menu posts the row's own piece by the keys' event.
        let menus = try SourceTree.read("Maugham/Views/PieceRowMenus.swift")
        XCTAssertTrue(menus.contains("MaughamEvent.postPullUpHistory(ofPiece: item.id)"))
        let event = try SourceTree.read("Maugham/Events/MaughamEvent.swift")
        XCTAssertTrue(event.contains("post(.maughamPullUp, to: .keyWindow,\n             payload: [pullUpKey: PullUpRequest.historyOfTheFaces.rawValue,\n                       pullUpPieceKey: docId])"))
        let window = try SourceTree.read("Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains("piece: ProjectWindow.pullUpPiece(in: note.userInfo))"),
                      "the receiver hands the named piece to the one pull-up act")
    }

    func test_briefFootsCarryHistory() throws {
        let piece = try SourceTree.read("Maugham/Views/Brief/BriefPieceView.swift")
        XCTAssertTrue(piece.contains("BriefHistoryLink(item: .history(docId: docId), onPullUp: onPullUp)"))
        let book = try SourceTree.read("Maugham/Views/Brief/BriefBookView.swift")
        XCTAssertTrue(book.contains("BriefHistoryLink(item: .projectHistory, onPullUp: onPullUp)"))
        let column = try SourceTree.read("Maugham/Views/RightColumn.swift")
        XCTAssertTrue(column.contains("onPullUp: pullUp,"), "Brief's pull-up act is the window's")
    }

    // MARK: - 7. Details

    private func chapter(tags: [String]? = nil, links: [String]? = nil,
                         wordTarget: Int? = nil) -> StructureItem {
        var item = StructureItem(id: "ch-2", title: "Two", type: .document, path: "manuscript/two.md")
        item.tags = tags
        item.links = links
        item.wordTarget = wordTarget
        return item
    }

    func test_detailsShowValuesAndOfferWhatTheRowMenuOffers() {
        let all: [PieceRowMenus.Item] = [.tags, .addLink, .target, .publishing]
        let set = BriefDetails.lines(piece: chapter(tags: ["Rome", "winter"], links: ["ch-1"],
                                                    wordTarget: 2000),
                                     projectType: .novel, projectPageTarget: nil, offered: all)
        XCTAssertEqual(set.map(\.text), ["Word target: \(2000.formatted())", "Tags: Rome, winter",
                                         "1 link", "Publishing settings"])
        XCTAssertEqual(set.map(\.opens), [.target, .tags, .addLink, .publishing],
                       "each opens the row menu's own sheet")

        // Nothing set: the quiet affordances, so the area is discoverable.
        let empty = BriefDetails.lines(piece: chapter(), projectType: .novel,
                                       projectPageTarget: nil, offered: [.tags, .addLink, .target])
        XCTAssertEqual(empty.map(\.text), ["Set a target", "Add tags"])
        XCTAssertEqual(empty.map(\.opens), [.target, .tags])

        // A posture the row menu offers nothing under: values read, no way in.
        let readOnly = BriefDetails.lines(piece: chapter(tags: ["Rome"], links: ["ch-1", "ch-3"],
                                                         wordTarget: 500),
                                          projectType: .novel, projectPageTarget: nil, offered: [])
        XCTAssertEqual(readOnly.map(\.text), ["Word target: 500", "Tags: Rome", "2 links"])
        XCTAssertEqual(readOnly.map(\.opens), [nil, nil, nil], "hidden, never disabled")
        XCTAssertTrue(BriefDetails.lines(piece: chapter(), projectType: .novel,
                                         projectPageTarget: nil, offered: []).isEmpty,
                      "nothing set and nothing offered: no Details at all")

        // A screenplay's script: the PROJECT's page target, no links.
        let script = StructureItem(id: "script", title: "Script", type: .document, path: "script.fountain")
        let screenplay = BriefDetails.lines(piece: script, projectType: .screenplay,
                                            projectPageTarget: 110, offered: [.tags, .target])
        XCTAssertEqual(screenplay.map(\.text), ["Page target: 110", "Add tags"])
        XCTAssertFalse(BriefDetails.offersLinks(projectType: .screenplay))
        XCTAssertTrue(BriefDetails.offersLinks(projectType: .novel))
        XCTAssertTrue(BriefDetails.offersLinks(projectType: .collection))
    }

    /// The target rule is the status line's, posture aside: `decide` is
    /// `target(of:)` under a posture, never a second spelling.
    func test_theTargetIsTheStatusLinesRule() {
        let piece = chapter(wordTarget: 700)
        XCTAssertEqual(PieceTargetMenu.target(of: piece, projectType: .novel, projectPageTarget: nil),
                       PieceTargetMenu.decide(piece: piece, projectType: .novel, projectPageTarget: nil,
                                              postureOf: { _ in .author }))
        XCTAssertNil(PieceTargetMenu.decide(piece: piece, projectType: .novel, projectPageTarget: nil,
                                            postureOf: { _ in .settling }))
        XCTAssertNotNil(PieceTargetMenu.target(of: piece, projectType: .novel, projectPageTarget: nil))
        var reference = piece
        reference.pieceKind = .reference
        XCTAssertNil(PieceTargetMenu.target(of: reference, projectType: .collection, projectPageTarget: nil))
    }

    /// Details opens the row menu's sheet slot — no sheet of its own, no
    /// write of its own.
    func test_detailsOpenTheRowMenusSheetsAndWriteNothing() throws {
        let code = try SourceTree.read("Maugham/Views/Brief/BriefDetails.swift")
        XCTAssertTrue(code.contains("tree.pieceRowSheet = PieceRowSheet(item, pieceId: docId)"))
        XCTAssertTrue(code.contains("PieceRowMenus.items("), "offered by the row menu's own answer")
        for forbidden in [".sheet(", "updateInspector", "updateProjectTargets"] {
            XCTAssertFalse(code.contains(forbidden), "Details has no \(forbidden)")
        }
    }

    // MARK: - 10. The proposal notice

    func test_theProposalNoticeSaysWhatTheDotMeansInTheBooksWords() throws {
        XCTAssertTrue(BriefPullUpLines.proposedHelp.hasPrefix(
            String(BriefProposalNotice.line.dropLast())), "the Book's own wording")
        XCTAssertTrue(BriefPullUpLines.proposedHelp.lowercased()
            .contains(BriefProposalNotice.linkTitle.lowercased()))
        let sentence = String(BriefProposalNotice.sentence.characters)
        XCTAssertEqual(sentence, "Claude proposed a visual language. Pull it up to adopt or discard.")
        XCTAssertTrue(BriefProposalNotice.sentence.runs.contains { $0.link != nil }, "the link pulls up")

        // One source with the segment's dot, at the top of every Brief.
        let pane = try SourceTree.read("Maugham/Views/Brief/BriefPane.swift")
        XCTAssertTrue(pane.contains("VisualLanguageProposalModifier("))
        XCTAssertTrue(pane.contains("if proposalPending {\n                BriefProposalNotice(onPullUp: onPullUp)"))
        let notice = try SourceTree.read("Maugham/Views/Brief/BriefDetails.swift")
        XCTAssertTrue(notice.contains("onPullUp(.visualLanguage)"))
    }

    // MARK: - 11. Going for grows

    func test_goingForGrowsWithItsTextFromAMinimum() {
        XCTAssertEqual(GoingForView.editorHeight(needed: nil), GoingForView.editorMinHeight,
                       "the minimum until measured")
        XCTAssertEqual(GoingForView.editorHeight(needed: 40), GoingForView.editorMinHeight)
        XCTAssertEqual(GoingForView.editorHeight(needed: 900), 900, "no ceiling: the column scrolls")
        XCTAssertEqual(EditorHeightProbe.neededHeight(usedHeight: 100.2, originY: 24, insetHeight: 24), 149)
        XCTAssertEqual(GoingForView.openInCentreTitle, "Open in Centre")
    }

    /// The probe reads the editor and writes nothing back to it (tripwires
    /// 2, 3, 6, 7): no text, no binding, no host state.
    func test_theHeightProbeOnlyReadsTheEditor() throws {
        let code = try SourceTree.read("Maugham/Views/BriefFocus.swift")
        let probe = String(code[code.range(of: "struct EditorHeightProbe")!.lowerBound...])
        for forbidden in [".string =", "displayText", "applyExternalText", "setAttributes",
                          "replaceCharacters", "textStorage?.", ".insertText"] {
            XCTAssertFalse(probe.contains(forbidden), "the probe never writes: \(forbidden)")
        }
        let goingFor = try SourceTree.read("Maugham/Views/Brief/GoingForView.swift")
        XCTAssertTrue(goingFor.contains(".frame(height: Self.editorHeight(needed: neededHeight))"))
        XCTAssertTrue(goingFor.contains("EditorHeightProbe(onHeight: { neededHeight = $0 })"))
    }

    // MARK: - 12. Decided before anything is filed

    func test_decidedSaysWhereAnswersLandWhileNothingIsFiled() {
        XCTAssertEqual(BriefDecidedSection.emptyLine, "What you answer in To resolve is filed here.")
        XCTAssertTrue(BriefDecidedSection.drawsEmptyLine(decisions: [], isUnreadable: false,
                                                         explainsWhenEmpty: true))
        XCTAssertFalse(BriefDecidedSection.drawsEmptyLine(decisions: [], isUnreadable: false,
                                                          explainsWhenEmpty: false),
                       "a Part's sections never explain themselves")
        XCTAssertFalse(BriefDecidedSection.drawsEmptyLine(decisions: [], isUnreadable: true,
                                                          explainsWhenEmpty: true),
                       "a statement that would not read is never drawn as empty")
        let ruling = Ruling(id: "r1", text: "Keep the tense.", ruledOn: nil, provenance: nil)
        XCTAssertFalse(BriefDecidedSection.drawsEmptyLine(decisions: [ruling], isUnreadable: false,
                                                          explainsWhenEmpty: true))
    }

    // MARK: - The empty fold

    func test_anEmptyFoldSaysHowToAttachMaterial() {
        let built = PieceFoldIndex(entries: ["ch-1": [.link(pieceId: "ch-2", title: "Two", incoming: false)]])
        func hint(_ docId: String, built isBuilt: Bool = true,
                  type: ProjectType = .novel, in structure: [StructureItem]? = nil) -> String? {
            BriefFoldHint.line(docId: docId, index: built, indexIsBuilt: isBuilt,
                               structure: structure ?? self.structure, projectType: type)
        }
        XCTAssertNil(hint("ch-1"), "a fold with something in it says nothing")
        XCTAssertEqual(hint("ch-2"),
                       "Nothing is attached to this chapter yet. Drag a research note onto it in the tree, "
                       + "or set a canvas region\u{2019}s Piece to it to attach the cards inside.")
        XCTAssertNil(hint("ch-2", built: false), "never over an index not yet built")
        XCTAssertNil(hint("part-1"), "a Part has no fold")

        // A short story keeps all research shared: a drag onto the row is
        // refused, so the line says adding research instead.
        XCTAssertEqual(hint("ch-2", type: .shortStory),
                       "Nothing is attached to this chapter yet. Research you add in the tree is attached "
                       + "to it, and so are the cards in a canvas region whose Piece is set to it.")
        // A Collection's loose piece by its noun; a reference piece has no fold.
        var loose = StructureItem(id: "pc01", title: "One", type: .document, path: "pieces/one/one.md")
        loose.pieceKind = .loose
        var reference = loose
        reference.id = "rf01"
        reference.pieceKind = .reference
        XCTAssertEqual(hint("pc01", type: .collection, in: [loose])?.hasPrefix(
            "Nothing is attached to this piece yet. Drag a research note"), true)
        XCTAssertNil(hint("rf01", type: .collection, in: [reference]))

        // The routing the line names is the drop's own: onto a short story's
        // row, a research drag is refused.
        XCTAssertEqual(try? ProjectStore.researchRouting(for: structure[1], projectType: .shortStory),
                       .sharedOnly)
    }

    /// Whether the fold is empty is the tree's index, never recomputed here.
    func test_theHintAsksTheTreesIndex() throws {
        let piece = try SourceTree.read("Maugham/Views/Brief/BriefPieceView.swift")
        XCTAssertTrue(piece.contains("index: tree.foldIndex, indexIsBuilt: tree.foldIndexIsBuilt"))
        let code = try SourceTree.read("Maugham/Views/Brief/BriefDetails.swift")
        XCTAssertFalse(code.contains("PieceFoldIndex.build"))
        let fold = try SourceTree.read("Maugham/Views/BinderPieceFold.swift")
        XCTAssertTrue(fold.contains("state.foldIndex = PieceFoldIndex.build(store: store, projectRoot: store.url)\n                state.foldIndexIsBuilt = true"))
    }
}
