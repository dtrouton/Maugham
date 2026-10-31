import XCTest
@testable import MaughamCore

final class BookLanguageTests: XCTestCase {
    private func tag(_ json: String) -> String? { BookLanguage.tag(fromConfigData: Data(json.utf8)) }

    func test_languageIsReadAndOtherKeysTolerated() {
        XCTAssertEqual(tag(#"{"schema_version":3,"outputs":{"pdf":true},"metadata":{"title":"T","language":"es","x":[1]},"extra":null}"#), "es")
    }

    func test_missingOrBlankIsNil() {
        XCTAssertNil(tag(#"{"schema_version":3}"#))
        XCTAssertNil(tag(#"{"metadata":{"title":"T"}}"#))
        XCTAssertNil(tag(#"{"metadata":{"language":"  \n"}}"#))
        XCTAssertNil(tag("not json"))
    }

    func test_tagNormalisesAsTheStoredNormaliserDoes() {
        XCTAssertEqual(tag(#"{"metadata":{"language":" en-GB "}}"#), TableLocale.languageTag(fromStored: " en-GB "))
        XCTAssertEqual(tag(#"{"metadata":{"language":" en-GB "}}"#), "en-GB")
    }

    func test_configURLIsTheDotMaughamPublishConfig() {
        let root = URL(fileURLWithPath: "/tmp/book")
        XCTAssertEqual(BookLanguage.configURL(in: root).path, "/tmp/book/.maugham/publish/config.json")
    }
}
