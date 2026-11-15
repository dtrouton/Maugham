import Foundation
import os

/// **One read of each production source file, one walk of each production
/// directory, per test process.**
///
/// The census suites (`TripwireGrepTests` first of all) walk the same
/// `Maugham/`, `MaughamPhone/` and `Packages/` trees dozens of times and read
/// every file again each time. The production tree does not change under a
/// running test, so the first walk and the first read are kept for the life of
/// the process.
///
/// Anything OUTSIDE the repo — a planted fixture under `TestTemp`, whose
/// controls rewrite and rename files between reads — bypasses the cache
/// entirely and goes to the file system every time (the same rule as
/// `SourceTree.memoKey`).
enum SourceTreeCache {

    private static let walks = OSAllocatedUnfairLock<[String: [URL]]>(initialState: [:])
    private static let texts = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    private static let repoPath = SourceTree.repoRoot.standardizedFileURL.path

    /// Whether `url` is the repo or inside it — the only places that are cached.
    /// A pure string test (no `standardizedFileURL`, which stats the disk on
    /// every call); a path with a `..` or `.` hop is simply not cached.
    private static func isCacheable(_ url: URL) -> Bool {
        let path = url.path
        guard path == repoPath || path.hasPrefix(repoPath + "/") else { return false }
        return !path.contains("/../") && !path.contains("/./") && !path.hasSuffix("/..")
    }

    /// `FileManager.enumerator(at:includingPropertiesForKeys: nil)`, replayed
    /// from the first walk when `dir` is inside the repo. Same order, same
    /// `nil` for an unreadable directory; the result iterates, `nextObject()`s
    /// and `allObjects` like the real one.
    static func enumerator(at dir: URL) -> NSEnumerator? {
        guard isCacheable(dir) else {
            return FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        }
        let key = dir.path
        if let known = walks.withLock({ $0[key] }) {
            return (known as NSArray).objectEnumerator()
        }
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let all = (walker.allObjects as? [URL]) ?? []
        walks.withLock { $0[key] = all }
        return (all as NSArray).objectEnumerator()
    }

    /// `String(contentsOf: url, encoding: .utf8)`, read once per process when
    /// `url` is inside the repo. Throws exactly what the real read throws.
    static func text(_ url: URL) throws -> String {
        guard isCacheable(url) else { return try String(contentsOf: url, encoding: .utf8) }
        let key = url.path
        if let known = texts.withLock({ $0[key] }) { return known }
        let text = try String(contentsOf: url, encoding: .utf8)
        texts.withLock { $0[key] = text }
        return text
    }

    // MARK: - Derived forms

    private struct DerivedKey: Hashable {
        let name: String
        let text: String
    }

    private static let derivedForms = OSAllocatedUnfairLock<[DerivedKey: Any]>(initialState: [:])

    /// `compute(text)` once per distinct `(name, text)` in this process.
    ///
    /// KEYED BY THE TEXT ITSELF, never by a path: a planted fixture that
    /// rewrites a file and reads it back hands this a different text and so
    /// gets a fresh answer, and the repo's own files — read once — hand it the
    /// same text every time. `compute` must be a pure function of `text`.
    /// Costly lexers (the comment/string maskers) are the intended callers.
    static func derived<T>(_ name: String, of text: String, _ compute: (String) -> T) -> T {
        let key = DerivedKey(name: name, text: text)
        if let known = derivedForms.withLock({ $0[key] }) as? T { return known }
        let value = compute(text)
        derivedForms.withLock { $0[key] = value }
        return value
    }
}
