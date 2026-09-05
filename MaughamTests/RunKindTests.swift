import XCTest
@testable import Maugham

/// **Which loop asked for a run** (two loops P1 Task 1).
///
/// The mint is a total function over `Persona` and nothing else, so it is
/// assertable without a window, a run or a store — which is the point: the one
/// production site that calls it (`CompilerRunModifier`) is a `ViewModifier`
/// no test can mount, and a census is all that guards the call. What the
/// census cannot check is the ANSWER, and that is what this file is.
final class RunKindTests: XCTestCase {

    /// **Every persona, named individually.** Written over `Persona.allCases`
    /// so a fifth persona fails to compile here rather than quietly defaulting
    /// to `.check` — the `switch` in `RunKind.of(persona:)` is exhaustive, and
    /// this is the assertion that says a new case must be decided rather than
    /// inherited.
    func test_reviewMintsARound_andEveryOtherPersonaMintsACheck() {
        XCTAssertEqual(RunKind.of(persona: .review), .round,
                       "Review's Run round is the round verb")
        XCTAssertEqual(RunKind.of(persona: .author), .check,
                       "Author's \u{2318}R is the check verb")
        XCTAssertEqual(RunKind.of(persona: .plan), .check,
                       "Plan has no run key of its own; a run reaching the "
                       + "orchestrator from it is a check")
        XCTAssertEqual(RunKind.of(persona: .publish), .check,
                       "…and so is one from Publish")

        // The census over the enum: every case is named above. A fifth persona
        // makes this fail rather than letting the four assertions above pass
        // over a case nobody decided.
        XCTAssertEqual(Persona.allCases, [.plan, .author, .review, .publish],
                       "a new persona must be given a RunKind above rather than "
                       + "inheriting .check by omission")
    }

    /// The raw values are a disk format — `CompilerRun.kind` is written into
    /// the per-document sidecar — so a rename reads back as an unrecognised
    /// word on every record already written. Pinned for the reason
    /// `DraftStage`'s and `SynthesisSource`'s are.
    func test_theRawValuesAreTheSidecarsWords() {
        XCTAssertEqual(RunKind.check.rawValue, "check")
        XCTAssertEqual(RunKind.round.rawValue, "round")
        XCTAssertEqual(RunKind(rawValue: "check"), .check)
        XCTAssertEqual(RunKind(rawValue: "round"), .round)
    }
}
