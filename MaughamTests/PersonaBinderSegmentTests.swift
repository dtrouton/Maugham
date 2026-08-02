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
        // §6.3 Left = "Binder". `.research` left in slice 2 of the persona
        // shell (§6.1): the right-hand registry already said research is not
        // Review's or Publish's business, so the left column was the half that
        // disagreed, and Author reads what a chapter points at through
        // `LinkedResearchPane` (⌘⌥R) instead.
        XCTAssertEqual(Persona.author.binderSegments(for: .novel),
                       [.manuscript, .palette])
    }

    func test_reviewPersona_exactSegments() {
        // DELIBERATE DEVIATION from §6.3's "Pieces by review state" (not
        // built yet): the ordinary binder stands in. Palette dropped out as a
        // making surface rather than an adjudicating one, and `.research`
        // followed it in slice 2.
        XCTAssertEqual(Persona.review.binderSegments(for: .novel), [.manuscript])
    }

    func test_publishPersona_exactSegments() {
        // DELIBERATE DEVIATION from §6.3's "Editions" (M1D not built yet):
        // the binder stands in alone. The old second entry was Research, kept
        // only so "the picker is a choice rather than a single button reading
        // as broken chrome" — a reason §6.1 overrules by name.
        XCTAssertEqual(Persona.publish.binderSegments(for: .novel), [.manuscript])
    }

    /// **The one-segment left column is a decision, not an accident** (§6.1),
    /// so it is asserted as one — over every project type, because the picker's
    /// list is built per type and a screenplay's home is a different case.
    ///
    /// This is the counterpart to
    /// `PersonaPaneRegistryTests.test_everyPersona_offersAtLeastTwoPanes`,
    /// which holds the floor on the RIGHT. There is no floor on the left and
    /// there deliberately is not one: Review and Publish are both standing in
    /// for unbuilt surfaces (§6.3's "Pieces by review state" and "Editions"),
    /// and a single entry makes that placeholder visible rather than disguising
    /// it. M3 and M4 each supply the real second entry.
    func test_reviewAndPublishStandOnASingleSegment() {
        for type in ProjectType.allCases {
            for persona in [Persona.review, .publish] {
                XCTAssertEqual(persona.binderSegments(for: type),
                               [BinderSegment.documentHome(for: type)],
                               "\(persona)/\(type) — one segment, and it is the "
                               + "document home rather than a padded list")
            }
        }
    }

    /// **`.research` is gone from the LEFT of the three drafting personas, and
    /// nowhere else.** Stated as the whole row of the matrix rather than three
    /// separate assertions, because §6.1's argument is about the two registries
    /// agreeing: research is a left-column surface exactly where it is a
    /// right-pane one, which is Plan.
    func test_researchIsALeftSegmentOnlyWhereItIsAlsoAPane() {
        for type in ProjectType.allCases {
            for persona in Persona.allCases {
                XCTAssertEqual(
                    persona.binderSegments(for: type).contains(.research),
                    persona == .plan,
                    "\(persona)/\(type) — after §6.1 only Plan offers Research "
                    + "on the left")
            }
        }
        // The half of the claim that would otherwise go unchecked: Author still
        // has the research PANE, so this was a move rather than an erasure —
        // and Review and Publish have neither half, which is the agreement §6.1
        // is about.
        XCTAssertTrue(Persona.author.panes.contains(.research))
        XCTAssertTrue(Persona.plan.panes.contains(.research))
        XCTAssertFalse(Persona.review.panes.contains(.research))
        XCTAssertFalse(Persona.publish.panes.contains(.research))
    }

    /// **The asymmetry §6.1 leaves behind, pinned rather than described.**
    /// Two event routes still force `.research` in Author —
    /// `ProjectWindow.openResearchItem` (the **Open** button on a promoted
    /// canvas card) and `handleShowLatestMCPNote` (the **Show** button on the
    /// MCP note banner). Neither consults the persona registry. So the segment
    /// a persona no longer offers must still RENDER, and render selected,
    /// rather than vanishing and leaving the picker with nothing highlighted
    /// over a pane that is showing research.
    ///
    /// Personas are lenses, not gates — and this is the assertion that keeps
    /// the removal from becoming one.
    func test_aForcedResearchSegmentStillRendersInEveryPersona() {
        for type in ProjectType.allCases {
            for persona in Persona.allCases {
                let rendered = BinderSegmentPicker.visibleSegments(
                    persona: persona, projectType: type,
                    hasTrash: false, findActive: false, including: .research)
                XCTAssertTrue(rendered.contains(.research),
                              "\(persona)/\(type): Open on a promoted card and "
                              + "Show on the MCP banner both land here")
                XCTAssertEqual(rendered.first, persona.binderHome(for: type),
                               "\(persona)/\(type): appending must not disturb "
                               + "the persona's own ordering")
            }
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
        XCTAssertEqual(segments, [.manuscript, .palette])
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
        // `.palette`, not `.research`: after §6.1 Author does not offer
        // Research, so a research selection here would be exercising the
        // APPEND path and this test would still read green while asserting
        // nothing about deduplication at all.
        let segments = BinderSegmentPicker.visibleSegments(
            persona: .author, projectType: .novel, hasTrash: false, findActive: false,
            including: .palette)
        XCTAssertEqual(segments.filter { $0 == .palette }.count, 1)
        XCTAssertTrue(Persona.author.binderSegments(for: .novel).contains(.palette),
                      "premise: the segment under test must be one Author offers")
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
