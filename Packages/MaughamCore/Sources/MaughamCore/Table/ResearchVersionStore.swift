import Foundation

/// **Who wrote a Research table's bytes** (spec §10.1, report plan 9d): the
/// writer, or the assistant over MCP. A Research label, never a signature —
/// Research is unsigned (spec §4.2).
public enum ResearchWriter: String, Codable, Equatable, Sendable {
    case writer
    case assistant
}

/// **One kept version of a Research table**, found on disk by
/// `ResearchVersionStore.versions(itemId:)`: the bytes a save replaced.
///
/// - `name` is the version's file stem, `<stamp>-<deviceSlug>[-n]`; its
///   `.csv` holds the prior bytes exactly and its `.json` the meta.
/// - `savedAt` is when those bytes were superseded: the meta's, or the
///   stamp's (to the second) when the meta can't be read here.
/// - `writtenBy` is whose bytes they were, nil when no one said (a sidecar
///   from before 9d, or a meta not yet downloaded).
public struct ResearchVersion: Equatable, Hashable, Sendable {
    public let itemId: String
    public let name: String
    public let savedAt: Date
    public let writtenBy: ResearchWriter?

    public init(itemId: String, name: String, savedAt: Date, writtenBy: ResearchWriter?) {
        self.itemId = itemId
        self.name = name
        self.savedAt = savedAt
        self.writtenBy = writtenBy
    }

    /// True when `device` kept this version: its name is the stamp, then
    /// exactly `device`'s slug, then at most a `-n` suffix.
    public func isKept(by device: DeviceSlug) -> Bool {
        ResearchVersionStore.parse(name)?.isFrom(device) ?? false
    }
}

/// **Every save of a Research table keeps the previous version** (spec
/// §10.1, report plan 9d Task 1): the bytes on disk before the save, exactly
/// (BOM and encoding kept), and the sidecar that described them, at
/// `.maugham/research-versions/<itemId>/<stamp>-<deviceSlug>[-n].csv` plus
/// `.json`.
///
/// - **Write-once, per device** (tripwire 17): the writing device's slug is in
///   every name (tripwire 24 — a `DeviceSlug`, never a hand-built string), so
///   two devices never write one file; each file is staged under a dot-named
///   sibling and moved into place, a move onto an existing name fails, and the
///   next free `-2`, `-3`… is taken instead. Nothing is ever rewritten.
/// - **Each device prunes only its own** (`prune`, `sweepOrphans`); the
///   listing (`versions`) is every device's, newest first, derived by
///   scanning — no shared counter.
/// - The item id comes from the synced manifest and a listed name from a
///   synced folder, so every path is resolved through `SafeRelativePath`
///   (`requireDocId` + `resolveFile`, tripwire 58); listings skip by NAME
///   (`DotfileScan`), never by the hidden flag.
/// - **Versions follow the item id**: the caller keeps them while the item is
///   in the Trash (it counts as live for `sweepOrphans`).
///
/// Shared by both apps (tripwire 19); the Mac's `ResearchTableHost` is the one
/// writer.
public struct ResearchVersionStore: Sendable {

    public let projectURL: URL

    public init(projectURL: URL) {
        self.projectURL = projectURL
    }

    /// The folder every item's versions live under, project-relative. Spelled
    /// here only (`MaughamSidecarPath` asks it).
    public static let folder = ".maugham/research-versions"

    /// How many versions of one table each device keeps (plan 9d ruling).
    public static let retention = 50

    /// How many `-n` suffixes one device's second is offered before `keep`
    /// gives up: far past any real burst of saves.
    public static let suffixLimit = 100

    /// How old a staging file must be before `keep` sweeps it: one a crash
    /// left behind, never another save's in progress.
    public static let staleStagingAge: TimeInterval = 10 * 60

    public enum KeepError: Error, LocalizedError, Equatable {
        case noFreeName(String)
        public var errorDescription: String? {
            switch self {
            case .noFreeName(let name):
                return "every research version name from \(name) on is taken; nothing was overwritten"
            }
        }
    }

    // MARK: - The meta

    /// A version's `.json`: when it was superseded, whose bytes they were,
    /// their `ContentHash`, and the sidecar that described them, whole (so a
    /// restore brings back the formats). Tolerant (ADR 0015).
    struct Meta: Codable, Equatable {
        var savedAt: Date?
        var writtenBy: ResearchWriter?
        var contentHash: String?
        var sidecar: ResearchTableSidecar?

        enum CodingKeys: String, CodingKey {
            case savedAt = "saved_at"
            case writtenBy = "written_by"
            case contentHash = "content_hash"
            case sidecar
        }

        init(savedAt: Date?, writtenBy: ResearchWriter?, contentHash: String?, sidecar: ResearchTableSidecar?) {
            self.savedAt = savedAt
            self.writtenBy = writtenBy
            self.contentHash = contentHash
            self.sidecar = sidecar
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            savedAt = (try? c.decodeIfPresent(Date.self, forKey: .savedAt)) ?? nil
            writtenBy = (try? c.decodeIfPresent(ResearchWriter.self, forKey: .writtenBy)) ?? nil
            contentHash = (try? c.decodeIfPresent(String.self, forKey: .contentHash)) ?? nil
            sidecar = (try? c.decodeIfPresent(ResearchTableSidecar.self, forKey: .sidecar)) ?? nil
        }
    }

    // MARK: - Names

    /// A version name's parts: `<yyyyMMdd-HHmmss>-<slug>[-n]`.
    struct ParsedName: Equatable {
        let stamp: String
        /// Everything after the stamp's dash: the slug, with any `-n`.
        let rest: String

        func isFrom(_ device: DeviceSlug) -> Bool {
            if rest == device.raw { return true }
            let prefix = device.raw + "-"
            guard rest.hasPrefix(prefix) else { return false }
            let n = rest.dropFirst(prefix.count)
            return !n.isEmpty && n.allSatisfy(\.isASCIIDigitCharacter) && (Int(n) ?? 0) >= 2
        }

        /// The `-n` this device's name carries (1 when none).
        func suffix(for device: DeviceSlug) -> Int {
            rest == device.raw ? 1 : Int(rest.dropFirst(device.raw.count + 1)) ?? 1
        }
    }

    static let stampLength = 15  // yyyyMMdd-HHmmss

    static func parse(_ name: String) -> ParsedName? {
        guard name.count > stampLength + 1 else { return nil }
        let stamp = String(name.prefix(stampLength))
        guard stampDate(stamp) != nil,
              name[name.index(name.startIndex, offsetBy: stampLength)] == "-" else { return nil }
        return ParsedName(stamp: stamp, rest: String(name.dropFirst(stampLength + 1)))
    }

    private static func stampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    static func stamp(_ date: Date) -> String { stampFormatter().string(from: date) }

    static func stampDate(_ stamp: String) -> Date? {
        guard stamp.count == stampLength else { return nil }
        return stampFormatter().date(from: stamp)
    }

    /// `<stamp>-<slug>`, the time in UTC. The slug is interpolated here and
    /// nowhere else (tripwire 24).
    static func baseName(at date: Date, device: DeviceSlug) -> String {
        stamp(date) + "-" + device.raw
    }

    // MARK: - Paths

    /// `<folder>/<itemId>`, after checking the id can name a file.
    private static func itemFolder(_ itemId: String) throws -> String {
        try SafeRelativePath.requireDocId(itemId)
        return folder + "/" + itemId
    }

    private func fileURL(_ name: String, itemId: String) throws -> URL {
        try SafeRelativePath.resolveFile(named: name, in: Self.itemFolder(itemId), under: projectURL)
    }

    private func itemFolderURL(_ itemId: String) throws -> URL {
        try SafeRelativePath.resolveFile(
            named: SafeRelativePath.requireDocId(itemId), in: Self.folder, under: projectURL)
    }

    /// The version stems in `itemId`'s folder: each `.csv` not dot-named,
    /// whatever its hidden flag (`DotfileScan`). Empty for an id that cannot
    /// name a file or a folder that isn't there.
    private func stems(itemId: String) -> [String] {
        guard let folderURL = try? itemFolderURL(itemId),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: folderURL, includingPropertiesForKeys: nil, options: [])
        else { return [] }
        return entries
            .filter { !DotfileScan.isDotfile($0) && $0.pathExtension == "csv" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    // MARK: - Keeping

    /// **Keeps `priorBytes`** — what was on disk before a save — with
    /// `priorSidecar`, the sidecar that described them, and `writtenBy`, whose
    /// bytes they were, as one new version of `itemId` named for `device` and
    /// `at`. Written once: the `.json` then the `.csv`, each staged and moved
    /// into place, under the first free `-n`. Throws for an id that cannot
    /// name a file (`SafeRelativePath.PathError.notADocId`) before anything is
    /// written.
    @discardableResult
    public func keep(priorBytes: Data, priorSidecar: ResearchTableSidecar?, writtenBy: ResearchWriter?,
                     itemId: String, device: DeviceSlug, at date: Date) throws -> ResearchVersion {
        let fm = FileManager.default
        let folderURL = try itemFolderURL(itemId)
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        Self.sweepStaleStaging(in: folderURL)

        let meta = Meta(savedAt: date, writtenBy: writtenBy,
                        contentHash: ContentHash.of(priorBytes), sidecar: priorSidecar)
        let metaStaging = folderURL.appendingPathComponent(".staging-\(UUID().uuidString).json") // local-path: a staging name minted here
        let csvStaging = folderURL.appendingPathComponent(".staging-\(UUID().uuidString).csv") // local-path: a staging name minted here
        defer {
            try? fm.removeItem(at: metaStaging)  // raw-delete: derived staging file
            try? fm.removeItem(at: csvStaging)   // raw-delete: derived staging file
        }
        let metaBytes = try Self.encoder().encode(meta)
        // The date as it reads back from disk, so this answer equals the listing's.
        let savedAt = (try? Self.decoder().decode(Meta.self, from: metaBytes))?.savedAt ?? date
        try metaBytes.write(to: metaStaging)
        try priorBytes.write(to: csvStaging)

        let base = Self.baseName(at: date, device: device)
        for n in 1...Self.suffixLimit {
            let name = n == 1 ? base : "\(base)-\(n)"
            let metaURL = try fileURL(name + ".json", itemId: itemId)
            let csvURL = try fileURL(name + ".csv", itemId: itemId)
            if fm.fileExists(atPath: metaURL.path) || fm.fileExists(atPath: csvURL.path) { continue }
            do {
                try fm.moveItem(at: metaStaging, to: metaURL)
            } catch where fm.fileExists(atPath: metaURL.path) {
                continue  // taken between the look and the move
            }
            do {
                try fm.moveItem(at: csvStaging, to: csvURL)
            } catch {
                try? fm.removeItem(at: metaURL)  // raw-delete: derived, the meta this call just placed
                if fm.fileExists(atPath: csvURL.path) {
                    try metaBytes.write(to: metaStaging)
                    continue
                }
                throw error
            }
            return ResearchVersion(itemId: itemId, name: name, savedAt: savedAt, writtenBy: writtenBy)
        }
        throw KeepError.noFreeName(base)
    }

    // MARK: - Reading

    /// **Every kept version of `itemId`**, every device's, newest first (by
    /// `savedAt`, then name). Derived from the folder's listing; a version
    /// whose meta can't be read still lists, dated by its stamp. Empty for an
    /// id that cannot name a file.
    public func versions(itemId: String) -> [ResearchVersion] {
        stems(itemId: itemId).compactMap { name -> ResearchVersion? in
            guard let parsed = Self.parse(name), let stamped = Self.stampDate(parsed.stamp) else { return nil }
            let meta = try? readMeta(name, itemId: itemId)
            return ResearchVersion(itemId: itemId, name: name,
                                   savedAt: meta?.savedAt ?? stamped, writtenBy: meta?.writtenBy)
        }
        .sorted { ($0.savedAt, $0.name) > ($1.savedAt, $1.name) }
    }

    /// **A version's bytes and the sidecar that described them** (nil when
    /// its meta is missing or held none). Throws when the bytes can't be read.
    public func read(_ version: ResearchVersion) throws -> (Data, ResearchTableSidecar?) {
        let url = try fileURL(version.name + ".csv", itemId: version.itemId)
        let bytes = try Data(contentsOf: url)  // adr-0018-ok: a kept Research table version, not manuscript
        let meta = try? readMeta(version.name, itemId: version.itemId)
        return (bytes, meta?.sidecar)
    }

    private func readMeta(_ name: String, itemId: String) throws -> Meta {
        let url = try fileURL(name + ".json", itemId: itemId)
        let data = try Data(contentsOf: url)  // adr-0018-ok: a Research version's meta JSON, not manuscript
        return try Self.decoder().decode(Meta.self, from: data)
    }

    // MARK: - Pruning

    /// **Removes `device`'s versions of `itemId` past the newest `keep`.**
    /// Another device's files are never touched (tripwire 17). A failed
    /// removal is left for the next prune.
    public func prune(itemId: String, device: DeviceSlug, keep: Int = ResearchVersionStore.retention) {
        let own = stems(itemId: itemId)
            .compactMap { name in Self.parse(name).flatMap { $0.isFrom(device) ? (name, $0) : nil } }
            .sorted { ($0.1.stamp, $0.1.suffix(for: device)) > ($1.1.stamp, $1.1.suffix(for: device)) }
        for (name, _) in own.dropFirst(max(keep, 0)) { remove(name, itemId: itemId) }
    }

    /// **Removes `device`'s versions of every item not in `liveItemIds`** —
    /// one deleted for good; an item in the Trash is live — and the item's
    /// folder once nothing is left in it. Another device's files are never
    /// touched (tripwire 17).
    public func sweepOrphans(liveItemIds: Set<String>, device: DeviceSlug) {
        guard let root = try? SafeRelativePath.resolve(Self.folder, under: projectURL),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [])
        else { return }
        for entry in entries where !DotfileScan.isDotfile(entry) {
            let itemId = entry.lastPathComponent
            guard !liveItemIds.contains(itemId) else { continue }
            for name in stems(itemId: itemId) where Self.parse(name)?.isFrom(device) == true {
                remove(name, itemId: itemId)
            }
            // `rmdir` removes the folder only when it is empty: another
            // device's versions, or one arriving, keep it.
            if let folderURL = try? itemFolderURL(itemId) { _ = rmdir(folderURL.path) }
        }
    }

    private func remove(_ name: String, itemId: String) {
        let fm = FileManager.default
        if let url = try? fileURL(name + ".csv", itemId: itemId) {
            try? fm.removeItem(at: url)  // raw-delete: derived, a kept Research version
        }
        if let url = try? fileURL(name + ".json", itemId: itemId) {
            try? fm.removeItem(at: url)  // raw-delete: derived, a kept Research version's meta
        }
    }

    /// Removes the `.staging-*` files in `folder` older than
    /// `staleStagingAge`. The staging files are dot-named on purpose, so this
    /// listing never skips hidden files.
    static func sweepStaleStaging(in folder: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-") {
            guard let stamp = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                  now.timeIntervalSince(stamp) > staleStagingAge else { continue }
            try? fm.removeItem(at: entry)  // raw-delete: derived, a crashed save's staging file
        }
    }

    // MARK: - Coding

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // To the millisecond, so a version reads back with the date it was
        // kept with and two saves in one second still order.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(fractionalISO8601))
        }
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: fractionalISO8601) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
        }
        return decoder
    }

    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
