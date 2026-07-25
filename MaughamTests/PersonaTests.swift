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
