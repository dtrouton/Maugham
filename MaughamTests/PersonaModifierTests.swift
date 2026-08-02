import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class PersonaModifierTests: XCTestCase {
    func test_applyPersonaChange_landsOnTheDestinationDefault_theFirstTime() {
        // Sitting on Annotations in Review, then switching to Author, which
        // does not offer it. Landing on a blank pane would read as a bug.
        let result = PersonaModifier.applyPersonaChange(
            to: .author, from: .review, currentSegment: .annotations,
            currentBinderSegment: .manuscript, projectType: .novel,
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
            currentBinderSegment: .manuscript, projectType: .novel,
            memory: .empty)
        XCTAssertEqual(result.segment, Persona.review.defaultPane)
    }

    func test_applyPersonaChange_toTheSamePersona_isIdentity() {
        let result = PersonaModifier.applyPersonaChange(
            to: .author, from: .author, currentSegment: .tasks,
            currentBinderSegment: .manuscript, projectType: .novel,
            memory: .empty)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, .tasks)
        XCTAssertEqual(result.binderSegment, .manuscript)
    }

    func test_applyPersonaChange_movesBinderHomeWhenTheSegmentIsUnavailable() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .inspector,
            currentBinderSegment: .manuscript, projectType: .novel,
            memory: .empty)
        XCTAssertEqual(result.binderSegment, .canvas)
    }

    func test_applyPersonaChange_preservesAnActiveFind() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .inspector,
            currentBinderSegment: .find, projectType: .novel,
            memory: .empty)
        XCTAssertEqual(result.binderSegment, .find, "switching persona must not cancel a search")
    }

    func test_applyPersonaChange_preservesTrash() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .inspector,
            currentBinderSegment: .trash, projectType: .novel,
            memory: .empty)
        XCTAssertEqual(result.binderSegment, .trash,
                       "switching persona must not eject a writer out of Trash")
    }

    /// A transient segment rides through the switch but must NOT be recorded
    /// as the departing persona's position — otherwise a search days ago comes
    /// back as the binder the writer lands on.
    func test_applyPersonaChange_neverRemembersATransientSegment() {
        // The DEPARTING persona is Plan, not Author, and it has to be: the
        // pre-existing remembered value is read back through
        // `restoredBinderSegment`, which filters against the persona's own
        // registry — so a value the persona does not offer comes back as its
        // home, and the assertion cannot tell "the old value stood" from "the
        // transient was recorded and then filtered". Task 6b took Author to
        // `[home]`, leaving Plan the only persona with a value to stand on.
        XCTAssertTrue(Persona.plan.binderSegments(for: .novel).contains(.palette),
                      "premise: the remembered value must be one Plan offers")
        XCTAssertNotEqual(Persona.plan.binderHome(for: .novel), .palette,
                          "premise: and must differ from the fallback")
        let result = PersonaModifier.applyPersonaChange(
            to: .author, from: .plan, currentSegment: .inspector,
            currentBinderSegment: .find, projectType: .novel,
            memory: PersonaMemory(binder: ["plan": .palette]))
        XCTAssertEqual(result.memory.restoredBinderSegment(for: .plan, projectType: .novel),
                       .palette,
                       "the pre-existing remembered value must stand")
    }

    // MARK: - Defect B: the round trip must be lossless

    /// ⌘1 then ⌘2 from Author/Manuscript used to strand the binder on
    /// Research, because Author also offers Research so nothing moved it back.
    func test_personaRoundTrip_returnsTheBinderWhereItWas() {
        let out = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .inspector,
            currentBinderSegment: .manuscript, projectType: .novel,
            memory: .empty)
        XCTAssertEqual(out.binderSegment, .canvas, "Plan's own binder home")

        let back = PersonaModifier.applyPersonaChange(
            to: .author, from: .plan, currentSegment: out.segment,
            currentBinderSegment: out.binderSegment, projectType: .novel,
            memory: out.memory)
        XCTAssertEqual(back.binderSegment, .manuscript,
                       "returning to Author must restore the binder it was left on")
        XCTAssertEqual(back.segment, .inspector,
                       "and the right pane it was left on")
    }

    /// The same round trip on a screenplay, where the binder home is Scenes.
    func test_personaRoundTrip_isLosslessOnAScreenplay() {
        // `.tasks` stands in for `.outline`, which the persona shell's slice 1
        // took out of every registry — a remembered pane the persona no longer
        // offers is filtered on restore, so the round trip could not be
        // lossless with it and the test would have been asserting the drop.
        let out = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .tasks,
            currentBinderSegment: .scenes, projectType: .screenplay,
            memory: .empty)
        let back = PersonaModifier.applyPersonaChange(
            to: .author, from: .plan, currentSegment: out.segment,
            currentBinderSegment: out.binderSegment, projectType: .screenplay,
            memory: out.memory)
        XCTAssertEqual(back.binderSegment, .scenes)
        XCTAssertEqual(back.segment, .tasks)
    }

    /// Every persona pair, every project type: leave and come back, and both
    /// columns must be where they were. This is the whole point of defect B's
    /// fix, so it is pinned exhaustively rather than by example.
    func test_personaRoundTrip_isLosslessForEveryPairAndProjectType() {
        for type in ProjectType.allCases {
            for home in Persona.allCases {
                let binder = home.binderHome(for: type)
                let pane = home.defaultPane
                for away in Persona.allCases where away != home {
                    let out = PersonaModifier.applyPersonaChange(
                        to: away, from: home, currentSegment: pane,
                        currentBinderSegment: binder, projectType: type,
                        memory: .empty)
                    let back = PersonaModifier.applyPersonaChange(
                        to: home, from: away, currentSegment: out.segment,
                        currentBinderSegment: out.binderSegment, projectType: type,
                        memory: out.memory)
                    XCTAssertEqual(back.binderSegment, binder, "\(type) \(home)→\(away)→\(home)")
                    XCTAssertEqual(back.segment, pane, "\(type) \(home)→\(away)→\(home)")
                }
            }
        }
    }

    func test_applyPersonaChange_restoresARememberedBinderSegment() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .inspector,
            currentBinderSegment: .manuscript, projectType: .novel,
            memory: PersonaMemory(binder: ["plan": .palette]))
        XCTAssertEqual(result.binderSegment, .palette)
    }

    func test_applyPersonaChange_dropsARememberedSegmentTheDestinationNoLongerOffers() {
        // `.manuscript` remembered against Plan (which never offers it) — a
        // value that could only arrive from a different build or a hand-edited
        // ui-state.json. It must not be restored.
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .inspector,
            currentBinderSegment: .research, projectType: .novel,
            memory: PersonaMemory(binder: ["plan": .manuscript]))
        XCTAssertEqual(result.binderSegment, .canvas, "Plan's home, not the stale value")
    }

    func test_applyPersonaChange_neverRestoresAStaleTrash() {
        // `.trash` is runtime-gated and never in any persona's registry, so it
        // can never come back out of the memory even if it got in.
        let result = PersonaModifier.applyPersonaChange(
            to: .review, from: .author, currentSegment: .inspector,
            currentBinderSegment: .manuscript, projectType: .novel,
            memory: PersonaMemory(binder: ["review": .trash]))
        XCTAssertNotEqual(result.binderSegment, .trash)
        XCTAssertEqual(result.binderSegment, Persona.review.binderHome(for: .novel))
    }

    func test_applyPersonaChange_neverLandsAScreenplayOnManuscript() {
        // A screenplay binder has no Manuscript segment (2026-07-02 smoke).
        for persona in Persona.allCases {
            let result = PersonaModifier.applyPersonaChange(
                to: persona, from: .author, currentSegment: .inspector,
                currentBinderSegment: .palette, projectType: .screenplay,
                memory: PersonaMemory(binder: [persona.rawValue: .manuscript]))
            XCTAssertNotEqual(result.binderSegment, .manuscript, "\(persona)")
        }
    }

    // MARK: - The palette stash must not fight the force-open

    /// `PaletteSegmentModifier`'s exit arm restores the pre-palette inspector
    /// visibility in a LATER update pass than the persona handler, so a ⌘3
    /// pressed while the binder is on `.palette` (with the stash `false`) used
    /// to close the column right back over `showInspector = true`. Dropping
    /// the stash in the persona handler makes that arm a no-op restore.
    func test_clearsPaletteStash_whenAPersonaChangeLeavesThePalette() {
        // Review does not offer Palette, so the binder moves to its home.
        let change = PersonaModifier.applyPersonaChange(
            to: .review, from: .plan, currentSegment: .palette,
            currentBinderSegment: .palette, projectType: .novel,
            memory: .empty)
        XCTAssertNotEqual(change.binderSegment, .palette)
        XCTAssertTrue(PersonaModifier.clearsPaletteStash(
            from: .palette, to: change.binderSegment))
    }

    func test_clearsPaletteStash_isFalseWhenThePaletteSurvives() {
        // Plan REMEMBERS Palette, so the binder stays put — nothing to clear,
        // and the exit arm never fires anyway.
        let change = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .palette,
            currentBinderSegment: .palette, projectType: .novel,
            memory: PersonaMemory(binder: ["plan": .palette]))
        XCTAssertEqual(change.binderSegment, .palette)
        XCTAssertFalse(PersonaModifier.clearsPaletteStash(
            from: .palette, to: change.binderSegment))
    }

    func test_clearsPaletteStash_isFalseWhenTheBinderWasNotOnThePalette() {
        XCTAssertFalse(PersonaModifier.clearsPaletteStash(from: .manuscript, to: .research))
    }

    // MARK: - Paragraph navigation lands on the project's document home

    /// `ParagraphNavModifier` routes through `BinderSegment.documentHome(for:)`
    /// rather than naming `.manuscript` raw: a screenplay has no Manuscript
    /// segment, and since `BinderSegmentPicker.visibleSegments` appends the
    /// active selection, a raw `.manuscript` would render a labelled Manuscript
    /// tab the persona registry promises never to offer.
    func test_documentHome_isTheOnlyParagraphNavLanding() {
        XCTAssertEqual(BinderSegment.documentHome(for: .screenplay), .scenes)
        for type in ProjectType.allCases where type != .screenplay {
            XCTAssertEqual(BinderSegment.documentHome(for: type), .manuscript, "\(type)")
        }
        for persona in Persona.allCases {
            XCTAssertFalse(
                persona.binderSegments(for: .screenplay).contains(.manuscript),
                "\(persona) offers Manuscript on a screenplay")
        }
    }

    func test_personaFromPayload_parsesAValidRawValue() {
        XCTAssertEqual(PersonaModifier.persona(fromPayload: "review"), .review)
    }

    func test_personaFromPayload_rejectsGarbage() {
        XCTAssertNil(PersonaModifier.persona(fromPayload: "nonsense"))
        XCTAssertNil(PersonaModifier.persona(fromPayload: nil))
    }
}
