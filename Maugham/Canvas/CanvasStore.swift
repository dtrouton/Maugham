import AppKit
import MaughamCore

/// Disk I/O for the canvas: the derived sidecar and the plain-text scraps.
///
/// Two files with two different statuses, and the split is the point (spec §8):
/// `.maugham/canvas.json` is derived state and may be deleted without losing a
/// word; `canvas.md` is content and is never written anywhere else.
final class CanvasStore {

    static let sidecarRelativePath = ".maugham/canvas.json"
    static let scrapsRelativePath = "canvas.md"

    /// Read by `CanvasModel.startFreshLayout`, which re-attaches to the same
    /// project after the damaged file is set aside.
    let projectRoot: URL
    private var pendingSave: DispatchWorkItem?
    /// The last payload `scheduleSave` queued. Held so `flush()` needs no
    /// arguments and so the app-quit hook has something to write.
    private var pendingPayload: (scene: CanvasScene, scraps: [CanvasNodeID: String])?
    private var terminationObserver: NSObjectProtocol?

    /// The owner's last chance to fold live editor text into the payload before
    /// it is written. `CanvasView` binds this to `CanvasEditFocus.syncActiveEdit`, so a quit
    /// mid-sentence writes the sentence. Calling `scheduleSave` from here is
    /// safe and is the intended use — it only queues, and `flush` cancels the
    /// queue on the very next line.
    var beforeFlush: (() -> Void)?

    /// Matches `DocumentStore`'s autosave debounce, so canvas edits and
    /// manuscript edits settle on the same rhythm.
    static let defaultDebounceInterval: TimeInterval = 0.75

    private let debounceInterval: TimeInterval

    /// Whether a file is an iCloud item whose bytes are not current on this Mac
    /// (issue #88). Asked BEFORE either file is read, because reading a dataless
    /// file from the main actor can block on a download; such a file is
    /// `.unreadable` without a byte read. Injected by tests; production is the
    /// app's one stub rule, `OpLogQuarantine.defaultStubProbe`. **Its limit:** it
    /// knows iCloud's dataless files only (`isUbiquitousItem`); a dataless file
    /// from a third-party File Provider (Dropbox, OneDrive…) is not detected, and
    /// reading one can still block on its download.
    private let isStub: (URL) -> Bool
    /// Asks iCloud to bring a stub down, so a later retry finds the bytes.
    /// Never waited on.
    private let startDownload: (URL) -> Void

    init(projectRoot: URL,
         debounceInterval: TimeInterval = CanvasStore.defaultDebounceInterval,
         isStub: @escaping (URL) -> Bool = OpLogQuarantine.defaultStubProbe,
         startDownload: @escaping (URL) -> Void = CanvasStore.defaultStartDownload) {
        self.projectRoot = projectRoot
        self.debounceInterval = debounceInterval
        self.isStub = isStub
        self.startDownload = startDownload
        // `.onDisappear` does NOT fire on app quit, and the 750ms debounce is
        // exactly long enough to lose the writer's last drag. This is an AppKit
        // lifecycle notification, not a `maugham.*` one, so it is outside
        // `MaughamEvent`'s remit (tripwire 21).
        //
        // `queue: nil` is REQUIRED, not a default. With a queue the block is
        // enqueued rather than run on the posting thread, and during termination
        // the hop may never run — which is precisely the write this observer
        // exists to guarantee.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.flush()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        // Deliberately NOT flushing here. Every real path is already covered —
        // the debounce timer, `CanvasView.onDisappear`, and app termination —
        // and a `deinit` write lands wherever the store happens to die, which in
        // tests is a temp directory `tearDown` has already removed.
    }

    var hasPendingWrite: Bool { pendingPayload != nil }

    private var sidecarURL: URL { projectRoot.appendingPathComponent(Self.sidecarRelativePath) } // local-path: a fixed constant
    private var scrapsURL: URL { projectRoot.appendingPathComponent(Self.scrapsRelativePath) } // local-path: a fixed constant

    /// What the sidecar turned out to be — **and it is not decoration**.
    ///
    /// An empty scene is returned for three different situations, and one of them
    /// is not like the others: a file this build could not read is a file that
    /// still holds the writer's arrangement, for some other build. Without this
    /// distinction a reader cannot tell "there was nothing here" from "there is
    /// something here I do not understand", and F9's load-time repair would
    /// answer the second by saving a current-schema sidecar over it — losing
    /// every region, line, position, mark and binding in it, on **open**.
    enum SidecarState: Equatable {
        /// Decoded, at a schema this build understands.
        case decoded
        /// No file. Nothing to lose, so a writer-facing repair may be saved.
        case absent
        /// **Present and unreadable** — undecodable bytes, or a schema from a
        /// newer build. The layout in it is not ours to overwrite.
        case refused

        /// Whether a repair made at load time may be WRITTEN back.
        ///
        /// An arrangement this build cannot read is one it must not stamp over
        /// merely because the writer looked at the canvas. (Every OTHER write is
        /// refused by the store itself once its load answered `.refused` — see
        /// `Loaded.refusal` — so this reader is the repair's alone.)
        var acceptsARepairWrite: Bool { self != .refused }
    }

    /// What a load found. **A struct rather than the pair**, so a reader cannot
    /// take the scene without the fact that it may be empty for a reason that
    /// forbids writing over it.
    struct Loaded {
        var scene: CanvasScene
        var scraps: [CanvasNodeID: String]
        let sidecar: SidecarState
        /// **The one answer to *is this canvas refused, and why*** (issue #44),
        /// for every route: `CanvasModel.attach` holds it for a canvas that is
        /// open, and `loadForTransientWrite` throws it for a write made with none
        /// open — so the error a caller sees is the same value either way.
        /// Non-nil exactly when `sidecar == .refused`.
        let refusal: SidecarRefused?
    }

    /// Only `schemaVersion`, read before the full decode, so a newer build's file
    /// is told apart from a damaged one even when the rest of it has changed
    /// shape beyond what this build's `CanvasSceneDTO` can decode.
    private struct VersionProbe: Decodable { let schemaVersion: Int }

    /// Set by every `load()`: the refusal it answered, or nil. **While it is set
    /// this store writes nothing** — not the debounced save, not a flush at quit,
    /// not a direct save — because a model attached over a refused file holds an
    /// in-memory scene this build made up (the words laid out loose), and writing
    /// it would replace the arrangement the file actually holds (issue #44). The
    /// refusal is SILENT here on purpose: `flush` runs from app termination and
    /// from `.onDisappear`, where nobody can be told. The loud refusals are the
    /// doors' — the model, the tool, the inbox — which ask before they change
    /// anything.
    private var loadRefusal: SidecarRefused?

    func load() -> Loaded {
        // canvas.md is scrap CONTENT, not a manuscript — it never goes through
        // the op log (spec §8); this function IS its reconciler.
        //
        // **Absent and unreadable are two different facts** (issue #88). An
        // absent canvas.md is a canvas with no scraps yet; one that is there and
        // will not read (an iCloud stub, a permissions break, a directory in its
        // place) still holds every scrap's words, and the next save would write
        // `ScrapText.render([:])` over them. So it refuses the load exactly as an
        // unreadable layout does.
        let scrapsRead = Self.read(scrapsURL, isStub: isStub, startDownload: startDownload)
        var scraps: [CanvasNodeID: String] = [:]
        var scrapsUnreadable = false
        switch scrapsRead {
        case .absent:
            break
        case .unreadable:
            scrapsUnreadable = true
        case .bytes(let data):
            // Not lossy: bytes that are not UTF-8 are words this build can't
            // read, and a save would replace them with whatever a lossy decode
            // made of them.
            if let text = String(data: data, encoding: .utf8) {
                scraps = ScrapText.parse(text)
            } else {
                scrapsUnreadable = true
            }
        }

        // Unreadable outranks every other answer: it is the one that may change
        // on its own (a download finishing), and a damaged layout must not be
        // offered Start a Fresh Layout while the words beside it can't be read.
        // The sidecar is not READ then — the answer is already refused — only
        // probed, so a stub of it starts downloading for the next retry.
        if scrapsUnreadable {
            if isStub(sidecarURL) { startDownload(sidecarURL) }
            return refuse(.unreadable, scraps: [:])
        }

        // canvas.json is the derived sidecar, not a manuscript.
        let sidecarRead = Self.read(sidecarURL, isStub: isStub, startDownload: startDownload)
        let data: Data
        switch sidecarRead {
        case .absent:
            loadRefusal = nil
            return Loaded(scene: CanvasScene(), scraps: scraps, sidecar: .absent, refusal: nil)
        case .unreadable:
            return refuse(.unreadable, scraps: scraps)
        case .bytes(let bytes):
            data = bytes
        }
        switch Self.decode(data) {
        case .failure(let reason):
            // Corrupt, or from a newer build. An empty layout with the words
            // intact is a recoverable state; a crash is not — and the FILE is
            // left alone, because it is somebody's arrangement.
            return refuse(reason, scraps: scraps)
        case .success(let dto):
            loadRefusal = nil
            return Loaded(scene: dto.scene, scraps: scraps, sidecar: .decoded, refusal: nil)
        }
    }

    /// A refused load: the scene is empty (what this build made up is not the
    /// writer's layout), the words that DID read are kept, and nothing this
    /// store holds may be written from now on.
    private func refuse(_ reason: SidecarRefused.Reason,
                        scraps: [CanvasNodeID: String]) -> Loaded {
        let refusal = SidecarRefused(projectName: projectRoot.lastPathComponent,
                                     reason: reason)
        loadRefusal = refusal
        // A payload queued before this load was made against whatever the
        // file held THEN; it may not land over what it holds now.
        pendingSave?.cancel()
        pendingSave = nil
        pendingPayload = nil
        return Loaded(scene: CanvasScene(), scraps: scraps, sidecar: .refused,
                      refusal: refusal)
    }

    /// What reading one of the canvas's two files found (issue #88).
    enum FileRead: Equatable {
        /// No file and no iCloud placeholder for one: nothing to lose.
        case absent
        case bytes(Data)
        /// **Present, and not readable right now** — an iCloud stub or
        /// placeholder, a permissions break, a directory in its place, an I/O
        /// error. It is somebody's file, so it is never written over.
        case unreadable
    }

    /// **The one classifier both files and `setDamagedSidecarAside` read
    /// through.** Never blocks on iCloud: a stub is answered from its resource
    /// values before any byte is asked for (and a download is requested, not
    /// awaited). Only a missing file with no `.<name>.icloud` placeholder beside
    /// it is absent; every other failure is unreadable.
    static func read(_ url: URL,
                     isStub: (URL) -> Bool,
                     startDownload: (URL) -> Void) -> FileRead {
        if isStub(url) {
            startDownload(url)
            return .unreadable
        }
        do {
            return .bytes(try Data(contentsOf: url)) // adr-0018-ok: canvas.md scrap text / canvas.json derived sidecar, not manuscript
        } catch {
            guard isNoSuchFile(error) else { return .unreadable }
            if hasICloudPlaceholder(for: url) {
                startDownload(url)
                return .unreadable
            }
            return .absent
        }
    }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileReadNoSuchFile.rawValue {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) {
            return true
        }
        return false
    }

    /// The old-style iCloud placeholder: the real file is gone and
    /// `.<name>.icloud` stands beside it. The same shape the op-log sweep
    /// refuses on (`StreamPositions.nameBehindICloudPlaceholder`, Core-internal,
    /// hence spelled here from the other direction).
    static func hasICloudPlaceholder(for url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    /// Production download request. Fire-and-forget; a failure only means a
    /// retry finds the file still unreadable.
    static func defaultStartDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// The sidecar's bytes decoded, or why this build cannot use them.
    ///
    /// **The version is asked FIRST.** A file whose `schemaVersion` is above ours
    /// is a newer build's whatever the rest of it looks like — that build may
    /// well have changed shapes this one cannot decode, and calling such a file
    /// "damaged" would offer the writer a repair that sets their real layout
    /// aside. Only a file that does not even carry a readable version, or one at
    /// a version we know whose body still fails to decode, is damaged.
    private static func decode(_ data: Data) -> Result<CanvasSceneDTO, SidecarRefused.Reason> {
        let decoder = JSONDecoder()
        if let probe = try? decoder.decode(VersionProbe.self, from: data),
           probe.schemaVersion > CanvasSceneDTO.currentSchemaVersion {
            return .failure(.newerVersion)
        }
        guard let dto = try? decoder.decode(CanvasSceneDTO.self, from: data) else {
            return .failure(.damaged)
        }
        return .success(dto)
    }

    /// The sidecar is there and this build cannot read it — a newer build's
    /// schema, or damaged bytes — so nothing is allowed to replace somebody's
    /// whole arrangement: not a write made with no canvas open (issue #33), and
    /// not one made through a canvas that is (issue #44).
    struct SidecarRefused: Error, LocalizedError, Equatable {
        /// Two different facts, with two different ways out: updating Maugham
        /// helps a newer build's file and does nothing for a damaged one.
        enum Reason: Error, Equatable {
            /// The file's `schemaVersion` is above this build's.
            case newerVersion
            /// Not JSON, truncated, hand-edited — anything at a version this build
            /// knows (or with no readable version at all) that will not decode.
            case damaged
            /// Either file — `canvas.json` or `canvas.md` — is there but could not
            /// be read just now: an iCloud stub still downloading, a placeholder,
            /// a permissions break (issue #88). Unlike the other two it can
            /// change on its own, so the way out is waiting, never a fresh layout.
            case unreadable

            /// The writer-facing sentence, one per reason (Denver's rulings on
            /// #44, 2026-10-18). Every surface — the canvas's notice, the inbox
            /// alert, the tool's refusal — says it from this one value.
            var sentence: String {
                switch self {
                case .newerVersion:
                    return "This canvas was saved by a newer version of Maugham, so only its words are shown. Update Maugham to see and edit your layout."
                case .damaged:
                    return "This canvas's layout file is damaged, so only its words are shown. Start a Fresh Layout sets the damaged file aside and lays your words out again."
                case .unreadable:
                    return "Maugham couldn't read this canvas's files just now, so it can't be changed yet. If the project is in iCloud they may still be downloading — Maugham will keep trying."
                }
            }
        }

        /// The project's folder name, so a caller with several projects open can
        /// say which one it is about.
        let projectName: String
        let reason: Reason

        var errorDescription: String? { reason.sentence }
    }

    /// Why Start a Fresh Layout did not set anything aside. (A NEWER build's
    /// file is refused with its own `SidecarRefused` instead, whose sentence
    /// already says the way out — updating Maugham.)
    enum FreshLayoutRefused: Error, LocalizedError, Equatable {
        /// The file is not damaged (any more): it is absent, or it reads.
        case nothingDamaged
        /// The model is not attached to a canvas on screen.
        case canvasNotOpen

        var errorDescription: String? {
            switch self {
            case .nothingDamaged:
                return "There's no damaged layout file to set aside. Close and reopen the project to see the canvas as it is now."
            case .canvasNotOpen:
                return "Open the canvas to start a fresh layout."
            }
        }
    }

    /// Where the damaged sidecar goes: `.maugham/canvas.damaged-<stamp>.json`,
    /// beside the file it was, with `-2`, `-3`… added when that name is taken.
    /// Pure, so the name and the collision rule are pinned without a disk.
    static func asideName(stamp: String, attempt: Int) -> String {
        attempt <= 1 ? "canvas.damaged-\(stamp).json"
                     : "canvas.damaged-\(stamp)-\(attempt).json"
    }

    static let asideStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        return f
    }()

    /// **Start a Fresh Layout's file half** (issue #44): move a DAMAGED sidecar
    /// aside and keep it — never delete it, never overwrite an earlier aside
    /// file — so the next `load()` finds no sidecar and lays the writer's words
    /// out again. `canvas.md` is not touched: the words were never in this file.
    ///
    /// **It re-reads the file rather than trusting the load's verdict**, because
    /// the bytes can have changed since (a sync): a file that is now a NEWER
    /// build's throws that refusal and moves nothing — setting a real layout
    /// aside is exactly the thing this verb must never do — and one that is
    /// absent or now reads throws `.nothingDamaged`.
    ///
    /// A raw `moveItem`, deliberately not the typed `DocumentStore` mover
    /// (tripwire 14): that rule is for user-editable CONTENT an autosave could
    /// recreate at the old path. This is the derived sidecar, no `Document`
    /// holds it, and this store's own writes are refused while its load is
    /// refused — the one write that follows is the fresh layout itself.
    ///
    /// Returns where the damaged file now is.
    func setDamagedSidecarAside(now: Date = Date()) throws -> URL {
        let data: Data
        switch Self.read(sidecarURL, isStub: isStub, startDownload: startDownload) {
        case .absent:
            throw FreshLayoutRefused.nothingDamaged
        case .unreadable:
            // Not damaged — not readable at all just now (#88). Nothing moves.
            throw SidecarRefused(projectName: projectRoot.lastPathComponent,
                                 reason: .unreadable)
        case .bytes(let bytes):
            data = bytes
        }
        switch Self.decode(data) {
        case .failure(.damaged):
            break
        case .failure(let reason):
            throw SidecarRefused(projectName: projectRoot.lastPathComponent, reason: reason)
        case .success:
            throw FreshLayoutRefused.nothingDamaged
        }
        let fm = FileManager.default
        let directory = sidecarURL.deletingLastPathComponent()
        let stamp = Self.asideStampFormatter.string(from: now)
        var attempt = 1
        while true {
            let aside = directory.appendingPathComponent(
                Self.asideName(stamp: stamp, attempt: attempt))
            if !fm.fileExists(atPath: aside.path) {
                do {
                    // `moveItem` refuses an existing destination, so a file
                    // that appears between the check and the move is never
                    // overwritten — it only costs another attempt.
                    try fm.moveItem(at: sidecarURL, to: aside)
                    return aside
                } catch CocoaError.fileWriteFileExists {
                    // Taken in the gap; try the next name.
                }
            }
            attempt += 1
        }
    }

    /// The one place a transient write asks permission. Loads, and throws the
    /// load's own `refusal` when the sidecar is present and unreadable.
    func loadForTransientWrite() throws -> Loaded {
        let loaded = load()
        if let refusal = loaded.refusal { throw refusal }
        return loaded
    }

    func save(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        guard loadRefusal == nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        pendingPayload = nil
        writeNow(scene: scene, scraps: scraps)
    }

    /// Debounced — a drag emits a position per frame and must not emit a write
    /// per frame.
    func scheduleSave(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        // Nothing is even queued, so `hasPendingWrite` stays false over a
        // refused file and a quit has nothing to flush.
        guard loadRefusal == nil else { return }
        pendingSave?.cancel()
        pendingPayload = (scene, scraps)
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Write whatever `scheduleSave` last queued, now. Called from the debounce
    /// timer, from `CanvasView.onDisappear`, and from app termination. A no-op
    /// when nothing is pending — it must never stamp an empty canvas over a real
    /// one.
    func flush() {
        // Before `beforeFlush`, too: over a refused file there is no payload to
        // fold the live text into, because nothing may be written at all.
        guard loadRefusal == nil else { return }
        // The owner's last chance to fold live editor text into the payload.
        beforeFlush?()
        pendingSave?.cancel()
        pendingSave = nil
        guard let payload = pendingPayload else { return }
        pendingPayload = nil
        writeNow(scene: payload.scene, scraps: payload.scraps)
    }

    /// Write the derived sidecar and **nothing else**.
    ///
    /// `canvas.md` is CONTENT (spec §8) and this deliberately does not touch it.
    /// The one caller is craft-intent adoption, which re-points marks inside
    /// `ProjectStore.load` before any `CanvasModel` exists: it has no scrap text
    /// of its own, and putting a parse→render round trip of the writer's scraps
    /// on a migration path is a risk with nothing on the other side of it.
    func saveSceneOnly(_ scene: CanvasScene) {
        guard loadRefusal == nil else { return }
        writeSidecar(scene)
    }

    private func writeNow(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        // Content first, derived second (F11, issue #28): both writes are
        // individually atomic but the PAIR is not, and a crash in the gap must
        // only ever lag the deletable sidecar — never leave a node in
        // canvas.json whose words missed canvas.md.
        try? ScrapText.render(scraps).write(to: scrapsURL, atomically: true, encoding: .utf8)
        writeSidecar(scene)
    }

    private func writeSidecar(_ scene: CanvasScene) {
        try? FileManager.default.createDirectory(
            at: sidecarURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(CanvasSceneDTO(scene: scene)) {
            try? data.write(to: sidecarURL, options: .atomic)
        }
    }
}
