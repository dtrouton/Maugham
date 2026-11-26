import XCTest
import MaughamCore
@testable import Maugham

/// **The Research section says where the rest went** (shell closing A8, the
/// milestone review's writer's-seat 2). Under either/or a note linked to a
/// chapter is drawn in that chapter's fold, not the section — so an older
/// project opens to an almost empty Research. The section's foot counts the
/// notes in the folds (`ResearchHomes.underAPiece`, derived once with the
/// homes and cached on the manifest — tripwire 4), in the project's noun.
final class ResearchWhereItWentTests: XCTestCase {

    private func note(_ id: String, path: String = "research/x.md") -> ResearchItem {
        ResearchItem(id: id, title: id, type: .asset, kind: .document, path: path)
    }

    private func chapter(_ id: String, linked: [String]) -> StructureItem {
        StructureItem(id: id, title: id, type: .document, path: "manuscript/\(id).md",
                      linkedResearchIds: linked)
    }

    // MARK: - The sentence

    func test_theFootSaysHowManyNotesAreInTheFolds() {
        XCTAssertNil(BinderTreeSections.researchElsewhereText(underAPiece: 0, noun: .chapter),
                     "none in a fold: no line")
        XCTAssertEqual(BinderTreeSections.researchElsewhereText(underAPiece: 1, noun: .chapter),
                       "1 note is with its chapter \u{2014} open the chapter\u{2019}s fold to see it.")
        XCTAssertEqual(BinderTreeSections.researchElsewhereText(underAPiece: 12, noun: .chapter),
                       "12 notes are with their chapters \u{2014} open a chapter\u{2019}s fold to see them.")
        XCTAssertEqual(BinderTreeSections.researchElsewhereText(
            underAPiece: 3, noun: PieceNoun.of(nil, in: PieceNoun.Book(type: .collection))),
            "3 notes are with their pieces \u{2014} open a piece\u{2019}s fold to see them.")
    }

    /// The emptied section says both: none is the book's, and where they went.
    func test_theEmptySectionSaysWhereTheyWent() {
        XCTAssertEqual(BinderTreeSections.emptyResearchText(anyUnderAPiece: false, underAPiece: 0, noun: .chapter),
                       "No research yet.")
        XCTAssertEqual(BinderTreeSections.emptyResearchText(anyUnderAPiece: true, underAPiece: 2, noun: .chapter),
                       "No whole-book research. 2 notes are with their chapters \u{2014} open a chapter\u{2019}s fold to see them.")
        XCTAssertEqual(BinderTreeSections.emptyResearchText(anyUnderAPiece: true, underAPiece: 0, noun: .chapter),
                       "No whole-book research.", "only an empty group in a fold: no count to give")
    }

    // MARK: - The count

    /// Linked notes count once each however many chapters link them; a group
    /// whose every note is a chapter's (a container, drawn nowhere) is counted
    /// through its notes; groups and whole-book notes are not counted.
    func test_theCountIsTheNotesInTheFolds() {
        let research = [
            note("r-loose"),
            note("r-linked-twice"),
            ResearchItem(id: "g-places", title: "Places", type: .group, path: "research/places",
                         children: [note("r-harbour"), note("r-mill")]),
            ResearchItem(id: "g-mixed", title: "People", type: .group, path: "research/people",
                         children: [note("r-ada"), note("r-kept")]),
        ]
        let structure = [
            chapter("ch-1", linked: ["r-linked-twice", "g-places"]),
            chapter("ch-2", linked: ["r-linked-twice", "r-ada"]),
        ]
        let homes = ResearchHomes.derive(structure: structure, research: research, projectType: .novel)
        XCTAssertEqual(homes.underAPiece, 4, "r-linked-twice, r-harbour, r-mill, r-ada")
        XCTAssertTrue(homes.isContainer("g-places") || homes.homes(of: "g-places") == ["ch-1"],
                      "premise: the linked group's notes are drawn under its chapter")
        XCTAssertEqual(ResearchHomes.derive(structure: [chapter("ch-1", linked: [])], research: research,
                                            projectType: .novel).underAPiece, 0, "control: nothing linked")
    }
}
