# MCP Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose Maugham projects to Claude Desktop via a local MCP server backed by a Unix-socket bridge, so writers can read/search projects and have Claude drop research notes — without leaving the editor.

**Architecture:** Two pieces. (1) A small `maugham-mcp` CLI inside `Maugham.app/Contents/MacOS/` is spawned by Claude Desktop as a stdio MCP transport; it forwards JSON-RPC bytes to a Unix socket and synthesizes `maugham_not_running` errors when the socket is absent. (2) An `MCPServer` actor inside the Maugham app target listens on that socket, dispatches JSON-RPC tool calls, and serves them directly from `ProjectStore` + `DocumentStore` so Claude always sees live state.

**Tech Stack:** Swift 6 / Darwin POSIX sockets (AF_UNIX) / JSON-RPC 2.0 / xcodegen / XCTest. No external SDK dependencies.

**Reference spec:** `docs/superpowers/specs/2026-05-15-mcp-foundation-design.md`

---

## File map

**Create — Maugham target:**
- `Maugham/MCP/ProjectIdentifier.swift` — deterministic `proj_*` IDs from project URLs
- `Maugham/MCP/MCPProtocol.swift` — JSON-RPC 2.0 request/response/error types
- `Maugham/MCP/MCPError.swift` — MCP-specific error codes
- `Maugham/MCP/ProjectRegistry.swift` — actor mapping `project_id` → `ProjectStore`
- `Maugham/MCP/MCPRouter.swift` — method-name dispatch (pure logic, no I/O)
- `Maugham/MCP/MCPServer.swift` — actor owning the Unix socket + connection loop
- `Maugham/MCP/Tools/ProjectTools.swift` — `list_projects`, `get_outline`, `get_metadata`
- `Maugham/MCP/Tools/DocumentTools.swift` — `read_document`, `search_text`
- `Maugham/MCP/Tools/ReferenceTools.swift` — `find_references`, `list_scenes`, `get_session_stats`
- `Maugham/MCP/Tools/AddNoteTool.swift` — `add_note(research)` write tool
- `Maugham/Views/MCPNoteBanner.swift` — transient banner for Claude-authored notes

**Create — new maugham-mcp target:**
- `maugham-mcp/main.swift` — stdio entrypoint
- `maugham-mcp/JSONRPCBridge.swift` — line-delimited JSON-RPC forwarder + error synth

**Create — tests:**
- `MaughamTests/MCP/ProjectIdentifierTests.swift`
- `MaughamTests/MCP/MCPProtocolTests.swift`
- `MaughamTests/MCP/ProjectRegistryTests.swift`
- `MaughamTests/MCP/MCPRouterTests.swift`
- `MaughamTests/MCP/MCPServerLifecycleTests.swift`
- `MaughamTests/MCP/Tools/ProjectToolsTests.swift`
- `MaughamTests/MCP/Tools/DocumentToolsTests.swift`
- `MaughamTests/MCP/Tools/ReferenceToolsTests.swift`
- `MaughamTests/MCP/Tools/AddNoteToolTests.swift`
- `MaughamTests/MCP/MCPBinaryIntegrationTests.swift`
- `MaughamTests/MCP/SetupClaudeDesktopConfigTests.swift`

**Modify:**
- `project.yml` — add `maugham-mcp` target + ensure it's bundled into Maugham.app
- `Maugham/MaughamApp.swift` — start `MCPServer` on launch; quit on terminate
- `Maugham/Models/MaughamNotifications.swift` — add `maughamMCPNoteAdded`
- `Maugham/Preferences/UserPreferences.swift` — add `mcpEnabled: Bool` (default true)
- `Maugham/Views/SettingsView.swift` (and `GeneralSettingsTab`) — add MCP toggle row
- `Maugham/Views/HelpClaudeDesktopSheet.swift` — rewrite as the three-state setup sheet
- `Maugham/Views/ProjectWindow.swift` — register project on `load`, unregister on `onDisappear`; show `MCPNoteBanner` on notification

---

## Phase 1 — Foundation types

### Task 1: `ProjectIdentifier`

**Files:**
- Create: `Maugham/MCP/ProjectIdentifier.swift`
- Test: `MaughamTests/MCP/ProjectIdentifierTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MaughamTests/MCP/ProjectIdentifierTests.swift`:

```swift
import XCTest
@testable import Maugham

final class ProjectIdentifierTests: XCTestCase {
    func test_id_isDeterministicForSamePath() {
        let url = URL(fileURLWithPath: "/Users/denver/projects/Novel1")
        XCTAssertEqual(ProjectIdentifier.id(for: url), ProjectIdentifier.id(for: url))
    }

    func test_id_differsForDifferentPaths() {
        let a = URL(fileURLWithPath: "/Users/denver/projects/Novel1")
        let b = URL(fileURLWithPath: "/Users/denver/projects/Novel2")
        XCTAssertNotEqual(ProjectIdentifier.id(for: a), ProjectIdentifier.id(for: b))
    }

    func test_id_hasExpectedPrefix() {
        let url = URL(fileURLWithPath: "/tmp/proj")
        XCTAssertTrue(ProjectIdentifier.id(for: url).hasPrefix("proj_"))
    }

    func test_id_length() {
        let url = URL(fileURLWithPath: "/tmp/proj")
        // "proj_" (5) + 40 hex chars
        XCTAssertEqual(ProjectIdentifier.id(for: url).count, 45)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
cd /Users/denver/src/Maugham
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/ProjectIdentifierTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL — `ProjectIdentifier` doesn't exist.

- [ ] **Step 3: Implement ProjectIdentifier**

Create `Maugham/MCP/ProjectIdentifier.swift`:

```swift
import Foundation
import CommonCrypto

/// Stable, deterministic identifier for a project, derived from its on-disk path.
/// Survives window-title renames; breaks if the folder is moved (acceptable since
/// the user re-opens the moved project in Maugham anyway).
public enum ProjectIdentifier {
    public static func id(for url: URL) -> String {
        let canonical = url.resolvingSymlinksInPath().path
        let data = Data(canonical.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "proj_" + hex
    }
}
```

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/ProjectIdentifierTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 4 tests, with 0 failures`.

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 520 tests, with 0 failures` (516 prior + 4 new).

```bash
git add Maugham/MCP/ProjectIdentifier.swift MaughamTests/MCP/ProjectIdentifierTests.swift
git commit -m "feat: ProjectIdentifier — deterministic proj_* IDs from project URL

SHA1 of the canonical path (resolved symlinks), prefixed with 'proj_'.
Used as the project_id surfaced to Claude via MCP. Deterministic
within a single machine; survives renames of the window title but
breaks if the project folder is moved on disk — which is fine since
re-opening in Maugham regenerates the ID.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `MCPProtocol` + `MCPError`

**Files:**
- Create: `Maugham/MCP/MCPProtocol.swift`
- Create: `Maugham/MCP/MCPError.swift`
- Test: `MaughamTests/MCP/MCPProtocolTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MaughamTests/MCP/MCPProtocolTests.swift`:

```swift
import XCTest
@testable import Maugham

final class MCPProtocolTests: XCTestCase {
    func test_request_decodes_methodAndId() throws {
        let raw = #"{"jsonrpc":"2.0","id":7,"method":"list_projects"}"#
        let req = try JSONDecoder().decode(MCPRequest.self, from: Data(raw.utf8))
        XCTAssertEqual(req.method, "list_projects")
        XCTAssertEqual(req.id, .int(7))
        XCTAssertNil(req.paramsJSON)
    }

    func test_request_decodes_stringId() throws {
        let raw = #"{"jsonrpc":"2.0","id":"abc","method":"x"}"#
        let req = try JSONDecoder().decode(MCPRequest.self, from: Data(raw.utf8))
        XCTAssertEqual(req.id, .string("abc"))
    }

    func test_request_preservesRawParams() throws {
        let raw = #"{"jsonrpc":"2.0","id":1,"method":"x","params":{"a":1}}"#
        let req = try JSONDecoder().decode(MCPRequest.self, from: Data(raw.utf8))
        XCTAssertNotNil(req.paramsJSON)
    }

    func test_successResponse_encodesResult() throws {
        let resp = MCPResponse.success(id: .int(7), resultJSON: Data("{\"ok\":true}".utf8))
        let encoded = try JSONEncoder().encode(resp)
        let json = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"jsonrpc\":\"2.0\""))
        XCTAssertTrue(json.contains("\"id\":7"))
        XCTAssertTrue(json.contains("\"result\""))
        XCTAssertFalse(json.contains("\"error\""))
    }

    func test_errorResponse_encodesError() throws {
        let resp = MCPResponse.failure(
            id: .int(7),
            code: MCPError.maughamNotRunning.code,
            message: "Maugham not running")
        let encoded = try JSONEncoder().encode(resp)
        let json = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"error\""))
        XCTAssertTrue(json.contains("-32001"))
    }

    func test_mcpError_codes() {
        XCTAssertEqual(MCPError.maughamNotRunning.code, -32001)
        XCTAssertEqual(MCPError.projectNotOpen.code, -32002)
        XCTAssertEqual(MCPError.mcpDisabled.code, -32003)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/MCPProtocolTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement MCPProtocol + MCPError**

Create `Maugham/MCP/MCPProtocol.swift`:

```swift
import Foundation

/// JSON-RPC 2.0 request id: int or string, never both.
public enum MCPRequestId: Codable, Equatable, Hashable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(
            MCPRequestId.self,
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "id must be int or string"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

/// Incoming JSON-RPC 2.0 request. params kept as raw JSON so tool handlers
/// decode their own typed shapes.
public struct MCPRequest: Codable, Equatable {
    public let jsonrpc: String
    public let id: MCPRequestId?
    public let method: String
    public let paramsJSON: Data?

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public init(jsonrpc: String = "2.0", id: MCPRequestId?, method: String, paramsJSON: Data?) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.paramsJSON = paramsJSON
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        self.id = try c.decodeIfPresent(MCPRequestId.self, forKey: .id)
        self.method = try c.decode(String.self, forKey: .method)
        if c.contains(.params) {
            // Re-encode the params value to raw bytes so handlers decode their own types.
            let any = try c.decode(AnyJSON.self, forKey: .params)
            self.paramsJSON = try JSONEncoder().encode(any)
        } else {
            self.paramsJSON = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(method, forKey: .method)
        if let raw = paramsJSON {
            let any = try JSONDecoder().decode(AnyJSON.self, from: raw)
            try c.encode(any, forKey: .params)
        }
    }
}

/// Outgoing JSON-RPC 2.0 response. result kept as raw JSON so handlers
/// encode their own typed shapes.
public struct MCPResponse: Codable, Equatable {
    public let jsonrpc: String
    public let id: MCPRequestId?
    public let resultJSON: Data?
    public let error: ErrorObject?

    public struct ErrorObject: Codable, Equatable {
        public let code: Int
        public let message: String
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public static func success(id: MCPRequestId?, resultJSON: Data) -> MCPResponse {
        MCPResponse(jsonrpc: "2.0", id: id, resultJSON: resultJSON, error: nil)
    }

    public static func failure(id: MCPRequestId?, code: Int, message: String) -> MCPResponse {
        MCPResponse(
            jsonrpc: "2.0",
            id: id,
            resultJSON: nil,
            error: ErrorObject(code: code, message: message))
    }

    public init(jsonrpc: String, id: MCPRequestId?, resultJSON: Data?, error: ErrorObject?) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.resultJSON = resultJSON
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        self.id = try c.decodeIfPresent(MCPRequestId.self, forKey: .id)
        if c.contains(.result) {
            let any = try c.decode(AnyJSON.self, forKey: .result)
            self.resultJSON = try JSONEncoder().encode(any)
        } else {
            self.resultJSON = nil
        }
        self.error = try c.decodeIfPresent(ErrorObject.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encodeIfPresent(id, forKey: .id)
        if let r = resultJSON {
            let any = try JSONDecoder().decode(AnyJSON.self, from: r)
            try c.encode(any, forKey: .result)
        }
        try c.encodeIfPresent(error, forKey: .error)
    }
}

/// Type-erased JSON for `params` and `result` round-tripping.
public enum AnyJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([AnyJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: AnyJSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
```

Create `Maugham/MCP/MCPError.swift`:

```swift
import Foundation

/// Maugham-specific MCP error codes. Plain JSON-RPC errors (-32600..-32603)
/// are returned without going through this enum.
public enum MCPError: Error, Equatable {
    case maughamNotRunning      // -32001: binary couldn't reach socket
    case projectNotOpen         // -32002: project_id not in registry
    case mcpDisabled            // -32003: user toggled off in Settings
    case invalidArgument(String)// -32602: param decoding / validation failure
    case internalError(String)  // -32603: unexpected

    public var code: Int {
        switch self {
        case .maughamNotRunning: return -32001
        case .projectNotOpen:    return -32002
        case .mcpDisabled:       return -32003
        case .invalidArgument:   return -32602
        case .internalError:     return -32603
        }
    }

    public var message: String {
        switch self {
        case .maughamNotRunning:     return "Maugham isn't running."
        case .projectNotOpen:        return "That project isn't open in Maugham."
        case .mcpDisabled:           return "Maugham's MCP connection is turned off in Settings."
        case .invalidArgument(let m):return "Invalid argument: \(m)"
        case .internalError(let m):  return "Internal error: \(m)"
        }
    }
}
```

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 526 tests, with 0 failures` (520 + 6).

```bash
git add Maugham/MCP/MCPProtocol.swift Maugham/MCP/MCPError.swift MaughamTests/MCP/MCPProtocolTests.swift
git commit -m "feat: MCP protocol types + error codes

JSON-RPC 2.0 Request/Response with raw-JSON params/result (so each
tool handler decodes its own typed shapes). MCPRequestId handles
int|string ids. AnyJSON for round-tripping arbitrary JSON values.
MCPError carries Maugham-specific codes (-32001 maugham_not_running,
-32002 project_not_open, -32003 mcp_disabled).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `MCPRouter` (method dispatch)

**Files:**
- Create: `Maugham/MCP/MCPRouter.swift`
- Test: `MaughamTests/MCP/MCPRouterTests.swift`

The router is pure logic: takes a method name + params Data + registry, returns result Data. No I/O. Tool handlers are added in later tasks; for now we register a stub method to prove dispatch works.

- [ ] **Step 1: Write the failing tests**

Create `MaughamTests/MCP/MCPRouterTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class MCPRouterTests: XCTestCase {
    func test_unknownMethod_throwsMethodNotFound() async {
        let router = await MCPRouter()
        do {
            _ = try await router.dispatch(method: "nope", paramsJSON: nil)
            XCTFail("expected throw")
        } catch let MCPRouterError.methodNotFound(method) {
            XCTAssertEqual(method, "nope")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_registeredMethod_dispatchesAndReturnsResult() async throws {
        let router = await MCPRouter()
        await router.register(method: "echo") { params in
            return params ?? Data("null".utf8)
        }
        let result = try await router.dispatch(method: "echo",
                                               paramsJSON: Data("\"hi\"".utf8))
        XCTAssertEqual(String(data: result, encoding: .utf8), "\"hi\"")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/MCPRouterTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement MCPRouter**

Create `Maugham/MCP/MCPRouter.swift`:

```swift
import Foundation

public enum MCPRouterError: Error, Equatable {
    case methodNotFound(String)
}

/// Pure dispatch: method name → registered handler. Each handler takes the
/// raw params JSON (or nil) and returns the raw result JSON. Tools register
/// themselves with the router during MCPServer initialization.
@MainActor
public final class MCPRouter {
    public typealias Handler = (Data?) async throws -> Data

    private var handlers: [String: Handler] = [:]

    public init() {}

    public func register(method: String, handler: @escaping Handler) {
        handlers[method] = handler
    }

    public func dispatch(method: String, paramsJSON: Data?) async throws -> Data {
        guard let handler = handlers[method] else {
            throw MCPRouterError.methodNotFound(method)
        }
        return try await handler(paramsJSON)
    }
}
```

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 528 tests, with 0 failures` (526 + 2).

```bash
git add Maugham/MCP/MCPRouter.swift MaughamTests/MCP/MCPRouterTests.swift
git commit -m "feat: MCPRouter — method-name dispatch

Pure logic: register(method:handler:) + dispatch(method:paramsJSON:).
Each handler is (Data?) async throws -> Data so tools own their typed
encoding/decoding. Unknown methods throw methodNotFound.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — Registry, settings, server

### Task 4: `ProjectRegistry`

**Files:**
- Create: `Maugham/MCP/ProjectRegistry.swift`
- Test: `MaughamTests/MCP/ProjectRegistryTests.swift`

In-memory map of `project_id → (ProjectStore, URL)`. ProjectWindow registers on load, unregisters on disappear.

- [ ] **Step 1: Write the failing tests**

Create `MaughamTests/MCP/ProjectRegistryTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class ProjectRegistryTests: XCTestCase {
    private func makeStore() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reg-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let item = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "Reg", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        return (tmp, store)
    }

    func test_register_lookupReturnsStore() async throws {
        let (url, store) = try await makeStore()
        let reg = ProjectRegistry()
        let id = ProjectIdentifier.id(for: url)
        reg.register(url: url, store: store)
        XCTAssertNotNil(reg.lookup(id: id))
        XCTAssertEqual(reg.lookup(id: id)?.store.manifest.title, "Reg")
    }

    func test_unregister_removesEntry() async throws {
        let (url, store) = try await makeStore()
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        reg.unregister(url: url)
        XCTAssertNil(reg.lookup(id: ProjectIdentifier.id(for: url)))
    }

    func test_list_returnsAllRegistered() async throws {
        let (u1, s1) = try await makeStore()
        let (u2, s2) = try await makeStore()
        let reg = ProjectRegistry()
        reg.register(url: u1, store: s1)
        reg.register(url: u2, store: s2)
        XCTAssertEqual(reg.list().count, 2)
    }

    func test_register_replacesPreviousByPath() async throws {
        let (url, store1) = try await makeStore()
        let reg = ProjectRegistry()
        reg.register(url: url, store: store1)
        // Same URL, simulated reload
        let store2 = try await ProjectStore.load(from: url)
        reg.register(url: url, store: store2)
        XCTAssertEqual(reg.list().count, 1)
        XCTAssertTrue(reg.lookup(id: ProjectIdentifier.id(for: url))?.store === store2)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/ProjectRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement ProjectRegistry**

Create `Maugham/MCP/ProjectRegistry.swift`:

```swift
import Foundation

@MainActor
public final class ProjectRegistry {
    public struct Entry {
        public let id: String
        public let url: URL
        public let store: ProjectStore
    }

    private var entriesById: [String: Entry] = [:]

    public init() {}

    public func register(url: URL, store: ProjectStore) {
        let id = ProjectIdentifier.id(for: url)
        entriesById[id] = Entry(id: id, url: url, store: store)
    }

    public func unregister(url: URL) {
        let id = ProjectIdentifier.id(for: url)
        entriesById.removeValue(forKey: id)
    }

    public func lookup(id: String) -> Entry? {
        entriesById[id]
    }

    public func list() -> [Entry] {
        Array(entriesById.values)
    }
}
```

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 532 tests, with 0 failures` (528 + 4).

```bash
git add Maugham/MCP/ProjectRegistry.swift MaughamTests/MCP/ProjectRegistryTests.swift
git commit -m "feat: ProjectRegistry — open projects by project_id

In-memory map. ProjectWindow registers on load() and unregisters on
onDisappear. Lookup by project_id; list() returns all currently-open
projects. Re-registering the same URL replaces the entry (handles
project reload).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `mcpEnabled` preference + Settings toggle

**Files:**
- Modify: `Maugham/Preferences/UserPreferences.swift`
- Modify: `Maugham/Views/SettingsView.swift` (specifically the `GeneralSettingsTab`)

No new tests for this task — exercised via the lifecycle tests in T6.

- [ ] **Step 1: Add `mcpEnabled` to UserPreferences**

In `Maugham/Preferences/UserPreferences.swift`:

1. Add a new private key constant alongside the others:
   ```swift
   private static let mcpEnabledKey = "maugham.mcpEnabled"
   ```

2. Add a stored property with `didSet` matching the existing pattern (after `goalIndicatorsVisible`):
   ```swift
   public var mcpEnabled: Bool {
       didSet { defaults.set(mcpEnabled, forKey: Self.mcpEnabledKey) }
   }
   ```

3. In `init(defaults:)`, add at the end:
   ```swift
   // Default ON when key is absent — first-run users get MCP enabled.
   self.mcpEnabled =
       defaults.object(forKey: Self.mcpEnabledKey) as? Bool ?? true
   ```

- [ ] **Step 2: Add toggle row in GeneralSettingsTab**

Find `GeneralSettingsTab` (likely in `Maugham/Views/SettingsView.swift` or a sibling file — grep if it's elsewhere). Add a section (or new row in an existing section) that uses `@Environment(UserPreferences.self) private var prefs` plus a Toggle bound to `prefs.mcpEnabled`. Label: "Allow Claude to connect (MCP)". Description below: "When on and Maugham is running, Claude Desktop can read your open projects and add research notes."

If `GeneralSettingsTab` doesn't yet exist as its own file, modify the inline definition at `Maugham/Views/SettingsView.swift` and place the new row there. The form pattern matches the existing toggles (typewriterScroll, goalIndicatorsVisible).

Example shape:
```swift
Toggle(isOn: Binding(
    get: { themeManager.mcpEnabled },
    set: { themeManager.mcpEnabled = $0 }
)) {
    Text("Allow Claude to connect (MCP)")
}
.help("When on and Maugham is running, Claude Desktop can read your open projects and add research notes.")
```

(The `themeManager` name is a holdover — it's actually `UserPreferences`; see the existing rows.)

- [ ] **Step 3: Build + test + commit**

```bash
cd /Users/denver/src/Maugham
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. Test count unchanged (532).

```bash
git add Maugham/Preferences/UserPreferences.swift Maugham/Views/SettingsView.swift
git commit -m "feat: mcpEnabled preference + General settings toggle

Defaults to ON. Reads/writes through UserDefaults via UserPreferences,
same pattern as other prefs. GeneralSettingsTab gains a row 'Allow
Claude to connect (MCP)' with help text.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `MCPServer` actor (Unix socket lifecycle)

**Files:**
- Create: `Maugham/MCP/MCPServer.swift`
- Test: `MaughamTests/MCP/MCPServerLifecycleTests.swift`

POSIX AF_UNIX socket. Server binds in `start()`, unlinks on `stop()`, accepts connections in a Task, reads line-delimited JSON-RPC, dispatches via MCPRouter, writes response.

- [ ] **Step 1: Write the failing tests**

Create `MaughamTests/MCP/MCPServerLifecycleTests.swift`:

```swift
import XCTest
import Foundation
import Darwin
@testable import Maugham

@MainActor
final class MCPServerLifecycleTests: XCTestCase {
    private func tmpSocketPath() -> String {
        // Unix socket paths capped at 104 chars on Darwin; tmp + short uuid.
        let id = UUID().uuidString.prefix(8)
        return "/tmp/mcp-\(id).sock"
    }

    func test_start_bindsSocket() async throws {
        let path = tmpSocketPath()
        let router = MCPRouter()
        let prefs = UserPreferences(defaults: ephemeralDefaults())
        let server = MCPServer(socketPath: path, router: router, preferences: prefs)
        try await server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func test_request_dispatchesViaRouter() async throws {
        let path = tmpSocketPath()
        let router = MCPRouter()
        router.register(method: "ping") { _ in Data("\"pong\"".utf8) }
        let prefs = UserPreferences(defaults: ephemeralDefaults())
        let server = MCPServer(socketPath: path, router: router, preferences: prefs)
        try await server.start()
        defer { Task { await server.stop() } }

        let req = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let resp = try await sendAndReceive(socketPath: path, request: req)
        XCTAssertTrue(resp.contains("\"result\":\"pong\""))
    }

    func test_request_whenDisabled_returnsMCPDisabled() async throws {
        let path = tmpSocketPath()
        let router = MCPRouter()
        router.register(method: "ping") { _ in Data("\"pong\"".utf8) }
        let prefs = UserPreferences(defaults: ephemeralDefaults())
        prefs.mcpEnabled = false
        let server = MCPServer(socketPath: path, router: router, preferences: prefs)
        try await server.start()
        defer { Task { await server.stop() } }

        let req = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let resp = try await sendAndReceive(socketPath: path, request: req)
        XCTAssertTrue(resp.contains("-32003"))
        XCTAssertFalse(resp.contains("\"result\""))
    }

    // MARK: helpers

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "mcp-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    /// Connect to a Unix socket, write `request` + newline, read until newline.
    private func sendAndReceive(socketPath: String, request: String) async throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertTrue(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strlcpy(
                    UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self),
                    src,
                    MemoryLayout.size(ofValue: dst.pointee))
            }
        }
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connectResult, 0, "connect failed: \(String(cString: strerror(errno)))")

        // Send request + newline
        var line = request + "\n"
        _ = line.withUTF8 { ptr in
            send(fd, ptr.baseAddress, ptr.count, 0)
        }
        // Read response (up to 64KB; loop if needed in real impl)
        var buf = [UInt8](repeating: 0, count: 65_536)
        let n = recv(fd, &buf, buf.count, 0)
        XCTAssertTrue(n > 0)
        return String(bytes: buf.prefix(Int(n)), encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/MCPServerLifecycleTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement MCPServer**

Create `Maugham/MCP/MCPServer.swift`:

```swift
import Foundation
import Darwin

/// MCPServer owns one AF_UNIX listening socket and runs an accept loop. Each
/// accepted connection reads line-delimited JSON-RPC requests, dispatches via
/// MCPRouter, and writes responses back. Disabled preference short-circuits
/// every request with mcp_disabled (-32003).
@MainActor
public final class MCPServer {
    private let socketPath: String
    private let router: MCPRouter
    private let preferences: UserPreferences
    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    public init(socketPath: String, router: MCPRouter, preferences: UserPreferences) {
        self.socketPath = socketPath
        self.router = router
        self.preferences = preferences
    }

    public func start() async throws {
        // Ensure parent dir exists
        let parent = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true)
        // Remove stale socket
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MCPServerStartError.socketCreateFailed(errno)
        }
        listenFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strlcpy(
                    UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self),
                    src,
                    MemoryLayout.size(ofValue: dst.pointee))
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            listenFD = -1
            throw MCPServerStartError.bindFailed(errno)
        }
        guard listen(fd, 5) == 0 else {
            close(fd)
            listenFD = -1
            throw MCPServerStartError.listenFailed(errno)
        }

        let listenFDCopy = fd
        let routerRef = router
        let prefsRef = preferences
        acceptTask = Task.detached(priority: .background) {
            await Self.acceptLoop(listenFD: listenFDCopy, router: routerRef, preferences: prefsRef)
        }
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    private static func acceptLoop(
        listenFD: Int32, router: MCPRouter, preferences: UserPreferences
    ) async {
        while !Task.isCancelled {
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(listenFD, &clientAddr, &len)
            if clientFD < 0 {
                if errno == EBADF || errno == EINVAL { break }  // listener closed
                continue
            }
            // Handle each connection on its own Task. MainActor hop happens
            // inside handleConnection because router + preferences are MA-isolated.
            Task.detached(priority: .background) {
                await Self.handleConnection(
                    clientFD: clientFD, router: router, preferences: preferences)
                close(clientFD)
            }
        }
    }

    private static func handleConnection(
        clientFD: Int32, router: MCPRouter, preferences: UserPreferences
    ) async {
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while !Task.isCancelled {
            let n = recv(clientFD, &buf, buf.count, 0)
            if n <= 0 { return }
            pending.append(buf, count: Int(n))
            // Process complete lines
            while let newlineIdx = pending.firstIndex(of: 0x0A) {
                let lineData = pending[..<newlineIdx]
                pending.removeSubrange(...newlineIdx)
                let response = await Self.dispatch(
                    lineData: Data(lineData),
                    router: router,
                    preferences: preferences)
                var out = response
                out.append(0x0A)
                _ = out.withUnsafeBytes { send(clientFD, $0.baseAddress, out.count, 0) }
            }
        }
    }

    private static func dispatch(
        lineData: Data, router: MCPRouter, preferences: UserPreferences
    ) async -> Data {
        let req: MCPRequest
        do {
            req = try JSONDecoder().decode(MCPRequest.self, from: lineData)
        } catch {
            // Parse error: id is unknown; return -32700 with null id
            let resp = MCPResponse.failure(id: nil, code: -32700, message: "Parse error")
            return (try? JSONEncoder().encode(resp)) ?? Data()
        }

        // Check disabled gate
        let enabled = await MainActor.run { preferences.mcpEnabled }
        if !enabled {
            let resp = MCPResponse.failure(
                id: req.id,
                code: MCPError.mcpDisabled.code,
                message: MCPError.mcpDisabled.message)
            return (try? JSONEncoder().encode(resp)) ?? Data()
        }

        // Dispatch
        do {
            let resultJSON = try await router.dispatch(
                method: req.method, paramsJSON: req.paramsJSON)
            let resp = MCPResponse.success(id: req.id, resultJSON: resultJSON)
            return (try? JSONEncoder().encode(resp)) ?? Data()
        } catch let MCPRouterError.methodNotFound(method) {
            let resp = MCPResponse.failure(
                id: req.id, code: -32601, message: "Method not found: \(method)")
            return (try? JSONEncoder().encode(resp)) ?? Data()
        } catch let e as MCPError {
            let resp = MCPResponse.failure(
                id: req.id, code: e.code, message: e.message)
            return (try? JSONEncoder().encode(resp)) ?? Data()
        } catch {
            let resp = MCPResponse.failure(
                id: req.id, code: MCPError.internalError("").code,
                message: "Internal error: \(error.localizedDescription)")
            return (try? JSONEncoder().encode(resp)) ?? Data()
        }
    }
}

public enum MCPServerStartError: Error {
    case socketCreateFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}
```

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 535 tests, with 0 failures` (532 + 3).

```bash
git add Maugham/MCP/MCPServer.swift MaughamTests/MCP/MCPServerLifecycleTests.swift
git commit -m "feat: MCPServer — Unix socket lifecycle + JSON-RPC accept loop

POSIX AF_UNIX listener binds in start(), unlinks on stop(). Per-
connection task reads line-delimited JSON-RPC, dispatches through
MCPRouter, writes responses. Disabled preference short-circuits
every request with mcp_disabled. Method-not-found, parse errors,
and MCPError values flow through standard JSON-RPC error responses.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Read tools

Each task in this phase registers a small group of tools with MCPRouter. Tools are implemented as enum namespaces — each owns its Params/Result types and a `handle(...)` function.

### Task 7: `list_projects` + `get_metadata`

**Files:**
- Create: `Maugham/MCP/Tools/ProjectTools.swift` (initially `list_projects` + `get_metadata`; T8 adds `get_outline`)
- Test: `MaughamTests/MCP/Tools/ProjectToolsTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MaughamTests/MCP/Tools/ProjectToolsTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class ProjectToolsTests: XCTestCase {
    private func makeProject(title: String = "Demo") async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        let item = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                  path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: title, author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, try await ProjectStore.load(from: tmp))
    }

    func test_listProjects_returnsRegisteredProjects() async throws {
        let (u1, s1) = try await makeProject(title: "A")
        let (u2, s2) = try await makeProject(title: "B")
        let reg = ProjectRegistry()
        reg.register(url: u1, store: s1)
        reg.register(url: u2, store: s2)
        let json = try await ListProjectsTool.handle(paramsJSON: nil, registry: reg)
        let result = try JSONDecoder().decode([ListProjectsTool.Project].self, from: json)
        XCTAssertEqual(Set(result.map(\.title)), ["A", "B"])
        XCTAssertEqual(Set(result.map(\.id)),
                       Set([ProjectIdentifier.id(for: u1), ProjectIdentifier.id(for: u2)]))
    }

    func test_getMetadata_returnsTitleAndType() async throws {
        let (url, store) = try await makeProject(title: "Mine")
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await GetMetadataTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let meta = try JSONDecoder().decode(GetMetadataTool.Metadata.self, from: json)
        XCTAssertEqual(meta.title, "Mine")
        XCTAssertEqual(meta.type, "novel")
    }

    func test_getMetadata_unknownProject_throwsProjectNotOpen() async throws {
        let reg = ProjectRegistry()
        let req = "{\"project_id\":\"proj_deadbeef\"}"
        do {
            _ = try await GetMetadataTool.handle(
                paramsJSON: Data(req.utf8), registry: reg)
            XCTFail("expected throw")
        } catch MCPError.projectNotOpen {
            // ok
        } catch {
            XCTFail("wrong: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/ProjectToolsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement the tools**

Create `Maugham/MCP/Tools/ProjectTools.swift`:

```swift
import Foundation

/// `list_projects` — currently-open projects.
public enum ListProjectsTool {
    public struct Project: Codable, Equatable {
        public let id: String
        public let title: String
        public let type: String   // raw value of ProjectType: novel/short-story/screenplay/collection
        public let path: String
    }
    public static let method = "list_projects"

    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let list = registry.list()
        let mapped = list.map { entry in
            Project(
                id: entry.id,
                title: entry.store.manifest.title,
                type: entry.store.manifest.type.rawValue,
                path: entry.url.path)
        }
        return try JSONEncoder().encode(mapped)
    }
}

/// `get_metadata(project_id)` — project-level info.
public enum GetMetadataTool {
    public struct Params: Codable {
        public let project_id: String
    }
    public struct Metadata: Codable, Equatable {
        public let title: String
        public let type: String
        public let author: String?
        public let created: Date
        public let modified: Date
        public let total_word_target: Int?
        public let page_target: Int?
        public let tags_in_use: [String]
        public let research_count: Int
    }
    public static let method = "get_metadata"

    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try Self.decodeParams(paramsJSON)
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let m = entry.store.manifest
        let tags = Self.collectTags(in: m.structure)
        let researchCount = Self.countResearch(m.research)
        let meta = Metadata(
            title: m.title,
            type: m.type.rawValue,
            author: m.author,
            created: m.created,
            modified: m.modified,
            total_word_target: m.targets?.totalWords,
            page_target: m.targets?.pageTarget,
            tags_in_use: tags,
            research_count: researchCount)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(meta)
    }

    private static func decodeParams(_ data: Data?) throws -> Params {
        guard let data else { throw MCPError.invalidArgument("project_id required") }
        do { return try JSONDecoder().decode(Params.self, from: data) }
        catch { throw MCPError.invalidArgument("project_id required") }
    }

    private static func collectTags(in items: [StructureItem]) -> [String] {
        var seen = Set<String>()
        func walk(_ list: [StructureItem]) {
            for item in list {
                if let tags = item.tags { for t in tags { seen.insert(t) } }
                if let kids = item.children { walk(kids) }
            }
        }
        walk(items)
        return seen.sorted()
    }

    private static func countResearch(_ items: [ResearchItem]) -> Int {
        var count = 0
        func walk(_ list: [ResearchItem]) {
            for item in list {
                if item.type == .asset { count += 1 }
                if let kids = item.children { walk(kids) }
            }
        }
        walk(items)
        return count
    }
}
```

NOTE: confirm `StructureItem.tags` and `ProjectManifest.targets` exist with these names. The fixture in milestone 2c added tags; the targets field is in the manifest from 1d. If your fixture's field name differs, adjust the references (don't rename the model — that's out of scope).

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 538 tests, with 0 failures` (535 + 3).

```bash
git add Maugham/MCP/Tools/ProjectTools.swift MaughamTests/MCP/Tools/ProjectToolsTests.swift
git commit -m "feat: list_projects + get_metadata MCP tools

list_projects returns currently-open projects with id/title/type/path.
get_metadata returns project-level info (title, type, author, created,
modified, targets, tags-in-use, research_count). Unknown project_id
throws projectNotOpen.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: `get_outline` + `read_document`

**Files:**
- Modify: `Maugham/MCP/Tools/ProjectTools.swift` (add `GetOutlineTool`)
- Create: `Maugham/MCP/Tools/DocumentTools.swift` (add `ReadDocumentTool`)
- Test: `MaughamTests/MCP/Tools/DocumentToolsTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/MCP/Tools/DocumentToolsTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class DocumentToolsTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "Chapter 1\n\nFirst paragraph.\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let ch = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    func test_getOutline_returnsStructure() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await GetOutlineTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let outline = try JSONDecoder().decode(
            GetOutlineTool.Outline.self, from: json)
        XCTAssertEqual(outline.nodes.count, 1)
        XCTAssertEqual(outline.nodes[0].title, "Ch 1")
        XCTAssertEqual(outline.nodes[0].type, "document")
    }

    func test_readDocument_returnsContent() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"ch-1\"}"
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let doc = try JSONDecoder().decode(
            ReadDocumentTool.DocumentContent.self, from: json)
        XCTAssertEqual(doc.title, "Ch 1")
        XCTAssertTrue(doc.text.contains("First paragraph"))
        XCTAssertEqual(doc.mode, "prose")
    }

    func test_readDocument_missingDoc_throws() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"nope\"}"
        do {
            _ = try await ReadDocumentTool.handle(
                paramsJSON: Data(req.utf8), registry: reg)
            XCTFail()
        } catch MCPError.invalidArgument {
            // ok
        } catch {
            XCTFail("wrong: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/DocumentToolsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement the tools**

Append to `Maugham/MCP/Tools/ProjectTools.swift`:

```swift
/// `get_outline(project_id)` — hierarchical manifest.structure with metadata.
public enum GetOutlineTool {
    public struct Params: Codable { public let project_id: String }
    public struct Outline: Codable, Equatable {
        public let nodes: [Node]
    }
    public struct Node: Codable, Equatable {
        public let id: String
        public let title: String
        public let type: String     // "document" or "group"
        public let status: String?
        public let synopsis: String?
        public let word_count: Int?
        public let word_target: Int?
        public let children: [Node]?
    }
    public static let method = "get_outline"

    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let store = entry.store
        let nodes = Self.toNodes(store.manifest.structure, store: store)
        return try JSONEncoder().encode(Outline(nodes: nodes))
    }

    private static func toNodes(_ items: [StructureItem], store: ProjectStore) -> [Node] {
        items.map { item in
            Node(
                id: item.id,
                title: item.title,
                type: item.type == .document ? "document" : "group",
                status: item.status,
                synopsis: item.synopsis,
                word_count: item.type == .document ? store.cachedWordCount(for: item.id) : nil,
                word_target: item.wordTarget,
                children: item.children.map { toNodes($0, store: store) })
        }
    }
}
```

Create `Maugham/MCP/Tools/DocumentTools.swift`:

```swift
import Foundation

/// `read_document(project_id, document_id)` — current text + metadata.
public enum ReadDocumentTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
    }
    public struct DocumentContent: Codable, Equatable {
        public let id: String
        public let title: String
        public let path: String
        public let mode: String    // "prose" / "screenplay" / "fountain"
        public let text: String
        public let word_count: Int
        public let character_count: Int
        public let tags: [String]?
        public let links: [String]?
    }
    public static let method = "read_document"

    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id and document_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let store = entry.store
        guard let item = Self.findItem(id: params.document_id, in: store.manifest.structure),
              item.type == .document,
              let path = item.path else {
            throw MCPError.invalidArgument("document not found: \(params.document_id)")
        }

        // Prefer live in-memory text from DocumentStore if this doc is open.
        let text: String
        if let ds = store.documentStore,
           let live = ds.liveText(forPath: path) {
            text = live
        } else {
            let abs = entry.url.appendingPathComponent(path)
            text = (try? String(contentsOf: abs, encoding: .utf8)) ?? ""
        }

        let mode = Self.modeFor(path: path, projectType: store.manifest.type)
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let chars = text.count
        let content = DocumentContent(
            id: item.id,
            title: item.title,
            path: path,
            mode: mode,
            text: text,
            word_count: words,
            character_count: chars,
            tags: item.tags,
            links: item.links)
        return try JSONEncoder().encode(content)
    }

    private static func findItem(id: String, in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let kids = item.children, let f = findItem(id: id, in: kids) { return f }
        }
        return nil
    }

    private static func modeFor(path: String, projectType: ProjectType) -> String {
        if path.hasSuffix(".fountain") { return "fountain" }
        if projectType == .screenplay { return "screenplay" }
        return "prose"
    }
}
```

NOTE: `DocumentStore.liveText(forPath:)` may not exist with that exact name. Look for an existing accessor like `currentText` or `openDocumentText` — if it's not a public method, expose one. The contract: return the in-memory working copy if the doc is currently open in this DocumentStore, else nil.

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 541 tests, with 0 failures` (538 + 3).

```bash
git add Maugham/MCP/Tools/ProjectTools.swift Maugham/MCP/Tools/DocumentTools.swift MaughamTests/MCP/Tools/DocumentToolsTests.swift
git commit -m "feat: get_outline + read_document MCP tools

get_outline returns hierarchical structure with status/synopsis/
word counts. read_document returns title/path/mode/text/word_count
with live in-memory text preferred over disk when the doc is open
in DocumentStore.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: `search_text` + `list_scenes`

**Files:**
- Modify: `Maugham/MCP/Tools/DocumentTools.swift` (add `SearchTextTool`)
- Create: `Maugham/MCP/Tools/ReferenceTools.swift` (add `ListScenesTool`)
- Test: `MaughamTests/MCP/Tools/ReferenceToolsTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/MCP/Tools/ReferenceToolsTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class ReferenceToolsTests: XCTestCase {
    private func makeProject(type: ProjectType = .novel) async throws -> (URL, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "She walked into the kitchen. He followed.\n\nKitchen scene continued.".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let ch = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: type, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, reg)
    }

    func test_searchText_findsMatches() async throws {
        let (url, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"query\":\"kitchen\"}"
        let json = try await SearchTextTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let matches = try JSONDecoder().decode(
            [SearchTextTool.Match].self, from: json)
        XCTAssertGreaterThanOrEqual(matches.count, 2)
    }

    func test_listScenes_nonScreenplay_returnsEmpty() async throws {
        let (url, reg) = try await makeProject(type: .novel)
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListScenesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let scenes = try JSONDecoder().decode(
            [ListScenesTool.Scene].self, from: json)
        XCTAssertEqual(scenes.count, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/ReferenceToolsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement the tools**

Append to `Maugham/MCP/Tools/DocumentTools.swift`:

```swift
/// `search_text(project_id, query, options?)` — reuses ProjectSearchEngine.
public enum SearchTextTool {
    public struct Params: Codable {
        public let project_id: String
        public let query: String
        public let case_sensitive: Bool?
        public let whole_word: Bool?
    }
    public struct Match: Codable, Equatable {
        public let document_id: String
        public let document_title: String
        public let line: Int
        public let preview: String
    }
    public static let method = "search_text"

    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id and query required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let opts = SearchOptions(
            caseSensitive: params.case_sensitive ?? false,
            wholeWord: params.whole_word ?? false)
        let results = try await ProjectSearchEngine.search(
            query: params.query, options: opts, in: entry.store)
        let matches = results.matches.compactMap { m -> Match? in
            // Skip research matches for now — search_text scopes to manuscript per spec.
            guard case .manuscript = m.documentSource else { return nil }
            return Match(
                document_id: m.documentId,
                document_title: m.documentTitle,
                line: m.lineNumber,
                preview: m.linePreview)
        }
        return try JSONEncoder().encode(matches)
    }
}
```

NOTE: `ProjectSearchEngine.search`, `SearchOptions`, `SearchMatch.documentSource` were added in the find-replace milestone. Confirm method signature; adjust call shape if it takes a different parameter order. If `ProjectSearchEngine` is `struct` with a different static method name, use that.

Create `Maugham/MCP/Tools/ReferenceTools.swift`:

```swift
import Foundation

/// `list_scenes(project_id)` — screenplay-only; reuses the last parsed Fountain script.
public enum ListScenesTool {
    public struct Params: Codable { public let project_id: String }
    public struct Scene: Codable, Equatable {
        public let id: String
        public let heading: String
        public let page_start: Double
        public let page_length: Double
        public let document_id: String
    }
    public static let method = "list_scenes"

    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        guard entry.store.manifest.type == .screenplay,
              let script = entry.store.lastParsedScript else {
            return try JSONEncoder().encode([Scene]())
        }
        let scenes = script.scenes.map { s in
            Scene(
                id: s.id,
                heading: s.heading,
                page_start: s.pageStart,
                page_length: s.pageLength,
                document_id: s.documentId ?? "")
        }
        return try JSONEncoder().encode(scenes)
    }
}
```

NOTE: `ProjectStore.lastParsedScript` and `FountainScript.scenes` shape are from milestone 3c. Confirm names; if `FountainScene` has different field names (`startPage` vs `pageStart`), adjust the mapping.

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 543 tests, with 0 failures` (541 + 2).

```bash
git add Maugham/MCP/Tools/DocumentTools.swift Maugham/MCP/Tools/ReferenceTools.swift MaughamTests/MCP/Tools/ReferenceToolsTests.swift
git commit -m "feat: search_text + list_scenes MCP tools

search_text reuses ProjectSearchEngine (find-replace milestone)
with case_sensitive and whole_word options; manuscript-scoped.
list_scenes reuses lastParsedScript (milestone 3c); returns []
for non-screenplay projects.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: `find_references` + `get_session_stats`

**Files:**
- Modify: `Maugham/MCP/Tools/ReferenceTools.swift` (add both)
- Modify: `MaughamTests/MCP/Tools/ReferenceToolsTests.swift` (add tests)

- [ ] **Step 1: Add failing tests**

Append to `MaughamTests/MCP/Tools/ReferenceToolsTests.swift`:

```swift
extension ReferenceToolsTests {
    func test_findReferences_byResearchId_returnsLinkedChapters() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        try "Sarah\n".write(to: tmp.appendingPathComponent("research/sarah.md"),
                             atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let sarah = ResearchItem(
            id: "res-sarah", title: "Sarah", type: .asset, kind: .document,
            path: "research/sarah.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"target\":\"res-sarah\"}"
        let json = try await FindReferencesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let refs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self, from: json)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].from_id, "ch-1")
        XCTAssertEqual(refs[0].kind, "linked_research")
    }

    func test_getSessionStats_returnsAggregate() async throws {
        let (url, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await GetSessionStatsTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let stats = try JSONDecoder().decode(
            GetSessionStatsTool.SessionStats.self, from: json)
        XCTAssertGreaterThanOrEqual(stats.daily.count, 0)
        XCTAssertGreaterThanOrEqual(stats.total_minutes, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/ReferenceToolsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL (new tools don't exist).

- [ ] **Step 3: Implement the tools**

Append to `Maugham/MCP/Tools/ReferenceTools.swift`:

```swift
/// `find_references(project_id, target)` — wiki links + linked_research backreferences.
public enum FindReferencesTool {
    public struct Params: Codable {
        public let project_id: String
        public let target: String     // either document_id or research_id
    }
    public struct Reference: Codable, Equatable {
        public let from_id: String
        public let from_title: String
        public let kind: String       // "wiki" or "linked_research"
    }
    public static let method = "find_references"

    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id and target required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let store = entry.store

        var refs: [Reference] = []

        // Linked-research backreferences (writing-companion API)
        for chapter in Self.flatDocs(store.manifest.structure) {
            if store.linkedResearchIds(forDocumentId: chapter.id).contains(params.target) {
                refs.append(Reference(
                    from_id: chapter.id,
                    from_title: chapter.title,
                    kind: "linked_research"))
            }
        }

        // Wiki-link references: search manuscript text for [[target_title]]
        // params.target might be a document_id or research_id; resolve to title for matching.
        let titles = Self.titlesFor(id: params.target, store: store)
        if !titles.isEmpty {
            for doc in Self.flatDocs(store.manifest.structure) {
                guard let path = doc.path else { continue }
                let abs = entry.url.appendingPathComponent(path)
                guard let text = try? String(contentsOf: abs, encoding: .utf8) else { continue }
                for title in titles {
                    if text.contains("[[\(title)]]") {
                        refs.append(Reference(
                            from_id: doc.id,
                            from_title: doc.title,
                            kind: "wiki"))
                        break
                    }
                }
            }
        }

        return try JSONEncoder().encode(refs)
    }

    private static func flatDocs(_ items: [StructureItem]) -> [StructureItem] {
        var out: [StructureItem] = []
        for item in items {
            if item.type == .document { out.append(item) }
            if let kids = item.children { out.append(contentsOf: flatDocs(kids)) }
        }
        return out
    }

    private static func titlesFor(id: String, store: ProjectStore) -> [String] {
        var titles: [String] = []
        for doc in flatDocs(store.manifest.structure) where doc.id == id {
            titles.append(doc.title)
        }
        for item in store.resolveResearchLinks([id]) {
            titles.append(item.title)
        }
        return titles
    }
}

/// `get_session_stats(project_id, range?)` — session log aggregates.
public enum GetSessionStatsTool {
    public struct Params: Codable {
        public let project_id: String
        public let days: Int?    // optional; default 30
    }
    public struct DayStat: Codable, Equatable {
        public let date: String  // ISO yyyy-MM-dd
        public let words_written: Int
        public let minutes: Int
    }
    public struct SessionStats: Codable, Equatable {
        public let daily: [DayStat]
        public let total_words: Int
        public let total_minutes: Int
    }
    public static let method = "get_session_stats"

    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let days = max(1, params.days ?? 30)
        let log = (try? await entry.store.documentStore?.loadSessionLog()) ?? .empty
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withFullDate]

        var daily: [DayStat] = []
        var totalWords = 0
        var totalMinutes = 0
        for entry in log.entries where entry.date >= cutoff {
            daily.append(DayStat(
                date: isoFormatter.string(from: entry.date),
                words_written: entry.wordsWritten,
                minutes: entry.minutes))
            totalWords += entry.wordsWritten
            totalMinutes += entry.minutes
        }
        return try JSONEncoder().encode(SessionStats(
            daily: daily, total_words: totalWords, total_minutes: totalMinutes))
    }
}
```

NOTE: `SessionLog.entries` / `SessionLogEntry.wordsWritten` / `.minutes` names are from milestone 2c. Confirm and adjust if the actual field names differ.

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 545 tests, with 0 failures` (543 + 2).

```bash
git add Maugham/MCP/Tools/ReferenceTools.swift MaughamTests/MCP/Tools/ReferenceToolsTests.swift
git commit -m "feat: find_references + get_session_stats MCP tools

find_references walks linked-research backreferences (writing-
companion API) and [[wiki-link]] matches in manuscript text. Target
can be document_id or research_id. get_session_stats aggregates
SessionLog entries within a window (default 30 days), returning
per-day counts plus totals.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — Write tool + UX

### Task 11: `add_note` tool + notification

**Files:**
- Create: `Maugham/MCP/Tools/AddNoteTool.swift`
- Modify: `Maugham/Models/MaughamNotifications.swift`
- Test: `MaughamTests/MCP/Tools/AddNoteToolTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/MCP/Tools/AddNoteToolTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class AddNoteToolTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AN-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    func test_addNote_createsFileAndManifestEntry() async throws {
        let (url, store, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = """
        {"project_id":"\(id)","title":"Sarah notes","body":"# Sarah\\n\\n32 years old."}
        """
        let json = try await AddNoteTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let result = try JSONDecoder().decode(
            AddNoteTool.Result.self, from: json)
        XCTAssertEqual(result.title, "Sarah notes")
        XCTAssertEqual(store.manifest.research.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(result.path).path))
    }

    func test_addNote_postsNotification() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let exp = expectation(forNotification: .maughamMCPNoteAdded, object: nil)
        let req = "{\"project_id\":\"\(id)\",\"title\":\"x\",\"body\":\"y\"}"
        _ = try await AddNoteTool.handle(paramsJSON: Data(req.utf8), registry: reg)
        await fulfillment(of: [exp], timeout: 2)
    }

    func test_addNote_validatesParentGroup() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"title\":\"x\",\"body\":\"y\",\"parent_group_id\":\"nope\"}"
        do {
            _ = try await AddNoteTool.handle(paramsJSON: Data(req.utf8), registry: reg)
            XCTFail()
        } catch MCPError.invalidArgument {
            // ok
        } catch {
            XCTFail("wrong: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/AddNoteToolTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Add notification name**

In `Maugham/Models/MaughamNotifications.swift`, add (alongside other names):

```swift
public static let maughamMCPNoteAdded = Notification.Name("maugham.mcp.note.added")
```

- [ ] **Step 4: Implement AddNoteTool**

Create `Maugham/MCP/Tools/AddNoteTool.swift`:

```swift
import Foundation

/// `add_note(project_id, title, body, parent_group_id?)` — creates a `.document`
/// research item under `research/` and posts maughamMCPNoteAdded for the UI.
public enum AddNoteTool {
    public struct Params: Codable {
        public let project_id: String
        public let title: String
        public let body: String
        public let parent_group_id: String?
    }
    public struct Result: Codable, Equatable {
        public let id: String
        public let title: String
        public let path: String
    }
    public static let method = "add_note"

    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id, title, body required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let store = entry.store

        // Validate parent group if supplied
        if let parentId = params.parent_group_id {
            if !Self.groupExists(id: parentId, in: store.manifest.research) {
                throw MCPError.invalidArgument("parent_group_id not found: \(parentId)")
            }
        }

        // Create the note via ProjectStore's existing research-create path.
        // Method name may be addResearchNote/createResearchNote — confirm in
        // research-polish milestone. If the API takes (title, body, parent?:
        // String?) and returns the new ResearchItem, call it directly. If it
        // only accepts title + creates an empty file, call it and then write
        // the body via the documentStore path.
        let created = try await store.createMCPResearchNote(
            title: params.title,
            body: params.body,
            parentGroupId: params.parent_group_id)

        NotificationCenter.default.post(
            name: .maughamMCPNoteAdded,
            object: nil,
            userInfo: [
                "project_id": params.project_id,
                "research_id": created.id,
                "title": created.title
            ])

        let result = Result(id: created.id, title: created.title, path: created.path ?? "")
        return try JSONEncoder().encode(result)
    }

    private static func groupExists(id: String, in items: [ResearchItem]) -> Bool {
        for item in items {
            if item.id == id && item.type == .group { return true }
            if let kids = item.children, groupExists(id: id, in: kids) { return true }
        }
        return false
    }
}
```

- [ ] **Step 5: Implement `createMCPResearchNote` on ProjectStore**

Add to `Maugham/Stores/ProjectStore.swift` (near the existing research-create method — search the file for the New Text Note implementation):

```swift
/// Creates a research note from MCP. Wraps the existing research-create
/// path so slug dedup, manifest mutation, and autosave behave identically
/// to the binder's New Text Note. Returns the created ResearchItem.
public func createMCPResearchNote(
    title: String,
    body: String,
    parentGroupId: String?
) async throws -> ResearchItem {
    // The existing path likely has a method like `addResearchTextNote(title:,
    // parentId:)` that creates an empty file. We call it, then write `body`
    // to the resulting path. If the existing method already accepts a body
    // parameter, prefer that and pass body through directly.
    //
    // Pseudocode — adjust to the real signature:
    let item = try await addResearchTextNote(
        title: title, parentId: parentGroupId)
    if let path = item.path {
        let absURL = url.appendingPathComponent(path)
        try body.write(to: absURL, atomically: true, encoding: .utf8)
    }
    return item
}
```

NOTE: this is the most likely-to-need-adjustment piece in the plan. The existing research-create API may have a different name or already accept a body. Look at the research-polish milestone's "New Text Note" implementation in `ProjectStore.swift` to find the right hook. If the existing method already supports body + parent, just delegate directly with no body re-write step.

- [ ] **Step 6: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 548 tests, with 0 failures` (545 + 3).

```bash
git add Maugham/MCP/Tools/AddNoteTool.swift Maugham/Models/MaughamNotifications.swift Maugham/Stores/ProjectStore.swift MaughamTests/MCP/Tools/AddNoteToolTests.swift
git commit -m "feat: add_note MCP tool + maughamMCPNoteAdded notification

Creates a .document research item via ProjectStore's existing
research-create path so slug dedup + autosave behave identically
to New Text Note in the binder. Validates parent_group_id against
the manifest; rejects unknown groups with invalidArgument. Posts
maughamMCPNoteAdded with project_id/research_id/title so the UI
can show the notification banner.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: `MCPNoteBanner` overlay + ProjectWindow wiring

**Files:**
- Create: `Maugham/Views/MCPNoteBanner.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

No new tests — UX is exercised manually in T17 smoke.

- [ ] **Step 1: Create MCPNoteBanner**

Create `Maugham/Views/MCPNoteBanner.swift`:

```swift
import SwiftUI

/// Transient banner displayed at the top of the editor pane when Claude
/// creates a research note via MCP. Mirrors the SaveFlashOverlay glass
/// material style from milestone 1c. Auto-dismisses after 8s.
struct MCPNoteBanner: View {
    let title: String
    let count: Int          // 1 for single, >1 when multiple within 8s window
    let onShow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            Button(count > 1 ? "Show latest" : "Show", action: onShow)
                .buttonStyle(.borderless)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        .padding(12)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private var message: String {
        if count > 1 {
            return "Claude added \(count) notes to research."
        } else {
            return "Claude added \"\(title)\" to research."
        }
    }
}
```

- [ ] **Step 2: Wire into ProjectWindow**

In `Maugham/Views/ProjectWindow.swift`:

1. Add state near the other `@State` declarations:
   ```swift
   @State private var mcpBannerTitle: String?
   @State private var mcpBannerCount: Int = 0
   @State private var mcpBannerLatestId: String?
   @State private var mcpBannerDismissTask: Task<Void, Never>?
   ```

2. Add overlay alongside the existing `SaveFlashOverlay`:
   ```swift
   .overlay(alignment: .top) {
       if let title = mcpBannerTitle {
           MCPNoteBanner(
               title: title,
               count: mcpBannerCount,
               onShow: { showLatestMCPNote() },
               onDismiss: { dismissMCPBanner() }
           )
           .transition(.move(edge: .top).combined(with: .opacity))
       }
   }
   .animation(.easeInOut(duration: 0.2), value: mcpBannerTitle)
   ```

3. Add the onReceive next to the other `.onReceive` chain (inside `SessionAndNavigationModifier` if used, otherwise inline):
   ```swift
   .onReceive(NotificationCenter.default.publisher(
       for: .maughamMCPNoteAdded)) { note in
       guard let info = note.userInfo,
             let projectId = info["project_id"] as? String,
             let researchId = info["research_id"] as? String,
             let title = info["title"] as? String,
             let store, ProjectIdentifier.id(for: url) == projectId else { return }
       handleMCPNoteAdded(researchId: researchId, title: title, store: store)
   }
   ```

4. Add helpers (place near other private funcs):
   ```swift
   private func handleMCPNoteAdded(
       researchId: String, title: String, store: ProjectStore
   ) {
       mcpBannerTitle = title
       mcpBannerCount += 1
       mcpBannerLatestId = researchId
       mcpBannerDismissTask?.cancel()
       mcpBannerDismissTask = Task {
           try? await Task.sleep(for: .seconds(8))
           if !Task.isCancelled { dismissMCPBanner() }
       }
   }

   private func showLatestMCPNote() {
       guard let id = mcpBannerLatestId else { return }
       binderSegment = .research
       selectedResearchId = id
       dismissMCPBanner()
   }

   private func dismissMCPBanner() {
       mcpBannerTitle = nil
       mcpBannerCount = 0
       mcpBannerLatestId = nil
       mcpBannerDismissTask?.cancel()
       mcpBannerDismissTask = nil
   }
   ```

- [ ] **Step 3: Build + test + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. Test count unchanged (548).

```bash
git add Maugham/Views/MCPNoteBanner.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: MCPNoteBanner overlay for Claude-authored notes

Transient banner at top of editor pane mirroring SaveFlashOverlay
glass style. Title-aware single-note message; count-based multi-
note message when add_note bursts within 8s. Show jumps to the
research segment and selects the latest item. Auto-dismisses
after 8s.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5 — The maugham-mcp binary

### Task 13: New CLI target + stdio↔socket bridge

**Files:**
- Modify: `project.yml`
- Create: `maugham-mcp/main.swift`
- Create: `maugham-mcp/JSONRPCBridge.swift`
- Test: `MaughamTests/MCP/MCPBinaryIntegrationTests.swift`

The binary is a stdio↔Unix-socket relay. On start, it tries to connect to the socket path. If that succeeds, it forwards line-delimited JSON-RPC bytes both ways. If it fails (ECONNREFUSED, ENOENT, etc.), it reads incoming requests from stdin and synthesizes `-32001 maugham_not_running` responses for each.

- [ ] **Step 1: Add target to project.yml**

In `project.yml`, add a new target `maugham-mcp` under `targets:`:

```yaml
  maugham-mcp:
    type: tool
    platform: macOS
    sources:
      - path: maugham-mcp
    settings:
      base:
        PRODUCT_NAME: maugham-mcp
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        SWIFT_VERSION: "5.10"
```

Then add a Copy Files build phase to the Maugham target so the binary lands inside the .app bundle at `Maugham.app/Contents/MacOS/maugham-mcp`:

```yaml
  Maugham:
    # ...existing config
    dependencies:
      - target: maugham-mcp
        copy:
          destination: executables   # Contents/MacOS
          codeSign: false
```

Re-run xcodegen (it's invoked automatically by the build, but you can do `xcodegen generate` manually to regenerate the .pbxproj).

- [ ] **Step 2: Create the binary sources**

Create `maugham-mcp/main.swift`:

```swift
import Foundation
import Darwin

let socketPath = NSString(string: "~/Library/Application Support/Maugham/mcp.sock")
    .expandingTildeInPath

let bridge = JSONRPCBridge(socketPath: socketPath)
bridge.run()
```

Create `maugham-mcp/JSONRPCBridge.swift`:

```swift
import Foundation
import Darwin

/// Stdio↔Unix-socket relay. If the socket connects, forwards line-delimited
/// JSON-RPC bytes in both directions until either side closes. If the socket
/// is absent, reads stdin requests and synthesizes maugham_not_running
/// responses (-32001), preserving the request id when present.
final class JSONRPCBridge {
    private let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func run() {
        let fd = openSocket()
        if fd >= 0 {
            relay(socketFD: fd)
            close(fd)
        } else {
            synthesizeErrors()
        }
    }

    private func openSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strlcpy(
                    UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self),
                    src,
                    MemoryLayout.size(ofValue: dst.pointee))
            }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if r != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    private func relay(socketFD: Int32) {
        // Two threads: stdin → socket, socket → stdout. Either ends causes shutdown.
        let group = DispatchGroup()
        let stdinFD: Int32 = 0
        let stdoutFD: Int32 = 1

        group.enter()
        DispatchQueue.global().async {
            Self.pipe(from: stdinFD, to: socketFD)
            shutdown(socketFD, SHUT_WR)
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            Self.pipe(from: socketFD, to: stdoutFD)
            group.leave()
        }
        group.wait()
    }

    private static func pipe(from: Int32, to: Int32) {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(from, &buf, buf.count)
            if n <= 0 { return }
            var written = 0
            while written < Int(n) {
                let w = write(to, buf.withUnsafeBufferPointer { $0.baseAddress! + written },
                              Int(n) - written)
                if w <= 0 { return }
                written += w
            }
        }
    }

    private func synthesizeErrors() {
        // Read stdin line-by-line, return a maugham_not_running error for each.
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(0, &buf, buf.count)
            if n <= 0 { return }
            pending.append(buf, count: Int(n))
            while let newlineIdx = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newlineIdx]
                pending.removeSubrange(...newlineIdx)
                let response = Self.errorResponseFor(line: Data(line))
                _ = response.withUnsafeBytes { write(1, $0.baseAddress, response.count) }
                _ = "\n".withCString { write(1, $0, 1) }
            }
        }
    }

    private static func errorResponseFor(line: Data) -> Data {
        // Extract the id field if present.
        struct PartialRequest: Decodable { let id: AnyDecodableId? }
        struct AnyDecodableId: Decodable {
            let json: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let i = try? c.decode(Int.self) { self.json = String(i) }
                else if let s = try? c.decode(String.self) { self.json = "\"\(s)\"" }
                else { self.json = "null" }
            }
        }
        let partial = (try? JSONDecoder().decode(PartialRequest.self, from: line))
        let idLiteral = partial?.id?.json ?? "null"
        let body = """
        {"jsonrpc":"2.0","id":\(idLiteral),"error":{"code":-32001,"message":"Maugham isn't running."}}
        """
        return Data(body.utf8)
    }
}
```

- [ ] **Step 3: Write integration tests**

Create `MaughamTests/MCP/MCPBinaryIntegrationTests.swift`:

```swift
import XCTest

final class MCPBinaryIntegrationTests: XCTestCase {
    private func binaryURL() -> URL {
        // Built sibling target output. In Xcode builds, products typically land in
        // BUILT_PRODUCTS_DIR. Test bundle has access via Bundle.main.builtProductsDirURL
        // (which isn't a real API) — instead, look for the binary next to the host:
        let hostPath = Bundle.main.bundleURL.deletingLastPathComponent()
        // Test host is Maugham.app/Contents/MacOS/Maugham; the binary is at the same level.
        return hostPath.appendingPathComponent("maugham-mcp")
    }

    func test_binary_synthesizesNotRunning_whenSocketAbsent() throws {
        let bin = binaryURL()
        guard FileManager.default.fileExists(atPath: bin.path) else {
            throw XCTSkip("maugham-mcp not built in this product dir")
        }
        // Point the binary at a socket path that definitely doesn't exist.
        let process = Process()
        process.executableURL = bin
        process.environment = ["MAUGHAM_MCP_SOCKET":
            "/tmp/definitely-not-a-real-socket-\(UUID()).sock"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()
        defer { process.terminate() }

        let request = #"{"jsonrpc":"2.0","id":7,"method":"list_projects"}"# + "\n"
        inPipe.fileHandleForWriting.write(Data(request.utf8))
        // Read response
        let resp = try XCTUnwrap(
            outPipe.fileHandleForReading.read(upToCount: 4096))
        let body = String(data: resp, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("-32001"))
        XCTAssertTrue(body.contains("\"id\":7"))
        inPipe.fileHandleForWriting.closeFile()
    }
}
```

NOTE: This test depends on the binary respecting `MAUGHAM_MCP_SOCKET`. Update `main.swift` to read that env var if present:

```swift
let socketPath = ProcessInfo.processInfo.environment["MAUGHAM_MCP_SOCKET"]
    ?? NSString(string: "~/Library/Application Support/Maugham/mcp.sock")
        .expandingTildeInPath
```

- [ ] **Step 4: Build + run + commit**

```bash
cd /Users/denver/src/Maugham
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 549 tests, with 0 failures` (548 + 1).

```bash
git add project.yml maugham-mcp/main.swift maugham-mcp/JSONRPCBridge.swift MaughamTests/MCP/MCPBinaryIntegrationTests.swift
git commit -m "feat: maugham-mcp binary — stdio↔socket bridge

New Swift CLI target produces a tool binary copied into
Maugham.app/Contents/MacOS/. When the Unix socket connects, the
binary relays line-delimited JSON-RPC in both directions. When the
socket is absent, it synthesizes -32001 maugham_not_running for
each stdin line, preserving the request id. Integration test
spawns the binary and verifies the synthesis path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 6 — Set up Claude Desktop UI

### Task 14: Three-state detection + sheet shell

**Files:**
- Modify: `Maugham/Views/HelpClaudeDesktopSheet.swift` (rewrite)
- Test: `MaughamTests/MCP/SetupClaudeDesktopConfigTests.swift`

This task replaces the existing sheet's body with the new three-state UX. It uses a `ClaudeDesktopConfig` helper for parsing / detection. The Configure / Update Path / Remove actions land in Task 15.

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/MCP/SetupClaudeDesktopConfigTests.swift`:

```swift
import XCTest
@testable import Maugham

final class SetupClaudeDesktopConfigTests: XCTestCase {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CDC-\(UUID())")
    }

    func test_state_isMissing_whenFileAbsent() {
        let dir = tmp()
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/x"),
            .missing)
    }

    func test_state_isUnconfigured_whenNoMaughamEntry() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"other":{"command":"x"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/x"),
            .unconfigured)
    }

    func test_state_isConfigured_whenPathMatches() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"maugham":{"command":"/x"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/x"),
            .configured(path: "/x"))
    }

    func test_state_isStalePath_whenMaughamEntryPathDiffers() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"maugham":{"command":"/old/path/maugham-mcp"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/new/path/maugham-mcp"),
            .stalePath(currentPath: "/old/path/maugham-mcp"))
    }

    func test_state_isCorrupt_whenJSONUnparseable() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try "not json {{{".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/x"),
            .corrupt)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/SetupClaudeDesktopConfigTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement ClaudeDesktopConfig helper**

Create `Maugham/MCP/ClaudeDesktopConfig.swift`:

```swift
import Foundation

/// Detects and (in Task 15) mutates Claude Desktop's config file.
public enum ClaudeDesktopConfig {
    public enum State: Equatable {
        case missing
        case corrupt
        case unconfigured
        case stalePath(currentPath: String)
        case configured(path: String)
    }

    public static let defaultConfigURL: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Application Support/Claude/claude_desktop_config.json")
    }()

    public static func detect(configURL: URL, expectedBinary: String) -> State {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: configURL) else { return .corrupt }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { return .corrupt }
        let servers = dict["mcpServers"] as? [String: Any] ?? [:]
        guard let entry = servers["maugham"] as? [String: Any],
              let cmd = entry["command"] as? String else {
            return .unconfigured
        }
        if cmd == expectedBinary { return .configured(path: cmd) }
        return .stalePath(currentPath: cmd)
    }
}
```

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 554 tests, with 0 failures` (549 + 5).

```bash
git add Maugham/MCP/ClaudeDesktopConfig.swift MaughamTests/MCP/SetupClaudeDesktopConfigTests.swift
git commit -m "feat: ClaudeDesktopConfig.detect — state machine for setup sheet

Five states: missing (file absent), corrupt (JSON unparseable),
unconfigured (no maugham entry), stalePath (entry exists but
command differs from current bundle path), configured.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: Sheet rewrite + Configure / Update / Remove actions

**Files:**
- Modify: `Maugham/MCP/ClaudeDesktopConfig.swift` (add merge/remove)
- Modify: `Maugham/Views/HelpClaudeDesktopSheet.swift` (rewrite body)
- Modify: `MaughamTests/MCP/SetupClaudeDesktopConfigTests.swift` (add merge tests)

- [ ] **Step 1: Add merge + remove failing tests**

Append to `MaughamTests/MCP/SetupClaudeDesktopConfigTests.swift`:

```swift
extension SetupClaudeDesktopConfigTests {
    func test_merge_writesMaughamEntry_preservingOthers() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"other":{"command":"/x"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/Applications/Maugham.app/Contents/MacOS/maugham-mcp")
        let data = try Data(contentsOf: path)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        let maugham = try XCTUnwrap(servers["maugham"] as? [String: Any])
        XCTAssertEqual(maugham["command"] as? String,
                       "/Applications/Maugham.app/Contents/MacOS/maugham-mcp")
    }

    func test_merge_createsFile_whenAbsent() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try ClaudeDesktopConfig.merge(configURL: path, maughamBinary: "/x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func test_remove_deletesEntry_preservingOthers() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"maugham":{"command":"/x"},"other":{"command":"/y"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        try ClaudeDesktopConfig.removeMaughamEntry(configURL: path)
        let data = try Data(contentsOf: path)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["maugham"])
        XCTAssertNotNil(servers["other"])
    }

    func test_merge_throws_whenExistingConfigIsCorrupt() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try "not json".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/x"))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/SetupClaudeDesktopConfigTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL (new methods don't exist).

- [ ] **Step 3: Implement merge + remove**

Append to `Maugham/MCP/ClaudeDesktopConfig.swift`:

```swift
extension ClaudeDesktopConfig {
    public enum MergeError: Error {
        case existingConfigCorrupt
    }

    /// Atomically merge a `maugham` mcpServer entry into the config. Creates
    /// the file if absent. Throws if the existing file is unparseable JSON
    /// (we never overwrite content we don't understand).
    public static func merge(configURL: URL, maughamBinary: String) throws {
        let parent = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)

        var dict: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            if data.isEmpty {
                dict = [:]
            } else if let any = try? JSONSerialization.jsonObject(with: data),
                      let parsed = any as? [String: Any] {
                dict = parsed
            } else {
                throw MergeError.existingConfigCorrupt
            }
        }
        var servers = dict["mcpServers"] as? [String: Any] ?? [:]
        servers["maugham"] = ["command": maughamBinary]
        dict["mcpServers"] = servers

        let out = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmpURL = configURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try out.write(to: tmpURL, options: .atomic)
        // Atomic replace
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmpURL)
    }

    /// Remove the `maugham` entry from `mcpServers`, preserving other servers.
    public static func removeMaughamEntry(configURL: URL) throws {
        let data = try Data(contentsOf: configURL)
        guard let any = try? JSONSerialization.jsonObject(with: data),
              var dict = any as? [String: Any] else {
            throw MergeError.existingConfigCorrupt
        }
        var servers = dict["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: "maugham")
        dict["mcpServers"] = servers
        let out = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmpURL = configURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try out.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmpURL)
    }
}
```

- [ ] **Step 4: Rewrite HelpClaudeDesktopSheet**

Replace contents of `Maugham/Views/HelpClaudeDesktopSheet.swift`:

```swift
import SwiftUI
import AppKit

struct HelpClaudeDesktopSheet: View {
    let projectURL: URL?
    let projectTitle: String?
    @Environment(\.dismiss) private var dismiss

    @State private var state: ClaudeDesktopConfig.State = .missing
    @State private var showingManualSnippet: Bool = false
    @State private var errorMessage: String?
    @State private var copied: Bool = false

    private var binaryPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/maugham-mcp").path
    }

    private var configURL: URL { ClaudeDesktopConfig.defaultConfigURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch state {
            case .missing:    missingView
            case .corrupt:    corruptView
            case .unconfigured: unconfiguredView
            case .stalePath(let oldPath): stalePathView(oldPath: oldPath)
            case .configured(let path):   configuredView(path: path)
            }
            if let err = errorMessage {
                Text(err).font(.callout).foregroundStyle(.red)
            }
            if showingManualSnippet { manualSnippet }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 360)
        .onAppear { detect() }
    }

    private func detect() {
        state = ClaudeDesktopConfig.detect(
            configURL: configURL, expectedBinary: binaryPath)
    }

    // MARK: State views

    private var missingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Desktop isn't set up yet.").font(.title2).fontWeight(.semibold)
            Text("Install Claude Desktop, then come back to connect Maugham. Once connected, Claude can read your open projects and create research notes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Get Claude Desktop") {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!)
                }
                Button("Show manual setup") { showingManualSnippet.toggle() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var corruptView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Claude Desktop config can't be parsed.").font(.title2).fontWeight(.semibold)
            Text("We won't overwrite a config we don't understand. Add the snippet manually:")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            manualSnippet
            Button("Reveal Config in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([configURL])
            }
        }
    }

    private var unconfiguredView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Maugham isn't connected to Claude Desktop yet.").font(.title2).fontWeight(.semibold)
            Text("Claude will be able to:")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Label("Read your open projects, outlines, and chapters", systemImage: "book.closed")
                Label("Search across your manuscript and research", systemImage: "magnifyingglass")
                Label("Create new research notes for you", systemImage: "doc.badge.plus")
            }
            .font(.callout)
            HStack {
                Button("Configure") { runConfigure() }
                    .buttonStyle(.borderedProminent)
                Button("Show manual setup") { showingManualSnippet.toggle() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func stalePathView(oldPath: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Maugham is connected, but the path is out of date.", systemImage: "exclamationmark.triangle")
                .font(.title3).fontWeight(.semibold)
            Text("Claude Desktop is pointing at:\n\(oldPath)\n\nUpdate it to this Maugham:\n\(binaryPath)")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Update Path") { runConfigure() }
                    .buttonStyle(.borderedProminent)
                Button("Reveal Config in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([configURL])
                }
            }
        }
    }

    private func configuredView(path: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Maugham is connected to Claude Desktop.", systemImage: "checkmark.circle.fill")
                .font(.title3).fontWeight(.semibold)
                .foregroundStyle(.green)
            Text("Try asking Claude: \"What chapters are in my novel?\"")
                .foregroundStyle(.secondary)
            Text(path).font(.caption).foregroundStyle(.tertiary)
            HStack {
                Button("Reveal Config in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([configURL])
                }
                Button("Remove", role: .destructive) { runRemove() }
            }
        }
    }

    private var manualSnippet: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manual setup:").font(.callout).fontWeight(.medium)
            ScrollView {
                Text(snippetText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(4)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
            HStack {
                Button(copied ? "Copied" : "Copy snippet") { copy() }
                Spacer()
                Text("Config: \(configURL.path)")
                    .font(.caption).foregroundStyle(.secondary)
                    .truncationMode(.middle).lineLimit(1)
            }
        }
    }

    private var snippetText: String {
        """
        {
          "mcpServers": {
            "maugham": {
              "command": "\(binaryPath)"
            }
          }
        }
        """
    }

    // MARK: Actions

    private func runConfigure() {
        errorMessage = nil
        do {
            try ClaudeDesktopConfig.merge(
                configURL: configURL, maughamBinary: binaryPath)
            detect()
        } catch ClaudeDesktopConfig.MergeError.existingConfigCorrupt {
            state = .corrupt
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runRemove() {
        errorMessage = nil
        do {
            try ClaudeDesktopConfig.removeMaughamEntry(configURL: configURL)
            detect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippetText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
```

- [ ] **Step 5: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 558 tests, with 0 failures` (554 + 4).

```bash
git add Maugham/MCP/ClaudeDesktopConfig.swift Maugham/Views/HelpClaudeDesktopSheet.swift MaughamTests/MCP/SetupClaudeDesktopConfigTests.swift
git commit -m "feat: Help → Set up Claude Desktop rewrite — three-state sheet

State 1 missing: 'Get Claude Desktop' link + manual snippet fallback.
State 2 unconfigured: 'Configure' button writes config atomically,
preserving other apps' mcpServers entries; manual snippet fallback.
State 3 configured: shows path + 'Remove' / 'Reveal in Finder'.
Stale path: 'Update Path' rewrites to current bundle. Corrupt config:
never overwrites; falls back to manual snippet.

Replaces the prior npx filesystem-server recommendation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 7 — Wiring + smoke

### Task 16: MCPServer lifecycle in MaughamApp + ProjectWindow registration

**Files:**
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

The server starts on app launch, stops on terminate. ProjectWindow registers/unregisters itself with the shared `ProjectRegistry` as it loads/disappears. All tool handlers are registered with the router at startup.

- [ ] **Step 1: Wire server + registry into MaughamApp**

In `Maugham/MaughamApp.swift`, near the top of the `App` body, add:

```swift
@State private var mcpRouter = MCPRouter()
@State private var mcpRegistry = ProjectRegistry()
@State private var mcpServer: MCPServer?

private var mcpSocketPath: String {
    let lib = FileManager.default.urls(
        for: .libraryDirectory, in: .userDomainMask)[0]
    return lib.appendingPathComponent("Application Support/Maugham/mcp.sock").path
}
```

Pass `mcpRegistry` into ProjectWindow as an environment object:

```swift
WindowGroup(for: URL.self) { $url in
    if let url {
        ProjectWindow(url: url)
            .environment(mcpRegistry)
    } else {
        StartView()
    }
}
```

Add the `.task` lifecycle near other app-level setup (or use `.onAppear` if the App body's task ladder isn't already structured for this):

```swift
.task {
    // Register all tool handlers
    let reg = mcpRegistry
    mcpRouter.register(method: ListProjectsTool.method) { params in
        try await ListProjectsTool.handle(paramsJSON: params, registry: reg)
    }
    mcpRouter.register(method: GetMetadataTool.method) { params in
        try await GetMetadataTool.handle(paramsJSON: params, registry: reg)
    }
    mcpRouter.register(method: GetOutlineTool.method) { params in
        try await GetOutlineTool.handle(paramsJSON: params, registry: reg)
    }
    mcpRouter.register(method: ReadDocumentTool.method) { params in
        try await ReadDocumentTool.handle(paramsJSON: params, registry: reg)
    }
    mcpRouter.register(method: SearchTextTool.method) { params in
        try await SearchTextTool.handle(paramsJSON: params, registry: reg)
    }
    mcpRouter.register(method: ListScenesTool.method) { params in
        try await ListScenesTool.handle(paramsJSON: params, registry: reg)
    }
    mcpRouter.register(method: FindReferencesTool.method) { params in
        try await FindReferencesTool.handle(paramsJSON: params, registry: reg)
    }
    mcpRouter.register(method: GetSessionStatsTool.method) { params in
        try await GetSessionStatsTool.handle(paramsJSON: params, registry: reg)
    }
    mcpRouter.register(method: AddNoteTool.method) { params in
        try await AddNoteTool.handle(paramsJSON: params, registry: reg)
    }

    // Start the server
    let server = MCPServer(
        socketPath: mcpSocketPath,
        router: mcpRouter,
        preferences: userPreferences)
    try? await server.start()
    mcpServer = server
}
```

In the `appWillTerminate` flow (look for the existing `maughamAppWillTerminate` notification handling), call `await mcpServer?.stop()`.

- [ ] **Step 2: Register projects from ProjectWindow**

In `Maugham/Views/ProjectWindow.swift`:

1. Add an `@Environment(ProjectRegistry.self) private var mcpRegistry` declaration near the top of the struct.

2. In `load()`, after `self.store = s`, add:
   ```swift
   mcpRegistry.register(url: url, store: s)
   ```

3. In `.onDisappear`, add:
   ```swift
   mcpRegistry.unregister(url: url)
   ```

- [ ] **Step 3: Build + smoke + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. Tests still at 558.

```bash
git add Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: wire MCPServer into MaughamApp + ProjectWindow registration

Router, registry, and server live at the App level. All nine tool
handlers register with the router on launch. ProjectWindow registers
its project with the shared registry on load() and unregisters on
onDisappear. Server starts on launch, stops on terminate (or
mcpEnabled = false → server unbinds the socket).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 17: Final smoke + tag

- [ ] **Manual smoke checklist**

Open three actual Maugham projects in separate windows (or one project + two scratch projects). For each verification step, confirm in Claude Desktop:

1. **Configure flow**: `Help → Set up Claude Desktop…` → sheet shows "not connected" → click `Configure` → restart Claude Desktop → re-open sheet → shows "connected" with green checkmark.
2. **list_projects**: Ask Claude "What Maugham projects are open?" → returns all three with titles/types.
3. **get_outline**: Ask "What are the chapters in <ProjectA>?" → matches the binder.
4. **read_document**: Ask "Read me Chapter 1 of <ProjectA>." → returns content matching the editor. Type some unsaved text in Maugham → ask again → returns the new text (live in-memory).
5. **search_text**: Ask "Search for 'kitchen' across <ProjectA>." → returns line previews matching the `⌘⌥F` results.
6. **list_scenes**: For the screenplay project, ask "What scenes are in the script?" → returns headings + page positions.
7. **find_references**: Ask "Where is the research note 'Sarah' linked from?" → returns chapters with linked_research / wiki backrefs.
8. **get_metadata**: Ask "What are the metadata details of <ProjectA>?" → matches manifest.
9. **get_session_stats**: Ask "How much did I write this week?" → matches the Project Statistics window.
10. **add_note**: Ask "Add a research note titled 'Voice notes' with body 'Sarah's voice is dry and clipped.'" → banner appears at top of editor pane → click `Show` → research segment opens with the new note selected → file exists in `research/`.
11. **Settings toggle**: Turn off `Allow Claude to connect (MCP)` in Settings → ask Claude anything → response surfaces `mcp_disabled`. Turn back on → works again.
12. **Close Maugham → ask Claude something** → response surfaces `maugham_not_running`.
13. **Multiple add_note within 8s**: rapid-fire two `add_note` requests → banner shows "Claude added 2 notes to research." → `Show latest` opens the most recent.
14. **Configure → Remove**: in setup sheet, click `Remove` → re-open sheet → state is back to `unconfigured`. Restart Claude Desktop → confirms removal.
15. **Stale path detection**: edit `claude_desktop_config.json` manually to point at `/old/path/maugham-mcp` → re-open setup sheet → shows `Update Path` → click → path normalizes to current bundle.
16. **Corrupt config**: replace the config with `not json` → re-open setup sheet → corrupt-state view shows; manual snippet present; Reveal-in-Finder works; no overwrite occurs.
17. **Regression sweep**: writing-companion features (linked research, outline view, keyboard cheatsheet) all work; ⌘F, ⌘⌥F, ⌘\, ⌘S, ⌘/, ⌘⌥Z still work.

- [ ] **Final build + full test**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 558 tests, with 0 failures`.

- [ ] **Push + tag**

```bash
git checkout main
git merge --ff-only feat/milestone-mcp-foundation
git tag -a milestone-mcp-foundation -m "MCP Foundation — Group 2 milestone 1

Live-only Unix-socket bridge between Claude Desktop and Maugham:
- maugham-mcp CLI inside the app bundle forwards stdio JSON-RPC
  to a Unix socket; synthesizes maugham_not_running when Maugham
  isn't open.
- MCPServer actor in the Maugham app dispatches nine tools:
  list_projects, get_outline, read_document, search_text,
  list_scenes, find_references, get_metadata, get_session_stats,
  add_note (research only).
- Help → Set up Claude Desktop replaces prior filesystem-server
  recommendation with one-click atomic config merge + three-state
  detection UI.
- add_note triggers a non-blocking banner overlay; Settings toggle
  to disable.

~558 tests passing."
git push origin main
git push origin milestone-mcp-foundation
```

- [ ] **Update memory**

Create `~/.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_mcp_foundation.md` capturing API surface (MCPServer, MCPError codes, MCPRouter, ProjectRegistry, 9 tool namespaces, ClaudeDesktopConfig, maughamMCPNoteAdded, mcpEnabled preference), bundle/socket paths, and any carry-forwards discovered during build (Unix socket reconnect behavior, JSON-RPC framing edge cases, ProjectStore.createMCPResearchNote shape).

Add an entry to `~/.claude/projects/-Users-denver-src-Maugham/memory/MEMORY.md` index.

---

## Spec coverage check

| Spec section | Covered by task(s) |
|---|---|
| ProjectIdentifier (`proj_` + SHA1 of canonical path) | T1 |
| MCP JSON-RPC types, MCPError codes | T2 |
| MCPRouter — pure method dispatch | T3 |
| ProjectRegistry — open projects by id | T4 |
| `mcpEnabled` preference + Settings toggle | T5 |
| MCPServer actor — Unix socket lifecycle + dispatch + disabled gate | T6 |
| `list_projects`, `get_metadata` | T7 |
| `get_outline`, `read_document` (live in-memory text) | T8 |
| `search_text`, `list_scenes` | T9 |
| `find_references`, `get_session_stats` | T10 |
| `add_note(research)` + `maughamMCPNoteAdded` | T11 |
| Banner overlay + ProjectWindow integration | T12 |
| `maugham-mcp` binary target + stdio↔socket + error synthesis | T13 |
| `ClaudeDesktopConfig.detect` — five states | T14 |
| `ClaudeDesktopConfig.merge`/`removeMaughamEntry` + sheet rewrite | T15 |
| Server lifecycle in MaughamApp + ProjectWindow registration | T16 |
| Smoke + tag | T17 |
| Manuscript edit proposals (deferred) | not covered — explicit later milestone |
| Prompt templates (deferred) | not covered — explicit later milestone |
| Auth (deferred) | not covered — local stdio, no auth |
| Menu-bar status indicator (deferred) | not covered |
