import XCTest
@testable import Maugham

/// Task 10: language-suffixed template/style/piece-file resolution.
///
/// `LanguageSuffixedFile.resolve("template.tex", language: "es", under: dir)`
/// returns `"template.es.tex"` when that suffixed file exists under `dir`,
/// otherwise the base name. A `nil`/empty language always returns the base.
///
/// Written BEFORE the implementation (TDD) — starts red, goes green once
/// `LanguageSuffixedFile` lands.
final class LanguageSuffixedFileTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func touch(_ name: String, in dir: URL) throws {
        try "x".write(to: dir.appendingPathComponent(name),
                      atomically: true, encoding: .utf8)
    }

    // MARK: - resolve() core

    func test_present_resolvesToSuffixed() throws {
        try touch("template.es.tex", in: tmp)
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("template.tex", language: "es", under: tmp),
            "template.es.tex",
            "existing suffixed file should win")
    }

    func test_absent_fallsBackToBase() throws {
        // Only the base exists (or nothing) — no suffixed variant.
        try touch("template.tex", in: tmp)
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("template.tex", language: "es", under: tmp),
            "template.tex",
            "missing suffixed file should fall back to base")
    }

    func test_nilLanguage_returnsBase() throws {
        // Even when a suffixed file exists, nil language must return base.
        try touch("template.es.tex", in: tmp)
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("template.tex", language: nil, under: tmp),
            "template.tex",
            "nil language must never suffix")
    }

    func test_emptyLanguage_returnsBase() throws {
        try touch("template..tex", in: tmp)   // what empty-language suffixing would produce
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("template.tex", language: "", under: tmp),
            "template.tex",
            "empty language must behave like nil")
    }

    func test_noExtension_suffixesBeforeNothing() throws {
        try touch("template.es", in: tmp)
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("template", language: "es", under: tmp),
            "template.es",
            "extensionless name suffixes to name.<lang>")
    }

    // MARK: - application-point filenames

    func test_pdfTemplatePick() throws {
        try touch("template.fr.tex", in: tmp)
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("template.tex", language: "fr", under: tmp),
            "template.fr.tex")
        // A different language with no matching file falls back.
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("template.tex", language: "de", under: tmp),
            "template.tex")
    }

    /// Task 5: the compiler hands `config.template` to the resolver, not the
    /// literal `"template.tex"`, so an imprint's own template takes the
    /// language suffix by exactly the same rule the book's does.
    func test_imprintTemplatePick() throws {
        try touch("special.sr.tex", in: tmp)
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("special.tex", language: "sr", under: tmp),
            "special.sr.tex",
            "an imprint template suffixes like any other")
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("special.tex", language: nil, under: tmp),
            "special.tex",
            "the source edition of an imprint keeps the base name")
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("special.tex", language: "de", under: tmp),
            "special.tex",
            "a language with no variant beside it falls back to the base")
    }

    /// A template may live in a subdirectory (`templates/special.tex`); the
    /// suffix still goes before the extension and the directory is preserved,
    /// and existence is checked at the joined path.
    func test_imprintTemplateInASubdirectory() throws {
        let templates = tmp.appendingPathComponent("templates", isDirectory: true)
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        try touch("special.sr.tex", in: templates)
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("templates/special.tex", language: "sr", under: tmp),
            "templates/special.sr.tex",
            "the suffix goes before the extension, inside the subdirectory")
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("templates/special.tex", language: "de", under: tmp),
            "templates/special.tex",
            "an absent variant in a subdirectory falls back to the base path")
    }

    func test_cssPick() throws {
        try touch("styles.es.css", in: tmp)
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("styles.css", language: "es", under: tmp),
            "styles.es.css")
        XCTAssertEqual(
            LanguageSuffixedFile.resolve("styles.css", language: nil, under: tmp),
            "styles.css")
    }

    // MARK: - style_file rewrite honors existence

    func test_styleFileRewrite_suffixedWhenPresent() throws {
        let pieces = tmp.appendingPathComponent("pieces", isDirectory: true)
        try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
        try touch("october-passed-me-by.es.tex", in: pieces)

        var cfg = PublishConfig()
        var sec = PublishConfig.Section()
        sec.styleFile = "october-passed-me-by.tex"
        cfg.sections["p1"] = sec

        let out = LanguageSuffixedFile.resolvingStyleFiles(
            in: cfg, language: "es", publishDir: tmp)
        XCTAssertEqual(out.sections["p1"]?.styleFile, "october-passed-me-by.es.tex",
                       "present suffixed piece style should be picked")
    }

    func test_styleFileRewrite_baseWhenAbsent() throws {
        let pieces = tmp.appendingPathComponent("pieces", isDirectory: true)
        try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
        try touch("october-passed-me-by.tex", in: pieces)   // only base exists

        var cfg = PublishConfig()
        var sec = PublishConfig.Section()
        sec.styleFile = "october-passed-me-by.tex"
        cfg.sections["p1"] = sec

        let out = LanguageSuffixedFile.resolvingStyleFiles(
            in: cfg, language: "es", publishDir: tmp)
        XCTAssertEqual(out.sections["p1"]?.styleFile, "october-passed-me-by.tex",
                       "absent suffixed piece style should keep base")
    }

    func test_styleFileRewrite_nilLanguage_unchanged() throws {
        let pieces = tmp.appendingPathComponent("pieces", isDirectory: true)
        try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
        try touch("october-passed-me-by.es.tex", in: pieces)

        var cfg = PublishConfig()
        var sec = PublishConfig.Section()
        sec.styleFile = "october-passed-me-by.tex"
        cfg.sections["p1"] = sec

        let out = LanguageSuffixedFile.resolvingStyleFiles(
            in: cfg, language: nil, publishDir: tmp)
        XCTAssertEqual(out, cfg, "nil language must leave config untouched")
    }

    // MARK: - safe-filename dots (brief point 4)

    func test_safeFilename_acceptsLanguageSuffixDot() {
        // The suffixed piece name that resolution produces must itself pass the
        // LaTeX \input{} safety guard — dots are allowed, only `..`/`/` are not.
        XCTAssertNotNil(LaTeXSafeFilename("october-passed-me-by.es"),
                        "single dots (incl. the language suffix dot) are safe")
        XCTAssertNotNil(LaTeXSafeFilename("october-passed-me-by.es.tex"),
                        "double dots-as-separators are safe (no '..' substring)")
    }

    func test_safeFilename_stillRejectsInjection() {
        XCTAssertNil(LaTeXSafeFilename("october..es"),
                     "'..' traversal must still be rejected")
        XCTAssertNil(LaTeXSafeFilename("dir/october.es.tex"),
                     "'/' path separator must still be rejected")
    }
}
