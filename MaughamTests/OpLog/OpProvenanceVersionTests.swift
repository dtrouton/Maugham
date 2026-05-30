import XCTest
import MaughamCore

/// `Op.Provenance.appVersion` / `osVersion` are additive, phone-only forensic
/// fields. Existing op logs (no `app_version`/`os_version`) must decode with
/// both nil, and populated ones must round-trip through the `app_version` /
/// `os_version` snake_case keys.
final class OpProvenanceVersionTests: XCTestCase {
    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        return e
    }
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return d
    }

    func test_legacyProvenanceWithoutVersionFields_decodesNil() throws {
        // A provenance blob predating the fields — must not fail to decode.
        let json = #"{"session_id":"s1","source_annotation_id":"a1","user_response":"no"}"#
        let prov = try decoder().decode(Op.Provenance.self, from: Data(json.utf8))
        XCTAssertNil(prov.appVersion)
        XCTAssertNil(prov.osVersion)
        XCTAssertEqual(prov.userResponse, "no")
    }

    func test_versionFields_roundTripThroughSnakeCaseKeys() throws {
        let prov = Op.Provenance(
            sessionId: "s1", sourceAnnotationId: "a1", userResponse: "no",
            appVersion: "0.1.0", osVersion: "iOS 17.4")
        let data = try encoder().encode(prov)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"app_version\":\"0.1.0\""), json)
        XCTAssertTrue(json.contains("\"os_version\":\"iOS 17.4\""), json)

        let decoded = try decoder().decode(Op.Provenance.self, from: data)
        XCTAssertEqual(decoded, prov)
    }
}
