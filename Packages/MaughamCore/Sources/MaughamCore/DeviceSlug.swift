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
public enum DeviceSlug {
    public static func make(from device: String) -> String {
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
        return "\(prefix)-\(StableHash.fnv1a32Hex(device))"
    }
}
