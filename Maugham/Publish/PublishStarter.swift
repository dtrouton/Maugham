import Foundation

/// Copies the bundled barebones starter into `.maugham/publish/`.
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

        let now = Date()
        for (resource, destination) in files {
            guard let src = Bundle.main.url(
                forResource: resource,
                withExtension: nil,
                subdirectory: "PublishStarter"
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
        let publications = (try? await publicationStore.load()) ?? []
        guard !publications.isEmpty else { return }
        // Build the highest tuple via an explicit loop — Swift's type
        // inference times out on .compactMap { tuple }.max(by: ...).
        var highest: VersionTuple? = nil
        for pub in publications {
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
            NSLog("PublishStarter.installIfMissing failed: \(error)")
        }
    }
}
