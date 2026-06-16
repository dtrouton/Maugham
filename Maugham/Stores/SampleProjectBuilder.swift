import Foundation
import MaughamCore

/// Materializes a bundled sample project (novel/screenplay) onto disk as a
/// normal, fully-editable project. Copies the seed folder to a deduped path
/// and installs the publishing starter. The CALLER opens the result through
/// the standard load path so `Bootstrap.run` mints the inline ¶id anchors —
/// the builder never constructs `Document` directly (hard invariant).
enum SampleProjectBuilder {
    enum Kind: String {
        case novel, screenplay

        /// User-visible destination name; leading word uses the build variant
        /// display name so dev/stable don't collide (tripwire 13).
        func destinationName() -> String {
            "\(BuildVariant.current.displayName) Sample \(rawValue.capitalized)"
        }
    }

    enum BuildError: Error { case seedMissing(String) }

    /// `seedsRoot` is injectable for tests; production passes the bundled dir.
    static func build(_ kind: Kind,
                      seedsRoot: URL,
                      destinationParent: URL) async throws -> URL {
        let fm = FileManager.default
        let seed = seedsRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
        guard fm.fileExists(
            atPath: seed.appendingPathComponent(ProjectManifest.fileName).path) else {
            throw BuildError.seedMissing(kind.rawValue)
        }

        let dest = dedupedURL(name: kind.destinationName(), in: destinationParent)
        // COPY (never move) — the seed lives in the read-only app bundle and
        // must survive for the next "create sample" (tripwire 14: no raw move
        // of user content; a copy is fine).
        try fm.copyItem(at: seed, to: dest)
        await PublishStarter.installIfMissing(into: dest)
        return dest
    }

    /// Production convenience: bundled seeds + ~/Documents.
    @MainActor
    static func buildInDocuments(_ kind: Kind) async throws -> URL {
        guard let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Samples") else {
            throw BuildError.seedMissing("Samples")
        }
        let docs = fmDocumentsURL()
        return try await build(kind, seedsRoot: bundled, destinationParent: docs)
    }

    private static func fmDocumentsURL() -> URL {
        (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    private static func dedupedURL(name: String, in parent: URL) -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}
