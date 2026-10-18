// Maugham/Updates/UpdateSweep.swift
import Foundation

/// Deletes old downloaded updates from the Updates folder (#67 Task 6, Denver's
/// ruling: Maugham may delete its own old downloads). The decision is pure
/// (`staleUpdateArtifacts`); the deletion touches only names that function
/// returned, joined onto the Updates folder.
enum UpdateSweep {
    private enum Match {
        case archive(SemanticVersion)      // Maugham-<v>.zip / .dmg
        case download(SemanticVersion)     // Maugham-<v>.zip.download / .dmg.download
        case staged(SemanticVersion)       // staged-<v>
    }

    private static func parse(_ name: String) -> Match? {
        func version(_ s: Substring) -> SemanticVersion? {
            let text = String(s)
            guard UpdateInstaller.isWellFormedVersion(text) else { return nil }
            return SemanticVersion(text)
        }
        if name.hasPrefix("staged-") {
            return version(name.dropFirst("staged-".count)).map(Match.staged)
        }
        guard name.hasPrefix("Maugham-") else { return nil }
        let rest = name.dropFirst("Maugham-".count)
        for ext in ["zip", "dmg"] {
            if rest.hasSuffix(".\(ext).download") {
                return version(rest.dropLast(".\(ext).download".count)).map(Match.download)
            }
            if rest.hasSuffix(".\(ext)") {
                return version(rest.dropLast(".\(ext)".count)).map(Match.archive)
            }
        }
        return nil
    }

    /// Which of `names` to delete. Only `Maugham-<semver>.(zip|dmg)`, the same
    /// with `.download`, and `staged-<semver>` can ever be returned. With a
    /// `keeping` version every matching entry of another version goes; with
    /// none, every matching entry at or below `runningVersion` goes (a newer
    /// one may be a download the next check is about to reuse).
    static func staleUpdateArtifacts(in names: [String], keeping version: String?,
                                     runningVersion: String) -> [String] {
        let keep = version.flatMap(SemanticVersion.init)
        let running = SemanticVersion(runningVersion)
        return names.filter { name in
            guard let match = parse(name) else { return false }
            let v: SemanticVersion
            switch match {
            case .archive(let x), .download(let x), .staged(let x): v = x
            }
            if version != nil {
                guard let keep else { return false } // unparseable keep: delete nothing
                return v != keep
            }
            guard let running else { return false }
            return v <= running
        }
    }

    /// Sweep `directory`. `includingDownloads: false` (the post-stage sweep,
    /// which runs while the app is up) never touches a `.download` file — one
    /// may be mid-write. Returns what it removed.
    @discardableResult
    static func sweep(in directory: URL, keeping version: String?, runningVersion: String,
                      includingDownloads: Bool) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var doomed = staleUpdateArtifacts(in: names, keeping: version, runningVersion: runningVersion)
        if !includingDownloads { doomed.removeAll { $0.hasSuffix(".download") } }
        for name in doomed {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        return doomed
    }
}
