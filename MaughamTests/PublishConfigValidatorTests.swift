import XCTest
@testable import Maugham

final class PublishConfigValidatorTests: XCTestCase {

    func testAccepts_validConfig() {
        let cfg = PublishConfig(metadata: .init(title: "X", author: "Y"))
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.isEmpty)
    }

    func testRejects_emptyTitle() {
        var cfg = PublishConfig()
        cfg.metadata.title = ""
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains(where: { $0.field == "metadata.title" }))
    }

    func testRejects_unknownStartOn() throws {
        // Decoder enforces enum, so we test via raw JSON.
        let json = """
        {"title_override":null,"start_on":"sideways","include_in_toc":true}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(
            PublishConfig.Section.self, from: Data(json.utf8)))
    }

    func testRejects_negativeYear() {
        var cfg = PublishConfig()
        cfg.metadata.year = -100
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains(where: { $0.field == "metadata.year" }))
    }

    func testRejects_unsupportedSchemaVersion() {
        var cfg = PublishConfig()
        cfg.schemaVersion = 99
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains(where: { $0.field == "schema_version" }))
    }

    func testBumpVersion_minor_succeeds() {
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "0.3"), "0.4")
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "1.9"), "1.10")
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "0.1"), "0.2")
    }

    func testBumpVersion_invalidInput_resetsToBaseline() {
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "garbage"), "0.1")
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: ""), "0.1")
    }
}
