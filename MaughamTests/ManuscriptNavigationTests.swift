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
/// asked of the persona's own CENTRE COLUMN, and it is asked here **over a
/// centre column the test supplies**, because that is the only way to falsify it
/// in an app whose four personas all agree with the shortcut. (Until
/// shell-finish stage 2b Task 6 the supplied input was a binder-segment list;
/// the basis moved because Task 7 deletes both the segment enum and the binder
/// registries, and the falsification moved with it rather than being lost.)
@MainActor
final class ManuscriptNavigationTests: XCTestCase {

    // MARK: - The rule, over centre columns this app does not have

    /// **The discriminating test, and the reason `showsManuscriptDocuments` is
    /// two functions.** Applied to the four real personas, the rule and the
    /// `== .plan` shortcut agree — Plan is the only persona whose centre column
    /// is the board today, which is precisely what the plan's ruling says should
    /// FALL OUT of the rule rather than be asserted by it. Asked of an arbitrary
    /// centre column, they disagree immediately.
    ///
    /// **The synthetic input changed shape in shell-finish stage 2b Task 6 and
    /// the discrimination survived the change.** It used to be a segment list
    /// this app does not ship (`[.canvas, .tree, .manuscript]`), because the
    /// rule was "does this persona's column offer the document home". Task 7
    /// deletes both the segment enum and the binder registries, so that basis
    /// could not be the one that survives; the rule now reads the centre column
    /// (`Persona.centresTheCanvas`). What is asserted is unchanged in kind: the
    /// answer follows the input, and a persona name appears nowhere in it.
    func test_theRuleIsAboutTheCentreColumn_notAboutAnyParticularPersona() {
        // A centre column that is not the board shows documents…
        XCTAssertTrue(Persona.showsManuscriptDocuments(centresTheCanvas: false),
                      "a persona whose centre is not the planning canvas shows "
                      + "the writer their manuscript, whatever it is called")
        // …and one that is does not, whoever's it is.
        XCTAssertFalse(Persona.showsManuscriptDocuments(centresTheCanvas: true))

        // **The anti-degeneracy control.** A rule that answered a constant
        // would satisfy either assertion above on its own and both of them if
        // the expectations had been bent to match, so the two answers are
        // pinned against each other as well as against their inputs.
        XCTAssertNotEqual(Persona.showsManuscriptDocuments(centresTheCanvas: true),
                          Persona.showsManuscriptDocuments(centresTheCanvas: false),
                          "the rule answers the same thing for both centre "
                          + "columns, so nothing below can be discriminating")
    }

    /// The instance form is the rule applied to the persona's own centre column
    /// and nothing else — so a future persona whose centre changes moves the
    /// behaviour with it, and no site re-derives the question.
    func test_everyPersonaAsksItsOwnCentreColumn() {
        for persona in Persona.allCases {
            XCTAssertEqual(
                persona.showsManuscriptDocuments,
                Persona.showsManuscriptDocuments(
                    centresTheCanvas: persona.centresTheCanvas),
                "\(persona): the instance form must be the static rule over "
                + "this persona's own centre — a second derivation here is the "
                + "fifth spelling slice 2 spent two tasks removing")
        }
    }

    /// **And the answers themselves, so the two forms above cannot agree on a
    /// wrong table.** Plan plans; the other three are where a document is read
    /// or written. Project type does not enter into it any more, which is the
    /// one thing the re-base did change: the old rule asked `documentHome(for:)`
    /// because a screenplay's home segment was `.scenes`, and there are no
    /// segments in the answer now.
    func test_planIsTheOnlyPersonaWhoseCentreIsNotADocument() {
        XCTAssertFalse(Persona.plan.showsManuscriptDocuments)
        for persona in Persona.allCases where persona != .plan {
            XCTAssertTrue(persona.showsManuscriptDocuments,
                          "\(persona) centres the editor")
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
