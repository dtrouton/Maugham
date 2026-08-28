import Foundation
import MaughamCore

/// Resolves a template/style/piece filename to its language-suffixed variant
/// when that variant exists on disk, otherwise the base name.
///
/// The suffix goes *before* the extension: `template.tex` + `es` →
/// `template.es.tex`. A per-edition translated book can ship its own template,
/// stylesheet, and per-piece style files (`template.es.tex`, `styles.es.css`,
/// `october-passed-me-by.es.tex`) that Maugham picks up automatically; when a
/// suffixed file is absent the base file is used, so a partial translation
/// still compiles.
///
/// A `nil` (or empty) language always returns the base — single-language
/// compiles are untouched.
///
/// Scope boundary: only the top-level file named here is Swift-resolved.
/// `\input` partials referenced *inside* a `template.es.tex` (e.g.
/// `frontmatter`) are the per-edition template's own responsibility — a
/// `template.es.tex` references `frontmatter.es` itself. No machinery here
/// chases those (spec §4).
enum LanguageSuffixedFile {

    /// `"template.tex"` + `"es"` → `"template.es.tex"` when it exists under
    /// `dir`, else the input `filename`. `nil`/empty language → `filename`.
    static func resolve(_ filename: String, language: String?, under dir: URL) -> String {
        guard let language, !language.isEmpty else { return filename }

        let ns = filename as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        let suffixed = ext.isEmpty ? "\(base).\(language)" : "\(base).\(language).\(ext)"

        let candidate = dir.appendingPathComponent(suffixed)
        return FileManager.default.fileExists(atPath: candidate.path) ? suffixed : filename
    }

    /// The inverse of the naming above, on the NAME alone: `template.es.tex` →
    /// `template.tex`; `template.tex` → itself. Exactly one component before
    /// the extension is removed, and only when it is a language tag by
    /// `TranslationRecord.isValidLanguageTag` — the same test `resolve` names
    /// its variants with — so `special.v2.tex` keeps its `v2`: a version
    /// marker is not an edition.
    ///
    /// Deliberately filesystem-free. Its caller
    /// (`PublishConfigValidator`'s template-basename rule) asks what a name
    /// COULD collide with, which is a question about names rather than about
    /// which variants happen to be on disk today.
    ///
    /// It inherits the tag test's own imprecision — `chapter.one.tex` strips
    /// to `chapter.tex`, because `one` matches the tag grammar — and that is
    /// the point: `resolve` would treat that same file as the `one` edition of
    /// `chapter.tex`, so the two agree about what is a variant.
    static func strippingLanguageSuffix(_ filename: String) -> String {
        let ns = filename as NSString
        let ext = ns.pathExtension
        guard !ext.isEmpty else { return filename }
        let base = ns.deletingPathExtension as NSString
        let candidate = base.pathExtension
        guard !candidate.isEmpty,
              TranslationRecord.isValidLanguageTag(candidate) else { return filename }
        return "\(base.deletingPathExtension).\(ext)"
    }

    /// Rewrites each section's `styleFile` to its language-suffixed variant when
    /// that variant exists under `publishDir/pieces/`. The emitter has no
    /// filesystem access, so this runs in the orchestrator against the
    /// EDITION-effective config *before* snapshot + emit. Only the in-memory
    /// effective config is rewritten; the shared on-disk config keeps its base
    /// names. Returns the config unchanged when `language` is `nil`/empty.
    static func resolvingStyleFiles(
        in config: PublishConfig, language: String?, publishDir: URL
    ) -> PublishConfig {
        guard let language, !language.isEmpty else { return config }

        let piecesDir = publishDir.appendingPathComponent("pieces", isDirectory: true)
        var out = config
        for (pieceID, section) in out.sections {
            guard let styleFile = section.styleFile else { continue }
            let resolved = resolve(styleFile, language: language, under: piecesDir)
            if resolved != styleFile {
                out.sections[pieceID]?.styleFile = resolved
            }
        }
        return out
    }
}
