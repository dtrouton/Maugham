import XCTest
@testable import Maugham

/// Task 6: `language_overrides` on PublishConfig, `effectiveMetadata(language:)`,
/// the `{language}` filename token + auto-suffix collision guard, and
/// `Publication.language`. The load-bearing test is decode tolerance: an old
/// config.json / publications.jsonl written before this milestone must still
/// decode, with `languageOverrides` defaulting to `[:]` and `language` to nil.
final class PublishConfigLanguageTests: XCTestCase {

    // MARK: - decode tolerance (RAW JSON, never round-tripped through the new encoder)

    func testOldConfig_withoutLanguageOverrides_decodesToEmpty() throws {
        // Hand-written fixture that predates language_overrides. The top-level
        // PublishConfig.init(from:) must decodeIfPresent the new key so this
        // survives with every other field intact.
        let json = """
        {
          "schema_version": 1,
          "metadata": {
            "title": "Stories from the Edge",
            "subtitle": null,
            "author": "Denver Trouton",
            "copyright": null,
            "isbn": null,
            "publisher": null,
            "year": 2026,
            "language": "en",
            "keywords": ["fiction"]
          },
          "outputs": {
            "directory": "Exports",
            "filename_template": "{title}-v{version}{label_suffix}.{ext}",
            "sanitize_spaces": false,
            "formats_enabled": ["pdf", "epub"]
          },
          "cover": { "path": "cover.jpg", "epub_specific_path": null },
          "sections": {
            "p_abc123": { "title_override": "Opening", "start_on": "recto", "include_in_toc": true }
          },
          "epub_overrides": { "metadata": {}, "cover": null },
          "next_version": "0.3",
          "active_label_hint": "galley"
        }
        """
        let config = try JSONDecoder().decode(PublishConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.languageOverrides, [:])
        // Every other field intact.
        XCTAssertEqual(config.metadata.title, "Stories from the Edge")
        XCTAssertEqual(config.metadata.year, 2026)
        XCTAssertEqual(config.metadata.keywords, ["fiction"])
        XCTAssertEqual(config.nextVersion, "0.3")
        XCTAssertEqual(config.activeLabelHint, "galley")
        XCTAssertEqual(config.sections["p_abc123"]?.startOn, .recto)
    }

    // MARK: - Task 1: imprints/template/imprint decode-tolerant + resolved-only encode

    func testOldConfig_withoutImprints_decodesToEmptyAndReencodesIdentically() throws {
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
        let json = try JSONEncoder().encode(config)
        let s = String(data: json, encoding: .utf8) ?? ""
        XCTAssertFalse(s.contains("\"imprints\""), "should not encode empty imprints: \(s)")
        XCTAssertFalse(s.contains("\"template\""), "should not encode default template: \(s)")
        XCTAssertFalse(s.contains("\"imprint\""), "should not encode nil imprint: \(s)")

        let decoded = try JSONDecoder().decode(PublishConfig.self, from: json)
        XCTAssertEqual(decoded.imprints, [:])
        XCTAssertEqual(decoded.template, "template.tex")
        XCTAssertNil(decoded.imprint)

        let reencoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(PublishConfig.self, from: reencoded)
        XCTAssertEqual(redecoded, decoded)
    }

    func testResolvedFields_encodeOnlyWhenSet() throws {
        let cfg = PublishConfig(
            metadata: .init(title: "T", author: "A"),
            template: "special.tex",
            imprint: "x"
        )
        let data = try JSONEncoder().encode(cfg)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("\"template\":\"special.tex\""), "expected explicit template: \(s)")
        XCTAssertTrue(s.contains("\"imprint\":\"x\""), "expected explicit imprint: \(s)")

        let defaultCfg = PublishConfig(metadata: .init(title: "T", author: "A"))
        let defaultData = try JSONEncoder().encode(defaultCfg)
        let defaultS = String(data: defaultData, encoding: .utf8) ?? ""
        XCTAssertFalse(defaultS.contains("\"template\""), "default template should not encode: \(defaultS)")
        XCTAssertFalse(defaultS.contains("\"imprint\""), "nil imprint should not encode: \(defaultS)")
    }

    func testLanguageOverrides_roundTrip() throws {
        var cfg = PublishConfig(metadata: .init(title: "Book", author: "A"))
        cfg.languageOverrides["fr"] = .init(metadata: ["title": "Livre"])
        let data = try JSONEncoder().encode(cfg)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"language_overrides\""))
        let back = try JSONDecoder().decode(PublishConfig.self, from: data)
        XCTAssertEqual(back.languageOverrides["fr"]?.metadata["title"], "Livre")
        XCTAssertEqual(back, cfg)
    }

    // MARK: - effectiveMetadata precedence

    func testEffectiveMetadata_nilLanguage_returnsUnchanged() {
        let cfg = PublishConfig(metadata: .init(title: "Original", author: "Denver", language: "en"))
        XCTAssertEqual(cfg.effectiveMetadata(language: nil), cfg.metadata)
    }

    func testEffectiveMetadata_appliesOverrideAndInherits() {
        var cfg = PublishConfig(
            metadata: .init(title: "Original", author: "Denver", year: 2026, language: "en", keywords: ["one"]))
        cfg.languageOverrides["fr"] = .init(metadata: [
            "title": "Traduit",
            "year": "2027",
            "keywords": "un, deux , trois",
        ])
        let m = cfg.effectiveMetadata(language: "fr")
        XCTAssertEqual(m.title, "Traduit")           // overridden
        XCTAssertEqual(m.author, "Denver")           // inherited
        XCTAssertEqual(m.year, 2027)                 // Int-parsed
        XCTAssertEqual(m.keywords, ["un", "deux", "trois"])  // comma-split + trimmed
        XCTAssertEqual(m.language, "fr")             // dc:language = tag
    }

    func testEffectiveMetadata_tagAppliedWithNoOverrideEntry() {
        let cfg = PublishConfig(metadata: .init(title: "Original", author: "Denver", language: "en"))
        // No override entry for "fr" — but language still set to the tag.
        let m = cfg.effectiveMetadata(language: "fr")
        XCTAssertEqual(m.language, "fr")
        XCTAssertEqual(m.title, "Original")
    }

    func testEffectiveMetadata_explicitLanguageKeyBeatsTag() {
        var cfg = PublishConfig(metadata: .init(title: "T", author: "A", language: "en"))
        cfg.languageOverrides["de"] = .init(metadata: ["language": "de-DE"])
        // An explicit `language` key in the override dict wins over the raw tag.
        XCTAssertEqual(cfg.effectiveMetadata(language: "de").language, "de-DE")
    }

    func testEffectiveMetadata_unparseableYearIgnored() {
        var cfg = PublishConfig(metadata: .init(title: "T", author: "A", year: 2026, language: "en"))
        cfg.languageOverrides["fr"] = .init(metadata: ["year": "not-a-year"])
        XCTAssertEqual(cfg.effectiveMetadata(language: "fr").year, 2026)  // inherited, unparseable ignored
    }

    // MARK: - {language} filename token

    func testFilename_languageTokenSubstituted() {
        var cfg = PublishConfig(metadata: .init(title: "Book", author: "A"))
        cfg.outputs.filenameTemplate = "{title}-{language}-v{version}.{ext}"
        let name = OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil, language: "fr")
        XCTAssertEqual(name, "Book-fr-v0.1.pdf")
    }

    func testFilename_languageTokenEmptyWhenNil() {
        var cfg = PublishConfig(metadata: .init(title: "Book", author: "A"))
        cfg.outputs.filenameTemplate = "{title}{language}-v{version}.{ext}"
        let name = OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil, language: nil)
        XCTAssertEqual(name, "Book-v0.1.pdf")
    }

    // MARK: - no-token auto-suffix collision guard

    func testFilename_autoSuffix_whenTemplateLacksLanguageToken() {
        // Default template has no {language}; a language edition must not collide
        // with the source edition — insert -<lang> before the extension.
        let cfg = PublishConfig(metadata: .init(title: "Book", author: "A"))
        let name = OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil, language: "fr")
        XCTAssertEqual(name, "Book-v0.1-fr.pdf")
    }

    func testFilename_noAutoSuffix_whenLanguageNil() {
        let cfg = PublishConfig(metadata: .init(title: "Book", author: "A"))
        let name = OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil, language: nil)
        XCTAssertEqual(name, "Book-v0.1.pdf")
    }

    func testFilename_autoSuffix_withLabel() {
        let cfg = PublishConfig(metadata: .init(title: "Book", author: "A"))
        let name = OutputFilenameBuilder.make(config: cfg, format: .epub, label: "galley", language: "de")
        XCTAssertEqual(name, "Book-v0.1-galley-de.epub")
    }

    // MARK: - {imprint} filename token (Task 4)
    //
    // Same shape as {language}: substituted when present, dangling separator
    // stripped when absent, and a template lacking the token gets an
    // auto-suffix collision guard so an imprint's compile can't overwrite
    // the book's own file.

    func testFilename_imprintTokenSubstituted() {
        var cfg = PublishConfig(
            metadata: .init(title: "Book", author: "A"), imprint: "special-edition")
        cfg.outputs.filenameTemplate = "{title}-{imprint}-v{version}.{ext}"
        let name = OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil, language: nil)
        XCTAssertEqual(name, "Book-special-edition-v0.1.pdf")
    }

    func testFilename_imprintTokenEmptyWhenNil() {
        var cfg = PublishConfig(metadata: .init(title: "Book", author: "A"))
        cfg.outputs.filenameTemplate = "{title}-v{version}-{imprint}.{ext}"
        let name = OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil, language: nil)
        XCTAssertEqual(name, "Book-v0.1.pdf", "the book's own compile drops the dangling separator")
    }

    func testFilename_imprintAutoSuffix_whenTemplateLacksImprintToken() {
        // Default template has no {imprint}; an imprint's compile must not
        // collide with the book's own file — insert -<imprint> before the
        // extension.
        let cfg = PublishConfig(
            metadata: .init(title: "Book", author: "A"), imprint: "special-edition")
        let name = OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil, language: nil)
        XCTAssertEqual(name, "Book-v0.1-special-edition.pdf")
    }

    func testFilename_noImprintAutoSuffix_whenImprintNil() {
        // The control: the book's own filename is unaffected by the guard.
        let cfg = PublishConfig(metadata: .init(title: "Book", author: "A"))
        let name = OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil, language: nil)
        XCTAssertEqual(name, "Book-v0.1.pdf")
    }

    func testFilename_guardOrder_imprintThenLanguage() {
        // Both guards fire on a template with neither token: the imprint
        // guard runs first (nearer the version), the language guard second
        // (nearer the extension) — "Title-v0.1-special-sr.pdf".
        var cfg = PublishConfig(
            metadata: .init(title: "Title", author: "A"), imprint: "special")
        cfg.nextVersion = "0.1"
        let name = OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil, language: "sr")
        XCTAssertEqual(name, "Title-v0.1-special-sr.pdf")
    }

    // MARK: - Publication decode tolerance

    func testPublication_withoutLanguage_decodesToNil() throws {
        // A publications.jsonl line written before this milestone.
        let json = """
        {"publication_id":"pub1","version":"0.1","label":null,"format":"pdf",
         "output_path":"Exports/Book-v0.1.pdf","snapshot_id":"s1","checkpoint_id":"c1",
         "republished_from":null,"compiled_at":0,"maugham_version":"0.24.0","tectonic_version":"0.15"}
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let pub = try dec.decode(Publication.self, from: Data(json.utf8))
        XCTAssertNil(pub.language)
        XCTAssertEqual(pub.publicationID, "pub1")
    }

    func testPublication_withLanguage_roundTrips() throws {
        let pub = Publication(
            publicationID: "p", version: "0.1", label: nil, format: .pdf,
            outputPath: "x", snapshotID: "s", checkpointID: "c", republishedFrom: nil,
            compiledAt: Date(timeIntervalSince1970: 0), maughamVersion: "0.24.0",
            tectonicVersion: "0.15", language: "fr")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let back = try dec.decode(Publication.self, from: enc.encode(pub))
        XCTAssertEqual(back.language, "fr")
    }

    // MARK: - validator

    func testValidator_rejectsUppercaseLanguageKey() {
        var cfg = PublishConfig(metadata: .init(title: "T", author: "A"))
        cfg.languageOverrides["ES"] = .init(metadata: [:])
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains(where: { $0.field == "language_overrides.ES" }),
                      "expected a validation error for the invalid tag key, got: \(errs)")
    }

    func testValidator_acceptsValidLanguageKey() {
        var cfg = PublishConfig(metadata: .init(title: "T", author: "A"))
        cfg.languageOverrides["fr"] = .init(metadata: ["title": "Livre"])
        cfg.languageOverrides["pt-br"] = .init(metadata: [:])
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertFalse(errs.contains(where: { $0.field.hasPrefix("language_overrides") }),
                       "valid tags flagged: \(errs)")
    }
}
