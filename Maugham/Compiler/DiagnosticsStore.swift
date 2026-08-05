import Foundation
import MaughamCore

/// Per-device, per-document sidecar of compiler diagnostics: the notes the
/// last un-superseded `CompilerRun` raised against one document, on THIS
/// machine.
///
/// Derived state (mirrors `CanvasStore.load`'s contract): a missing or
/// corrupt sidecar reads as empty rather than throwing. Losing it costs
/// nothing — the next compiler run repopulates it — so there is no repair
/// path, only "start from nothing."
///
/// One file per `(docId, device)` under `.maugham/diagnostics/` (tripwire 17
/// spirit: a diagnostics run on one Mac must not collide with a run on
/// another writing the same doc). `replace` is the compiler's write: a new
/// run's diagnostics wholly supersede the previous run's for that doc — there
/// is never more than one run's worth of notes live per document.
@Observable @MainActor
final class DiagnosticsStore {
    /// Monotonic; bumped by every mutation (`load`, `replace`, `dismiss`) so
    /// an observing pane can invalidate a cached read without diffing arrays.
    private(set) var version: Int = 0

    private let projectRoot: URL
    private let device: DeviceSlug

    private struct FileContent: Codable, Equatable {
        var run: CompilerRun
        var diagnostics: [Diagnostic]
    }

    private var byDoc: [String: FileContent] = [:]

    init(projectRoot: URL, device: DeviceSlug) {
        self.projectRoot = projectRoot
        self.device = device
    }

    /// Read this device's sidecar for `docId` into memory. A missing or
    /// corrupt file clears any in-memory entry for `docId` rather than
    /// throwing — the derived-state contract.
    func load(docId: String) {
        let url = Self.sidecarURL(projectRoot: projectRoot, docId: docId, device: device)
        guard let data = try? Data(contentsOf: url), // adr-0018-ok: diagnostics sidecar, derived, not manuscript
              let content = try? Self.makeDecoder().decode(FileContent.self, from: data)
        else {
            byDoc[docId] = nil
            version += 1
            return
        }
        byDoc[docId] = content
        version += 1
    }

    /// A new run's diagnostics wholly replace the previous run's for
    /// `docId` — un-promoted notes from the prior run are dropped, not
    /// merged. Persists immediately.
    func replace(run: CompilerRun, diagnostics: [Diagnostic], docId: String) {
        let content = FileContent(run: run, diagnostics: diagnostics)
        byDoc[docId] = content
        persist(docId: docId, content: content)
        version += 1
    }

    /// The diagnostics for `docId` that are still trustworthy to show:
    /// drift notes (`anchor == nil`) always qualify; an anchored note only
    /// qualifies while its paragraph's current text still matches the text
    /// the compiler anchored it to. `currentText(paragraphId) == nil` means
    /// the paragraph is gone, which is also not live.
    func live(docId: String, currentText: (String) -> String?) -> [Diagnostic] {
        guard let content = byDoc[docId] else { return [] }
        return content.diagnostics.filter { diagnostic in
            guard let anchor = diagnostic.anchor else { return true }
            guard let text = currentText(anchor.paragraphId) else { return false }
            return text == anchor.anchorText
        }
    }

    /// Move the delta marker forward without touching this doc's notes.
    ///
    /// The empty-delta run: ops landed that changed no prose — a checkpoint, an
    /// annotation, a paragraph typed and typed back — so there is nothing to
    /// ask the compiler about, but the next run must not read them again.
    /// `replace` cannot do this: it would drop the standing notes for a run
    /// that produced none.
    ///
    /// **A doc with no run record is left alone.** The marker is a property of
    /// a run that happened, and a document nobody has ever checked has nothing
    /// to move; the empty delta on a first run means an empty document, and the
    /// next run's answer is the same either way.
    func advanceMarker(to opId: String, docId: String) {
        guard var content = byDoc[docId] else { return }
        content.run.lastOpId = opId
        byDoc[docId] = content
        persist(docId: docId, content: content)
        version += 1
    }

    /// Remove one diagnostic (the writer answered or ignored it). Persists
    /// immediately. No-op if `docId`/`id` is unknown.
    func dismiss(_ id: String, docId: String) {
        guard var content = byDoc[docId] else { return }
        content.diagnostics.removeAll { $0.id == id }
        byDoc[docId] = content
        persist(docId: docId, content: content)
        version += 1
    }

    func lastRun(docId: String) -> CompilerRun? {
        byDoc[docId]?.run
    }

    /// The delta marker: the op-log position the last run checked as of.
    func lastOpId(docId: String) -> String? {
        byDoc[docId]?.run.lastOpId
    }

    /// `.maugham/diagnostics/<docId>.<slug>.json` — per-device so two
    /// machines running the compiler against the same doc never race each
    /// other's sidecar. `.raw` is interpolated only here (tripwire 24).
    static func sidecarURL(projectRoot: URL, docId: String, device: DeviceSlug) -> URL {
        projectRoot
            .appendingPathComponent(".maugham/diagnostics")
            .appendingPathComponent("\(docId).\(device.raw).json")
    }

    private func persist(docId: String, content: FileContent) {
        let url = Self.sidecarURL(projectRoot: projectRoot, docId: docId, device: device)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(content) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
