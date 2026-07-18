# Skills over MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Maugham-served agent skills (transcription workflow, editing pass) three ways — the draft SEP-2640 standard surface, `get_help` compat with tool nudges, and a Claude Code bootstrap skill — plus setup-sheet install affordances.

**Architecture:** One content source (`docs/skills/<name>/SKILL.md`, agentskills.io format) loaded by a `SkillIndex` modeled on `HelpTopicIndex`. All SEP-2640 protocol knowledge lives in one seam (`Maugham/MCP/SkillsExtension.swift`): capability declaration, `skills/list`, `skills/get`, and a narrow `resources/read` for `skill://` URIs with sha256 digests. `get_help` additionally serves the same content; two tool descriptions gain pointers. The setup sheet gains a Claude Code section (bootstrap-skill install with staleness detection + copyable `claude mcp add` command).

**Tech Stack:** Swift (Mac target only; no MaughamCore or phone changes), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-18-skills-over-mcp-design.md`

## Global Constraints

- **SEP-2640 is an unmerged draft** — every SEP shape (capability id `io.modelcontextprotocol/skills`, `skills/list`, `skills/get`, entry fields `name/description/uri/frontmatter/resources`, `digest: "sha256:<hex>"`, `-32602` on unknown skill URI) lives ONLY in `Maugham/MCP/SkillsExtension.swift`, with a revision-pin comment. No SEP knowledge leaks into other files.
- `skills/list` / `skills/get` / `resources/read` are **protocol methods, not tools** — the tool count stays **48** (`get_help` already exists). Tools-list tests must not change count; only two tool DESCRIPTION strings change (blast radius: description-snapshot assertions if any).
- Single content source: `docs/skills/` bundled like `docs/guide/`; no copied prose anywhere (guide, help window, tool descriptions may POINT, never duplicate).
- Frontmatter is restricted to flat `key: value` string pairs (`name`, `description`) — hand-rolled parser, no third-party YAML dep (repo rule: Apple frameworks only).
- MCP responses stay under the 1 MB budget (tripwire 10) — skill bodies are a few KB; contract test asserts anyway.
- Bootstrap-skill install writes OUTSIDE any project (`~/.claude/skills/…`) — plain FileManager, NOT the typed user-content mover (that seam is for project content).
- Variant awareness (tripwire 13): the copyable CLI command and binary paths come from `Bundle.main` / `BuildVariant`, never hardcoded `"maugham"` strings.
- Test after each task: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`. New bundled folder → `./gen.sh` after `project.yml` edits. Never edit `project.pbxproj`.
- Subagent models: opus Tasks 1, 2, 4; sonnet Task 3; haiku Task 5. Reviewers haiku (sonnet for Task 2).

---

### Task 1: SkillIndex + bundled skill content + bootstrap template

**Files:**
- Create: `Maugham/Help/SkillIndex.swift`
- Create: `docs/skills/transcribing-notebooks/SKILL.md`, `docs/skills/editing-pass/SKILL.md`, `docs/skills/maugham-bootstrap/SKILL.md`
- Modify: `project.yml` (bundle `docs/skills` beside the existing `- path: docs/guide` folder resource, same `type: folder` shape)
- Test: `MaughamTests/SkillIndexTests.swift` (create)

**Interfaces:**
- Consumes: `HelpTopicIndex` (`Maugham/Help/HelpTopicIndex.swift`) as the structural model — injected directory, `.bundled()` production loader, typed `LoadError`.
- Produces (Tasks 2–4 rely on these exact signatures):

```swift
struct SkillIndex {
    struct Skill: Equatable {
        let name: String            // folder name == frontmatter name
        let description: String     // frontmatter description
        let body: String            // SKILL.md markdown WITHOUT frontmatter
        let raw: String             // full SKILL.md including frontmatter
        let files: [SkillFile]      // every file in the folder, SKILL.md first
    }
    struct SkillFile: Equatable {
        let relativePath: String    // e.g. "SKILL.md"
        let bytes: Data
        let sha256Hex: String
    }
    enum LoadError: Error, Equatable {
        case directoryMissing
        case malformedFrontmatter(String)   // skill folder name
    }
    let skills: [Skill]                      // sorted by name
    init(directory: URL, strict: Bool) throws
    static func bundled() throws -> SkillIndex   // strict: BuildVariant.current == .dev
    func skill(named name: String) -> Skill?
}
```

Bootstrap template access: the `maugham-bootstrap` skill is loaded like any other but is EXCLUDED from `skills` (it's the client-side router, not a served skill): expose it as `let bootstrapTemplate: Skill?` and filter it out of `skills`.

- [ ] **Step 1: Write the failing tests**

Create `MaughamTests/SkillIndexTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import Maugham

final class SkillIndexTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func writeSkill(_ name: String, frontmatter: String, body: String) throws {
        let dir = temp.url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\n\(frontmatter)\n---\n\(body)".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    func test_load_parsesFrontmatterAndBody() throws {
        try writeSkill("alpha",
            frontmatter: "name: alpha\ndescription: Does alpha things.",
            body: "# Alpha\nStep one.")
        let index = try SkillIndex(directory: temp.url, strict: true)
        let skill = try XCTUnwrap(index.skill(named: "alpha"))
        XCTAssertEqual(skill.description, "Does alpha things.")
        XCTAssertEqual(skill.body, "# Alpha\nStep one.")
        XCTAssertTrue(skill.raw.hasPrefix("---\n"))
    }

    func test_files_haveStableSha256() throws {
        try writeSkill("alpha", frontmatter: "name: alpha\ndescription: d", body: "B")
        let index = try SkillIndex(directory: temp.url, strict: true)
        let file = try XCTUnwrap(index.skill(named: "alpha")?.files.first)
        XCTAssertEqual(file.relativePath, "SKILL.md")
        let expected = SHA256.hash(data: file.bytes)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(file.sha256Hex, expected)
    }

    func test_extraFiles_listedAfterSkillMd() throws {
        try writeSkill("alpha", frontmatter: "name: alpha\ndescription: d", body: "B")
        try "ref".write(
            to: temp.url.appendingPathComponent("alpha/reference.md"),
            atomically: true, encoding: .utf8)
        let index = try SkillIndex(directory: temp.url, strict: true)
        let paths = index.skill(named: "alpha")?.files.map(\.relativePath)
        XCTAssertEqual(paths, ["SKILL.md", "reference.md"])
    }

    func test_bootstrap_excludedFromSkillsButExposed() throws {
        try writeSkill("alpha", frontmatter: "name: alpha\ndescription: d", body: "B")
        try writeSkill("maugham-bootstrap",
            frontmatter: "name: maugham\ndescription: router", body: "R")
        let index = try SkillIndex(directory: temp.url, strict: true)
        XCTAssertEqual(index.skills.map(\.name), ["alpha"])
        XCTAssertEqual(index.bootstrapTemplate?.body, "R")
    }

    func test_strict_malformedFrontmatterThrows() throws {
        try writeSkill("bad", frontmatter: "no-colon-here", body: "B")
        XCTAssertThrowsError(try SkillIndex(directory: temp.url, strict: true)) { error in
            XCTAssertEqual(error as? SkillIndex.LoadError, .malformedFrontmatter("bad"))
        }
    }

    func test_lenient_malformedFrontmatterSkipsSkill() throws {
        try writeSkill("bad", frontmatter: "no-colon-here", body: "B")
        try writeSkill("good", frontmatter: "name: good\ndescription: d", body: "B")
        let index = try SkillIndex(directory: temp.url, strict: false)
        XCTAssertEqual(index.skills.map(\.name), ["good"])
    }

    func test_bundledSkills_loadAndAreNonEmpty() throws {
        // The real bundled content: both skills present with descriptions.
        let index = try SkillIndex.bundled()
        XCTAssertEqual(index.skills.map(\.name),
                       ["editing-pass", "transcribing-notebooks"])
        XCTAssertNotNil(index.bootstrapTemplate)
        for skill in index.skills {
            XCTAssertFalse(skill.description.isEmpty)
            XCTAssertGreaterThan(skill.body.count, 200)
        }
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/SkillIndexTests`
Expected: FAIL — `SkillIndex` undefined.

- [ ] **Step 3: Implement `Maugham/Help/SkillIndex.swift`**

```swift
import Foundation
import CryptoKit

/// Loads the bundled agent skills (`docs/skills/<name>/SKILL.md`,
/// agentskills.io format). The single seam every skills surface reads
/// through — SEP-2640 extension, get_help topics, and the bootstrap-skill
/// installer. Modeled on HelpTopicIndex: injected directory for tests,
/// `.bundled()` in production.
///
/// Frontmatter is deliberately restricted to flat `key: value` string
/// pairs (`name`, `description`) so a hand-rolled parser suffices — no
/// third-party YAML dependency (repo rule: Apple frameworks only).
struct SkillIndex {
    struct SkillFile: Equatable {
        let relativePath: String
        let bytes: Data
        let sha256Hex: String
    }
    struct Skill: Equatable {
        let name: String
        let description: String
        let body: String
        let raw: String
        let files: [SkillFile]
    }
    enum LoadError: Error, Equatable {
        case directoryMissing
        case malformedFrontmatter(String)
    }

    /// The router template installed into ~/.claude/skills — not served.
    static let bootstrapFolderName = "maugham-bootstrap"

    let skills: [Skill]
    let bootstrapTemplate: Skill?

    init(directory: URL, strict: Bool) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw LoadError.directoryMissing
        }
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        var loaded: [Skill] = []
        var bootstrap: Skill?
        for folder in folders {
            do {
                let skill = try Self.loadSkill(at: folder)
                if folder.lastPathComponent == Self.bootstrapFolderName {
                    bootstrap = skill
                } else {
                    loaded.append(skill)
                }
            } catch {
                // A broken skill must not take the MCP server down in
                // release; dev builds fail loudly so authoring errors are
                // caught immediately (spec: error handling).
                if strict { throw error }
                NSLog("SkillIndex: skipping malformed skill %@: %@",
                      folder.lastPathComponent, "\(error)")
            }
        }
        self.skills = loaded
        self.bootstrapTemplate = bootstrap
    }

    /// Production loader: the `skills/` folder bundled by `project.yml`.
    static func bundled() throws -> SkillIndex {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("skills") else {
            throw LoadError.directoryMissing
        }
        return try SkillIndex(directory: url, strict: BuildVariant.current == .dev)
    }

    func skill(named name: String) -> Skill? {
        skills.first(where: { $0.name == name })
    }

    // MARK: - Loading

    private static func loadSkill(at folder: URL) throws -> Skill {
        let folderName = folder.lastPathComponent
        let skillURL = folder.appendingPathComponent("SKILL.md")
        guard let raw = try? String(contentsOf: skillURL, encoding: .utf8) else {  // adr-0018-ok: bundled skill read, not manuscript
            throw LoadError.malformedFrontmatter(folderName)
        }
        let (frontmatter, body) = try parseFrontmatter(raw, folderName: folderName)
        guard let name = frontmatter["name"], !name.isEmpty,
              let description = frontmatter["description"], !description.isEmpty else {
            throw LoadError.malformedFrontmatter(folderName)
        }

        var files: [SkillFile] = []
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        for fileURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let bytes = try? Data(contentsOf: fileURL) else { continue }  // adr-0018-ok: bundled skill read, not manuscript
            let digest = SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }.joined()
            files.append(SkillFile(
                relativePath: fileURL.lastPathComponent,
                bytes: bytes, sha256Hex: digest))
        }
        // SKILL.md leads; siblings follow in name order.
        files.sort { a, b in
            if a.relativePath == "SKILL.md" { return true }
            if b.relativePath == "SKILL.md" { return false }
            return a.relativePath < b.relativePath
        }
        return Skill(name: name, description: description,
                     body: body, raw: raw, files: files)
    }

    /// Flat `key: value` frontmatter between `---` fences.
    static func parseFrontmatter(
        _ raw: String, folderName: String
    ) throws -> (fields: [String: String], body: String) {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first == "---",
              let closeIdx = lines.dropFirst().firstIndex(of: "---") else {
            throw LoadError.malformedFrontmatter(folderName)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<closeIdx] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let colon = trimmed.firstIndex(of: ":") else {
                throw LoadError.malformedFrontmatter(folderName)
            }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        let body = lines[(closeIdx + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        return (fields, body)
    }
}
```

- [ ] **Step 4: Author the three SKILL.md files**

`docs/skills/transcribing-notebooks/SKILL.md`:

```markdown
---
name: transcribing-notebooks
description: Transcribe handwritten notebook photos from a Maugham project's research into text notes. Use when asked to transcribe notebook pages, journals, or handwritten research images.
---

# Transcribing notebook photos

Turn photographed notebook pages (image research items) into faithful text
transcriptions stored as research notes. Never write into the manuscript.

## Workflow

1. **Find the pages.** `list_research(project_id)` — image items have
   `kind: image`. Note which pages are already covered by existing
   transcription notes (search their titles/bodies first; don't re-transcribe).
2. **Read each page.** `read_document(project_id, document_id)` — the
   default 2048px works for most handwriting. If the transport caps you
   to a lower size (the response says so), that's normal.
3. **Hard-to-read lines:** re-read with a `region` crop at higher
   effective resolution, e.g. `{"x": 0, "y": 0.6, "width": 1, "height": 0.2}`
   for a band 60% down the page. Crop tight; resolution goes where the
   pixels are.
4. **Write the transcription** with `add_note` into the piece's research
   (pass the piece as the target so it lands beside the source images).
   One note per session or per chapter of pages — follow the existing
   naming in the project (e.g. `dreams-notes-transcription-part-2`).
5. **Verify continuity.** Consecutive pages usually continue sentences
   across the boundary; if a page doesn't follow from the last, say so
   rather than smoothing it over.

## Honesty rules (non-negotiable)

- Transcribe only what you can actually read in the returned pixels.
- Mark unreadable passages `[illegible]` — never reconstruct, guess, or
  paraphrase them into existence.
- If a read returns no visible image, STOP and say exactly that. Do not
  produce a transcription from context or memory.
- Preserve the writer's spelling, punctuation, and line grouping; use
  paragraph breaks where the notebook has them.
```

`docs/skills/editing-pass/SKILL.md`:

```markdown
---
name: editing-pass
description: Run an editing pass over a Maugham manuscript using the annotation layer. Use when asked to edit, critique, line-edit, or review manuscript text in Maugham.
---

# Editing pass

Editorial feedback in Maugham flows through the annotation layer. The
manuscript itself is never edited directly — the writer accepts or
rejects every change.

## Workflow

1. **Read this project's craft intent first**: `read_craft_intent`. It
   holds the writer's own guidelines for this project (voice, tense,
   things to leave alone). It overrides any general editing instinct you
   have. If there is no craft intent, say so and ask what kind of pass
   the writer wants before annotating.
2. **Read the target text** with `read_document` and use the returned
   paragraph ids for anchoring.
3. **Annotate, never edit:**
   - `add_comment` — editorial observations; use `quote` to anchor a
     specific phrase.
   - `add_suggested_change` — concrete rewordings the writer can accept
     with one click. Keep each suggestion minimal and single-purpose.
   - `add_query` — questions (continuity, factual, intent) rather than
     opinions.
4. **Batch sensibly.** A pass of focused annotations on one chapter beats
   a scattering across the whole manuscript. State your coverage when done
   ("commented on chapters 1–2, stopped there").
5. **Respect prior rejections.** Rejected annotations carry the writer's
   reasoning — read them (`list_annotations` with status filters) and
   don't re-raise settled points.
```

`docs/skills/maugham-bootstrap/SKILL.md`:

```markdown
---
name: maugham
description: Working with the Maugham writing app (manuscripts, research, transcription, editing passes, publishing) via its MCP tools. Use whenever the Maugham MCP server's tools are in play or the user mentions Maugham.
---

# Maugham

Maugham serves its own task skills over MCP — always fetch the current
procedure instead of improvising:

1. Call `get_help` with topic `skills` to list the available Maugham
   skills with descriptions.
2. Call `get_help` with the relevant skill's name (e.g.
   `transcribing-notebooks`, `editing-pass`) to load the full procedure.
3. Follow the loaded procedure. It is authoritative for how to use
   Maugham's tools for that task and reflects the installed app version.

Hard rules that apply regardless of task: Claude never edits manuscript
text directly (annotations and research only), and `get_help` without a
topic lists Maugham's user documentation.
```

- [ ] **Step 5: Bundle the folder**

In `project.yml`, in the Maugham target's resources list (beside the existing `- path: docs/guide` entry), add:

```yaml
      - path: docs/skills
        type: folder
```

Then run `./gen.sh`.

- [ ] **Step 6: Run tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/SkillIndexTests`
Expected: PASS (including `test_bundledSkills_loadAndAreNonEmpty` against the real bundle).

- [ ] **Step 7: Commit**

```bash
git add Maugham/Help/SkillIndex.swift docs/skills MaughamTests/SkillIndexTests.swift project.yml
git commit -m "feat(skills): SkillIndex loader + bundled transcription/editing-pass/bootstrap skills"
```

---

### Task 2: SEP-2640 surface — capability, skills/list, skills/get, resources/read

**Files:**
- Create: `Maugham/MCP/SkillsExtension.swift`
- Modify: `Maugham/MCP/MCPInitializeHandler.swift` (capability declaration), `Maugham/MaughamApp.swift:312-331` area (register the three methods)
- Test: `MaughamTests/MCP/SkillsExtensionTests.swift` (create)

**Interfaces:**
- Consumes: `SkillIndex` (Task 1), `MCPRouter.register(method:handler:)`, `AnyJSON`, `MCPError`.
- Produces:

```swift
public enum SkillsExtension {
    public static let extensionId = "io.modelcontextprotocol/skills"
    public static let listMethod = "skills/list"
    public static let getMethod = "skills/get"
    public static let readMethod = "resources/read"
    static func uri(for skill: SkillIndex.Skill, file: SkillIndex.SkillFile) -> String
    // handlers, all pure over an injected SkillIndex:
    static func handleList(paramsJSON: Data?, index: SkillIndex) throws -> Data
    static func handleGet(paramsJSON: Data?, index: SkillIndex) throws -> Data
    static func handleRead(paramsJSON: Data?, index: SkillIndex) throws -> Data
}
```

- [ ] **Step 1: Pin the draft shapes**

WebFetch the SEP-2640 spec text (PR https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2640 — the added spec file in its Files view; fall back to `https://github.com/modelcontextprotocol/experimental-ext-skills` → `docs/sep-draft-skills-extension.md` raw). Record: (a) the exact capability-declaration JSON shape for extensions (where the id goes inside `capabilities`), (b) `skills/list` result field names, (c) `skills/get` param name, (d) error code for unknown skill URI. If the fetch fails or the draft has drifted incompatibly, use the shapes embedded in this task (captured from the 2026-07-18 controller read: entries `{name, description, uri, frontmatter, resources: [{uri, digest}]}`, digest `sha256:<hex>`, unknown URI → JSON-RPC `-32602`) and say so in the pin comment. Either way, the seam's header comment records: `// SEP-2640 pin: <revision/date fetched>, shapes: <one line>`.

- [ ] **Step 2: Write the failing contract tests**

Create `MaughamTests/MCP/SkillsExtensionTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import Maugham

final class SkillsExtensionTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeIndex() throws -> SkillIndex {
        let dir = temp.url.appendingPathComponent("transcribing-notebooks")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: transcribing-notebooks\ndescription: Transcribe pages.\n---\nBody here."
            .write(to: dir.appendingPathComponent("SKILL.md"),
                   atomically: true, encoding: .utf8)
        return try SkillIndex(directory: temp.url, strict: true)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_list_entryShape() throws {
        let result = try SkillsExtension.handleList(paramsJSON: nil, index: makeIndex())
        let obj = try json(result)
        let skills = try XCTUnwrap(obj["skills"] as? [[String: Any]])
        XCTAssertEqual(skills.count, 1)
        let entry = skills[0]
        XCTAssertEqual(entry["name"] as? String, "transcribing-notebooks")
        XCTAssertEqual(entry["description"] as? String, "Transcribe pages.")
        XCTAssertEqual(entry["uri"] as? String,
                       "skill://transcribing-notebooks/SKILL.md")
        let fm = try XCTUnwrap(entry["frontmatter"] as? [String: Any])
        XCTAssertEqual(fm["name"] as? String, "transcribing-notebooks")
        let resources = try XCTUnwrap(entry["resources"] as? [[String: Any]])
        XCTAssertEqual(resources[0]["uri"] as? String,
                       "skill://transcribing-notebooks/SKILL.md")
        let digest = try XCTUnwrap(resources[0]["digest"] as? String)
        XCTAssertTrue(digest.hasPrefix("sha256:"))
        XCTAssertNil(obj["nextCursor"], "single page — no cursor")
    }

    func test_read_roundTrips_andDigestMatches() throws {
        let index = try makeIndex()
        let listObj = try json(
            try SkillsExtension.handleList(paramsJSON: nil, index: index))
        let entry = (listObj["skills"] as! [[String: Any]])[0]
        let resource = (entry["resources"] as! [[String: Any]])[0]
        let uri = resource["uri"] as! String
        let digest = resource["digest"] as! String

        let params = try JSONSerialization.data(withJSONObject: ["uri": uri])
        let readObj = try json(
            try SkillsExtension.handleRead(paramsJSON: params, index: index))
        let contents = try XCTUnwrap(readObj["contents"] as? [[String: Any]])
        let text = try XCTUnwrap(contents[0]["text"] as? String)
        let computed = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual("sha256:\(computed)", digest,
                       "published digest must match read bytes")
        XCTAssertTrue(text.contains("Body here."))
    }

    func test_get_knownAndUnknown() throws {
        let index = try makeIndex()
        let known = try JSONSerialization.data(
            withJSONObject: ["uri": "skill://transcribing-notebooks/SKILL.md"])
        let obj = try json(
            try SkillsExtension.handleGet(paramsJSON: known, index: index))
        XCTAssertEqual((obj["skill"] as? [String: Any])?["name"] as? String,
                       "transcribing-notebooks")

        let unknown = try JSONSerialization.data(
            withJSONObject: ["uri": "skill://nope/SKILL.md"])
        XCTAssertThrowsError(
            try SkillsExtension.handleGet(paramsJSON: unknown, index: index))
    }

    func test_read_nonSkillUri_failsLoudly() throws {
        let params = try JSONSerialization.data(
            withJSONObject: ["uri": "file:///etc/passwd"])
        XCTAssertThrowsError(
            try SkillsExtension.handleRead(paramsJSON: params, index: makeIndex()))
    }

    func test_initialize_declaresExtension() async throws {
        let result = try await MCPInitializeHandler.handle(paramsJSON: nil)
        let obj = try json(result)
        let caps = try XCTUnwrap(obj["capabilities"] as? [String: Any])
        // Exact nesting per the SEP pin (Step 1); this asserts the id
        // appears somewhere under capabilities as a key.
        let flattened = String(data: try JSONSerialization.data(withJSONObject: caps),
                               encoding: .utf8) ?? ""
        XCTAssertTrue(flattened.contains("io.modelcontextprotocol/skills"))
    }

    func test_list_underOneMegabyte() throws {
        let result = try SkillsExtension.handleList(paramsJSON: nil, index: makeIndex())
        XCTAssertLessThan(result.count, 1_000_000)
    }
}
```

- [ ] **Step 3: Run to verify compile failure** (`SkillsExtension` undefined).

- [ ] **Step 4: Implement `Maugham/MCP/SkillsExtension.swift`**

```swift
import Foundation

/// SEP-2640 "Skills Extension" surface — Maugham-served agent skills over
/// MCP, built on the Resources primitives per the draft's direction.
///
/// // SEP-2640 pin: <fill from Step 1 — revision date + one-line shapes>
/// This file is the ONLY place SEP shapes live (spec: one seam, expect
/// drift while the SEP is unmerged). These are protocol methods like
/// tools/list — NOT tools; the tool catalog is unaffected.
public enum SkillsExtension {
    public static let extensionId = "io.modelcontextprotocol/skills"
    public static let listMethod = "skills/list"
    public static let getMethod = "skills/get"
    public static let readMethod = "resources/read"

    static func uri(for skill: SkillIndex.Skill, file: SkillIndex.SkillFile) -> String {
        "skill://\(skill.name)/\(file.relativePath)"
    }

    // MARK: - skills/list

    static func handleList(paramsJSON: Data?, index: SkillIndex) throws -> Data {
        let entries: [[String: Any]] = index.skills.map { skill in
            let (frontmatter, _) = (try? SkillIndex.parseFrontmatter(
                skill.raw, folderName: skill.name)) ?? ([:], "")
            return [
                "name": skill.name,
                "description": skill.description,
                "uri": uri(for: skill, file: skill.files[0]),
                "frontmatter": frontmatter,
                "resources": skill.files.map { file in
                    ["uri": uri(for: skill, file: file),
                     "digest": "sha256:\(file.sha256Hex)"]
                },
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: ["skills": entries], options: [.sortedKeys])
    }

    // MARK: - skills/get

    private struct URIParams: Codable { let uri: String }

    static func handleGet(paramsJSON: Data?, index: SkillIndex) throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(URIParams.self, from: data),
              let skill = skillFor(skillMdURI: params.uri, in: index) else {
            // Draft: unknown skill URI → invalid params (-32602). MCPError
            // .invalidArgument maps to that class at the router boundary.
            throw MCPError.invalidArgument(
                "Unknown skill URI. Call skills/list for served skills.")
        }
        let entryData = try handleList(paramsJSON: nil, index: index)
        let obj = try JSONSerialization.jsonObject(with: entryData) as! [String: Any]
        let entry = (obj["skills"] as! [[String: Any]])
            .first { ($0["name"] as? String) == skill.name }!
        return try JSONSerialization.data(
            withJSONObject: ["skill": entry], options: [.sortedKeys])
    }

    // MARK: - resources/read (skill:// only)

    static func handleRead(paramsJSON: Data?, index: SkillIndex) throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(URIParams.self, from: data) else {
            throw MCPError.invalidArgument("resources/read requires a uri")
        }
        guard params.uri.hasPrefix("skill://") else {
            throw MCPError.invalidArgument(
                "Maugham serves resources only under skill:// (agent skills). Got: \(params.uri)")
        }
        for skill in index.skills {
            for file in skill.files where uri(for: skill, file: file) == params.uri {
                let text = String(data: file.bytes, encoding: .utf8) ?? ""
                return try JSONSerialization.data(withJSONObject: [
                    "contents": [[
                        "uri": params.uri,
                        "mimeType": "text/markdown",
                        "text": text,
                    ]]
                ], options: [.sortedKeys])
            }
        }
        throw MCPError.invalidArgument("Unknown skill resource: \(params.uri)")
    }

    private static func skillFor(
        skillMdURI: String, in index: SkillIndex
    ) -> SkillIndex.Skill? {
        index.skills.first { skill in
            uri(for: skill, file: skill.files[0]) == skillMdURI
        }
    }
}
```

Adjust field/nesting details to match the Step-1 pin (e.g. if the draft nests the capability under `capabilities.extensions`, or names the list result differently) — the tests assert whatever the pin says; update both together and record it in the pin comment.

- [ ] **Step 5: Declare the capability + register the methods**

`MCPInitializeHandler.swift` — extend `Capabilities` per the Step-1 pin. If the pin shows extensions declared as an object keyed by id (the draft's prose default), use:

```swift
    public struct Capabilities: Codable, Equatable {
        public let tools: ToolsCapability
        public let extensions: [String: EmptyObject]
        public struct EmptyObject: Codable, Equatable {}
    }
    // in handle():
        capabilities: Capabilities(
            tools: ToolsCapability(),
            extensions: [SkillsExtension.extensionId: .init()])
```

`MaughamApp.swift` `registerTools(router:registry:)` — after the tools/call registration, add:

```swift
        router.register(method: SkillsExtension.listMethod) { params in
            try SkillsExtension.handleList(paramsJSON: params, index: try SkillIndex.bundled())
        }
        router.register(method: SkillsExtension.getMethod) { params in
            try SkillsExtension.handleGet(paramsJSON: params, index: try SkillIndex.bundled())
        }
        router.register(method: SkillsExtension.readMethod) { params in
            try SkillsExtension.handleRead(paramsJSON: params, index: try SkillIndex.bundled())
        }
```

(If `MCPToolsCallHandler` also registers per-tool methods through the same router, confirm no name collision — `skills/list` etc. contain `/` and cannot collide with tool names.)

- [ ] **Step 6: Run tests**

Run: `xcodebuild ... -only-testing:MaughamTests/MCP/SkillsExtensionTests -only-testing:MaughamTests/MCP`
Expected: PASS (existing MCP suite unaffected — tool count untouched).

- [ ] **Step 7: Commit**

```bash
git add Maugham/MCP/SkillsExtension.swift Maugham/MCP/MCPInitializeHandler.swift Maugham/MaughamApp.swift MaughamTests/MCP/SkillsExtensionTests.swift
git commit -m "feat(mcp): SEP-2640 skills extension — capability, skills/list, skills/get, skill:// resources/read"
```

---

### Task 3: get_help skills topics + tool-description nudges

**Files:**
- Modify: `Maugham/MCP/Tools/GetHelpTool.swift`, `Maugham/MCP/Tools/DocumentTools.swift` (`ReadDocumentTool.description`), `Maugham/MCP/Tools/AnnotationCreationTools.swift` (`add_comment` description)
- Test: `MaughamTests/MCP/Tools/GetHelpToolTests.swift` (extend — locate existing tests first: `grep -rn "GetHelpTool" MaughamTests | head`), tools-list snapshot tests as flagged by failures

**Interfaces:**
- Consumes: `SkillIndex` (Task 1), existing `GetHelpTool.respond(paramsJSON:index:)`.
- Produces: `GetHelpTool.respond(paramsJSON:index:skills:)` — same output shapes plus:
  - topic list response gains `"skills": [{"name": …, "description": …}]`
  - `topic == "skills"` → `{"skills": [{name, description}], "hint": "Pass a skill name as topic to load it."}`
  - `topic == <skill name>` → `{"slug": name, "markdown": <skill body — frontmatter stripped>}`
  - unknown topics still throw (help topics checked first, then skills).

- [ ] **Step 1: Write failing tests**

Append to the existing GetHelpTool test file (create `MaughamTests/MCP/Tools/GetHelpToolTests.swift` if none exists, using the injected-index pattern the tool's `respond` was built for):

```swift
    private func makeSkillsDir() throws -> SkillIndex {
        let dir = temp.url.appendingPathComponent("skills/editing-pass")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: editing-pass\ndescription: Run an editing pass.\n---\nRead craft intent first."
            .write(to: dir.appendingPathComponent("SKILL.md"),
                   atomically: true, encoding: .utf8)
        return try SkillIndex(
            directory: temp.url.appendingPathComponent("skills"), strict: true)
    }

    func test_skillsIndexTopic_listsSkills() throws {
        let data = try GetHelpTool.respond(
            paramsJSON: try JSONSerialization.data(withJSONObject: ["topic": "skills"]),
            index: makeHelpIndex(), skills: makeSkillsDir())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let skills = try XCTUnwrap(obj["skills"] as? [[String: Any]])
        XCTAssertEqual(skills.first?["name"] as? String, "editing-pass")
    }

    func test_skillName_returnsBodyWithoutFrontmatter() throws {
        let data = try GetHelpTool.respond(
            paramsJSON: try JSONSerialization.data(withJSONObject: ["topic": "editing-pass"]),
            index: makeHelpIndex(), skills: makeSkillsDir())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let md = try XCTUnwrap(obj["markdown"] as? String)
        XCTAssertTrue(md.contains("Read craft intent first."))
        XCTAssertFalse(md.contains("---"), "frontmatter stripped")
    }

    func test_topicList_includesSkillsSection() throws {
        let data = try GetHelpTool.respond(
            paramsJSON: nil, index: makeHelpIndex(), skills: makeSkillsDir())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(obj["skills"])
        XCTAssertNotNil(obj["topics"])
    }

    func test_unknownTopic_stillThrows() throws {
        XCTAssertThrowsError(try GetHelpTool.respond(
            paramsJSON: try JSONSerialization.data(withJSONObject: ["topic": "nope"]),
            index: makeHelpIndex(), skills: makeSkillsDir()))
    }
```

(`makeHelpIndex()` — reuse the file's existing fixture; if creating the file fresh, build a minimal one-topic guide dir + `index.json` in the temp dir following `HelpTopicIndex`'s format.)

- [ ] **Step 2: Run to verify failure** (new `respond` signature doesn't exist).

- [ ] **Step 3: Implement**

In `GetHelpTool.swift`, change `respond` to take the skills index and branch before the help lookup; keep the old two-arg call sites working by making the parameter non-optional and updating the one production call in `handle`:

```swift
    static func respond(
        paramsJSON: Data?, index: HelpTopicIndex, skills: SkillIndex
    ) throws -> Data {
        let topic = paramsJSON
            .flatMap { try? JSONDecoder().decode(Params.self, from: $0) }?
            .topic

        if let topic, !topic.isEmpty {
            if topic == "skills" {
                return try JSONSerialization.data(withJSONObject: [
                    "skills": skills.skills.map {
                        ["name": $0.name, "description": $0.description]
                    },
                    "hint": "Pass a skill name as topic to load its full procedure.",
                ], options: [.sortedKeys])
            }
            if let skill = skills.skill(named: topic) {
                return try JSONSerialization.data(withJSONObject: [
                    "slug": skill.name, "markdown": skill.body,
                ], options: [.sortedKeys])
            }
            let md = try index.markdown(for: topic)
            return try JSONSerialization.data(withJSONObject: [
                "slug": topic, "markdown": md,
            ], options: [.sortedKeys])
        }

        let topics = index.topics.map { ["slug": $0.slug, "title": $0.title] }
        return try JSONSerialization.data(withJSONObject: [
            "topics": topics,
            "count": topics.count,
            "skills": skills.skills.map {
                ["name": $0.name, "description": $0.description]
            },
        ], options: [.sortedKeys])
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let index = try HelpTopicIndex.bundled()
        let skills = try SkillIndex.bundled()
        return try respond(paramsJSON: paramsJSON, index: index, skills: skills)
    }
```

Update `GetHelpTool.description` (append): `" Topic \"skills\" lists Maugham's agent skills (task procedures like transcribing-notebooks, editing-pass); pass a skill name as topic to load it."`

- [ ] **Step 4: Add the two nudges**

`DocumentTools.swift` `ReadDocumentTool` description — append one sentence:
`" Transcribing notebook photos? Call get_help with topic \"transcribing-notebooks\" first for the recommended workflow."`

`AnnotationCreationTools.swift` `add_comment` description — append:
`" Running an editing pass? Call get_help with topic \"editing-pass\" first — it covers craft intent and annotation conventions."`

- [ ] **Step 5: Run MCP test surface; fix description-snapshot fallout**

Run: `xcodebuild ... -only-testing:MaughamTests/MCP`
Expected: possible failures ONLY in tests that snapshot tool descriptions (`grep -rn "Transcribing notebook\|get_help" MaughamTests/MCP` to find them); update those strings. Tool COUNT assertions must not change (48).

- [ ] **Step 6: Full suite, then commit**

```bash
git add Maugham/MCP/Tools/GetHelpTool.swift Maugham/MCP/Tools/DocumentTools.swift Maugham/MCP/Tools/AnnotationCreationTools.swift MaughamTests/MCP
git commit -m "feat(mcp): get_help serves agent skills; read_document/add_comment nudge toward them"
```

---

### Task 4: Bootstrap-skill installer + Claude Code section in the setup sheet

**Files:**
- Create: `Maugham/MCP/ClaudeCodeSkillInstall.swift`
- Modify: `Maugham/Views/HelpClaudeDesktopSheet.swift` (add a "Claude Code" section)
- Test: `MaughamTests/ClaudeCodeSkillInstallTests.swift` (create)

**Interfaces:**
- Consumes: `SkillIndex.bundled().bootstrapTemplate` (Task 1), `ClaudeDesktopConfig.State` as the pattern (not the type), `BuildVariant.current.mcpServerKey`, `Bundle.main.bundleURL`.
- Produces:

```swift
public enum ClaudeCodeSkillInstall {
    public enum State: Equatable {
        case notInstalled
        case installedCurrent
        case stale                    // installed bytes ≠ bundled template
    }
    public static let defaultSkillURL: URL   // ~/.claude/skills/maugham/SKILL.md
    public static func detect(installURL: URL, template: String) -> State
    public static func install(installURL: URL, template: String) throws
    /// The copyable CLI command for THIS build variant.
    public static func cliCommand(serverKey: String, binaryPath: String, socketPath: String?) -> String
}
```

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class ClaudeCodeSkillInstallTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private var url: URL { temp.url.appendingPathComponent("skills/maugham/SKILL.md") }

    func test_detect_notInstalled() {
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: "T"),
                       .notInstalled)
    }

    func test_install_thenCurrent_thenStale_thenUpdateRestores() throws {
        try ClaudeCodeSkillInstall.install(installURL: url, template: "T v1")
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: "T v1"),
                       .installedCurrent)
        // App update ships new template → stale
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: "T v2"),
                       .stale)
        try ClaudeCodeSkillInstall.install(installURL: url, template: "T v2")
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: "T v2"),
                       .installedCurrent)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "T v2")
    }

    func test_userEditedFile_readsAsStale_installOverwritesOnlyOnExplicitCall() throws {
        try ClaudeCodeSkillInstall.install(installURL: url, template: "T")
        try "user edited".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: "T"),
                       .stale)
        // detect() must never write:
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "user edited")
    }

    func test_cliCommand_stableAndDevShapes() {
        XCTAssertEqual(
            ClaudeCodeSkillInstall.cliCommand(
                serverKey: "maugham",
                binaryPath: "/Applications/Maugham.app/Contents/MacOS/maugham-mcp",
                socketPath: nil),
            "claude mcp add maugham /Applications/Maugham.app/Contents/MacOS/maugham-mcp")
        XCTAssertEqual(
            ClaudeCodeSkillInstall.cliCommand(
                serverKey: "maugham-dev",
                binaryPath: "/tmp/Dev.app/Contents/MacOS/maugham-mcp",
                socketPath: "/tmp/dev.sock"),
            "claude mcp add maugham-dev --env \"MAUGHAM_MCP_SOCKET=/tmp/dev.sock\" -- /tmp/Dev.app/Contents/MacOS/maugham-mcp")
    }
}
```

- [ ] **Step 2: Run to verify compile failure.**

- [ ] **Step 3: Implement `Maugham/MCP/ClaudeCodeSkillInstall.swift`**

```swift
import Foundation
import MaughamCore

/// Installs the bundled bootstrap ("router") skill into Claude Code's
/// personal skills directory and detects staleness — the same
/// detect/act/state pattern as ClaudeDesktopConfig, for a file instead of
/// JSON. detect() never writes; install() is the only mutation and only
/// runs on explicit user action from the setup sheet.
///
/// This writes OUTSIDE any Maugham project (app-config class, like the
/// Claude Desktop config) — plain FileManager by design, not the typed
/// user-content mover.
public enum ClaudeCodeSkillInstall {
    public enum State: Equatable {
        case notInstalled
        case installedCurrent
        case stale
    }

    public static let defaultSkillURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/maugham/SKILL.md")
    }()

    public static func detect(installURL: URL, template: String) -> State {
        guard let installed = try? String(contentsOf: installURL, encoding: .utf8) else {  // adr-0018-ok: app-config read, not manuscript
            return .notInstalled
        }
        return installed == template ? .installedCurrent : .stale
    }

    public static func install(installURL: URL, template: String) throws {
        try FileManager.default.createDirectory(
            at: installURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try template.write(to: installURL, atomically: true, encoding: .utf8)
    }

    public static func cliCommand(
        serverKey: String, binaryPath: String, socketPath: String?
    ) -> String {
        if let socketPath {
            return "claude mcp add \(serverKey) --env \"MAUGHAM_MCP_SOCKET=\(socketPath)\" -- \(binaryPath)"
        }
        return "claude mcp add \(serverKey) \(binaryPath)"
    }
}
```

- [ ] **Step 4: Add the Claude Code section to `HelpClaudeDesktopSheet`**

Extend the sheet (rename NOT required — it's launched from one place, `ProjectWindow.swift:115`; retitle content only). Add below the existing Desktop state views, before the error/footer:

```swift
    @State private var skillState: ClaudeCodeSkillInstall.State = .notInstalled
    @State private var skillError: String?
    @State private var cliCopied: Bool = false

    private var bootstrapTemplate: String? {
        (try? SkillIndex.bundled())?.bootstrapTemplate?.raw
    }

    private var claudeCodeCLICommand: String {
        ClaudeCodeSkillInstall.cliCommand(
            serverKey: BuildVariant.current.mcpServerKey,
            binaryPath: binaryPath,
            socketPath: BuildVariant.current == .dev
                ? BuildVariant.current.mcpSocketPath : nil)
    }

    private var claudeCodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Claude Code").font(.headline)
            HStack(spacing: 8) {
                Text(claudeCodeCLICommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Button(cliCopied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(claudeCodeCLICommand, forType: .string)
                    cliCopied = true
                }
            }
            Text("Run this once in a terminal to connect Maugham to Claude Code.")
                .font(.callout).foregroundStyle(.secondary)
            switch skillState {
            case .notInstalled:
                Button("Install Claude Code Skill") { installSkill() }
                Text("Adds a small skill so Claude automatically loads Maugham's workflows (transcription, editing passes).")
                    .font(.callout).foregroundStyle(.secondary)
            case .installedCurrent:
                Label("Maugham skill installed", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .stale:
                HStack {
                    Label("Maugham skill is out of date", systemImage: "exclamationmark.triangle")
                    Button("Update") { installSkill() }
                }
            }
            if let skillError {
                Text(skillError).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func detectSkill() {
        guard let template = bootstrapTemplate else { return }
        skillState = ClaudeCodeSkillInstall.detect(
            installURL: ClaudeCodeSkillInstall.defaultSkillURL, template: template)
    }

    private func installSkill() {
        guard let template = bootstrapTemplate else {
            skillError = "Bundled skill template missing — reinstall Maugham."
            return
        }
        do {
            try ClaudeCodeSkillInstall.install(
                installURL: ClaudeCodeSkillInstall.defaultSkillURL, template: template)
            detectSkill()
        } catch {
            skillError = error.localizedDescription
        }
    }
```

Insert `claudeCodeSection` into `body`'s VStack after the Desktop `switch state` block, and call `detectSkill()` alongside `detect()` in `.onAppear`. Check `BuildVariant` for the actual socket-path property name (`grep -n "sock" Maugham/BuildVariant.swift`) and use it; if dev's bridge default already resolves the dev socket without the env var, still include the env form — it's the explicit, correct instruction.

- [ ] **Step 5: Run tests + build**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS (install tests + full suite; sheet is UI-verified in smoke).

- [ ] **Step 6: Commit**

```bash
git add Maugham/MCP/ClaudeCodeSkillInstall.swift Maugham/Views/HelpClaudeDesktopSheet.swift MaughamTests/ClaudeCodeSkillInstallTests.swift
git commit -m "feat(mcp): Claude Code setup — bootstrap-skill installer with staleness + copyable CLI command"
```

---

### Task 5: Docs sweep + full verification

**Files:**
- Modify: `Maugham/MCP/AREA.md` (skills extension seam + SEP pin note + get_help skills topics + `docs/skills/` as a content root; skills/list is NOT a tool — count stays 48), `Maugham/Stores/AREA.md` only if it claims all app content roots (check), `docs/guide/claude-desktop.md` (mention Claude Code setup + skills briefly — guide describes what ships), `CLAUDE.md` MCP row (one clause: "+ SEP-2640 skills extension (protocol methods, not tools)"), `docs/roadmap.md`, spec status header.
- Check-only: `docs/superpowers/notes/cross-surface-contracts.md` (no phone surface — expect no change).

- [ ] **Step 1: Make the edits.** Workflow rule 10: anything this milestone made false gets fixed in the same commit. The AREA.md paragraph must name the drift risk explicitly: "SEP-2640 is unmerged; all shapes live in `SkillsExtension.swift` with a revision pin — check the SEP on next touch."

- [ ] **Step 2: Full verification**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
git diff main --stat -- Packages/MaughamCore   # must be EMPTY
```

- [ ] **Step 3: MCP pre-smoke via raw socket** (established lesson; write to the session scratchpad, not the repo):

```python
# probe: initialize shows the extension; skills/list lists 2; resources/read
# round-trips a digest-matching SKILL.md; get_help topic "skills" resolves.
# (Adapt the socket-probe pattern from
# docs/superpowers/notes/2026-07-17-claude-desktop-image-block-bug.md —
# connect to the DEV socket, send initialize / skills/list / resources/read /
# tools/call get_help {"topic":"skills"}, print shapes.)
```

Run it against the dev app; paste results in the task report.

- [ ] **Step 4: Commit**

```bash
git add Maugham/MCP/AREA.md docs CLAUDE.md
git commit -m "docs: skills-over-mcp sweep — extension seam, SEP pin, guide + roadmap"
```

- [ ] **Step 5: Whole-branch review** (workflow rule 9), then user manual smoke:

Setup sheet → Claude Code section shows CLI command (copy works) → Install skill → `~/.claude/skills/maugham/SKILL.md` exists → new Claude Code session → "transcribe the next notebook page in Playlist" → router fires → `get_help('skills')` → loads `transcribing-notebooks` → follows it (region crops, `[illegible]` rule, add_note into piece research) → editing pass on a piece reads craft intent first → annotations only.
