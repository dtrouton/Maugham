import Foundation
import MaughamCore

/// What a trash entry is a deletion OF. Recorded in `meta.json` at write time
/// so neither the pane nor a restore has to guess from the shape of the
/// metadata blob (a `ResearchItem` decodes cleanly as a `StructureItem`, which
/// is how every restored research note used to land in the manuscript binder).
///
/// Additive-optional on disk (ADR 0015): an entry written before this field
/// existed decodes as `nil`, and the readers fall back to their old behaviour.
public enum TrashSubject: String, Codable, Sendable {
    /// A binder row. Restore rewires `manifest.structure`.
    case manuscriptItem
    /// A research-tree row. Restore rewires `manifest.research`. Carries no
    /// file when the row is manifest-only (a `.link`, RULING-45).
    case researchItem
    /// A capture's asset file, moved out of the inbox by a promotion
    /// (RULING-15). There is no manifest row to rewire: putting the file back
    /// where it was IS the whole restore, and re-ingesting it is the writer's
    /// next act (RULING-14).
    case captureAsset
    /// Maugham's own safety copy of a file the writer never deleted — today,
    /// the prior version of a per-piece style file. Never shown in the Trash
    /// pane: it is not the writer's deletion (RULING-43).
    case internalArtifact
    /// The contents a file HAD, kept because Maugham was about to write over it
    /// on the writer's behalf — today, the research note a canvas Rewrite
    /// replaces (M6-PR-037, RULING-24, 2026-08-09).
    ///
    /// **Visible in the Trash pane, and that is the whole difference from
    /// `internalArtifact`.** A style file's prior version is a paranoia copy
    /// nothing would point at again, so RULING-43 hides it. This one is the
    /// writer's own prose and it is the ONLY route back to it: research is
    /// recoverable but not versioned (RULING-24's middle tier), and a note that
    /// was *deleted* rather than rewritten would be sitting in this same pane.
    /// Hiding it would give a rewrite a weaker guarantee than a delete.
    ///
    /// Restores as a FILE — there is no manifest row to rewire, because the row
    /// still exists and points at the rewritten note. It lands beside the live
    /// note under a deduped filename (`destinationBesideAnyOccupant`), so
    /// nothing is overwritten and both are visible.
    case priorVersion
}

/// Per-project trash directory operations. Lives at <projectURL>/.trash/
/// with each trashed item in its own timestamped subfolder containing the
/// original file/folder plus a meta.json describing the restoration target.
@MainActor
public struct TrashStore {
    public let projectURL: URL

    public init(projectURL: URL) {
        self.projectURL = projectURL
    }

    var trashRoot: URL {
        projectURL.appendingPathComponent(".trash")
    }

    /// List the WRITER's deletions, newest first. Maugham's own safety copies
    /// (`.internalArtifact`) are not the writer's deletions and do not appear
    /// (RULING-43); `entriesIncludingInternal` is the unfiltered read for the
    /// verbs that must still reach them.
    public func list() async throws -> [TrashEntry] {
        try await entriesIncludingInternal().filter { $0.subject != .internalArtifact }
    }

    /// Every entry, the writer's and Maugham's alike. Used by the
    /// disposal verbs (a hidden entry must still be swept and still be
    /// permanently deletable) and by `restore`, which refuses the internal ones
    /// by name rather than by not finding them.
    ///
    /// **An entry whose `meta.json` cannot be read is reported, not skipped**
    /// (RULING-7). Maugham writes the file into the folder and the metadata
    /// after it; a crash between the two leaves the writer's chapter in a folder
    /// that used to be invisible to every surface, so the pane said the trash
    /// was empty while it held their words. It now comes back as an
    /// `isUnreadable` entry — see `unreadableEntry(at:trashedAt:)` for the two
    /// shapes that are still, correctly, skipped.
    public func entriesIncludingInternal() async throws -> [TrashEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashRoot.path) else { return [] }
        let folders = (try? fm.contentsOfDirectory(
            at: trashRoot,
            includingPropertiesForKeys: nil,
            options: [])) ?? []

        var entries: [TrashEntry] = []
        for folder in folders where folder.hasDirectoryPath {
            // A folder name Maugham did not write is not Maugham's entry, and
            // describing it is not Maugham's business (RULING-9).
            guard let trashedAt = Self.parseTimestamp(from: folder.lastPathComponent) else {
                continue
            }
            let metaURL = folder.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),  // adr-0018-ok: trash metadata read, not manuscript
                  let meta = try? JSONDecoder().decode(TrashMeta.self, from: data) else {
                if let unreadable = Self.unreadableEntry(at: folder, trashedAt: trashedAt) {
                    entries.append(unreadable)
                }
                continue
            }
            entries.append(TrashEntry(
                id: folder.lastPathComponent,
                trashedAt: trashedAt,
                originalRelativePath: meta.originalRelativePath,
                displayTitle: meta.displayTitle,
                itemMetadata: meta.itemMetadata,
                originalParentId: meta.originalParentId,
                originalIndex: meta.originalIndex,
                subject: meta.subject,
                carriesFile: meta.carriesFile ?? true))
        }
        return entries.sorted { $0.trashedAt > $1.trashedAt }
    }

    /// The row for an entry Maugham wrote and cannot read back, or nil when the
    /// folder holds NOTHING but its unreadable metadata.
    ///
    /// The empty case is the other half of the same duty: a refused or
    /// interrupted move that never got as far as moving the file leaves an empty
    /// folder, and a row promising "contents preserved" over it would be its own
    /// misrepresentation. What is on disk decides, not what the folder is called.
    static func unreadableEntry(at folder: URL, trashedAt: Date) -> TrashEntry? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
        guard contents.contains(where: { $0.lastPathComponent != "meta.json" }) else { return nil }
        return TrashEntry(
            id: folder.lastPathComponent,
            trashedAt: trashedAt,
            originalRelativePath: "",
            displayTitle: TrashEntry.unreadableTitle,
            itemMetadata: Data(),
            subject: nil,
            carriesFile: true,
            isUnreadable: true)
    }

    /// Every entry FOLDER in `.trash/`, readable or not, named or not.
    ///
    /// The disposal counterpart of the sweep's walk (RULING-39): "Empty Trash"
    /// means the trash directory, not one observer's cached view of it. An entry
    /// written straight through this store — which is how the MCP piece-style
    /// tools write one — is in here and in no cache.
    ///
    /// Throws when `.trash/` exists and cannot be enumerated, because a caller
    /// that reported an emptied trash after silently seeing nothing would be
    /// making exactly the claim this walk exists to keep honest. No `.trash/` at
    /// all is not a failure — there is nothing to empty.
    public func entryFolderIds() async throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashRoot.path) else { return [] }
        return try fm.contentsOfDirectory(
            at: trashRoot, includingPropertiesForKeys: nil, options: [])
            .filter(\.hasDirectoryPath)
            .map(\.lastPathComponent)
    }

    /// Remove entries older than 30 days. Called from ProjectStore.load.
    ///
    /// **Walks the trash directory, not `list()`** (RULING-39). An entry whose
    /// `meta.json` never landed — an interrupted `moveToTrash`, whose file is
    /// already inside the entry folder — is invisible to `list()`, and a sweep
    /// built on `list()` therefore left it in the project for ever, travelling
    /// into every backup. Age comes from the folder name's timestamp where it
    /// parses and from the folder's own filesystem dates where it does not, so
    /// an entry with no readable metadata of any kind still expires.
    public func sweep() async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashRoot.path) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let folders = (try? fm.contentsOfDirectory(
            at: trashRoot,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [])) ?? []
        for folder in folders where folder.hasDirectoryPath {
            guard let trashedAt = Self.ageOfEntry(at: folder) else { continue }
            if trashedAt < cutoff {
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// When an entry folder was trashed: its name's timestamp, else the
    /// filesystem's own dates for the folder (oldest of creation/modification,
    /// so a folder touched since it was trashed is not given a fresh lease).
    /// `nil` only when the folder has neither — nothing can date it, so the
    /// sweep leaves it rather than destroying something of unknown age.
    static func ageOfEntry(at folder: URL) -> Date? {
        if let stamped = parseTimestamp(from: folder.lastPathComponent) { return stamped }
        let values = try? folder.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey])
        let dates = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }
        return dates.min()
    }

    /// Permanently delete a trashed entry.
    public func permanentlyDelete(trashId: String) async throws {
        let entryFolder = trashRoot.appendingPathComponent(trashId)
        try FileManager.default.removeItem(at: entryFolder)
    }

    /// Restore a trashed entry: move its file back, delete the trash folder,
    /// return the original metadata plus WHERE the file actually landed.
    ///
    /// `to` overrides the recorded destination. The caller is the only one that
    /// knows where the binder says the row is going to sit, and the file has to
    /// follow it there (RULING-41) — `TrashStore` knows nothing about manifests.
    ///
    /// **An occupied destination is restored BESIDE the occupant** under a
    /// deduped filename rather than refused (RULING-38): the writer asked for
    /// their item back, nothing is overwritten, and both are visible. The
    /// numeric-suffix pattern is `addResearchTextNote`'s.
    @discardableResult
    public func restore(trashId: String, to preferredRelativePath: String? = nil) async throws -> TrashEntry {
        let fm = FileManager.default
        let entryFolder = trashRoot.appendingPathComponent(trashId)
        let metaURL = entryFolder.appendingPathComponent("meta.json")
        let meta: TrashMeta
        do {
            let metaData = try Data(contentsOf: metaURL)  // adr-0018-ok: trash metadata read, not manuscript
            meta = try JSONDecoder().decode(TrashMeta.self, from: metaData)
        } catch {
            // An id that is in the trash but whose record cannot be read is a
            // different refusal from an id that is not there at all, and saying
            // which is the whole of RULING-7's "a refusal names its real cause".
            // The folder — and the writer's file in it — is left exactly as it is.
            guard fm.fileExists(atPath: entryFolder.path) else { throw error }
            throw TrashError.entryMetadataUnreadable(trashId: trashId, underlying: error)
        }

        guard let trashedAt = Self.parseTimestamp(from: trashId) else {
            throw TrashError.malformedEntryId(trashId)
        }

        func result(restoredAt: String?) -> TrashEntry {
            TrashEntry(
                id: trashId,
                trashedAt: trashedAt,
                originalRelativePath: meta.originalRelativePath,
                displayTitle: meta.displayTitle,
                itemMetadata: meta.itemMetadata,
                originalParentId: meta.originalParentId,
                originalIndex: meta.originalIndex,
                subject: meta.subject,
                carriesFile: meta.carriesFile ?? true,
                restoredRelativePath: restoredAt)
        }

        // A manifest-only entry (a research link, RULING-45) has no file to
        // move: the meta.json IS the record, and handing it back to the caller
        // is the whole restore.
        if meta.carriesFile == false {
            try fm.removeItem(at: entryFolder)
            return result(restoredAt: nil)
        }

        // Identify the file inside the entry folder (the non-meta.json file)
        guard let fileURL = Self.fileURL(inEntryFolder: entryFolder) else {
            let contents = (try? fm.contentsOfDirectory(
                at: entryFolder,
                includingPropertiesForKeys: nil,
                options: [])) ?? []
            throw TrashError.entryFileMissing(
                trashId: trashId,
                folderContents: contents.map(\.lastPathComponent))
        }

        // Restore to the requested path; ensure parent dirs exist. meta.json is
        // sidecar-supplied (read off disk, not validated at write time by
        // every caller) — a corrupted or hostile originalRelativePath must
        // not be able to move the file outside the project root (A5). The
        // caller's override goes through the same guard: it is manifest-derived
        // and no more trusted than the sidecar.
        let requested = preferredRelativePath ?? meta.originalRelativePath
        let target: URL
        do {
            target = try SafeRelativePath.resolve(requested, under: projectURL)
        } catch {
            throw TrashError.unsafeRelativePath(requested, underlying: error)
        }
        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let dest = Self.destinationBesideAnyOccupant(target)
        try fm.moveItem(at: fileURL, to: dest)

        // Delete entry folder (now contains only meta.json)
        try fm.removeItem(at: entryFolder)

        return result(restoredAt: Self.relativePath(of: dest, under: projectURL) ?? requested)
    }

    /// What an entry is holding: the one thing in its folder that is not
    /// `meta.json`, or nil when the folder holds nothing but its metadata (a
    /// manifest-only entry, or an interrupted move).
    static func fileURL(inEntryFolder folder: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [])) ?? [])
            .first { $0.lastPathComponent != "meta.json" }
    }

    /// Where a trashed entry's contents are sitting right now.
    ///
    /// For the caller that has to READ an entry back without restoring it —
    /// `ProjectStore.trashPriorVersion`, which moves a file in for the typed
    /// mover's flush discipline and then copies it straight back so the live
    /// file never stops existing. Restoring would undo the move it just made.
    func entryFileURL(trashId: String) -> URL? {
        Self.fileURL(inEntryFolder: trashRoot.appendingPathComponent(trashId))
    }

    /// `dest` itself when nothing is there, else the same name with a numeric
    /// suffix — `chapter-2.md`, `chapter-3.md`, … — matching the on-disk dedupe
    /// `addResearchTextNote` already uses. Falls back to a UUID name after 999
    /// collisions, exactly as `ProjectStore.researchDedupedFilename` does.
    static func destinationBesideAnyOccupant(_ dest: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dest.path) else { return dest }
        let directory = dest.deletingLastPathComponent()
        let ext = dest.pathExtension
        let stem = dest.deletingPathExtension().lastPathComponent
        for n in 2...999 {
            let name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent(UUID().uuidString)
    }

    /// Project-relative spelling of an absolute URL under `root`, or nil when
    /// it is not under it. Both sides are standardized first so the /private
    /// symlink on macOS temp paths doesn't make a child look foreign.
    static func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// Move a file or folder from its original project-relative path into
    /// .trash/<timestamp>-<id>/, with meta.json recording the original path,
    /// display title, item metadata, and original parent/index for restore.
    public func moveToTrash(
        fileRelativePath: String,
        itemMetadata: Data,
        originalParentId: String?,
        originalIndex: Int,
        displayTitle: String,
        subject: TrashSubject
    ) async throws -> TrashEntry {
        let fm = FileManager.default
        let now = Date()
        let (entryId, entryFolder) = try mintEntryFolder(itemMetadata: itemMetadata, now: now)

        // Move original file/folder into the entry folder, keeping its filename.
        // fileRelativePath ultimately traces back to a manifest-derived path
        // (item.path / a StructureItem's relative path) — validate it stays
        // inside the project root before touching the filesystem (A5).
        let source: URL
        do {
            source = try SafeRelativePath.resolve(fileRelativePath, under: projectURL)
        } catch {
            throw TrashError.unsafeRelativePath(fileRelativePath, underlying: error)
        }
        let dest = entryFolder.appendingPathComponent(source.lastPathComponent)
        try fm.moveItem(at: source, to: dest)

        try writeMeta(
            TrashMeta(
                originalRelativePath: fileRelativePath,
                displayTitle: displayTitle,
                itemMetadata: itemMetadata,
                originalParentId: originalParentId,
                originalIndex: originalIndex,
                subject: subject,
                carriesFile: true),
            to: entryFolder)

        return TrashEntry(
            id: entryId,
            trashedAt: now,
            originalRelativePath: fileRelativePath,
            displayTitle: displayTitle,
            itemMetadata: itemMetadata,
            subject: subject,
            carriesFile: true)
    }

    /// Record a trash entry whose contents are handed over as TEXT rather than
    /// moved off disk.
    ///
    /// For what Maugham keeps of an artifact that has no file of its own to
    /// move: a palette card's prose lives inside its card file beside the
    /// swatches, sensory notes and image references, and a rewrite replaces
    /// only the prose — so moving the file would take the rest of the card with
    /// it, and there is nothing else on disk that is just the body.
    ///
    /// `originalRelativePath` is where a RESTORE should land it, not where it
    /// came from — nothing was moved, so there is no "back". The caller names a
    /// path under `research/` so the `.priorVersion` restore arm files it as a
    /// research note the writer can open.
    func recordTextEntry(
        text: String,
        filename: String,
        originalRelativePath: String,
        itemMetadata: Data,
        displayTitle: String,
        subject: TrashSubject
    ) async throws -> TrashEntry {
        let now = Date()
        let (entryId, entryFolder) = try mintEntryFolder(itemMetadata: itemMetadata, now: now)
        try text.write(to: entryFolder.appendingPathComponent(filename),
                       atomically: true, encoding: .utf8)
        try writeMeta(
            TrashMeta(
                originalRelativePath: originalRelativePath,
                displayTitle: displayTitle,
                itemMetadata: itemMetadata,
                originalParentId: nil,
                originalIndex: 0,
                subject: subject,
                carriesFile: true),
            to: entryFolder)
        return TrashEntry(
            id: entryId,
            trashedAt: now,
            originalRelativePath: originalRelativePath,
            displayTitle: displayTitle,
            itemMetadata: itemMetadata,
            subject: subject,
            carriesFile: true)
    }

    /// Record a trash entry for an item that has no file at all — a research
    /// link, whose URL and title live only in the manifest (RULING-45). The
    /// entry folder holds a `meta.json` and nothing else, and `carriesFile:
    /// false` is what tells `restore` that is the complete entry rather than an
    /// interrupted move (which still throws `entryFileMissing`).
    ///
    /// `originalRelativePath` is recorded as the item's manifest path so the
    /// row round-trips unchanged; nothing on the filesystem is touched, in
    /// either direction.
    public func recordManifestOnlyTrash(
        originalRelativePath: String,
        itemMetadata: Data,
        originalParentId: String?,
        originalIndex: Int,
        displayTitle: String,
        subject: TrashSubject
    ) async throws -> TrashEntry {
        let now = Date()
        let (entryId, entryFolder) = try mintEntryFolder(itemMetadata: itemMetadata, now: now)
        try writeMeta(
            TrashMeta(
                originalRelativePath: originalRelativePath,
                displayTitle: displayTitle,
                itemMetadata: itemMetadata,
                originalParentId: originalParentId,
                originalIndex: originalIndex,
                subject: subject,
                carriesFile: false),
            to: entryFolder)
        return TrashEntry(
            id: entryId,
            trashedAt: now,
            originalRelativePath: originalRelativePath,
            displayTitle: displayTitle,
            itemMetadata: itemMetadata,
            subject: subject,
            carriesFile: false)
    }

    /// `.trash/<yyyyMMdd-HHmmss>-<the metadata's id>/`, created — and a folder
    /// NO other entry holds (RULING-4).
    ///
    /// The name used to be the timestamp and the id and nothing else, which is
    /// unique only to the second: two deletions of rows sharing a metadata id in
    /// one second landed in one folder, the second `meta.json` overwrote the
    /// first, and the writer's first deletion was gone from every surface — then
    /// destroyed outright when the surviving entry was restored. So the creation
    /// IS the claim: `withIntermediateDirectories: false` fails if the name is
    /// taken (where `true` silently shares it), and a taken name takes the next
    /// number, the same `-2`, `-3` … dedupe `destinationBesideAnyOccupant` uses.
    ///
    /// **The timestamp stays a PREFIX.** The sweep dates an entry by parsing its
    /// folder name (RULING-39), including entries it can read nothing else
    /// about, so an id that buried or dropped the stamp — a ULID, a bare UUID —
    /// would quietly cost that.
    private func mintEntryFolder(
        itemMetadata: Data, now: Date
    ) throws -> (id: String, folder: URL) {
        // Extract id from item metadata for folder naming (best-effort).
        struct IdProbe: Decodable { let id: String? }
        let originalId = ((try? JSONDecoder().decode(IdProbe.self, from: itemMetadata))?.id) ?? "x"
        let stem = "\(Self.timestampPrefix(for: now))-\(originalId)"
        let fm = FileManager.default
        try fm.createDirectory(at: trashRoot, withIntermediateDirectories: true)

        func claim(_ entryId: String) throws -> (id: String, folder: URL)? {
            let folder = trashRoot.appendingPathComponent(entryId)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                return (entryId, folder)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileWriteFileExistsError {
                return nil
            }
        }

        if let claimed = try claim(stem) { return claimed }
        for n in 2...999 {
            if let claimed = try claim("\(stem)-\(n)") { return claimed }
        }
        guard let claimed = try claim("\(stem)-\(UUID().uuidString)") else {
            throw TrashError.couldNotMintEntry(stem)
        }
        return claimed
    }

    private func writeMeta(_ meta: TrashMeta, to entryFolder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(
            to: entryFolder.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// Internal metadata persisted in each trash folder's meta.json.
    /// `subject` and `carriesFile` are additive-optional (ADR 0015): an entry
    /// written before they existed decodes with both nil.
    struct TrashMeta: Codable {
        let originalRelativePath: String
        let displayTitle: String
        let itemMetadata: Data
        let originalParentId: String?
        let originalIndex: Int
        var subject: TrashSubject?
        var carriesFile: Bool?

        init(
            originalRelativePath: String,
            displayTitle: String,
            itemMetadata: Data,
            originalParentId: String?,
            originalIndex: Int,
            subject: TrashSubject? = nil,
            carriesFile: Bool? = nil
        ) {
            self.originalRelativePath = originalRelativePath
            self.displayTitle = displayTitle
            self.itemMetadata = itemMetadata
            self.originalParentId = originalParentId
            self.originalIndex = originalIndex
            self.subject = subject
            self.carriesFile = carriesFile
        }

        /// A `subject` this build does not know decodes as nil rather than
        /// failing the whole entry (ADR 0015 forward-tolerance). Failing it
        /// would make the entry unreadable, and an unreadable entry is one the
        /// pane cannot show — the exact shape of the bug RULING-39 convicts.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            originalRelativePath = try c.decode(String.self, forKey: .originalRelativePath)
            displayTitle = try c.decode(String.self, forKey: .displayTitle)
            itemMetadata = try c.decode(Data.self, forKey: .itemMetadata)
            originalParentId = try c.decodeIfPresent(String.self, forKey: .originalParentId)
            originalIndex = try c.decode(Int.self, forKey: .originalIndex)
            subject = try c.decodeIfPresent(String.self, forKey: .subject)
                .flatMap { TrashSubject(rawValue: $0) }
            carriesFile = try c.decodeIfPresent(Bool.self, forKey: .carriesFile)
        }
    }

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        return f
    }()

    static func parseTimestamp(from folderName: String) -> Date? {
        // Folder name: "yyyyMMdd-HHmmss-<original-id>"
        let parts = folderName.split(separator: "-", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let stamp = "\(parts[0])-\(parts[1])"
        return timestampFormatter.date(from: stamp)
    }

    static func timestampPrefix(for date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    public enum TrashError: Error, LocalizedError {
        case entryFileMissing(trashId: String, folderContents: [String])
        case malformedEntryId(String)
        case unsafeRelativePath(String, underlying: Error)
        /// The entry is in the trash; its `meta.json` is missing or undecodable,
        /// so nothing says where its contents belong. Distinct from an unknown
        /// id, which fails at the read as a plain Cocoa error (RULING-7).
        case entryMetadataUnreadable(trashId: String, underlying: Error)
        /// Nothing could claim an entry folder name — 1,000 taken names and a
        /// UUID. Unreachable in practice; a silent share of someone else's
        /// folder is what this refuses to do instead.
        case couldNotMintEntry(String)

        public var errorDescription: String? {
            switch self {
            case .entryFileMissing(let id, let contents):
                return "Trash entry \(id) is missing its source file. Contents: \(contents.joined(separator: ", "))"
            case .malformedEntryId(let id):
                return "Trash entry id \(id) is malformed (no parseable timestamp)."
            case .unsafeRelativePath(let path, let underlying):
                return "Trash relative path \"\(path)\" is unsafe: \(underlying.localizedDescription)"
            case .entryMetadataUnreadable(let id, _):
                return "Trash entry \(id) still holds what was deleted, but Maugham’s "
                    + "record of what it was can’t be read."
            case .couldNotMintEntry(let stem):
                return "Maugham could not make a trash entry for \(stem)."
            }
        }
    }
}
