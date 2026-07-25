import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class PersonaModifierTests: XCTestCase {
    func test_applyPersonaChange_coercesASegmentTheDestinationLacks() {
        // Sitting on Annotations in Review, then switching to Author, which
        // does not offer it. Landing on a blank pane would read as a bug.
        let result = PersonaModifier.applyPersonaChange(
            to: .author, currentSegment: .annotations,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, Persona.author.defaultPane)
    }

    func test_applyPersonaChange_keepsASegmentTheDestinationOffers() {
        let result = PersonaModifier.applyPersonaChange(
            to: .review, currentSegment: .outline,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.segment, .outline, "Outline exists in Review; don't disturb it")
    }

    func test_applyPersonaChange_toTheSamePersona_isIdentity() {
        let result = PersonaModifier.applyPersonaChange(
            to: .author, currentSegment: .tasks,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, .tasks)
    }

    func test_applyPersonaChange_movesBinderHomeWhenTheSegmentIsUnavailable() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, currentSegment: .inspector,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.binderSegment, .research)
    }

    func test_applyPersonaChange_preservesAnActiveFind() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, currentSegment: .inspector,
            currentBinderSegment: .find, projectType: .novel)
        XCTAssertEqual(result.binderSegment, .find, "switching persona must not cancel a search")
    }

    func test_applyPersonaChange_preservesTrash() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, currentSegment: .inspector,
            currentBinderSegment: .trash, projectType: .novel)
        XCTAssertEqual(result.binderSegment, .trash,
                       "switching persona must not eject a writer out of Trash")
    }

    func test_applyPersonaChange_keepsABinderSegmentTheDestinationOffers() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, currentSegment: .inspector,
            currentBinderSegment: .palette, projectType: .novel)
        XCTAssertEqual(result.binderSegment, .palette, "Plan offers Palette; don't disturb it")
    }

    func test_applyPersonaChange_neverLandsAScreenplayOnManuscript() {
        // A screenplay binder has no Manuscript segment (2026-07-02 smoke).
        for persona in Persona.allCases {
            let result = PersonaModifier.applyPersonaChange(
                to: persona, currentSegment: .inspector,
                currentBinderSegment: .palette, projectType: .screenplay)
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
            to: .review, currentSegment: .palette,
            currentBinderSegment: .palette, projectType: .novel)
        XCTAssertNotEqual(change.binderSegment, .palette)
        XCTAssertTrue(PersonaModifier.clearsPaletteStash(
            from: .palette, to: change.binderSegment))
    }

    func test_clearsPaletteStash_isFalseWhenThePaletteSurvives() {
        // Plan offers Palette, so the binder stays put — nothing to clear, and
        // the exit arm never fires anyway.
        let change = PersonaModifier.applyPersonaChange(
            to: .plan, currentSegment: .palette,
            currentBinderSegment: .palette, projectType: .novel)
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
