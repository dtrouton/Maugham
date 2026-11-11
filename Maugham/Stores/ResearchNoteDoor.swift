import Foundation
import MaughamCore
import Observation
import os

private let researchNoteLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham", category: "ResearchNoteDoor")

/// **What a Research text document is** — the one predicate, asked by the
/// centre column's router (`ProjectWindow.researchCentreRoute`), the
/// Versions section, the note door, `researchNoteItem(atPath:)` and
/// `update_note`. A text document (`type == .asset`, `kind == .document`, a
/// path) inside a research root (`isInsideAResearchRoot`) is a palette card
/// when its path is inside the palette folder, and a note otherwise.
/// Anything else (a table, a picture, a PDF, audio, a link, a group, a
/// pathless item, and a text item whose path is anywhere else) is neither:
/// nil, and nothing writes it as Research text. A note and a card both keep
/// versions through the note door (RULING-24 as amended 2026-11-11); the
/// roles stay distinct for what edits them (`ResearchNoteEditor`,
/// `PaletteCardEditor`) and for the assistant, which writes notes only
/// (`update_note`, ADR 0034). Pure: views call it.
enum ResearchTextRole: Equatable {
    case note(path: String)
    case paletteCard

    /// `structure` says which `pieces/…` folders are loose pieces, whose
    /// `research/` folders are research roots.
    static func of(_ item: ResearchItem, structure: [StructureItem]) -> ResearchTextRole? {
        guard item.type == .asset, item.kind == .document, let path = item.path,
              isInsideAResearchRoot(path, structure: structure) else { return nil }
        // **A path prefix ending in the SEPARATOR**, not a name test and not a
        // bare `hasPrefix`: a research group called "Palette research" gives its
        // notes paths that start with the palette folder's characters and are
        // not inside it, and calling one of those a card shows "Card
        // unavailable" over a note the writer can see in their tree
        // (`test_aNoteBesideThePaletteFolderIsStillANote`).
        if path.hasPrefix(ProjectStore.paletteFolderPath + "/") { return .paletteCard }
        return .note(path: path)
    }

    /// **Whether `path` sits inside a research root** — the shared
    /// `research/` folder, or a loose piece's own research folder (asked of
    /// `ProjectStore.researchScopePieceId(ofPath:structure:)`, that root's one
    /// spelling) — with no component that is empty or starts with "." (so
    /// nothing under `.maugham/` or `.trash/`, no dotfile, no `..`). Compared
    /// by component, so `research-old/x.md` is not inside `research/`; case
    /// as written, as every research path Maugham mints is. The manifest is
    /// synced, untrusted input (tripwire 58's reason): a `.document` item
    /// naming the manuscript or the op log is never Research text.
    static func isInsideAResearchRoot(_ path: String, structure: [StructureItem]) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return false }
        if components[0] == "research" { return true }
        return ProjectStore.researchScopePieceId(ofPath: path, structure: structure) != nil
    }

    /// **The path of the Research table `item` is, nil when it is not one
    /// Maugham may open or write as a table** — a table asset (`type ==
    /// .asset`, `kind == .table`) whose path sits inside a research root
    /// (`isInsideAResearchRoot`, the one spelling of the roots). The table
    /// door asks it at every read and every write
    /// (`ResearchTableHost.readFile`, `.write`), and so do the centre
    /// column's router and `write_research_cells` / `read_research_table`:
    /// a synced manifest's `.table` naming the manuscript or the op log is
    /// never opened in the grid, never written, and keeps no version.
    static func tablePath(of item: ResearchItem, structure: [StructureItem]) -> String? {
        guard item.type == .asset, item.kind == .table, let path = item.path,
              isInsideAResearchRoot(path, structure: structure) else { return nil }
        return path
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
        /// replace it): the last moment that text exists. Also a palette
        /// card editor's own debounced save (`saveTyped`), whose draft is the
        /// only other copy of what the writer typed.
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
        /// A timer's save that did not land and whose text must not be lost:
        /// the version could not be kept, the file would not read, or the
        /// write failed. The editor's text stays pending for the next attempt.
        case stoppedTextStaysPending

        var asSave: ResearchNoteSave {
            switch self {
            case .saved(let kept): return .saved(keptAVersion: kept)
            case .notSaved, .stoppedTextStaysPending: return .notSaved
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
    /// stopped at the keep, at a file that will not read, or at a failed
    /// write leaves it for the next attempt (a keystroke's timer, or a
    /// flush), and a newer keystroke's edit replaces it.
    private func fire(_ itemId: String, generation: Int, in store: DocumentStore) async {
        guard let entry = pending[itemId], entry.generation == generation else { return }
        pending[itemId]?.timer = nil
        let outcome = await enqueue(itemId, text: entry.text, by: .writer, restoring: false,
                                    source: .editorTimer, in: store)
        if outcome != .stoppedTextStaysPending, pending[itemId]?.generation == generation {
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

    /// **A palette card editor's own save** (`PaletteCardEditor`, through
    /// `ProjectStore.updatePaletteCard(typed: true)`): the writer's typing,
    /// so it keeps a version once per editing run, as a note's typed save
    /// does, and moves no reload signal. The card editor debounces its own
    /// draft, so this arrives as a flush: when the version cannot be kept it
    /// is saved anyway and said (the draft is the only other copy).
    func saveTyped(_ itemId: String, text: String, owner: ProjectStore? = nil,
                   in store: DocumentStore) async -> ResearchNoteSave {
        if let entry = pending.removeValue(forKey: itemId) {
            entry.timer?.cancel()
            _ = await enqueue(itemId, text: entry.text, by: .writer, restoring: false,
                              source: .editorFlush, owner: owner, in: store)
        }
        return await enqueue(itemId, text: text, by: .writer, restoring: false,
                             source: .editorFlush, owner: owner, in: store).asSave
    }

    /// **Anyone else's write** of `itemId`. The editor's pending edit of the
    /// note is saved first (a flush), and is then the version this write
    /// replaces; once written, an editor open on the note reloads.
    /// `owner` is the project store asking, when it is one (a palette card's
    /// funnel, a rename sweep, Replace, a promotion): the item is looked up
    /// in it, so a store whose `DocumentStore` was wired one way only (a
    /// load-only test context) still finds what it is writing.
    func save(_ itemId: String, text: String, by writer: ResearchWriter, restoring: Bool,
              mustLand: Bool, owner: ProjectStore? = nil, in store: DocumentStore) async -> ResearchNoteSave {
        if let entry = pending.removeValue(forKey: itemId) {
            entry.timer?.cancel()
            _ = await enqueue(itemId, text: entry.text, by: .writer, restoring: false,
                              source: .editorFlush, owner: owner, in: store)
        }
        return await enqueue(itemId, text: text, by: writer, restoring: restoring,
                             source: .direct(mustLand: mustLand), owner: owner, in: store).asSave
    }

    /// One save, queued behind any save of the same note already in flight.
    private func enqueue(_ itemId: String, text: String, by writer: ResearchWriter, restoring: Bool,
                         source: SaveSource, owner: ProjectStore? = nil,
                         in store: DocumentStore) async -> Outcome {
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
                                    source: source, owner: owner, in: store)
        }
        inFlight[itemId] = (token, task)
        return await task.value
    }

    private func finished(_ itemId: String, token: Int) {
        if inFlight[itemId]?.token == token { inFlight[itemId] = nil }
    }

    /// **Returns once `itemId` (nil: every note) has no edit pending and no
    /// save in flight** — the one loop for the store's flush (and so its
    /// close) and for a writer about to read one note's file. Waiting only
    /// for pending edits is not enough: a flush takes an edit out of
    /// `pending` as its save begins, so while that save is in its keep a
    /// writer that saw nothing pending would read the bytes before it, and
    /// its own save, queued behind the flush, would write them back over the
    /// edit (`test_aWriterThatReadsTheNoteWaitsForAFlushAlreadyInFlight`).
    /// Never called from inside a door save (its task would wait on itself).
    func settle(_ itemId: String? = nil, in store: DocumentStore) async {
        while true {
            if itemId.map({ pending[$0] != nil }) ?? !pending.isEmpty {
                await flushPending(in: store)
                continue
            }
            let saving: Task<Outcome, Never>?
            if let itemId { saving = inFlight[itemId]?.task } else { saving = inFlight.values.first?.task }
            guard let saving else { return }
            _ = await saving.value
        }
    }

    // MARK: The door

    /// **The one door for an existing note's text**, step for step the table
    /// door's: the item and its path asked now; the prior bytes read off the
    /// main actor; the version kept (off it) when the run, a restore, or bytes
    /// this store did not write say so; then the file; then the record of who
    /// wrote it.
    private func write(_ itemId: String, text: String, by writer: ResearchWriter, restoring: Bool,
                       source: SaveSource, owner: ProjectStore?, in store: DocumentStore) async -> Outcome {
        let projectURL = store.projectURL
        let item: ResearchItem, path: String
        switch noteLookup(itemId, owner: owner, in: store) {
        case .note(let found, let foundPath): (item, path) = (found, foundPath)
        case let missed: return unreachable(itemId, missed, text: text, source: source, in: store)
        }
        guard let fileURL = resolved(path, in: store) else {
            return unreachable(itemId, .refusedPath(item, path), text: text, source: source, in: store)
        }

        let prior: PriorBytes = await Task.detached { PriorBytes.read(fileURL) }.value
        let onDisk: Data?
        switch prior {
        case .missing: onDisk = nil
        case .bytes(let data): onDisk = data
        case .unreadable:
            // A file that is there but will not read cannot be kept: nothing
            // is written over it (RULING-7), whatever the source.
            return refusedOverAnUnreadableFile(itemId, item, fileURL, text: text, by: writer,
                                               restoring: restoring, source: source, projectURL: projectURL)
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
                        sayOnceForTheTimer(itemId,
                            "“\(item.title)”’s previous version couldn’t be kept, so your edits aren’t saved yet. They stay in the editor and are saved when you leave the note.",
                            projectURL: projectURL)
                        return .stoppedTextStaysPending
                    case .stopTheSave:
                        MaughamEvent.postNotice(
                            "“\(item.title)”’s previous version couldn’t be kept, so \(Self.whose(writer, restoring: restoring)) saved over it.",
                            projectURL: projectURL)
                        return .notSaved
                    case .saveAnyway where source == .direct(mustLand: true):
                        // Not the writer's edits: the text a move's refs
                        // were rewritten in (the only write that must land).
                        MaughamEvent.postNotice(
                            "“\(item.title)”’s previous version couldn’t be kept; its picture links were updated anyway.",
                            projectURL: projectURL)
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
        let pathNow: String
        switch noteLookup(itemId, owner: owner, in: store) {
        case .note(_, let foundPath): pathNow = foundPath
        case let missed: return unreachable(itemId, missed, text: text, source: source, in: store)
        }
        do {
            try await store.performFileSave(path: pathNow, text: text)
        } catch ProjectStoreError.unsafeProjectPath(let refused, let reason) {
            store.logRefusedSave(path: refused, reason: reason)
            return unreachable(itemId, .refusedPath(item, pathNow), text: text, source: source, in: store)
        } catch {
            researchNoteLog.error(
                "\(pathNow, privacy: .public) was not saved: \(error.localizedDescription, privacy: .public)")
            // A timer's text stays pending (the next keystroke's timer, or
            // the flush, tries again); a flush's text — the last copy there
            // is — is kept as a conflict backup; anyone else's write is not made.
            let couldNot = "Couldn’t save “\(item.title)”: \(error.localizedDescription)"
            switch source {
            case .editorTimer:
                sayOnceForTheTimer(itemId,
                    "Couldn’t save “\(item.title)” yet: \(error.localizedDescription) Your edits stay in the editor and are saved when you leave the note.",
                    projectURL: projectURL)
                return .stoppedTextStaysPending
            case .editorFlush:
                return keepTheFlushedText(itemId, fileURL, text: text, couldNot: couldNot, projectURL: projectURL)
            case .direct:
                MaughamEvent.postNotice(couldNot, projectURL: projectURL)
                return .notSaved
            }
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

    /// **A file that is there but will not read is never saved over**
    /// (RULING-7; Review Focus 4). A timer's text stays pending, said once.
    /// A flush is the last moment the editor's text exists, so it is kept as
    /// a conflict backup under `.maugham/conflicts/` (the helper the table
    /// door keeps an outside version with) and the notice names it; anyone
    /// else's write is refused and said.
    private func refusedOverAnUnreadableFile(_ itemId: String, _ item: ResearchItem, _ fileURL: URL,
                                             text: String, by writer: ResearchWriter, restoring: Bool,
                                             source: SaveSource, projectURL: URL) -> Outcome {
        let unread = "Maugham couldn’t read “\(item.title)” to keep its previous version"
        switch source {
        case .editorTimer:
            sayOnceForTheTimer(itemId,
                "\(unread), so your edits aren’t saved over it. They stay in the editor, and when you leave the note they are kept as a conflict backup.",
                projectURL: projectURL)
            return .stoppedTextStaysPending
        case .editorFlush:
            if let backup = keptAsAConflictBackup(itemId, fileURL, text: text) {
                MaughamEvent.postNotice(
                    "\(unread), so your edits weren’t saved over it. They were kept in the project’s .maugham/conflicts folder as “\(backup.lastPathComponent)”.",
                    projectURL: projectURL)
            } else {
                MaughamEvent.postNotice(
                    "\(unread), so your edits weren’t saved over it, and they couldn’t be kept anywhere else.",
                    projectURL: projectURL)
            }
            return .notSaved
        case .direct:
            MaughamEvent.postNotice(
                "\(unread), so \(Self.whose(writer, restoring: restoring)) saved over it.",
                projectURL: projectURL)
            return .notSaved
        }
    }

    /// A flushed text that did not land, kept as a conflict backup and said:
    /// `couldNot` (a sentence) and where the text is, or that it is nowhere.
    private func keepTheFlushedText(_ itemId: String, _ fileURL: URL, text: String, couldNot: String,
                                    projectURL: URL) -> Outcome {
        if let backup = keptAsAConflictBackup(itemId, fileURL, text: text) {
            MaughamEvent.postNotice(
                "\(couldNot) Your edits were kept in the project’s .maugham/conflicts folder as “\(backup.lastPathComponent)”.",
                projectURL: projectURL)
        } else {
            MaughamEvent.postNotice(
                "\(couldNot) Your edits weren’t saved, and they couldn’t be kept anywhere else.",
                projectURL: projectURL)
        }
        return .notSaved
    }

    /// **A save that cannot reach the note's file**: the item left Research,
    /// is no longer a note, or its path is refused. The editor's text is not
    /// dropped — a timer's stays pending (said once) and a flush's is kept as
    /// a conflict backup and named; anyone else's write is refused as before
    /// (a gone note said, a non-note logged, a refused path logged).
    private func unreachable(_ itemId: String, _ why: NoteLookup, text: String, source: SaveSource,
                             in store: DocumentStore) -> Outcome {
        let projectURL = store.projectURL
        let reason: String, title: String, anchor: URL?
        switch why {
        case .note: return .notSaved
        case .gone:
            (reason, title, anchor) = ("it is no longer in Research", "a Research note", nil)
        case .notANote(let item):
            (reason, title, anchor) = ("it is no longer a Research note", "“\(item.title)”",
                                       item.path.flatMap { try? store.resolvedProjectPath($0) })
        case .refusedPath(let item, _):
            (reason, title, anchor) = ("its path isn’t a place inside this project", "“\(item.title)”", nil)
        }
        switch source {
        case .editorTimer:
            sayOnceForTheTimer(itemId,
                "Couldn’t save \(title): \(reason). Maugham is holding your edits and keeps them as a conflict backup at the next save — leaving the note, ⌘S, or closing the project.",
                projectURL: projectURL)
            return .stoppedTextStaysPending
        case .editorFlush:
            // With no file to name the backup after, it is named as a note
            // in Research would be; the project root is found from it.
            let named = anchor ?? projectURL.appendingPathComponent("research/note.md") // local-path: only names the backup under .maugham/conflicts/
            return keepTheFlushedText(itemId, named, text: text, couldNot: "Couldn’t save \(title): \(reason).",
                                      projectURL: projectURL)
        case .direct:
            switch why {
            case .gone:
                MaughamEvent.postNotice("A Research note’s edits couldn’t be saved: it is no longer in Research.",
                                        projectURL: projectURL)
            case .notANote:
                researchNoteLog.error("\(itemId, privacy: .public) is not a Research note; the note door wrote nothing")
            case .note, .refusedPath:
                break
            }
            return .notSaved
        }
    }

    /// **A flush's text that did not land, kept** — the editor's text is the
    /// last copy there is — as a conflict backup under `.maugham/conflicts/`
    /// (`Document.writeConflictBackup`, the helper the table door keeps an
    /// outside version with). Its URL; nil, logged, when it could not be kept.
    private func keptAsAConflictBackup(_ itemId: String, _ fileURL: URL, text: String) -> URL? {
        do {
            return try Document.writeConflictBackup(forFileAt: fileURL, docId: itemId, text: text, kind: "unsaved")
        } catch {
            researchNoteLog.error(
                "\(itemId, privacy: .public)'s unsaved edits were not kept: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A timer-stop notice, said once — not once per typing pause — until a
    /// save of the note lands or the note is read again.
    private func sayOnceForTheTimer(_ itemId: String, _ sentence: String, projectURL: URL) {
        guard !(notes[itemId]?.timerStopSaid ?? false) else { return }
        notes[itemId, default: NoteState()].timerStopSaid = true
        MaughamEvent.postNotice(sentence, projectURL: projectURL)
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

    /// What the manifest says `itemId` is now, for a save.
    private enum NoteLookup {
        /// A note the door takes, and its path.
        case note(ResearchItem, String)
        /// No longer in Research (or pathless).
        case gone
        /// There, but not the door's (`takes`: a table, a picture, a text
        /// item outside a research root).
        case notANote(ResearchItem)
        /// A note whose path the project refuses (`SafeRelativePath`).
        case refusedPath(ResearchItem, String)
    }

    /// The note `itemId` names and its path, asked of the manifest now
    /// (`takes`, so `ResearchTextRole`: nothing outside a research root);
    /// anything else is `unreachable`'s to say.
    private func noteLookup(_ itemId: String, owner: ProjectStore?, in store: DocumentStore) -> NoteLookup {
        let projectStore = owner ?? store.projectStore
        guard let item = projectStore.flatMap({ $0.findResearchItem(id: itemId, in: $0.manifest.research) }),
              let path = item.path else { return .gone }
        guard Self.takes(item, structure: projectStore?.manifest.structure ?? []) else { return .notANote(item) }
        return .note(item, path)
    }

    /// **Whether a write of `item`'s text goes through the door** — the one
    /// question every writer of existing Research text asks. A note and a
    /// palette card both do (Denver, 2026-11-11: cards keep versions as notes
    /// do); `ResearchTextRole` says which of the two it is, and nil is
    /// neither. Every card writer — the card editor, the palette funnel
    /// (`ProjectStore.paletteCoordinatedWrite`), a promotion, the inbox, the
    /// rename's link sweep, Replace, a move's asset refs — comes here.
    nonisolated static func takes(_ item: ResearchItem, structure: [StructureItem]) -> Bool {
        ResearchTextRole.of(item, structure: structure) != nil
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

/// Why a note's version was not put back; the note is as it was.
struct ResearchNoteRestoreError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

extension DocumentStore {

    /// **Research note `itemId` put back to a kept `version`**, through the
    /// door (`restoring: true`: what it replaces is kept, so restoring again
    /// undoes it). Refused under a view-only share (as `restoreResearchTable`),
    /// for a version that is not a note's, and for bytes that are not UTF-8
    /// (nothing is written). A version's bytes are the file's bytes verbatim:
    /// the text is those bytes decoded without normalising (a BOM and CRLF
    /// survive). Restoring the text the note already holds writes and keeps
    /// nothing, and succeeds.
    func restoreResearchNote(itemId: String, to version: ResearchVersion,
                             shareIsReadOnly: Bool) async throws {
        if shareIsReadOnly { throw ResearchTableHost.Refused(reason: .viewOnlyShare, noun: "note") }
        guard version.payload == .note else {
            throw ResearchNoteRestoreError(message: "That version is of a table, not a note.")
        }
        let projectURL = self.projectURL
        let bytes: Data
        do {
            bytes = try await Task.detached {
                try ResearchVersionStore(projectURL: projectURL).read(version).0
            }.value
        } catch {
            throw ResearchNoteRestoreError(message: "That version couldn’t be read, so the note is as it was.")
        }
        guard String(data: bytes, encoding: .utf8) != nil else {
            throw ResearchNoteRestoreError(
                message: "That version isn’t UTF-8 text, so it wasn’t restored and the note is as it was.")
        }
        // `decoding:` keeps a leading BOM, which `String(data:encoding:)` may drop.
        let text = String(decoding: bytes, as: UTF8.self)
        guard case .saved = await saveResearchNote(itemId: itemId, text: text, restoring: true) else {
            throw ResearchNoteRestoreError(message: "That version wasn’t restored; the note is as it was.")
        }
    }

    /// **The one door every write of an existing Research note's text goes
    /// through** (`ResearchNoteDoor`) outside the editor: the bytes it
    /// replaces are always kept as a version first (a retry of the same bytes
    /// once), and the writer's typing run ends. `writer` is whose text this is.
    /// Takes a note or a palette card; refuses a table, or an id that names
    /// neither.
    /// `mustLand`: saved even when that version cannot be kept, with a
    /// notice saying so (a write whose reason has already happened, as a
    /// moved note's asset refs).
    /// `from`: the project store asking, when one is (`ResearchNoteDoor.save`'s `owner`).
    @discardableResult
    func saveResearchNote(itemId: String, text: String, by writer: ResearchWriter = .writer,
                          restoring: Bool = false, mustLand: Bool = false,
                          from projectStore: ProjectStore? = nil) async -> ResearchNoteSave {
        await researchNoteDoor.save(itemId, text: text, by: writer, restoring: restoring,
                                    mustLand: mustLand, owner: projectStore, in: self)
    }

    /// **A palette card editor's own save of the card's text** — the writer's
    /// typing (`ResearchNoteDoor.saveTyped`): one version per editing run,
    /// no reload of the editor that wrote it.
    @discardableResult
    func saveTypedResearchText(itemId: String, text: String,
                               from projectStore: ProjectStore? = nil) async -> ResearchNoteSave {
        await researchNoteDoor.saveTyped(itemId, text: text, owner: projectStore, in: self)
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

    /// **Returns once note `itemId` has no edit waiting and no save in
    /// flight** (`ResearchNoteDoor.settle`). A writer that reads a note's
    /// file to write a changed copy back (a rename's link sweep, Replace, a
    /// promotion's appended link, a move's asset refs) reads after this, with
    /// no `await` before its `saveResearchNote`: otherwise an edit typed
    /// during its earlier awaits, or one another caller's flush is saving,
    /// is written over by text made from the bytes before it.
    func settleResearchNoteEdits(itemId: String) async {
        await researchNoteDoor.settle(itemId, in: self)
    }

    /// The note `itemId`'s `bytes` were read (the editor's load): a later save
    /// over them is over known bytes.
    func researchNoteWasRead(itemId: String, bytes: Data) {
        researchNoteDoor.wasRead(itemId: itemId, bytes: bytes)
    }

    /// **The Research note or palette card at `path`**, nil for a path whose
    /// text the door does not take (a table, anything else) — the one path →
    /// door item lookup.
    func researchNoteItem(atPath path: String) -> ResearchItem? {
        guard let projectStore else { return nil }
        return TreeWalk.first(in: projectStore.manifest.research) { item in
            item.path == path && ResearchNoteDoor.takes(item, structure: projectStore.manifest.structure)
        }
    }
}
