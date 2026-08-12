import AppKit
import Foundation
import MaughamCore

#if MAUGHAM_DEV_BUILD

/// `test_flush_autosave` — dev-only lifecycle tool. Forces the live doc's
/// pending burst (`flushBurstNow`) and then its debounced autosave
/// (`performAutosave`, `internal` on `Document` and reachable directly from
/// this app-target tool) to write the clean, anchor-free `.md` to disk NOW,
/// without waiting on the 750ms autosave debounce.
public enum TestFlushAutosaveTool: MCPTool {
    public struct Params: Codable { let project_id: String; let doc_id: String }
    public struct Result: Codable { public let ok: Bool; public let clean_disk_bytes: Int }
    public static let method = "test_flush_autosave"
    public static let description = "Dev-only: force the doc's pending burst + autosave to write the clean .md now (no 750ms wait)."
    public static let inputSchemaJSON = TestDumpDocumentTool.inputSchemaJSON

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(p.project_id, in: registry)
        // Safety fence: performAutosave WRITES the clean .md to disk. Require the
        // target live under TestWorkspace.root so this dev tool can never write
        // over the writer's real (also-open) manuscripts.
        try TestWorkspace.require(entry.url)
        guard let doc = entry.store.documentStore?.document(forDocId: p.doc_id) else {
            throw MCPError.invalidArgument("doc not open: \(p.doc_id)")
        }
        try await doc.flushBurstNow()
        try await doc.performAutosave()
        let bytes = MarkdownDisplayFilter.stripAnchors(doc.materialize())
        return try JSONEncoder().encode(Result(ok: true, clean_disk_bytes: bytes.utf8.count))
    }
}

/// `test_checkpoint` — dev-only lifecycle tool. Fires a project-scope ⌘S
/// checkpoint (flushing the live doc's pending burst first) via the same
/// `CheckpointCapture.run` entry point the real ⌘S handler uses.
public enum TestCheckpointTool: MCPTool {
    public struct Params: Codable { let project_id: String; let doc_id: String; let label: String? }
    public struct Result: Codable { public let label: String; public let checkpoint_count: Int }
    public static let method = "test_checkpoint"
    public static let description = "Dev-only: fire a project-scope \u{2318}S checkpoint (flushes the live doc first)."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"doc_id":{"type":"string"},"label":{"type":"string"}},"required":["project_id","doc_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(p.project_id, in: registry)
        // Safety fence: this writes a project-scope checkpoint (and flushes the
        // live doc). Require the target live under TestWorkspace.root so it can
        // never touch the writer's real projects.
        try TestWorkspace.require(entry.url)
        guard let ds = entry.store.documentStore, let doc = ds.document(forDocId: p.doc_id) else {
            throw MCPError.invalidArgument("doc not open: \(p.doc_id)")
        }
        try? await doc.flushBurstNow()
        let cp = try await CheckpointCapture.run(
            projectURL: entry.url,
            activeDocId: p.doc_id,
            allDocIds: ds.allOpenDocuments().map { $0.docId },
            device: doc.device,
            session: doc.session,
            label: p.label,
            activeDocument: doc)
        // RULING-54 lenient, reason recorded: a dev-only count over the
        // TestWorkspace fence — an unreadable device file here is a test
        // fixture problem, and the load names it in its own result type.
        let all = await CheckpointStore(projectURL: entry.url).load().checkpoints
        return try JSONEncoder().encode(Result(label: cp.label, checkpoint_count: all.count))
    }
}

/// `test_reset_workspace` — dev-only lifecycle tool. Deletes everything under
/// `TestWorkspace.root` (and recreates an empty root). `TestWorkspace.reset()`
/// itself is fenced to only ever touch paths under the root, so this can never
/// reach the writer's real manuscripts.
public enum TestResetWorkspaceTool: MCPTool {
    public struct Result: Codable { public let ok: Bool }
    public static let method = "test_reset_workspace"
    public static let description = "Dev-only: delete everything under the test workspace root (only paths under the root)."
    public static let inputSchemaJSON = #"{"type":"object","properties":{}}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        try TestWorkspace.reset()
        return try JSONEncoder().encode(Result(ok: true))
    }
}

/// `test_quit` — dev-only lifecycle tool. Acks immediately, then flushes every
/// open doc's pending burst + autosave (so the manuscript is durable) and
/// terminates the app on a short delay so this response reaches the client
/// before the socket closes. NOT unit-tested: calling `NSApp.terminate` would
/// kill the XCTest host process (`MaughamTests` runs injected into the live
/// `Maugham.app` via `BUNDLE_LOADER`/`TEST_HOST`). Verified in the manual
/// smoke instead. `TestMCPCatalogConsistencyTests.test_allTestTools_areDispatchable`
/// explicitly skips this tool for the same reason.
public enum TestQuitTool: MCPTool {
    public struct Result: Codable { public let terminating: Bool }
    public static let method = "test_quit"
    public static let description = "Dev-only: ack, then flush + clean-terminate the app (~100ms later). The socket close is the expected signal."
    public static let inputSchemaJSON = #"{"type":"object","properties":{}}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        // Flush every open doc so the manuscript is durable, then terminate on
        // a short delay so this response reaches the client first.
        for e in registry.list() {
            for doc in e.store.documentStore?.allOpenDocuments() ?? [] {
                try? await doc.flushBurstNow()
                try? await doc.performAutosave()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.terminate(nil)
        }
        return try JSONEncoder().encode(Result(terminating: true))
    }
}
#endif
