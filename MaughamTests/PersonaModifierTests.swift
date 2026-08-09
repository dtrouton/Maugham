import XCTest
import MaughamCore
@testable import Maugham

/// **One column since shell-finish stage 2b Task 7.** Half of this suite was
/// about the binder — a transient segment riding through a switch, a stale
/// `.trash` never coming back out of the memory, a screenplay never landing on
/// the manuscript segment — and all of it went with `BinderSegment`. There is no
/// left-hand position for a persona switch to move, so the round trip that
/// defect B is about is now a round trip of the right column alone.
@MainActor
final class PersonaModifierTests: XCTestCase {
    func test_applyPersonaChange_landsOnTheDestinationDefault_theFirstTime() {
        // Sitting on Annotations in Review, then switching to Author, which
        // does not offer it. Landing on a blank pane would read as a bug.
        let result = PersonaModifier.applyPersonaChange(
            to: .author, from: .review, currentSegment: .annotations,
            memory: .empty)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, Persona.author.defaultPane)
    }

    /// The behaviour change defect B bought: a persona is a workspace, so
    /// entering one restores ITS panes, not whatever the last one happened to
    /// share with it. `.tasks` exists in Review, but Review's own remembered
    /// pane (here: none, so its default) wins.
    ///
    /// The shared pane must be one BOTH personas offer, or the test passes for
    /// the wrong reason — it would prove only that an unoffered pane is
    /// dropped, which is a different test two files over. It was `.outline`
    /// until the persona shell's slice 1 took that pane out of every registry.
    func test_applyPersonaChange_doesNotInheritASegmentJustBecauseTheDestinationOffersIt() {
        XCTAssertTrue(Persona.author.panes.contains(.tasks))
        XCTAssertTrue(Persona.review.panes.contains(.tasks))
        XCTAssertNotEqual(Persona.review.defaultPane, .tasks)

        let result = PersonaModifier.applyPersonaChange(
            to: .review, from: .author, currentSegment: .tasks,
            memory: .empty)
        XCTAssertEqual(result.segment, Persona.review.defaultPane)
    }

    func test_applyPersonaChange_toTheSamePersona_isIdentity() {
        let result = PersonaModifier.applyPersonaChange(
            to: .author, from: .author, currentSegment: .tasks,
            memory: .empty)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, .tasks)
    }

    // MARK: - Defect B: the round trip must be lossless

    /// ⌘1 then ⌘2 used to strand the right column on whatever the destination
    /// happened to share with the persona being left.
    func test_personaRoundTrip_returnsThePaneWhereItWas() {
        let out = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .inspector,
            memory: .empty)
        XCTAssertEqual(out.segment, Persona.plan.defaultPane, "Plan's own default")

        let back = PersonaModifier.applyPersonaChange(
            to: .author, from: .plan, currentSegment: out.segment,
            memory: out.memory)
        XCTAssertEqual(back.segment, .inspector,
                       "returning to Author must restore the pane it was left on")
    }

    /// Every persona pair: leave and come back, and the right column must be
    /// where it was. This is the whole point of defect B's fix, so it is pinned
    /// exhaustively rather than by example.
    ///
    /// **The default pane is what each persona is seeded with, and that is not
    /// a weakening.** A remembered pane the persona no longer offers is filtered
    /// on restore, so a non-offered fixture would make this assert the drop
    /// rather than the round trip — the trap
    /// `test_personaRoundTrip_isLosslessOnAScreenplay` fell into when slice 1
    /// took `.outline` out of every registry.
    func test_personaRoundTrip_isLosslessForEveryPair() {
        for home in Persona.allCases {
            let pane = home.defaultPane
            for away in Persona.allCases where away != home {
                let out = PersonaModifier.applyPersonaChange(
                    to: away, from: home, currentSegment: pane, memory: .empty)
                let back = PersonaModifier.applyPersonaChange(
                    to: home, from: away, currentSegment: out.segment,
                    memory: out.memory)
                XCTAssertEqual(back.segment, pane, "\(home)→\(away)→\(home)")
            }
        }
    }

    /// The other half, and the one the exhaustive loop above cannot see: a
    /// NON-default pane must round-trip too. With every persona seeded on its
    /// own default, a `record` that stored nothing at all would still pass.
    func test_personaRoundTrip_carriesANonDefaultPane() {
        XCTAssertTrue(Persona.author.panes.contains(.tasks))
        XCTAssertNotEqual(Persona.author.defaultPane, .tasks)

        let out = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .tasks, memory: .empty)
        let back = PersonaModifier.applyPersonaChange(
            to: .author, from: .plan, currentSegment: out.segment,
            memory: out.memory)
        XCTAssertEqual(back.segment, .tasks)
    }

    func test_applyPersonaChange_restoresARememberedPane() {
        XCTAssertTrue(Persona.plan.panes.contains(.tasks))
        XCTAssertNotEqual(Persona.plan.defaultPane, .tasks)
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .inspector,
            memory: PersonaMemory(detail: ["plan": .tasks]))
        XCTAssertEqual(result.segment, .tasks)
    }

    func test_applyPersonaChange_dropsARememberedPaneTheDestinationNoLongerOffers() {
        // `.annotations` remembered against Author, which does not offer it — a
        // value that could only arrive from a different build or a hand-edited
        // ui-state.json. It must not be restored.
        let result = PersonaModifier.applyPersonaChange(
            to: .author, from: .plan, currentSegment: .inspector,
            memory: PersonaMemory(detail: ["author": .annotations]))
        XCTAssertEqual(result.segment, Persona.author.defaultPane,
                       "Author's default, not the stale value")
    }

    // MARK: - The wall's stash must not fight the force-open

    // **The three `clearsPaletteWallStash` cases moved to
    // `PaletteWallDoorTests` with the rule itself** (stage 2b final review's
    // I3). The predicate lived here, asked of this handler, and this handler is
    // one of THREE writers of `persona` — the other two (a Claude arrival, a
    // wiki-link jump) never reach it, so a wall opened in Author survived them
    // both. Its successor is `ProjectWindow.closePaletteWallOnPersonaChange`,
    // observed on the persona in `PaletteWallModifier`, and the ordering
    // argument these tests pinned is pinned there instead: the stash is
    // dropped, so the exit arm's conditional restore cannot fight the
    // `showInspector = true` below.

    func test_personaFromPayload_parsesAValidRawValue() {
        XCTAssertEqual(PersonaModifier.persona(fromPayload: "review"), .review)
    }

    func test_personaFromPayload_rejectsGarbage() {
        XCTAssertNil(PersonaModifier.persona(fromPayload: "nonsense"))
        XCTAssertNil(PersonaModifier.persona(fromPayload: nil))
    }
}
