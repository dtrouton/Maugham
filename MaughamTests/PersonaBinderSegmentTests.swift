import XCTest
import MaughamCore
@testable import Maugham

final class PersonaBinderSegmentTests: XCTestCase {
    func test_planPersona_leadsWithResearch() {
        XCTAssertEqual(Persona.plan.binderHome(for: .novel), .research)
    }

    func test_authorPersona_leadsWithTheDocumentHome() {
        XCTAssertEqual(Persona.author.binderHome(for: .novel), .manuscript)
        XCTAssertEqual(Persona.author.binderHome(for: .screenplay), .scenes,
                       "screenplay binders have no Manuscript segment")
    }

    func test_reviewPersona_leadsWithTheDocumentHome() {
        XCTAssertEqual(Persona.review.binderHome(for: .screenplay), .scenes)
    }

    func test_everyPersonaBinderHome_isAmongItsOwnSegments() {
        for persona in Persona.allCases {
            for type in ProjectType.allCases where type != .unknown {
                let segments = persona.binderSegments(for: type)
                XCTAssertTrue(segments.contains(persona.binderHome(for: type)),
                              "\(persona)/\(type) home is not in its segment list")
            }
        }
    }

    func test_screenplayPersonasNeverOfferManuscript() {
        // documentHome(for:)'s doc comment records the 2026-07-02 smoke bug:
        // forcing .manuscript on a screenplay drops into a one-row BinderView.
        for persona in Persona.allCases {
            XCTAssertFalse(persona.binderSegments(for: .screenplay).contains(.manuscript),
                           "\(persona) offers Manuscript on a screenplay")
        }
    }

    // MARK: - What the picker renders

    func test_visibleSegments_appendsTheRuntimeGatedOnesInEveryPersona() {
        for persona in Persona.allCases {
            let segments = BinderSegmentPicker.visibleSegments(
                persona: persona, projectType: .novel, hasTrash: true, findActive: true)
            XCTAssertEqual(segments.suffix(2), [.trash, .find],
                           "\(persona) must still offer Trash and Find")
        }
    }

    func test_visibleSegments_omitsTheRuntimeGatedOnesWhenTheirPredicatesAreFalse() {
        let segments = BinderSegmentPicker.visibleSegments(
            persona: .author, projectType: .novel, hasTrash: false, findActive: false)
        XCTAssertEqual(segments, [.manuscript, .research, .palette])
    }

    func test_visibleSegments_alwaysCarriesTheCurrentSelection() {
        // Review does not offer Palette, but a restored UIState or a forced
        // navigation can land there. A picker with nothing highlighted is the
        // state this avoids.
        let segments = BinderSegmentPicker.visibleSegments(
            persona: .review, projectType: .novel, hasTrash: false, findActive: false,
            including: .palette)
        XCTAssertTrue(segments.contains(.palette))
        XCTAssertEqual(segments.first, Persona.review.binderHome(for: .novel),
                       "appending must not disturb the persona's own ordering")
    }

    func test_visibleSegments_doesNotDuplicateASelectionItAlreadyOffers() {
        let segments = BinderSegmentPicker.visibleSegments(
            persona: .author, projectType: .novel, hasTrash: false, findActive: false,
            including: .research)
        XCTAssertEqual(segments.filter { $0 == .research }.count, 1)
    }
}
