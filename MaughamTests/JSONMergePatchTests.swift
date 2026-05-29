import XCTest
@testable import Maugham

final class JSONMergePatchTests: XCTestCase {

    func testReplaces_topLevelScalar() throws {
        let original = #"{"a":1,"b":2}"#.data(using: .utf8)!
        let patch    = #"{"a":99}"#.data(using: .utf8)!
        let merged = try JSONMergePatch.apply(patch: patch, to: original)
        XCTAssertEqual(try canon(merged), try canon(#"{"a":99,"b":2}"#.data(using: .utf8)!))
    }

    func testNullDeletes_key() throws {
        let original = #"{"a":1,"b":2}"#.data(using: .utf8)!
        let patch    = #"{"a":null}"#.data(using: .utf8)!
        let merged = try JSONMergePatch.apply(patch: patch, to: original)
        XCTAssertEqual(try canon(merged), try canon(#"{"b":2}"#.data(using: .utf8)!))
    }

    func testRecursiveMerge_objects() throws {
        let original = #"{"o":{"a":1,"b":2}}"#.data(using: .utf8)!
        let patch    = #"{"o":{"a":99,"c":3}}"#.data(using: .utf8)!
        let merged = try JSONMergePatch.apply(patch: patch, to: original)
        XCTAssertEqual(try canon(merged), try canon(#"{"o":{"a":99,"b":2,"c":3}}"#.data(using: .utf8)!))
    }

    func testArrays_replacedWhole() throws {
        let original = #"{"a":[1,2,3]}"#.data(using: .utf8)!
        let patch    = #"{"a":[9]}"#.data(using: .utf8)!
        let merged = try JSONMergePatch.apply(patch: patch, to: original)
        XCTAssertEqual(try canon(merged), try canon(#"{"a":[9]}"#.data(using: .utf8)!))
    }

    private func canon(_ data: Data) throws -> String {
        let any = try JSONSerialization.jsonObject(with: data)
        let out = try JSONSerialization.data(withJSONObject: any, options: [.sortedKeys])
        return String(data: out, encoding: .utf8)!
    }
}
