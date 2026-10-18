// Maugham/Updates/InstallStatus.swift
import Foundation

/// What the detached swap helper left in `Updates/install-status` when an
/// install did not complete (#67 Task 5). The helper writes ONE line after the
/// app has exited — `refused <version>` when the install-time check refused the
/// copy, `failed <version> <step>` when a step broke — and nothing on success.
/// The next launch reads it, removes it, and the update banner says it once.
public enum InstallStatus: Equatable {
    /// The install-time codesign/spctl check refused the staged copy. The old
    /// app is untouched, and the staged files are discarded so the next check
    /// downloads the update afresh.
    case refused(version: String)
    /// A helper step (`UpdateInstaller.HelperFailureStep`) failed. The staged
    /// files are kept: the next "Restart & Update" or quit tries them again.
    case failed(version: String, step: String)

    public var version: String {
        switch self {
        case .refused(let v), .failed(let v, _): return v
        }
    }

    /// Parse the helper's line. Nil for anything that is not exactly one of the
    /// two forms with an `X.Y.Z` version and a step the helper names — a
    /// garbled file is not a message.
    public static func parse(_ text: String) -> InstallStatus? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.contains("\n") else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, UpdateInstaller.isWellFormedVersion(parts[1]) else { return nil }
        switch (parts[0], parts.count) {
        case ("refused", 2):
            return .refused(version: parts[1])
        case ("failed", 3):
            guard UpdateInstaller.HelperFailureStep(rawValue: parts[2]) != nil else { return nil }
            return .failed(version: parts[1], step: parts[2])
        default:
            return nil
        }
    }

    /// The one sentence the banner draws (Denver's ruling for `refused`).
    public var sentence: String { sentence(waitsForManualCheck: false) }

    /// After the install-time check has refused the same version twice the
    /// background poll stops re-downloading it (`InstallRefusalMemory`), so
    /// the refused sentence must not promise a download that won't happen.
    public func sentence(waitsForManualCheck: Bool) -> String {
        if case .refused(let v) = self, waitsForManualCheck {
            return "The update to Maugham \(v) didn't pass its safety check again and wasn't installed. Choose Check for Updates… to try once more."
        }
        return plainSentence
    }

    private var plainSentence: String {
        switch self {
        case .refused(let v):
            return "The update to Maugham \(v) didn't pass its safety check and wasn't installed. Maugham will download it again."
        case .failed(let v, _):
            return "The update to Maugham \(v) couldn't be installed. Maugham will try again."
        }
    }

    /// Read `install-status` from `updatesDirectory` and remove it —
    /// unconditionally, even when it does not parse: a stale or garbled line
    /// must never be read twice (a later successful install writes nothing, so
    /// an old line left behind would otherwise outlive it).
    static func consume(in updatesDirectory: URL) -> InstallStatus? {
        let file = updatesDirectory.appendingPathComponent(UpdateInstaller.installStatusFileName)
        let data = try? Data(contentsOf: file) // adr-0018-ok: the update helper's status line, not a manuscript
        try? FileManager.default.removeItem(at: file)
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }
}
