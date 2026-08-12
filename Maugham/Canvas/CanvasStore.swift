import AppKit

/// Disk I/O for the canvas: the derived sidecar and the plain-text scraps.
///
/// Two files with two different statuses, and the split is the point (spec §8):
/// `.maugham/canvas.json` is derived state and may be deleted without losing a
/// word; `canvas.md` is content and is never written anywhere else.
final class CanvasStore {

    static let sidecarRelativePath = ".maugham/canvas.json"
    static let scrapsRelativePath = "canvas.md"

    private let projectRoot: URL
    private var pendingSave: DispatchWorkItem?
    /// The last payload `scheduleSave` queued. Held so `flush()` needs no
    /// arguments and so the app-quit hook has something to write.
    private var pendingPayload: (scene: CanvasScene, scraps: [CanvasNodeID: String])?
    private var terminationObserver: NSObjectProtocol?

    /// The owner's last chance to fold live editor text into the payload before
    /// it is written. `CanvasView` binds this to `syncActiveEdit`, so a quit
    /// mid-sentence writes the sentence. Calling `scheduleSave` from here is
    /// safe and is the intended use — it only queues, and `flush` cancels the
    /// queue on the very next line.
    var beforeFlush: (() -> Void)?

    /// Matches `DocumentStore`'s autosave debounce, so canvas edits and
    /// manuscript edits settle on the same rhythm.
    static let defaultDebounceInterval: TimeInterval = 0.75

    private let debounceInterval: TimeInterval

    init(projectRoot: URL,
         debounceInterval: TimeInterval = CanvasStore.defaultDebounceInterval) {
        self.projectRoot = projectRoot
        self.debounceInterval = debounceInterval
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

    private var sidecarURL: URL { projectRoot.appendingPathComponent(Self.sidecarRelativePath) }
    private var scrapsURL: URL { projectRoot.appendingPathComponent(Self.scrapsRelativePath) }

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
        /// The rule has one home because it is the whole point of the enum: an
        /// arrangement this build cannot read is one it must not stamp over
        /// merely because the writer looked at the canvas.
        var acceptsARepairWrite: Bool { self != .refused }
    }

    /// What a load found. **A struct rather than the pair**, so a reader cannot
    /// take the scene without the fact that it may be empty for a reason that
    /// forbids writing over it.
    struct Loaded {
        var scene: CanvasScene
        var scraps: [CanvasNodeID: String]
        var sidecar: SidecarState
    }

    func load() -> Loaded {
        // canvas.md is scrap CONTENT, not a manuscript — it never goes through
        // the op log (spec §8); this function IS its reconciler.
        let scraps = (try? String(contentsOf: scrapsURL, encoding: .utf8)) // adr-0018-ok: canvas.md scrap text, not manuscript
            .map(ScrapText.parse) ?? [:]

        // canvas.json is the derived sidecar, not a manuscript.
        guard let data = try? Data(contentsOf: sidecarURL) else { // adr-0018-ok: canvas.json derived sidecar, not manuscript
            return Loaded(scene: CanvasScene(), scraps: scraps, sidecar: .absent)
        }
        guard let dto = try? JSONDecoder().decode(CanvasSceneDTO.self, from: data),
              dto.schemaVersion <= CanvasSceneDTO.currentSchemaVersion else {
            // Corrupt, or from a newer build. An empty layout with the words
            // intact is a recoverable state; a crash is not — and the FILE is
            // left alone, because it is somebody's arrangement.
            return Loaded(scene: CanvasScene(), scraps: scraps, sidecar: .refused)
        }
        return Loaded(scene: dto.scene, scraps: scraps, sidecar: .decoded)
    }

    func save(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        pendingSave?.cancel()
        pendingSave = nil
        pendingPayload = nil
        writeNow(scene: scene, scraps: scraps)
    }

    /// Debounced — a drag emits a position per frame and must not emit a write
    /// per frame.
    func scheduleSave(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
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
