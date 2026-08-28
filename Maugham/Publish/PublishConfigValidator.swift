import Foundation
import MaughamCore

public enum PublishConfigValidator {

    /// Maximum supported `schema_version`. Bump when adding fields that older
    /// clients shouldn't silently accept.
    public static let supportedSchemaVersion = 1

    public struct ValidationError: Equatable, Sendable {
        public let field: String
        public let message: String
    }

    public static func validate(_ cfg: PublishConfig) -> [ValidationError] {
        var errs: [ValidationError] = []

        if cfg.schemaVersion < 1 || cfg.schemaVersion > supportedSchemaVersion {
            errs.append(.init(
                field: "schema_version",
                message: "Unsupported schema_version \(cfg.schemaVersion); supported: 1...\(supportedSchemaVersion)"))
        }

        if cfg.metadata.title.trimmingCharacters(in: .whitespaces).isEmpty {
            errs.append(.init(field: "metadata.title", message: "title must not be empty"))
        }

        if let y = cfg.metadata.year, y < 0 || y > 9999 {
            errs.append(.init(field: "metadata.year", message: "year must be in 0...9999"))
        }

        if cfg.outputs.directory.isEmpty {
            errs.append(.init(field: "outputs.directory", message: "directory must not be empty"))
        } else {
            // Traversal checks on outputs.directory (finding 1.5): reject leading '/',
            // and any path segment that is exactly '..'. Plain subdirs ("Exports",
            // "output/books") are fine; "../../outside" or "/absolute" are not.
            if cfg.outputs.directory.hasPrefix("/") {
                errs.append(.init(
                    field: "outputs.directory",
                    message: "directory must be a relative path (no leading '/')"))
            } else {
                let dirSegments = cfg.outputs.directory
                    .split(separator: "/", omittingEmptySubsequences: false)
                    .map(String.init)
                if dirSegments.contains("..") {
                    errs.append(.init(
                        field: "outputs.directory",
                        message: "directory must not contain '..' path traversal segments"))
                }
            }
        }

        if !cfg.outputs.filenameTemplate.contains("{title}") ||
           !cfg.outputs.filenameTemplate.contains("{version}") ||
           !cfg.outputs.filenameTemplate.contains("{ext}") {
            errs.append(.init(
                field: "outputs.filename_template",
                message: "filename_template must include {title}, {version}, and {ext}"))
        } else if cfg.outputs.filenameTemplate.contains("/") || cfg.outputs.filenameTemplate.contains("..") {
            // Traversal check on filenameTemplate (finding 1.5): a '/' or '..' in the
            // template expands to a path that escapes the outputs.directory on write.
            // The template is a filename, not a path — no separators are allowed.
            errs.append(.init(
                field: "outputs.filename_template",
                message: "filename_template must not contain '/' or '..' (path traversal)"))
        }

        if cfg.outputs.formatsEnabled.isEmpty {
            errs.append(.init(
                field: "outputs.formats_enabled",
                message: "at least one format must be enabled"))
        }

        for key in cfg.languageOverrides.keys where !TranslationRecord.isValidLanguageTag(key) {
            errs.append(.init(
                field: "language_overrides.\(key)",
                message: "'\(key)' is not a valid language tag (lowercase BCP-47, e.g. 'fr', 'pt-br')"))
        }

        // NB: nothing above constrains the top-level `next_version` — the only
        // version-shaped logic in this file is `bumpedNextVersion`, which is
        // total (any unparseable input yields "0.1") and deliberately refuses
        // nothing. An imprint's own counter is held to that same rule, i.e. to
        // none; `PublishConfigImprintValidationTests
        // .test_nextVersion_isUnconstrained_atBothLevels` pins the pair, so
        // adding a rule at one level goes red until it is added at the other.
        errs.append(contentsOf: imprintErrors(cfg))

        return errs
    }

    /// The same rules PLUS the two questions a pure function cannot answer:
    /// does this template exist inside the publish tree, and is this allowlist
    /// id a piece of this project. **This is the only entry point that touches
    /// the filesystem** — `set_publish_config` calls it through
    /// `PublishConfigStore.applyPatch(_:additionalValidation:)`, and the
    /// compile path (Task 6) calls it directly.
    ///
    /// - Parameters:
    ///   - publishDir: the project's `.maugham/publish/` directory.
    ///   - pieceIDs: the manuscript pieces a compile can render —
    ///     `ProjectStoreASTSource.publishablePieces()`, the one spelling.
    public static func validate(
        _ cfg: PublishConfig, publishDir: URL, pieceIDs: [String]
    ) -> [ValidationError] {
        validate(cfg) + existenceErrors(cfg, publishDir: publishDir, pieceIDs: pieceIDs)
    }

    /// The compile pre-flight's door (Task 6): everything the config-write
    /// door asks, PLUS the one question that door deliberately does not — does
    /// the template this compile will actually typeset through exist, even
    /// when it is the starter's own `template.tex`?
    ///
    /// `existenceErrors` skips a DEFAULT template on purpose: a project whose
    /// starter install failed silently (`PublishStarter.installIfMissing`
    /// swallows its error by design) must still be able to patch any config
    /// key. A compile is the other case entirely — without the template there
    /// is nothing to typeset — so the miss is met here, in Maugham's own
    /// words, rather than downstream as a tectonic error.
    ///
    /// Asked only of the format that would use the answer: an EPUB is emitted
    /// without LaTeX, and refusing one for a missing `.tex` would be this
    /// validator inventing a dependency the emitter does not have. A template
    /// the writer NAMED is a claim they made and is checked either way, by
    /// `validate(_:publishDir:pieceIDs:)` above.
    public static func validateForCompile(
        _ cfg: PublishConfig, publishDir: URL, pieceIDs: [String],
        format: PublishConfig.Format
    ) -> [ValidationError] {
        var errs = validate(cfg, publishDir: publishDir, pieceIDs: pieceIDs)
        if format == .pdf, cfg.template == defaultTemplate,
           let err = templateExistenceError(
            cfg.template, field: "template", publishDir: publishDir,
            remedy: "reinstall the publish starter files, or write it with "
                + "write_publish_file") {
            errs.append(err)
        }
        return errs
    }

    // MARK: - Imprints (spec `2026-08-27-imprints-and-bilingual-editions-design` §3)

    /// The starter's template, read off `PublishConfig`'s own default rather
    /// than restated — a fourth copy of the literal would be a fourth place to
    /// drift from `PublishConfig.init`/`encode(to:)`/`init(from:)`.
    private static let defaultTemplate = PublishConfig().template

    /// Every character an imprint name may hold: `^[a-z0-9-]+$`. A name reaches
    /// filenames (`{imprint}`) and the publication catalog's key, so it is held
    /// to a slug the way a language tag is.
    private static let imprintNameAlphabet = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")

    /// The pure imprint rules. Fields are `imprints.<name>.<field>`; the name
    /// rule, which has no sub-field, reports `imprints.<name>`.
    private static func imprintErrors(_ cfg: PublishConfig) -> [ValidationError] {
        var errs: [ValidationError] = []

        // Constraint 3: nothing writes the empty string — nil is the book.
        if cfg.imprint?.isEmpty == true {
            errs.append(.init(
                field: "imprint",
                message: "imprint must name an imprint or be absent; \"\" is not a name"))
        }

        // The book's own template travels the same road as an imprint's, so it
        // takes the same path rule under its own field name.
        if let err = templatePathError(cfg.template, field: "template") {
            errs.append(err)
        }

        for (name, imprint) in cfg.imprints.sorted(by: { $0.key < $1.key }) {
            if name.isEmpty {
                errs.append(.init(
                    field: "imprints.\(name)",
                    message: "an imprint name must not be empty"))
            } else if !name.unicodeScalars.allSatisfy(imprintNameAlphabet.contains) {
                errs.append(.init(
                    field: "imprints.\(name)",
                    message: "imprint name '\(name)' must match [a-z0-9-]+ "
                        + "(lowercase letters, digits and hyphens)"))
            }

            if let template = imprint.template,
               let err = templatePathError(template, field: "imprints.\(name).template") {
                errs.append(err)
            }

            if let sections = imprint.sections {
                if sections.isEmpty {
                    errs.append(.init(
                        field: "imprints.\(name).sections",
                        message: "sections is an allowlist and must name at least one piece; "
                            + "omit the key to inherit the book's map"))
                }
                for (id, section) in sections.sorted(by: { $0.key < $1.key })
                where !section.include {
                    errs.append(.init(
                        field: "imprints.\(name).sections.\(id)",
                        message: "an allowlist entry must not set include:false — naming a piece "
                            + "IS the inclusion; drop the entry to leave the piece out"))
                }
            }
        }

        errs.append(contentsOf: templateBasenameErrors(cfg))

        return errs
    }

    /// Template BASENAMES must be distinct across the book's template and
    /// every imprint's, however far apart their directories are.
    ///
    /// Tectonic's `--outdir` is FLAT and names its output after the template's
    /// own basename (measured 2026-08-27, Task 5): `templates/a/special.tex`
    /// and `templates/b/special.tex` both typeset into `build/special.pdf`, as
    /// does an imprint template called `template.tex` in a subdirectory beside
    /// the book's. Two such compiles running at once would read and overwrite
    /// one another's intermediates, so distinct PATHS are not enough.
    ///
    /// Compared case-insensitively: `build/` sits on the writer's own volume,
    /// and APFS is case-insensitive by default, so `Special.tex` and
    /// `special.tex` are one file there.
    ///
    /// A language-suffixed variant (`special.sr.tex`) is NOT a second template
    /// — it is the same one rendered in another language, picked per compile
    /// by `LanguageSuffixedFile.resolve` — and it carries its own basename and
    /// its own intermediate, so nothing here strips the suffix before
    /// comparing.
    ///
    /// The book is seeded first and imprints are walked in name order, so the
    /// error always lands on the later claimant and names the earlier owner.
    private static func templateBasenameErrors(_ cfg: PublishConfig) -> [ValidationError] {
        // The rule is about the config as WRITTEN — the book's declared
        // template against each imprint's. A RESOLVED config (`imprint` set,
        // which `resolved(imprint:pieceIDs:)` alone does) no longer holds that
        // relationship: its `template` has already been replaced BY one of the
        // imprints', so comparing the two would have that imprint colliding
        // with itself. The compile door validates a resolved config, so
        // without this guard every compile under an imprint that names a
        // template would refuse itself.
        guard cfg.imprint == nil else { return [] }

        func basename(_ path: String) -> String {
            (path as NSString).lastPathComponent
        }

        var owners: [String: (path: String, description: String)] = [:]
        var errs: [ValidationError] = []

        // A template whose *pure* path rule already failed is skipped — it has
        // its own error, and a second one about its filename would be noise.
        if templatePathError(cfg.template, field: "template") == nil {
            owners[basename(cfg.template).lowercased()] =
                (cfg.template, "the book's own template ('\(cfg.template)')")
        }

        for (name, imprint) in cfg.imprints.sorted(by: { $0.key < $1.key }) {
            guard let template = imprint.template,
                  templatePathError(template, field: "") == nil else { continue }
            let key = basename(template).lowercased()
            guard let owner = owners[key] else {
                owners[key] = (template, "the template of imprint '\(name)' ('\(template)')")
                continue
            }
            // The SAME path is the same file, deliberately shared — an imprint
            // that changes only its metadata or its sections keeps the book's
            // typography by naming the book's own template, and refusing that
            // would refuse the commonest imprint there is. The hazard is two
            // DIFFERENT templates answering to one filename.
            guard owner.path != template else { continue }
            errs.append(.init(
                field: "imprints.\(name).template",
                message: "template '\(template)' has the same filename as \(owner.description); "
                    + "tectonic typesets every template into one flat build/ "
                    + "directory, so the two would overwrite each other's "
                    + "intermediates — give this one a distinct filename"))
        }

        return errs
    }

    /// A template path's *pure* rules — the ones answerable without a disk.
    /// Mirrors `PublishPath.validateAndResolve`'s segment-wise `..` check (a
    /// filename like `chapter..outline.tex` is legal); returns nil when the
    /// path is a well-formed relative path, which is also the signal that it
    /// is safe to ask the filesystem about.
    private static func templatePathError(_ path: String, field: String) -> ValidationError? {
        if path.isEmpty {
            return .init(field: field, message: "template must not be empty")
        }
        if path.contains("\0") {
            return .init(field: field, message: "template must not contain a null byte")
        }
        if path.hasPrefix("/") {
            return .init(
                field: field,
                message: "template must be a relative path inside .maugham/publish/ "
                    + "(no leading '/')")
        }
        if path.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            return .init(
                field: field,
                message: "template must not contain '..' path traversal segments")
        }
        return nil
    }

    /// The filesystem half. A template whose *pure* path rule already failed is
    /// skipped — a path carrying `..` is refused before any disk is consulted.
    private static func existenceErrors(
        _ cfg: PublishConfig, publishDir: URL, pieceIDs: [String]
    ) -> [ValidationError] {
        var errs: [ValidationError] = []
        let pieces = Set(pieceIDs)

        // The book's own template is checked for existence ONLY when the writer
        // named a non-default one. A config write is not the place to discover
        // that `template.tex` is missing: a project whose starter install failed
        // silently (`PublishStarter.installIfMissing` swallows its error by
        // design) would otherwise be unable to patch ANY config key, publishing
        // or not. A named template is a different claim — the writer says this
        // file exists, so the validator holds them to it. A missing default is
        // still met, loudly, at compile pre-flight.
        if cfg.template != defaultTemplate,
           let err = templateExistenceError(
            cfg.template, field: "template", publishDir: publishDir,
            remedy: "write it with write_publish_file, or drop the `template` key "
                + "to use the starter's template.tex") {
            errs.append(err)
        }

        for (name, imprint) in cfg.imprints.sorted(by: { $0.key < $1.key }) {
            if let template = imprint.template,
               let err = templateExistenceError(
                   template, field: "imprints.\(name).template", publishDir: publishDir,
                   remedy: "write it with write_publish_file first") {
                errs.append(err)
            }
            for id in (imprint.sections?.keys.sorted() ?? []) where !pieces.contains(id) {
                errs.append(.init(
                    field: "imprints.\(name).sections.\(id)",
                    message: "'\(id)' matches no publishable piece in this project; "
                        + "call get_outline for valid piece ids"))
            }
        }

        return errs
    }

    private static func templateExistenceError(
        _ path: String, field: String, publishDir: URL, remedy: String
    ) -> ValidationError? {
        if templatePathError(path, field: field) != nil { return nil }

        let candidate = publishDir.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .init(
                field: field,
                message: "template '\(path)' does not exist under .maugham/publish/; \(remedy)")
        }

        // Canonical paths, not standardized ones: a *symlink* whose target sits
        // outside the tree carries no '..' for the pure rule to catch, and
        // `standardizedFileURL` alone does not follow it. Both sides are
        // canonicalized so /tmp-vs-/private/tmp cannot fake a mismatch.
        let root = canonicalPath(publishDir)
        let resolved = canonicalPath(candidate)
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            return .init(
                field: field,
                message: "template '\(path)' resolves outside .maugham/publish/")
        }
        return nil
    }

    /// The one canonicalization both sides of the containment check go
    /// through. **It takes two steps, and neither is sufficient alone**
    /// (measured on macOS 26.6, 2026-08-27):
    /// `URLResourceKey.canonicalPathKey` canonicalizes the directory
    /// components and case but does NOT follow a symlink at the leaf — a
    /// template file that *is* a link out of the tree comes back reading as
    /// though it lived inside it — while `resolvingSymlinksInPath()` follows
    /// the leaf but strips the `/private` prefix, so a `/var`-vs-`/private/var`
    /// mismatch would fail every comparison under a temp directory. Resolve
    /// first, canonicalize second.
    private static func canonicalPath(_ url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if let values = try? resolved.resourceValues(forKeys: [.canonicalPathKey]),
           let canonical = values.canonicalPath {
            return canonical
        }
        return resolved.path
    }

    /// Parse "X.Y" and return "X.(Y+1)". Returns "0.1" for any invalid input.
    public static func bumpedNextVersion(from current: String) -> String {
        let parts = current.split(separator: ".")
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              major >= 0, minor >= 0
        else {
            return "0.1"
        }
        return "\(major).\(minor + 1)"
    }
}
