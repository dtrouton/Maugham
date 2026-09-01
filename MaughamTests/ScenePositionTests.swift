// MaughamTests/ScenePositionTests.swift
import MaughamCore
import XCTest
@testable import Maugham

/// **The three-position derivation** (spec §3.4's table, editorial letter P1
/// Task 3). What the letter's scene table is allowed to be — nothing, a weak
/// observational form, or the strong form — is decided app-side from the
/// project's type, the writer's own intent statement and the active pass's
/// brief, and the model is TOLD which position it is in rather than asked to
/// infer one.
///
/// The split inside the strong form is the doctrine these tests exist for:
/// a turn-less scene is a conformance strain only when the writer's own words
/// carry the clause it would strain against (`.strongDeclared`). Arrived at
/// any other way — a screenplay whose intent says nothing about form, a prose
/// piece opted in by a pass brief — it is `.strongDefault`, and the table's
/// turn-less rows stay observations with the Add-to-intent offer beneath them
/// (Task 9). Nothing here synthesizes a clause on the writer's behalf.
final class ScenePositionTests: XCTestCase {

    // MARK: - The table, row by row (spec §3.4)

    /// Row 1. Prose whose intent says nothing about form gets the weak form:
    /// rows, no charge, a blank `changes` read as an observation.
    func test_proseSayingNothingAboutFormIsWeak() {
        XCTAssertEqual(
            ScenePosition.derive(
                projectType: .novel,
                statement: "Cold, and never wistful. The sentences stay short.",
                passBrief: nil),
            .weak)
        XCTAssertEqual(
            ScenePosition.derive(projectType: .shortStory, statement: nil, passBrief: nil),
            .weak,
            "no statement at all is a writer who has declared nothing, not an opt-out")
        XCTAssertEqual(
            ScenePosition.derive(projectType: .collection, statement: "", passBrief: nil),
            .weak)
    }

    /// Row 2, first half. Prose whose own intent carries a turn clause is in
    /// the strong form AND has a clause to strain against.
    func test_proseWhoseIntentCarriesATurnClauseIsStrongDeclared() {
        for clause in ["Every scene must turn.",
                       "This book moves by dramatic turns.",
                       "Every chapter is built on conflict."] {
            XCTAssertEqual(
                ScenePosition.derive(projectType: .novel, statement: clause, passBrief: nil),
                .strongDeclared,
                "the writer's own words carry the clause: \(clause)")
        }
    }

    /// Row 2, second half. The pass brief can put a prose piece in the strong
    /// form — but a brief is doctrine the writer chose a lane for, not a
    /// sentence they wrote about their book, so it earns no strain.
    func test_prosePutInTheStrongFormByThePassBriefAloneIsStrongDefault() {
        XCTAssertEqual(
            ScenePosition.derive(
                projectType: .novel,
                statement: "Cold, and never wistful.",
                passBrief: "Structure and shape — and hold this book to conflict "
                    + "in every scene."),
            .strongDefault)
    }

    /// **The shipped Structural brief does NOT flip a prose piece into the
    /// strong form**, and that is the guard, not an accident. Perkins reads
    /// for architecture in every writer's book; a brief that happened to say
    /// "conflict" would silently put every prose novel in a Structural pass
    /// under a doctrine its writer never chose, and the offer beneath the
    /// table would ask them to declare a clause the app had already assumed.
    /// The brief route belongs to a writer who edited their own brief.
    func test_theShippedStructuralBriefLeavesAProsePieceWeak() throws {
        let brief = try XCTUnwrap(
            ReviewPass.presets.first(where: { $0.id == "structural" })?.brief,
            "the structural preset lost its brief")
        XCTAssertEqual(
            ScenePosition.derive(
                projectType: .novel, statement: "Cold, and never wistful.", passBrief: brief),
            .weak)
    }

    /// …and when BOTH say so, the writer's own words win the split: there is a
    /// clause to quote, so a turn-less scene is a strain.
    func test_aClauseInTheIntentBeatsTheBriefsSilenceAboutOne() {
        XCTAssertEqual(
            ScenePosition.derive(
                projectType: .novel,
                statement: "Every scene must turn.",
                passBrief: "Read for structure: does every scene turn?"),
            .strongDeclared)
    }

    /// Row 3. Prose that opts out explicitly has no scene table at all.
    func test_proseThatOptsOutHasNoScenes() {
        for optOut in ["This is not scene-driven; it accretes.",
                       "A lyric sequence, not a plot.",
                       "Essayistic throughout.",
                       "It should meander."] {
            XCTAssertEqual(
                ScenePosition.derive(projectType: .novel, statement: optOut, passBrief: nil),
                ScenePosition.none,
                "an explicit opt-out: \(optOut)")
        }
    }

    /// Row 4. A screenplay whose intent says nothing is in the strong form by
    /// its FORM rather than by anything the writer declared — so the offer,
    /// not the strain.
    func test_aScreenplayWithASilentIntentIsStrongDefault() {
        XCTAssertEqual(
            ScenePosition.derive(
                projectType: .screenplay,
                statement: "Cold, and never wistful.",
                passBrief: nil),
            .strongDefault)
        XCTAssertEqual(
            ScenePosition.derive(projectType: .screenplay, statement: nil, passBrief: nil),
            .strongDefault,
            "no intent at all is still a screenplay")
    }

    /// …and a screenplay whose writer DID declare the clause strains against
    /// it like any other declared piece. The `.strongDeclared`/`.strongDefault`
    /// split turns on whether a clause exists, never on how the strong form was
    /// arrived at — spec §3.4's "a strain needs a clause the writer wrote".
    func test_aScreenplayWhoseIntentCarriesTheClauseIsStrongDeclared() {
        XCTAssertEqual(
            ScenePosition.derive(
                projectType: .screenplay,
                statement: "Every scene must turn, or it is cut.",
                passBrief: nil),
            .strongDeclared)
    }

    /// Row 5. A screenplay that opts out explicitly gets no table either — the
    /// opt-out is the writer's own sentence and outranks the form's default.
    func test_aScreenplayThatOptsOutHasNoScenes() {
        XCTAssertEqual(
            ScenePosition.derive(
                projectType: .screenplay,
                statement: "A lyric documentary; not scene-driven.",
                passBrief: nil),
            ScenePosition.none)
    }

    // MARK: - The two rules the table does not spell

    /// **The opt-out beats everything**, including a clause in the same
    /// statement and a brief that asks for structure. The writer said the
    /// piece does not move by scenes; nothing else in the derivation may
    /// overrule that sentence.
    func test_theOptOutBeatsAClauseAndABrief() {
        XCTAssertEqual(
            ScenePosition.derive(
                projectType: .screenplay,
                statement: "Every scene must turn — except this one, which is lyric.",
                passBrief: "Hold this book to conflict in every scene."),
            ScenePosition.none)
    }

    /// **`nil` reads as prose.** A project whose type could not be resolved is
    /// not a screenplay, and defaulting the unknown case into the strong form
    /// would put an essay collection under a doctrine its writer never chose.
    /// `.unknown` — a type written by a newer build (ADR 0015) — reads the
    /// same way.
    func test_anUnresolvedProjectTypeReadsAsProse() {
        XCTAssertEqual(
            ScenePosition.derive(projectType: nil, statement: "Cold.", passBrief: nil),
            .weak)
        XCTAssertEqual(
            ScenePosition.derive(projectType: .unknown, statement: "Cold.", passBrief: nil),
            .weak)
        XCTAssertEqual(
            ScenePosition.derive(projectType: nil, statement: "Every scene must turn.",
                                 passBrief: nil),
            .strongDeclared,
            "control: reading as prose is not reading as silent")
    }

    /// Matching is case-insensitive — the writer wrote a sentence, not a key.
    func test_matchingIsCaseInsensitive() {
        XCTAssertEqual(
            ScenePosition.derive(projectType: .novel, statement: "EVERY SCENE MUST TURN.",
                                 passBrief: nil),
            .strongDeclared)
        XCTAssertEqual(
            ScenePosition.derive(projectType: .novel, statement: "Lyric, throughout.",
                                 passBrief: nil),
            ScenePosition.none)
    }

    // MARK: - The whole statement, not its essay half

    /// **The derivation reads the WHOLE statement, rulings included.**
    ///
    /// Task 9's Add-to-intent offer files "Every scene turns." as a dated
    /// ruling under `## Rulings` — that is what the rulings path writes, and it
    /// is the entire point of the offer: the next round strains against a
    /// clause the writer can find in their own statement. Derived over
    /// `StatementEssay.half(of:)` the clause would land where this function
    /// never looks, the offer would reappear on every round forever, and no
    /// strain would ever be raised. The prompt's own essay section is
    /// unaffected and still embeds the essay half alone.
    func test_aClauseFiledUnderRulingsIsFound() {
        let statement = """
            Cold, and never wistful.

            ## Rulings

            - 2026-09-01 — Every scene must turn.
            """
        XCTAssertEqual(
            ScenePosition.derive(projectType: .novel, statement: statement, passBrief: nil),
            .strongDeclared,
            "a clause filed by the Add-to-intent offer lands in the rulings half")
        XCTAssertEqual(
            StatementEssay.half(of: statement).lowercased().contains("every scene must turn"),
            false,
            "control: the essay half genuinely does not carry it")
    }

    /// The same rule from the other side: an opt-out the writer filed as a
    /// ruling closes the table.
    func test_anOptOutFiledUnderRulingsIsAlsoFound() {
        let statement = """
            A novel in fragments.

            ## Rulings

            - 2026-09-01 — This piece is not scene-driven.
            """
        XCTAssertEqual(
            ScenePosition.derive(projectType: .screenplay, statement: statement, passBrief: nil),
            ScenePosition.none)
    }

    // MARK: - The raw values are stored

    /// `Letter.scenePosition` carries `rawValue` into the sidecar, so these
    /// four strings are a disk format and not an implementation detail. A
    /// rename here silently reads back as `nil` on every letter already
    /// written (ADR 0015's shape).
    func test_theRawValuesAreTheSidecarsOwn() {
        XCTAssertEqual(ScenePosition.none.rawValue, "none")
        XCTAssertEqual(ScenePosition.weak.rawValue, "weak")
        XCTAssertEqual(ScenePosition.strongDeclared.rawValue, "strong_declared")
        XCTAssertEqual(ScenePosition.strongDefault.rawValue, "strong_default")
        XCTAssertEqual(ScenePosition(rawValue: "strong_default"), .strongDefault,
                       "…and they decode back")
    }
}
