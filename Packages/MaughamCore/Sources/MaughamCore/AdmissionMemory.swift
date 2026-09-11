import Foundation
import os

/// The one thing this type can fail at quietly: the memory could not be
/// persisted, so a decision the writer made this morning is gone by tonight.
private let admissionMemoryLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.core",
    category: "AdmissionMemory")

/// **What this writer has already decided to call a device** — decision B2's
/// memory, device-local, beside `registry-cache.json` (spec §2.4).
///
/// A phone reaches a second book, a third, a tenth. The sheet that asks *who is
/// this?* is worth putting up once; putting it up in every project the phone
/// syncs into is the same question ten times, and the honest answer to the
/// second one is *you already told me*. So the label is kept here, by device
/// fingerprint, and `RegistryPresence.admitRemembered` writes the person record
/// at open without asking.
///
/// **Keyed by device and by nothing else.** `RegistryCache` is a memory of a
/// FOLDER and is pruned with the project whose folder it describes. This is a
/// memory of a DECISION, and a project going away is no reason to forget that
/// the writer once said this phone is Denver. Nothing prunes it; the writer
/// forgets a device from People & Devices, which is the only thing that should.
///
/// **`labelledAt` is when the decision was made**, not when it was last used.
/// Silent admission calls `remember` again on every open it acts on, so
/// `remember` deliberately keeps the existing date when the label is unchanged
/// — a date that moved every morning would make *remembered from Playlist*
/// false about the only thing it claims.
///
/// **Identity-scoped, like the cache.** A label is one writer's word on one
/// machine. A file written under another identity is not this device's memory
/// and starts empty, and the next write takes the file over.
public final class AdmissionMemory: @unchecked Sendable {

    /// The writer's word for one device, and when they chose it.
    ///
    /// `ownName` is the device's own name as it was when the writer decided.
    /// It is kept because a surface has to be able to name a device whose
    /// record is not in this project at all — the *Forget this device* row for
    /// a fingerprint that is remembered and absent has nothing else to show.
    /// Where a device record IS present, that record is the device saying its
    /// name now, and it wins.
    public struct Label: Codable, Equatable, Sendable {
        public var label: String
        public var ownName: String
        /// When the writer decided on this label.
        ///
        /// **Compare it to a person record's `admittedAt` with a STRICT `<`.**
        /// A silent admission is one whose label was decided in an earlier book,
        /// so its `labelledAt` is genuinely earlier; a sheet admission decides
        /// the label and writes the record in one act, from one clock, so the
        /// two are EQUAL. A `<=` would read every admission the writer made by
        /// hand as one nobody was asked about.
        public var labelledAt: Date

        public init(label: String, ownName: String, labelledAt: Date) {
            self.label = label
            self.ownName = ownName
            self.labelledAt = labelledAt
        }
    }

    /// Decode-tolerant on purpose, as `RegistryCache.Stored` is: every field is
    /// read with `decodeIfPresent` and a default, so a shape this build does not
    /// recognise costs at most the fields it cannot read. With the synthesized
    /// `Codable` a single future non-optional field would fail the whole decode
    /// and silently empty the memory — and an empty label memory is the writer
    /// being asked about every device they have ever named, all over again.
    private struct Stored: Codable, Equatable {
        var identity: String = ""
        var devices: [String: Label] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identity = try container.decodeIfPresent(String.self, forKey: .identity) ?? ""
            devices = try container.decodeIfPresent(
                [String: Label].self, forKey: .devices) ?? [:]
        }
    }

    public let fileURL: URL
    /// The fingerprint this memory belongs to.
    public let identity: String
    private let lock = NSLock()
    private var stored: Stored

    /// Loads whatever is at `fileURL` **and belongs to `identity`**, or starts
    /// empty. An unreadable or undecodable file starts empty: this is a memory,
    /// not a source of truth, and an empty one simply asks the writer again.
    public init(fileURL: URL, identity: String = DeviceIdentity.author.fingerprint) {
        self.fileURL = fileURL
        self.identity = identity
        let bytes = try? Data(contentsOf: fileURL)  // adr-0018-ok: this device's own admission memory — derived bookkeeping, never manuscript text
        let decoded = bytes.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        if let decoded, decoded.identity == identity {
            self.stored = decoded
            return
        }
        var fresh = Stored()
        fresh.identity = identity
        self.stored = fresh
        // `persistLocked` without the lock, and the one place that is right:
        // `self` is still under construction, so nothing else can be holding it
        // (the same call `RegistryCache` makes from its own init).
        if bytes != nil { persistLocked() }
    }

    /// The process-wide memory, beside this device's key material, the op-log
    /// heads and the registry cache.
    public static let shared = AdmissionMemory(
        fileURL: DeviceState.directory.appendingPathComponent("admission-memory.json"),
        identity: DeviceIdentity.author.fingerprint)

    // MARK: - Asking

    /// What this writer calls that device, if they have ever said.
    public func label(for fingerprint: String) -> Label? {
        lock.lock()
        defer { lock.unlock() }
        return stored.devices[fingerprint]
    }

    /// Every device this writer has named — what People & Devices lists,
    /// including a fingerprint no record in this project mentions.
    public var remembered: [String: Label] {
        lock.lock()
        defer { lock.unlock() }
        return stored.devices
    }

    // MARK: - Deciding

    /// Record that this writer calls `fingerprint` by `label`.
    ///
    /// **The date moves only when the decision does.** A label unchanged from
    /// what is already here keeps its original `labelledAt` — silent admission
    /// re-states a remembered label on every project it acts on, and it is
    /// using the decision, not making it. `ownName` is refreshed either way: it
    /// is a fact about the device, and a renamed phone should read as its new
    /// name wherever this memory is what a surface has.
    public func remember(
        _ fingerprint: String, label: String, ownName: String, at when: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        let existing = stored.devices[fingerprint]
        let decided = existing.flatMap { $0.label == label ? $0.labelledAt : nil } ?? when
        let entry = Label(label: label, ownName: ownName, labelledAt: decided)
        guard stored.devices[fingerprint] != entry else { return }
        stored.devices[fingerprint] = entry
        persistLocked()
    }

    /// Forget one device — People & Devices' *Forget this device*, and the only
    /// thing that removes an entry here.
    public func forget(_ fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        guard stored.devices.removeValue(forKey: fingerprint) != nil else { return }
        persistLocked()
    }

    // MARK: - Persistence

    /// Call with `lock` held — or from `init`, where there is no `self` to
    /// share yet. Atomic, so a crash mid-write leaves the previous memory
    /// rather than a truncated one.
    private func persistLocked() {
        do {
            try DeviceState.ensureDirectory(fileURL.deletingLastPathComponent())
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            admissionMemoryLog.error("""
                Could not persist the admission memory at \
                \(self.fileURL.path, privacy: .public): \
                \(String(describing: error), privacy: .public). \
                A label decided now will be asked for again.
                """)
        }
    }
}
