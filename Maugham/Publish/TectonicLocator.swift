import Foundation

public enum TectonicLocator {

    public enum Error: Swift.Error {
        case notFound
        case notExecutable
    }

    /// Locates `tectonic` inside the running app bundle's Resources/bin.
    public static func locate() throws -> URL {
        guard let bundle = Bundle.main.resourceURL else {
            throw Error.notFound
        }
        return try locateInBundle(at: bundle.deletingLastPathComponent())
    }

    /// Locates `tectonic` relative to a candidate app-bundle root
    /// (the `.app` directory). Used for testability.
    public static func locateInBundle(at appURL: URL) throws -> URL {
        let candidate = appURL
            .appendingPathComponent("Contents/Resources/bin/tectonic")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw Error.notFound
        }
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw Error.notExecutable
        }
        return candidate
    }
}
