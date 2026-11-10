import Foundation
import MaughamCore
import os

private let researchNoteLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham", category: "ResearchNoteDoor")

/// **What a Research text document is** — the one predicate, asked by the
/// centre column's router (`ProjectWindow.researchCentreRoute`) and by the
/// note door. A text document (`type == .asset`, `kind == .document`, a
/// path) is a palette card when its path is inside the palette folder, and a
/// note otherwise. Anything else (a table, a picture, a PDF, audio, a link, a
/// group, a pathless item) is neither: nil.
enum ResearchTextRole: Equatable {
    case note(path: String)
    case paletteCard

    static func of(_ item: ResearchItem) -> ResearchTextRole? {
        guard item.type == .asset, item.kind == .document, let path = item.path else { return nil }
        // **A path prefix ending in the SEPARATOR**, not a name test and not a
        // bare `hasPrefix`: a research group called "Palette research" gives its
        // notes paths that start with the palette folder's characters and are
        // not inside it, and calling one of those a card shows "Card
        // unavailable" over a note the writer can see in their tree
        // (`test_aNoteBesideThePaletteFolderIsStillANote`).
        if path.hasPrefix(ProjectStore.paletteFolderPath + "/") { return .paletteCard }
        return .note(path: path)
    }
}

/// What one save through the note door did.
enum ResearchNoteSave: Equatable {
    /// The text is on disk; `keptAVersion` when the bytes it replaced were
    /// kept as a version first.
    case saved(keptAVersion: Bool)
    /// Nothing was written (and, where the writer can act on it, said).
    case notSaved
}

/// **The note door's memory** (note versions plan 2): the table door
/// (`ResearchTableHost.write`) keeps its run state per host; a note has no
/// host, so this keeps it per note id for the store's life. Owned by
/// `DocumentStore` (`researchNoteDoor`), never observed: a save invalidates
/// no view. Saves of one note run one after another (`inFlight`); saves of
/// different notes do not wait for each other.
@MainActor
final class ResearchNoteDoor {

    /// The run-rule clock (as `ResearchTableHost.now`); tests move it.
    var now: @MainActor () -> Date = { Date() }
    /// Told (item id, text) after each file write the door makes.
    var wroteForTesting: (@MainActor (String, String) -> Void)?
    /// Called on the main actor just before a keep goes off it.
    var keepWillRunForTesting: (@MainActor () -> Void)?

    /// **P3 (pending Denver, asked 2026-11-10): when the bytes a save replaces
    /// cannot be kept, is the save stopped or made anyway?** The default built
    /// is the table's — stopped. Flipping it is this one constant;
    /// `ResearchNoteDoorTests.test_aKeepThatFailsStopsTheSave` is the test to
    /// change with it.
    enum WhenTheKeepFails { case stopTheSave, saveAnyway }
    static let whenTheKeepFails: WhenTheKeepFails = .stopTheSave

    private struct NoteState {
        /// The hash of the bytes this store last read or wrote for the note;
        /// nil — it never has. A save over other bytes keeps them.
        var knownHash: String?
        var run = ResearchSaveRun()
        /// A keep of the same bytes again (a retry) keeps nothing.
        var lastKeptHash: String?
    }

    private var notes: [String: NoteState] = [:]
    private var inFlight: [String: (token: Int, task: Task<ResearchNoteSave, Never>)] = [:]
    private var nextToken = 0

    /// The bytes `itemId` holds were read (an editor's load): they are known.
    /// Bytes that are not the ones known end the writer's run, so the next
    /// save keeps what was read (a reload is not this run's).
    func wasRead(itemId: String, bytes: Data) {
        let hash = ContentHash.of(bytes)
        var state = notes[itemId] ?? NoteState()
        if state.knownHash != hash { state.run.end() }
        state.knownHash = hash
        notes[itemId] = state
    }

    /// One save, queued behind any save of the same note already in flight.
    func save(_ itemId: String, text: String, by writer: ResearchWriter, restoring: Bool,
              in store: DocumentStore) async -> ResearchNoteSave {
        let before = inFlight[itemId]?.task
        nextToken += 1
        let token = nextToken
        // Unstructured, so a caller's cancellation (the debounce task a new
        // schedule cancels) never cuts a save in half.
        let task = Task { @MainActor [weak self, weak store] () -> ResearchNoteSave in
            _ = await before?.value
            guard let self, let store else { return .notSaved }
            let result = await self.write(itemId, text: text, by: writer, restoring: restoring, in: store)
            if self.inFlight[itemId]?.token == token { self.inFlight[itemId] = nil }
            return result
        }
        inFlight[itemId] = (token, task)
        return await task.value
    }

    /// Returns once no save is in flight (the store's flush, and so its close).
    func settle() async {
        while let next = inFlight.values.first {
            _ = await next.task.value
        }
    }

    // MARK: The door

    /// **The one door for an existing note's text**, step for step the table
    /// door's: the item and its path asked now; the prior bytes read off the
    /// main actor; the version kept (off it) when the run, a restore, or bytes
    /// this store did not write say so; then the file; then the record of who
    /// wrote it.
    private func write(_ itemId: String, text: String, by writer: ResearchWriter, restoring: Bool,
                       in store: DocumentStore) async -> ResearchNoteSave {
        let projectURL = store.projectURL
        guard let found = noteItem(itemId, in: store) else { return .notSaved }
        let (item, path) = found
        guard let fileURL = resolved(path, in: store) else { return .notSaved }

        let prior: PriorBytes = await Task.detached { PriorBytes.read(fileURL) }.value
        let onDisk: Data?
        switch prior {
        case .missing: onDisk = nil
        case .bytes(let data): onDisk = data
        case .unreadable:
            // A file that is there but will not read cannot be kept: nothing is written over it.
            MaughamEvent.postNotice(
                "Maugham couldn’t read “\(item.title)” to keep its previous version, so \(Self.whose(writer, restoring: restoring)) saved over it.",
                projectURL: projectURL)
            return .notSaved
        }
        let newBytes = Data(text.utf8)
        let at = now()
        // The file already holds this text (the same save arriving twice):
        // nothing to keep and nothing to write.
        if let onDisk, onDisk == newBytes {
            notes[itemId, default: NoteState()].knownHash = ContentHash.of(newBytes)
            counted(itemId, by: writer, restoring: restoring, at: at)
            return .saved(keptAVersion: false)
        }

        var kept = false
        if let onDisk, !onDisk.isEmpty {
            let state = notes[itemId] ?? NoteState()
            let onDiskHash = ContentHash.of(onDisk)
            let overOwnBytes = onDiskHash == state.knownHash
            if restoring || state.run.keepsAVersion(by: writer, at: at, overOwnBytes: overOwnBytes),
               onDiskHash != state.lastKeptHash {
                if let failure = await keepThePriorVersion(onDisk, of: itemId, at: at, by: writer, in: store) {
                    researchNoteLog.error(
                        "\(item.title, privacy: .public)'s previous version was not kept: \(failure.localizedDescription, privacy: .public)")
                    switch Self.whenTheKeepFails {
                    case .stopTheSave:
                        MaughamEvent.postNotice(
                            "“\(item.title)”’s previous version couldn’t be kept, so \(Self.whose(writer, restoring: restoring)) saved over it.",
                            projectURL: projectURL)
                        return .notSaved
                    case .saveAnyway:
                        MaughamEvent.postNotice(
                            "“\(item.title)”’s previous version couldn’t be kept; \(Self.saved(writer, restoring: restoring)) anyway.",
                            projectURL: projectURL)
                    }
                } else {
                    // Written to the live entry, not a copy taken before the
                    // await: a read recorded meanwhile is not undone.
                    notes[itemId, default: NoteState()].lastKeptHash = onDiskHash
                    kept = true
                    store.researchVersionsRevision += 1
                }
            }
        }
        counted(itemId, by: writer, restoring: restoring, at: at)

        // The keep was awaited: the note may have moved (written where it now
        // is) or left Research meanwhile (written nowhere, so a trashed note's
        // file is not made again).
        guard let pathNow = noteItem(itemId, in: store)?.1 else { return .notSaved }
        do {
            try await store.performFileSave(path: pathNow, text: text)
        } catch ProjectStoreError.unsafeProjectPath(let refused, let reason) {
            store.logRefusedSave(path: refused, reason: reason)
            return .notSaved
        } catch {
            researchNoteLog.error(
                "\(pathNow, privacy: .public) was not saved: \(error.localizedDescription, privacy: .public)")
            MaughamEvent.postNotice("Couldn’t save “\(item.title)”: \(error.localizedDescription)",
                                    projectURL: projectURL)
            return .notSaved
        }
        let writtenHash = ContentHash.of(newBytes)
        notes[itemId]?.knownHash = writtenHash
        wroteForTesting?(itemId, text)
        do {
            try ResearchNoteRecord.write(ResearchNoteRecord(contentHash: writtenHash, writtenBy: writer),
                                         forItem: itemId, in: projectURL)
        } catch {
            // A label, not the text: the next save writes it again.
            researchNoteLog.error(
                "\(itemId, privacy: .public)'s note record was not written: \(error.localizedDescription, privacy: .public)")
        }
        return .saved(keptAVersion: kept)
    }

    /// Counted once the version is kept, saved or not: a retry after a failed
    /// save is still the run whose start is kept. A restore, and an
    /// assistant's save, end it.
    private func counted(_ itemId: String, by writer: ResearchWriter, restoring: Bool, at date: Date) {
        if restoring {
            notes[itemId, default: NoteState()].run.end()
        } else {
            notes[itemId, default: NoteState()].run.saved(by: writer, at: date)
        }
    }

    /// The note `itemId` names and its path, asked of the manifest now; nil —
    /// write nothing — when it is gone (said) or is not a note (logged: P2's
    /// default keeps palette cards, and a table has its own door).
    private func noteItem(_ itemId: String, in store: DocumentStore) -> (ResearchItem, String)? {
        guard let item = store.projectStore.flatMap({ $0.findResearchItem(id: itemId, in: $0.manifest.research) }),
              item.path != nil else {
            MaughamEvent.postNotice("A Research note’s edits couldn’t be saved: it is no longer in Research.",
                                    projectURL: store.projectURL)
            return nil
        }
        guard case .note(let path) = ResearchTextRole.of(item) else {
            researchNoteLog.error("\(itemId, privacy: .public) is not a Research note; the note door wrote nothing")
            return nil
        }
        return (item, path)
    }

    private func resolved(_ path: String, in store: DocumentStore) -> URL? {
        do {
            return try store.resolvedProjectPath(path)
        } catch ProjectStoreError.unsafeProjectPath(let refused, let reason) {
            store.logRefusedSave(path: refused, reason: reason)
        } catch {
            researchNoteLog.error("\(path, privacy: .public) did not resolve: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    /// **The bytes about to be replaced, kept as a version** (payload
    /// `.note`), their author when the note's record was written for these
    /// bytes, `writer` as whose save replaces them; then this device's
    /// versions past the retention are pruned. Off the main actor. The error
    /// when it could not be kept.
    private func keepThePriorVersion(_ prior: Data, of itemId: String, at date: Date,
                                     by writer: ResearchWriter, in store: DocumentStore) async -> Error? {
        let versions = ResearchVersionStore(projectURL: store.projectURL)
        let projectURL = store.projectURL
        let device = DeviceIdentity.author.slug
        keepWillRunForTesting?()
        return await Task.detached { () -> Error? in
            let record = (try? ResearchNoteRecord.read(forItem: itemId, in: projectURL)) ?? nil
            let author = record?.contentHash == ContentHash.of(prior) ? record?.writtenBy : nil
            do {
                try versions.keep(priorBytes: prior, priorSidecar: nil, writtenBy: author, replacedBy: writer,
                                  payload: .note, itemId: itemId, device: device, at: date)
            } catch {
                return error
            }
            versions.prune(itemId: itemId, device: device)
            return nil
        }.value
    }

    /// The words for whose change a refused save did not write.
    private static func whose(_ writer: ResearchWriter, restoring: Bool) -> String {
        if restoring { return "the restored version wasn’t" }
        switch writer {
        case .writer: return "your edits weren’t"
        case .assistant: return "the assistant’s change wasn’t"
        }
    }

    /// The words for whose change was saved without its version kept.
    private static func saved(_ writer: ResearchWriter, restoring: Bool) -> String {
        if restoring { return "the restored version was saved" }
        switch writer {
        case .writer: return "your edits were saved"
        case .assistant: return "the assistant’s change was saved"
        }
    }
}

/// A note's file as the door found it, read off the main actor.
private enum PriorBytes: Sendable {
    /// Nothing at the path: nothing to keep, and the save proceeds.
    case missing
    case bytes(Data)
    /// Something at the path that will not read: never saved over.
    case unreadable

    static func read(_ url: URL) -> PriorBytes {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable } // adr-0018-ok: a Research note's bytes, kept before a save; not manuscript
        return .bytes(data)
    }
}

extension DocumentStore {

    /// **The one door every write of an existing Research note's text goes
    /// through** (`ResearchNoteDoor`): the bytes it replaces are kept as a
    /// version first when the run, a restore (`restoring`) or bytes this store
    /// did not write say so. `writer` is whose text this is. Refuses a
    /// palette card, a table, or an id that names no note.
    @discardableResult
    func saveResearchNote(itemId: String, text: String, by writer: ResearchWriter = .writer,
                          restoring: Bool = false) async -> ResearchNoteSave {
        await researchNoteDoor.save(itemId, text: text, by: writer, restoring: restoring, in: self)
    }

    /// The note `itemId`'s `bytes` were read (the editor's load): a later save
    /// over them is over known bytes.
    func researchNoteWasRead(itemId: String, bytes: Data) {
        researchNoteDoor.wasRead(itemId: itemId, bytes: bytes)
    }

    /// **The Research note at `path`**, nil for a path that names no note (a
    /// palette card, a table, anything else) — the one path → note lookup.
    func researchNoteItem(atPath path: String) -> ResearchItem? {
        guard let projectStore else { return nil }
        return TreeWalk.first(in: projectStore.manifest.research) { item in
            if case .note(let notePath) = ResearchTextRole.of(item) { return notePath == path }
            return false
        }
    }
}
