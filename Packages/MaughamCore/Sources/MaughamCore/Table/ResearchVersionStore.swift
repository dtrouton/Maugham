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
///   stamp's (to the second) when the meta's date doesn't read.
/// - `writtenBy` is whose bytes they were, nil when no one said (a sidecar
///   from before 9d, or a value this build doesn't know).
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
///   listing (`versions`) is every device's complete pairs, newest first,
///   derived by scanning — no shared counter. A crash between the two moves
///   leaves a lone `.json`, swept once stale (`sweepLeftovers`).
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

    /// How old a staging file, or this device's lone `.json`, must be before
    /// it is swept: one a crash left behind, never a save in progress.
    public static let staleStagingAge: TimeInterval = 10 * 60

    public enum ReadError: Error, LocalizedError, Equatable {
        /// The version's `.json` is missing or not JSON: its bytes alone
        /// would restore without their formats, so nothing is read.
        case metaUnreadable(String)
        public var errorDescription: String? {
            switch self {
            case .metaUnreadable(let name):
                return "the research version \(name) has no readable record beside it; nothing was read"
            }
        }
    }

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

        /// The `-n` the name carries, 1 when none: a last dash-part of one
        /// to three digits, at least 2 (`suffixLimit` is 100; a real slug
        /// ends in its eight-hex hash, never that short).
        var suffix: Int {
            guard let dash = rest.lastIndex(of: "-") else { return 1 }
            let tail = rest[rest.index(after: dash)...]
            guard (1...3).contains(tail.count), tail.allSatisfy(\.isASCIIDigitCharacter),
                  let n = Int(tail), n >= 2 else { return 1 }
            return n
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

    /// What `itemId`'s folder holds, skipping dot-named entries by NAME
    /// (`DotfileScan`, whatever the hidden flag — so a staging file and an
    /// iCloud placeholder `.<name>.csv.icloud` are both skipped): the stems
    /// with a `.csv`, and the stems with a `.json` and its modification date.
    /// Empty for an id that cannot name a file or a folder that isn't there.
    private func contents(itemId: String) -> (csv: Set<String>, json: [String: Date]) {
        guard let folderURL = try? itemFolderURL(itemId),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
        else { return ([], [:]) }
        var csv: Set<String> = [], json: [String: Date] = [:]
        for entry in entries where !DotfileScan.isDotfile(entry) {
            let stem = entry.deletingPathExtension().lastPathComponent
            switch entry.pathExtension {
            case "csv": csv.insert(stem)
            case "json":
                json[stem] = (try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
            default: break
            }
        }
        return (csv, json)
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
        sweepLeftovers(itemId: itemId, device: device)

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
    /// `savedAt`, then stamp, then the `-n` as a number). Derived from the
    /// folder's listing. A version lists only once BOTH its `.csv` and a
    /// readable `.json` are here: another device's pair can arrive one file
    /// at a time, and a `.csv` alone would restore without its formats; a
    /// meta that reads but whose fields don't is dated by its stamp.
    ///
    /// Another device's version iCloud has not downloaded yet (its files are
    /// `.<name>.icloud` placeholders) is not listed until it arrives; the
    /// listing asks for no download. Empty for an id that cannot name a file.
    public func versions(itemId: String) -> [ResearchVersion] {
        let (csv, json) = contents(itemId: itemId)
        return csv.intersection(json.keys).compactMap { name -> (ResearchVersion, ParsedName)? in
            guard let parsed = Self.parse(name), let stamped = Self.stampDate(parsed.stamp),
                  let meta = try? readMeta(name, itemId: itemId) else { return nil }
            return (ResearchVersion(itemId: itemId, name: name,
                                    savedAt: meta.savedAt ?? stamped, writtenBy: meta.writtenBy), parsed)
        }
        .sorted { a, b in
            (a.0.savedAt, a.1.stamp, a.1.suffix, a.0.name) > (b.0.savedAt, b.1.stamp, b.1.suffix, b.0.name)
        }
        .map(\.0)
    }

    /// **A version's bytes and the sidecar that described them** (nil when
    /// the table had none). Both files are read through a coordinated read,
    /// so a file iCloud evicted since the listing is downloaded first. Throws
    /// `ReadError.metaUnreadable` when the `.json` is missing or not JSON —
    /// a restore never silently drops the formats — and whatever the read
    /// throws for the bytes.
    public func read(_ version: ResearchVersion) throws -> (Data, ResearchTableSidecar?) {
        let meta: Meta
        do { meta = try readMeta(version.name, itemId: version.itemId) } catch {
            throw ReadError.metaUnreadable(version.name)
        }
        let bytes = try Self.coordinatedRead(fileURL(version.name + ".csv", itemId: version.itemId))
        return (bytes, meta.sidecar)
    }

    private func readMeta(_ name: String, itemId: String) throws -> Meta {
        let data = try Self.coordinatedRead(fileURL(name + ".json", itemId: itemId))
        return try Self.decoder().decode(Meta.self, from: data)
    }

    /// `url`'s bytes under an `NSFileCoordinator` read, which brings an
    /// evicted iCloud file down before the block runs.
    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }  // adr-0018-ok: a kept Research table version or its meta JSON, not manuscript
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    // MARK: - Pruning

    /// **Removes `device`'s versions of `itemId` past the newest `keep`**
    /// (by stamp, then the `-n` as a number), then this device's leftovers
    /// (`sweepLeftovers`), and the item's folder if that left it empty.
    /// Another device's files are never touched (tripwire 17). A failed
    /// removal is left for the next prune.
    public func prune(itemId: String, device: DeviceSlug, keep: Int = ResearchVersionStore.retention) {
        let own = contents(itemId: itemId).csv
            .compactMap { name in Self.parse(name).flatMap { $0.isFrom(device) ? (name, $0) : nil } }
            .sorted { ($0.1.stamp, $0.1.suffix) > ($1.1.stamp, $1.1.suffix) }
        for (name, _) in own.dropFirst(max(keep, 0)) { remove(name, itemId: itemId) }
        sweepLeftovers(itemId: itemId, device: device)
        removeFolderIfEmpty(itemId: itemId)
    }

    /// **Removes `device`'s files of every item not in `liveItemIds`** — one
    /// deleted for good; an item in the Trash is live — a `.json` whose
    /// `.csv` never landed included, and the item's folder once nothing is
    /// left in it. Another device's files are never touched (tripwire 17).
    public func sweepOrphans(liveItemIds: Set<String>, device: DeviceSlug) {
        guard let root = try? SafeRelativePath.resolve(Self.folder, under: projectURL),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [])
        else { return }
        for entry in entries where !DotfileScan.isDotfile(entry) {
            let itemId = entry.lastPathComponent
            guard !liveItemIds.contains(itemId) else { continue }
            let (csv, json) = contents(itemId: itemId)
            for name in csv.union(json.keys) where Self.parse(name)?.isFrom(device) == true {
                remove(name, itemId: itemId)
            }
            sweepLeftovers(itemId: itemId, device: device)
            removeFolderIfEmpty(itemId: itemId)
        }
    }

    /// **What a crash mid-`keep` left in `itemId`'s folder**, once older than
    /// `staleStagingAge` (never another save's in progress): any `.staging-*`
    /// file, and `device`'s own `.json` whose `.csv` never landed. Another
    /// device's lone `.json` is its pair still arriving, and stays.
    func sweepLeftovers(itemId: String, device: DeviceSlug, now: Date = Date()) {
        let fm = FileManager.default
        guard let folderURL = try? itemFolderURL(itemId) else { return }
        // The staging files are dot-named on purpose, so this listing never
        // skips hidden files.
        let entries = (try? fm.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-") {
            guard let stamp = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                  now.timeIntervalSince(stamp) > Self.staleStagingAge else { continue }
            try? fm.removeItem(at: entry)  // raw-delete: derived, a crashed save's staging file
        }
        let (csv, json) = contents(itemId: itemId)
        for (name, modified) in json where !csv.contains(name)
            && now.timeIntervalSince(modified) > Self.staleStagingAge
            && Self.parse(name)?.isFrom(device) == true {
            if let url = try? fileURL(name + ".json", itemId: itemId) {
                try? fm.removeItem(at: url)  // raw-delete: derived, a crashed save's lone meta
            }
        }
    }

    /// `rmdir` removes the folder only when it is empty: another device's
    /// versions, or one arriving, keep it.
    private func removeFolderIfEmpty(itemId: String) {
        if let folderURL = try? itemFolderURL(itemId) { _ = rmdir(folderURL.path) }
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
