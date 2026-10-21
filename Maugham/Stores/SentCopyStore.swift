import Foundation
import MaughamCore

/// **What a Word export sent** (report plan 4, R-4-4; spec §6.3): one folder
/// per export at `.maugham/exports/<book>/<export-id>/`, holding the
/// `export.docx` exactly as it left and a `sent.json` naming its label, its
/// draft and every exported piece's paragraphs (`¶id`, text). A returned file
/// is later compared against what was sent, not against the current text.
///
/// - `<book>` is `book`, or the imprint's name (`WordDraft.book(of:)`).
/// - `<export-id>` is `yyyyMMdd-HHmmss-<deviceSlug>` (UTC), with `-2`, `-3`…
///   after it for a second export from one device in one second. The slug is
///   the writing device's (tripwire 24), so two devices never write one
///   folder (tripwire 17); each folder is written once and never rewritten.
/// - A book's drafts are DERIVED by scanning its folder (`drafts(book:)`), so
///   no counter is shared between devices.
///
/// A folder is written whole: staged under a dot-named sibling, then moved
/// into place, so a reader never meets half a sent copy. Written only after a
/// successful export (`CompileOrchestrator`); a republish writes none — it is
/// the same draft, re-rendered.
///
/// Excluded from the backup signature (`BackupSignature`): reproducible
/// history, not working state.
@MainActor
struct SentCopyStore {

    let projectURL: URL

    // MARK: the record

    /// `sent.json`.
    struct SentCopy: Codable, Equatable, Sendable {
        /// "Draft 3, sent 21 October 2026" — as the `.docx` carries it.
        var label: String
        var draft: Int
        var sentAt: Date
        /// The edition's language identity (`en`, `en+sr`).
        var language: String
        /// `WordDraft.book(of:)`.
        var book: String
        /// The source body's pieces in book order (R-S2); a translated body is
        /// not recorded.
        var pieces: [Piece]
    }

    struct Piece: Codable, Equatable, Sendable {
        var pieceID: String
        var title: String
        var paragraphs: [Paragraph]
    }

    struct Paragraph: Codable, Equatable, Sendable {
        var id: String
        var text: String
    }

    /// One sent copy found on disk. `copy` is nil when its `sent.json` can't
    /// be read here (not yet downloaded, or damaged): the folder still counts
    /// as a draft sent.
    struct Draft: Equatable {
        let exportID: String
        let copy: SentCopy?
    }

    static let docxName = "export.docx"
    static let recordName = "sent.json"

    // MARK: paths

    /// `.maugham/exports/` — the one spelling of the folder.
    nonisolated static func directory(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/exports", isDirectory: true)
    }

    nonisolated static func directory(book: String, in projectURL: URL) -> URL {
        directory(in: projectURL).appendingPathComponent(book, isDirectory: true)
    }

    /// `yyyyMMdd-HHmmss-<slug>`, the time in UTC. The slug is interpolated
    /// here and nowhere else (tripwire 24).
    nonisolated static func exportID(sentAt: Date, device: DeviceSlug) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: sentAt) + "-" + device.raw
    }

    // MARK: reading

    /// Every sent copy of `book`, oldest first by export id. A dotfile (a
    /// staging folder, an iCloud placeholder) is skipped by name; the scan
    /// never uses `.skipsHiddenFiles` (`DotfileScan`).
    func drafts(book: String) -> [Draft] {
        let folder = Self.directory(book: book, in: projectURL)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        let decoder = Self.decoder()
        return entries
            .filter { !DotfileScan.isDotfile($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { entry in
                let record = entry.appendingPathComponent(Self.recordName)
                let data = try? Data(contentsOf: record)  // adr-0018-ok: a Word export's sent.json, derived sidecar, not manuscript
                return Draft(exportID: entry.lastPathComponent,
                             copy: data.flatMap { try? decoder.decode(SentCopy.self, from: $0) })
            }
    }

    // MARK: writing

    /// How many `-n` suffixes one device's second is offered before the write
    /// gives up: far past any real burst of exports.
    static let suffixLimit = 100

    enum WriteError: Error, LocalizedError, Equatable {
        case noFreeExportID(String)
        var errorDescription: String? {
            switch self {
            case .noFreeExportID(let id):
                return "every sent-copy name from \(id) on is taken; nothing was overwritten"
            }
        }
    }

    /// Writes one sent copy — `docx` copied in as `export.docx`, and `copy` as
    /// `sent.json` — and returns its folder. Staged whole in a dot-named
    /// sibling and moved into place under the first free export id: a second
    /// export from one device in one second takes `-2`, never an existing
    /// folder (a move onto one fails, so nothing is overwritten).
    @discardableResult
    func write(_ copy: SentCopy, docx: URL,
               device: DeviceSlug = DeviceIdentity.author.slug) throws -> URL {
        let fm = FileManager.default
        let book = Self.directory(book: copy.book, in: projectURL)
        let id = Self.exportID(sentAt: copy.sentAt, device: device)

        try fm.createDirectory(at: book, withIntermediateDirectories: true)
        Self.sweepStaleStaging(in: book)
        let staging = book.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: docx, to: staging.appendingPathComponent(Self.docxName))
        try Self.encoder().encode(copy).write(to: staging.appendingPathComponent(Self.recordName))
        for n in 1...Self.suffixLimit {
            let destination = book.appendingPathComponent(n == 1 ? id : "\(id)-\(n)", isDirectory: true)
            if fm.fileExists(atPath: destination.path) { continue }
            do {
                try fm.moveItem(at: staging, to: destination)
                return destination
            } catch where fm.fileExists(atPath: destination.path) {
                continue  // taken between the look and the move
            }
        }
        throw WriteError.noFreeExportID(id)
    }

    /// How old a staging folder must be before a write sweeps it: one a
    /// crash or a kill left behind, never another export's in progress.
    static let staleStagingAge: TimeInterval = 10 * 60

    /// Removes the `.staging-*` folders under `book` older than
    /// `staleStagingAge`. A failed removal is left for the next write.
    static func sweepStaleStaging(in book: URL, now: Date = Date()) {
        let fm = FileManager.default
        // The staging folders are dot-named on purpose, so the listing never
        // skips hidden files (`DotfileScan`'s rule, the other way round).
        guard let entries = try? fm.contentsOfDirectory(
            at: book, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey])
        else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-") {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            guard let stamp = values?.contentModificationDate ?? values?.creationDate,
                  now.timeIntervalSince(stamp) > staleStagingAge else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: coding

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
