import XCTest
import MaughamCore
@testable import Maugham

/// **THE BRIDGE, AND TASK 7 DELETES THIS WHOLE FILE.**
///
/// Shell-finish stage 2b Task 6 re-bases *"the centre column is the planning
/// canvas"* off the binder segment and onto the persona, one task before the
/// segment enum dies. Between the two tasks the app can be asked the question
/// both ways, and this file is the proof that it answers the same — over every
/// `(persona, segment)` pair a writer can actually reach.
///
/// **The old rule is TRANSCRIBED here rather than left in production.**
/// `BinderSegment.centresTheCanvas` had seven callers and now has none, and a
/// predicate kept alive solely so a test can compare against it is a second
/// spelling with no reader — exactly what this milestone is removing. So the
/// rule it used to carry (`.canvas` and `.tree`, and nothing else) lives in
/// `oldRule` below, as an exhaustive `switch` with no `default:` so that a new
/// segment has to be answered for here too while the enum still stands.
///
/// **What "reachable" means, and it is not `allCases × allCases`.** The two
/// spellings CANNOT agree on every pair — one is a function of the segment
/// alone and the other reads the persona first — and the pairs where they part
/// are pairs no writer can be in. Plan on `.manuscript` is the sharp one: Plan's
/// picker does not offer it, `PersonaModifier.applyPersonaChange` coerces onto
/// the destination's own list, and `ManuscriptNavigation` moves the writer to
/// Author before it forces the document home. So the pair set is built from the
/// registries plus the two forced arrivals `Persona.author`'s own doc comment
/// records, rather than from `allCases`.
@MainActor
final class PersonaCanvasBasisBridgeTests: XCTestCase {

    /// The rule `BinderSegment.centresTheCanvas` carried until Task 6, verbatim.
    ///
    /// Exhaustive with no `default:` on purpose: while `BinderSegment` stands, a
    /// new case must state whether it drew the board, or the bridge would call
    /// it equivalent by inheriting "no" from a `default:` on one side only.
    private func oldRule(_ segment: BinderSegment) -> Bool {
        switch segment {
        case .canvas, .tree: return true
        case .manuscript, .research, .palette, .scenes, .trash, .find: return false
        }
    }

    /// Every `(persona, segment, projectType)` a writer can be in.
    ///
    /// Two sources, and the second is the one a registry sweep would miss.
    /// `binderSegments(for:)` is what the picker offers. The two extras are the
    /// asymmetry recorded at `Persona.author`'s case: `openResearchItem` and
    /// `handleShowLatestMCPNote` still force `.research` in Author, and a
    /// project last quit on the palette wall restores `.palette` there once.
    /// Both render, because `BinderSegmentPicker.visibleSegments` appends the
    /// current selection — so both are reachable states this bridge has to
    /// cover.
    private var reachablePairs: [(Persona, BinderSegment, ProjectType)] {
        var pairs: [(Persona, BinderSegment, ProjectType)] = []
        for type in ProjectType.allCases {
            for persona in Persona.allCases {
                for segment in persona.binderSegments(for: type) {
                    pairs.append((persona, segment, type))
                }
            }
            pairs.append((.author, .research, type))
            pairs.append((.author, .palette, type))
        }
        return pairs
    }

    /// **The equivalence.** Every reachable pair answers the same both ways.
    func test_theNewBasisReproducesTheOldSegmentRuleEverywhereAWriterCanBe() {
        for (persona, segment, type) in reachablePairs {
            XCTAssertEqual(
                persona.centresTheCanvas(interimSegment: segment),
                oldRule(segment),
                "\(persona)/\(segment)/\(type): the persona basis disagrees "
                + "with the segment rule it replaces — this re-base was meant "
                + "to be behaviour-neutral")
        }
    }

    /// **The anti-vacuity control.** A bridge over a pair set that had gone
    /// empty, or over two predicates that both answered a constant, would pass
    /// in silence. So the set is asked to contain both answers, and each side
    /// is asked to produce both.
    func test_theBridgeIsNotVacuous() {
        let pairs = reachablePairs
        XCTAssertFalse(pairs.isEmpty, "the reachable-pair set is empty")
        XCTAssertTrue(pairs.contains { oldRule($0.1) },
                      "no reachable pair centres the canvas — the old rule "
                      + "cannot be being exercised")
        XCTAssertTrue(pairs.contains { !oldRule($0.1) },
                      "every reachable pair centres the canvas — the bridge "
                      + "would pass against a constant-true predicate")
        XCTAssertTrue(pairs.contains { $0.0.centresTheCanvas(interimSegment: $0.1) })
        XCTAssertTrue(pairs.contains { !$0.0.centresTheCanvas(interimSegment: $0.1) })
    }

    /// **The interim term is doing work, and this is what says so.**
    ///
    /// The composite is `persona.centresTheCanvas` MINUS the segments Plan
    /// still offers whose centre is an old pane. Drop the second term — the
    /// obvious "simplification", and what Task 7 will legitimately do once
    /// those panes are gone — and Plan on Research or Palette starts claiming
    /// the board: the region inspector over a research note, `Promote…`
    /// enabled over the palette wall, the canvas mounted where `ResearchView`'s
    /// selection should be. The brief for this task asserted the two spellings
    /// were *exactly* equivalent; these two rows are where that is false, and
    /// they are the reason the interim parameter exists at all.
    func test_plansOldPanesAreWhyTheInterimTermIsStillThere() {
        for segment in [BinderSegment.research, .palette] {
            XCTAssertTrue(Persona.plan.binderSegments(for: .novel).contains(segment),
                          "\(segment) has left Plan's picker — if Task 7 has "
                          + "run, this whole file goes with it")
            XCTAssertFalse(
                Persona.plan.centresTheCanvas(interimSegment: segment),
                "\(segment)'s centre column is the old pane, not the board — "
                + "dropping the interim term here is a behaviour change, not a "
                + "simplification")
            XCTAssertTrue(Persona.plan.centresTheCanvas,
                          "control: the persona half says yes, so the second "
                          + "term is what produced the no above")
        }
    }
}
