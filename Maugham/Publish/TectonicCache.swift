import Foundation
import MaughamCore

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
        // Use the variant's support-folder name so dev and stable builds write
        // separate tectonic caches (avoids cache pollution when both variants
        // run on the same machine). Routes through BuildVariant per tripwire 13.
        return caches
            .appendingPathComponent(BuildVariant.current.supportFolderName, isDirectory: true)
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
