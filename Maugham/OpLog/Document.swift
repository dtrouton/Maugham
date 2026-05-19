import Foundation
import AppKit

/// Per-manuscript canonical state. Owns its op log + pending buffer +
/// burst scheduler + autosave + conflict detection. The single
/// `displayText` property is the only observed text-state; SwiftUI body
/// re-evaluates against it, and every internal mutation path writes
/// `_displayText` exactly once at the end so updateNSView always sees a
/// consistent (textView, text) pair.
///
/// See docs/superpowers/specs/2026-05-19-document-first-class-oplog-design.md
@MainActor
@Observable
public final class Document {

    // === Public observed state ===
    public private(set) var displayText: String = ""
    public var cursorLocation: Int = 0
    public private(set) var pendingConflict: ConflictState?

    // === Internal state ===
    private let url: URL
    public let docId: String
    private let device: String
    private let session: String
    private let presenter: NSFilePresenter?
    private let opStore: OpLogStore
    private let pending: PendingBuffer
    private let burstScheduler: BurstScheduler

    private var paragraphs: [String: String]
    private var sequence: [String]
    private var lastWrittenText: String

    /// Internal autosave debounce (replaces DocumentStore.scheduleSave).
    private var autosaveScheduler: DebounceScheduler<Void>!

    private init(
        url: URL, docId: String, device: String, session: String,
        presenter: NSFilePresenter?, opStore: OpLogStore,
        pending: PendingBuffer, burstScheduler: BurstScheduler,
        paragraphs: [String: String], sequence: [String],
        lastWrittenText: String
    ) {
        self.url = url
        self.docId = docId
        self.device = device
        self.session = session
        self.presenter = presenter
        self.opStore = opStore
        self.pending = pending
        self.burstScheduler = burstScheduler
        self.paragraphs = paragraphs
        self.sequence = sequence
        self.lastWrittenText = lastWrittenText
    }

    /// Construct a Document from an on-disk manuscript file. Runs the
    /// Bootstrap migration if needed (the .md lacks inline ¶id markers
    /// or no op log exists yet). Recovers from a crashed pending buffer
    /// by folding its contents into a synthesized typing_burst op.
    public static func load(
        url: URL,
        device: String,
        session: String,
        presenter: NSFilePresenter?
    ) async throws -> Document {
        // Resolve doc-id by looking up the manifest. For tests + initial
        // setup, fall back to a deterministic id derived from the path.
        let docId = try resolveDocId(for: url)

        // projectURL is the parent of the manuscript/ folder.
        let projectURL = url.deletingLastPathComponent()
            .deletingLastPathComponent()

        // Bootstrap detection.
        let opLogPath = projectURL
            .appendingPathComponent(".maugham/ops/\(docId).jsonl")
        let logExists = FileManager.default.fileExists(atPath: opLogPath.path)
        let storedBytes = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let parsed = ParagraphParser.parse(storedBytes)
        let needsBootstrap = !logExists || parsed.allSatisfy { $0.id == nil }

        if needsBootstrap {
            _ = try await Bootstrap.run(
                projectURL: projectURL, docId: docId,
                mdURL: url, device: device, session: session)
        }

        let opStore = OpLogStore(projectURL: projectURL, presenter: presenter)
        let pending = PendingBuffer(projectURL: projectURL, docId: docId)
        try await pending.loadFromDisk()

        var ops = try await opStore.load(docId: docId)

        // Crash recovery: fold any pending changes into a real op.
        if !pending.isEmpty() {
            let recovered = Op(
                opId: ULID.generate(), docId: docId, at: Date(),
                device: device, session: session, kind: .typingBurst,
                changes: pending.snapshot())
            try await opStore.append(recovered)
            try await pending.clear()
            ops.append(recovered)
        }

        let initial = Deriver.derive(ops: ops)
        let lastWritten = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        // BurstScheduler with default thresholds.
        let burstHolder = WeakBurstHolder()
        let burst = BurstScheduler(
            idle: .seconds(30), max: .seconds(90)
        ) {
            Task { @MainActor in
                try? await burstHolder.document?.flushBurstNow()
            }
        }

        let doc = Document(
            url: url, docId: docId, device: device, session: session,
            presenter: presenter, opStore: opStore, pending: pending,
            burstScheduler: burst,
            paragraphs: initial.paragraphs, sequence: initial.sequence,
            lastWrittenText: lastWritten)
        burstHolder.document = doc

        // Initialize autosave + displayText.
        doc.autosaveScheduler = DebounceScheduler<Void>(
            delay: .milliseconds(750)
        ) { [weak doc] _ in
            try? await doc?.performAutosave()
        }
        doc.recomputeDisplayText()
        return doc
    }

    private func recomputeDisplayText() {
        var rendered = ""
        for id in sequence {
            guard let text = paragraphs[id] else { continue }
            if !rendered.isEmpty { rendered.append("\n\n") }
            rendered.append(text)
        }
        displayText = rendered
    }

    private func performAutosave() async throws {
        let bytes = materialize()
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var writeErr: Error?
        coord.coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordErr
        ) { wu in
            do {
                try bytes.data(using: .utf8)?.write(to: wu, options: .atomic)
                self.lastWrittenText = bytes
            } catch {
                writeErr = error
            }
        }
        if let coordErr { throw coordErr }
        if let writeErr { throw writeErr }
    }

    public func materialize() -> String {
        return Materializer.materialize(
            paragraphs: paragraphs, sequence: sequence)
    }

    // === Stubs to be filled in by Tasks 6-8 ===
    public func setFullText(_ text: String) {
        fatalError("setFullText: implemented in Task 6")
    }
    public func setParagraph(id: String, text: String) {
        fatalError("setParagraph: implemented in Task 6")
    }
    public func insertParagraph(after: String?, text: String) -> String {
        fatalError("insertParagraph: implemented in Task 6")
    }
    public func deleteParagraph(id: String) {
        fatalError("deleteParagraph: implemented in Task 6")
    }
    public func reorder(sequence: [String]) {
        fatalError("reorder: implemented in Task 6")
    }
    public func flushBurstNow() async throws {
        fatalError("flushBurstNow: implemented in Task 7")
    }
    public func close() async {
        fatalError("close: implemented in Task 7")
    }
    public func handleExternalDiskChange(diskMd: String) async throws {
        fatalError("handleExternalDiskChange: implemented in Task 8")
    }
    public func handleExternalLogChange() async throws {
        fatalError("handleExternalLogChange: implemented in Task 8")
    }
    public func resolveConflictKeepMine() async throws {
        fatalError("resolveConflictKeepMine: implemented in Task 8")
    }
    public func resolveConflictUseExternal() async throws {
        fatalError("resolveConflictUseExternal: implemented in Task 8")
    }
}

/// Looks up the doc-id for a manuscript path. For now resolves via the
/// manifest if available; falls back to a deterministic hash of the
/// relative path. Test helper; real lookup will use ProjectStore.
internal func resolveDocId(for url: URL) throws -> String {
    let projectURL = url.deletingLastPathComponent()
        .deletingLastPathComponent()
    let manifestURL = projectURL
        .appendingPathComponent("project.maugham.json")
    let relativePath = url.path
        .replacingOccurrences(of: projectURL.path + "/", with: "")
    if let data = try? Data(contentsOf: manifestURL) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let manifest = try? dec.decode(ProjectManifest.self, from: data),
           let item = findItemByPath(relativePath, in: manifest.structure) {
            return item.id
        }
    }
    // Fallback: deterministic id from path. Sufficient for tests.
    return "doc-\(relativePath.hashValue.magnitude)"
}

private func findItemByPath(_ path: String, in items: [StructureItem]) -> StructureItem? {
    for item in items {
        if item.path == path { return item }
        if let kids = item.children,
           let found = findItemByPath(path, in: kids) { return found }
    }
    return nil
}

/// Indirection so BurstScheduler's fire closure can reference the
/// Document without a retain cycle.
@MainActor
private final class WeakBurstHolder {
    weak var document: Document?
}
