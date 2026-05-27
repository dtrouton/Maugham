import Foundation

public enum TectonicCache {

    public enum Error: Swift.Error {
        case noCachesDirectory
    }

    public static func cacheURL() throws -> URL {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask).first
        else {
            throw Error.noCachesDirectory
        }
        return caches
            .appendingPathComponent("Maugham", isDirectory: true)
            .appendingPathComponent("tectonic", isDirectory: true)
    }

    @discardableResult
    public static func ensureCacheExists() throws -> URL {
        let url = try cacheURL()
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }
}
