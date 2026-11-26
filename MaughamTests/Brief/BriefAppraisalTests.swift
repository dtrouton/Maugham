import XCTest
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **Brief's appraisal wave** (2026-11-20 appraisal items 6, 7, 10, 11):
/// History is findable, a piece's set details are visible, Brief says what
/// its dot means, Going for grows. Items 12 (Decided explaining itself while
/// empty) and the empty fold's sentence were withdrawn by Denver on
/// 2026-11-21 (Task 6a: teaching belongs at the moment of action). Pure
/// decisions and source censuses only; nothing is mounted or pressed
/// (tripwire 33).
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
            structure: structure, piece: ProjectWindow.pullUpPiece(in: userInfo), memory: nil)
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
        XCTAssertTrue(window.contains("piece: ProjectWindow.pullUpPiece(in: note.userInfo),"),
                      "the receiver hands the named piece to the one pull-up act")
    }

    func test_briefFootsCarryHistory() throws {
        let piece = try SourceTree.read("Maugham/Views/Brief/BriefPieceView.swift")
        XCTAssertTrue(piece.contains("BriefFoot.line(docId: docId, store: store, tree: tree)"))
        XCTAssertTrue(piece.contains("onPullUp: onPullUp, offered: line.offered, noun: line.noun)"))
        let foot = try SourceTree.read("Maugham/Views/Brief/BriefDetails.swift")
        XCTAssertTrue(foot.contains("offered: offered, history: .history(docId: docId))"),
                      "a piece's foot ends with that piece's History")
        XCTAssertTrue(foot.contains("Button { onPullUp(item) } label: {"))
        let book = try SourceTree.read("Maugham/Views/Brief/BriefBookView.swift")
        XCTAssertTrue(book.contains("BriefFootView(parts: [.history(.projectHistory)], openSheet: nil, onPullUp: onPullUp)"))
        let column = try SourceTree.read("Maugham/Views/RightColumn.swift")
        XCTAssertTrue(column.contains("onPullUp: pullUp,"), "Brief's pull-up act is the window's")
    }

    // MARK: - 7. Details, now the foot (Task 6a)

    private func chapter(tags: [String]? = nil, links: [String]? = nil,
                         wordTarget: Int? = nil) -> StructureItem {
        var item = StructureItem(id: "ch-2", title: "Two", type: .document, path: "manuscript/two.md")
        item.tags = tags
        item.links = links
        item.wordTarget = wordTarget
        return item
    }

    private func foot(_ piece: StructureItem, type: ProjectType = .novel, pageTarget: Int? = nil,
                      offered: [PieceRowMenus.Item],
                      history: PulledUp? = .history(docId: "ch-2")) -> [BriefFoot.Part] {
        BriefFoot.parts(target: PieceTargetMenu.target(of: piece, projectType: type,
                                                       projectPageTarget: pageTarget),
                        tags: piece.tags ?? [], links: (piece.links ?? []).count,
                        offered: offered, history: history)
    }

    /// **The foot, as a table** (Denver, 2026-11-21): set values, then
    /// History; "Details" alone when nothing is set; no how-to words.
    func test_theFootIsTheSetValuesThenHistory() {
        let all: [PieceRowMenus.Item] = [.tags, .addLink, .target, .publishing]
        let details = BriefFoot.Part.details(offers: all)
        let history = BriefFoot.Part.history(.history(docId: "ch-2"))
        let words = "\(3000.formatted()) words"
        let target = BriefFoot.Part.value(.target, text: words, short: nil,
                                          spoken: "Word target: \(words)", opens: .target)
        let tags = BriefFoot.Part.value(.tags, text: "rome, draft", short: "2 tags",
                                        spoken: "Tags: rome, draft", opens: .tags)

        // Nothing set: "Details", a menu of what the row menu offers, then History.
        XCTAssertEqual(foot(chapter(), offered: all), [details, history])

        // Target only; tags only: the value, and Details is still the door
        // to every other sheet (the follow-up: one visible door always).
        XCTAssertEqual(foot(chapter(wordTarget: 3000), offered: all), [target, details, history])
        XCTAssertEqual(foot(chapter(tags: ["rome", "draft"]), offered: all), [tags, details, history])

        // Both, and links: in that order, then Details, then History. The
        // menu lists every sheet the row menu offers, none marked out.
        XCTAssertEqual(foot(chapter(tags: ["rome", "draft"], links: ["ch-1"], wordTarget: 3000),
                            offered: all), [
            target, tags,
            .value(.links, text: "1 link", short: nil, spoken: "1 link", opens: .addLink),
            details, history])

        // Details offers exactly what the row menu offers (posture).
        XCTAssertEqual(foot(chapter(wordTarget: 3000), offered: [.target]),
                       [target, .details(offers: [.target]), history])

        // A reviewer's posture (the row menu offers nothing): values read as
        // text, no doors, no Details menu — hidden, never disabled.
        XCTAssertEqual(foot(chapter(tags: ["rome"], links: ["ch-1", "ch-3"], wordTarget: 500),
                            offered: []), [
            .value(.target, text: "500 words", short: nil, spoken: "Word target: 500 words", opens: nil),
            .value(.tags, text: "rome", short: "1 tag", spoken: "Tags: rome", opens: nil),
            .value(.links, text: "2 links", short: nil, spoken: "2 links", opens: nil),
            history])
        XCTAssertEqual(foot(chapter(), offered: []), [history], "nothing set, nothing offered: History alone")

        // A screenplay's script: the PROJECT's page target.
        let script = StructureItem(id: "script", title: "Script", type: .document, path: "script.fountain")
        XCTAssertEqual(foot(script, type: .screenplay, pageTarget: 1, offered: [.tags, .target]).first,
                       .value(.target, text: "1 page", short: nil, spoken: "Page target: 1 page", opens: .target))
        XCTAssertFalse(BriefFoot.offersLinks(projectType: .screenplay))
        XCTAssertTrue(BriefFoot.offersLinks(projectType: .novel))
        XCTAssertTrue(BriefFoot.offersLinks(projectType: .collection))

        // The Book: History alone (its Brief showed no details before the
        // foot); a Part draws no foot (it had no History or details).
        XCTAssertEqual(BriefFoot.parts(target: nil, tags: [], links: 0, offered: [],
                                       history: .projectHistory),
                       [.history(.projectHistory)])
        XCTAssertEqual(BriefFoot.parts(target: nil, tags: [], links: 0, offered: [], history: nil), [])
    }

    /// **The tags give way, and nothing else does**: whole, capped twice
    /// (truncating in the middle), then their count; the order is widest
    /// first, so `ViewThatFits` takes the first that fits.
    func test_theTagsGiveWayInSteps() {
        XCTAssertEqual(BriefFoot.Fit.allCases,
                       [.whole, .shortened, .shorter, .counted, .withoutLinks, .targetOnly])
        XCTAssertEqual(BriefFoot.Fit.allCases.map(\.tagsMaxWidth), [nil, 140, 72, nil, nil, nil])
        XCTAssertEqual(BriefFoot.Fit.whole.tagsText("rome, draft", short: "2 tags"), "rome, draft")
        XCTAssertEqual(BriefFoot.Fit.shorter.tagsText("rome, draft", short: "2 tags"), "rome, draft")
        XCTAssertEqual(BriefFoot.Fit.counted.tagsText("rome, draft", short: "2 tags"), "2 tags")

        // What each step draws: the doors (Details, History) always; the
        // target always; the links, then the tags, leave only at the end.
        let parts = BriefFoot.parts(
            target: PieceTargetMenu.target(of: chapter(wordTarget: 3000), projectType: .novel,
                                           projectPageTarget: nil),
            tags: ["rome", "draft"], links: 2, offered: [.tags, .addLink, .target],
            history: .history(docId: "ch-2"))
        func kinds(_ fit: BriefFoot.Fit) -> [String] {
            fit.shown(parts).map { part in
                switch part {
                case .value(let value, _, _, _, _): return "\(value)"
                case .details: return "details"
                case .history: return "history"
                }
            }
        }
        for fit in [BriefFoot.Fit.whole, .shortened, .shorter, .counted] {
            XCTAssertEqual(kinds(fit), ["target", "tags", "links", "details", "history"], "\(fit)")
        }
        XCTAssertEqual(kinds(.withoutLinks), ["target", "tags", "details", "history"])
        XCTAssertEqual(kinds(.targetOnly), ["target", "details", "history"])
    }

    /// **Every door on the foot is a real control**: a `Button` or a `Menu`,
    /// so it joins the key-view loop when Keyboard navigation is on and
    /// takes Space — never a tap gesture on text, never taken out of focus.
    func test_theFootsDoorsAreRealControls() throws {
        let code = try SourceTree.read("Maugham/Views/Brief/BriefDetails.swift")
        let view = String(code[code.range(of: "struct BriefFootView")!.lowerBound...]
            .prefix(while: { _ in true }))
            .components(separatedBy: "struct BriefFootButtonStyle")[0]
        XCTAssertTrue(view.contains("Button { openSheet(opens) } label:"), "a value is a button")
        XCTAssertTrue(view.contains("Menu {"), "Details is a menu")
        XCTAssertTrue(view.contains("Button { onPullUp(item) } label:"), "History is a button")
        for forbidden in ["onTapGesture", "focusable(false)", ".allowsHitTesting(false)", "focusEffectDisabled"] {
            XCTAssertFalse(view.contains(forbidden), "the foot's doors must stay controls: \(forbidden)")
        }
    }

    /// The how-to lines are gone from Brief's source, not merely hidden.
    func test_theHowToLinesAreGone() throws {
        var code = ""
        for name in ["BriefDetails", "BriefPieceView", "BriefBookView", "BriefDecidedSection"] {
            code += try SourceTree.read("Maugham/Views/Brief/\(name).swift")
        }
        for gone in ["What you answer in To resolve is filed here.", "Nothing is attached to this",
                     "Set a target", "Add tags", "Publishing settings", "explainsWhenEmpty",
                     "BriefFoldHint", "emptySection"] {
            XCTAssertFalse(code.contains(gone), "Brief still says or draws: \(gone)")
        }
        let part = try SourceTree.read("Maugham/Views/Brief/BriefPartView.swift")
        XCTAssertFalse(part.contains("BriefFootView"), "a Part's Brief has no foot")
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
        let piece = try SourceTree.read("Maugham/Views/Brief/BriefPieceView.swift")
        XCTAssertTrue(piece.contains("{ [docId] item in tree.pieceRowSheet = PieceRowSheet(item, pieceId: docId) }"))
        let code = try SourceTree.read("Maugham/Views/Brief/BriefDetails.swift")
        XCTAssertTrue(code.contains("PieceRowMenus.items("), "offered by the row menu's own answer")
        for source in [code, piece] {
            for forbidden in [".sheet(", "updateInspector", "updateProjectTargets"] {
                XCTAssertFalse(source.contains(forbidden), "the foot has no \(forbidden)")
            }
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
}
