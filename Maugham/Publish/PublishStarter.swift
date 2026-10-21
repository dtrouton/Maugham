import Foundation
import MaughamCore

/// Copies the bundled barebones starter into `.maugham/publish/`.
///
/// **Two starters** (report plan 4, R-4-6). A book gets the barebones book
/// starter at `PublishStarter/`. A Report gets the `PublishStarter/report/`
/// variant over it: its own `template.tex` (an 11pt article whose paper
/// `PDFCompiler` decides at each compile, R-S7), `frontmatter.tex` (a title page, then the contents), `prose.tex`
/// (restrained section headings) and `default-config.json` (PDF and Word);
/// every other file is the book starter's. Which starter is read from the
/// project's manifest on disk (`variant(for:)`), so a re-install — MCP
/// `initialize_publish_template` — picks the same one the factory did; the
/// factory writes the manifest before it installs.
public enum PublishStarter {

    public enum Error: Swift.Error {
        case alreadyInitialized
        case starterResourceMissing(String)
    }

    /// Files copied from the bundle, with their destination filename.
    /// `default-config.json` → `config.json` (rename on copy).
    private static let files: [(resource: String, destination: String)] = [
        ("template.tex",        "template.tex"),
        ("preamble.tex",        "preamble.tex"),
        ("frontmatter.tex",     "frontmatter.tex"),
        ("prose.tex",           "prose.tex"),
        ("screenplay.tex",      "screenplay.tex"),
        ("backmatter.tex",      "backmatter.tex"),
        ("styles.css",          "styles.css"),
        ("default-config.json", "config.json"),
        ("EMISSION.md",         "EMISSION.md"),
    ]

    /// Which starter a project takes.
    public enum Variant: Equatable {
        /// The barebones book starter — every project without a Report profile.
        case book
        /// The Report starter. `singleDocument` (the short-story shape) prints
        /// no title for its FIRST piece: that piece is titled with the
        /// project's name, which the title page already prints. A document
        /// added later prints its own (`report/prose-single.tex`).
        case report(singleDocument: Bool)
    }

    /// The starter `manifest` takes: the Report variant for a Report on a
    /// prose shape, the book starter otherwise — and for no manifest at all
    /// (a bare folder, a test). A screenplay Report is refused by the factory;
    /// one made by hand keeps the book starter, whose `screenplay.tex` it needs.
    public static func variant(for manifest: ProjectManifest?) -> Variant {
        guard let manifest else { return .book }
        switch manifest.profile {
        case nil, .unknown?: return .book
        case .report?:
            switch manifest.type {
            case .shortStory: return .report(singleDocument: true)
            case .novel, .collection, .unknown: return .report(singleDocument: false)
            case .screenplay: return .book
            }
        }
    }

    /// The bundle folder a Report's overrides live in.
    private static let reportSubdirectory = "PublishStarter/report"

    /// Where `resource` comes from for `variant`, and under which bundle name:
    /// a Report's four overrides from `report/` (its single-document shape
    /// reading `prose-single.tex` as `prose.tex`), everything else from the
    /// book starter.
    private static func source(of resource: String, for variant: Variant)
        -> (name: String, subdirectory: String) {
        switch variant {
        case .book:
            return (resource, "PublishStarter")
        case .report(let single):
            switch resource {
            case "prose.tex":
                return (single ? "prose-single.tex" : "prose.tex", reportSubdirectory)
            case "template.tex", "frontmatter.tex", "default-config.json":
                return (resource, reportSubdirectory)
            default:
                return (resource, "PublishStarter")
            }
        }
    }

    /// The project's manifest as written on disk, or nil when there is none
    /// (or it does not decode — the book starter is the safe answer).
    private static func manifestOnDisk(_ projectURL: URL) -> ProjectManifest? {
        let url = projectURL.appendingPathComponent(ProjectManifest.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }  // adr-0018-ok: project manifest JSON read, not manuscript
        return try? ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: data)
    }

    public static func isInitialized(in projectURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent(
                ".maugham/publish/template.tex").path)
    }

    public static func install(into projectURL: URL, force: Bool) async throws {
        let pub = projectURL.appendingPathComponent(".maugham/publish")
        let alreadyExists = isInitialized(in: projectURL)
        if alreadyExists && !force {
            throw Error.alreadyInitialized
        }

        try FileManager.default.createDirectory(
            at: pub, withIntermediateDirectories: true)

        let variant = variant(for: manifestOnDisk(projectURL))
        let now = Date()
        for (resource, destination) in files {
            let source = source(of: resource, for: variant)
            guard let src = Bundle.main.url(
                forResource: source.name,
                withExtension: nil,
                subdirectory: source.subdirectory
            ) else {
                throw Error.starterResourceMissing(resource)
            }
            let dst = pub.appendingPathComponent(destination)
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
            // copyItem preserves source mtime — the bundle's build time —
            // which makes every freshly-init'd file look stale. Touch with
            // wall-clock so `modified_at` reflects "when did THIS project's
            // copy get installed" rather than "when was Maugham.app built".
            try? FileManager.default.setAttributes(
                [.modificationDate: now], ofItemAtPath: dst.path)
        }

        // High-water-mark guard. The starter's default-config.json carries
        // `next_version: "0.1"`. If publications already exist (e.g. force-init
        // on a project with prior publishes), restoring the starter would
        // rewind the counter into territory already occupied by historical
        // publications — and the next compile would mint a colliding version,
        // making `read_publication_page(version: ...)` ambiguous between two
        // real publications. Reconcile here by reading the publications log
        // and pinning next_version to max(existing) + 1.
        try await reconcileNextVersion(in: projectURL)
    }

    /// Read `.maugham/publications.jsonl`, find the highest existing version,
    /// and bump `config.next_version` past it. No-op if no publications exist
    /// or the freshly-written config already has a higher counter.
    private static func reconcileNextVersion(in projectURL: URL) async throws {
        let publicationStore = await PublicationStore(projectURL: projectURL)
        // RULING-54: propagate, don't blank. An unreadable catalog read as []
        // silently no-ops this guard — the exact collision the comment above
        // describes, armed by the read the guard exists to consult.
        let publications = try await publicationStore.load()
        guard !publications.isEmpty else { return }
        // Build the highest tuple via an explicit loop — Swift's type
        // inference times out on .compactMap { tuple }.max(by: ...).
        var highest: VersionTuple? = nil
        for pub in publications {
            // M1 (whole-branch review): the counter being reconciled is the
            // BOOK's `next_version`, and an imprint counts its own versions —
            // a special edition at 3.7 beside a book at 0.1 is the ordinary
            // case, not a corner. Only the book's own rows are its high-water
            // mark. (An imprint's counter lives in `imprints.<name>
            // .next_version` and is advanced by its own compiles.)
            guard pub.imprint == nil else { continue }
            guard let parsed = parseVersion(pub.version) else { continue }
            if let h = highest {
                if VersionTuple.isLess(h, parsed) { highest = parsed }
            } else {
                highest = parsed
            }
        }
        guard let highest else { return }
        let bumped = "\(highest.major).\(highest.minor + 1)"

        let configStore = PublishConfigStore(projectURL: projectURL)
        guard var config = try await configStore.load() else { return }
        // Only push the counter FORWARD. Never roll it back below current.
        if let current = parseVersion(config.nextVersion),
           !VersionTuple.isLess(current, highest)
            && !(current.major == highest.major && current.minor == highest.minor) {
            return
        }
        config.nextVersion = bumped
        try await configStore.save(config)
    }

    /// Numeric (major, minor) pair used for version comparison. Kept as a
    /// named struct (rather than the inline tuple type that triggered Swift's
    /// expression-type-check timeout) so the closures stay simple.
    private struct VersionTuple {
        let major: Int
        let minor: Int

        static func isLess(_ a: VersionTuple, _ b: VersionTuple) -> Bool {
            a.major == b.major ? a.minor < b.minor : a.major < b.major
        }
    }

    /// Parse "X.Y" into a `VersionTuple`. Returns nil for non-numeric versions
    /// (e.g. republish suffixes like "0.3-r5f7a") so they don't poison the
    /// max calculation — those forms aren't valid `next_version` targets.
    private static func parseVersion(_ s: String) -> VersionTuple? {
        let parts = s.split(separator: ".")
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1])
        else { return nil }
        return VersionTuple(major: major, minor: minor)
    }

    /// Convenience for new-project creation — does nothing if already initialized.
    public static func installIfMissing(into projectURL: URL) async {
        guard !isInitialized(in: projectURL) else { return }
        do {
            try await install(into: projectURL, force: false)
        } catch {
            // Non-fatal: writer can re-trigger via the MCP tool.
            // RULING-54 residual (M9-OL-009's filing): since the catalog read
            // went strict, this catch also swallows reconcileNextVersion's
            // unreadable-catalog refusal — reachable only for a project with
            // a catalog present and the publish template missing. The next
            // compile meets the same refusal loudly at pre-flight, so the
            // collision guard is deferred, not lost.
            NSLog("PublishStarter.installIfMissing failed: \(error)")
        }
    }
}
