import XCTest
import MaughamCore
@testable import Maugham

/// **Navigating to a manuscript document moves the writer to Author — from a
/// persona that would not show the document, and from no other.**
///
/// Denver's ruling, 2026-08-02: *"if I'm moving to the manuscript I'm moving to
/// Author — I shouldn't be writing the manuscript in plan."*
///
/// The whole risk lives in HOW the guard asks its question. A hardcoded
/// `persona == .plan` produces exactly the same behaviour today and ships the
/// defect the moment Review's left column changes: clicking an annotation or a
/// history row navigates to a paragraph, and a reviewer ejected into Author
/// cannot adjudicate — which is the one job Review exists for. So the rule is
/// asked of the persona's own binder registry, and it is asked here **over a
/// segment list the test supplies**, because that is the only way to falsify it
/// in an app whose four registries all agree with the shortcut.
@MainActor
final class ManuscriptNavigationTests: XCTestCase {

    // MARK: - The rule, over registries this app does not have

    /// **The discriminating test, and the reason `showsManuscriptDocuments` is
    /// two functions.** Applied to the four real personas, the rule and the
    /// `== .plan` shortcut agree on every project type — Plan is the only
    /// persona whose binder omits the document home today, which is precisely
    /// what the plan's ruling says should FALL OUT of the rule rather than be
    /// asserted by it. Asked of an arbitrary segment list, they disagree
    /// immediately.
    func test_theRuleIsAboutTheDocumentHome_notAboutAnyParticularPersona() {
        // A registry with the home in it shows documents…
        XCTAssertTrue(Persona.showsManuscriptDocuments(
            in: [.canvas, .tree, .manuscript], for: .novel),
            "a persona offering the document home shows documents, whatever "
            + "else its column carries")
        // …and one without it does not, however many planning surfaces it has.
        XCTAssertFalse(Persona.showsManuscriptDocuments(
            in: [.canvas, .tree, .research, .palette], for: .novel))

        // **The screenplay case is the one a `.manuscript` literal gets wrong.**
        // A screenplay's document home is `.scenes`, so a column offering
        // `.manuscript` shows a screenplay nothing at all.
        XCTAssertTrue(Persona.showsManuscriptDocuments(in: [.scenes], for: .screenplay))
        XCTAssertFalse(Persona.showsManuscriptDocuments(in: [.manuscript],
                                                        for: .screenplay))

        // The empty column, which nothing offers today and the rule still answers.
        XCTAssertFalse(Persona.showsManuscriptDocuments(in: [], for: .novel))
    }

    /// The instance form is the rule applied to the persona's own registry and
    /// nothing else — so a future registry edit moves the behaviour with it.
    func test_everyPersonaAsksItsOwnRegistry() {
        for persona in Persona.allCases {
            for type in ProjectType.allCases where type != .unknown {
                XCTAssertEqual(
                    persona.showsManuscriptDocuments(for: type),
                    Persona.showsManuscriptDocuments(
                        in: persona.binderSegments(for: type), for: type),
                    "\(persona)/\(type): the instance form must be the static "
                    + "rule over this persona's own segments — a second "
                    + "derivation here is the fifth spelling slice 2 spent two "
                    + "tasks removing")
            }
        }
    }

    // MARK: - The four personas

    /// **Plan moves; Review, Publish and Author do not** — in every project
    /// type. Review is the case the ruling is written around: clicking an
    /// annotation or a history row posts `.maughamNavigateToParagraph`, and
    /// ejecting the reviewer into Author would take the notes off their screen.
    func test_onlyPlanIsMovedToAuthorAndTheOthersStayWhereTheyAre() {
        for type in ProjectType.allCases where type != .unknown {
            for persona in Persona.allCases {
                let destination = ManuscriptNavigation.destination(
                    from: persona,
                    currentBinderSegment: persona.binderHome(for: type),
                    currentDetailSegment: persona.defaultPane,
                    projectType: type,
                    memory: .empty)
                let expected: Persona = persona == .plan ? .author : persona
                XCTAssertEqual(destination.persona, expected,
                               "\(persona)/\(type): expected to land in "
                               + "\(expected)")
            }
        }
    }

    /// And the binder lands on the document home in every case — the behaviour
    /// that was there before the persona move and must survive it.
    func test_theBinderAlwaysLandsOnTheDocumentHome() {
        for type in ProjectType.allCases where type != .unknown {
            for persona in Persona.allCases {
                let destination = ManuscriptNavigation.destination(
                    from: persona,
                    currentBinderSegment: persona.binderHome(for: type),
                    currentDetailSegment: persona.defaultPane,
                    projectType: type,
                    memory: .empty)
                XCTAssertEqual(destination.binderSegment,
                               .documentHome(for: type),
                               "\(persona)/\(type)")
            }
        }
    }

    /// **The plant against reusing `applyPersonaChange`'s own binder answer.**
    /// That function deliberately carries a TRANSIENT segment through a persona
    /// switch — a writer mid-search is not ejected — so a navigation that took
    /// `Change.binderSegment` would leave the binder sitting in Find while the
    /// window had just been told to show a document.
    func test_aNavigationFromFindStillLandsOnTheDocument() {
        for segment in BinderSegment.allCases where segment.isTransient {
            let destination = ManuscriptNavigation.destination(
                from: .plan,
                currentBinderSegment: segment,
                currentDetailSegment: .intent,
                projectType: .novel,
                memory: .empty)
            XCTAssertEqual(destination.binderSegment, .manuscript,
                           "from \(segment): the navigation names a document, "
                           + "so the binder must show one")
            XCTAssertEqual(destination.persona, .author)
        }
    }

    // MARK: - ⌘1 gets the writer back

    /// **What makes the move acceptable rather than destructive.** The departing
    /// position is recorded, so ⌘1 returns the writer to the tree they were
    /// arranging — verified by feeding the memory this navigation produces back
    /// through the real persona switch.
    ///
    /// **The pane was `.visualLanguage` until §5.0's right-column re-cut, and
    /// the swap is worth reading rather than skipping.** `PersonaMemory`
    /// remembers a pane only if the persona's registry still offers it, so a
    /// pane Plan reaches by shortcut alone — intent (⌘⌥N) and visual language
    /// (⌘⌥V), both of which Plan now AUTHORS from the left column instead — is
    /// deliberately not restored by ⌘1. That is the same rule that has always
    /// dropped `.outline`, and it is the accepted cost of §5.0's parked build
    /// rather than a defect this test should be pinning as correct. `.history`
    /// is a pane Plan really carries, and the assertion below checks it is not
    /// Plan's default so the restore cannot pass by falling back.
    func test_theDepartingPlanPositionIsRecordedSoCommand1ComesBack() throws {
        XCTAssertNotEqual(DetailSegment.history, Persona.plan.defaultPane,
                          "pick a non-default pane, or the restore assertion is "
                          + "satisfied by the fallback")
        let destination = ManuscriptNavigation.destination(
            from: .plan,
            currentBinderSegment: .tree,
            currentDetailSegment: .history,
            projectType: .novel,
            memory: .empty)
        let memory = try XCTUnwrap(
            destination.memory,
            "the move must hand back a memory to persist, or ⌘1 lands on "
            + "Plan's home and the writer's place in the tree is gone")
        let back = PersonaModifier.applyPersonaChange(
            to: .plan, from: destination.persona,
            currentSegment: destination.detailSegment,
            currentBinderSegment: destination.binderSegment,
            projectType: .novel,
            memory: memory)
        XCTAssertEqual(back.persona, .plan)
        XCTAssertEqual(back.binderSegment, .tree,
                       "⌘1 must return the writer to the structure they were "
                       + "arranging, not to Plan's canvas home")
        XCTAssertEqual(back.segment, .history,
                       "and to the pane they were reading it against")
    }

    /// A transient departure is not recorded — `PersonaMemory.record` refuses
    /// it, and the navigation must not smuggle one past that by another route.
    func test_aDepartureFromFindIsNotRememberedAsPlansPosition() {
        let destination = ManuscriptNavigation.destination(
            from: .plan,
            currentBinderSegment: .find,
            currentDetailSegment: .intent,
            projectType: .novel,
            memory: .empty)
        let memory = destination.memory ?? .empty
        XCTAssertEqual(memory.restoredBinderSegment(for: .plan, projectType: .novel),
                       Persona.plan.binderHome(for: .novel),
                       "a search is a state the writer passed through, not the "
                       + "surface Plan works on")
    }

    /// Nothing is persisted when nothing moved — a navigation inside Author must
    /// not rewrite the memory of a persona the writer never left.
    func test_noMemoryIsWrittenWhenThePersonaDoesNotMove() {
        for persona in [Persona.author, .review, .publish] {
            let destination = ManuscriptNavigation.destination(
                from: persona,
                currentBinderSegment: .manuscript,
                currentDetailSegment: .inspector,
                projectType: .novel,
                memory: .empty)
            XCTAssertNil(destination.memory,
                         "\(persona): no persona change, nothing to record")
            XCTAssertFalse(destination.movesPersona)
        }
    }

    /// The right column moves with the persona. A window whose bar says Author
    /// while its right pane shows Visual Language — a pane Author's registry
    /// does not carry — is half a persona switch, and the half that is missing
    /// is the one `PersonaMemory` then records against Author.
    func test_theRightColumnLandsOnTheDestinationsOwnPane() {
        let destination = ManuscriptNavigation.destination(
            from: .plan,
            currentBinderSegment: .tree,
            currentDetailSegment: .visualLanguage,
            projectType: .novel,
            memory: .empty)
        XCTAssertEqual(destination.detailSegment, Persona.author.defaultPane)
        XCTAssertTrue(Persona.author.panes.contains(destination.detailSegment))
    }

    /// A persona that already shows documents keeps the pane the writer chose:
    /// clicking a history row in Review must leave Review's own column alone.
    func test_aNonMovingNavigationLeavesTheRightColumnAlone() {
        let destination = ManuscriptNavigation.destination(
            from: .review,
            currentBinderSegment: .manuscript,
            currentDetailSegment: .annotations,
            projectType: .novel,
            memory: .empty)
        XCTAssertEqual(destination.persona, .review)
        XCTAssertEqual(destination.detailSegment, .annotations)
    }
}
