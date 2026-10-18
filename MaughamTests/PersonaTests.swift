import XCTest
@testable import Maugham

final class PersonaTests: XCTestCase {
    func test_allCases_areInStageOrder() {
        XCTAssertEqual(Persona.allCases, [.plan, .author, .review, .publish])
    }

    func test_rawValues_areStableSnakeCaseTokens() {
        XCTAssertEqual(Persona.plan.rawValue, "plan")
        XCTAssertEqual(Persona.author.rawValue, "author")
        XCTAssertEqual(Persona.review.rawValue, "review")
        XCTAssertEqual(Persona.publish.rawValue, "publish")
    }

    func test_shortcutKeys_areOneThroughFourInOrder() {
        XCTAssertEqual(Persona.allCases.map(\.shortcutKey), ["1", "2", "3", "4"])
    }

    // MARK: - The three named gates (foundations plan 4 Task 6)

    /// **Each predicate answers, over every persona, exactly what the literal
    /// it replaced answered** — written out as a table rather than re-derived
    /// from a comparison, so the oracle is not the spelling being retired.
    ///
    /// - `showsPaletteWall` replaced `persona != .plan` in
    ///   `ProjectWindow.showsPaletteWallCentre`;
    /// - `showsIntentStrip` replaced `persona == .author` in both of
    ///   `IntentStrip.line`'s gates;
    /// - `showsExports` replaced `persona != .plan` in both binder toggles'
    ///   Exports footers.
    func test_showsPaletteWall_isEveryPersonaButPlan() {
        let expected: [Persona: Bool] = [.plan: false, .author: true, .review: true, .publish: true]
        for persona in Persona.allCases {
            XCTAssertEqual(persona.showsPaletteWall, expected[persona], "\(persona)")
        }
    }

    func test_showsIntentStrip_isAuthorAlone() {
        let expected: [Persona: Bool] = [.plan: false, .author: true, .review: false, .publish: false]
        for persona in Persona.allCases {
            XCTAssertEqual(persona.showsIntentStrip, expected[persona], "\(persona)")
        }
    }

    func test_showsExports_isEveryPersonaButPlan() {
        let expected: [Persona: Bool] = [.plan: false, .author: true, .review: true, .publish: true]
        for persona in Persona.allCases {
            XCTAssertEqual(persona.showsExports, expected[persona], "\(persona)")
        }
    }

    /// The tables above name every case, so a fifth persona fails here until
    /// somebody decides its three answers.
    func test_theGateTablesNameEveryPersona() {
        XCTAssertEqual(Persona.allCases.count, 4,
                       "a persona was added — give it a row in each gate table above")
    }

    func test_everyPersona_hasNonEmptyDisplayNameAndIcon() {
        for persona in Persona.allCases {
            XCTAssertFalse(persona.displayName.isEmpty, "\(persona) has no display name")
            XCTAssertFalse(persona.systemImageName.isEmpty, "\(persona) has no icon")
        }
    }

    func test_decode_ofUnrecognisedRawValue_fallsBackToAuthor() throws {
        // Forward tolerance: a project written by a newer build naming a
        // persona this build has never heard of must open in the default
        // rather than refuse. Persona is presentation state, not identity —
        // unlike ResearchRole it does not need lossless round-tripping.
        let json = Data(#""somethingNewer""#.utf8)
        let decoded = try JSONDecoder().decode(Persona.self, from: json)
        XCTAssertEqual(decoded, .author)
    }
}
