import XCTest
import SwiftUI
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
        //
        // `.tree` joined in slice 2 (spec §3.1) and sits second: it is the
        // project's own manuscript tree with the canvas STILL in the centre —
        // Plan's structure segment, closing §1's hole ("the binder hasn't
        // appeared in plan view", 2026-08-02). It is second rather than first
        // because `binderHome` is `.first` and entering Plan must still land on
        // the canvas.
        //
        // `.manuscript` stays absent, and the reason recorded before slice 2 —
        // "the coercion rule can't strand a writer on it" — is gone with the
        // rule: `PersonaMemory.restoredBinderSegment` restores the DESTINATION's
        // own remembered position. What is true now is that `.manuscript` means
        // the editor in the centre and §2 says Plan does not draft; `.tree` is
        // the same tree without the same centre.
        XCTAssertEqual(Persona.plan.binderSegments(for: .novel),
                       [.canvas, .tree, .research, .palette])
    }

    func test_authorPersona_exactSegments() {
        // §6.3 Left = "Binder", and after slice 2 that is all it is.
        //
        // `.research` left in task 6 (§6.1): the right-hand registry already
        // said research is not Review's or Publish's business, so the left
        // column was the half that disagreed, and Author reads what a chapter
        // points at through `LinkedResearchPane` (⌘⌥R) instead.
        //
        // `.palette` followed in task 6b, on a WEAKER warrant that is stated
        // as the weaker one: nothing disagreed. Palette is a left segment in
        // Plan and Author and a right pane in Plan, Author and Review, so the
        // left set was a strict SUBSET of the right set. This is §6.1's
        // principle applied further — editing palette material is planning,
        // consulting it while drafting is Author, and `PalettePane` (⌘⌥P) is
        // read-only by its own doc comment — not a contradiction corrected.
        XCTAssertEqual(Persona.author.binderSegments(for: .novel), [.manuscript])
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

    /// **Research is AUTHORED on Plan's left and CONSULTED on Author's right,
    /// and lives in neither column of Review or Publish.** Stated as the whole
    /// row of both registries rather than as separate assertions, because the
    /// claim is about how the two relate.
    ///
    /// **That relation flipped on 2026-08-03 and this test's name went with
    /// it.** §6.1's argument was that the registries AGREE — research was a
    /// left segment exactly where it was a right pane, which was Plan — and the
    /// test was called `test_researchIsALeftSegmentOnlyWhereItIsAlsoAPane`.
    /// §5.0 of `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`
    /// takes the Research pane off Plan on the grounds that Plan authors
    /// research, so the two registries are now COMPLEMENTS on this pane: making
    /// it is Plan's left, reading it is Author's right. Both readings put
    /// `.research` in exactly the same two places; only the sentence explaining
    /// why changed, which is precisely the kind of claim a renamed test has to
    /// carry rather than a comment.
    func test_researchIsAuthoredOnPlansLeftAndConsultedOnAuthorsRight() {
        for type in ProjectType.allCases {
            for persona in Persona.allCases {
                XCTAssertEqual(
                    persona.binderSegments(for: type).contains(.research),
                    persona == .plan,
                    "\(persona)/\(type) — after §6.1 only Plan offers Research "
                    + "on the left")
            }
        }
        for persona in Persona.allCases {
            XCTAssertEqual(
                persona.panes.contains(.research), persona == .author,
                "\(persona) — after §5.0 only Author offers the Research PANE; "
                + "Plan makes research in the centre from its left segment")
        }
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
        // Plan, not Author: after task 6b Author's list is one element long, so
        // "the gated ones are absent" would be indistinguishable from "the list
        // collapsed to the home segment". Plan is the only persona left whose
        // list has a shape to lose.
        let segments = BinderSegmentPicker.visibleSegments(
            persona: .plan, projectType: .novel, hasTrash: false, findActive: false)
        XCTAssertEqual(segments, [.canvas, .tree, .research, .palette])
        XCTAssertFalse(segments.contains(.trash))
        XCTAssertFalse(segments.contains(.find))
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
        // Task 6 moved this off Author/`.research` for a reason that came
        // straight back around in task 6b: a selection the persona does NOT
        // offer exercises the APPEND path, so the test reads green while
        // asserting nothing about deduplication. `.palette` on Author was that
        // fixture, and 6b made it the same mistake it was written to avoid.
        //
        // Plan is now the ONLY persona with a non-home segment to test this
        // with (§6.2 — three of four stand on a single-segment picker), so it
        // is Plan, with the premise stated rather than assumed.
        XCTAssertTrue(Persona.plan.binderSegments(for: .novel).contains(.palette),
                      "premise: the segment under test must be one Plan offers, "
                      + "or this exercises the append path instead")
        let segments = BinderSegmentPicker.visibleSegments(
            persona: .plan, projectType: .novel, hasTrash: false, findActive: false,
            including: .palette)
        XCTAssertEqual(segments.filter { $0 == .palette }.count, 1)
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

    /// **The successor to `test_planAndAuthorAlwaysReachThePalette`, which task
    /// 6b of the persona shell's slice 2 answered rather than edited.**
    ///
    /// That test said Plan and Author are the two *making* personas and both
    /// must reach the palette wall from the binder. Half of it is still exactly
    /// true and is asserted below unchanged: **Plan** must reach the wall from
    /// the binder on every project type, which is the reachability the
    /// 2026-07-25 smoke lost ("I cannot find the wall of images").
    ///
    /// The other half stopped being true on purpose (§6.1, task 6b). The left
    /// segment is `PaletteBinderList` and picking a card puts `PaletteCardEditor`
    /// in the CENTRE — that is *making* palette material, which is Plan's work.
    /// What Author keeps is the right-hand `PalettePane`, whose own doc comment
    /// reads "pick a palette card and write against it — read-only images,
    /// swatches, and sensory notes beside the editor": consulting the palette
    /// while drafting, which is what Author is for.
    ///
    /// So the claim that replaces it is **the compensating route, asserted as a
    /// route** — Author reaches the palette by ⌘⌥P and by ⌘1, not by its binder.
    /// Deleting the old test outright would have left the removal unrecorded and
    /// nothing at all saying Author can still see a card.
    func test_theWallIsPlansAndTheCardIsStillAuthorsThroughTheRightColumn() {
        for type in ProjectType.allCases {
            XCTAssertTrue(
                BinderSegmentPicker.visibleSegments(
                    persona: .plan, projectType: type,
                    hasTrash: true, findActive: true).contains(.palette),
                "plan/\(type) cannot reach the palette wall")
            XCTAssertFalse(
                BinderSegmentPicker.visibleSegments(
                    persona: .author, projectType: type,
                    hasTrash: true, findActive: true).contains(.palette),
                "author/\(type) — the wall is one ⌘1 away, not a segment")
        }

        // What Author is left with, and it is a right-pane route, so it is
        // asserted against the right-hand registry rather than described.
        // `.palette` is OFFERED there rather than appended, which is the
        // difference between a pane ⌘⌥P lands on and one it merely forces.
        XCTAssertTrue(Persona.author.panes.contains(.palette),
                      "⌘⌥P must have a pane to land on in Author")
        XCTAssertTrue(
            DetailPaneToggle<AnyView>.visibleSegments(persona: .author, hideOutline: false)
                .contains(.palette),
            "and the right pane's own picker must offer it, so the writer can "
            + "get back to it without the menu")
        // And it survives the round trip, so ⌘⌥P in Author is not undone by the
        // next persona switch: `PersonaMemory` filters a remembered pane against
        // `panes`, which is the filter that drops `.outline`.
        var memory = PersonaMemory.empty
        memory.record(persona: .author, binderSegment: .manuscript, detailSegment: .palette)
        XCTAssertEqual(memory.restoredDetailSegment(for: .author), .palette)
    }

    /// **The upgrade path, which is the one way a writer can still be SITTING on
    /// `.palette` in Author.** `ProjectWindow`'s restore reads
    /// `UIState.binderSegment` verbatim and filters only `.manuscript` on a
    /// screenplay — it is not persona-filtered — so a project last quit on
    /// today's build in Author on the palette wall reopens there on the next
    /// one. `PersonaModifier.applyPersonaChange` closes the door going forward
    /// (⌘2 out of Plan coerces to Author's home), but it cannot reach a
    /// `ui-state.json` written before the change.
    ///
    /// So the segment Author no longer offers must still RENDER, and render
    /// selected — the same lens-not-gate property task 6 pinned for `.research`,
    /// which is what makes this a restore the writer can click out of rather
    /// than a picker with nothing highlighted over a wall of images.
    func test_aRestoredPaletteSegmentStillRendersInEveryPersona() {
        for type in ProjectType.allCases {
            for persona in Persona.allCases {
                let rendered = BinderSegmentPicker.visibleSegments(
                    persona: persona, projectType: type,
                    hasTrash: false, findActive: false, including: .palette)
                XCTAssertTrue(rendered.contains(.palette),
                              "\(persona)/\(type): a ui-state.json from before "
                              + "task 6b lands here")
                XCTAssertEqual(rendered.first, persona.binderHome(for: type),
                               "\(persona)/\(type): appending must not disturb "
                               + "the persona's own ordering")
            }
        }
    }
}
