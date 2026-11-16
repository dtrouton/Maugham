import Foundation

/// Runs `body` with `folder` read-only, so a file cannot be made directly in
/// it (`saveManifest`'s temporary file) — the disk's own failure, not a seam.
/// Its subfolders stay writable. The permissions are restored on the way out.
enum UnwritableFolder {
    static func with(_ folder: URL, _ body: () async throws -> Void) async throws {
        let fm = FileManager.default
        let original = try XCTUnwrapPermissions(of: folder)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: folder.path) }
        try await body()
    }

    private static func XCTUnwrapPermissions(of folder: URL) throws -> NSNumber {
        guard let n = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        else { throw CocoaError(.fileReadUnknown) }
        return n
    }
}
