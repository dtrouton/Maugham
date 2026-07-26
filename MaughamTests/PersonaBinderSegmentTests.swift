import XCTest
import MaughamCore
@testable import Maugham

final class PersonaBinderSegmentTests: XCTestCase {
    func test_planPersona_leadsWithTheCanvas() {
        // M1C: Plan's centre column is the freeform planning canvas, so the
        // canvas leads its segment list and is therefore its binderHome.
        XCTAssertEqual(Persona.plan.binderHome(for: .novel), .canvas)
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

    func test_documentHome_forCollection_isManuscript() {
        // A collection's manuscript segment is the same case as a novel's —
        // only its picker label differs ("Pieces" via displayName(for:)).
        XCTAssertEqual(BinderSegment.documentHome(for: .collection), .manuscript)
    }

    // MARK: - Exact segment lists, reconciled against §6.3 of
    // docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md.
    // Each `Persona.binderSegments(for:)` case carries its own reconciliation
    // comment, including the two DELIBERATE DEVIATIONs (Review, Publish) —
    // these tests pin what the code does today; the comments at the source
    // explain why. Novel stands in for the non-screenplay home segment
    // (`.manuscript`); the screenplay swap is covered separately above.

    func test_planPersona_exactSegments() {
        // §6.3 Left = "Research tree" and centre = the canvas (M1C). The canvas
        // leads because entering Plan should land on it; Research follows as
        // §6.3's Left surface and as the source 1C-d drags items from.
        // Manuscript is deliberately absent so the coercion rule can't strand a
        // writer on it (see Persona.swift).
        XCTAssertEqual(Persona.plan.binderSegments(for: .novel), [.canvas, .research, .palette])
    }

    func test_authorPersona_exactSegments() {
        // §6.3 Left = "Binder" — the default persona must look unchanged to
        // an upgrading writer.
        XCTAssertEqual(Persona.author.binderSegments(for: .novel),
                       [.manuscript, .research, .palette])
    }

    func test_reviewPersona_exactSegments() {
        // DELIBERATE DEVIATION from §6.3's "Pieces by review state" (not
        // built yet): the ordinary binder stands in, and Palette drops out
        // as a making surface rather than an adjudicating one.
        XCTAssertEqual(Persona.review.binderSegments(for: .novel), [.manuscript, .research])
    }

    func test_publishPersona_exactSegments() {
        // DELIBERATE DEVIATION from §6.3's "Editions" (M1D not built yet):
        // the binder stands in, plus Research so the picker is a choice
        // rather than a single button reading as broken chrome.
        XCTAssertEqual(Persona.publish.binderSegments(for: .novel), [.manuscript, .research])
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

    // MARK: - Defect C: the palette must be present and selectable

    /// Every binder segment renders as an icon, so every one needs a symbol and
    /// no two may collide — a duplicate would be indistinguishable in a picker
    /// that has no text labels.
    func test_everySegmentHasADistinctPickerSymbol() {
        let all = BinderSegment.allCases
        let symbols = all.map(\.pickerSymbolName)
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
        XCTAssertEqual(Set(symbols).count, all.count, "picker symbols must be distinct")
    }

    /// The tooltip / accessibility label is the only text an icon-only picker
    /// carries, so it must never be empty — and a collection still says
    /// "Pieces", not "Manuscript".
    func test_everySegmentHasANonEmptyDisplayNameForEveryProjectType() {
        let all = BinderSegment.allCases
        for type in ProjectType.allCases {
            for segment in all {
                XCTAssertFalse(segment.displayName(for: type).isEmpty, "\(segment)/\(type)")
            }
        }
        XCTAssertEqual(BinderSegment.manuscript.displayName(for: .collection), "Pieces")
    }

    /// The writer's actual complaint: "I cannot find the wall of images."
    /// Palette must be in the rendered list — for every project type — in
    /// exactly the personas whose registry offers it, and selecting it is what
    /// routes the centre column to `PaletteWallView`.
    func test_paletteIsRendered_inEveryPersonaWhoseRegistryOffersIt() {
        for type in ProjectType.allCases {
            for persona in Persona.allCases {
                let offered = persona.binderSegments(for: type).contains(.palette)
                let rendered = BinderSegmentPicker.visibleSegments(
                    persona: persona, projectType: type,
                    hasTrash: false, findActive: false).contains(.palette)
                XCTAssertEqual(rendered, offered, "\(persona)/\(type)")
            }
        }
    }

    /// Plan and Author are the two making personas, and both must reach the
    /// palette wall from the binder on every project type. Pinned by name
    /// because this is the reachability the smoke lost.
    func test_planAndAuthorAlwaysReachThePalette() {
        for type in ProjectType.allCases {
            for persona in [Persona.plan, .author] {
                XCTAssertTrue(
                    BinderSegmentPicker.visibleSegments(
                        persona: persona, projectType: type,
                        hasTrash: true, findActive: true).contains(.palette),
                    "\(persona)/\(type) cannot reach the palette wall")
            }
        }
    }
}
