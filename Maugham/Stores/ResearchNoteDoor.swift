import Foundation
import MaughamCore
import Observation
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
/// no view (each note's reload signal is its own observed object). Saves of
/// one note run one after another (`inFlight`); saves of different notes do
/// not wait for each other. The editor's debounced edits wait here too, one
/// pending text per note (`pending`).
@MainActor
final class ResearchNoteDoor {

    /// The run-rule clock (as `ResearchTableHost.now`); tests move it.
    var now: @MainActor () -> Date = { Date() }
    /// How long after the last keystroke the editor's edit is saved.
    var saveDelay: Duration = .milliseconds(750)
    /// Told (item id, text) after each file write the door makes.
    var wroteForTesting: (@MainActor (String, String) -> Void)?
    /// Called on the main actor just before a keep goes off it.
    var keepWillRunForTesting: (@MainActor () async -> Void)?
    /// Told the item id once a timer-fired save has finished.
    var timerSaveFinishedForTesting: (@MainActor (String) -> Void)?

    /// Where a save came from: what the keep-failure rule asks.
    enum SaveSource: Equatable {
        /// The editor's edit, its debounce elapsed.
        case editorTimer
        /// The editor's edit, flushed (`flushPendingSave`: a note switch, ⌘S,
        /// the typed mover, the store's close; or a door write about to
        /// replace it): the last moment that text exists.
        case editorFlush
        /// Anyone else's write (`saveResearchNote`): a restore, the assistant,
        /// a rename, Replace, a promotion. It always keeps what it replaces
        /// and ends the writer's run. `mustLand` when it is saved even if
        /// that version cannot be kept (a move's asset refs: the move has
        /// already happened).
        case direct(mustLand: Bool)
    }

    /// **P3 (pending Denver, asked 2026-11-10): when the bytes a save replaces
    /// cannot be kept, is the save stopped or made anyway?** Interim ruling
    /// (controller, Task 3), by source: a timer-fired edit is stopped and stays
    /// pending; a flushed edit is saved anyway, with a notice (the spec's
    /// anti-goal: no text lost because its previous version could not be
    /// kept); anyone else's write is stopped, as tables, unless it must land
    /// (saved anyway, with the notice). Changing it is this
    /// one function; `ResearchNoteDoorTests.test_aKeepThatFailsStopsTheSave`,
    /// `test_aTimerSaveWhoseKeepFailsStops_andTheTextIsStillPendingForTheFlush`
    /// and `test_aFlushSavesEvenWhenTheVersionCannotBeKept_andSaysSo` change with it.
    enum WhenTheKeepFails { case stopTheSave, saveAnyway }
    static func whenTheKeepFails(_ source: SaveSource) -> WhenTheKeepFails {
        switch source {
        case .editorTimer: return .stopTheSave
        case .editorFlush: return .saveAnyway
        case .direct(let mustLand): return mustLand ? .saveAnyway : .stopTheSave
        }
    }

    /// What one write did, as the door's callers need it.
    enum Outcome: Equatable {
        case saved(keptAVersion: Bool)
        case notSaved
        /// Stopped because the version could not be kept: the editor's text
        /// stays pending.
        case stoppedAtTheKeep

        var asSave: ResearchNoteSave {
            switch self {
            case .saved(let kept): return .saved(keptAVersion: kept)
            case .notSaved, .stoppedAtTheKeep: return .notSaved
            }
        }
    }

    private struct NoteState {
        /// The hash of the bytes this store last read or wrote for the note;
        /// nil — it never has. A save over other bytes keeps them.
        var knownHash: String?
        var run = ResearchSaveRun()
        /// A keep of the same bytes again (a retry) keeps nothing.
        var lastKeptHash: String?
        /// The hash of what another writer wrote (`.direct`) that no editor
        /// has read since: the editor's save over them keeps them, run or
        /// not — the writer typed over text they had not seen.
        var writtenBehindTheEditor: String?
        /// The timer-stop notice was posted: said once, not once per typing
        /// pause, until a save of the note lands or the note is read again.
        var timerStopSaid = false
    }

    /// One note's edit waiting for its debounce.
    private struct Pending {
        var text: String
        var generation: Int
        var timer: Task<Void, Never>?
    }

    private var notes: [String: NoteState] = [:]
    private var inFlight: [String: (token: Int, task: Task<Outcome, Never>)] = [:]
    private var nextToken = 0
    private var pending: [String: Pending] = [:]
    private var nextGeneration = 0
    private var reloadSignals: [String: ResearchNoteReloadSignal] = [:]

    /// The bytes `itemId` holds were read (an editor's load): they are known.
    /// Bytes that are not the ones known end the writer's run, so the next
    /// save keeps what was read (a reload is not this run's).
    func wasRead(itemId: String, bytes: Data) {
        let hash = ContentHash.of(bytes)
        var state = notes[itemId] ?? NoteState()
        if state.knownHash != hash { state.run.end() }
        state.knownHash = hash
        state.writtenBehindTheEditor = nil
        state.timerStopSaid = false
        notes[itemId] = state
    }

    // MARK: The reload signal

    /// **Moves when the door wrote `itemId` for anyone but the editor**: an
    /// open editor on the note re-reads it. Reading it observes this note's
    /// signal only, so a save of another note invalidates nothing here.
    func reloadCount(_ itemId: String) -> Int { signal(itemId).count }

    private func signal(_ itemId: String) -> ResearchNoteReloadSignal {
        if let existing = reloadSignals[itemId] { return existing }
        let made = ResearchNoteReloadSignal()
        reloadSignals[itemId] = made
        return made
    }

    // MARK: The editor's pending edits

    /// The editor's edit of `itemId`, saved `saveDelay` after the last one.
    /// Each note has its own slot: a schedule for another note never drops
    /// this one.
    func schedule(_ itemId: String, text: String, in store: DocumentStore) {
        pending[itemId]?.timer?.cancel()
        nextGeneration += 1
        let generation = nextGeneration
        let delay = saveDelay
        let timer = Task { @MainActor [weak self, weak store] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let store else { return }
            await self.fire(itemId, generation: generation, in: store)
        }
        pending[itemId] = Pending(text: text, generation: generation, timer: timer)
    }

    /// Whether the editor's edit of `itemId` is waiting to be saved.
    func hasPending(_ itemId: String) -> Bool { pending[itemId] != nil }

    /// The debounce elapsed. The edit stays pending until it lands: a save
    /// stopped at the keep leaves it for the next attempt (a keystroke's
    /// timer, or a flush), and a newer keystroke's edit replaces it.
    private func fire(_ itemId: String, generation: Int, in store: DocumentStore) async {
        guard let entry = pending[itemId], entry.generation == generation else { return }
        pending[itemId]?.timer = nil
        let outcome = await enqueue(itemId, text: entry.text, by: .writer, restoring: false,
                                    source: .editorTimer, in: store)
        if outcome != .stoppedAtTheKeep, pending[itemId]?.generation == generation {
            pending[itemId] = nil
        }
        timerSaveFinishedForTesting?(itemId)
    }

    /// Every note's pending edit, saved now as a flush.
    /// One note at a time, each taken out of `pending` only as its own save
    /// begins: a note still waiting its turn stays pending, so a door write
    /// meanwhile flushes it first and the editor does not reload under it.
    func flushPending(in store: DocumentStore) async {
        while let itemId = pending.keys.min(), let entry = pending.removeValue(forKey: itemId) {
            entry.timer?.cancel()
            _ = await enqueue(itemId, text: entry.text, by: .writer, restoring: false,
                              source: .editorFlush, in: store)
        }
    }

    // MARK: Saves

    /// **Anyone else's write** of `itemId`. The editor's pending edit of the
    /// note is saved first (a flush), and is then the version this write
    /// replaces; once written, an editor open on the note reloads.
    func save(_ itemId: String, text: String, by writer: ResearchWriter, restoring: Bool,
              mustLand: Bool, in store: DocumentStore) async -> ResearchNoteSave {
        if let entry = pending.removeValue(forKey: itemId) {
            entry.timer?.cancel()
            _ = await enqueue(itemId, text: entry.text, by: .writer, restoring: false,
                              source: .editorFlush, in: store)
        }
        return await enqueue(itemId, text: text, by: writer, restoring: restoring,
                             source: .direct(mustLand: mustLand), in: store).asSave
    }

    /// One save, queued behind any save of the same note already in flight.
    private func enqueue(_ itemId: String, text: String, by writer: ResearchWriter, restoring: Bool,
                         source: SaveSource, in store: DocumentStore) async -> Outcome {
        let before = inFlight[itemId]?.task
        nextToken += 1
        let token = nextToken
        // Unstructured, so a caller's cancellation (the debounce task a new
        // schedule cancels) never cuts a save in half.
        let task = Task { @MainActor [weak self, weak store] () -> Outcome in
            // Cleared on every way out, so `settle` never waits on a save that ended.
            defer { self?.finished(itemId, token: token) }
            _ = await before?.value
            guard let self, let store else { return .notSaved }
            return await self.write(itemId, text: text, by: writer, restoring: restoring,
                                    source: source, in: store)
        }
        inFlight[itemId] = (token, task)
        return await task.value
    }

    private func finished(_ itemId: String, token: Int) {
        if inFlight[itemId]?.token == token { inFlight[itemId] = nil }
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
                       source: SaveSource, in store: DocumentStore) async -> Outcome {
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
            notes[itemId]?.timerStopSaid = false
            counted(itemId, by: writer, source: source, at: at)
            wroteBehindTheEditor(itemId, newBytes, source: source)
            return .saved(keptAVersion: false)
        }

        var kept = false
        if let onDisk, !onDisk.isEmpty {
            let state = notes[itemId] ?? NoteState()
            let onDiskHash = ContentHash.of(onDisk)
            let overOwnBytes = onDiskHash == state.knownHash
            if restoring || Self.keepsRegardlessOfTheRun(source, onDiskHash: onDiskHash, state.writtenBehindTheEditor)
                || state.run.keepsAVersion(by: writer, at: at, overOwnBytes: overOwnBytes),
               onDiskHash != state.lastKeptHash {
                if let failure = await keepThePriorVersion(onDisk, of: itemId, at: at, by: writer, in: store) {
                    researchNoteLog.error(
                        "\(item.title, privacy: .public)'s previous version was not kept: \(failure.localizedDescription, privacy: .public)")
                    switch Self.whenTheKeepFails(source) {
                    case .stopTheSave where source == .editorTimer:
                        if !(notes[itemId]?.timerStopSaid ?? false) {
                            notes[itemId, default: NoteState()].timerStopSaid = true
                            MaughamEvent.postNotice(
                                "“\(item.title)”’s previous version couldn’t be kept, so your edits aren’t saved yet. They stay in the editor and are saved when you leave the note.",
                                projectURL: projectURL)
                        }
                        return .stoppedAtTheKeep
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
        counted(itemId, by: writer, source: source, at: at)

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
        notes[itemId]?.timerStopSaid = false
        wroteForTesting?(itemId, text)
        do {
            try ResearchNoteRecord.write(ResearchNoteRecord(contentHash: writtenHash, writtenBy: writer),
                                         forItem: itemId, in: projectURL)
        } catch {
            // A label, not the text: the next save writes it again.
            researchNoteLog.error(
                "\(itemId, privacy: .public)'s note record was not written: \(error.localizedDescription, privacy: .public)")
        }
        wroteBehindTheEditor(itemId, newBytes, source: source)
        return .saved(keptAVersion: kept)
    }

    /// A save keeps what it replaces whatever the run says when it is anyone
    /// else's write (a rename, Replace, a promotion, the assistant, a
    /// restore: none has an undo, and the run is the editor's typing), or the
    /// editor's own save over text another writer put there that the editor
    /// never showed (the writer typed before the reload landed). A retry of
    /// the same bytes still keeps once (`lastKeptHash`).
    private static func keepsRegardlessOfTheRun(_ source: SaveSource, onDiskHash: String,
                                                 _ writtenBehind: String?) -> Bool {
        switch source {
        case .direct: return true
        case .editorTimer, .editorFlush: return onDiskHash == writtenBehind
        }
    }

    /// After anyone else's write: the bytes are marked unread by the editor,
    /// and an editor open on the note is told to re-read it. The editor's
    /// own saves move nothing.
    private func wroteBehindTheEditor(_ itemId: String, _ bytes: Data, source: SaveSource) {
        guard case .direct = source else { return }
        notes[itemId, default: NoteState()].writtenBehindTheEditor = ContentHash.of(bytes)
        signal(itemId).count += 1
    }

    /// Counted once the version is kept, saved or not: a retry after a failed
    /// save is still the run whose start is kept. Anyone else's write (a
    /// restore, the assistant's, a rename, Replace, a promotion) ends it, so
    /// the writer's next typed save keeps again.
    private func counted(_ itemId: String, by writer: ResearchWriter, source: SaveSource, at date: Date) {
        switch source {
        case .direct:
            notes[itemId, default: NoteState()].run.end()
        case .editorTimer, .editorFlush:
            notes[itemId, default: NoteState()].run.saved(by: writer, at: date)
        }
    }

    /// The note `itemId` names and its path, asked of the manifest now; nil —
    /// write nothing — when it is gone (said) or the door does not take it
    /// (logged: a palette card under P2's default, and a table has its own door).
    private func noteItem(_ itemId: String, in store: DocumentStore) -> (ResearchItem, String)? {
        guard let item = store.projectStore.flatMap({ $0.findResearchItem(id: itemId, in: $0.manifest.research) }),
              let path = item.path else {
            MaughamEvent.postNotice("A Research note’s edits couldn’t be saved: it is no longer in Research.",
                                    projectURL: store.projectURL)
            return nil
        }
        guard Self.takes(item) else {
            researchNoteLog.error("\(itemId, privacy: .public) is not a Research note; the note door wrote nothing")
            return nil
        }
        return (item, path)
    }

    /// **P2 (pending Denver, asked 2026-11-10): do palette cards get
    /// versions?** Default built: no. A writer whose target is a card keeps
    /// the write it had (`ProjectStore.paletteCoordinatedWrite`, the rename's
    /// link sweep, Replace, a promotion's link). Flipping this routes those
    /// sweeps' card writes through the door too; the palette's own writer
    /// (`paletteCoordinatedWrite`) would still need routing by hand.
    static let paletteCardsKeepVersions = false

    /// **Whether a write of `item`'s text goes through the door** — the one
    /// question every writer of existing Research text asks (`ResearchTextRole`
    /// says what the item is; P2 says whether a card is the door's).
    static func takes(_ item: ResearchItem) -> Bool {
        switch ResearchTextRole.of(item) {
        case .note: return true
        case .paletteCard: return paletteCardsKeepVersions
        case nil: return false
        }
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
        await keepWillRunForTesting?()
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

/// One note's reload signal (`ResearchNoteDoor.reloadCount`): its own
/// observed object, so a view reading it is invalidated by this note's
/// writes only.
@Observable
@MainActor
final class ResearchNoteReloadSignal {
    var count = 0
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
    /// through** (`ResearchNoteDoor`) outside the editor: the bytes it
    /// replaces are always kept as a version first (a retry of the same bytes
    /// once), and the writer's typing run ends. `writer` is whose text this is. Refuses a
    /// palette card, a table, or an id that names no note.
    /// `mustLand`: saved even when that version cannot be kept, with a
    /// notice saying so (a write whose reason has already happened, as a
    /// moved note's asset refs).
    @discardableResult
    func saveResearchNote(itemId: String, text: String, by writer: ResearchWriter = .writer,
                          restoring: Bool = false, mustLand: Bool = false) async -> ResearchNoteSave {
        await researchNoteDoor.save(itemId, text: text, by: writer, restoring: restoring,
                                    mustLand: mustLand, in: self)
    }

    /// **Moves each time the door writes note `itemId` for anyone but the
    /// editor's own debounced save** (a restore, the assistant, a rename): an
    /// editor open on the note re-reads its file. Observed per note — reading
    /// it invalidates the reader on that note's writes only.
    func researchNoteReloadCount(itemId: String) -> Int {
        researchNoteDoor.reloadCount(itemId)
    }

    /// Whether the editor's edit of note `itemId` is waiting to be saved.
    func researchNoteHasPendingSave(itemId: String) -> Bool {
        researchNoteDoor.hasPending(itemId)
    }

    /// **Returns once no edit of note `itemId` is waiting.** A writer that
    /// reads a note's file to write a changed copy back (a rename's link
    /// sweep, Replace, a promotion's appended link) reads after this, with no
    /// `await` before its `saveResearchNote`: otherwise an edit typed during
    /// its earlier awaits is flushed by the door and then written over by
    /// text made from the bytes before it.
    func settleResearchNoteEdits(itemId: String) async {
        while researchNoteDoor.hasPending(itemId) {
            await researchNoteDoor.flushPending(in: self)
        }
    }

    /// The note `itemId`'s `bytes` were read (the editor's load): a later save
    /// over them is over known bytes.
    func researchNoteWasRead(itemId: String, bytes: Data) {
        researchNoteDoor.wasRead(itemId: itemId, bytes: bytes)
    }

    /// **The Research note at `path`**, nil for a path whose text the door
    /// does not take (a palette card under P2, a table, anything else) — the
    /// one path → note lookup.
    func researchNoteItem(atPath path: String) -> ResearchItem? {
        guard let projectStore else { return nil }
        return TreeWalk.first(in: projectStore.manifest.research) { item in
            item.path == path && ResearchNoteDoor.takes(item)
        }
    }
}
