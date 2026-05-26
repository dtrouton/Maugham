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
    ]

    public static func isInitialized(in projectURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent(
                ".maugham/publish/template.tex").path)
    }

    public static func install(into projectURL: URL, force: Bool) throws {
        let pub = projectURL.appendingPathComponent(".maugham/publish")
        let alreadyExists = isInitialized(in: projectURL)
        if alreadyExists && !force {
            throw Error.alreadyInitialized
        }

        try FileManager.default.createDirectory(
            at: pub, withIntermediateDirectories: true)

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
        }
    }

    /// Convenience for new-project creation — does nothing if already initialized.
    public static func installIfMissing(into projectURL: URL) {
        guard !isInitialized(in: projectURL) else { return }
        do {
            try install(into: projectURL, force: false)
        } catch {
            // Non-fatal: writer can re-trigger via the MCP tool.
            NSLog("PublishStarter.installIfMissing failed: \(error)")
        }
    }
}
