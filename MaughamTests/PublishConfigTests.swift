import XCTest
@testable import Maugham

final class PublishConfigTests: XCTestCase {

    func testRoundTrips_minimalConfig() throws {
        let config = PublishConfig(
            schemaVersion: 1,
            metadata: .init(title: "Test Book", author: "Author"),
            outputs: .init(),
            cover: .init(),
            sections: [:],
            epubOverrides: .init(),
            nextVersion: "0.1",
            activeLabelHint: nil
        )
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PublishConfig.self, from: encoded)
        XCTAssertEqual(decoded, config)
    }

    func testDecodes_fullConfig() throws {
        let json = """
        {
          "schema_version": 1,
          "metadata": {
            "title": "Stories from the Edge",
            "subtitle": null,
            "author": "Denver Trouton",
            "copyright": "© 2026 Denver Trouton",
            "isbn": null,
            "publisher": null,
            "year": 2026,
            "language": "en",
            "keywords": ["fiction", "collection"]
          },
          "outputs": {
            "directory": "Exports",
            "filename_template": "{title}-v{version}{label_suffix}.{ext}",
            "sanitize_spaces": false,
            "formats_enabled": ["pdf", "epub"]
          },
          "cover": {
            "path": "cover.jpg",
            "epub_specific_path": null
          },
          "sections": {
            "p_abc123": {
              "title_override": "Opening",
              "start_on": "recto",
              "include_in_toc": true
            }
          },
          "epub_overrides": {
            "metadata": {},
            "cover": null
          },
          "next_version": "0.3",
          "active_label_hint": "galley"
        }
        """
        let config = try JSONDecoder().decode(PublishConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.metadata.title, "Stories from the Edge")
        XCTAssertEqual(config.metadata.keywords, ["fiction", "collection"])
        XCTAssertEqual(config.nextVersion, "0.3")
        XCTAssertEqual(config.sections["p_abc123"]?.startOn, .recto)
        XCTAssertEqual(config.sections["p_abc123"]?.titleOverride, "Opening")
    }

    func testStartOn_decodesAllValues() throws {
        for raw in ["any", "recto", "verso"] {
            let json = "{\"title_override\": null, \"start_on\": \"\(raw)\", \"include_in_toc\": true}"
            let section = try JSONDecoder().decode(PublishConfig.Section.self, from: Data(json.utf8))
            XCTAssertEqual(section.startOn.rawValue, raw)
        }
    }

    func testFormats_decodesEnabledArray() throws {
        let outputs = try JSONDecoder().decode(
            PublishConfig.Outputs.self,
            from: Data("{\"directory\":\"Exports\",\"filename_template\":\"x\",\"sanitize_spaces\":false,\"formats_enabled\":[\"pdf\",\"epub\"]}".utf8)
        )
        XCTAssertEqual(outputs.formatsEnabled, [.pdf, .epub])
    }

    // MARK: - encoder emits explicit nulls (shape preservation)

    func testEncoder_emitsExplicitNullsForOptionalMetadata() throws {
        // External tester surfaced config.json shrinking by ~134 B on
        // every compile because the default Codable encoder omitted nil
        // fields. With encodeAlways, all optional fields stay present
        // (as null) in the output JSON.
        let cfg = PublishConfig()   // defaults — all optional fields nil
        let data = try JSONEncoder().encode(cfg)
        let s = String(data: data, encoding: .utf8) ?? ""
        for key in [
            "\"subtitle\":null",
            "\"copyright\":null",
            "\"isbn\":null",
            "\"publisher\":null",
            "\"year\":null",
            "\"active_label_hint\":null",
        ] {
            XCTAssertTrue(s.contains(key),
                          "missing explicit null for \(key) in: \(s)")
        }
    }

    func testEncoder_preservesShape_acrossRoundTrip() throws {
        let cfg = PublishConfig()
        let encoded = try JSONEncoder().encode(cfg)
        let dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        let meta = dict["metadata"] as? [String: Any] ?? [:]
        XCTAssertTrue(meta.keys.contains("subtitle"))
        XCTAssertTrue(meta["subtitle"] is NSNull)
        XCTAssertTrue(meta.keys.contains("year"))
        XCTAssertTrue(meta["year"] is NSNull)
    }
}
