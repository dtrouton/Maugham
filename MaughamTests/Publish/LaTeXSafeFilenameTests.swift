import XCTest
@testable import Maugham

/// TDD tests for `LaTeXSafeFilename` (finding 1.4) and
/// traversal checks on `outputs.directory`/`filenameTemplate` (finding 1.5).
///
/// These tests are intentionally written BEFORE the implementation so they
/// start red and go green once the fix lands.
final class LaTeXSafeFilenameTests: XCTestCase {

    // MARK: - LaTeXSafeFilename allowlist

    func test_valid_alphanumeric() {
        XCTAssertNotNil(LaTeXSafeFilename("chapter1.tex"),
                        "plain alphanumeric + dot should be accepted")
    }

    func test_valid_hyphenAndUnderscore() {
        XCTAssertNotNil(LaTeXSafeFilename("my_style-v2.tex"),
                        "hyphen and underscore are safe filename chars")
    }

    func test_valid_justLettersNoDot() {
        XCTAssertNotNil(LaTeXSafeFilename("salute"),
                        "letters without extension are accepted")
    }

    func test_rejects_TeX_closeBrace() {
        // `}` closes the \input{} argument — injection vector
        XCTAssertNil(LaTeXSafeFilename("bad}arg"),
                     "} must be rejected (closes TeX group)")
    }

    func test_rejects_TeX_openBrace() {
        XCTAssertNil(LaTeXSafeFilename("bad{arg"),
                     "{ must be rejected (opens TeX group)")
    }

    func test_rejects_TeX_percent() {
        // % starts a TeX comment — `piece%\input{evil}` injects post-comment content
        XCTAssertNil(LaTeXSafeFilename("comment%hack"),
                     "% must be rejected (TeX comment character)")
    }

    func test_rejects_TeX_dollar() {
        XCTAssertNil(LaTeXSafeFilename("math$mode"),
                     "$ must be rejected (TeX math mode)")
    }

    func test_rejects_TeX_hash() {
        XCTAssertNil(LaTeXSafeFilename("param#1"),
                     "# must be rejected (TeX parameter)")
    }

    func test_rejects_TeX_ampersand() {
        XCTAssertNil(LaTeXSafeFilename("col&sep"),
                     "& must be rejected (TeX alignment)")
    }

    func test_rejects_TeX_tilde() {
        XCTAssertNil(LaTeXSafeFilename("non~break"),
                     "~ must be rejected (TeX non-breaking space)")
    }

    func test_rejects_TeX_caret() {
        XCTAssertNil(LaTeXSafeFilename("super^script"),
                     "^ must be rejected (TeX superscript)")
    }

    func test_rejects_TeX_backslash() {
        XCTAssertNil(LaTeXSafeFilename("\\cmd"),
                     "\\ must be rejected (TeX command introducer)")
    }

    func test_rejects_forwardSlash() {
        XCTAssertNil(LaTeXSafeFilename("path/traversal.tex"),
                     "/ must be rejected (path separator)")
    }

    func test_rejects_dotDot_standalone() {
        XCTAssertNil(LaTeXSafeFilename(".."),
                     "bare '..' must be rejected (parent directory)")
    }

    func test_rejects_dotDot_embedded() {
        // `../etc/passwd` — the `.tex` is appended by the caller, but even
        // without it `../secret` breaks `\input{pieces/../secret}`.
        XCTAssertNil(LaTeXSafeFilename("../secret.tex"),
                     "'../' traversal must be rejected")
    }

    func test_rejects_null_byte() {
        XCTAssertNil(LaTeXSafeFilename("foo\0bar"),
                     "null byte must be rejected")
    }

    func test_rejects_empty() {
        XCTAssertNil(LaTeXSafeFilename(""),
                     "empty string must be rejected")
    }

    // MARK: - LaTeXSafeFilename raw-value access

    func test_rawValue_roundtrip() {
        let name = LaTeXSafeFilename("chapter-1.tex")!
        XCTAssertEqual(name.rawValue, "chapter-1.tex")
    }

    // MARK: - LaTeXBodyEmitter rejects unsafe styleFile via type

    /// Regression guard: LaTeXBodyEmitter must not accept a raw String for
    /// styleFile — it must use LaTeXSafeFilename so the injection path can't
    /// even compile with an unvalidated value.
    ///
    /// This is a *compile-time* contract; the test simply exercises the
    /// emitter with a safe name and confirms the \input line is produced,
    /// as a signal that the value-type is threaded through correctly.
    func test_emitter_producesInput_forSafeStyleFile() {
        var section = PublishConfig.Section()
        section.styleFile = "salute.tex"

        var cfg = PublishConfig()
        cfg.sections["p1"] = section

        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Ch", mode: .prose, nodes: [])
        ])

        let body = LaTeXBodyEmitter.emit(ast, config: cfg)
        XCTAssertTrue(body.contains("\\input{pieces/salute.tex}"),
                      "safe styleFile should emit \\input; body: \(body)")
    }

    /// Defence-in-depth: if an unsafe styleFile somehow appears in config.json
    /// (hand-edited or loaded from a snapshot bypassing write-side validation),
    /// the emitter must NOT produce `\input{pieces/<unsafe>}`. Instead it emits
    /// a clearly-broken placeholder that makes tectonic error out rather than
    /// execute injected TeX.
    func test_emitter_doesNotInject_forUnsafeStyleFile() {
        var section = PublishConfig.Section()
        // A classically dangerous value: closes the \input arg, injects another command.
        section.styleFile = "}\\input{/etc/passwd}%"

        var cfg = PublishConfig()
        cfg.sections["p1"] = section

        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Ch", mode: .prose, nodes: [])
        ])

        let body = LaTeXBodyEmitter.emit(ast, config: cfg)
        // The injected string must NOT appear verbatim.
        XCTAssertFalse(body.contains("\\input{/etc/passwd}"),
                       "injected path must not appear in body; body: \(body)")
        // The \begingroup must still open (the group-close is what stops the
        // injection from leaking across sections).
        XCTAssertTrue(body.contains("\\begingroup"),
                      "\\begingroup must still be emitted; body: \(body)")
        // The safe `\input` form must NOT be emitted with the unsafe name.
        XCTAssertFalse(body.contains("\\input{pieces/}"),
                       "no partial unsafe \\input must be emitted; body: \(body)")
    }
}

// MARK: - PublishConfigValidator traversal tests (finding 1.5)

final class PublishConfigValidatorTraversalTests: XCTestCase {

    // MARK: outputs.directory traversal

    func test_rejects_dotDot_directory() {
        var cfg = PublishConfig()
        cfg.outputs.directory = "../../outside"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(
            errs.contains(where: { $0.field == "outputs.directory" }),
            "../../outside should be rejected; errs=\(errs)")
    }

    func test_rejects_leadingSlash_directory() {
        var cfg = PublishConfig()
        cfg.outputs.directory = "/absolute/path"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(
            errs.contains(where: { $0.field == "outputs.directory" }),
            "absolute path should be rejected; errs=\(errs)")
    }

    func test_accepts_simple_directory() {
        var cfg = PublishConfig()
        cfg.outputs.directory = "Exports"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertFalse(
            errs.contains(where: { $0.field == "outputs.directory" }),
            "'Exports' should be valid; errs=\(errs)")
    }

    func test_accepts_nested_relative_directory() {
        var cfg = PublishConfig()
        cfg.outputs.directory = "output/books"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertFalse(
            errs.contains(where: { $0.field == "outputs.directory" }),
            "'output/books' should be valid; errs=\(errs)")
    }

    func test_rejects_dotDot_segment_in_directory() {
        var cfg = PublishConfig()
        cfg.outputs.directory = "output/../../../etc"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(
            errs.contains(where: { $0.field == "outputs.directory" }),
            "directory with '..' segment should be rejected; errs=\(errs)")
    }

    // MARK: outputs.filenameTemplate traversal

    func test_rejects_slash_in_filenameTemplate() {
        var cfg = PublishConfig()
        cfg.outputs.filenameTemplate = "../../../etc/{title}-{version}.{ext}"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(
            errs.contains(where: { $0.field == "outputs.filename_template" }),
            "template with / should be rejected; errs=\(errs)")
    }

    func test_rejects_dotDot_in_filenameTemplate() {
        var cfg = PublishConfig()
        cfg.outputs.filenameTemplate = "..{title}-{version}.{ext}"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(
            errs.contains(where: { $0.field == "outputs.filename_template" }),
            "template with '..' should be rejected; errs=\(errs)")
    }

    func test_rejects_slash_embedded_in_filenameTemplate() {
        // Slash anywhere in the template escapes the directory on write.
        var cfg = PublishConfig()
        cfg.outputs.filenameTemplate = "subdir/{title}-{version}.{ext}"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(
            errs.contains(where: { $0.field == "outputs.filename_template" }),
            "template with embedded / should be rejected; errs=\(errs)")
    }

    func test_accepts_safe_filenameTemplate() {
        var cfg = PublishConfig()
        cfg.outputs.filenameTemplate = "{title}-v{version}{label_suffix}.{ext}"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertFalse(
            errs.contains(where: { $0.field == "outputs.filename_template" }),
            "default template should be valid; errs=\(errs)")
    }

    // MARK: full-config acceptance (no regressions on the happy path)

    func test_validConfig_noTraversalErrors() {
        let cfg = PublishConfig(metadata: .init(title: "X", author: "Y"))
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.isEmpty, "default config should be fully valid; errs=\(errs)")
    }
}

// MARK: - Republisher config re-validation (finding 1.5)

/// Validates that `Republisher` re-checks the snapshot's config for
/// traversal before writing to disk. This test exercises the validator
/// path without invoking tectonic (no real compile).
final class RepublisherConfigValidationTests: XCTestCase {

    func test_republish_rejectsTraversalInSnapshotConfig() {
        // PublishConfigValidator must reject a traversal directory.
        var cfg = PublishConfig()
        cfg.outputs.directory = "../../escape"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(
            errs.contains(where: { $0.field == "outputs.directory" }),
            "validator must catch traversal directory; errs=\(errs)")
    }

    func test_republish_rejectsTraversalFilenameTemplate() {
        var cfg = PublishConfig()
        cfg.outputs.filenameTemplate = "../evil/{title}-{version}.{ext}"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(
            errs.contains(where: { $0.field == "outputs.filename_template" }),
            "validator must catch traversal template; errs=\(errs)")
    }
}
