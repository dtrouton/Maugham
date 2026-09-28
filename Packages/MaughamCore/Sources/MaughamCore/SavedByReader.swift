import Foundation

/// **Who iCloud says last saved a file** (your devices are you, plan 2 Task 3;
/// ruling P2-3) — the one reader of the ubiquitous most-recent-editor name.
///
/// The spike (`docs/superpowers/notes/2026-09-27-person-key-spike.md` §4)
/// measured what the OS answers, and this reader passes that answer through
/// without adding to it:
///
/// - **nil for a file the CURRENT user saved last.** On the book owner's Mac
///   every file the owner saved reads nil (107 of 108 in a real shared
///   folder), so this reader can never say the owner's own save was somebody
///   else's — it has no name to say.
/// - **the other participant's name** for a file they saved last. Apple's
///   servers set it, not the file's content, which is why the admission sheet
///   may draw it beside a device's own claim as an independent hint.
/// - **nil everywhere else**: a file that is not in iCloud, a folder that is
///   not shared, a file that does not exist, a value that has not arrived, and
///   a name that formats to nothing. It never invents one.
///
/// It never throws. It does a single `resourceValues(forKeys:)` — disk and
/// possibly a daemon round trip — so callers must never ask it on the main
/// actor; the Mac's admission refresh asks it from a detached task.
///
/// `FileURLShareMetadataReader` requests the same key for the share pill and
/// never reads it; this is the file that does (`TripwireGrepTests`' census).
public protocol SavedByReading: Sendable {
    /// The formatted name of whoever iCloud says saved `url` last, or nil.
    func name(ofFileAt url: URL) -> String?
}

public struct SavedByReader: SavedByReading {

    public init() {}

    public func name(ofFileAt url: URL) -> String? {
        guard let values = try? url.resourceValues(
            forKeys: [.ubiquitousSharedItemMostRecentEditorNameComponentsKey])
        else { return nil }
        return Self.formatted(values.ubiquitousSharedItemMostRecentEditorNameComponents)
    }

    /// The components as one display name, or nil when there are none or
    /// they format to nothing but whitespace. Internal so the rule is pinned
    /// without iCloud.
    static func formatted(_ components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let name = PersonNameComponentsFormatter()
            .string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

extension SavedByReading {
    /// **Who iCloud says saved each of these devices' records**, keyed by
    /// the device fingerprint — the record's own filename,
    /// `<devices directory>/<fingerprint>.json`. A fingerprint with no answer is
    /// absent from the map, never present with an empty name, so a caller
    /// cannot draw a line about a save nobody reported.
    public func savedBy(
        deviceRecordsOf fingerprints: [String], in projectURL: URL
    ) -> [String: String] {
        var names: [String: String] = [:]
        for fingerprint in fingerprints {
            // `directoryURL` is the read (tripwire 40 keeps the writer's own
            // `url(` in the writer's files); the name is the record's filename.
            let url = RegistryWriter.directoryURL(.devices, in: projectURL)
                .appendingPathComponent("\(fingerprint).json")
            let name = name(ofFileAt: url)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { names[fingerprint] = name }
        }
        return names
    }
}
