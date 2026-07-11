import Foundation

/// Derives a filename-safe, stable-per-device slug from an op's `device`
/// identifier, for per-device JSONL partitioning (ADR 0012, spec §3.12).
///
/// Each device writes only to its own `<docId>.<slug>.jsonl` so iCloud Drive
/// never has to reconcile concurrent appends to one path (which it resolves by
/// whole-file replace, silently dropping the loser as a conflict-twin the
/// loader never opens). The slug must be:
///   - filename-safe (the `device` string is a hostname or `phone:<uuid>` —
///     may contain dots, colons, spaces);
///   - stable for a given `device` string across launches (so a device keeps
///     writing to the same file);
///   - collision-resistant after sanitization/truncation (hence the hash
///     suffix — two hosts that sanitize to the same prefix still differ).
///
/// A construction-safe value type (tripwire 24): the only way to obtain one is
/// `make(from:)` (or the test-only `unsafeForTesting(_:)`), so a hand-written
/// slug string can never be passed where a `DeviceSlug` is expected — that's a
/// compile error at every filename-construction seam (op-log/segment/inbox/
/// pending paths). Interpolate `.raw` at the filename point; never elsewhere
/// synthesize the string. The slug lives ONLY in filenames — it is never
/// serialized into JSONL/manifest content — so this is a type-level guard, not
/// a wire-format change.
public struct DeviceSlug: Equatable, Hashable, Sendable {
    /// The filename-safe slug string. The sole interpolation surface; use it at
    /// filename-construction points and nowhere else.
    public let raw: String

    private init(raw: String) { self.raw = raw }

    public static func make(from device: String) -> DeviceSlug {
        let lowered = device.lowercased()
        // Map anything that isn't [a-z0-9] to '-', collapse runs, trim.
        var sanitized = ""
        var lastWasDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                sanitized.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                sanitized.append("-")
                lastWasDash = true
            }
        }
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let prefix = trimmed.isEmpty ? "device" : String(trimmed.prefix(24))
        return DeviceSlug(raw: "\(prefix)-\(StableHash.fnv1a32Hex(device))")
    }

    /// Test-only escape hatch: wrap an ARBITRARY string as a `DeviceSlug`
    /// WITHOUT sanitize/hash, so filename-shape contract tests can assert exact
    /// templates (e.g. `inbox.phoneA-1234.jsonl`) against a known slug. Reachable
    /// only via `@testable import MaughamCore`; production surfaces import
    /// MaughamCore normally and so cannot see it — the `internal` access level is
    /// the guard. NEVER use in production.
    static func unsafeForTesting(_ raw: String) -> DeviceSlug { DeviceSlug(raw: raw) }
}
