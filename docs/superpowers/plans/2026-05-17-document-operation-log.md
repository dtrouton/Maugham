# Document Operation Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a per-document append-only operation log the source of truth for manuscript content; the `.md` file becomes a derived artifact.

**Architecture:** Per-doc append-only JSONL op logs under `.maugham/ops/`, with a project-wide `.maugham/checkpoints.jsonl` for named restore points. Each paragraph is anchored by a stable `<!-- ¶id -->` HTML comment inline in the markdown. The `.md` is re-derived from the log on every save via a paragraph-keyed last-write-wins fold. A pending buffer file at the autosave (750 ms) cadence closes the dual-cadence safety gap.

**Tech Stack:** Swift 5.10 / SwiftUI / AppKit, XCTest, NSFileCoordinator + NSFilePresenter (existing), JSONLines on disk, pure-Swift ULID generation.

**Spec:** [docs/superpowers/specs/2026-05-17-document-operation-log-design.md](../specs/2026-05-17-document-operation-log-design.md)

---

## Branch and Worktree

Before any task, the implementer creates the feature branch:

```bash
git checkout -b feat/milestone-document-operation-log
./gen.sh
```

All tasks land on this branch. Final smoke + ff-merge to main + tag on the last task.

## File Structure

### New files (Maugham target)

| Path | Responsibility |
|---|---|
| `Maugham/OpLog/ULID.swift` | Pure-Swift ULID generator (Crockford base32, 26 chars, sortable). |
| `Maugham/OpLog/OpKind.swift` | Enum of op kinds. |
| `Maugham/OpLog/Op.swift` | `Op` struct (envelope) + `ParagraphChange` + `Provenance` + Codable. |
| `Maugham/OpLog/Checkpoint.swift` | `Checkpoint` struct (project-wide) + Codable. |
| `Maugham/OpLog/ParagraphID.swift` | Mint paragraph IDs; format/parse `<!-- ¶abcd -->` markers. |
| `Maugham/OpLog/ParagraphParser.swift` | Parse markdown text into `[ParsedParagraph(id, text)]`. |
| `Maugham/OpLog/Materializer.swift` | Render `(paragraph_id → text, sequence)` back to markdown with inline IDs. |
| `Maugham/OpLog/Deriver.swift` | Fold an ordered `[Op]` into `(paragraph_id → text, sequence)`. |
| `Maugham/OpLog/OpLogStore.swift` | Load + append JSONL log; dedupe + sort by `op_id`. NSFileCoordinator-aware. |
| `Maugham/OpLog/CheckpointStore.swift` | Load + append checkpoints.jsonl; project-wide. NSFileCoordinator-aware. |
| `Maugham/OpLog/PendingBuffer.swift` | In-memory burst buffer + `.pending.jsonl` on-disk twin. |
| `Maugham/OpLog/BurstScheduler.swift` | 30s idle + 90s max-duration + force-flush. |
| `Maugham/OpLog/Bootstrap.swift` | First-open migration: parse legacy .md, mint IDs, emit bootstrap op. |
| `Maugham/OpLog/ShingleMatcher.swift` | k=4 word-shingle Jaccard for orphan recovery. |
| `Maugham/OpLog/Reconciler.swift` | Cross-Mac log merge + external-tool conflict detection. |
| `Maugham/OpLog/Restore.swift` | Build `checkpoint_restore` ops; partial-restore scoping. |
| `Maugham/Editor/RenderFilter.swift` | Strip `<!-- ¶id -->` for display; round-trip on edit. |
| `Maugham/Views/CheckpointBrowserPane.swift` | Right-pane checkpoint list + "Revert" button. |
| `Maugham/Views/CheckpointLabelPromptSheet.swift` | Shift-⌘S sheet. |
| `Maugham/Views/PartialRestorePicker.swift` | Whole-project / doc / paragraph restore-scope chooser. |
| `Maugham/Views/BootstrapNoticeSheet.swift` | One-time post-upgrade notice. |

### Modified files

| Path | Reason |
|---|---|
| `Maugham/Stores/DocumentStore.swift` | Add `recordParagraphChanges`, wire `BurstScheduler` + `PendingBuffer`, route materialization through `Materializer`. |
| `Maugham/Editor/EditorCoordinator.swift` | Apply `RenderFilter` on load + save; emit paragraph-touch signals. |
| `Maugham/Views/ProjectWindow.swift` | ⌘S handler → checkpoint; Shift-⌘S → label sheet; History segment in right pane. |
| `Maugham/Stores/ProjectFolderPresenter.swift` | Observe `.maugham/ops/<id>.jsonl` and `.maugham/checkpoints.jsonl` files. |
| `Maugham/Views/DetailPaneToggle.swift` | Add History segment (alongside Inspector / Research / Outline). |
| `Maugham/Models/MaughamNotifications.swift` | New notifications: `maughamOpLogChanged`, `maughamCheckpointAdded`. |

### New tests (MaughamTests/OpLog/ unless otherwise noted)

Mirror new core files. Plus: `CrashRecoveryTests.swift`, `CrossMacMergeTests.swift`, `EndToEndIntegrationTests.swift`.

---

## Task Plan

Tasks below are sequenced so each lands on a passing build. Subagent model annotation in `[]`: `H` = haiku (mechanical), `S` = sonnet (substantive judgment).

---

### Task 1: ULID generator [H]

**Files:**
- Create: `Maugham/OpLog/ULID.swift`
- Test: `MaughamTests/OpLog/ULIDTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/ULIDTests.swift
import XCTest
@testable import Maugham

final class ULIDTests: XCTestCase {
    func test_generate_produces26CharacterString() {
        let u = ULID.generate()
        XCTAssertEqual(u.count, 26)
    }

    func test_generate_usesCrockfordBase32Alphabet() {
        let u = ULID.generate()
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(u.allSatisfy { allowed.contains($0) },
            "ULID contained out-of-alphabet character: \(u)")
    }

    func test_generate_isSortableByCreationTime() async throws {
        let a = ULID.generate()
        try await Task.sleep(for: .milliseconds(2))
        let b = ULID.generate()
        XCTAssertLessThan(a, b, "earlier ULID should sort before later one")
    }

    func test_generate_isUniqueAcrossManyCalls() {
        let many = (0..<10_000).map { _ in ULID.generate() }
        XCTAssertEqual(Set(many).count, many.count, "no duplicates expected")
    }

    func test_timestampPrefix_decodesBackToMilliseconds() {
        let before = Date().timeIntervalSince1970 * 1000
        let u = ULID.generate()
        let after = Date().timeIntervalSince1970 * 1000
        let ms = ULID.timestampMillis(of: u)
        XCTAssertNotNil(ms)
        XCTAssertGreaterThanOrEqual(Double(ms!), before - 5)
        XCTAssertLessThanOrEqual(Double(ms!), after + 5)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/ULIDTests test 2>&1 | tail -10
```
Expected: FAIL with `cannot find 'ULID' in scope`.

- [ ] **Step 3: Implement minimal ULID**

```swift
// Maugham/OpLog/ULID.swift
import Foundation

/// Pure-Swift ULID (Universally Unique Lexicographically Sortable Identifier).
/// 26 chars, Crockford base32. First 10 chars encode the unix-millis timestamp
/// (sortable); last 16 chars encode 80 bits of randomness. See https://github.com/ulid/spec
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let alphabetIndex: [Character: Int] = {
        var d = [Character: Int]()
        for (i, c) in alphabet.enumerated() { d[c] = i }
        return d
    }()

    public static func generate() -> String {
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        let timePart = encode(millis, length: 10)
        var randomBytes = [UInt8](repeating: 0, count: 10)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let randomPart = encodeBytes(randomBytes, length: 16)
        return timePart + randomPart
    }

    public static func timestampMillis(of ulid: String) -> UInt64? {
        guard ulid.count == 26 else { return nil }
        let prefix = String(ulid.prefix(10))
        var value: UInt64 = 0
        for ch in prefix {
            guard let idx = alphabetIndex[ch] else { return nil }
            value = (value << 5) | UInt64(idx)
        }
        return value
    }

    private static func encode(_ value: UInt64, length: Int) -> String {
        var v = value
        var chars = [Character](repeating: "0", count: length)
        for i in stride(from: length - 1, through: 0, by: -1) {
            chars[i] = alphabet[Int(v & 0x1F)]
            v >>= 5
        }
        return String(chars)
    }

    private static func encodeBytes(_ bytes: [UInt8], length: Int) -> String {
        // 10 random bytes = 80 bits → 16 base32 chars exactly.
        var bits: UInt64 = 0
        var bitsHeld = 0
        var out = ""
        var byteIdx = 0
        while out.count < length {
            if bitsHeld < 5 {
                bits = (bits << 8) | UInt64(byteIdx < bytes.count ? bytes[byteIdx] : 0)
                bitsHeld += 8
                byteIdx += 1
            }
            let shift = bitsHeld - 5
            let chunk = (bits >> UInt64(shift)) & 0x1F
            out.append(alphabet[Int(chunk)])
            bits &= (1 << UInt64(shift)) - 1
            bitsHeld -= 5
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/ULIDTests test 2>&1 | tail -10
```
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Update project + commit**

```bash
./gen.sh
git add Maugham/OpLog/ULID.swift MaughamTests/OpLog/ULIDTests.swift project.yml Maugham.xcodeproj
git commit -m "feat: ULID generator for op + checkpoint ids"
```

---

### Task 2: OpKind enum + Op envelope [H]

**Files:**
- Create: `Maugham/OpLog/OpKind.swift`, `Maugham/OpLog/Op.swift`
- Test: `MaughamTests/OpLog/OpTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/OpTests.swift
import XCTest
@testable import Maugham

final class OpTests: XCTestCase {
    func test_op_codable_roundTripsTypingBurst() throws {
        let op = Op(
            opId: "01HZK7ABCDABCDABCDABCDABCD",
            docId: "doc-a3f9b2",
            at: Date(timeIntervalSince1970: 1_715_950_392.512),
            device: "macbook-pro-1",
            session: "session-1",
            kind: .typingBurst,
            changes: [
                Op.ParagraphChange(
                    paragraphId: "a3f9",
                    prior: "Old line.",
                    next: "New line."),
            ],
            sequence: ["a3f9", "b21c"],
            provenance: nil)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(op)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Op.self, from: data)
        XCTAssertEqual(back, op)
    }

    func test_op_codable_omitsOptionalSequenceAndProvenance() throws {
        let op = Op(
            opId: "01HZK7ABCDABCDABCDABCDABCD",
            docId: "doc-a3f9b2",
            at: Date(),
            device: "mac-1",
            session: "s1",
            kind: .typingBurst,
            changes: [],
            sequence: nil,
            provenance: nil)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let json = String(data: try enc.encode(op), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"sequence\""),
            "expected sequence to be omitted when nil")
        XCTAssertFalse(json.contains("\"provenance\""),
            "expected provenance to be omitted when nil")
    }

    func test_op_decodesAllKinds() throws {
        let kinds: [(String, OpKind)] = [
            ("typing_burst", .typingBurst),
            ("claude_suggestion", .claudeSuggestion),
            ("claude_accept", .claudeAccept),
            ("claude_reject", .claudeReject),
            ("external_edit", .externalEdit),
            ("checkpoint", .checkpoint),
            ("checkpoint_restore", .checkpointRestore),
            ("bootstrap", .bootstrap),
        ]
        for (str, expected) in kinds {
            let json = """
            {"op_id":"01HZK7","doc_id":"d","at":"2026-05-17T00:00:00Z","device":"m","session":"s","kind":"\(str)","changes":[]}
            """
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let op = try dec.decode(Op.self, from: Data(json.utf8))
            XCTAssertEqual(op.kind, expected, "kind \(str) didn't decode to \(expected)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/OpTests test 2>&1 | tail -10
```
Expected: FAIL with `cannot find type 'Op' in scope`.

- [ ] **Step 3: Implement Op + OpKind**

```swift
// Maugham/OpLog/OpKind.swift
import Foundation

public enum OpKind: String, Codable, Equatable, Sendable {
    case typingBurst = "typing_burst"
    case claudeSuggestion = "claude_suggestion"
    case claudeAccept = "claude_accept"
    case claudeReject = "claude_reject"
    case externalEdit = "external_edit"
    case checkpoint
    case checkpointRestore = "checkpoint_restore"
    case bootstrap
}
```

```swift
// Maugham/OpLog/Op.swift
import Foundation

/// The on-disk envelope for a single operation in a document's op log.
/// See docs/superpowers/specs/2026-05-17-document-operation-log-design.md §1.2.
public struct Op: Codable, Equatable, Sendable {
    public let opId: String
    public let docId: String
    public let at: Date
    public let device: String
    public let session: String
    public let kind: OpKind
    public let changes: [ParagraphChange]
    public let sequence: [String]?
    public let provenance: Provenance?

    public struct ParagraphChange: Codable, Equatable, Sendable {
        public let paragraphId: String
        public let prior: String?
        public let next: String

        enum CodingKeys: String, CodingKey {
            case paragraphId = "paragraph_id"
            case prior, next
        }

        public init(paragraphId: String, prior: String?, next: String) {
            self.paragraphId = paragraphId
            self.prior = prior
            self.next = next
        }
    }

    /// Kind-specific opaque blob. Stored as JSON; consumers cast as needed.
    public struct Provenance: Codable, Equatable, Sendable {
        public let sessionId: String?
        public let prompt: String?
        public let toolArgs: String?
        public let sourceCheckpoint: String?
        public let synthesisSource: String?
        public let orphanRecoveryMethod: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case prompt
            case toolArgs = "tool_args"
            case sourceCheckpoint = "source_checkpoint"
            case synthesisSource = "synthesis_source"
            case orphanRecoveryMethod = "orphan_recovery_method"
        }

        public init(
            sessionId: String? = nil, prompt: String? = nil,
            toolArgs: String? = nil, sourceCheckpoint: String? = nil,
            synthesisSource: String? = nil, orphanRecoveryMethod: String? = nil
        ) {
            self.sessionId = sessionId
            self.prompt = prompt
            self.toolArgs = toolArgs
            self.sourceCheckpoint = sourceCheckpoint
            self.synthesisSource = synthesisSource
            self.orphanRecoveryMethod = orphanRecoveryMethod
        }
    }

    enum CodingKeys: String, CodingKey {
        case opId = "op_id"
        case docId = "doc_id"
        case at, device, session, kind, changes, sequence, provenance
    }

    public init(
        opId: String, docId: String, at: Date, device: String,
        session: String, kind: OpKind, changes: [ParagraphChange],
        sequence: [String]? = nil, provenance: Provenance? = nil
    ) {
        self.opId = opId
        self.docId = docId
        self.at = at
        self.device = device
        self.session = session
        self.kind = kind
        self.changes = changes
        self.sequence = sequence
        self.provenance = provenance
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/OpTests test 2>&1 | tail -10
```
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/OpKind.swift Maugham/OpLog/Op.swift \
        MaughamTests/OpLog/OpTests.swift Maugham.xcodeproj
git commit -m "feat: Op envelope + OpKind enum with Codable"
```

---

### Task 3: Checkpoint struct [H]

**Files:**
- Create: `Maugham/OpLog/Checkpoint.swift`
- Test: `MaughamTests/OpLog/CheckpointTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/CheckpointTests.swift
import XCTest
@testable import Maugham

final class CheckpointTests: XCTestCase {
    func test_checkpoint_codable_roundTrips() throws {
        let cp = Checkpoint(
            checkpointId: "cp-01HZK",
            label: "end of draft 2",
            labelSource: .user,
            at: Date(timeIntervalSince1970: 1_715_950_400),
            device: "mac-1",
            activeDoc: "doc-a3f9b2",
            docPointers: ["doc-a3f9b2": "op-01HZK", "doc-c81e44": "op-01HZJ"],
            manuscriptWordCount: 42301)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Checkpoint.self, from: try enc.encode(cp))
        XCTAssertEqual(back, cp)
    }

    func test_checkpoint_decodesUserAndAutoLabelSource() throws {
        for str in ["user", "auto"] {
            let json = """
            {"checkpoint_id":"cp","label":"L","label_source":"\(str)","at":"2026-05-17T00:00:00Z","device":"m","active_doc":"d","doc_pointers":{},"manuscript_word_count":0}
            """
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let cp = try dec.decode(Checkpoint.self, from: Data(json.utf8))
            XCTAssertEqual(cp.labelSource.rawValue, str)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/CheckpointTests test 2>&1 | tail -10
```
Expected: FAIL.

- [ ] **Step 3: Implement Checkpoint**

```swift
// Maugham/OpLog/Checkpoint.swift
import Foundation

public struct Checkpoint: Codable, Equatable, Sendable {
    public let checkpointId: String
    public let label: String
    public let labelSource: LabelSource
    public let at: Date
    public let device: String
    public let activeDoc: String
    public let docPointers: [String: String]   // doc_id -> op_id
    public let manuscriptWordCount: Int

    public enum LabelSource: String, Codable, Sendable {
        case user, auto
    }

    enum CodingKeys: String, CodingKey {
        case checkpointId = "checkpoint_id"
        case label
        case labelSource = "label_source"
        case at, device
        case activeDoc = "active_doc"
        case docPointers = "doc_pointers"
        case manuscriptWordCount = "manuscript_word_count"
    }

    public init(
        checkpointId: String, label: String, labelSource: LabelSource,
        at: Date, device: String, activeDoc: String,
        docPointers: [String: String], manuscriptWordCount: Int
    ) {
        self.checkpointId = checkpointId
        self.label = label
        self.labelSource = labelSource
        self.at = at
        self.device = device
        self.activeDoc = activeDoc
        self.docPointers = docPointers
        self.manuscriptWordCount = manuscriptWordCount
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/Checkpoint.swift MaughamTests/OpLog/CheckpointTests.swift Maugham.xcodeproj
git commit -m "feat: Checkpoint struct + LabelSource enum"
```

---

### Task 4: ParagraphID mint + comment parser [H]

**Files:**
- Create: `Maugham/OpLog/ParagraphID.swift`
- Test: `MaughamTests/OpLog/ParagraphIDTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/ParagraphIDTests.swift
import XCTest
@testable import Maugham

final class ParagraphIDTests: XCTestCase {
    func test_mint_returnsFourLowercaseAlphanumeric() {
        let id = ParagraphID.mint()
        XCTAssertEqual(id.count, 4)
        let allowed = Set("0123456789abcdefghjkmnpqrstvwxyz")
        XCTAssertTrue(id.allSatisfy { allowed.contains($0) })
    }

    func test_mint_isUniqueAcrossManyCalls() {
        // At 4 base32 chars there are ~1M possibilities. 5k should not collide.
        let many = (0..<5_000).map { _ in ParagraphID.mint() }
        XCTAssertGreaterThan(Set(many).count, 4_990,
            "too many collisions in 5k mints (got \(Set(many).count) unique)")
    }

    func test_formatComment_producesCanonicalForm() {
        XCTAssertEqual(ParagraphID.formatComment("a3f9"), "<!-- ¶a3f9 -->")
    }

    func test_parseComment_extractsId() {
        XCTAssertEqual(ParagraphID.parseComment("<!-- ¶a3f9 -->"), "a3f9")
        XCTAssertEqual(ParagraphID.parseComment("<!--¶b21c-->"), "b21c")
        XCTAssertEqual(ParagraphID.parseComment("<!--  ¶c1ee  -->"), "c1ee")
    }

    func test_parseComment_rejectsMalformed() {
        XCTAssertNil(ParagraphID.parseComment("<!-- a3f9 -->"))       // missing ¶
        XCTAssertNil(ParagraphID.parseComment("¶a3f9"))               // bare, no <!---->
        XCTAssertNil(ParagraphID.parseComment("the brown fox"))
        XCTAssertNil(ParagraphID.parseComment("<!-- ¶ABCD -->"))      // uppercase
        XCTAssertNil(ParagraphID.parseComment("<!-- ¶abc -->"))       // too short
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement ParagraphID**

```swift
// Maugham/OpLog/ParagraphID.swift
import Foundation

public enum ParagraphID {
    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    public static func mint() -> String {
        var bytes = [UInt8](repeating: 0, count: 3)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // 24 bits of randomness → enough entropy for 4 base32 chars.
        // We only emit 4 chars (20 bits) — discard the top 4 bits.
        let raw: UInt32 = (UInt32(bytes[0]) << 16)
            | (UInt32(bytes[1]) << 8)
            | UInt32(bytes[2])
        var v = raw & 0x000F_FFFF        // mask to 20 bits
        var chars = [Character](repeating: "0", count: 4)
        for i in stride(from: 3, through: 0, by: -1) {
            chars[i] = alphabet[Int(v & 0x1F)]
            v >>= 5
        }
        return String(chars)
    }

    public static func formatComment(_ id: String) -> String {
        return "<!-- ¶\(id) -->"
    }

    /// Returns the id if `line` matches `<!--  ¶id  -->` exactly (optional
    /// surrounding whitespace inside the comment). Otherwise nil.
    public static func parseComment(_ line: String) -> String? {
        let pattern = "^<!--\\s*¶([0-9abcdefghjkmnpqrstvwxyz]{4})\\s*-->$"
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let m = regex.firstMatch(in: trimmed, range: range),
              m.numberOfRanges == 2,
              let idRange = Range(m.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[idRange])
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/ParagraphID.swift MaughamTests/OpLog/ParagraphIDTests.swift Maugham.xcodeproj
git commit -m "feat: ParagraphID mint + HTML-comment format/parse"
```

---

### Task 5: ParagraphParser — markdown → [ParsedParagraph] [S]

**Files:**
- Create: `Maugham/OpLog/ParagraphParser.swift`
- Test: `MaughamTests/OpLog/ParagraphParserTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/ParagraphParserTests.swift
import XCTest
@testable import Maugham

final class ParagraphParserTests: XCTestCase {
    func test_parse_emptyDocument_returnsEmptyArray() {
        XCTAssertEqual(ParagraphParser.parse(""), [])
    }

    func test_parse_singleParagraph_noId_assignsNilId() {
        let para = ParagraphParser.parse("The morning began with toast.")
        XCTAssertEqual(para.count, 1)
        XCTAssertNil(para[0].id)
        XCTAssertEqual(para[0].text, "The morning began with toast.")
    }

    func test_parse_idCommentAttachesToNextParagraph() {
        let md = """
        <!-- ¶a3f9 -->

        The morning began.

        <!-- ¶b21c -->

        She opened the window.
        """
        let p = ParagraphParser.parse(md)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].id, "a3f9")
        XCTAssertEqual(p[0].text, "The morning began.")
        XCTAssertEqual(p[1].id, "b21c")
        XCTAssertEqual(p[1].text, "She opened the window.")
    }

    func test_parse_blankLineSeparatedParagraphs() {
        let md = """
        First paragraph.

        Second paragraph.

        Third paragraph.
        """
        let p = ParagraphParser.parse(md)
        XCTAssertEqual(p.map(\.text),
            ["First paragraph.", "Second paragraph.", "Third paragraph."])
    }

    func test_parse_multiLineParagraphPreservesInternalNewlines() {
        let md = """
        Line one of a paragraph.
        Line two of the same paragraph.

        Second paragraph.
        """
        let p = ParagraphParser.parse(md)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].text,
            "Line one of a paragraph.\nLine two of the same paragraph.")
    }

    func test_parse_strayCommentWithoutFollowingParagraph_isIgnored() {
        let md = """
        First.

        <!-- ¶a3f9 -->
        """
        let p = ParagraphParser.parse(md)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].text, "First.")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement ParagraphParser**

```swift
// Maugham/OpLog/ParagraphParser.swift
import Foundation

public struct ParsedParagraph: Equatable, Sendable {
    public let id: String?
    public let text: String
    public init(id: String?, text: String) {
        self.id = id
        self.text = text
    }
}

public enum ParagraphParser {
    /// Split markdown text into paragraphs by blank lines. An optional
    /// `<!-- ¶id -->` comment immediately preceding a paragraph attaches
    /// its id to that paragraph. Stray comments without a following text
    /// block are discarded.
    public static func parse(_ markdown: String) -> [ParsedParagraph] {
        var result: [ParsedParagraph] = []
        var pendingId: String? = nil
        var buffer: [String] = []

        func flushParagraph() {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(ParsedParagraph(id: pendingId, text: text))
            }
            buffer.removeAll(keepingCapacity: true)
            pendingId = nil
        }

        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for line in lines {
            let s = String(line)
            if s.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }
            if let id = ParagraphID.parseComment(s) {
                // Comment lines flush any in-progress buffer and stash the id
                // for the next paragraph. Existing pendingId (from a prior
                // stray comment) is replaced.
                flushParagraph()
                pendingId = id
                continue
            }
            buffer.append(s)
        }
        flushParagraph()
        return result
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/ParagraphParser.swift MaughamTests/OpLog/ParagraphParserTests.swift Maugham.xcodeproj
git commit -m "feat: ParagraphParser for markdown → [ParsedParagraph]"
```

---

### Task 6: Materializer — (paragraph map + sequence) → markdown [H]

**Files:**
- Create: `Maugham/OpLog/Materializer.swift`
- Test: `MaughamTests/OpLog/MaterializerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/MaterializerTests.swift
import XCTest
@testable import Maugham

final class MaterializerTests: XCTestCase {
    func test_materialize_emptySequence_returnsEmptyString() {
        XCTAssertEqual(Materializer.materialize(paragraphs: [:], sequence: []), "")
    }

    func test_materialize_singleParagraph_withId_emitsCommentAndText() {
        let md = Materializer.materialize(
            paragraphs: ["a3f9": "The morning began."],
            sequence: ["a3f9"])
        XCTAssertEqual(md, "<!-- ¶a3f9 -->\n\nThe morning began.\n")
    }

    func test_materialize_multipleParagraphs_blankLineSeparated() {
        let md = Materializer.materialize(
            paragraphs: ["a3f9": "First.", "b21c": "Second."],
            sequence: ["a3f9", "b21c"])
        XCTAssertEqual(md,
            "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n")
    }

    func test_materialize_missingParagraphInMap_isSkipped() {
        let md = Materializer.materialize(
            paragraphs: ["a3f9": "Present."],
            sequence: ["a3f9", "ghost", "b21c"])
        XCTAssertEqual(md, "<!-- ¶a3f9 -->\n\nPresent.\n")
    }

    func test_roundTrip_parserMaterializerProducesSameStructure() {
        let original = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n"
        let parsed = ParagraphParser.parse(original)
        var map = [String: String]()
        var seq = [String]()
        for p in parsed {
            guard let id = p.id else { continue }
            map[id] = p.text
            seq.append(id)
        }
        let mat = Materializer.materialize(paragraphs: map, sequence: seq)
        XCTAssertEqual(mat, original)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement Materializer**

```swift
// Maugham/OpLog/Materializer.swift
import Foundation

public enum Materializer {
    /// Render the derived state back to a `.md` string. Each paragraph emits:
    ///   <!-- ¶id -->
    ///   <blank>
    ///   <text>
    /// Sequence entries missing from the paragraph map are skipped (a defensive
    /// behaviour — never expected in healthy logs, but doesn't panic if seen).
    public static func materialize(
        paragraphs: [String: String], sequence: [String]
    ) -> String {
        var out = ""
        for id in sequence {
            guard let text = paragraphs[id] else { continue }
            if !out.isEmpty { out.append("\n") }
            out.append(ParagraphID.formatComment(id))
            out.append("\n\n")
            out.append(text)
            out.append("\n")
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/Materializer.swift MaughamTests/OpLog/MaterializerTests.swift Maugham.xcodeproj
git commit -m "feat: Materializer for derived-state → markdown"
```

---

### Task 7: Deriver — [Op] → (paragraph_id → text, sequence) [S]

**Files:**
- Create: `Maugham/OpLog/Deriver.swift`
- Test: `MaughamTests/OpLog/DeriverTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/DeriverTests.swift
import XCTest
@testable import Maugham

final class DeriverTests: XCTestCase {
    private func makeOp(
        opId: String, kind: OpKind = .typingBurst,
        changes: [Op.ParagraphChange], sequence: [String]? = nil
    ) -> Op {
        return Op(
            opId: opId, docId: "doc-1", at: Date(), device: "m", session: "s",
            kind: kind, changes: changes, sequence: sequence)
    }

    func test_derive_emptyLog_returnsEmptyState() {
        let state = Deriver.derive(ops: [])
        XCTAssertEqual(state.paragraphs, [:])
        XCTAssertEqual(state.sequence, [])
    }

    func test_derive_singleBurst_populatesParagraphsAndSequence() {
        let op = makeOp(opId: "1", changes: [
            .init(paragraphId: "a", prior: nil, next: "First."),
            .init(paragraphId: "b", prior: nil, next: "Second."),
        ], sequence: ["a", "b"])
        let state = Deriver.derive(ops: [op])
        XCTAssertEqual(state.paragraphs, ["a": "First.", "b": "Second."])
        XCTAssertEqual(state.sequence, ["a", "b"])
    }

    func test_derive_lastWriteWinsPerParagraph() {
        let ops = [
            makeOp(opId: "1", changes: [.init(paragraphId: "a", prior: nil, next: "First v1")], sequence: ["a"]),
            makeOp(opId: "2", changes: [.init(paragraphId: "a", prior: "First v1", next: "First v2")]),
        ]
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.paragraphs["a"], "First v2")
    }

    func test_derive_sequenceUpdatedOnlyWhenOpCarriesSequence() {
        let ops = [
            makeOp(opId: "1", changes: [.init(paragraphId: "a", prior: nil, next: "A")], sequence: ["a"]),
            makeOp(opId: "2", changes: [.init(paragraphId: "a", prior: nil, next: "A2")]),  // no sequence
            makeOp(opId: "3", changes: [.init(paragraphId: "b", prior: nil, next: "B")], sequence: ["a", "b"]),
        ]
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.sequence, ["a", "b"])
    }

    func test_derive_walksOpsInGivenOrder() {
        // Caller is responsible for sorting; deriver respects input order.
        let ops = [
            makeOp(opId: "2", changes: [.init(paragraphId: "a", prior: nil, next: "Later")], sequence: ["a"]),
            makeOp(opId: "1", changes: [.init(paragraphId: "a", prior: nil, next: "Earlier")]),
        ]
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.paragraphs["a"], "Earlier",
            "deriver applies ops in argument order; sort happens upstream")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement Deriver**

```swift
// Maugham/OpLog/Deriver.swift
import Foundation

public enum Deriver {
    public struct DerivedState: Equatable, Sendable {
        public let paragraphs: [String: String]
        public let sequence: [String]
        public init(paragraphs: [String: String], sequence: [String]) {
            self.paragraphs = paragraphs
            self.sequence = sequence
        }
    }

    /// Fold ops in the given order into a paragraph_id → text map and the
    /// current sequence. Caller sorts by `op_id` first.
    public static func derive(ops: [Op]) -> DerivedState {
        var paragraphs: [String: String] = [:]
        var sequence: [String] = []
        for op in ops {
            for change in op.changes {
                paragraphs[change.paragraphId] = change.next
            }
            if let s = op.sequence {
                sequence = s
            }
        }
        return DerivedState(paragraphs: paragraphs, sequence: sequence)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/Deriver.swift MaughamTests/OpLog/DeriverTests.swift Maugham.xcodeproj
git commit -m "feat: Deriver folds ops into paragraph map + sequence"
```

---

### Task 8: OpLogStore — load/append JSONL with NSFileCoordinator [S]

**Files:**
- Create: `Maugham/OpLog/OpLogStore.swift`
- Test: `MaughamTests/OpLog/OpLogStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/OpLogStoreTests.swift
import XCTest
@testable import Maugham

final class OpLogStoreTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OLT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeOp(opId: String) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 0),
           device: "m", session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "a", prior: nil, next: "x")])
    }

    func test_load_missingFile_returnsEmpty() async throws {
        let store = OpLogStore(projectURL: tmp)
        let ops = try await store.load(docId: "doc-1")
        XCTAssertEqual(ops, [])
    }

    func test_appendThenLoad_returnsAppendedOp() async throws {
        let store = OpLogStore(projectURL: tmp)
        let op = makeOp(opId: "01HZK01")
        try await store.append(op)
        let loaded = try await store.load(docId: "doc-1")
        XCTAssertEqual(loaded, [op])
    }

    func test_load_sortsByOpId() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01HZK03"))
        try await store.append(makeOp(opId: "01HZK01"))
        try await store.append(makeOp(opId: "01HZK02"))
        let loaded = try await store.load(docId: "doc-1")
        XCTAssertEqual(loaded.map(\.opId), ["01HZK01", "01HZK02", "01HZK03"])
    }

    func test_load_deduplicatesByOpId() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01HZK01"))
        try await store.append(makeOp(opId: "01HZK01"))   // duplicate
        let loaded = try await store.load(docId: "doc-1")
        XCTAssertEqual(loaded.count, 1)
    }

    func test_load_dropsUnparseableTrailingLines() async throws {
        let store = OpLogStore(projectURL: tmp)
        let op = makeOp(opId: "01HZK01")
        try await store.append(op)
        // Manually append a corrupted trailing line.
        let opsDir = tmp.appendingPathComponent(".maugham/ops")
        let file = opsDir.appendingPathComponent("doc-1.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"this is\": \"truncated\n".utf8))
        try handle.close()
        let loaded = try await store.load(docId: "doc-1")
        XCTAssertEqual(loaded.count, 1, "corrupt trailing line should be dropped")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement OpLogStore**

```swift
// Maugham/OpLog/OpLogStore.swift
import Foundation

/// Per-document append-only JSONL op log. One file per document at
/// `.maugham/ops/<doc-id>.jsonl`. Coordinated via NSFileCoordinator for
/// safety under iCloud and external editors.
@MainActor
public final class OpLogStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    private func opsDir() -> URL {
        projectURL.appendingPathComponent(".maugham/ops")
    }

    private func file(for docId: String) -> URL {
        opsDir().appendingPathComponent("\(docId).jsonl")
    }

    public func load(docId: String) async throws -> [Op] {
        let url = file(for: docId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var bytes: Data?
        coord.coordinate(readingItemAt: url, options: [], error: &coordErr) { ru in
            bytes = try? Data(contentsOf: ru)
        }
        if let coordErr { throw coordErr }
        return parseAndSort(bytes: bytes ?? Data())
    }

    public func append(_ op: Op) async throws {
        try FileManager.default.createDirectory(
            at: opsDir(), withIntermediateDirectories: true)
        let url = file(for: op.docId)
        let line = try encode(op) + "\n"
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var writeErr: Error?
        coord.coordinate(writingItemAt: url, options: [], error: &coordErr) { wu in
            do {
                if FileManager.default.fileExists(atPath: wu.path) {
                    let h = try FileHandle(forWritingTo: wu)
                    try h.seekToEnd()
                    try h.write(contentsOf: Data(line.utf8))
                    try h.close()
                } else {
                    try Data(line.utf8).write(to: wu, options: .atomic)
                }
            } catch { writeErr = error }
        }
        if let coordErr { throw coordErr }
        if let writeErr { throw writeErr }
    }

    private func encode(_ op: Op) throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(op)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseAndSort(bytes: Data) -> [Op] {
        guard let text = String(data: bytes, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var seen = Set<String>()
        var ops: [Op] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let op = try? dec.decode(Op.self, from: data) else { continue }
            if seen.insert(op.opId).inserted {
                ops.append(op)
            }
        }
        return ops.sorted { $0.opId < $1.opId }
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/OpLogStore.swift MaughamTests/OpLog/OpLogStoreTests.swift Maugham.xcodeproj
git commit -m "feat: OpLogStore for per-doc JSONL append + sort/dedupe load"
```

---

### Task 9: CheckpointStore — append/load checkpoints.jsonl [H]

**Files:**
- Create: `Maugham/OpLog/CheckpointStore.swift`
- Test: `MaughamTests/OpLog/CheckpointStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/CheckpointStoreTests.swift
import XCTest
@testable import Maugham

final class CheckpointStoreTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CST-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeCheckpoint(id: String, label: String = "L") -> Checkpoint {
        Checkpoint(
            checkpointId: id, label: label, labelSource: .user,
            at: Date(timeIntervalSince1970: 0), device: "m",
            activeDoc: "doc-1", docPointers: ["doc-1": "op-1"],
            manuscriptWordCount: 42)
    }

    func test_load_missingFile_returnsEmpty() async throws {
        let s = CheckpointStore(projectURL: tmp)
        let cps = try await s.load()
        XCTAssertEqual(cps, [])
    }

    func test_appendThenLoad_returnsAppended() async throws {
        let s = CheckpointStore(projectURL: tmp)
        let cp = makeCheckpoint(id: "cp-1")
        try await s.append(cp)
        let loaded = try await s.load()
        XCTAssertEqual(loaded, [cp])
    }

    func test_load_returnsInAppendOrder() async throws {
        let s = CheckpointStore(projectURL: tmp)
        try await s.append(makeCheckpoint(id: "cp-1"))
        try await s.append(makeCheckpoint(id: "cp-2"))
        try await s.append(makeCheckpoint(id: "cp-3"))
        let loaded = try await s.load()
        XCTAssertEqual(loaded.map(\.checkpointId), ["cp-1", "cp-2", "cp-3"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement CheckpointStore**

```swift
// Maugham/OpLog/CheckpointStore.swift
import Foundation

/// Project-wide append-only JSONL of named checkpoints.
@MainActor
public final class CheckpointStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    private func file() -> URL {
        projectURL.appendingPathComponent(".maugham/checkpoints.jsonl")
    }

    public func load() async throws -> [Checkpoint] {
        let url = file()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var bytes: Data?
        coord.coordinate(readingItemAt: url, options: [], error: &coordErr) { ru in
            bytes = try? Data(contentsOf: ru)
        }
        if let coordErr { throw coordErr }
        return parse(bytes: bytes ?? Data())
    }

    public func append(_ cp: Checkpoint) async throws {
        try FileManager.default.createDirectory(
            at: file().deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let line = try encode(cp) + "\n"
        let url = file()
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var writeErr: Error?
        coord.coordinate(writingItemAt: url, options: [], error: &coordErr) { wu in
            do {
                if FileManager.default.fileExists(atPath: wu.path) {
                    let h = try FileHandle(forWritingTo: wu)
                    try h.seekToEnd()
                    try h.write(contentsOf: Data(line.utf8))
                    try h.close()
                } else {
                    try Data(line.utf8).write(to: wu, options: .atomic)
                }
            } catch { writeErr = error }
        }
        if let coordErr { throw coordErr }
        if let writeErr { throw writeErr }
    }

    private func encode(_ cp: Checkpoint) throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return String(data: try enc.encode(cp), encoding: .utf8) ?? ""
    }

    private func parse(bytes: Data) -> [Checkpoint] {
        guard let text = String(data: bytes, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [Checkpoint] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let d = String(line).data(using: .utf8),
                  let cp = try? dec.decode(Checkpoint.self, from: d) else { continue }
            out.append(cp)
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/CheckpointStore.swift MaughamTests/OpLog/CheckpointStoreTests.swift Maugham.xcodeproj
git commit -m "feat: CheckpointStore for project-wide checkpoints.jsonl"
```

---

### Task 10: PendingBuffer — in-memory + .pending.jsonl twin [S]

**Files:**
- Create: `Maugham/OpLog/PendingBuffer.swift`
- Test: `MaughamTests/OpLog/PendingBufferTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/PendingBufferTests.swift
import XCTest
@testable import Maugham

final class PendingBufferTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PBT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_recordChange_thenSnapshot_returnsRecorded() {
        let buf = PendingBuffer(projectURL: tmp, docId: "d")
        buf.recordChange(paragraphId: "a", prior: nil, next: "Hello.")
        XCTAssertEqual(buf.snapshot().map(\.paragraphId), ["a"])
    }

    func test_recordChange_multipleSamePid_keepsLatest() {
        let buf = PendingBuffer(projectURL: tmp, docId: "d")
        buf.recordChange(paragraphId: "a", prior: nil, next: "v1")
        buf.recordChange(paragraphId: "a", prior: "v1", next: "v2")
        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].next, "v2")
    }

    func test_flushToDisk_writesPendingJsonl() async throws {
        let buf = PendingBuffer(projectURL: tmp, docId: "d")
        buf.recordChange(paragraphId: "a", prior: nil, next: "Hello.")
        try await buf.flushToDisk()
        let url = tmp.appendingPathComponent(".maugham/ops/d.pending.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"a\""))
        XCTAssertTrue(text.contains("Hello."))
    }

    func test_clear_emptiesInMemoryAndDeletesDiskFile() async throws {
        let buf = PendingBuffer(projectURL: tmp, docId: "d")
        buf.recordChange(paragraphId: "a", prior: nil, next: "Hello.")
        try await buf.flushToDisk()
        try await buf.clear()
        XCTAssertEqual(buf.snapshot().count, 0)
        let url = tmp.appendingPathComponent(".maugham/ops/d.pending.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_loadFromDisk_recoversRecordedChanges() async throws {
        let original = PendingBuffer(projectURL: tmp, docId: "d")
        original.recordChange(paragraphId: "a", prior: nil, next: "From disk.")
        try await original.flushToDisk()

        let fresh = PendingBuffer(projectURL: tmp, docId: "d")
        try await fresh.loadFromDisk()
        let snap = fresh.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].paragraphId, "a")
        XCTAssertEqual(snap[0].next, "From disk.")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement PendingBuffer**

```swift
// Maugham/OpLog/PendingBuffer.swift
import Foundation

/// In-memory buffer of paragraph changes since the last burst boundary,
/// mirrored to disk at `.maugham/ops/<doc-id>.pending.jsonl` on the autosave
/// cadence so a hard-crash mid-burst doesn't lose editorial classification.
@MainActor
public final class PendingBuffer {
    public let projectURL: URL
    public let docId: String
    private var buffer: [String: Op.ParagraphChange] = [:]

    public init(projectURL: URL, docId: String) {
        self.projectURL = projectURL
        self.docId = docId
    }

    public func recordChange(paragraphId: String, prior: String?, next: String) {
        let priorToKeep = buffer[paragraphId]?.prior ?? prior
        buffer[paragraphId] = .init(paragraphId: paragraphId, prior: priorToKeep, next: next)
    }

    public func snapshot() -> [Op.ParagraphChange] {
        // Sort by paragraphId for deterministic output.
        return buffer.values.sorted { $0.paragraphId < $1.paragraphId }
    }

    public func isEmpty() -> Bool { buffer.isEmpty }

    public func flushToDisk() async throws {
        let url = file()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let lines: [String] = try snapshot().map {
            String(data: try enc.encode($0), encoding: .utf8) ?? ""
        }
        let payload = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try Data(payload.utf8).write(to: url, options: .atomic)
    }

    public func loadFromDisk() async throws {
        let url = file()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let d = String(line).data(using: .utf8),
                  let change = try? dec.decode(Op.ParagraphChange.self, from: d) else { continue }
            buffer[change.paragraphId] = change
        }
    }

    public func clear() async throws {
        buffer.removeAll()
        let url = file()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func file() -> URL {
        projectURL
            .appendingPathComponent(".maugham/ops")
            .appendingPathComponent("\(docId).pending.jsonl")
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/PendingBuffer.swift MaughamTests/OpLog/PendingBufferTests.swift Maugham.xcodeproj
git commit -m "feat: PendingBuffer for in-memory + on-disk burst buffer"
```

---

### Task 11: BurstScheduler — 30s idle / 90s max [S]

**Files:**
- Create: `Maugham/OpLog/BurstScheduler.swift`
- Test: `MaughamTests/OpLog/BurstSchedulerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/BurstSchedulerTests.swift
import XCTest
@testable import Maugham

final class BurstSchedulerTests: XCTestCase {
    func test_recordActivity_doesNotFireBeforeIdleThreshold() async throws {
        let exp = expectation(description: "should not fire")
        exp.isInverted = true
        let s = BurstScheduler(idle: .milliseconds(200), max: .seconds(10)) {
            exp.fulfill()
        }
        s.recordActivity()
        await fulfillment(of: [exp], timeout: 0.1)
    }

    func test_recordActivity_firesAfterIdleThreshold() async throws {
        let exp = expectation(description: "fires on idle")
        let s = BurstScheduler(idle: .milliseconds(100), max: .seconds(10)) {
            exp.fulfill()
        }
        s.recordActivity()
        await fulfillment(of: [exp], timeout: 1)
    }

    func test_continuousActivity_firesAtMaxDuration() async throws {
        let exp = expectation(description: "fires on max")
        let s = BurstScheduler(idle: .seconds(60), max: .milliseconds(300)) {
            exp.fulfill()
        }
        for _ in 0..<10 {
            s.recordActivity()
            try await Task.sleep(for: .milliseconds(50))
        }
        await fulfillment(of: [exp], timeout: 1)
    }

    func test_forceFlush_firesImmediately() async throws {
        let exp = expectation(description: "fires on force")
        let s = BurstScheduler(idle: .seconds(60), max: .seconds(60)) {
            exp.fulfill()
        }
        s.recordActivity()
        s.forceFlush()
        await fulfillment(of: [exp], timeout: 0.5)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement BurstScheduler**

```swift
// Maugham/OpLog/BurstScheduler.swift
import Foundation

/// Closes a burst when either:
///   - no activity for `idle`, or
///   - the burst has been open for `max` since first activity.
/// Force-flush is available for document-switch / window-close / ⌘S.
@MainActor
public final class BurstScheduler {
    public let idle: Duration
    public let max: Duration
    public let onFire: () -> Void

    private var idleTimer: DispatchWorkItem?
    private var maxTimer: DispatchWorkItem?
    private var burstOpen: Bool = false

    public init(idle: Duration, max: Duration, onFire: @escaping () -> Void) {
        self.idle = idle
        self.max = max
        self.onFire = onFire
    }

    public func recordActivity() {
        idleTimer?.cancel()
        let token = DispatchWorkItem { [weak self] in
            self?.fire()
        }
        idleTimer = token
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.toSeconds(idle), execute: token)

        if !burstOpen {
            burstOpen = true
            let maxToken = DispatchWorkItem { [weak self] in
                self?.fire()
            }
            maxTimer = maxToken
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.toSeconds(max), execute: maxToken)
        }
    }

    public func forceFlush() {
        if burstOpen { fire() }
    }

    private func fire() {
        idleTimer?.cancel()
        maxTimer?.cancel()
        idleTimer = nil
        maxTimer = nil
        burstOpen = false
        onFire()
    }

    private static func toSeconds(_ d: Duration) -> Double {
        let comps = d.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/BurstScheduler.swift MaughamTests/OpLog/BurstSchedulerTests.swift Maugham.xcodeproj
git commit -m "feat: BurstScheduler with idle + max-duration + force-flush"
```

---

### Task 12: Bootstrap — first-open migration of legacy .md [S]

**Files:**
- Create: `Maugham/OpLog/Bootstrap.swift`
- Test: `MaughamTests/OpLog/BootstrapTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/BootstrapTests.swift
import XCTest
@testable import Maugham

final class BootstrapTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BST-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_bootstrap_writesIdsIntoMarkdownAndEmitsOp() async throws {
        let mdURL = tmp.appendingPathComponent("manuscript.md")
        try "First paragraph.\n\nSecond paragraph.\n".write(to: mdURL, atomically: true, encoding: .utf8)

        let result = try await Bootstrap.run(
            projectURL: tmp,
            docId: "doc-1",
            mdURL: mdURL,
            device: "m",
            session: "s")

        // .md gained inline IDs
        let after = try String(contentsOf: mdURL, encoding: .utf8)
        let parsed = ParagraphParser.parse(after)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertNotNil(parsed[0].id)
        XCTAssertNotNil(parsed[1].id)
        XCTAssertNotEqual(parsed[0].id, parsed[1].id)

        // Bootstrap op landed
        let store = OpLogStore(projectURL: tmp)
        let ops = try await store.load(docId: "doc-1")
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].kind, .bootstrap)
        XCTAssertEqual(ops[0].changes.count, 2)
        XCTAssertEqual(ops[0].sequence?.count, 2)

        // Result reports the new IDs
        XCTAssertEqual(result.paragraphIds.count, 2)
    }

    func test_bootstrap_isIdempotent_doesNotRunIfIdsAlreadyPresent() async throws {
        let mdURL = tmp.appendingPathComponent("manuscript.md")
        try "<!-- ¶a3f9 -->\n\nAlready tagged.\n".write(to: mdURL, atomically: true, encoding: .utf8)

        let result = try await Bootstrap.run(
            projectURL: tmp, docId: "doc-1", mdURL: mdURL,
            device: "m", session: "s")

        XCTAssertFalse(result.bootstrapped, "should detect existing IDs and skip")
        let store = OpLogStore(projectURL: tmp)
        XCTAssertEqual(try await store.load(docId: "doc-1"), [])
    }

    func test_bootstrap_emitsAutoLabeledCheckpoint() async throws {
        let mdURL = tmp.appendingPathComponent("manuscript.md")
        try "First.\n".write(to: mdURL, atomically: true, encoding: .utf8)

        _ = try await Bootstrap.run(
            projectURL: tmp, docId: "doc-1", mdURL: mdURL,
            device: "m", session: "s")

        let cps = try await CheckpointStore(projectURL: tmp).load()
        XCTAssertEqual(cps.count, 1)
        XCTAssertEqual(cps[0].labelSource, .auto)
        XCTAssertTrue(cps[0].label.contains("Initial"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement Bootstrap**

```swift
// Maugham/OpLog/Bootstrap.swift
import Foundation

/// First-open migration of a legacy .md to the op-log format. Idempotent.
@MainActor
public enum Bootstrap {
    public struct Result: Sendable {
        public let bootstrapped: Bool
        public let paragraphIds: [String]
    }

    public static func run(
        projectURL: URL, docId: String, mdURL: URL,
        device: String, session: String
    ) async throws -> Result {
        let original = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
        let parsed = ParagraphParser.parse(original)
        let allHaveIds = !parsed.isEmpty && parsed.allSatisfy { $0.id != nil }
        if allHaveIds {
            return Result(bootstrapped: false,
                paragraphIds: parsed.compactMap(\.id))
        }

        // Mint new ids for any missing.
        var sequence: [String] = []
        var paragraphMap: [String: String] = [:]
        var changes: [Op.ParagraphChange] = []
        for p in parsed {
            let id = p.id ?? ParagraphID.mint()
            sequence.append(id)
            paragraphMap[id] = p.text
            changes.append(.init(paragraphId: id, prior: nil, next: p.text))
        }

        // Write .md back with IDs.
        let newMd = Materializer.materialize(
            paragraphs: paragraphMap, sequence: sequence)
        try newMd.data(using: .utf8)?.write(to: mdURL, options: .atomic)

        // Emit bootstrap op.
        let op = Op(
            opId: ULID.generate(), docId: docId, at: Date(),
            device: device, session: session, kind: .bootstrap,
            changes: changes, sequence: sequence, provenance: nil)
        let opStore = OpLogStore(projectURL: projectURL)
        try await opStore.append(op)

        // Emit initial checkpoint.
        let wordCount = paragraphMap.values
            .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
            .reduce(0, +)
        let cp = Checkpoint(
            checkpointId: ULID.generate(),
            label: "Initial — pre-tracking content",
            labelSource: .auto,
            at: Date(),
            device: device,
            activeDoc: docId,
            docPointers: [docId: op.opId],
            manuscriptWordCount: wordCount)
        try await CheckpointStore(projectURL: projectURL).append(cp)

        return Result(bootstrapped: true, paragraphIds: sequence)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/Bootstrap.swift MaughamTests/OpLog/BootstrapTests.swift Maugham.xcodeproj
git commit -m "feat: Bootstrap migrates legacy .md to op-log format"
```

---

### Task 13: ShingleMatcher — k=4 Jaccard for orphan recovery [S]

**Files:**
- Create: `Maugham/OpLog/ShingleMatcher.swift`
- Test: `MaughamTests/OpLog/ShingleMatcherTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/ShingleMatcherTests.swift
import XCTest
@testable import Maugham

final class ShingleMatcherTests: XCTestCase {
    func test_jaccard_identicalText_isOne() {
        let s = "The morning began with toast and a sense of foreboding."
        XCTAssertEqual(ShingleMatcher.jaccard(s, s, k: 4), 1.0, accuracy: 0.001)
    }

    func test_jaccard_disjointText_isZero() {
        let a = "The cat sat on the mat in the morning light."
        let b = "Programming languages have evolved enormously over the decades."
        XCTAssertEqual(ShingleMatcher.jaccard(a, b, k: 4), 0.0, accuracy: 0.001)
    }

    func test_jaccard_minorEdit_returnsHighSimilarity() {
        let a = "The morning began with toast and a sense of foreboding she could not place."
        let b = "The morning began with burnt toast and a sense of foreboding she could not place."
        XCTAssertGreaterThan(ShingleMatcher.jaccard(a, b, k: 4), 0.6)
    }

    func test_bestMatch_returnsHighestAboveThreshold() {
        let needle = "The morning began with toast."
        let haystack = [
            "id-1": "Completely unrelated text about programming.",
            "id-2": "The morning began with burnt toast.",
            "id-3": "Another piece of unrelated content here."
        ]
        let match = ShingleMatcher.bestMatch(
            needle: needle, candidates: haystack, k: 4, threshold: 0.5)
        XCTAssertEqual(match?.id, "id-2")
    }

    func test_bestMatch_returnsNilBelowThreshold() {
        let needle = "Completely original content."
        let haystack = ["id-1": "Different text entirely with no overlap nearby."]
        let match = ShingleMatcher.bestMatch(
            needle: needle, candidates: haystack, k: 4, threshold: 0.6)
        XCTAssertNil(match)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement ShingleMatcher**

```swift
// Maugham/OpLog/ShingleMatcher.swift
import Foundation

public enum ShingleMatcher {
    public struct Match: Equatable {
        public let id: String
        public let score: Double
    }

    /// Jaccard similarity between two strings using k-word shingles.
    public static func jaccard(_ a: String, _ b: String, k: Int) -> Double {
        let sa = shingles(of: a, k: k)
        let sb = shingles(of: b, k: k)
        if sa.isEmpty && sb.isEmpty { return 1.0 }
        if sa.isEmpty || sb.isEmpty { return 0.0 }
        let inter = sa.intersection(sb).count
        let union = sa.union(sb).count
        return Double(inter) / Double(union)
    }

    /// Find the best-matching candidate above threshold.
    public static func bestMatch(
        needle: String, candidates: [String: String],
        k: Int, threshold: Double
    ) -> Match? {
        var best: Match? = nil
        for (id, text) in candidates {
            let score = jaccard(needle, text, k: k)
            if score >= threshold {
                if let b = best {
                    if score > b.score { best = Match(id: id, score: score) }
                } else {
                    best = Match(id: id, score: score)
                }
            }
        }
        return best
    }

    private static func shingles(of text: String, k: Int) -> Set<String> {
        let words = text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard words.count >= k else { return Set(words.isEmpty ? [] : [words.joined(separator: " ")]) }
        var s = Set<String>()
        for i in 0...(words.count - k) {
            s.insert(words[i..<i+k].joined(separator: " "))
        }
        return s
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/ShingleMatcher.swift MaughamTests/OpLog/ShingleMatcherTests.swift Maugham.xcodeproj
git commit -m "feat: ShingleMatcher for paragraph similarity / orphan recovery"
```

---

### Task 14: Reconciler — cross-Mac merge + external-tool detection [S]

**Files:**
- Create: `Maugham/OpLog/Reconciler.swift`
- Test: `MaughamTests/OpLog/ReconcilerTests.swift`, `MaughamTests/OpLog/CrossMacMergeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/ReconcilerTests.swift
import XCTest
@testable import Maugham

final class ReconcilerTests: XCTestCase {
    func test_classifyExternalEdit_diskEqualsDerived_isEcho() {
        let derivedMd = "<!-- ¶a -->\n\nHello.\n"
        let diskMd = "<!-- ¶a -->\n\nHello.\n"
        let cls = Reconciler.classify(diskMd: diskMd, derivedMd: derivedMd)
        XCTAssertEqual(cls, .echo)
    }

    func test_classifyExternalEdit_idsIntact_isSilentIngest() {
        let derivedMd = "<!-- ¶a -->\n\nHello.\n\n<!-- ¶b -->\n\nWorld.\n"
        let diskMd = "<!-- ¶a -->\n\nHello, edited.\n\n<!-- ¶b -->\n\nWorld.\n"
        let cls = Reconciler.classify(diskMd: diskMd, derivedMd: derivedMd)
        if case .silentIngest(let changes) = cls {
            XCTAssertEqual(changes.count, 1)
            XCTAssertEqual(changes[0].paragraphId, "a")
            XCTAssertEqual(changes[0].next, "Hello, edited.")
        } else {
            XCTFail("expected .silentIngest; got \(cls)")
        }
    }

    func test_classifyExternalEdit_idsMissing_needsSheet() {
        let derivedMd = "<!-- ¶a -->\n\nHello.\n"
        let diskMd = "Hello, but the comment got stripped.\n"
        let cls = Reconciler.classify(diskMd: diskMd, derivedMd: derivedMd)
        if case .needsSheet = cls {
            // expected
        } else {
            XCTFail("expected .needsSheet; got \(cls)")
        }
    }
}
```

```swift
// MaughamTests/OpLog/CrossMacMergeTests.swift
import XCTest
@testable import Maugham

final class CrossMacMergeTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMM-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_logMerge_deduplicatesByOpIdAndSortsAcrossDevices() async throws {
        let store = OpLogStore(projectURL: tmp)
        // Simulate Mac A ops and Mac B ops arriving in mixed order.
        try await store.append(Op(
            opId: "01HZK02", docId: "d", at: Date(), device: "mac-A",
            session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "a", prior: nil, next: "A-1")]))
        try await store.append(Op(
            opId: "01HZK01", docId: "d", at: Date(), device: "mac-B",
            session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "a", prior: nil, next: "B-0")]))
        try await store.append(Op(
            opId: "01HZK02", docId: "d", at: Date(), device: "mac-A",
            session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "a", prior: nil, next: "A-1-dup")]))

        let ops = try await store.load(docId: "d")
        XCTAssertEqual(ops.map(\.opId), ["01HZK01", "01HZK02"])
        // LWW: 01HZK02 wins for paragraph a.
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.paragraphs["a"], "A-1")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement Reconciler**

```swift
// Maugham/OpLog/Reconciler.swift
import Foundation

/// Classifies an observed change to a manuscript .md file. Cross-Mac merges
/// happen at the log layer (transparent to UI); only external-tool edits
/// produce visible reconciliation events here.
public enum Reconciler {
    public enum Classification: Equatable {
        case echo
        case silentIngest(changes: [Op.ParagraphChange])
        case needsSheet(orphanCount: Int)
    }

    public static func classify(diskMd: String, derivedMd: String) -> Classification {
        if diskMd == derivedMd { return .echo }

        let diskParsed = ParagraphParser.parse(diskMd)
        let derivedParsed = ParagraphParser.parse(derivedMd)

        // If any paragraph in disk lacks an id, fall to sheet path.
        if diskParsed.contains(where: { $0.id == nil }) {
            return .needsSheet(orphanCount: diskParsed.filter { $0.id == nil }.count)
        }

        // Both sides fully tagged. Compute per-paragraph changes.
        var derivedMap: [String: String] = [:]
        for p in derivedParsed {
            if let id = p.id { derivedMap[id] = p.text }
        }
        var changes: [Op.ParagraphChange] = []
        for p in diskParsed {
            guard let id = p.id else { continue }
            if derivedMap[id] != p.text {
                changes.append(.init(paragraphId: id, prior: derivedMap[id], next: p.text))
            }
        }
        if changes.isEmpty { return .echo }
        return .silentIngest(changes: changes)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/Reconciler.swift MaughamTests/OpLog/ReconcilerTests.swift MaughamTests/OpLog/CrossMacMergeTests.swift Maugham.xcodeproj
git commit -m "feat: Reconciler classifies disk-vs-derived (echo/ingest/sheet) + log-merge LWW"
```

---

### Task 15: Restore — build checkpoint_restore ops for partial scope [S]

**Files:**
- Create: `Maugham/OpLog/Restore.swift`
- Test: `MaughamTests/OpLog/RestoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/RestoreTests.swift
import XCTest
@testable import Maugham

final class RestoreTests: XCTestCase {
    func test_buildRestoreOp_singleParagraphScope_emitsOnlyThatParagraph() {
        let currentState = Deriver.DerivedState(
            paragraphs: ["a": "current-a", "b": "current-b"],
            sequence: ["a", "b"])
        let targetState = Deriver.DerivedState(
            paragraphs: ["a": "old-a", "b": "old-b"],
            sequence: ["a", "b"])
        let op = Restore.buildRestoreOp(
            current: currentState, target: targetState,
            scope: .paragraph("a"),
            docId: "doc-1", device: "m", session: "s",
            sourceCheckpoint: "cp-1")
        XCTAssertEqual(op.kind, .checkpointRestore)
        XCTAssertEqual(op.changes.count, 1)
        XCTAssertEqual(op.changes[0].paragraphId, "a")
        XCTAssertEqual(op.changes[0].next, "old-a")
        XCTAssertEqual(op.provenance?.sourceCheckpoint, "cp-1")
    }

    func test_buildRestoreOp_documentScope_emitsAllChangedParagraphs() {
        let currentState = Deriver.DerivedState(
            paragraphs: ["a": "current-a", "b": "current-b", "c": "same"],
            sequence: ["a", "b", "c"])
        let targetState = Deriver.DerivedState(
            paragraphs: ["a": "old-a", "b": "old-b", "c": "same"],
            sequence: ["a", "b", "c"])
        let op = Restore.buildRestoreOp(
            current: currentState, target: targetState,
            scope: .document,
            docId: "doc-1", device: "m", session: "s",
            sourceCheckpoint: "cp-1")
        XCTAssertEqual(op.changes.count, 2)
        XCTAssertEqual(Set(op.changes.map(\.paragraphId)), ["a", "b"])
    }

    func test_buildRestoreOp_noChanges_returnsNil() {
        let same = Deriver.DerivedState(
            paragraphs: ["a": "x"], sequence: ["a"])
        XCTAssertNil(Restore.buildRestoreOp(
            current: same, target: same, scope: .document,
            docId: "doc-1", device: "m", session: "s",
            sourceCheckpoint: "cp-1"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement Restore**

```swift
// Maugham/OpLog/Restore.swift
import Foundation

public enum Restore {
    public enum Scope: Equatable {
        case document
        case paragraph(String)
    }

    /// Build a checkpoint_restore op that turns `current` into `target` for the
    /// given scope. Returns nil when no changes are needed.
    public static func buildRestoreOp(
        current: Deriver.DerivedState,
        target: Deriver.DerivedState,
        scope: Scope,
        docId: String,
        device: String,
        session: String,
        sourceCheckpoint: String
    ) -> Op? {
        let candidatePids: [String]
        switch scope {
        case .document:
            candidatePids = Array(Set(current.paragraphs.keys).union(target.paragraphs.keys))
        case .paragraph(let pid):
            candidatePids = [pid]
        }
        var changes: [Op.ParagraphChange] = []
        for pid in candidatePids {
            let curr = current.paragraphs[pid]
            let tgt = target.paragraphs[pid]
            guard curr != tgt, let next = tgt else { continue }
            changes.append(.init(paragraphId: pid, prior: curr, next: next))
        }
        guard !changes.isEmpty else { return nil }
        return Op(
            opId: ULID.generate(),
            docId: docId,
            at: Date(),
            device: device,
            session: session,
            kind: .checkpointRestore,
            changes: changes,
            sequence: nil,
            provenance: .init(sourceCheckpoint: sourceCheckpoint))
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/OpLog/Restore.swift MaughamTests/OpLog/RestoreTests.swift Maugham.xcodeproj
git commit -m "feat: Restore builds checkpoint_restore ops for partial scope"
```

---

### Task 16: Editor RenderFilter — hide HTML-comment IDs from the editor view [S]

**Files:**
- Create: `Maugham/Editor/RenderFilter.swift`
- Test: `MaughamTests/OpLog/RenderFilterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/RenderFilterTests.swift
import XCTest
@testable import Maugham

final class RenderFilterTests: XCTestCase {
    func test_stripComments_removesIdMarkers_keepsParagraphs() {
        let stored = "<!-- ¶a -->\n\nFirst.\n\n<!-- ¶b -->\n\nSecond.\n"
        let display = RenderFilter.stripComments(stored)
        XCTAssertEqual(display, "First.\n\nSecond.")
    }

    func test_stripComments_keepsArbitraryHtmlCommentsThatAreNotIds() {
        let stored = "<!-- A real author note -->\n\nFirst.\n"
        XCTAssertEqual(RenderFilter.stripComments(stored),
            "<!-- A real author note -->\n\nFirst.")
    }

    func test_restoreComments_reattachesIdsByContentMatch() {
        let stored = "<!-- ¶a -->\n\nFirst.\n\n<!-- ¶b -->\n\nSecond.\n"
        let displayEdited = "First, edited.\n\nSecond."
        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "a")
        XCTAssertEqual(parsed[0].text, "First, edited.")
        XCTAssertEqual(parsed[1].id, "b")
        XCTAssertEqual(parsed[1].text, "Second.")
    }

    func test_restoreComments_paragraphInserted_mintsNewIdForIt() {
        let stored = "<!-- ¶a -->\n\nFirst.\n\n<!-- ¶b -->\n\nSecond.\n"
        let displayEdited = "First.\n\nMiddle inserted.\n\nSecond."
        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].id, "a")
        XCTAssertNotNil(parsed[1].id)
        XCTAssertNotEqual(parsed[1].id, "a")
        XCTAssertNotEqual(parsed[1].id, "b")
        XCTAssertEqual(parsed[2].id, "b")
    }

    func test_restoreComments_paragraphRemoved_dropsItsId() {
        let stored = "<!-- ¶a -->\n\nFirst.\n\n<!-- ¶b -->\n\nSecond.\n"
        let displayEdited = "First."
        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "a")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Implement RenderFilter**

```swift
// Maugham/Editor/RenderFilter.swift
import Foundation

/// Translates between the on-disk markdown (with `<!-- ¶id -->` comments)
/// and the display form (comments hidden). On every editor save we round-
/// trip: parse the prior stored form to know existing IDs, then reattach
/// IDs to the display-edited paragraphs by positional + shingle match.
public enum RenderFilter {
    /// Strip only `<!-- ¶id -->` comment lines. Other HTML comments are kept.
    public static func stripComments(_ stored: String) -> String {
        let lines = stored.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var out: [String] = []
        for line in lines {
            let s = String(line)
            if ParagraphID.parseComment(s) != nil { continue }
            out.append(s)
        }
        // Collapse leading/trailing blank lines that result from stripped comments.
        return out.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Given the on-disk stored form and the edited display form, produce a
    /// new stored form with IDs reattached. Strategy:
    ///   1. Parse stored to get [(id, text)] ordered.
    ///   2. Parse displayEdited to get [text] ordered.
    ///   3. Walk display order; for each:
    ///      a. exact text match against unmatched stored → reuse id
    ///      b. shingle best-match above 0.6 against unmatched stored → reuse id
    ///      c. otherwise mint a new id
    public static func restoreComments(
        stored: String, displayEdited: String
    ) -> String {
        let storedParsed = ParagraphParser.parse(stored)
        let displayParsed = ParagraphParser.parse(displayEdited)

        var unmatchedById: [String: String] = [:]
        for p in storedParsed {
            if let id = p.id { unmatchedById[id] = p.text }
        }

        var pairs: [(String, String)] = []
        for d in displayParsed {
            // Exact match first.
            if let id = unmatchedById.first(where: { $0.value == d.text })?.key {
                pairs.append((id, d.text))
                unmatchedById.removeValue(forKey: id)
                continue
            }
            // Shingle match.
            if let m = ShingleMatcher.bestMatch(
                needle: d.text, candidates: unmatchedById,
                k: 4, threshold: 0.6) {
                pairs.append((m.id, d.text))
                unmatchedById.removeValue(forKey: m.id)
                continue
            }
            // Mint fresh.
            pairs.append((ParagraphID.mint(), d.text))
        }

        var paragraphs: [String: String] = [:]
        var sequence: [String] = []
        for (id, text) in pairs {
            paragraphs[id] = text
            sequence.append(id)
        }
        return Materializer.materialize(paragraphs: paragraphs, sequence: sequence)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/Editor/RenderFilter.swift MaughamTests/OpLog/RenderFilterTests.swift Maugham.xcodeproj
git commit -m "feat: RenderFilter strips ¶id markers for display + restores them on save"
```

---

### Task 17: DocumentStore integration — wire burst scheduler + materialization [S]

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift`
- Test: `MaughamTests/OpLog/EditorIntegrationTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/EditorIntegrationTests.swift
import XCTest
@testable import Maugham

@MainActor
final class EditorIntegrationTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EIT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_recordParagraphChange_buffersInPending() async throws {
        let store = try await DocumentStore.open(url: tmp)
        store.beginOpLogContext(docId: "doc-1", device: "m", session: "s")
        store.recordParagraphChange(
            paragraphId: "a", prior: nil, next: "First.")
        XCTAssertFalse(store.opLogPendingIsEmpty(),
            "pending buffer should hold the change")
    }

    func test_flushBurst_appendsOpAndClearsPending() async throws {
        let store = try await DocumentStore.open(url: tmp)
        store.beginOpLogContext(docId: "doc-1", device: "m", session: "s")
        store.recordParagraphChange(paragraphId: "a", prior: nil, next: "x")
        store.recordParagraphChange(paragraphId: "b", prior: nil, next: "y")
        try await store.flushBurstNow()

        let log = OpLogStore(projectURL: tmp)
        let ops = try await log.load(docId: "doc-1")
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].kind, .typingBurst)
        XCTAssertEqual(Set(ops[0].changes.map(\.paragraphId)), ["a", "b"])
        XCTAssertTrue(store.opLogPendingIsEmpty())
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL with `recordParagraphChange` / `beginOpLogContext` / `flushBurstNow` not found.

- [ ] **Step 3: Add the API to DocumentStore**

In `Maugham/Stores/DocumentStore.swift`, add a private context struct and direct stored properties on the class (matching the existing pattern — see e.g. `cursorPositions: [String: Int]`):

```swift
// Add near other private state at the top of DocumentStore:
private struct OpLogContext {
    let docId: String
    let device: String
    let session: String
    let buffer: PendingBuffer
}
private var opLogContext: OpLogContext?
private var burstScheduler: BurstScheduler?

// Add as public methods on DocumentStore:
public func beginOpLogContext(docId: String, device: String, session: String) {
    opLogContext = OpLogContext(
        docId: docId, device: device, session: session,
        buffer: PendingBuffer(projectURL: projectURL, docId: docId))
    burstScheduler = BurstScheduler(
        idle: .seconds(30), max: .seconds(90)
    ) { [weak self] in
        Task { @MainActor [weak self] in
            try? await self?.flushBurstNow()
        }
    }
}

public func recordParagraphChange(paragraphId: String, prior: String?, next: String) {
    guard let ctx = opLogContext else { return }
    ctx.buffer.recordChange(paragraphId: paragraphId, prior: prior, next: next)
    burstScheduler?.recordActivity()
}

public func opLogPendingIsEmpty() -> Bool {
    return opLogContext?.buffer.isEmpty() ?? true
}

public func flushBurstNow() async throws {
    guard let ctx = opLogContext, !ctx.buffer.isEmpty() else { return }
    let changes = ctx.buffer.snapshot()
    let op = Op(
        opId: ULID.generate(),
        docId: ctx.docId, at: Date(),
        device: ctx.device, session: ctx.session,
        kind: .typingBurst,
        changes: changes,
        sequence: nil,
        provenance: nil)
    try await OpLogStore(projectURL: projectURL, presenter: presenter).append(op)
    try await ctx.buffer.clear()
}

public func persistPendingBufferToDisk() async throws {
    guard let ctx = opLogContext else { return }
    try await ctx.buffer.flushToDisk()
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/Stores/DocumentStore.swift MaughamTests/OpLog/EditorIntegrationTests.swift Maugham.xcodeproj
git commit -m "feat: DocumentStore op-log integration (record + flush burst)"
```

---

### Task 18: EditorCoordinator — apply RenderFilter + emit paragraph changes [S]

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`
- Test: integrated; manual smoke (see Task 24).

- [ ] **Step 1: Locate the load + save paths in EditorCoordinator**

Search for the `openDocument` / `loadDocument` / save-related methods.

```bash
grep -n "openDocument\|currentDocumentText\|scheduleSave" Maugham/Editor/EditorCoordinator.swift
```

- [ ] **Step 2: Add render-filter integration around editor I/O**

Wrap the text loaded into the editor with `RenderFilter.stripComments`, and on save apply `RenderFilter.restoreComments(stored:, displayEdited:)`. Add a method to derive paragraph-change events by diffing pre-burst and post-burst paragraph maps.

```swift
// In EditorCoordinator.swift, on load:
let storedText = try await documentStore.openDocument(at: path)
let displayText = RenderFilter.stripComments(storedText)
textView.string = displayText
self.priorStoredMarkdown = storedText
self.priorDisplayMarkdown = displayText

// On save (existing scheduleSave path):
let displayEdited = textView.string
let newStored = RenderFilter.restoreComments(
    stored: priorStoredMarkdown, displayEdited: displayEdited)

// Compute paragraph changes and feed them to the op log.
let priorParsed = ParagraphParser.parse(priorStoredMarkdown)
let nextParsed = ParagraphParser.parse(newStored)
var priorById: [String: String] = [:]
for p in priorParsed { if let id = p.id { priorById[id] = p.text } }
for p in nextParsed {
    guard let id = p.id else { continue }
    let prior = priorById[id]
    if prior != p.text {
        documentStore.recordParagraphChange(
            paragraphId: id, prior: prior, next: p.text)
    }
}
documentStore.scheduleSave(for: path, text: newStored)
self.priorStoredMarkdown = newStored
```

(Exact method signatures will depend on the existing `EditorCoordinator`; this is the conceptual shape — the agent adapts to the actual class.)

- [ ] **Step 3: Build to verify integration compiles**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run full test suite to check no regressions**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | tail -5
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift Maugham.xcodeproj
git commit -m "feat: EditorCoordinator applies RenderFilter + records paragraph changes"
```

---

### Task 19: Checkpoint capture — ⌘S handler + Shift-⌘S sheet [S]

**Files:**
- Create: `Maugham/Views/CheckpointLabelPromptSheet.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`
- Test: `MaughamTests/OpLog/CheckpointCaptureTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MaughamTests/OpLog/CheckpointCaptureTests.swift
import XCTest
@testable import Maugham

@MainActor
final class CheckpointCaptureTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_captureCheckpoint_autoLabel_emitsCheckpointAndOp() async throws {
        // Seed: one typing op so doc has a pointer.
        let opStore = OpLogStore(projectURL: tmp)
        let seedOp = Op(
            opId: ULID.generate(),
            docId: "doc-1", at: Date(),
            device: "m", session: "s",
            kind: .typingBurst,
            changes: [.init(paragraphId: "a", prior: nil, next: "Hello.")])
        try await opStore.append(seedOp)

        let cp = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: "doc-1",
            allDocIds: ["doc-1"],
            device: "m", session: "s",
            label: nil)        // auto

        XCTAssertEqual(cp.labelSource, .auto)
        XCTAssertEqual(cp.docPointers["doc-1"], seedOp.opId)

        // Persisted to checkpoints.jsonl.
        let cps = try await CheckpointStore(projectURL: tmp).load()
        XCTAssertEqual(cps.count, 1)
        XCTAssertEqual(cps[0], cp)

        // Breadcrumb checkpoint op landed on doc-1's log.
        let ops = try await opStore.load(docId: "doc-1")
        XCTAssertTrue(ops.contains(where: { $0.kind == .checkpoint }))
    }

    func test_captureCheckpoint_userLabel_isHonored() async throws {
        let opStore = OpLogStore(projectURL: tmp)
        try await opStore.append(Op(
            opId: ULID.generate(), docId: "doc-1", at: Date(),
            device: "m", session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "a", prior: nil, next: "Hello.")]))
        let cp = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: "doc-1",
            allDocIds: ["doc-1"],
            device: "m", session: "s",
            label: "end of draft 2")
        XCTAssertEqual(cp.label, "end of draft 2")
        XCTAssertEqual(cp.labelSource, .user)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL.

- [ ] **Step 3: Implement CheckpointCapture**

```swift
// Maugham/OpLog/CheckpointCapture.swift
import Foundation

/// Single entry point for ⌘S and Shift-⌘S. Force-flushes pending bursts on
/// every doc, appends a `checkpoint` breadcrumb op to the active doc's log,
/// and writes a project-wide entry to `checkpoints.jsonl`.
@MainActor
public enum CheckpointCapture {
    public static func run(
        projectURL: URL,
        activeDocId: String,
        allDocIds: [String],
        device: String,
        session: String,
        label: String?
    ) async throws -> Checkpoint {
        let opStore = OpLogStore(projectURL: projectURL)

        // doc_pointers = last op_id per doc.
        var pointers: [String: String] = [:]
        for docId in allDocIds {
            if let last = try await opStore.load(docId: docId).last {
                pointers[docId] = last.opId
            }
        }

        // Breadcrumb op on the active doc.
        let cpOpId = ULID.generate()
        let cpOp = Op(
            opId: cpOpId,
            docId: activeDocId,
            at: Date(),
            device: device,
            session: session,
            kind: .checkpoint,
            changes: [],
            sequence: nil,
            provenance: nil)
        try await opStore.append(cpOp)
        pointers[activeDocId] = cpOpId

        // Compute word count over all docs.
        var totalWords = 0
        for docId in allDocIds {
            let ops = try await opStore.load(docId: docId)
            let state = Deriver.derive(ops: ops)
            totalWords += state.paragraphs.values
                .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
                .reduce(0, +)
        }

        // Auto-label or user-supplied.
        let resolvedLabel: String
        let labelSource: Checkpoint.LabelSource
        if let userLabel = label, !userLabel.isEmpty {
            resolvedLabel = userLabel
            labelSource = .user
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let timeStr = formatter.string(from: Date())
            let words = totalWords.formatted(.number)
            resolvedLabel = "\(timeStr) — \(words) words (\(activeDocId))"
            labelSource = .auto
        }

        let cp = Checkpoint(
            checkpointId: ULID.generate(),
            label: resolvedLabel,
            labelSource: labelSource,
            at: Date(),
            device: device,
            activeDoc: activeDocId,
            docPointers: pointers,
            manuscriptWordCount: totalWords)
        try await CheckpointStore(projectURL: projectURL).append(cp)
        return cp
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Implement the Shift-⌘S sheet**

```swift
// Maugham/Views/CheckpointLabelPromptSheet.swift
import SwiftUI

struct CheckpointLabelPromptSheet: View {
    @State private var label: String = ""
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name this checkpoint").font(.headline)
            TextField("e.g. end of draft 2", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onConfirm(label) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}
```

- [ ] **Step 6: Wire ⌘S and Shift-⌘S in ProjectWindow**

In `Maugham/Views/ProjectWindow.swift`, add commands or a `.keyboardShortcut` modifier:

```swift
.keyboardShortcut("s", modifiers: [.command])
.onSubmit {
    Task { @MainActor in
        try? await store.flushBurstNow()
        _ = try? await CheckpointCapture.run(
            projectURL: projectURL,
            activeDocId: activeDocId,
            allDocIds: allDocIds,
            device: deviceId,
            session: sessionId,
            label: nil)
        showSaveFlash()
    }
}
```

(And a Shift-⌘S binding that sets `showingLabelSheet = true`; on confirm, call `CheckpointCapture.run(..., label: enteredLabel)`.)

- [ ] **Step 7: Build + run full suite**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | tail -5
```
Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Maugham/OpLog/CheckpointCapture.swift \
        Maugham/Views/CheckpointLabelPromptSheet.swift \
        Maugham/Views/ProjectWindow.swift \
        MaughamTests/OpLog/CheckpointCaptureTests.swift \
        Maugham.xcodeproj
git commit -m "feat: ⌘S checkpoint capture + Shift-⌘S label sheet"
```

---

### Task 20: CheckpointBrowserPane — minimal restore browser [S]

**Files:**
- Create: `Maugham/Views/CheckpointBrowserPane.swift`, `Maugham/Views/PartialRestorePicker.swift`
- Modify: `Maugham/Views/DetailPaneToggle.swift`, `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Implement CheckpointBrowserPane**

```swift
// Maugham/Views/CheckpointBrowserPane.swift
import SwiftUI

struct CheckpointBrowserPane: View {
    let projectURL: URL
    let activeDocId: String
    let allDocIds: [String]
    let device: String
    let session: String
    @State private var checkpoints: [Checkpoint] = []
    @State private var selected: Checkpoint?
    @State private var showingRestorePicker: Bool = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("Checkpoints").font(.headline).padding(.horizontal)
            List(selection: $selected) {
                ForEach(checkpoints.reversed(), id: \.checkpointId) { cp in
                    VStack(alignment: .leading) {
                        Text(cp.label).font(.body)
                        Text("\(cp.at.formatted()) · \(cp.manuscriptWordCount) words · saved while editing \(cp.activeDoc)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(cp)
                }
            }
            if selected != nil {
                Button("Revert here…") { showingRestorePicker = true }
                    .padding()
            }
        }
        .task { await loadCheckpoints() }
        .sheet(isPresented: $showingRestorePicker) {
            if let cp = selected {
                PartialRestorePicker(
                    checkpoint: cp,
                    projectURL: projectURL,
                    activeDocId: activeDocId,
                    allDocIds: allDocIds,
                    device: device,
                    session: session,
                    onComplete: {
                        showingRestorePicker = false
                        Task { await loadCheckpoints() }
                    },
                    onCancel: { showingRestorePicker = false })
            }
        }
    }

    private func loadCheckpoints() async {
        if let loaded = try? await CheckpointStore(projectURL: projectURL).load() {
            checkpoints = loaded
        }
    }
}
```

- [ ] **Step 2: Implement PartialRestorePicker**

```swift
// Maugham/Views/PartialRestorePicker.swift
import SwiftUI

struct PartialRestorePicker: View {
    let checkpoint: Checkpoint
    let projectURL: URL
    let activeDocId: String
    let allDocIds: [String]
    let device: String
    let session: String
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var scope: ScopeChoice
    enum ScopeChoice: Hashable {
        case wholeProject, document(String)
    }

    init(checkpoint: Checkpoint, projectURL: URL, activeDocId: String,
         allDocIds: [String], device: String, session: String,
         onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.checkpoint = checkpoint
        self.projectURL = projectURL
        self.activeDocId = activeDocId
        self.allDocIds = allDocIds
        self.device = device
        self.session = session
        self.onComplete = onComplete
        self.onCancel = onCancel
        _scope = State(initialValue: .document(checkpoint.activeDoc))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Revert to “\(checkpoint.label)”").font(.headline)
            Picker("Scope", selection: $scope) {
                Text("Whole project").tag(ScopeChoice.wholeProject)
                ForEach(allDocIds, id: \.self) { docId in
                    Text("Document: \(docId)").tag(ScopeChoice.document(docId))
                }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Revert") { Task { await performRestore() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private func performRestore() async {
        let opStore = OpLogStore(projectURL: projectURL)
        let docs: [String]
        switch scope {
        case .wholeProject: docs = allDocIds
        case .document(let id): docs = [id]
        }
        for docId in docs {
            let allOps = (try? await opStore.load(docId: docId)) ?? []
            let current = Deriver.derive(ops: allOps)
            let targetOpId = checkpoint.docPointers[docId]
            let pastOps = allOps.prefix(while: {
                guard let target = targetOpId else { return true }
                return $0.opId <= target
            })
            let target = Deriver.derive(ops: Array(pastOps))
            if let op = Restore.buildRestoreOp(
                current: current, target: target,
                scope: .document,
                docId: docId, device: device, session: session,
                sourceCheckpoint: checkpoint.checkpointId) {
                try? await opStore.append(op)
            }
        }
        onComplete()
    }
}
```

- [ ] **Step 3: Add History segment to DetailPaneToggle**

In `Maugham/Views/DetailPaneToggle.swift`, add a `.history` case to whatever enum the toggle uses, and route it to `CheckpointBrowserPane`.

```swift
// inside the toggle segment definitions:
case .history:
    CheckpointBrowserPane(
        projectURL: projectURL,
        activeDocId: activeDocId,
        allDocIds: allDocIds,
        device: deviceId,
        session: sessionId)
```

Add `.keyboardShortcut("4", modifiers: [.command, .option])` to the History segment.

- [ ] **Step 4: Build + run full suite**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/CheckpointBrowserPane.swift \
        Maugham/Views/PartialRestorePicker.swift \
        Maugham/Views/DetailPaneToggle.swift \
        Maugham/Views/ProjectWindow.swift \
        Maugham.xcodeproj
git commit -m "feat: CheckpointBrowserPane + PartialRestorePicker UI"
```

---

### Task 21: One-time bootstrap notice [H]

**Files:**
- Create: `Maugham/Views/BootstrapNoticeSheet.swift`
- Modify: `Maugham/Stores/UIState.swift`, `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Add a flag to UIState**

In `Maugham/Stores/UIState.swift`, add:

```swift
public var hasShownOpLogBootstrapNotice: Bool = false
```

- [ ] **Step 2: Implement the sheet**

```swift
// Maugham/Views/BootstrapNoticeSheet.swift
import SwiftUI

struct BootstrapNoticeSheet: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit history is now tracked").font(.headline)
            Text("""
            Maugham now keeps a history of every paragraph edit so you can \
            restore earlier versions. Each manuscript file will have small \
            invisible marker comments added the first time it's opened.

            Existing text is preserved exactly. Compiled output (PDF, EPUB) \
            strips the markers automatically.
            """)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 480)
            HStack {
                Spacer()
                Button("Got it") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
```

- [ ] **Step 3: Wire into ProjectWindow .task block**

```swift
.sheet(isPresented: Binding(
    get: { !documentStore.uiState.hasShownOpLogBootstrapNotice },
    set: { _ in })) {
    BootstrapNoticeSheet {
        documentStore.updateUIState { $0.hasShownOpLogBootstrapNotice = true }
    }
}
```

- [ ] **Step 4: Build + run full suite**

Expected: build succeeds, all tests pass.

- [ ] **Step 5: Commit**

```bash
./gen.sh
git add Maugham/Views/BootstrapNoticeSheet.swift \
        Maugham/Stores/UIState.swift \
        Maugham/Views/ProjectWindow.swift \
        Maugham.xcodeproj
git commit -m "feat: one-time bootstrap notice for op-log migration"
```

---

### Task 22: ProjectFolderPresenter observes .maugham/ops + checkpoints.jsonl [S]

**Files:**
- Modify: `Maugham/Stores/ProjectFolderPresenter.swift`, `Maugham/Stores/DocumentStore.swift`

- [ ] **Step 1: Extend presenter to observe op-log files**

In `Maugham/Stores/ProjectFolderPresenter.swift`, ensure the presenter responds to subitem changes anywhere under `.maugham/ops/` and to `.maugham/checkpoints.jsonl`. The presenter already observes the project directory recursively; if so, only the delegate logic needs to fan out to the new file paths.

In `DocumentStore.presenterDidChangeSubitem(at:)` (in `Maugham/Stores/DocumentStore.swift`), add branches:

```swift
if relativePath.hasPrefix(".maugham/ops/") && relativePath.hasSuffix(".jsonl") {
    NotificationCenter.default.post(name: .maughamOpLogChanged,
        object: nil, userInfo: ["path": relativePath])
    return
}
if relativePath == ".maugham/checkpoints.jsonl" {
    NotificationCenter.default.post(name: .maughamCheckpointAdded, object: nil)
    return
}
```

- [ ] **Step 2: Declare the notifications**

In `Maugham/Models/MaughamNotifications.swift`:

```swift
public extension Notification.Name {
    static let maughamOpLogChanged = Notification.Name("maughamOpLogChanged")
    static let maughamCheckpointAdded = Notification.Name("maughamCheckpointAdded")
}
```

- [ ] **Step 3: Build + run full suite**

Expected: builds, all tests pass.

- [ ] **Step 4: Commit**

```bash
./gen.sh
git add Maugham/Stores/ProjectFolderPresenter.swift \
        Maugham/Stores/DocumentStore.swift \
        Maugham/Models/MaughamNotifications.swift \
        Maugham.xcodeproj
git commit -m "feat: presenter observes .maugham/ops + checkpoints.jsonl"
```

---

### Task 23: Crash-recovery test — pending buffer round-trips through reopen [S]

**Files:**
- Test: `MaughamTests/OpLog/CrashRecoveryTests.swift`

- [ ] **Step 1: Write the test**

```swift
// MaughamTests/OpLog/CrashRecoveryTests.swift
import XCTest
@testable import Maugham

@MainActor
final class CrashRecoveryTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_pendingBufferOnDisk_isRecoveredOnReopen() async throws {
        // Simulate session 1: write to pending, do not flush burst.
        do {
            let buf = PendingBuffer(projectURL: tmp, docId: "d")
            buf.recordChange(paragraphId: "a", prior: nil, next: "Crashed in-flight.")
            try await buf.flushToDisk()
        }

        // Simulate session 2: open fresh buffer, recover from disk, flush to op log.
        let buf2 = PendingBuffer(projectURL: tmp, docId: "d")
        try await buf2.loadFromDisk()
        XCTAssertEqual(buf2.snapshot().count, 1)

        // Fold recovered pending into a fresh typing_burst op.
        let op = Op(
            opId: ULID.generate(), docId: "d", at: Date(),
            device: "m", session: "s", kind: .typingBurst,
            changes: buf2.snapshot())
        try await OpLogStore(projectURL: tmp).append(op)
        try await buf2.clear()

        // Verify pending file is gone and op log carries the bytes.
        let pendingURL = tmp.appendingPathComponent(".maugham/ops/d.pending.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        let loaded = try await OpLogStore(projectURL: tmp).load(docId: "d")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].changes.first?.next, "Crashed in-flight.")
    }
}
```

- [ ] **Step 2: Run test to verify it passes (no new prod code needed)**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/CrashRecoveryTests test 2>&1 | tail -5
```
Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 3: Commit**

```bash
git add MaughamTests/OpLog/CrashRecoveryTests.swift Maugham.xcodeproj
git commit -m "test: crash-recovery round-trips pending buffer through reopen"
```

---

### Task 24: End-to-end integration test + manual smoke [S]

**Files:**
- Test: `MaughamTests/OpLog/EndToEndIntegrationTests.swift`
- Manual smoke: see Step 5

- [ ] **Step 1: Write a round-trip integration test**

```swift
// MaughamTests/OpLog/EndToEndIntegrationTests.swift
import XCTest
@testable import Maugham

@MainActor
final class EndToEndIntegrationTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2E-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_typeBurst_checkpoint_restore_roundTrip() async throws {
        let store = try await DocumentStore.open(url: tmp)
        store.beginOpLogContext(docId: "doc-1", device: "m", session: "s")

        // Burst 1: two paragraphs.
        store.recordParagraphChange(paragraphId: "a", prior: nil, next: "First v1.")
        store.recordParagraphChange(paragraphId: "b", prior: nil, next: "Second v1.")
        try await store.flushBurstNow()

        // Checkpoint.
        let cp = try await CheckpointCapture.run(
            projectURL: tmp, activeDocId: "doc-1", allDocIds: ["doc-1"],
            device: "m", session: "s", label: "draft 1")

        // Burst 2: rewrite paragraph a.
        store.recordParagraphChange(paragraphId: "a", prior: "First v1.", next: "First v2.")
        try await store.flushBurstNow()

        let opStore = OpLogStore(projectURL: tmp)
        let ops = try await opStore.load(docId: "doc-1")
        XCTAssertEqual(Deriver.derive(ops: ops).paragraphs["a"], "First v2.")

        // Restore to draft 1.
        let target = Deriver.derive(ops: ops.prefix(while: { $0.opId <= cp.docPointers["doc-1"]! }).map { $0 })
        let restoreOp = Restore.buildRestoreOp(
            current: Deriver.derive(ops: ops),
            target: target,
            scope: .document,
            docId: "doc-1", device: "m", session: "s",
            sourceCheckpoint: cp.checkpointId)
        XCTAssertNotNil(restoreOp)
        try await opStore.append(restoreOp!)

        let after = Deriver.derive(ops: try await opStore.load(docId: "doc-1"))
        XCTAssertEqual(after.paragraphs["a"], "First v1.")
        XCTAssertEqual(after.paragraphs["b"], "Second v1.")
    }
}
```

- [ ] **Step 2: Run integration test, confirm pass**

Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 3: Run the full test suite**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | tail -10
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add MaughamTests/OpLog/EndToEndIntegrationTests.swift Maugham.xcodeproj
git commit -m "test: end-to-end burst → checkpoint → restore round-trip"
```

- [ ] **Step 5: Manual smoke checklist**

Build and launch the app:

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' build 2>&1 | tail -3
open -a Maugham
```

Smoke list:
- [ ] Open an existing manuscript project. One-time bootstrap notice appears, dismissable.
- [ ] Each chapter's `.md` gains `<!-- ¶id -->` comments on first open; editor view does not show them.
- [ ] Type for 30 s; observe `.maugham/ops/<doc-id>.jsonl` gains a typing_burst entry.
- [ ] Type for 90 s continuously; observe a typing_burst lands without idle.
- [ ] Hit ⌘S; observe an entry in `.maugham/checkpoints.jsonl` with auto label.
- [ ] Hit Shift-⌘S; sheet appears, enter label, save; entry has user label.
- [ ] Open ⌘⌥4 History pane; see checkpoints listed reverse-chronologically.
- [ ] Select a checkpoint, click Revert here, pick "Document", confirm; editor text rewinds.
- [ ] Quit and reopen Maugham; state persists.
- [ ] In a second Mac with iCloud sync, open the same project; bursts from Mac 1 appear without conflict UI.
- [ ] Edit a .md in BBEdit (preserve IDs), save; Maugham silently ingests with no sheet.
- [ ] Edit a .md in BBEdit (strip IDs), save; conflict sheet appears.

---

### Task 25: Final smoke + merge + tag [H]

**Files:**
- Update auto-memory (skill-driven, after completion)

- [ ] **Step 1: Run full test suite one final time**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | tail -5
```
Expected: all tests pass.

- [ ] **Step 2: Ff-merge to main**

```bash
git checkout main
git merge --ff-only feat/milestone-document-operation-log
```

- [ ] **Step 3: Tag and push**

```bash
git tag milestone-document-operation-log
git push origin main
git push origin milestone-document-operation-log
```

- [ ] **Step 4: Delete local feature branch**

```bash
git branch -d feat/milestone-document-operation-log
```

- [ ] **Step 5: Update auto-memory**

Write a new memory file at `~/.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_document_operation_log.md` summarizing what shipped (the public APIs, file layout, what's wired into the editor + checkpoint UI + reconciliation), and update `MEMORY.md` with a one-line entry following the existing pattern. Reference the deferred items (annotation schema, accept/reject UX, craft_principles, history-pane forensic burst view) as carry-forwards.
