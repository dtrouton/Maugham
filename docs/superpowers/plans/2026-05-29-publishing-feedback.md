# Publishing Feedback Milestone — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the seven gaps Claude Desktop hit using the v1 publishing pipeline — make the emitter's behavior visible and documented, honor per-section config overrides, add cheap per-piece LaTeX overrides, spike custom fonts, and let EPUB output be inspected.

**Architecture:** Three clusters built in order. **A (visibility):** persist the compile log + body artifacts, surface warnings on success, ship a generated `EMISSION.md` contract. **B (config→emitter seam):** thread `PublishConfig` into the body emitters (the keystone), honor `title_override`/`include_in_toc`/`start_on`, add per-piece `style_file` via scoped-group `\input`, plus `set_piece_style`/`clear_piece_style` tools that reuse the trash mechanism for safety. **Fonts** is spike-gated. **EPUB** gets an open-loop source read.

**Tech Stack:** Swift + XCTest, xcodegen (`project.yml` → `./gen.sh`), tectonic (bundled), LaTeX. Reference spec: `docs/superpowers/specs/2026-05-29-publishing-feedback-design.md`.

---

## Conventions for every task

- **Build the project after adding any NEW file:** `./gen.sh` (regenerates `Maugham.xcodeproj` from `project.yml`). Modifying existing files does not need it.
- **Run the full suite:** `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
- **Run one test:** append `-only-testing:MaughamTests/<TestClass>/<testMethod>` to the test command.
- **Trust `xcodebuild`, not SourceKit/IDE diagnostics** (they complain about XCTest imports until Xcode reopens the regenerated project).
- **Never hand-edit `Maugham.xcodeproj/`** or commit anything under it — it is gitignored and generated.
- **4-char alphabet-restricted paragraph IDs** in any test crossing the `.md` ↔ op-log boundary (`ParagraphID.mint()` or a literal matching `[0123456789abcdefghjkmnpqrstvwxyz]{4}`).
- The pipeline reads `.md`/`.fountain` directly, never via `Document`.
- Branch: `feat/publishing-pipeline` (already current). Commit per task.

---

## File Structure

**Cluster A**
- Modify `Maugham/Publish/PDFCompiler.swift` — write `build/compile.log` always.
- Modify `Maugham/Publish/EPUBCompiler.swift` — write `build/compile.log` + `build/body.xhtml`.
- Modify `Maugham/Publish/CompileOrchestrator.swift` — carry `warnings` on `Outcome.completed`.
- Modify `Maugham/MCP/Tools/CompileTools.swift` — surface `warnings` + `log_path` on completed; add `build_artifacts`; remove `_diagnostic`.
- Modify `Maugham/MCP/Tools/PublishFileTools.swift` — `build_artifacts` in `list_publish_files`; document `build/` reads.
- Create `Maugham/Publish/EmissionContract.swift` — the canonical pattern→LaTeX table + `EMISSION.md` renderer.
- Create `Maugham/Resources/PublishStarter/EMISSION.md` — generated, committed, shipped in starter.
- Modify `Maugham/Publish/PublishStarter.swift` — copy `EMISSION.md` on install.
- Create `MaughamTests/Publish/EmissionContractTests.swift` — golden corpus + doc-matches-corpus test.
- Create `MaughamTests/Publish/CompileLogSurfacingTests.swift`.
- Modify `MaughamTests/MCP/Tools/PublishFileToolsTests.swift` — `build_artifacts` + completeness.

**Cluster B**
- Modify `Maugham/Publish/LaTeXBodyEmitter.swift` — `emit(_:config:)`, honor overrides, scoped-group style_file.
- Modify `Maugham/Publish/XHTMLBodyEmitter.swift` — `emit(_:config:)`, honor title_override/include_in_toc.
- Modify `Maugham/Publish/PublishConfig.swift` — add `Section.styleFile`.
- Modify `Maugham/Publish/PDFCompiler.swift`, `PreviewCompiler.swift`, `EPUBCompiler.swift` — pass `config` to emitters.
- Modify `Maugham/Resources/PublishStarter/prose.tex`, `screenplay.tex` — `\pieceheading` default-flip + `[notoc]` optional arg.
- Create `Maugham/MCP/Tools/PieceStyleTools.swift` — `set_piece_style`, `clear_piece_style`.
- Modify `Maugham/MCP/MCPTool.swift` — register the two tools.
- Modify `MaughamTests/MCP/MCPProtocolHandlersTests.swift`, `MaughamTests/MCP/MCPToolsListSmokeTest.swift` (or wherever the count assertions live) — 37 → 39.
- Create `MaughamTests/Publish/BodyEmitterOverrideTests.swift`, `MaughamTests/MCP/Tools/PieceStyleToolsTests.swift`.

**Fonts**
- Create `MaughamTests/Publish/FontSpikeTests.swift` — determinism-checked compile spike.
- Modify `Maugham/Resources/PublishStarter/preamble.tex` (if spike green) — commented fontspec block.

**EPUB** — covered by EPUBCompiler change above + `MaughamTests/Publish/EPUBBodyArtifactTests.swift`.

---

# Cluster A — Visibility

## Task A1: Persist `build/compile.log` on every PDF compile

**Files:**
- Modify: `Maugham/Publish/PDFCompiler.swift` (`compile(label:)`, around line 84 where `combinedLog` is available)
- Test: `MaughamTests/Publish/CompileLogSurfacingTests.swift` (create)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CompileLogSurfacingTests: XCTestCase {
    // Uses the same project-scaffold helper pattern as PublishingEndToEndTests.
    // After a PDF compile, build/compile.log must exist and be non-empty.
    func test_pdfCompile_writesCompileLog() async throws {
        let fix = try await PublishFixture.make()          // see note below
        _ = try await fix.compilePDF()
        let log = fix.publishRoot.appendingPathComponent("build/compile.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path),
                      "build/compile.log should exist after compile")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "compile.log should carry the tectonic log")
    }
}
```

> **Note on `PublishFixture`:** there is no shared fixture helper yet. Reuse the project-scaffolding approach already used in `MaughamTests/Publish/PublishingEndToEndTests.swift` and `PublishBodyRenderingEndToEndTests.swift` (they build a real project + config + run a compile). If those tests have an inline helper, lift it into a small `PublishFixture` in this test file; if they scaffold inline, scaffold inline here the same way. Do **not** invent new store APIs — copy the working setup.

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodebuild ... test -only-testing:MaughamTests/CompileLogSurfacingTests/test_pdfCompile_writesCompileLog`
Expected: FAIL — `compile.log` does not exist.

- [ ] **Step 3: Write `build/compile.log` in `PDFCompiler.compile`**

In `Maugham/Publish/PDFCompiler.swift`, immediately after `let diagnostics = TectonicLogParser.parse(log: invocationResult.combinedLog)` (line ~84), write the log to disk — before the exit-code branch, so it persists on both success and failure:

```swift
let logURL = build.appendingPathComponent("compile.log")
try? invocationResult.combinedLog.write(to: logURL, atomically: true, encoding: .utf8)
```

(`build` is already defined at line 39. `try?` — failing to persist the log must not fail the compile.)

- [ ] **Step 4: Run test, verify it passes**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/PDFCompiler.swift MaughamTests/Publish/CompileLogSurfacingTests.swift
git commit -m "feat(publish): persist build/compile.log on every PDF compile"
```

---

## Task A2: Surface `warnings` + `log_path` on the completed compile response

The `completed` MCP response hardcodes `"warnings": []`. `PDFCompiler.Result.warnings` already carries the parsed warnings; thread them through `Outcome.completed` to the encoder, and add `log_path`.

**Files:**
- Modify: `Maugham/Publish/CompileOrchestrator.swift` (`Outcome` enum line 5-8; `.completed` construction line 159)
- Modify: `Maugham/MCP/Tools/CompileTools.swift` (`encodeCompleted` line 6-18; `encodeOutcome` line 30-37; `encodeFailed` line 20-28)
- Test: `MaughamTests/Publish/CompileLogSurfacingTests.swift` (add a case)

- [ ] **Step 1: Write the failing test**

```swift
func test_completedResponse_surfacesWarningsAndLogPath() throws {
    let pub = Publication(
        publicationID: "pub-test00000000", version: "0.1", label: nil,
        format: .pdf, outputPath: "Exports/X-v0.1.pdf",
        snapshotID: "snap-x", checkpointID: "", republishedFrom: nil,
        compiledAt: Date(), maughamVersion: "test", tectonicVersion: "test")
    let warn = TectonicLogParser.Diagnostic(
        level: .warning, file: "prose.tex", line: 3,
        message: "Overfull \\hbox", contextLines: [])
    let data = try CompileResponseEncoder.encodeCompleted(pub, warnings: [warn])
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(obj["status"] as? String, "completed")
    XCTAssertEqual(obj["log_path"] as? String, "build/compile.log")
    let warnings = obj["warnings"] as! [[String: Any]]
    XCTAssertEqual(warnings.count, 1)
    XCTAssertEqual(warnings.first?["message"] as? String, "Overfull \\hbox")
}
```

- [ ] **Step 2: Run test, verify it fails**

Expected: FAIL — `encodeCompleted` currently takes only `Publication` (no `warnings:` label) → compile error in the test target, which counts as a red.

- [ ] **Step 3: Thread warnings through `Outcome` and the encoder**

In `CompileOrchestrator.swift`, change the enum case:

```swift
public enum Outcome: Sendable {
    case completed(Publication, warnings: [TectonicLogParser.Diagnostic])
    case failed(errors: [TectonicLogParser.Diagnostic], logExcerpt: String)
}
```

At line 159 change `return .completed(pub)` → `return .completed(pub, warnings: warnings)`.

In `CompileTools.swift`, update the encoder:

```swift
static func encodeCompleted(
    _ pub: Publication, warnings: [TectonicLogParser.Diagnostic]
) throws -> Data {
    var obj: [String: Any] = [
        "status": "completed",
        "version": pub.version,
        "format": pub.format.rawValue,
        "output_path": pub.outputPath,
        "checkpoint_id": pub.checkpointID,
        "log_path": "build/compile.log",
        "warnings": warnings.map { encode(diag: $0) },
        "errors": []
    ]
    if let label = pub.label { obj["label"] = label }
    return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
}
```

And in `encodeOutcome`:

```swift
case .completed(let pub, let warnings):
    return try encodeCompleted(pub, warnings: warnings)
```

Also add `"log_path": "build/compile.log"` to `encodeFailed`'s dictionary.

> **Find the other `encodeCompleted` / `.completed` call sites.** Grep before compiling: `grep -rn "encodeCompleted\|\.completed(" Maugham/`. The `CompileStatusTool` path renders a *job's* completed state (the `CompileJob.completed(outputPath:warnings:errors:)` case carries warnings — see `CompileJob.swift:18`). Make the status-tool path surface the job's warnings the same way (build a `[String:Any]` with `warnings`/`log_path`). `Republisher` (`Republisher.swift`) has a parallel `Outcome`-shaped return — update its `.completed` construction too if it shares this enum; if it has its own, leave it.

- [ ] **Step 4: Run the full suite, verify green**

Run the full test command (the enum change touches several files; let the compiler find them all). Fix every `.completed(pub)` to `.completed(pub, warnings:)`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/CompileOrchestrator.swift Maugham/MCP/Tools/CompileTools.swift MaughamTests/Publish/CompileLogSurfacingTests.swift
git commit -m "feat(publish): surface warnings + log_path on completed compile"
```

---

## Task A3: `build_artifacts` in `list_publish_files` + remove `_diagnostic` + completeness test

**Files:**
- Modify: `Maugham/MCP/Tools/PublishFileTools.swift` (`ListPublishFilesTool.handle`, lines 85-180)
- Modify: `Maugham/MCP/Tools/PublishFileTools.swift` (`ReadPublishFileTool.description`, line 187 — note `build/` readability)
- Test: `MaughamTests/MCP/Tools/PublishFileToolsTests.swift` (add cases)

- [ ] **Step 1: Write the failing tests**

```swift
func test_listPublishFiles_surfacesBuildArtifactsSeparately() async throws {
    // Scaffold a project with a publish dir containing a top-level file and a build/ file.
    let (registry, projectID, publishRoot) = try await makePublishProject()  // existing helper in this file
    try "x".write(to: publishRoot.appendingPathComponent("prose.tex"), atomically: true, encoding: .utf8)
    let build = publishRoot.appendingPathComponent("build")
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try "BODY".write(to: build.appendingPathComponent("body.tex"), atomically: true, encoding: .utf8)

    let params = #"{"project_id":"\#(projectID)"}"#.data(using: .utf8)
    let data = try await ListPublishFilesTool.handle(paramsJSON: params, registry: registry)
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    let files = obj["files"] as! [[String: Any]]
    XCTAssertTrue(files.contains { $0["path"] as? String == "prose.tex" })
    XCTAssertFalse(files.contains { ($0["path"] as? String)?.hasPrefix("build/") ?? false },
                   "build/ stays out of the main files list")

    let artifacts = obj["build_artifacts"] as! [[String: Any]]
    XCTAssertTrue(artifacts.contains { $0["path"] as? String == "build/body.tex" })

    XCTAssertNil(obj["_diagnostic"], "diagnostic instrumentation must be removed")
}
```

> Match `makePublishProject()` to whatever scaffolding the existing `PublishFileToolsTests` already use (the file has working setup — reuse it; do not invent a new registry API).

- [ ] **Step 2: Run, verify fail**

Expected: FAIL — `build_artifacts` key absent; `_diagnostic` present.

- [ ] **Step 3: Rewrite `ListPublishFilesTool.handle`**

Replace the body (lines 85-180) with a clean enumerator that splits top-level files from `build/` artifacts and drops the `_diagnostic` block:

```swift
@MainActor
public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
    guard let json = paramsJSON else { throw MCPError.invalidArgument("missing params") }
    let params = try JSONDecoder().decode(Params.self, from: json)
    guard let entry = registry.lookup(id: params.projectID) else {
        throw MCPError.invalidArgument("unknown project_id")
    }
    let publishRoot = entry.url.appendingPathComponent(".maugham/publish", isDirectory: true)
    var files: [[String: Any]] = []
    var buildArtifacts: [[String: Any]] = []

    if FileManager.default.fileExists(atPath: publishRoot.path),
       let enumerator = FileManager.default.enumerator(
        at: publishRoot,
        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]) {
        let rootPath = publishRoot.standardizedFileURL.path + "/"
        let iso = ISO8601DateFormatter()
        while let item = enumerator.nextObject() as? URL {
            let abs = item.standardizedFileURL.path
            guard abs.hasPrefix(rootPath) else { continue }
            let res = try? item.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard res?.isRegularFile == true else { continue }
            let rel = String(abs.dropFirst(rootPath.count))
            let record: [String: Any] = [
                "path": rel,
                "size": res?.fileSize ?? 0,
                "modified_at": res?.contentModificationDate.map { iso.string(from: $0) } ?? ""
            ]
            if rel.hasPrefix("build/") { buildArtifacts.append(record) }
            else { files.append(record) }
        }
    }
    files.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
    buildArtifacts.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
    return try JSONSerialization.data(
        withJSONObject: ["files": files, "build_artifacts": buildArtifacts],
        options: [.sortedKeys])
}
```

Update `ListPublishFilesTool.description` to mention `build_artifacts`. Update `ReadPublishFileTool.description` to add: "Files under build/ (body.tex, body.xhtml, compile.log) are readable for diagnosing emitter/compile output."

> **The subset symptom (spec §4.4):** this rewrite removes `.skipsHiddenFiles`? No — keep it (publish files are not dotfiles; the parent `.maugham` is already inside the enumerated root). The completeness test below is the regression net. If it surfaces a real missing-file case, the cause is almost certainly a genuinely hidden file the writer expects — handle by documenting that publish files must not start with `.`, not by removing the skip (which would surface `.DS_Store`).

- [ ] **Step 4: Add the completeness regression test**

```swift
func test_listPublishFiles_returnsEveryRegularFile() async throws {
    let (registry, projectID, publishRoot) = try await makePublishProject()
    let names = ["template.tex", "prose.tex", "config.json", "EMISSION.md", "pieces/tribute.tex"]
    for n in names {
        let u = publishRoot.appendingPathComponent(n)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: u, atomically: true, encoding: .utf8)
    }
    let params = #"{"project_id":"\#(projectID)"}"#.data(using: .utf8)
    let data = try await ListPublishFilesTool.handle(paramsJSON: params, registry: registry)
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let listed = Set((obj["files"] as! [[String: Any]]).compactMap { $0["path"] as? String })
    XCTAssertTrue(listed.isSuperset(of: Set(names)), "every regular file must be listed; missing: \(Set(names).subtracting(listed))")
}
```

- [ ] **Step 5: Run both tests, verify pass; commit**

```bash
git add Maugham/MCP/Tools/PublishFileTools.swift MaughamTests/MCP/Tools/PublishFileToolsTests.swift
git commit -m "feat(publish): list_publish_files surfaces build_artifacts; drop diagnostics"
```

---

## Task A4: `EmissionContract` + generated `EMISSION.md` + ship in starter

The contract doc is a generated build artifact: a single Swift source-of-truth table renders the doc, a golden test asserts the committed `EMISSION.md` matches, and `PublishStarter` ships it.

**Files:**
- Create: `Maugham/Publish/EmissionContract.swift`
- Create: `Maugham/Resources/PublishStarter/EMISSION.md`
- Modify: `Maugham/Publish/PublishStarter.swift`
- Create: `MaughamTests/Publish/EmissionContractTests.swift`

- [ ] **Step 1: Write `EmissionContract.swift`**

A single enum holding: the example corpus (input snippet → emitted `body.tex` line, produced by calling the *real* `LaTeXBodyEmitter`/`ProjectASTBuilder` so examples can't lie), the negative-space list, the locality-criterion prose, the style_file constraint contract, and a `renderMarkdown()` that assembles `EMISSION.md`.

```swift
import Foundation

/// Source of truth for the body-emission contract documented in EMISSION.md.
/// `renderMarkdown()` is the doc; `EmissionContractTests` asserts the committed
/// Resources/PublishStarter/EMISSION.md matches, so the doc cannot drift.
public enum EmissionContract {

    /// One positive-space example: a source snippet and the LaTeX the emitter
    /// produces for it. `latex` is computed by running the real emitter so the
    /// table is generated, never hand-transcribed.
    public struct Example { public let label: String; public let source: String }

    public static let proseExamples: [Example] = [
        .init(label: "Paragraph", source: "A plain sentence."),
        .init(label: "Heading level 1", source: "# Chapter Title"),
        .init(label: "Blockquote with emphasis", source: "> A quote with *italic* inside."),
        .init(label: "Scene break", source: "***"),
        .init(label: "Inline mix", source: "Text with *em*, **strong**, _under_, `code`."),
        .init(label: "Anchor-only paragraph", source: "<!-- ¶ab12 -->"),
    ]

    /// Render the body.tex the emitter actually produces for a prose snippet.
    static func emittedProse(_ source: String) -> String {
        let ast = ProjectASTBuilder.build(from: SinglePieceSource(
            pieceID: "ex01", title: "Example", mode: .prose, text: source))
        // Emit and strip the section wrapper so the example shows the node-level output.
        return LaTeXBodyEmitter.emit(ast, config: PublishConfig())
    }

    public static func renderMarkdown() -> String {
        var out = "# EMISSION.md — Body Emission Contract\n\n"
        out += "_Generated from `EmissionContract.swift`. Do not hand-edit; "
        out += "edit the Swift source and regenerate (the test enforces the match)._\n\n"
        out += localityCriterion + "\n\n"
        out += "## Positive space — recognized patterns\n\n"
        for ex in proseExamples {
            out += "### \(ex.label)\n\n```\n\(ex.source)\n```\n\nemits:\n\n```latex\n\(emittedProse(ex.source))\n```\n\n"
        }
        out += negativeSpace + "\n\n"
        out += styleFileContract + "\n\n"
        out += recoveryNote + "\n"
        return out
    }

    static let localityCriterion = """
    ## Where does a typographic move live? The locality criterion

    > Does honoring this override require **global** knowledge the piece cannot \
    have on its own? **Global → config. Local → template (per-piece `.tex`).**

    - `start_on` (recto/verso), `include_in_toc` → **config** (need page / ToC global state).
    - `title_override` → **config** (a declaration, not typography).
    - Numbering visibility, isolating the final line, drop caps, ornaments → \
    **template** — do them in a per-piece `.tex` (see below).
    """

    static let negativeSpace = """
    ## Negative space — patterns the emitter does NOT give special meaning

    Anything not listed under "positive space" passes through as its constituent \
    text/inline nodes. Specifically, and from real use:

    - A line beginning with `:` (e.g. `: foo`) → literal paragraph text. No \
    definition-list semantics.
    - `:*emphasis*` → a literal colon then `\\emph{emphasis}`. No marker semantics.
    - `**Context: 0%**` → `\\textbf{Context: 0\\%}`. There is no progress-meter \
    or status rendering — it is ordinary bold text.

    If you need any of these to render specially, that's a per-piece `.tex` hook.
    """

    static let styleFileContract = """
    ## Per-piece style files (`style_file`)

    Set via `set_piece_style`. Sourced inside a TeX group, **before** the piece's \
    environment opens:

    ```latex
    \\begingroup
      \\input{pieces/<file>}      % runs here, at source time
      \\begin{prose}{Title} ... \\end{prose}
    \\endgroup
    ```

    A per-piece file **MAY**: `\\renewcommand`, `\\newcommand`, `\\definecolor`, \
    `\\renewenvironment`, and emit arbitrary LaTeX at file top (e.g. a per-piece \
    **title page** — put it before any `\\renewcommand`).

    A per-piece file **MAY NOT**: `\\usepackage` (packages load only in the \
    preamble) or change `\\geometry` (page geometry is preamble-level and does \
    not revert at `\\endgroup`). These are collection-level — edit `preamble.tex`.
    """

    static let recoveryNote = """
    ## Recovery

    Overwriting or clearing a style file moves the prior version to Maugham's \
    trash (`.maugham/trash/`, 30-day sweep, undo via ⌘⌥Z). There is **no git** in \
    this workflow; the trash is the recovery path. `build/body.tex`, \
    `build/body.xhtml`, and `build/compile.log` are readable via `read_publish_file` \
    for diagnosing what the emitter and compiler produced.
    """
}

/// Minimal single-piece AST source for generating contract examples.
struct SinglePieceSource: ProjectASTBuilder.Source {
    let pieceID: String; let title: String; let mode: ProjectAST.Mode; let text: String
    func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
        [.init(pieceID: pieceID, title: title, mode: mode, displayText: text)]
    }
}
```

> `LaTeXBodyEmitter.emit(ast, config:)` and `PublishConfig()` are introduced in Cluster B. **Task A4 depends on Task B1** (the config-threaded emitter signature). Sequence B1 before A4, or temporarily call the old `emit(ast)` and switch in B1. Recommended: do **A1–A3 first, then B1, then come back for A4** — noted in the build order.

- [ ] **Step 2: Generate and commit `EMISSION.md`**

Write the test first (Step 3), run it once in "regenerate" mode to produce the file, eyeball it, commit. Concretely: the test computes `EmissionContract.renderMarkdown()` and compares to the committed file; on first run, have it write the file if missing.

- [ ] **Step 3: Write the golden test**

```swift
import XCTest
@testable import Maugham

final class EmissionContractTests: XCTestCase {
    /// Path to the committed starter copy.
    private var docURL: URL {
        URL(fileURLWithPath: #filePath)            // .../MaughamTests/Publish/EmissionContractTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Resources/PublishStarter/EMISSION.md")
    }

    func test_committedEmissionDoc_matchesGeneratedContract() throws {
        let generated = EmissionContract.renderMarkdown()
        if !FileManager.default.fileExists(atPath: docURL.path) {
            try generated.write(to: docURL, atomically: true, encoding: .utf8)
            XCTFail("EMISSION.md did not exist — wrote it. Re-run; commit the file.")
            return
        }
        let committed = try String(contentsOf: docURL, encoding: .utf8)
        XCTAssertEqual(committed, generated,
            "EMISSION.md is stale. Regenerate: the emitter changed but the doc didn't. "
          + "Delete Maugham/Resources/PublishStarter/EMISSION.md and re-run this test to regenerate.")
    }
}
```

> `#filePath`-relative navigation matches how repo-file-touching tests locate sources here; if other tests use a different anchor (e.g. an env var or `Bundle`), match theirs. Verify by grepping `#filePath` in `MaughamTests/`.

- [ ] **Step 4: Run, regenerate, commit `EMISSION.md`; run again → PASS**

```bash
./gen.sh   # EmissionContract.swift + the new test are new files
xcodebuild ... test -only-testing:MaughamTests/EmissionContractTests
# first run writes + fails; commit EMISSION.md; second run passes
```

- [ ] **Step 5: Ship `EMISSION.md` in the starter on install**

In `Maugham/Publish/PublishStarter.swift`, find where the starter files are copied into `.maugham/publish/` (the existing list of `template.tex`, `prose.tex`, …). Add `EMISSION.md` to that copy set. Add/extend a `PublishStarterTests` assertion that an installed project contains `EMISSION.md`.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Publish/EmissionContract.swift Maugham/Resources/PublishStarter/EMISSION.md Maugham/Publish/PublishStarter.swift MaughamTests/Publish/EmissionContractTests.swift MaughamTests/Publish/PublishStarterTests.swift
git commit -m "feat(publish): generated EMISSION.md contract shipped in starter"
```

---

# Cluster B — config→emitter seam

## Task B1: Thread `PublishConfig` into the body emitters (keystone, no behavior change)

Pure refactor: change the signatures, pass config from callers, keep output byte-identical. Existing emitter tests stay green.

**Files:**
- Modify: `Maugham/Publish/LaTeXBodyEmitter.swift` (`emit` line 11)
- Modify: `Maugham/Publish/XHTMLBodyEmitter.swift` (`emit` line 8)
- Modify: `Maugham/Publish/PDFCompiler.swift` (line 48), `PreviewCompiler.swift`, `EPUBCompiler.swift` (line 48)
- Test: existing `MaughamTests/Publish/*EmitterTests*` (update call sites)

- [ ] **Step 1: Change signatures with a defaulted config so existing callers compile**

```swift
// LaTeXBodyEmitter
public static func emit(_ ast: ProjectAST, config: PublishConfig = PublishConfig()) -> String { ... }
// XHTMLBodyEmitter
public static func emit(_ ast: ProjectAST, config: PublishConfig = PublishConfig()) -> String { ... }
```

- [ ] **Step 2: Pass real config from the compilers**

`PDFCompiler.swift:48` → `LaTeXBodyEmitter.emit(ast, config: config)`. `EPUBCompiler.swift:48` → `XHTMLBodyEmitter.emit(ProjectAST(sections: [s]), config: config)`. `PreviewCompiler` → pass its `config` likewise.

- [ ] **Step 3: Run the full suite, verify still green (no behavior change yet)**

Expected: PASS — config is accepted but unused.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Publish/LaTeXBodyEmitter.swift Maugham/Publish/XHTMLBodyEmitter.swift Maugham/Publish/PDFCompiler.swift Maugham/Publish/EPUBCompiler.swift Maugham/Publish/PreviewCompiler.swift
git commit -m "refactor(publish): thread PublishConfig into body emitters (no behavior change)"
```

---

## Task B2: Add `Section.styleFile` to the config schema

**Files:**
- Modify: `Maugham/Publish/PublishConfig.swift` (`Section` struct, lines 144-171)
- Modify: `Maugham/Publish/PublishConfigValidator.swift` (if it allow-lists section keys)
- Test: `MaughamTests/PublishConfigTests.swift`

- [ ] **Step 1: Write the failing round-trip test**

```swift
func test_section_styleFile_roundTrips() throws {
    var cfg = PublishConfig()
    cfg.sections["ab12"] = .init(titleOverride: nil, startOn: .any, includeInToc: true, styleFile: "tribute.tex")
    let data = try JSONEncoder().encode(cfg)
    let back = try JSONDecoder().decode(PublishConfig.self, from: data)
    XCTAssertEqual(back.sections["ab12"]?.styleFile, "tribute.tex")
    // Explicit-null shape preserved when absent:
    XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"style_file\""))
}
```

- [ ] **Step 2: Run, verify fail** (no `styleFile` member).

- [ ] **Step 3: Add the field**

In `Section` (PublishConfig.swift), add `public var styleFile: String?`, extend `init` with `styleFile: String? = nil`, add `try c.encodeAlways(styleFile, forKey: .styleFile)` to `encode`, and add `case styleFile = "style_file"` to `CodingKeys`.

> If `PublishConfigValidator` rejects unknown section keys (check it — the spec's v1 said "schema validation rejects unknown fields"), add `style_file` to the permitted set so `set_publish_config` patches don't bounce.

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/PublishConfig.swift Maugham/Publish/PublishConfigValidator.swift MaughamTests/PublishConfigTests.swift
git commit -m "feat(publish): add per-section style_file to publish config"
```

---

## Task B3: Honor `title_override`, `include_in_toc`, `start_on` in `LaTeXBodyEmitter`

**Files:**
- Modify: `Maugham/Publish/LaTeXBodyEmitter.swift` (`emit(section:isFirst:into:)` lines 21-39)
- Test: `MaughamTests/Publish/BodyEmitterOverrideTests.swift` (create)

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class BodyEmitterOverrideTests: XCTestCase {
    private func proseAST(pieceID: String, title: String, _ text: String) -> ProjectAST {
        ProjectASTBuilder.build(from: SinglePieceSource(pieceID: pieceID, title: title, mode: .prose, text: text))
    }

    func test_titleOverride_replacesSectionTitle() {
        var cfg = PublishConfig(); cfg.sections["ab12"] = .init(titleOverride: "New Title")
        let out = LaTeXBodyEmitter.emit(proseAST(pieceID: "ab12", title: "Old Title", "Body."), config: cfg)
        XCTAssertTrue(out.contains("\\begin{prose}{New Title}"))
        XCTAssertFalse(out.contains("Old Title"))
    }

    func test_includeInTocFalse_emitsNotocOptionalArg() {
        var cfg = PublishConfig(); cfg.sections["ab12"] = .init(includeInToc: false)
        let out = LaTeXBodyEmitter.emit(proseAST(pieceID: "ab12", title: "T", "Body."), config: cfg)
        XCTAssertTrue(out.contains("\\begin{prose}[notoc]{T}"))
    }

    func test_startOnRecto_emitsCleardoublepage() {
        var cfg = PublishConfig()
        cfg.sections["aa11"] = .init(); cfg.sections["bb22"] = .init(startOn: .recto)
        let ast = ProjectAST(sections: [
            proseAST(pieceID: "aa11", title: "One", "A.").sections[0],
            proseAST(pieceID: "bb22", title: "Two", "B.").sections[0],
        ])
        let out = LaTeXBodyEmitter.emit(ast, config: cfg)
        XCTAssertTrue(out.contains("\\cleardoublepage"), "recto piece should clear to a recto page")
    }
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement override-aware section emission**

Rewrite `emit(section:isFirst:into:)` to look up `config.sections[section.pieceID]`:

```swift
private static func emit(section: ProjectAST.Section, isFirst: Bool,
                         config: PublishConfig, into out: inout [String]) {
    let ov = config.sections[section.pieceID]
    if !isFirst {
        switch ov?.startOn ?? .any {
        case .recto:  out.append("\\cleardoublepage")
        case .verso:  out.append("\\cleardoublepage\\thispagestyle{empty}\\null\\clearpage") // crude verso; template may refine
        case .any:    out.append("\\clearpage")
        }
    }
    let rawTitle = ov?.titleOverride ?? section.title
    let title = LaTeXEscape.escape(rawTitle)
    let opt = (ov?.includeInToc == false) ? "[notoc]" : ""
    switch section.mode {
    case .prose:
        out.append("\\begin{prose}\(opt){\(title)}")
        for node in section.nodes { emit(node: node, into: &out) }
        out.append("\\end{prose}")
    case .fountain:
        out.append("\\begin{screenplay}\(opt){\(title)}")
        for node in section.nodes { emit(node: node, into: &out) }
        out.append("\\end{screenplay}")
    }
}
```

Thread `config` from the top-level `emit` loop into this call (the loop already exists at lines 11-17 — pass `config:` down).

- [ ] **Step 4: Run, verify pass.** Then run the full suite (the `[notoc]` optional arg requires Task B5's starter env change to actually *compile* a PDF — that's a later task; emitter tests don't compile LaTeX, so they pass now).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/LaTeXBodyEmitter.swift MaughamTests/Publish/BodyEmitterOverrideTests.swift
git commit -m "feat(publish): honor title_override/include_in_toc/start_on in LaTeX emitter"
```

---

## Task B4: Honor `title_override` + `include_in_toc` in `XHTMLBodyEmitter`

EPUB has no pages, so `start_on`/`style_file` are no-ops; only title and ToC-ish title apply.

**Files:**
- Modify: `Maugham/Publish/XHTMLBodyEmitter.swift` (`emit(section:into:)` lines 16-26)
- Test: `MaughamTests/Publish/BodyEmitterOverrideTests.swift` (add)

- [ ] **Step 1: Failing test**

```swift
func test_xhtml_titleOverride_replacesH1() {
    var cfg = PublishConfig(); cfg.sections["ab12"] = .init(titleOverride: "New")
    let ast = ProjectASTBuilder.build(from: SinglePieceSource(pieceID: "ab12", title: "Old", mode: .prose, text: "Body."))
    let out = XHTMLBodyEmitter.emit(ast, config: cfg)
    XCTAssertTrue(out.contains("<h1>New</h1>"))
    XCTAssertFalse(out.contains("Old"))
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** — in `emit(section:into:)`, resolve `let title = config.sections[section.pieceID]?.titleOverride ?? section.title` and use it for the `<h1>`. For `include_in_toc == false`, add `data-toc="false"` to the `<section>` element so `styles.css` / the OPF nav can choose to skip it (document this attribute in `EMISSION.md`'s EPUB note — add it to `EmissionContract`). Thread `config` through `emit(_:config:)`.

- [ ] **Step 4: Run, verify pass; regenerate EMISSION.md if the EPUB note changed; commit**

```bash
git add Maugham/Publish/XHTMLBodyEmitter.swift Maugham/Publish/EmissionContract.swift Maugham/Resources/PublishStarter/EMISSION.md MaughamTests/Publish/BodyEmitterOverrideTests.swift
git commit -m "feat(publish): honor title_override/include_in_toc in XHTML emitter"
```

---

## Task B5: Starter default-flip (`\pieceheading`) + `[notoc]` optional env arg

**Files:**
- Modify: `Maugham/Resources/PublishStarter/prose.tex`
- Modify: `Maugham/Resources/PublishStarter/screenplay.tex`
- Test: `MaughamTests/Publish/PublishingEndToEndTests.swift` (extend) or a new render-guard test

- [ ] **Step 1: Rewrite `prose.tex`'s environment**

```latex
% Piece title: unnumbered by default (the common book case). A piece that
% wants a number opts in via its style_file: \renewcommand{\pieceheading}[1]{\section{#1}}
\newcommand{\pieceheading}[1]{\section*{#1}\addcontentsline{toc}{section}{#1}}
\newcommand{\pieceheadingnotoc}[1]{\section*{#1}}

% Optional first arg `notoc` suppresses the ToC entry (emitted by Maugham when
% a section sets include_in_toc:false).
\newenvironment{prose}[2][toc]
  {\ifx\relax#1\relax\pieceheading{#2}\else
     \def\tmptoc{notoc}\def\tmparg{#1}%
     \ifx\tmparg\tmptoc \pieceheadingnotoc{#2}\else \pieceheading{#2}\fi\fi}
  {}

\newcommand{\scenebreak}{%
  \par\vspace{1em}\centering * * *\vspace{1em}\par\noindent}
```

> Verify the `\ifx` optional-arg branch compiles under tectonic; if the `\ifx` dance is fragile, the simpler robust form is two environments selected by the emitter — but prefer the optional-arg form per spec §5.2. Test by compiling (Step 3).

- [ ] **Step 2: Mirror in `screenplay.tex`** — replace the `\section{#1}` inside `\NewEnviron{screenplay}[1]` with `\pieceheading{#1}` and add the same `\pieceheading`/`\pieceheadingnotoc` definitions + optional-arg handling (using `environ`'s optional-arg support; check `\NewEnviron`'s optional-arg syntax).

- [ ] **Step 3: Add a render-guard test** that compiles a 2-piece project (one `include_in_toc:false`) and asserts a PDF is produced with no compile errors. Reuse the end-to-end compile path. Assert the unnumbered default by checking `build/body.tex` contains `\begin{prose}{` (no number leaks into source) — the visual numbering check is covered by "compiles + a piece opting into `\section` renders".

- [ ] **Step 4: Run, verify pass; commit**

```bash
git add Maugham/Resources/PublishStarter/prose.tex Maugham/Resources/PublishStarter/screenplay.tex MaughamTests/Publish/PublishingEndToEndTests.swift
git commit -m "feat(publish): starter piece titles unnumbered by default; [notoc] arg"
```

---

## Task B6: `style_file` scoped-group emission + scope-reversion regression test

**Files:**
- Modify: `Maugham/Publish/LaTeXBodyEmitter.swift` (`emit(section:...)`)
- Test: `MaughamTests/Publish/BodyEmitterOverrideTests.swift` (add)

- [ ] **Step 1: Failing tests (shape + the named reversion invariant)**

```swift
func test_styleFile_wrapsSectionInScopedGroupBeforeEnvironment() {
    var cfg = PublishConfig(); cfg.sections["ab12"] = .init(styleFile: "tribute.tex")
    let ast = ProjectASTBuilder.build(from: SinglePieceSource(pieceID: "ab12", title: "T", mode: .prose, text: "Body."))
    let out = LaTeXBodyEmitter.emit(ast, config: cfg)
    let g = out.range(of: "\\begingroup")!
    let inp = out.range(of: "\\input{pieces/tribute.tex}")!
    let env = out.range(of: "\\begin{prose}")!
    let end = out.range(of: "\\endgroup")!
    XCTAssertTrue(g.lowerBound < inp.lowerBound, "begingroup before input")
    XCTAssertTrue(inp.lowerBound < env.lowerBound, "input before environment (title-page pattern depends on this)")
    XCTAssertTrue(env.lowerBound < end.lowerBound, "endgroup after environment")
}

/// THE INVARIANT THE SCOPED GROUP EXISTS FOR. If someone "optimizes" by
/// hoisting \input out of \begingroup, a styled piece leaks its redefinitions
/// into the next piece. This guards that.
func test_styleFile_scopeDoesNotLeakIntoNextPiece() {
    var cfg = PublishConfig(); cfg.sections["aa11"] = .init(styleFile: "x.tex")  // bb22 has none
    let ast = ProjectAST(sections: [
        ProjectASTBuilder.build(from: SinglePieceSource(pieceID: "aa11", title: "One", mode: .prose, text: "A.")).sections[0],
        ProjectASTBuilder.build(from: SinglePieceSource(pieceID: "bb22", title: "Two", mode: .prose, text: "B.")).sections[0],
    ])
    let out = LaTeXBodyEmitter.emit(ast, config: cfg)
    // The styled piece is fully bracketed; the unstyled piece is OUTSIDE any group.
    let endgroup = out.range(of: "\\endgroup")!
    let twoEnv = out.range(of: "\\begin{prose}{Two}")!
    XCTAssertTrue(endgroup.lowerBound < twoEnv.lowerBound, "second piece must follow \\endgroup (style scope closed)")
    // And the second piece is not itself wrapped in a group (no styleFile).
    let after = String(out[twoEnv.lowerBound...])
    XCTAssertFalse(after.contains("\\input{pieces/"), "unstyled piece must not source any style file")
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement scoped-group wrapping** in `emit(section:...)`: when `ov?.styleFile` is non-nil, emit `\begingroup`, `\input{pieces/<file>}`, then the page-break + environment, then `\endgroup`. When nil, emit as today. Put the page-break (`\clearpage`/`\cleardoublepage`) *inside* the group, after the input, before `\begin`.

- [ ] **Step 4: Run, verify pass; commit**

```bash
git add Maugham/Publish/LaTeXBodyEmitter.swift MaughamTests/Publish/BodyEmitterOverrideTests.swift
git commit -m "feat(publish): scoped-group style_file emission + scope-reversion guard"
```

---

## Task B7: `set_piece_style` tool (write + wire + trash-on-overwrite)

**Files:**
- Create: `Maugham/MCP/Tools/PieceStyleTools.swift`
- Test: `MaughamTests/MCP/Tools/PieceStyleToolsTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import Maugham

final class PieceStyleToolsTests: XCTestCase {
    func test_setPieceStyle_writesFileAndWiresConfig() async throws {
        let (registry, projectID, publishRoot) = try await makePublishProject()  // reuse PublishFileToolsTests helper pattern
        let params = #"{"project_id":"\#(projectID)","piece_id":"ab12","content":"\\renewcommand{\\pieceheading}[1]{\\section{#1}}","filename":"tribute.tex"}"#.data(using: .utf8)
        _ = try await SetPieceStyleTool.handle(paramsJSON: params, registry: registry)

        let file = publishRoot.appendingPathComponent("pieces/tribute.tex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let store = PublishConfigStore(projectURL: registry.lookup(id: projectID)!.url)
        let cfg = try await store.load()
        XCTAssertEqual(cfg?.sections["ab12"]?.styleFile, "tribute.tex")
    }

    func test_setPieceStyle_overwriteSendsPriorToTrash() async throws {
        let (registry, projectID, publishRoot) = try await makePublishProject()
        let base = #"{"project_id":"\#(projectID)","piece_id":"ab12","filename":"tribute.tex","content":"%v1"}"#.data(using: .utf8)
        _ = try await SetPieceStyleTool.handle(paramsJSON: base, registry: registry)
        let base2 = #"{"project_id":"\#(projectID)","piece_id":"ab12","filename":"tribute.tex","content":"%v2"}"#.data(using: .utf8)
        _ = try await SetPieceStyleTool.handle(paramsJSON: base2, registry: registry)

        // File now holds v2; the v1 copy is recoverable from trash.
        let file = publishRoot.appendingPathComponent("pieces/tribute.tex")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "%v2")
        let trashRoot = registry.lookup(id: projectID)!.url.appendingPathComponent(".maugham/trash")
        let dump = try recursiveContents(of: trashRoot)
        XCTAssertTrue(dump.contains("%v1"), "prior version should be in trash")
    }
}
```

> `recursiveContents` is a tiny test helper that reads all files under a dir into a joined string — add it to the test file.

- [ ] **Step 2: Run, verify fail** (tool doesn't exist).

- [ ] **Step 3: Implement `SetPieceStyleTool`**

```swift
public enum SetPieceStyleTool: MCPTool {
    public static let method = "set_piece_style"
    public static let description =
    "Create or replace a per-piece LaTeX style file under .maugham/publish/pieces/ AND wire it to the section in one call. filename defaults to a slug of the piece title. Overwriting an existing file moves the prior version to trash (recoverable). Per-piece files may \\renewcommand/\\definecolor/redefine environments and emit a title page at file top; they may NOT \\usepackage or change \\geometry (those are preamble-level). See EMISSION.md."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "piece_id":{"type":"string"},
       "content":{"type":"string"},
       "filename":{"type":"string","description":"Optional .tex filename under pieces/. Defaults to a deterministic slug of the piece title."}
     },"required":["project_id","piece_id","content"]}
    """

    struct Params: Codable {
        let projectID: String; let pieceID: String; let content: String; let filename: String?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"; case pieceID = "piece_id"; case content; case filename
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidArgument("missing params") }
        let p = try JSONDecoder().decode(Params.self, from: json)
        guard let entry = registry.lookup(id: p.projectID) else {
            throw MCPError.invalidArgument("unknown project_id")
        }
        // Resolve filename: explicit, else slug of the section's title from config, else piece_id.
        let store = PublishConfigStore(projectURL: entry.url)
        let cfg = (try await store.load()) ?? PublishConfig()
        let title = cfg.sections[p.pieceID]?.titleOverride ?? p.pieceID
        let name = p.filename ?? (PieceStyleSlug.slug(title) + ".tex")
        let rel = "pieces/\(name)"
        let url = try PublishPath.validateAndResolve(relativePath: rel, in: entry.url)

        // Trash-on-overwrite (spec §5.6): if a file already exists at the target,
        // move it to trash before writing the new content.
        if FileManager.default.fileExists(atPath: url.path) {
            let trash = TrashStore(projectURL: entry.url)
            let meta = try JSONSerialization.data(withJSONObject: ["id": "style-\(name)"])
            _ = try await trash.moveToTrash(
                fileRelativePath: ".maugham/publish/\(rel)",
                itemMetadata: meta, originalParentId: nil, originalIndex: 0,
                displayTitle: name)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try p.content.write(to: url, atomically: true, encoding: .utf8)

        // Wire config.
        var next = cfg
        var sec = next.sections[p.pieceID] ?? PublishConfig.Section()
        sec.styleFile = name
        next.sections[p.pieceID] = sec
        try await store.save(next)

        return try JSONSerialization.data(
            withJSONObject: ["status": "set", "piece_id": p.pieceID, "style_file": name],
            options: [.sortedKeys])
    }
}

enum PieceStyleSlug {
    /// Deterministic, idempotent: same title → same slug. Lowercase, spaces→-,
    /// strip non-alnum/-, collapse repeats, trim, fallback "piece".
    static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "piece" : trimmed
    }
}
```

> **Verify `TrashStore(projectURL:)` init** matches the real initializer (open `TrashStore.swift` top). The `moveToTrash` signature is confirmed: `moveToTrash(fileRelativePath:itemMetadata:originalParentId:originalIndex:displayTitle:)`. The `registry.lookup(id:)`/`entry.url`/`entry.store` shape is confirmed in `ProjectRegistry.swift`.

- [ ] **Step 4: Run, verify pass** (`./gen.sh` first — new file). 

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/Tools/PieceStyleTools.swift MaughamTests/MCP/Tools/PieceStyleToolsTests.swift
git commit -m "feat(publish): set_piece_style tool (write+wire, trash on overwrite)"
```

---

## Task B8: `clear_piece_style` tool (unwire + delete-iff-orphaned + trash)

**Files:**
- Modify: `Maugham/MCP/Tools/PieceStyleTools.swift`
- Test: `MaughamTests/MCP/Tools/PieceStyleToolsTests.swift`

- [ ] **Step 1: Failing tests**

```swift
func test_clearPieceStyle_unwiresAndTrashesOrphanFile() async throws {
    let (registry, projectID, publishRoot) = try await makePublishProject()
    _ = try await SetPieceStyleTool.handle(paramsJSON:
        #"{"project_id":"\#(projectID)","piece_id":"ab12","filename":"t.tex","content":"%x"}"#.data(using: .utf8), registry: registry)
    _ = try await ClearPieceStyleTool.handle(paramsJSON:
        #"{"project_id":"\#(projectID)","piece_id":"ab12"}"#.data(using: .utf8), registry: registry)

    let store = PublishConfigStore(projectURL: registry.lookup(id: projectID)!.url)
    XCTAssertNil((try await store.load())?.sections["ab12"]?.styleFile)
    XCTAssertFalse(FileManager.default.fileExists(
        atPath: publishRoot.appendingPathComponent("pieces/t.tex").path), "orphan file deleted (to trash)")
}

func test_clearPieceStyle_keepsFileWhenSharedByAnotherPiece() async throws {
    let (registry, projectID, publishRoot) = try await makePublishProject()
    for pid in ["ab12", "cd34"] {
        _ = try await SetPieceStyleTool.handle(paramsJSON:
            #"{"project_id":"\#(projectID)","piece_id":"\#(pid)","filename":"shared.tex","content":"%s"}"#.data(using: .utf8), registry: registry)
    }
    _ = try await ClearPieceStyleTool.handle(paramsJSON:
        #"{"project_id":"\#(projectID)","piece_id":"ab12"}"#.data(using: .utf8), registry: registry)
    XCTAssertTrue(FileManager.default.fileExists(
        atPath: publishRoot.appendingPathComponent("pieces/shared.tex").path),
        "file still referenced by cd34 must survive")
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement `ClearPieceStyleTool`** — load config, read `sections[piece_id].styleFile`; set it to nil and save; then check whether any *other* section still references that filename; if none, move the file to trash (same `TrashStore.moveToTrash` call as B7). If `piece_id` has no style_file, return `{"status":"noop"}`. Docstring states the orphan rule.

- [ ] **Step 4: Run, verify pass; commit**

```bash
git add Maugham/MCP/Tools/PieceStyleTools.swift MaughamTests/MCP/Tools/PieceStyleToolsTests.swift
git commit -m "feat(publish): clear_piece_style tool (unwire, delete iff orphaned, trash)"
```

---

## Task B9: Register the two tools + bump catalog counts

**Files:**
- Modify: `Maugham/MCP/MCPTool.swift` (`MCPToolCatalog.all`)
- Modify: `MaughamTests/MCP/MCPProtocolHandlersTests.swift`, `MaughamTests/MCP/MCPToolsListSmokeTest.swift` (count 37→39 + names)

- [ ] **Step 1:** Add `SetPieceStyleTool.self, ClearPieceStyleTool.self` to the end of `MCPToolCatalog.all`.
- [ ] **Step 2:** `grep -rn "== 37\|count, 37\|37 tools" MaughamTests/` to find the hardcoded count assertions; bump to 39. Add `"set_piece_style"`, `"clear_piece_style"` to the expected-names set in `test_toolsList_returnsAllExpectedTools` (and any smoke test name set).
- [ ] **Step 3:** Run full suite (incl. `MCPCatalogConsistencyTests`), verify green.
- [ ] **Step 4: Commit**

```bash
git add Maugham/MCP/MCPTool.swift MaughamTests/MCP/MCPProtocolHandlersTests.swift MaughamTests/MCP/MCPToolsListSmokeTest.swift
git commit -m "feat(publish): register set_piece_style/clear_piece_style (37->39 tools)"
```

---

# Fonts (spike-gated)

## Task F1: Custom-font compile spike with determinism check

This is exploratory but lands as a test so the result is durable. It must compile a local font AND verify determinism.

**Files:**
- Create: `MaughamTests/Publish/FontSpikeTests.swift`
- (Test fixture font: use any `.otf`/`.ttf` already in the repo if present; else the test downloads/embeds a tiny test font — prefer a checked-in fixture under `MaughamTests/Fixtures/`.)

- [ ] **Step 1: Write the spike test**

```swift
import XCTest
@testable import Maugham

final class FontSpikeTests: XCTestCase {
    func test_localFontCompiles_andIsDeterministic() async throws {
        try XCTSkipUnless(TectonicLocator.locateInBundle() != nil, "tectonic not available")
        // Scaffold a project; write a fixture font into .maugham/publish/fonts/;
        // patch preamble.tex to \usepackage{fontspec}\setmainfont[Path=fonts/]{<fixture>}.
        let fix = try await PublishFixture.make()
        try fix.installFixtureFont(named: "TestFont-Regular.otf")
        try fix.appendPreamble("""
        \\usepackage{fontspec}
        \\setmainfont[Path=fonts/]{TestFont-Regular.otf}
        """)
        // Compile twice with metadata held constant.
        let pdf1 = try await fix.compilePDFRaw(version: "0.1")
        let pdf2 = try await fix.compilePDFRaw(version: "0.1")
        XCTAssertGreaterThan(pdf1.count, 1000, "compiled a real PDF")
        // Determinism: identical bytes when version/timestamp are pinned equal.
        XCTAssertEqual(pdf1, pdf2,
            "two compiles of identical input with a local font differ — fonts introduced non-determinism (spec §6.3)")
    }
}
```

> `compilePDFRaw` must hold `\MaughamCompiledAt`/version constant across both runs so the only variable under test is font handling. If pinning the timestamp isn't feasible through the public compile path, compile via `PDFCompiler` directly with a fixed `maughamVersion` and strip/normalize the known-variable PDF metadata streams before comparing. Document in the test what was normalized.

- [ ] **Step 2: Run the spike.**

Run: `xcodebuild ... test -only-testing:MaughamTests/FontSpikeTests`
**Decision gate:**
- **Green (compiles + deterministic):** proceed to Task F2.
- **Compiles but non-deterministic:** keep the test but invert the determinism assertion into an `XCTExpectFailure` with a recorded note, surface the finding to the writer (spec §6.3), and decide whether to ship fonts with the caveat or carry-forward. Either way A/B are unaffected.
- **Doesn't compile:** record the failure mode in a handoff note, descope fonts to a carry-forward, skip F2.

- [ ] **Step 3: Commit the spike result**

```bash
git add MaughamTests/Publish/FontSpikeTests.swift MaughamTests/Fixtures/TestFont-Regular.otf
git commit -m "test(publish): custom-font compile + determinism spike"
```

---

## Task F2 (conditional on F1 green): ship the fonts convention

**Files:**
- Modify: `Maugham/Resources/PublishStarter/preamble.tex`
- Modify: `Maugham/Publish/EmissionContract.swift` + regenerate `EMISSION.md`

- [ ] **Step 1:** Add a commented (inactive by default) fontspec block to `preamble.tex`:

```latex
% --- Custom body font (optional) -------------------------------------------
% Drop an .otf/.ttf into .maugham/publish/fonts/ (write_publish_file, base64),
% then uncomment and set the filename. Verified to compile under tectonic.
% \usepackage{fontspec}
% \setmainfont[Path=fonts/]{EBGaramond-Regular.otf}
% ---------------------------------------------------------------------------
```

- [ ] **Step 2:** Add a "Fonts" section to `EmissionContract` (the write→reference loop + the constraint that font loading lives in preamble.tex, never config). Regenerate `EMISSION.md`; the golden test enforces the match.
- [ ] **Step 3:** Run full suite; commit.

```bash
git add Maugham/Resources/PublishStarter/preamble.tex Maugham/Publish/EmissionContract.swift Maugham/Resources/PublishStarter/EMISSION.md
git commit -m "feat(publish): document + ship custom-font convention (fontspec)"
```

---

# EPUB

## Task E1: Persist `build/body.xhtml` + `build/compile.log` for EPUB; document open-loop

**Files:**
- Modify: `Maugham/Publish/EPUBCompiler.swift` (`compile`, after building `sections` ~line 49)
- Test: `MaughamTests/Publish/EPUBBodyArtifactTests.swift` (create)

- [ ] **Step 1: Failing test**

```swift
func test_epubCompile_persistsBodyXhtml() async throws {
    let fix = try await PublishFixture.make()
    _ = try await fix.compileEPUB()
    let body = fix.publishRoot.appendingPathComponent("build/body.xhtml")
    XCTAssertTrue(FileManager.default.fileExists(atPath: body.path))
    let text = try String(contentsOf: body, encoding: .utf8)
    XCTAssertTrue(text.contains("<section"), "assembled XHTML should be present for inspection")
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Write the artifact** — in `EPUBCompiler.compile`, after `sections` is built, assemble and write:

```swift
let build = publish.appendingPathComponent("build", isDirectory: true)
try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
let assembled = sections.map { $0.xhtmlBody }.joined(separator: "\n")
try? assembled.write(to: build.appendingPathComponent("body.xhtml"), atomically: true, encoding: .utf8)
// EPUB has no tectonic log; write an explanatory stub so the artifact exists.
try? "EPUB compile: no LaTeX log (HTML/CSS pipeline).".write(
    to: build.appendingPathComponent("compile.log"), atomically: true, encoding: .utf8)
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5:** Ensure `EmissionContract`'s recovery/EPUB note documents the open-loop asymmetry (PDF closed-loop via `read_publication_page`; EPUB open-loop — `build/body.xhtml` shows structure, not rendering; iterate via Denver describing the reader). Regenerate `EMISSION.md` if changed.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Publish/EPUBCompiler.swift MaughamTests/Publish/EPUBBodyArtifactTests.swift Maugham/Publish/EmissionContract.swift Maugham/Resources/PublishStarter/EMISSION.md
git commit -m "feat(publish): persist build/body.xhtml for EPUB inspection (open-loop)"
```

---

# Finalization

## Task Z1: Full-suite green + smoke handoff

- [ ] **Step 1:** `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` — entire suite green.
- [ ] **Step 2:** Verify the catalog count test reflects 39 and `MCPCatalogConsistencyTests` passes.
- [ ] **Step 3:** Write a handoff note `docs/superpowers/notes/2026-05-29-publishing-feedback-handoff.md` summarizing what shipped, the fonts-spike outcome, and any carry-forwards.
- [ ] **Step 4:** Manual smoke (user runs): set up publishing on a test collection in Claude Desktop, `read_publish_file EMISSION.md`, `set_piece_style` on one piece, compile, confirm the override lands and the prior style file is in trash. Do not claim done until the user confirms.
- [ ] **Step 5: Commit the handoff note.**

---

## Self-Review notes (for the executor)

- **Build-order dependency:** A4 (EMISSION.md generation) calls `LaTeXBodyEmitter.emit(_:config:)`, introduced in **B1**. Run order: **A1, A2, A3 → B1 → A4 → B2…B9 → F1[→F2] → E1 → Z1.** A4 is the one cross-cluster dependency; everything else is in declared order.
- **`PublishFixture` / `makePublishProject` are not yet shared helpers.** Each test cluster reuses the scaffolding already present in `PublishingEndToEndTests` / `PublishFileToolsTests`. First task that needs it should extract a small shared helper; later tasks reuse it. Do not invent store APIs — copy the working setup verbatim.
- **API-name caution (handoff lesson):** the v1 plan used stub names that didn't exist. Before implementing each task, confirm the real signatures: `registry.lookup(id:) -> Entry?` with `.url`/`.store`; `MCPError.invalidArgument`; `PublishConfigStore(projectURL:)` actor with async `load()`/`save(_:)`; `TrashStore(projectURL:)` with `moveToTrash(fileRelativePath:itemMetadata:originalParentId:originalIndex:displayTitle:)`. All verified present 2026-05-29.
