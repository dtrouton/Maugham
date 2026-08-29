# Translation Pipeline — Plan 2: Briefings, Cold Calls, and the Two Verbs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build everything the seven-leg pipeline (Plan 3) will *call* but that stands on its own: the two cold briefings, the translator briefing's `.fix` mode and directed work-list, the sealed `claude -p` confinement and the `ColdCall` runner with its teardown sibling, the cast sheet's reader and collator fields, and **Translator's note…** in the editor.

**Architecture:** Every briefing stays a pure function in `Maugham/Compiler/` (`TranslatorBriefing`'s discipline — no I/O, no clock). `ClaudeCLISession` learns one enum, `Confinement`, so a sealed process is a spawn-argument fact pinned by the same fake-CLI test that pins the compiler's flags. `ColdCall` is a one-shot owner of a sealed session — spawn, send once, shut down — and joins the window's teardown census as a fourth sibling. Directives and the glossary are read off the writer's statements through the P1 `Ruling` shapes and handed to the briefings as plain values. The editor verb is a key-window command that opens a SwiftUI sheet and writes through `RulingPerformer.rule` — the one door.

**Tech Stack:** Swift 6, SwiftUI + AppKit, XCTest. Mac scheme only (nothing here touches MaughamCore).

**Spec:** `docs/superpowers/specs/2026-08-28-translation-pipeline-design.md` — §2 (briefings), §3 (directives), §5 (ColdCall), §9 (what ColdCall will serve), §11 (confinement), §12 (tests by unit), §13 item 2. Read §1–§13 once.

**Built on:** Plan 1 (`docs/superpowers/plans/2026-08-28-translation-pipeline-p1-cast-rulings-wire.md`), merged at `ef538475`. **This plan never restates P1's API.** The types it points at, by file:

- `Packages/MaughamCore/Sources/MaughamCore/ProductionRole.swift` — `Role.reader(language:)`/`.collator(language:)`, `defaultReaderName`/`defaultCollatorName`, `effectiveName`/`effectiveBrief`.
- `Packages/MaughamCore/Sources/MaughamCore/RulingShapes.swift` — `Ruling.directive`, `.paragraphId`, `.glossary`, `Ruling.directiveText(paragraphId:_:)`, `Ruling.glossaryText(term:rendering:note:)`, `Ruling.Provenance.translatorsNote`/`.glossary`.
- `Packages/MaughamCore/Sources/MaughamCore/RulingsSection.swift` — `RulingsSection.parse(_:) -> (essay:, rulings:)`; `Ruling.ruledOn` is **UTC midnight of the ruled day** (the formatter is `d MMM yyyy` in UTC).
- `Maugham/Compiler/ReaderReport.swift`, `CollatorReport.swift` — `schemaDescription`, `parse(_:briefedParagraphIds:)`.
- `Maugham/Compiler/TranslatorReport.swift` — `Mode` (`.translate`/`.fix(briefedNoteIds:)`), `schemaDescription`, `fixSchemaDescription`, `parse(_:mode:)`.
- `Maugham/Stores/ProjectStore+ProductionRoles.swift` — `translatorRole/readerRole/collatorRole(for:)` (RUN-ONLY mints), `renameProductionRole(id:to:)`; `Maugham/Publish/EditionStatus.swift` — `translatorName/readerName/collatorName(for:in:)` (read-only), `editionLanguages(files:queries:roles:)`.
- `Maugham/Compiler/RulingPerformer.swift` — `rule(_:provenance:kind:forScope:store:world:)`.

**Research already done** — the appendix at the end of the P1 plan ("Appendix — facts gathered for Plan 2"). Line numbers there are from v0.33.0; verify before relying on them.

## Global Constraints

Copied from the spec; every task's requirements include these.

- **Every `ColdCall` spawns with `--tools ""`, `--strict-mcp-config`, and no `--mcp-config` at all** — blind by construction, not by allowlist (§11). The translator's allowlist is unchanged.
- **No new `AnnotationKind`.** Every writer-facing record here is a ruling (§ Constitution check).
- **Directives are minted only through `RulingPerformer.rule`** with provenance `Ruling.Provenance.translatorsNote` (§3). Home: craft intent `.document(id)` by default ("Every edition"), else that language's edition brief at `.project` ("This edition only").
- **A composed ruling line never contains an em-dash, `«`/`»`, or a line break** — P1's composers already sanitize; this plan only ever composes through them (§3).
- **Briefings are pure**: no I/O, no clock, no store lookup; testable without a subprocess (§2).
- **Reader is never shown source text, craft intent's essay, translator queries, prior reader notes, or the bible**; a stale or missing paragraph is rendered `[¶id — not yet translated]` and never as source (§2).
- **Collator is never shown reader notes, translator queries, or the bible** (§2).
- **The `.translate` work-list = `stale ∪ missing ∪ directed`**, directed = a fresh paragraph carrying a directive ruled after its `TranslationRecord.at` — derived from two dates, nothing stored (§2).
- **The keystroke is the only trigger.** Nothing here re-arms itself (§ Constitution check).
- **No `NSPopover` in the editor** (Editor AREA tripwire 7). Translator's note is a sheet.
- **A new `⌘⌥` binding lands in `KeyboardShortcuts.all` and `docs/guide/reference.md`** or `DocSyncTests` fails. Free letters at v0.33.0: C, G, J, M(system), U, X, Y.
- **`./gen.sh` after adding ANY source or test file**; a stale project runs 0 tests silently (CLAUDE.md build flow).
- **`./scripts/test.sh full` before merge; read the kept xcresult for the verdict** (`xcrun xcresulttool get test-results summary --path …`), never the pipe's exit code.
- **Execution in a worktree** under `../Maugham-wt/` (`git worktree add ../Maugham-wt/translation-p2 -b translation-pipeline-p2 main`), `./gen.sh` there before any `xcodebuild`.
- The running command for one suite: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/<Class>` (Mac tests only; this plan adds nothing to MaughamCore).

## File structure

| File | Responsibility |
|---|---|
| `Maugham/Compiler/ClaudeCLISession.swift` (modify) | `Confinement` enum; init and `arguments` take it; cwd derives from it |
| `Maugham/Compiler/CompilerEnvironment+Project.swift`, `DesignerEnvironment+Project.swift`, `TranslatorEnvironment+Project.swift` (modify) | `.bridged(mcpConfigPath:)` at the three spawn sites; translator gather grows directives, glossary, directed work-list |
| `Maugham/Compiler/ColdCall.swift` (create) | One-shot sealed session owner: configure, call, cancel, shutdown, detach; production runner factory |
| `Maugham/Compiler/BriefingDoctrine.swift` (create) | `Directive`/`Directives` (gather, index, `isDirected`) and `GlossaryEntry`/`GlossaryTable` (gather, render) — pure, over statement markdown |
| `Maugham/Compiler/ReaderBriefing.swift` (create) | Pure composer for the blind read |
| `Maugham/Compiler/CollatorBriefing.swift` (create) | Pure composer for the collation |
| `Maugham/Compiler/TranslatorBriefing.swift` (modify) | `Mode`, `FixNote`; directives per work item; glossary section; fix-mode work-list and contract |
| `Maugham/Compiler/TranslatorOrchestrator.swift` (modify) | parses with `inputs.reportMode` |
| `Maugham/Views/CompilerRunModifier.swift`, `Maugham/Views/ProjectWindow.swift` (modify) | `coldCall` sibling in every teardown arm; Translator's note command + sheet |
| `Maugham/Views/Publish/DepartmentCastSheet.swift`, `DepartmentPaneHost.swift` (modify) | Three name fields; `RenameSubject.edition`; `nameCast` |
| `Maugham/Views/TranslatorsNote.swift` (create) | `TranslatorsNote` (target, home, destination, editions, commit), `TranslatorsNoteSheet`, `TranslatorsNoteCopy` |
| `Maugham/Editor/SelectionToolbarView.swift`, `EditorCoordinator+ReviewRender.swift` (modify) | Fourth toolbar kind posting the window command |
| `Maugham/MaughamApp.swift`, `Maugham/Resources/KeyboardShortcuts.swift`, `Maugham/Models/MaughamNotifications.swift`, `docs/guide/reference.md`, `docs/guide/compiler.md` (modify) | The ⌘⌥C command and its documentation |
| `Maugham/Compiler/AREA.md`, `Maugham/Editor/AREA.md` (modify) | ColdCall/confinement/briefings entries; the editor verb |
| Tests | `ClaudeCLISessionTests` (+2), `ColdCallTests` (new), `TripwireGrepTests` (+2), `TranslatorEnvironmentTests` (census widened, +2 gather tests), `BriefingDoctrineTests` (new), `ReaderBriefingTests` (new), `CollatorBriefingTests` (new), `TranslatorBriefingTests` (+6), `TranslatorOrchestratorTests` (+1), `DepartmentRunTests` (+3, edits), `DepartmentPaneTests` (+1), `TranslatorsNoteTests` (new) |

---

### Task 1: Sealed confinement on `ClaudeCLISession`

**Files:**
- Modify: `Maugham/Compiler/ClaudeCLISession.swift` (init ~152, `ensureProcess` ~295, `arguments` ~396)
- Modify: `Maugham/Compiler/CompilerEnvironment+Project.swift:418`, `Maugham/Compiler/DesignerEnvironment+Project.swift:98`, `Maugham/Compiler/TranslatorEnvironment+Project.swift:101` (the three spawn sites)
- Test: `MaughamTests/ClaudeCLISessionTests.swift` (`makeSession` ~205, `test_spawnArgumentsMatchTheSpike` ~787)

**Interfaces:**
- Produces:
  ```swift
  extension ClaudeCLISession {
      enum Confinement: Equatable {
          case bridged(mcpConfigPath: URL)
          case sealed
          var workingDirectory: URL
      }
  }
  // init(model:confinement:cliOverride:isEnabled:idleTimeout:runTimeout:deathReapGrace:locator:)
  // let confinement: Confinement            (internal, readable — Task 2's factory test reads it)
  // static func arguments(model: String, confinement: Confinement, preamble: String?) -> [String]
  ```
- Consumes: `CompilerAllowlist.cliArguments()` (unchanged).

- [ ] **Step 1: Write the failing tests**

Add to `ClaudeCLISessionTests`, next to `test_spawnArgumentsMatchTheSpike`:

```swift
    /// **The sealed membrane, pinned the way the bridged one is** (translation
    /// pipeline spec §11): a reader, a collator or a gloss is blind by
    /// construction — no bridge config, no allowlist, built-ins emptied.
    func test_aSealedSessionSpawnsWithNoBridgeAndNoAllowlist() async throws {
        let cli = try makeFakeCLI(mode: .normal)
        let session = makeSession(cli: cli, confinement: .sealed)

        _ = await session.send(message: "hello", systemPreamble: "BE TERSE")

        var argv = try String(contentsOf: argsURL, encoding: .utf8)
            .components(separatedBy: "\n")
        if argv.last?.isEmpty == true { argv.removeLast() }

        for flag in ["-p", "--verbose", "--strict-mcp-config"] {
            XCTAssertTrue(argv.contains(flag), "missing \(flag) in \(argv)")
        }
        XCTAssertFalse(argv.contains("--mcp-config"),
                       "a sealed session must not be handed Maugham's bridge: \(argv)")
        XCTAssertFalse(argv.contains("--allowedTools"),
                       "there is nothing to pre-approve in a sealed session: \(argv)")
        func value(after flag: String) -> String? {
            guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
            return argv[i + 1]
        }
        XCTAssertEqual(value(after: "--tools"), "",
                       "--tools \"\" is what removes Read/Glob/Grep")
        XCTAssertEqual(value(after: "--append-system-prompt"), "BE TERSE")

        let cwd = try String(contentsOf: cwdURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path,
            ClaudeCLISession.sessionConfigDirectory.resolvingSymlinksInPath().path,
            "a sealed process stands in the session config directory, never the "
            + "writer's project")
        session.shutdown()
    }

    /// The pure half — no subprocess — so the difference between the two
    /// confinements is readable in one assertion each.
    func test_argumentsDifferBetweenBridgedAndSealedExactlyWhereTheMembraneSaysTheyDo() {
        let config = URL(fileURLWithPath: "/tmp/x/mcp.json")
        let bridged = ClaudeCLISession.arguments(
            model: "haiku", confinement: .bridged(mcpConfigPath: config), preamble: nil)
        let sealed = ClaudeCLISession.arguments(
            model: "haiku", confinement: .sealed, preamble: nil)

        XCTAssertTrue(bridged.contains("--mcp-config"))
        XCTAssertTrue(bridged.contains("--allowedTools"))
        XCTAssertFalse(sealed.contains("--mcp-config"))
        XCTAssertFalse(sealed.contains("--allowedTools"))
        for args in [bridged, sealed] {
            XCTAssertTrue(args.contains("--strict-mcp-config"))
            XCTAssertTrue(args.contains("--include-partial-messages"))
            let toolsIndex = try? XCTUnwrap(args.firstIndex(of: "--tools"))
            XCTAssertEqual(toolsIndex.map { args[$0 + 1] }, "")
        }
        XCTAssertEqual(ClaudeCLISession.Confinement.sealed.workingDirectory,
                       ClaudeCLISession.sessionConfigDirectory)
        XCTAssertEqual(
            ClaudeCLISession.Confinement.bridged(mcpConfigPath: config).workingDirectory,
            config.deletingLastPathComponent())
    }
```

Change `makeSession` to take a confinement, defaulting to today's shape so every existing test is untouched:

```swift
    private func makeSession(
        cli: URL?,
        confinement: ClaudeCLISession.Confinement? = nil,
        isEnabled: @escaping () -> Bool = { true },
        idleTimeout: TimeInterval = 600,
        runTimeout: TimeInterval = 20,
        deathReapGrace: TimeInterval = ClaudeCLISession.defaultDeathReapGrace,
        locator: (@Sendable () -> URL?)? = nil
    ) -> ClaudeCLISession {
        ClaudeCLISession(
            model: "haiku",
            confinement: confinement
                ?? .bridged(mcpConfigPath: tempDir.appendingPathComponent("mcp.json")),
            cliOverride: cli,
            isEnabled: isEnabled,
            idleTimeout: idleTimeout,
            runTimeout: runTimeout,
            deathReapGrace: deathReapGrace,
            locator: locator ?? { nil })
    }
```

`test_spawnArgumentsMatchTheSpike` stays byte-for-byte as it is — it is the bridged membrane's standing proof.

- [ ] **Step 2: Run the suite to see it fail to compile**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ClaudeCLISessionTests 2>&1 | grep -E "error:|Test Suite|passed|failed" | head -20`
Expected: compile error — `no parameter 'confinement'` / `Confinement` not found.

- [ ] **Step 3: Implement `Confinement`**

In `ClaudeCLISession.swift`, replace the stored `private let mcpConfigPath: URL` with:

```swift
    /// What the spawned CLI can reach. See `Confinement`.
    let confinement: Confinement
```

Add the enum (a nested type, after the `// MARK: - Injected` block's properties):

```swift
    /// **What the spawned CLI can reach — a spawn-argument fact, not a
    /// setting** (translation pipeline spec §11).
    ///
    /// `.bridged` is the compiler's, the translator's and the designer's
    /// membrane: Maugham's own MCP bridge through a per-session `--mcp-config`
    /// file the owner wrote and deletes, built-ins emptied by `--tools ""`, the
    /// bridge's read tools pre-approved by `CompilerAllowlist`. `.sealed` is
    /// the reader's, the collator's and the glosser's: **no `--mcp-config` at
    /// all**, no allowlist, built-ins emptied — blind by construction rather
    /// than by an allowlist that happens to name nothing. A sealed session
    /// cannot read the source it must not see even if a later allowlist edit
    /// were to widen the bridge, because it was never handed the bridge.
    enum Confinement: Equatable {
        case bridged(mcpConfigPath: URL)
        case sealed

        /// The directory the process stands in — never the writer's project
        /// (see `ensureProcess`). A bridged session stands beside its config
        /// file; a sealed one, which has no file, stands in the same shared
        /// session directory so an orphaned process is findable in one place.
        var workingDirectory: URL {
            switch self {
            case .bridged(let path): return path.deletingLastPathComponent()
            case .sealed: return ClaudeCLISession.sessionConfigDirectory
            }
        }
    }
```

Change the init signature and body:

```swift
    init(model: String,
         confinement: Confinement,
         cliOverride: URL?,
         isEnabled: @escaping () -> Bool,
         idleTimeout: TimeInterval = 600,
         runTimeout: TimeInterval = ClaudeCLISession.defaultRunTimeout,
         deathReapGrace: TimeInterval = ClaudeCLISession.defaultDeathReapGrace,
         locator: @escaping @Sendable () -> URL? = { ClaudeCLISession.locateCLI() }) {
        self.model = model
        self.confinement = confinement
        // … the rest unchanged
```

In `ensureProcess`, replace the two `mcpConfigPath` reads:

```swift
        proc.arguments = Self.arguments(
            model: model, confinement: confinement, preamble: lastPreamble)
        // …
        let workingDirectory = confinement.workingDirectory
```

(keep the existing comment above the cwd lines; amend its first sentence to "Defence in depth behind `--tools ""`, for both confinements.")

Replace `arguments`:

```swift
    /// The invocation the spike measured, plus the confinement's own flags.
    ///
    /// (keep the existing doc paragraphs about `--append-system-prompt` and
    /// the two-flag membrane verbatim, then add:)
    ///
    /// **A sealed session emits neither `--mcp-config` nor `--allowedTools`.**
    /// `--strict-mcp-config` is emitted in both cases — with no config beside
    /// it, it is what keeps the writer's own user-level MCP servers out of a
    /// process that is supposed to hold nothing. `--tools ""` is common to
    /// both, for the reason above.
    static func arguments(model: String, confinement: Confinement, preamble: String?) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
        ]
        if case .bridged(let path) = confinement {
            args += ["--mcp-config", path.path]
        }
        args += [
            "--strict-mcp-config",
            // (keep the existing "The stream has to be asked for" comment here)
            "--include-partial-messages",
            "--tools", ""
        ]
        if let preamble, !preamble.isEmpty {
            args += ["--append-system-prompt", preamble]
        }
        if case .bridged = confinement {
            args += CompilerAllowlist.cliArguments()
        }
        return args
    }
```

Update the three production spawn sites — each is `ClaudeCLISession(model: model, mcpConfigPath: configURL, cliOverride: nil, isEnabled: …)`; change `mcpConfigPath: configURL` to `confinement: .bridged(mcpConfigPath: configURL)`. Nothing else at those sites changes.

- [ ] **Step 4: Run the suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ClaudeCLISessionTests 2>&1 | grep -E "error:|Test Suite 'ClaudeCLISessionTests'|passed|failed" | tail -5`
Expected: every existing test green plus the two new ones. Then build the whole app target once (`xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"`) — the three environment files must compile.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/ClaudeCLISession.swift Maugham/Compiler/CompilerEnvironment+Project.swift Maugham/Compiler/DesignerEnvironment+Project.swift Maugham/Compiler/TranslatorEnvironment+Project.swift MaughamTests/ClaudeCLISessionTests.swift
git commit -m "feat(compiler): ClaudeCLISession.Confinement — sealed spawns with no bridge and no allowlist"
```

---

### Task 2: `ColdCall` — one sealed process per call

**Files:**
- Create: `Maugham/Compiler/ColdCall.swift`
- Create: `MaughamTests/ColdCallTests.swift`
- Modify: `MaughamTests/TripwireGrepTests.swift` (add two tests near `test_noBareParagraphIDMintInProduction`)
- Modify: `Maugham/Compiler/AREA.md` (new section after "The designer — the area's third orchestrator")

**Interfaces:**
- Consumes: `CompilerRunner`, `CompilerRunEvent`, `CompilerRunFailure.Detail` (`Maugham/Compiler/CompilerRunner.swift`); `ClaudeCLISession.Confinement.sealed` (Task 1); `UserPreferences.mcpEnabled`.
- Produces:
  ```swift
  @MainActor final class ColdCall {
      typealias RunnerFactory = @MainActor (_ model: String) -> CompilerRunner
      func configure(makeRunner: @escaping RunnerFactory)
      func call(message: String, preamble: String?, model: String) async -> CompilerRunEvent
      func cancel()
      func shutdown()
      func detach()
      private(set) var isRunning: Bool
      static func productionRunnerFactory(preferences: UserPreferences) -> RunnerFactory
  }
  ```

- [ ] **Step 1: Write the failing tests**

`MaughamTests/ColdCallTests.swift`:

```swift
// MaughamTests/ColdCallTests.swift
import XCTest
@testable import Maugham

/// `ColdCall` is the one runner every cold session shares (translation
/// pipeline spec §5): a fresh sealed process per call, one briefing in, one
/// report out, the process ended. Reader, collator, gloss and Ask-the-collator
/// are its four callers (Plans 3–4); this suite pins the runner's own
/// contract over a spy.
@MainActor
final class ColdCallTests: XCTestCase {

    /// `TranslatorOrchestratorTests.SpyRunner`'s shape, kept local for that
    /// suite's reason (each loop's spy diverges as the loop grows).
    private final class SpyRunner: CompilerRunner {
        private(set) var sends: [(message: String, preamble: String?)] = []
        private(set) var shutdowns = 0
        private(set) var cancels = 0
        var isRunning = false
        var sessionEpoch = 1
        var nextEvent: CompilerRunEvent? = .resultText("{\"gloss\":\"the fog came\"}")
        private var held: CheckedContinuation<CompilerRunEvent, Never>?

        func send(message: String, systemPreamble: String?) async -> CompilerRunEvent {
            sends.append((message, systemPreamble))
            if let nextEvent { return nextEvent }
            isRunning = true
            return await withCheckedContinuation { held = $0 }
        }

        func release(_ event: CompilerRunEvent) {
            isRunning = false
            let continuation = held
            held = nil
            continuation?.resume(returning: event)
        }

        func cancelCurrentRun() {
            cancels += 1
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)))
        }

        func shutdown() {
            shutdowns += 1
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown)))
        }
    }

    /// A factory that remembers every runner it made and the model it was
    /// asked for.
    private final class Factory {
        private(set) var made: [SpyRunner] = []
        private(set) var models: [String] = []
        var configure: (SpyRunner) -> Void = { _ in }

        func make(model: String) -> CompilerRunner {
            let runner = SpyRunner()
            configure(runner)
            made.append(runner)
            models.append(model)
            return runner
        }
    }

    private func makeColdCall() -> (ColdCall, Factory) {
        let factory = Factory()
        let coldCall = ColdCall()
        coldCall.configure(makeRunner: { factory.make(model: $0) })
        return (coldCall, factory)
    }

    // MARK: - One call, one process

    func test_aCallSpawnsOneRunnerSendsOnceAndShutsItDown() async {
        let (coldCall, factory) = makeColdCall()

        let event = await coldCall.call(
            message: "read this", preamble: "you are blind", model: "opus")

        XCTAssertEqual(event, .resultText("{\"gloss\":\"the fog came\"}"))
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(factory.models, ["opus"], "the model is the caller's, per call")
        XCTAssertEqual(factory.made[0].sends.count, 1)
        XCTAssertEqual(factory.made[0].sends[0].message, "read this")
        XCTAssertEqual(factory.made[0].sends[0].preamble, "you are blind")
        XCTAssertEqual(factory.made[0].shutdowns, 1,
                       "the process ends with the call — warmth would cost blindness")
        XCTAssertFalse(coldCall.isRunning)
    }

    func test_twoCallsAreTwoProcesses() async {
        let (coldCall, factory) = makeColdCall()

        _ = await coldCall.call(message: "one", preamble: nil, model: "opus")
        _ = await coldCall.call(message: "two", preamble: nil, model: "opus")

        XCTAssertEqual(factory.made.count, 2, "nothing is remembered between calls")
        XCTAssertEqual(factory.made.map(\.shutdowns), [1, 1])
    }

    /// A failed turn is still a finished call: the process is ended and the
    /// failure is returned as it came.
    func test_aFailedTurnEndsTheProcessAndReturnsTheFailure() async {
        let (coldCall, factory) = makeColdCall()
        factory.configure = { $0.nextEvent = .failed(.timedOut) }

        let event = await coldCall.call(message: "x", preamble: nil, model: "opus")

        XCTAssertEqual(event, .failed(.timedOut))
        XCTAssertEqual(factory.made[0].shutdowns, 1)
        XCTAssertFalse(coldCall.isRunning)
    }

    // MARK: - Refusals

    func test_anUnconfiguredColdCallRefusesInWords() async {
        let coldCall = ColdCall()
        let event = await coldCall.call(message: "x", preamble: nil, model: "opus")
        guard case .failed(.sessionDied(let detail)) = event else {
            return XCTFail("expected a sessionDied refusal, got \(event)")
        }
        XCTAssertEqual(detail, ColdCall.notWiredDetail)
    }

    /// One call at a time, like the orchestrators: a second call arriving
    /// while the first is out is refused with the seam's own spelling, and
    /// spawns nothing.
    func test_aSecondCallWhileOneIsInFlightIsRefusedAndSpawnsNothing() async {
        let (coldCall, factory) = makeColdCall()
        factory.configure = { $0.nextEvent = nil }   // hold the turn open

        let first = Task { await coldCall.call(message: "one", preamble: nil, model: "opus") }
        _ = await pumpUntil(deadline: 2) { coldCall.isRunning }

        let second = await coldCall.call(message: "two", preamble: nil, model: "opus")
        XCTAssertEqual(second, .failed(.sessionDied(detail: CompilerRunFailure.Detail.runInFlight)))
        XCTAssertEqual(factory.made.count, 1)

        factory.made[0].release(.resultText("{}"))
        let firstEvent = await first.value
        XCTAssertEqual(firstEvent, .resultText("{}"))
    }

    // MARK: - Cancel and shutdown

    func test_cancelReachesTheLiveProcessAndTheCallReturnsCancelled() async {
        let (coldCall, factory) = makeColdCall()
        factory.configure = { $0.nextEvent = nil }

        let call = Task { await coldCall.call(message: "one", preamble: nil, model: "opus") }
        _ = await pumpUntil(deadline: 2) { coldCall.isRunning }

        coldCall.cancel()
        let event = await call.value

        XCTAssertEqual(event, .failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)))
        XCTAssertEqual(factory.made[0].cancels, 1)
        XCTAssertEqual(factory.made[0].shutdowns, 1, "cancelled or not, the process ends")
        XCTAssertFalse(coldCall.isRunning)
    }

    /// The window closing mid-read: `shutdown()` ends the process, the call
    /// resolves as shut down, and the runner is shut down exactly once — the
    /// call's own completion must not reach a process the shutdown already
    /// ended.
    func test_shutdownMidCallEndsTheProcessOnce() async {
        let (coldCall, factory) = makeColdCall()
        factory.configure = { $0.nextEvent = nil }

        let call = Task { await coldCall.call(message: "one", preamble: nil, model: "opus") }
        _ = await pumpUntil(deadline: 2) { coldCall.isRunning }

        coldCall.shutdown()
        let event = await call.value

        XCTAssertEqual(event, .failed(.sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown)))
        XCTAssertEqual(factory.made[0].shutdowns, 1)
        XCTAssertFalse(coldCall.isRunning)
    }

    func test_shutdownWithNothingInFlightIsANoOp() {
        let (coldCall, factory) = makeColdCall()
        coldCall.shutdown()
        XCTAssertTrue(factory.made.isEmpty)
    }

    /// `detach()` is `shutdown()` plus dropping the factory: the next call
    /// refuses rather than spawning against a window that is gone.
    func test_detachDropsTheFactory() async {
        let (coldCall, _) = makeColdCall()
        coldCall.detach()
        let event = await coldCall.call(message: "x", preamble: nil, model: "opus")
        XCTAssertEqual(event, .failed(.sessionDied(detail: ColdCall.notWiredDetail)))
    }

    // MARK: - Production

    /// The production factory builds a SEALED session — the whole of spec §11
    /// from this side. `ClaudeCLISession.confinement` is readable for exactly
    /// this assertion.
    func test_theProductionFactoryBuildsASealedSession() {
        let suite = "ColdCallTests-\(UUID().uuidString)"
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let factory = ColdCall.productionRunnerFactory(preferences: preferences)

        let runner = factory("haiku")
        let session = runner as? ClaudeCLISession
        XCTAssertNotNil(session, "production spawns the real CLI session")
        XCTAssertEqual(session?.confinement, .sealed)
        session?.shutdown()
    }
}
```

`pumpUntil(deadline:_:)` is the existing async test helper used throughout `DepartmentRunTests` — if it is declared `private` there, reuse whichever shared copy `MaughamTests/TestSupport/` holds (grep `func pumpUntil`); if none is shared, add a `fileprivate` copy at the bottom of this file:

```swift
@MainActor
private func pumpUntil(deadline: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
```

Then the two tripwires in `TripwireGrepTests`, after `test_noBareParagraphIDMintInProduction`:

```swift
    // MARK: - ColdCall never bridges (translation pipeline spec §11)

    /// **`ColdCall` is sealed by construction and stays that way.** A sealed
    /// session is handed no `--mcp-config` (Task 1's pin); this census keeps
    /// the ONE production spawner of sealed sessions from ever writing a
    /// bridge config or asking for the bridged confinement — the two ways a
    /// later edit could hand the reader the source it must not see.
    func test_coldCallNeverBridges() throws {
        let file = sourceDir.appendingPathComponent("Compiler/ColdCall.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for forbidden in ["writeMCPConfig", ".bridged(", "--mcp-config", "CompilerAllowlist"] {
            XCTAssertFalse(text.contains(forbidden),
                           "ColdCall.swift must not contain `\(forbidden)` — a cold call is "
                           + "blind by construction, never by allowlist")
        }
        XCTAssertTrue(text.contains(".sealed"),
                      "the scan reads the file rather than always answering true")
    }

    /// **The converse: `.sealed` is spelled in production by `ColdCall` and the
    /// session type alone.** A fourth file asking for a sealed session is a
    /// fifth cold caller the spec's four (reader, collator, gloss, Ask the
    /// collator) do not name — it goes through `ColdCall`, not around it.
    func test_theOnlySealedSpawnerIsColdCall() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: [".sealed"],
            allowed: ["ColdCall.swift", "ClaudeCLISession.swift"])
        XCTAssertTrue(offenders.isEmpty,
                      "a sealed session is spawned through ColdCall only. Offenders:\n"
                      + offenders.joined(separator: "\n"))
    }
```

(`sourceDir` and `grepSwift(in:patterns:allowed:)` are the file's existing helpers; `grepSwift` matches each pattern as a plain **substring** per line — `lineStr.contains(pat)` — so `".sealed"` is the whole pattern.)

- [ ] **Step 2: `./gen.sh`, then run to see the failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ColdCallTests 2>&1 | grep -E "error:|Test Suite|passed|failed" | head`
Expected: compile error, `ColdCall` not found.

- [ ] **Step 3: Implement `ColdCall`**

`Maugham/Compiler/ColdCall.swift`:

```swift
import Foundation

/// **The cold sessions' one runner** (translation pipeline spec §5, §11).
///
/// A reader, a collator, a gloss and an Ask-the-collator each need one thing
/// from a `claude -p` process: send one briefing, read one report, end. They
/// share this runner rather than each owning a warm session — warmth would buy
/// nothing (the whole briefing is re-sent every time) and would cost the one
/// property these callers exist for: **blindness**. A reader shown its last
/// notes defends them; a process that remembers nothing cannot.
///
/// Every runner this spawns is `ClaudeCLISession.Confinement.sealed` — no
/// bridge config, no allowlist, built-ins emptied — and `TripwireGrepTests
/// .test_coldCallNeverBridges` keeps this file from ever asking for anything
/// else. The tool-less half of "reads and returns" is therefore a fact about
/// the spawn arguments, pinned by `ClaudeCLISessionTests`, not an intention.
///
/// **One call at a time**, the orchestrators' own rule: a second call arriving
/// while one is out is refused with `CompilerRunFailure.Detail.runInFlight`
/// and spawns nothing. Sequencing the pipeline's legs is `TranslationPipeline`'s
/// job (Plan 3); this type holds no queue.
///
/// **The owner must call `shutdown()` or `detach()`.** `ClaudeCLISession`'s
/// contract inherited whole: a call in flight when the window closes is a
/// live, billing process otherwise. `ProjectWindow` owns this runner beside
/// the three orchestrators and every teardown arm `TranslatorEnvironmentTests`'
/// census pairs carries a `coldCall.shutdown()` — it is the census's fourth
/// sibling.
@MainActor
final class ColdCall {

    typealias RunnerFactory = @MainActor (_ model: String) -> CompilerRunner

    /// The refusal a call gets before `configure` has run, or after `detach()`.
    static let notWiredDetail = "no cold-call runner is wired to this window"

    private var makeRunner: RunnerFactory?
    /// The process of the call in flight, so `cancel()`/`shutdown()` can reach
    /// it. `nil` between calls — there is nothing to keep.
    private var live: CompilerRunner?
    /// Bumped by every `shutdown()`. A call resuming from its `send` compares
    /// the generation it started under and, if a shutdown landed in between,
    /// does not touch the runner the shutdown already ended — `ClaudeCLISession
    /// .generation`'s reasoning, one owner up.
    private var generation = 0

    private(set) var isRunning = false

    /// Wire the runner factory. Called where the preferences exist — never
    /// from a `body`.
    func configure(makeRunner: @escaping RunnerFactory) {
        self.makeRunner = makeRunner
    }

    /// One cold call: spawn, send, end. `model` is the caller's — the compiler's
    /// setting, read at the call rather than captured here, so a change
    /// between two calls reaches the second.
    func call(message: String, preamble: String?, model: String) async -> CompilerRunEvent {
        guard let makeRunner else {
            return .failed(.sessionDied(detail: Self.notWiredDetail))
        }
        guard !isRunning else {
            return .failed(.sessionDied(detail: CompilerRunFailure.Detail.runInFlight))
        }
        let gen = generation
        isRunning = true
        let runner = makeRunner(model)
        live = runner

        let event = await runner.send(message: message, systemPreamble: preamble)

        guard generation == gen else {
            // A shutdown landed while the turn was out. It ended this runner
            // and cleared the surface; the event it resolved the send with is
            // the honest answer, and touching the runner again would end a
            // process twice.
            return event
        }
        runner.shutdown()
        live = nil
        isRunning = false
        return event
    }

    /// End the turn in flight. The call returns `cancelled` and its process is
    /// ended by `call` on the way out.
    func cancel() {
        live?.cancelCurrentRun()
    }

    /// End whatever is in flight: window close, project close, app quit, the
    /// AI toggle. Not optional on any of those paths.
    func shutdown() {
        generation &+= 1
        live?.shutdown()
        live = nil
        isRunning = false
    }

    /// Shut down and forget the window's factory, so a call after the window
    /// is gone refuses rather than spawning against it.
    func detach() {
        shutdown()
        makeRunner = nil
    }

    // MARK: - Production

    /// The real thing: a sealed `ClaudeCLISession`, enabled by the same toggle
    /// every other session reads at every spawn. `preferences` is captured
    /// weak for the orchestrators' reason — `nil` means refuse.
    static func productionRunnerFactory(preferences: UserPreferences) -> RunnerFactory {
        { [weak preferences] model in
            ClaudeCLISession(
                model: model,
                confinement: .sealed,
                cliOverride: nil,
                isEnabled: { preferences?.mcpEnabled ?? false })
        }
    }
}
```

- [ ] **Step 4: Run the two suites**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ColdCallTests -only-testing:MaughamTests/TripwireGrepTests 2>&1 | grep -E "error:|Test Suite '(ColdCallTests|TripwireGrepTests)'|passed|failed" | tail -6`
Expected: both suites green.

- [ ] **Step 5: AREA.md**

In `Maugham/Compiler/AREA.md`, add a section after "The designer — the area's third orchestrator" (before "Tripwires this area sits on"):

```markdown
## Cold calls — the sealed sessions (translation pipeline P2)

`ColdCall.swift` is the one runner every **cold** session shares: a reader, a
collator, a gloss and an Ask-the-collator (spec §5, §9 — the callers arrive in
Plans 3–4; P2 built the runner and wired its teardown). One call = one fresh
process, one briefing sent, one report returned, the process ended. There is
no `ReaderOrchestrator`: warmth would buy nothing (the whole briefing is
re-sent every leg) and would cost blindness.

- **Confinement is an enum on the session, not a setting** —
  `ClaudeCLISession.Confinement.bridged(mcpConfigPath:)` for the compiler,
  translator and designer (the two-flag membrane above, unchanged), `.sealed`
  for a cold call: **no `--mcp-config`, no `--allowedTools`**, `--tools ""` and
  `--strict-mcp-config` as before. Pinned by `ClaudeCLISessionTests
  .test_aSealedSessionSpawnsWithNoBridgeAndNoAllowlist` beside the bridged
  spike pin, and by two `TripwireGrepTests` censuses: `ColdCall.swift` never
  contains `writeMCPConfig`/`.bridged(`/`CompilerAllowlist`, and `.sealed` is
  spelled in production nowhere but `ColdCall.swift` and the session type.
- **One call at a time** (`runInFlight` refusal); no queue — leg order is the
  pipeline's (Plan 3).
- **Teardown: the census's fourth sibling.** `ProjectWindow` owns a `ColdCall`
  beside the three orchestrators; `CompilerRunModifier`'s two arms and
  `.onDisappear` carry `coldCall.shutdown()`/`coldCall.detach()`;
  `TranslatorEnvironmentTests.test_everyWindowEndingPathShutsEverySessionDown`
  counts it.
- **The briefings it will be handed are pure**: `ReaderBriefing` and
  `CollatorBriefing` (this directory) follow `TranslatorBriefing`'s discipline
  — no I/O, no clock. `BriefingDoctrine.swift` is where directives and the
  glossary are read off statement markdown (`Ruling.directive`/`.glossary`,
  MaughamCore) into the plain values all three briefings take.
```

- [ ] **Step 6: Commit**

```bash
git add Maugham/Compiler/ColdCall.swift MaughamTests/ColdCallTests.swift MaughamTests/TripwireGrepTests.swift Maugham/Compiler/AREA.md
git commit -m "feat(compiler): ColdCall — one sealed process per call, with its grep census"
```

---

### Task 3: The window owns a `ColdCall`; the teardown census widens to four

**Files:**
- Modify: `Maugham/Views/CompilerRunModifier.swift`
- Modify: `Maugham/Views/ProjectWindow.swift` (`@State` block ~222–233; `.onDisappear` ~388; modifier call ~392; the configure block ~3747–3780)
- Modify: `MaughamTests/TranslatorEnvironmentTests.swift` (`test_everyWindowEndingPathShutsEverySessionDown` ~688)

**Interfaces:**
- Consumes: `ColdCall` (Task 2).
- Produces: `CompilerRunModifier.init(orchestrator:translator:designer:coldCall:window:activeDocId:mcpEnabled:)`; `ProjectWindow`'s `coldCall` (private `@State`), later read by Plans 3–4's wiring.

- [ ] **Step 1: Widen the census test (it fails first)**

In `test_everyWindowEndingPathShutsEverySessionDown`, after the designer-sibling assertion add:

```swift
        XCTAssertEqual(
            compilerShutdowns,
            modifier.components(separatedBy: "coldCall.shutdown()").count - 1,
            "every compiler shutdown in the modifier needs its cold-call sibling — "
            + "a cold read in flight when the window closes is a billing process "
            + "otherwise (translation pipeline spec §5)")
```

and extend the `ProjectWindow` token loop with a second loop:

```swift
        for token in ["ColdCall()", "coldCall.detach()", "coldCall.configure(",
                      "coldCall: coldCall"] {
            XCTAssertTrue(window.contains(token),
                          "ProjectWindow is missing \(token) — without it the cold-call "
                          + "runner is unwired, unmounted, or outlives the window")
        }
```

Run: `xcodebuild … -only-testing:MaughamTests/TranslatorEnvironmentTests/test_everyWindowEndingPathShutsEverySessionDown 2>&1 | grep -E "error|failed|passed" | tail -3`
Expected: FAIL on the `coldCall.shutdown()` count.

- [ ] **Step 2: Wire it**

`CompilerRunModifier.swift` — add the property after `designer` and the call in both arms:

```swift
    /// The cold-call runner, torn down beside the three warm sessions. A reader
    /// or collator mid-read when the window ends is a live, billing process
    /// otherwise (translation pipeline spec §5, "session owners").
    let coldCall: ColdCall
```

```swift
            .onGlobalEvent(.maughamAppWillTerminate) { _ in
                orchestrator.shutdown()
                translator.shutdown()
                designer.shutdown()
                coldCall.shutdown()
            }
            .onChange(of: mcpEnabled) { _, enabled in
                guard !enabled else { return }
                orchestrator.shutdown()
                translator.shutdown()
                designer.shutdown()
                coldCall.shutdown()
            }
```

Update the doc comment's "**There are THREE session owners now**" paragraph: four owners; the fourth is `ColdCall`, which owns no warm session but can have a process in flight.

`ProjectWindow.swift`:
- beside `@State private var designer = DesignerOrchestrator()` add
  ```swift
      /// The cold-call runner (translation pipeline P2): reader, collator, gloss
      /// and Ask-the-collator will spawn through it (Plans 3–4). Owned here so
      /// its teardown sits beside the three orchestrators'.
      @State private var coldCall = ColdCall()
  ```
- in `.onDisappear`, after `designer.detach()`: `coldCall.detach()`
- the modifier call gains `coldCall: coldCall,` after `designer: designer,`
- in the load block, after `designer.configure(…)`:
  ```swift
              // The cold-call runner, wired beside the three orchestrators. It
              // holds no session between calls; what it needs is the factory
              // that builds a sealed one, and the same toggle every spawn reads.
              coldCall.configure(
                  makeRunner: ColdCall.productionRunnerFactory(preferences: userPreferences))
  ```

- [ ] **Step 3: Build and run the census**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/TranslatorEnvironmentTests 2>&1 | grep -E "error:|Test Suite 'TranslatorEnvironmentTests'|passed|failed" | tail -4`
Expected: green. Also run `-only-testing:MaughamTests/DesignerEnvironmentTests` (its own token census reads the same files).

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/CompilerRunModifier.swift Maugham/Views/ProjectWindow.swift MaughamTests/TranslatorEnvironmentTests.swift
git commit -m "feat(window): ColdCall is the fourth teardown sibling"
```

---

### Task 4: `BriefingDoctrine` — directives and the glossary as plain values

**Files:**
- Create: `Maugham/Compiler/BriefingDoctrine.swift`
- Create: `MaughamTests/BriefingDoctrineTests.swift`

**Interfaces:**
- Consumes: `RulingsSection.parse(_:)`, `Ruling.directive`, `Ruling.glossary`, `Ruling.ruledOn` (MaughamCore, P1).
- Produces:
  ```swift
  struct Directive: Equatable { let paragraphId: String; let text: String; let ruledOn: Date?; let source: Source
      enum Source: Equatable { case craftIntent, editionBrief } }
  enum Directives {
      static func gather(craftIntent: String?, editionBrief: String?) -> [Directive]
      static func byParagraph(_ directives: [Directive]) -> [String: [Directive]]
      static func isDirected(translatedAt: Date?, directives: [Directive]) -> Bool
  }
  struct GlossaryEntry: Equatable { let term: String; let rendering: String; let note: String? }
  enum GlossaryTable {
      static func gather(editionBrief: String?) -> [GlossaryEntry]
      static func render(_ entries: [GlossaryEntry]) -> String?
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/BriefingDoctrineTests.swift
import MaughamCore
import XCTest
@testable import Maugham

/// `BriefingDoctrine.swift` reads directives and the glossary off statement
/// markdown into the plain values every briefing takes — pure, over the P1
/// `Ruling` shapes.
final class BriefingDoctrineTests: XCTestCase {

    private let intent = """
        A quiet book.

        ## Rulings

        - Kelly never lies — ruled 20 Aug 2026, from a run on ¶wnse
        - ¶k7mq: keep the three "and"s - this sentence is a list on purpose — ruled 28 Aug 2026, translator's note
        """

    private let brief = """
        Texture: reads as written in Spanish.

        ## Rulings

        - ¶k7mq: do not elevate this — ruled 29 Aug 2026, translator's note
        - «October» → «Octubre» (the month, never a name) — ruled 28 Aug 2026, glossary
        - «Kelly» → «Kelly» — ruled 28 Aug 2026, glossary
        - ¶zzzz: one sentence, not two
        """

    // MARK: - Directives

    func test_gatherReadsDirectivesFromBothStatementsAndNothingElse() {
        let directives = Directives.gather(craftIntent: intent, editionBrief: brief)
        XCTAssertEqual(directives.map(\.paragraphId), ["k7mq", "k7mq", "zzzz"])
        XCTAssertEqual(directives[0].text, "keep the three \"and\"s - this sentence is a list on purpose")
        XCTAssertEqual(directives[0].source, .craftIntent)
        XCTAssertEqual(directives[1].source, .editionBrief)
        XCTAssertNil(directives[2].ruledOn, "a hand-written bare line has no date")
        XCTAssertNotNil(directives[0].ruledOn)
    }

    func test_gatherOverNothingIsEmpty() {
        XCTAssertEqual(Directives.gather(craftIntent: nil, editionBrief: nil), [])
        XCTAssertEqual(Directives.gather(craftIntent: "", editionBrief: "no rulings here"), [])
    }

    func test_byParagraphGroupsInOrder() {
        let grouped = Directives.byParagraph(
            Directives.gather(craftIntent: intent, editionBrief: brief))
        XCTAssertEqual(grouped["k7mq"]?.count, 2)
        XCTAssertEqual(grouped["zzzz"]?.count, 1)
        XCTAssertNil(grouped["wnse"], "an ordinary ruling mentioning an id in prose is not a directive")
    }

    /// Spec §2: directed = a directive ruled AFTER the record's `at`. Dates in
    /// the stratum are days (UTC midnight), so the comparison is on days.
    func test_isDirectedComparesRuledDayAgainstTheRecordsDay() {
        let ruled = Directives.gather(craftIntent: intent, editionBrief: nil)  // 28 Aug 2026
        let day = { (iso: String) -> Date in ISO8601DateFormatter().date(from: iso)! }

        XCTAssertTrue(Directives.isDirected(
            translatedAt: day("2026-08-27T15:00:00Z"), directives: ruled),
            "translated the day before the ruling → directed")
        XCTAssertTrue(Directives.isDirected(
            translatedAt: day("2026-08-28T15:00:00Z"), directives: ruled),
            "translated the SAME day → directed: the day cannot say which came first, "
            + "and re-sending one paragraph is cheaper than losing the writer's ruling")
        XCTAssertFalse(Directives.isDirected(
            translatedAt: day("2026-08-29T01:00:00Z"), directives: ruled),
            "translated the day after → the ruling was already honoured")
    }

    func test_anUndatedDirectiveNeverDirects() {
        let undated = [Directive(paragraphId: "zzzz", text: "one sentence", ruledOn: nil,
                                 source: .editionBrief)]
        XCTAssertFalse(Directives.isDirected(translatedAt: .distantPast, directives: undated),
                       "no date, no 'after' — it still reaches the translator whenever the "
                       + "paragraph is work, but it must not keep it work for ever")
    }

    func test_isDirectedIsAboutFreshParagraphsOnly() {
        let ruled = Directives.gather(craftIntent: intent, editionBrief: nil)
        XCTAssertFalse(Directives.isDirected(translatedAt: nil, directives: ruled),
                       "no record is `missing`, which is already work")
        XCTAssertFalse(Directives.isDirected(translatedAt: .distantPast, directives: []))
    }

    // MARK: - Glossary

    func test_gatherReadsGlossaryEntriesInOrder() {
        let entries = GlossaryTable.gather(editionBrief: brief)
        XCTAssertEqual(entries, [
            GlossaryEntry(term: "October", rendering: "Octubre", note: "the month, never a name"),
            GlossaryEntry(term: "Kelly", rendering: "Kelly", note: nil),
        ])
        XCTAssertEqual(GlossaryTable.gather(editionBrief: nil), [])
    }

    func test_renderIsAMarkdownTableAndNilWhenEmpty() {
        XCTAssertNil(GlossaryTable.render([]))
        let table = GlossaryTable.render(GlossaryTable.gather(editionBrief: brief))!
        XCTAssertTrue(table.hasPrefix("| Term | Rendering | Note |\n|---|---|---|\n"), table)
        XCTAssertTrue(table.contains("| October | Octubre | the month, never a name |"))
        XCTAssertTrue(table.contains("| Kelly | Kelly |  |"))
    }

    /// A pipe inside a term would break the table's own columns.
    func test_renderEscapesPipes() {
        let table = GlossaryTable.render([
            GlossaryEntry(term: "a|b", rendering: "c", note: nil)])!
        XCTAssertTrue(table.contains("| a\\|b | c |  |"), table)
    }
}
```

- [ ] **Step 2: `./gen.sh`, run, see the compile failure**

Run: `./gen.sh && xcodebuild … -only-testing:MaughamTests/BriefingDoctrineTests 2>&1 | grep -E "error:|Test Suite|passed|failed" | head`
Expected: `Directives` not found.

- [ ] **Step 3: Implement**

`Maugham/Compiler/BriefingDoctrine.swift`:

```swift
import Foundation
import MaughamCore

/// **The writer's directives and glossary, as the plain values a briefing
/// takes** (translation pipeline spec §2, §3, §3.1).
///
/// Both live in the writer's own statements as rulings of a recognised shape
/// (`Ruling.directive`, `Ruling.glossary` — MaughamCore, P1). This file is
/// where a statement's markdown becomes lists the three briefings and the
/// work-list derivation can read without knowing what a statement is. Pure:
/// no store, no clock, no I/O — `TranslatorBriefing`'s discipline, one layer
/// down.

/// One paragraph-anchored instruction from the writer.
struct Directive: Equatable {
    enum Source: Equatable {
        /// The piece's craft intent — a directive about the English, applying
        /// to every edition.
        case craftIntent
        /// This language's edition brief — this edition only.
        case editionBrief
    }

    let paragraphId: String
    let text: String
    /// The day it was ruled (UTC midnight — `RulingsSection`'s date is a day),
    /// or nil for a hand-written line with no suffix.
    let ruledOn: Date?
    let source: Source
}

enum Directives {

    /// Every directive in the two statements, craft intent first, each in its
    /// statement's own order. Either text may be nil (no statement) or carry
    /// no rulings at all.
    static func gather(craftIntent: String?, editionBrief: String?) -> [Directive] {
        directives(in: craftIntent, source: .craftIntent)
            + directives(in: editionBrief, source: .editionBrief)
    }

    static func byParagraph(_ directives: [Directive]) -> [String: [Directive]] {
        Dictionary(grouping: directives, by: \.paragraphId)
    }

    /// **Whether a FRESH paragraph is this round's work anyway** — spec §2's
    /// `directed`: a directive ruled after the paragraph's translation record.
    ///
    /// Compared on **days**, because that is what the stratum stores: a
    /// ruling's `ruledOn` is UTC midnight of its day, so "after" means "ruled
    /// on or after the day the record was written". Same-day counts — the day
    /// cannot say which came first, and re-sending a paragraph once is cheaper
    /// than silently dropping the writer's ruling. The consequence, recorded:
    /// a paragraph directed today stays in the work-list for the rest of
    /// today's Runs. Plan 3's round record is the place to refine that if it
    /// ever costs anything.
    ///
    /// An **undated** directive (a bare hand-written line) never directs: with
    /// no date there is no "after", and treating it as always-after would keep
    /// the paragraph work on every Run for ever. It still reaches the
    /// translator whenever the paragraph is work for another reason.
    ///
    /// `translatedAt == nil` (no record) is `missing`, already work — this
    /// predicate answers only for paragraphs that have a translation.
    static func isDirected(translatedAt: Date?, directives: [Directive]) -> Bool {
        guard let translatedAt else { return false }
        let translatedDay = utc.startOfDay(for: translatedAt)
        return directives.contains { directive in
            guard let ruledOn = directive.ruledOn else { return false }
            return ruledOn >= translatedDay
        }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func directives(in markdown: String?, source: Directive.Source) -> [Directive] {
        guard let markdown, !markdown.isEmpty else { return [] }
        return RulingsSection.parse(markdown).rulings.compactMap { ruling in
            guard let directive = ruling.directive else { return nil }
            return Directive(paragraphId: directive.paragraphId, text: directive.text,
                             ruledOn: ruling.ruledOn, source: source)
        }
    }
}

/// One glossary row: a source-language term and the edition's rendering.
struct GlossaryEntry: Equatable {
    let term: String
    let rendering: String
    let note: String?
}

enum GlossaryTable {

    /// Every glossary-shaped ruling in the edition brief, in the brief's order.
    static func gather(editionBrief: String?) -> [GlossaryEntry] {
        guard let editionBrief, !editionBrief.isEmpty else { return [] }
        return RulingsSection.parse(editionBrief).rulings.compactMap { ruling in
            guard let entry = ruling.glossary else { return nil }
            return GlossaryEntry(term: entry.term, rendering: entry.rendering, note: entry.note)
        }
    }

    /// The table a briefing carries — a markdown table, because a table is
    /// what makes a glossary readable by an author who cannot read the
    /// language (spec §3.1), and what a model reads back as rows. `nil` for
    /// no entries: a briefing announces no empty glossary.
    static func render(_ entries: [GlossaryEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        var lines = ["| Term | Rendering | Note |", "|---|---|---|"]
        for entry in entries {
            lines.append("| \(cell(entry.term)) | \(cell(entry.rendering)) | \(cell(entry.note ?? "")) |")
        }
        return lines.joined(separator: "\n")
    }

    /// A pipe inside a cell is the table's own delimiter; escaped, not stripped
    /// — the writer's term is the writer's term.
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}
```

- [ ] **Step 4: Run**

Run: `xcodebuild … -only-testing:MaughamTests/BriefingDoctrineTests 2>&1 | grep -E "error:|Test Suite 'BriefingDoctrineTests'|passed|failed" | tail -4`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/BriefingDoctrine.swift MaughamTests/BriefingDoctrineTests.swift
git commit -m "feat(compiler): BriefingDoctrine — directives and the glossary as briefing values"
```

---

### Task 5: `ReaderBriefing`

**Files:**
- Create: `Maugham/Compiler/ReaderBriefing.swift`
- Create: `MaughamTests/ReaderBriefingTests.swift`

**Interfaces:**
- Consumes: `ReaderReport.schemaDescription` (P1); `MarkdownDisplayFilter.stripAnchors` (MaughamCore).
- Produces:
  ```swift
  enum ReaderBriefing {
      struct Inputs: Equatable {
          struct Paragraph: Equatable { let paragraphId: String; let translation: String? }
          let readerName: String; let language: String; let authorLanguage: String
          let roleBrief: String?; let editionBriefText: String?
          let paragraphs: [Paragraph]
          var briefedParagraphIds: Set<String>
      }
      static func compose(inputs: Inputs) -> String
      static func gapMarker(_ paragraphId: String) -> String   // "[<id> — not yet translated]"
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/ReaderBriefingTests.swift
import XCTest
@testable import Maugham

/// `ReaderBriefing.compose` is what the blind reader is sent (translation
/// pipeline spec §2). The one property everything else serves: **the reader
/// never sees the source.**
final class ReaderBriefingTests: XCTestCase {

    private let plantedSource = "The fog came in over the harbour."

    private func makeInputs(
        readerName: String = "Ocampo", language: String = "es",
        authorLanguage: String = "English",
        roleBrief: String? = nil, editionBriefText: String? = nil,
        paragraphs: [ReaderBriefing.Inputs.Paragraph] = [
            .init(paragraphId: "a1b2", translation: "Llegó la niebla sobre el puerto."),
            .init(paragraphId: "c3d4", translation: nil),
            .init(paragraphId: "e5f6", translation: "Nadie habló."),
        ]
    ) -> ReaderBriefing.Inputs {
        ReaderBriefing.Inputs(
            readerName: readerName, language: language, authorLanguage: authorLanguage,
            roleBrief: roleBrief, editionBriefText: editionBriefText, paragraphs: paragraphs)
    }

    func test_thePlantedSourceSentenceIsAbsent() {
        // The type has no field a source sentence could travel in; this is
        // the spec's own test, and it also guards the gap marker, which is the
        // one place a careless composer would reach for the source.
        let briefing = ReaderBriefing.compose(inputs: makeInputs())
        XCTAssertFalse(briefing.contains(plantedSource))
        XCTAssertFalse(briefing.contains("fog"))
    }

    func test_roleFrameIsFirstAndNamesReaderLanguageAndBlindness() {
        let briefing = ReaderBriefing.compose(inputs: makeInputs())
        XCTAssertTrue(briefing.hasPrefix("You are Ocampo"), briefing)
        XCTAssertTrue(briefing.contains("es"))
        XCTAssertTrue(briefing.contains("You have not seen, and will not see, any other version"))
        XCTAssertTrue(briefing.contains("in English"), "the report's language is the author's")
    }

    func test_roleBriefIsCarriedWhenPresent() {
        let briefing = ReaderBriefing.compose(
            inputs: makeInputs(roleBrief: "Judge rhythm above all."))
        XCTAssertTrue(briefing.contains("Judge rhythm above all."))
    }

    func test_editionBriefIsCarriedWholeRulingsIncluded() {
        let brief = """
            Texture: reads as written in Spanish.

            ## Rulings

            - ¶a1b2: this fragment is deliberate — ruled 28 Aug 2026, translator's note
            """
        let briefing = ReaderBriefing.compose(inputs: makeInputs(editionBriefText: brief))
        XCTAssertTrue(briefing.contains("## Rulings"))
        XCTAssertTrue(briefing.contains("this fragment is deliberate"),
                      "a declared feature is not a fault — the directive reaches the reader")
        XCTAssertTrue(briefing.contains("Texture: reads as written in Spanish."))
    }

    func test_noEditionBriefComposesNoBriefSection() {
        let briefing = ReaderBriefing.compose(inputs: makeInputs(editionBriefText: nil))
        XCTAssertFalse(briefing.contains("Edition brief"))
    }

    func test_paragraphsAreTaggedInOrderAndAGapIsMarkedNeverFilled() {
        let briefing = ReaderBriefing.compose(inputs: makeInputs())
        let a = briefing.range(of: "[a1b2]")!.lowerBound
        let gap = briefing.range(of: ReaderBriefing.gapMarker("c3d4"))!.lowerBound
        let e = briefing.range(of: "[e5f6]")!.lowerBound
        XCTAssertLessThan(a, gap)
        XCTAssertLessThan(gap, e)
        XCTAssertEqual(ReaderBriefing.gapMarker("c3d4"), "[c3d4 \u{2014} not yet translated]")
        XCTAssertTrue(briefing.contains("Llegó la niebla sobre el puerto."))
    }

    func test_briefedIdsAreTheTranslatedOnesOnly() {
        XCTAssertEqual(makeInputs().briefedParagraphIds, ["a1b2", "e5f6"])
    }

    func test_nothingOfTheCompilersWorldIsBriefed() {
        let briefing = ReaderBriefing.compose(inputs: makeInputs())
        for absent in ["Declared intent", "Established so far", "Queries from earlier rounds"] {
            XCTAssertFalse(briefing.contains(absent), absent)
        }
    }

    func test_reportContractIsTheLastSection() {
        let briefing = ReaderBriefing.compose(inputs: makeInputs())
        XCTAssertTrue(briefing.hasSuffix(ReaderReport.schemaDescription))
    }

    func test_anchorsAreStrippedFromEmbeddedText() {
        let briefing = ReaderBriefing.compose(inputs: makeInputs(
            editionBriefText: "Texture <!-- ¶zzzz --> line",
            paragraphs: [.init(paragraphId: "a1b2", translation: "Hola <!-- ¶a1b2 --> mundo")]))
        XCTAssertFalse(briefing.contains("<!-- ¶"))
    }
}
```

- [ ] **Step 2: `./gen.sh`, run, see failure**

Expected: `ReaderBriefing` not found.

- [ ] **Step 3: Implement**

`Maugham/Compiler/ReaderBriefing.swift`:

```swift
import Foundation
import MaughamCore

/// What the blind reader is sent (translation pipeline spec §2): a role frame,
/// the edition brief verbatim, the translated text in `sequence` order with a
/// marker where nothing stands yet, and the report contract.
///
/// **What is NOT here is the design.** No source text — the type has no field
/// it could travel in. No craft intent essay (it is about the English), no
/// translator queries, no prior reader notes (a reader shown its last notes
/// defends them), no bible (a side channel to the source). A stale or missing
/// paragraph is a gap marker and never the source.
///
/// Pure, `TranslatorBriefing`'s discipline: no I/O, no clock, no store.
enum ReaderBriefing {

    struct Inputs: Equatable {

        /// One paragraph of the edition, in `sequence` order. `translation`
        /// is nil for a paragraph the reader must not see yet — missing, or
        /// stale (the caller passes nil for stale: an out-of-date translation
        /// is not the edition either).
        struct Paragraph: Equatable {
            let paragraphId: String
            let translation: String?

            init(paragraphId: String, translation: String?) {
                self.paragraphId = paragraphId
                self.translation = translation
            }
        }

        let readerName: String
        let language: String
        /// The language the report and every note are written in — the
        /// author's own. Resolved by the caller (Plan 3); this type only
        /// says it.
        let authorLanguage: String
        /// `ProductionRole.effectiveBrief` for this reader.
        let roleBrief: String?
        /// The edition brief verbatim, rulings and directives included.
        let editionBriefText: String?
        let paragraphs: [Paragraph]

        init(readerName: String, language: String, authorLanguage: String,
             roleBrief: String? = nil, editionBriefText: String? = nil,
             paragraphs: [Paragraph] = []) {
            self.readerName = readerName
            self.language = language
            self.authorLanguage = authorLanguage
            self.roleBrief = roleBrief
            self.editionBriefText = editionBriefText
            self.paragraphs = paragraphs
        }

        /// The ids a note may name — `ReaderReport.parse(_:briefedParagraphIds:)`'s
        /// second argument. A gap is not readable and cannot be noted.
        var briefedParagraphIds: Set<String> {
            Set(paragraphs.compactMap { $0.translation == nil ? nil : $0.paragraphId })
        }
    }

    static func compose(inputs: Inputs) -> String {
        var sections: [String] = [roleFrame(inputs)]
        if let brief = inputs.editionBriefText, !brief.isEmpty {
            sections.append(
                "Edition brief for \(inputs.language) — the author's doctrine for this "
                    + "edition: its register, what stays foreign, and rulings settled in "
                    + "earlier sessions. A feature the brief declares deliberate is not a "
                    + "fault:\n" + cleaned(brief))
        }
        sections.append(textSection(inputs))
        sections.append(ReaderReport.schemaDescription)
        return sections.joined(separator: "\n\n")
    }

    /// `[<id> — not yet translated]`, spec §2's exact shape.
    static func gapMarker(_ paragraphId: String) -> String {
        "[\(paragraphId) \u{2014} not yet translated]"
    }

    private static func roleFrame(_ inputs: Inputs) -> String {
        var lines = [
            "You are \(inputs.readerName), reading the \(inputs.language) edition of a "
                + "book. You have not seen, and will not see, any other version of it. "
                + "Write your notes and your report in \(inputs.authorLanguage): the "
                + "author reads that language and not this one."
        ]
        if let brief = inputs.roleBrief, !brief.isEmpty {
            lines.append(cleaned(brief))
        }
        return lines.joined(separator: "\n")
    }

    private static func textSection(_ inputs: Inputs) -> String {
        var lines = [
            "The book, in \(inputs.language), paragraph by paragraph. A paragraph "
                + "marked not yet translated has no text for you; do not note it and "
                + "do not guess at it:"
        ]
        for paragraph in inputs.paragraphs {
            if let translation = paragraph.translation {
                lines.append("[\(paragraph.paragraphId)]")
                lines.append(cleaned(translation))
            } else {
                lines.append(gapMarker(paragraph.paragraphId))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func cleaned(_ text: String) -> String {
        MarkdownDisplayFilter.stripAnchors(text)
    }
}
```

- [ ] **Step 4: Run** — `-only-testing:MaughamTests/ReaderBriefingTests`. Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/ReaderBriefing.swift MaughamTests/ReaderBriefingTests.swift
git commit -m "feat(compiler): ReaderBriefing — the blind read, source-free by construction"
```

---

### Task 6: `CollatorBriefing`

**Files:**
- Create: `Maugham/Compiler/CollatorBriefing.swift`
- Create: `MaughamTests/CollatorBriefingTests.swift`

**Interfaces:**
- Consumes: `CollatorReport.schemaDescription` (P1); `GlossaryEntry`, `GlossaryTable.render` (Task 4).
- Produces:
  ```swift
  enum CollatorBriefing {
      struct Inputs: Equatable {
          struct Pair: Equatable { let paragraphId: String; let sourceText: String; let translation: String?; let directives: [String] }
          let collatorName, language, authorLanguage: String
          let roleBrief: String?; let craftIntentText: String?; let editionBriefText: String?
          let glossary: [GlossaryEntry]; let pairs: [Pair]
          var briefedParagraphIds: Set<String>
      }
      static func compose(inputs: Inputs) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/CollatorBriefingTests.swift
import XCTest
@testable import Maugham

/// `CollatorBriefing.compose` — both texts side by side, the writer's intent,
/// the brief, the glossary, and every directive under its paragraph
/// (translation pipeline spec §2).
final class CollatorBriefingTests: XCTestCase {

    private func makeInputs(
        craftIntentText: String? = nil, editionBriefText: String? = nil,
        glossary: [GlossaryEntry] = [],
        pairs: [CollatorBriefing.Inputs.Pair] = [
            .init(paragraphId: "a1b2", sourceText: "The fog came in.",
                  translation: "Llegó la niebla.", directives: ["keep it one sentence"]),
            .init(paragraphId: "c3d4", sourceText: "She closed the door.",
                  translation: nil, directives: []),
        ]
    ) -> CollatorBriefing.Inputs {
        CollatorBriefing.Inputs(
            collatorName: "Borges", language: "es", authorLanguage: "English",
            roleBrief: "Meaning is your only business.",
            craftIntentText: craftIntentText, editionBriefText: editionBriefText,
            glossary: glossary, pairs: pairs)
    }

    func test_roleFrameIsFirstAndNamesBothTextsAndTheReportLanguage() {
        let briefing = CollatorBriefing.compose(inputs: makeInputs())
        XCTAssertTrue(briefing.hasPrefix("You are Borges"), briefing)
        XCTAssertTrue(briefing.contains("original and the es translation side by side"))
        XCTAssertTrue(briefing.contains("in English"))
        XCTAssertTrue(briefing.contains("Meaning is your only business."))
    }

    func test_thePairCarriesSourceThenTranslationThenItsDirectives() {
        let briefing = CollatorBriefing.compose(inputs: makeInputs())
        let id = briefing.range(of: "[a1b2]")!.lowerBound
        let source = briefing.range(of: "Original: The fog came in.")!.lowerBound
        let translation = briefing.range(of: "Translation: Llegó la niebla.")!.lowerBound
        let directive = briefing.range(of: "Directive from the author: keep it one sentence")!.lowerBound
        XCTAssertLessThan(id, source)
        XCTAssertLessThan(source, translation)
        XCTAssertLessThan(translation, directive)
    }

    func test_anUntranslatedPairIsListedAsSuchWithItsSource() {
        let briefing = CollatorBriefing.compose(inputs: makeInputs())
        XCTAssertTrue(briefing.contains("[c3d4] (not translated)"))
        XCTAssertTrue(briefing.contains("Original: She closed the door."))
        XCTAssertFalse(briefing.contains("Translation: \n"), "no empty translation line")
    }

    func test_briefedIdsAreThePairsWithATranslation() {
        XCTAssertEqual(makeInputs().briefedParagraphIds, ["a1b2"])
    }

    func test_intentAndBriefAreCarriedVerbatim() {
        let briefing = CollatorBriefing.compose(inputs: makeInputs(
            craftIntentText: "Plainness is the point.",
            editionBriefText: "Texture: fluent.\n\n## Rulings\n\n- «October» → «Octubre» — ruled 28 Aug 2026, glossary"))
        XCTAssertTrue(briefing.contains("Declared intent:\nPlainness is the point."))
        XCTAssertTrue(briefing.contains("Texture: fluent."))
        XCTAssertTrue(briefing.contains("## Rulings"))
    }

    func test_theGlossaryIsATableAndAbsentWhenEmpty() {
        let with = CollatorBriefing.compose(inputs: makeInputs(
            glossary: [GlossaryEntry(term: "October", rendering: "Octubre", note: nil)]))
        XCTAssertTrue(with.contains("| Term | Rendering | Note |"))
        XCTAssertTrue(with.contains("| October | Octubre |  |"))
        XCTAssertTrue(with.contains("rendered two ways"), "the consistency remit is said in words")
        let without = CollatorBriefing.compose(inputs: makeInputs())
        XCTAssertFalse(without.contains("| Term |"))
    }

    func test_nothingOfTheOtherSessionsIsBriefed() {
        let briefing = CollatorBriefing.compose(inputs: makeInputs())
        for absent in ["Established so far", "Queries from earlier rounds", "reader's notes"] {
            XCTAssertFalse(briefing.contains(absent), absent)
        }
    }

    func test_reportContractIsLast() {
        XCTAssertTrue(CollatorBriefing.compose(inputs: makeInputs())
            .hasSuffix(CollatorReport.schemaDescription))
    }

    func test_anchorsAreStripped() {
        let briefing = CollatorBriefing.compose(inputs: makeInputs(pairs: [
            .init(paragraphId: "a1b2", sourceText: "Fog <!-- ¶a1b2 --> came",
                  translation: "Niebla <!-- ¶a1b2 -->", directives: [])]))
        XCTAssertFalse(briefing.contains("<!-- ¶"))
    }
}
```

- [ ] **Step 2: `./gen.sh`, run, see failure**

- [ ] **Step 3: Implement**

`Maugham/Compiler/CollatorBriefing.swift`:

```swift
import Foundation
import MaughamCore

/// What the collator is sent (translation pipeline spec §2): role frame and
/// doctrine; craft intent verbatim (fidelity to what the writer MEANT is its
/// business); the edition brief verbatim; the glossary as a table; and the
/// paragraph pairs in `sequence` order — original, translation, then that
/// paragraph's directives, which are the standard for it.
///
/// **Not briefed**: reader notes, translator queries, the bible. Pure.
enum CollatorBriefing {

    struct Inputs: Equatable {

        /// One paragraph, both texts. `translation` nil = untranslated, listed
        /// as such so the collator can report `untranslated` rather than guess.
        struct Pair: Equatable {
            let paragraphId: String
            let sourceText: String
            let translation: String?
            /// The writer's directives on this paragraph, from either
            /// statement — `Directives.byParagraph`'s texts.
            let directives: [String]

            init(paragraphId: String, sourceText: String, translation: String?,
                 directives: [String] = []) {
                self.paragraphId = paragraphId
                self.sourceText = sourceText
                self.translation = translation
                self.directives = directives
            }
        }

        let collatorName: String
        let language: String
        let authorLanguage: String
        let roleBrief: String?
        let craftIntentText: String?
        let editionBriefText: String?
        let glossary: [GlossaryEntry]
        let pairs: [Pair]

        init(collatorName: String, language: String, authorLanguage: String,
             roleBrief: String? = nil, craftIntentText: String? = nil,
             editionBriefText: String? = nil, glossary: [GlossaryEntry] = [],
             pairs: [Pair] = []) {
            self.collatorName = collatorName
            self.language = language
            self.authorLanguage = authorLanguage
            self.roleBrief = roleBrief
            self.craftIntentText = craftIntentText
            self.editionBriefText = editionBriefText
            self.glossary = glossary
            self.pairs = pairs
        }

        /// `CollatorReport.parse(_:briefedParagraphIds:)`'s second argument:
        /// a departure names a paragraph with a translation to depart in.
        var briefedParagraphIds: Set<String> {
            Set(pairs.compactMap { $0.translation == nil ? nil : $0.paragraphId })
        }
    }

    static func compose(inputs: Inputs) -> String {
        var sections: [String] = [roleFrame(inputs)]
        if let intent = inputs.craftIntentText, !intent.isEmpty {
            sections.append("Declared intent:\n\(cleaned(intent))")
        }
        if let brief = inputs.editionBriefText, !brief.isEmpty {
            sections.append(
                "Edition brief for \(inputs.language) — the author's doctrine for this "
                    + "edition, rulings included. A directive on a paragraph is the "
                    + "standard for that paragraph:\n" + cleaned(brief))
        }
        if let table = GlossaryTable.render(inputs.glossary) {
            sections.append(
                "Glossary — the edition's fixed renderings. Read the whole document "
                    + "against it: a name or term rendered two ways is a departure "
                    + "(kind \"inconsistency\") even when each paragraph is fine alone:\n"
                    + table)
        }
        sections.append(pairsSection(inputs))
        sections.append(CollatorReport.schemaDescription)
        return sections.joined(separator: "\n\n")
    }

    private static func roleFrame(_ inputs: Inputs) -> String {
        var lines = [
            "You are \(inputs.collatorName). You hold the original and the "
                + "\(inputs.language) translation side by side. Write every note and "
                + "every gloss in \(inputs.authorLanguage): the author reads that "
                + "language and not this one, and the gloss is how they will judge "
                + "what the translation now says."
        ]
        if let brief = inputs.roleBrief, !brief.isEmpty {
            lines.append(cleaned(brief))
        }
        return lines.joined(separator: "\n")
    }

    private static func pairsSection(_ inputs: Inputs) -> String {
        var lines = [
            "The document, paragraph by paragraph — the original, then what the "
                + "translation says there, then any directive the author has ruled "
                + "on that paragraph:"
        ]
        for pair in inputs.pairs {
            if let translation = pair.translation {
                lines.append("[\(pair.paragraphId)]")
                lines.append("Original: \(cleaned(pair.sourceText))")
                lines.append("Translation: \(cleaned(translation))")
            } else {
                lines.append("[\(pair.paragraphId)] (not translated)")
                lines.append("Original: \(cleaned(pair.sourceText))")
            }
            for directive in pair.directives {
                lines.append("Directive from the author: \(cleaned(directive))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func cleaned(_ text: String) -> String {
        MarkdownDisplayFilter.stripAnchors(text)
    }
}
```

- [ ] **Step 4: Run** — `-only-testing:MaughamTests/CollatorBriefingTests`. Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/CollatorBriefing.swift MaughamTests/CollatorBriefingTests.swift
git commit -m "feat(compiler): CollatorBriefing — paired texts, directives under their paragraphs, the glossary table"
```

---

### Task 7: `TranslatorBriefing.Mode` — directives, the glossary, and the fix leg

**Files:**
- Modify: `Maugham/Compiler/TranslatorBriefing.swift`
- Modify: `Maugham/Compiler/TranslatorOrchestrator.swift` (`begin` ~461, `finish` ~480–508)
- Modify: `MaughamTests/TranslatorBriefingTests.swift` (append tests; adjust `makeInputs` if it has no `mode`/`glossary` args — it should keep its defaults so nothing existing changes)
- Modify: `MaughamTests/TranslatorOrchestratorTests.swift` (+1)

**Interfaces:**
- Consumes: `TranslatorReport.Mode`, `.fixSchemaDescription` (P1); `GlossaryEntry`, `GlossaryTable.render` (Task 4).
- Produces:
  ```swift
  extension TranslatorBriefing {
      struct FixNote: Equatable { let id: String; let paragraphId: String; let author: String; let kind: String; let severity: String?; let text: String }
      enum Mode: Equatable { case translate; case fix(notes: [FixNote], isFinalLeg: Bool) }
  }
  // Inputs gains `mode: Mode = .translate`, `glossary: [GlossaryEntry] = []`, `var reportMode: TranslatorReport.Mode`
  // Inputs.WorkItem gains `directives: [String] = []`
  ```

- [ ] **Step 1: Write the failing tests**

Append to `TranslatorBriefingTests` (its `makeInputs` helper is at the bottom of the file — add `mode:` and `glossary:` parameters with defaults `.translate` / `[]` and pass them through; `WorkItem` construction sites need no change because `directives` defaults to `[]`):

```swift
    // MARK: - Directives and the glossary (translation pipeline P2)

    func test_workItem_carriesItsDirectivesAsInstructions() {
        let inputs = makeInputs(workList: [
            .init(paragraphId: "a1b2", sourceText: "And, and, and.", status: .missing,
                  directives: ["keep the three \"and\"s", "one sentence, not two"])])
        let briefing = TranslatorBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("Directive from the writer: keep the three \"and\"s"))
        XCTAssertTrue(briefing.contains("Directive from the writer: one sentence, not two"))
    }

    /// A directed paragraph is FRESH with a prior translation — the status
    /// arm says why it is work.
    func test_workItem_directedFreshEntry_saysSoAndHandsOverThePriorTranslation() {
        let inputs = makeInputs(workList: [
            .init(paragraphId: "a1b2", sourceText: "And, and, and.", status: .fresh,
                  priorTranslation: "Y, y, y.", directives: ["keep the three \"and\"s"])])
        let briefing = TranslatorBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("[a1b2] (directed"), briefing)
        XCTAssertTrue(briefing.contains("Prior translation: Y, y, y."))
    }

    func test_glossary_isATableAfterTheBriefAndAbsentWhenEmpty() {
        let with = TranslatorBriefing.compose(inputs: makeInputs(
            editionBriefText: "Texture: fluent.",
            glossary: [GlossaryEntry(term: "October", rendering: "Octubre", note: "the month")]))
        let brief = with.range(of: "Texture: fluent.")!.lowerBound
        let table = with.range(of: "| October | Octubre | the month |")!.lowerBound
        XCTAssertLessThan(brief, table)
        XCTAssertTrue(with.contains("Glossary"))
        XCTAssertFalse(TranslatorBriefing.compose(inputs: makeInputs()).contains("| Term |"))
    }

    // MARK: - Fix mode

    private func fixInputs(isFinalLeg: Bool = false) -> TranslatorBriefing.Inputs {
        makeInputs(
            workList: [
                .init(paragraphId: "a1b2", sourceText: "The fog came in.", status: .fresh,
                      priorTranslation: "La niebla vino.", directives: ["plain, not lyrical"]),
                .init(paragraphId: "c3d4", sourceText: "She closed the door.", status: .fresh,
                      priorTranslation: "Cerró la puerta."),
            ],
            mode: .fix(notes: [
                .init(id: "n-1", paragraphId: "a1b2", author: "Ocampo", kind: "rhythm",
                      severity: "major", text: "The sentence limps."),
                .init(id: "n-2", paragraphId: "c3d4", author: "Borges", kind: "omission",
                      severity: nil, text: "The door is not closed in the translation."),
            ], isFinalLeg: isFinalLeg))
    }

    func test_fixMode_workListIsTheNotedParagraphsWithTheirNotes() {
        let briefing = TranslatorBriefing.compose(inputs: fixInputs())
        XCTAssertTrue(briefing.contains("[a1b2] (noted)"))
        XCTAssertTrue(briefing.contains("Current translation: La niebla vino."))
        XCTAssertTrue(briefing.contains("Note n-1 from Ocampo (rhythm, major): The sentence limps."))
        XCTAssertTrue(briefing.contains("Note n-2 from Borges (omission): The door is not closed in the translation."))
        XCTAssertTrue(briefing.contains("Directive from the writer: plain, not lyrical"))
    }

    /// The repair sentence, in words: a repair, not a polish; unnoted
    /// paragraphs untouched; every note answered.
    func test_fixMode_saysItIsARepairAndCarriesTheFixContract() {
        let briefing = TranslatorBriefing.compose(inputs: fixInputs())
        XCTAssertTrue(briefing.contains(TranslatorBriefing.repairSentence))
        XCTAssertTrue(briefing.contains(TranslatorReport.schemaDescription))
        XCTAssertTrue(briefing.contains(TranslatorReport.fixSchemaDescription))
        XCTAssertTrue(briefing.contains(TranslatorBriefing.notFinalLegSentence))
        XCTAssertFalse(briefing.contains(TranslatorBriefing.finalLegSentence))
    }

    func test_fixMode_finalLegAsksForSummaryAndProposals() {
        let briefing = TranslatorBriefing.compose(inputs: fixInputs(isFinalLeg: true))
        XCTAssertTrue(briefing.contains(TranslatorBriefing.finalLegSentence))
        XCTAssertFalse(briefing.contains(TranslatorBriefing.notFinalLegSentence))
    }

    func test_reportMode_followsTheBriefingMode() {
        XCTAssertEqual(makeInputs().reportMode, .translate)
        XCTAssertEqual(fixInputs().reportMode, .fix(briefedNoteIds: ["n-1", "n-2"]))
    }

    func test_translateMode_carriesNoFixContract() {
        let briefing = TranslatorBriefing.compose(inputs: makeInputs())
        XCTAssertFalse(briefing.contains(TranslatorReport.fixSchemaDescription))
        XCTAssertTrue(briefing.hasSuffix(TranslatorReport.schemaDescription))
    }
```

And in `TranslatorOrchestratorTests`, one test that the orchestrator parses a fix-mode round with the fix parser (find the suite's `makeRound`/harness helpers and follow `test_aFailedRunIngestsNothing`'s shape):

```swift
    /// The parser's mode is the briefing's: a fix-mode round whose report
    /// leaves a briefed note unaccounted for is unusable output, not a
    /// translate-mode success.
    func test_aFixModeRoundIsParsedWithTheFixContract() throws {
        let runner = SpyRunner()
        // A translate-shaped report — entries only, no `addressed`/`declined`
        // — which a fix-mode parse must refuse: the briefed note is unaccounted for.
        runner.nextEvent = .resultText(Self.oneEntry)
        let note = TranslatorBriefing.FixNote(
            id: "n-1", paragraphId: "a1b2", author: "Ocampo", kind: "rhythm",
            severity: "major", text: "The sentence limps.")
        let harness = try makeHarness(
            runner: runner,
            round: makeRound(mode: .fix(notes: [note], isFinalLeg: false)))

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        settle()

        XCTAssertTrue(harness.ingests.isEmpty,
                      "a fix leg's report that ignores its note must not be ingested")
        guard case .failed(_, _, let reported, _) = harness.orchestrator.runState else {
            return XCTFail("expected unusableOutput, got \(harness.orchestrator.runState)")
        }
        XCTAssertEqual(reported, .run(.unusableOutput))
        XCTAssertTrue(runner.sends[0].message.contains(TranslatorBriefing.repairSentence),
                      "…and the briefing that went out was the fix leg's")
    }
```

`makeRound(work:)` (the suite's helper, ~line 76) gains a `mode: TranslatorBriefing.Mode = .translate` parameter passed into its `TranslatorBriefing.Inputs(…)` init; when the mode is `.fix` the helper's work items should be built `.fresh` with `priorTranslation: "Y."` so the round is shaped like a real fix leg. `awaitSends(_:on:)`, `settle()`, `docId`, `language`, `oneEntry` are the suite's existing helpers/constants.

- [ ] **Step 2: Run to see failures** — `-only-testing:MaughamTests/TranslatorBriefingTests`. Expected: compile errors on `directives:`, `mode:`, `FixNote`.

- [ ] **Step 3: Implement**

In `TranslatorBriefing.swift`:

Add to `Inputs.WorkItem`: `let directives: [String]` with init parameter `directives: [String] = []` (doc: "the writer's directives on this paragraph, as instructions — `Directives.byParagraph`'s texts").

Add, inside `enum TranslatorBriefing` before `Inputs`:

```swift
    /// One note a fix leg is asked to answer — a reader's note or a collator's
    /// departure, flattened to what the translator needs: who said it, what
    /// kind, how bad, and where. `id` is what `addressed`/`declined` name
    /// (`TranslatorReport.Mode.fix(briefedNoteIds:)`).
    struct FixNote: Equatable {
        let id: String
        let paragraphId: String
        let author: String
        let kind: String
        let severity: String?
        let text: String

        init(id: String, paragraphId: String, author: String, kind: String,
             severity: String? = nil, text: String) {
            self.id = id
            self.paragraphId = paragraphId
            self.author = author
            self.kind = kind
            self.severity = severity
            self.text = text
        }
    }

    /// Which leg this briefing is for (spec §2). `.translate` is today's round
    /// plus directives and the glossary; `.fix` is a repair of exactly the
    /// noted paragraphs — the caller's work-list IS those paragraphs, each
    /// `.fresh` with its current translation in `priorTranslation`.
    /// `isFinalLeg` is leg 7: the one that also returns the summary and the
    /// glossary proposals.
    enum Mode: Equatable {
        case translate
        case fix(notes: [FixNote], isFinalLeg: Bool)
    }

    /// The fix leg's sentence, in words the model cannot read as a polish.
    static let repairSentence =
        "This is a repair of the noted paragraphs, not a polish. Leave every "
        + "paragraph that carries no note exactly as it is — do not send an entry "
        + "for it. For every note below, either rewrite that paragraph in answer "
        + "to it or decline it with a reason; never stay silent on a note."

    static let finalLegSentence =
        "This is the round's last fix leg: include \"summary\" and "
        + "\"glossary_proposals\" in your report."

    static let notFinalLegSentence =
        "Leave \"summary\" and \"glossary_proposals\" out of this leg's report; "
        + "a later leg asks for them."
```

Add to `Inputs`: `let mode: Mode`, `let glossary: [GlossaryEntry]` with init parameters `mode: Mode = .translate, glossary: [GlossaryEntry] = []`, plus:

```swift
        /// The parser's mode for this briefing's report — one derivation, so
        /// the orchestrator cannot brief a fix leg and parse a translate one.
        var reportMode: TranslatorReport.Mode {
            switch mode {
            case .translate: return .translate
            case .fix(let notes, _): return .fix(briefedNoteIds: Set(notes.map(\.id)))
            }
        }
```

In `compose`, after the edition-brief section:

```swift
        if let table = GlossaryTable.render(inputs.glossary) {
            sections.append(
                "Glossary — the edition's fixed renderings. Render these terms "
                    + "exactly so, every time:\n" + table)
        }
```

Replace `sections.append(workListSection(inputs.workList))` with `sections.append(workListSection(inputs))`, and the trailing contract with:

```swift
        switch inputs.mode {
        case .translate:
            sections.append(TranslatorReport.schemaDescription)
        case .fix(_, let isFinalLeg):
            sections.append(
                [TranslatorReport.schemaDescription, TranslatorReport.fixSchemaDescription,
                 isFinalLeg ? finalLegSentence : notFinalLegSentence]
                    .joined(separator: "\n"))
        }
```

Replace `workListSection`/`workItemLines`:

```swift
    private static func workListSection(_ inputs: Inputs) -> String {
        switch inputs.mode {
        case .translate:
            guard !inputs.workList.isEmpty else {
                return "This round's work: nothing needs translation right now."
            }
            var lines = [
                "This round's work — for each paragraph below, answer with an "
                    + "entry: a full translation, or \"verbatim\" if it should carry "
                    + "over unchanged:"
            ]
            for item in inputs.workList {
                lines.append(contentsOf: workItemLines(item))
                lines.append(contentsOf: directiveLines(item))
            }
            return lines.joined(separator: "\n")

        case .fix(let notes, _):
            let byParagraph = Dictionary(grouping: notes, by: \.paragraphId)
            var lines = [repairSentence, "The noted paragraphs:"]
            for item in inputs.workList {
                lines.append("[\(item.paragraphId)] (noted)")
                lines.append("Source: \(cleaned(item.sourceText))")
                if let current = item.priorTranslation {
                    lines.append("Current translation: \(cleaned(current))")
                }
                for note in byParagraph[item.paragraphId] ?? [] {
                    lines.append(noteLine(note))
                }
                lines.append(contentsOf: directiveLines(item))
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func noteLine(_ note: FixNote) -> String {
        let qualifier = [note.kind, note.severity].compactMap { $0 }.joined(separator: ", ")
        return "Note \(note.id) from \(note.author) (\(qualifier)): \(cleaned(note.text))"
    }

    private static func directiveLines(_ item: Inputs.WorkItem) -> [String] {
        item.directives.map { "Directive from the writer: \(cleaned($0))" }
    }

    private static func workItemLines(_ item: Inputs.WorkItem) -> [String] {
        switch item.status {
        case .missing:
            return [
                "[\(item.paragraphId)] (missing — no translation yet)",
                cleaned(item.sourceText),
            ]
        case .stale:
            var lines = [
                "[\(item.paragraphId)] (stale — the source has changed since this "
                    + "was last translated)",
                "Source: \(cleaned(item.sourceText))",
            ]
            if let prior = item.priorTranslation {
                lines.append("Prior translation: \(cleaned(prior))")
            }
            return lines
        case .fresh:
            // A fresh item in the work-list is a DIRECTED one (spec §2): the
            // writer ruled on it after it was translated. Say why it is here,
            // and hand over what it currently says so the rewrite is a repair
            // against a standard rather than a fresh guess. A fresh item with
            // no directive is the old permissive arm, rendered plainly.
            guard !item.directives.isEmpty else {
                return ["[\(item.paragraphId)]", cleaned(item.sourceText)]
            }
            var lines = [
                "[\(item.paragraphId)] (directed — the writer has ruled on this "
                    + "paragraph since it was translated; the directive below is the "
                    + "standard for it)",
                "Source: \(cleaned(item.sourceText))",
            ]
            if let prior = item.priorTranslation {
                lines.append("Prior translation: \(cleaned(prior))")
            }
            return lines
        }
    }
```

Update the type's doc comment ("Assembles what one translator run sends…") with one sentence: "Since P2 it composes in two `Mode`s — `.translate` (with directives and the glossary) and `.fix` (a repair of the noted paragraphs)."

In `TranslatorOrchestrator.swift`: thread the mode to `finish`. `begin` calls `finish(event, pair:, runId:, identity:, briefedSourceHashes: round.sourceHashes, reportMode: inputs.reportMode, generation:)`; `finish` gains `reportMode: TranslatorReport.Mode` and parses with `TranslatorReport.parse(text, mode: reportMode)`. The doc comment on `finish` gains: "The parser's mode is the briefing's (`Inputs.reportMode`) — a fix leg's report is held to its briefed notes."

- [ ] **Step 4: Run** — `-only-testing:MaughamTests/TranslatorBriefingTests -only-testing:MaughamTests/TranslatorOrchestratorTests`. Expected: green, including every pre-existing test unchanged.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/TranslatorBriefing.swift Maugham/Compiler/TranslatorOrchestrator.swift MaughamTests/TranslatorBriefingTests.swift MaughamTests/TranslatorOrchestratorTests.swift
git commit -m "feat(compiler): TranslatorBriefing.Mode — directives, the glossary, and the fix leg"
```

---

### Task 8: The production gather — directed work-list, directives, glossary

**Files:**
- Modify: `Maugham/Compiler/TranslatorEnvironment+Project.swift` (`briefing(docId:language:store:documentStore:bible:projectURL:)` ~130–205)
- Modify: `MaughamTests/TranslatorEnvironmentTests.swift` (+2 tests beside `test_theBriefingAsksForWhatIsStaleOrMissingOnly`)

**Interfaces:**
- Consumes: `Directives.gather/byParagraph/isDirected`, `GlossaryTable.gather` (Task 4); `TranslationStore.latestByParagraph(_:)`, `TranslationRecord.at` (MaughamCore); `WorkItem.directives`, `Inputs.glossary` (Task 7).
- Produces: nothing new — the same `briefRound` closure, now answering spec §2's work-list.

- [ ] **Step 1: Write the failing tests**

```swift
    /// **Spec §2's `directed`**: a fresh paragraph carrying a directive ruled
    /// after its record is this round's work; one whose directive is older
    /// than its record is not.
    func test_aDirectiveNewerThanTheRecordMakesAFreshParagraphWork() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence
        // Every paragraph fresh, translated "two days ago" so the ruling days
        // below fall clearly on either side.
        let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
        for id in ids {
            try await TranslationStore.append(
                TranslationRecord(
                    paragraphId: id, language: "es", text: "…",
                    sourceHash: TranslationHash.hash(harness.doc.paragraphs[id] ?? ""),
                    at: twoDaysAgo),
                forDocId: harness.doc.docId,
                deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
                in: harness.projectURL)
        }
        _ = try await harness.environment.translatorIdentity("es")

        // ids[0]: directive ruled TODAY (after the record) → directed.
        try await RulingPerformer.rule(
            Ruling.directiveText(paragraphId: ids[0], "keep it plain"),
            provenance: Ruling.Provenance.translatorsNote,
            kind: .intent, forScope: .document(harness.doc.docId),
            store: harness.projectStore, world: nil)
        // ids[1]: a directive dated a week BEFORE the record → not directed.
        let brief = try await harness.projectStore.createStatement(
            kind: .editionBrief("es"), scope: .project)
        try await harness.projectStore.mutateStatementText(
            of: brief, session: "test-\(UUID().uuidString)") { markdown in
            RulingsSection.appending(
                Ruling.directiveText(paragraphId: ids[1], "one sentence"),
                provenance: Ruling.Provenance.translatorsNote,
                on: twoDaysAgo.addingTimeInterval(-7 * 86_400), to: markdown)
        }

        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        XCTAssertEqual(inputs.workList.map(\.paragraphId), [ids[0]])
        XCTAssertEqual(inputs.workList.first?.status, .fresh)
        XCTAssertEqual(inputs.workList.first?.priorTranslation, "…",
                       "a directed item hands over what it currently says")
        XCTAssertEqual(inputs.workList.first?.directives, ["keep it plain"])
        XCTAssertEqual(gathered?.sourceHashes.keys.sorted(), [ids[0]],
                       "the mid-run-edit guard covers the directed item too")

        await harness.documentStore.close()
    }

    /// Directives and the glossary reach the briefing off the writer's own
    /// statements — craft intent's for every edition, the brief's for this one.
    func test_theBriefingCarriesDirectivesFromBothStatementsAndTheGlossary() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence
        _ = try await harness.environment.translatorIdentity("es")
        try await RulingPerformer.rule(
            Ruling.directiveText(paragraphId: ids[2], "this fragment is deliberate"),
            provenance: Ruling.Provenance.translatorsNote,
            kind: .intent, forScope: .document(harness.doc.docId),
            store: harness.projectStore, world: nil)
        try await RulingPerformer.rule(
            Ruling.directiveText(paragraphId: ids[2], "do not elevate this"),
            provenance: Ruling.Provenance.translatorsNote,
            kind: .editionBrief("es"), forScope: .project,
            store: harness.projectStore, world: nil)
        try await RulingPerformer.rule(
            Ruling.glossaryText(term: "October", rendering: "Octubre", note: "the month"),
            provenance: Ruling.Provenance.glossary,
            kind: .editionBrief("es"), forScope: .project,
            store: harness.projectStore, world: nil)

        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        let last = try XCTUnwrap(inputs.workList.first { $0.paragraphId == ids[2] })
        XCTAssertEqual(last.directives, ["this fragment is deliberate", "do not elevate this"],
                       "craft intent's first, then the brief's")
        XCTAssertEqual(inputs.glossary,
                       [GlossaryEntry(term: "October", rendering: "Octubre", note: "the month")])
        XCTAssertEqual(inputs.mode, .translate)

        await harness.documentStore.close()
    }
```

(`RulingsSection.appending(_:provenance:on:to:)` is the P1-era MaughamCore composer `RulingPerformer.rule` itself calls — check its exact label spelling in `RulingsSection.swift` ~line 135 and match it.)

- [ ] **Step 2: Run to see the failure** — first test fails on `workList == []` (a fresh paragraph is not work today).

- [ ] **Step 3: Implement**

In `briefing(…)`, restructure the middle:

```swift
        let intentText = craftIntentText(docId: docId, store: store)
        let briefText = editionBriefText(language: language, store: store)
        let directives = Directives.byParagraph(
            Directives.gather(craftIntent: intentText, editionBrief: briefText))

        let records = TranslationStore.loadMerged(
            forDocId: docId, language: language, in: projectURL)
        let latest = TranslationStore.latestByParagraph(records)
        let derived = TranslationDeriver.derive(
            records: records,
            sequence: state.sequence, paragraphs: state.paragraphs, language: language)

        // **The delta is `stale ∪ missing ∪ directed`** (spec §2). Stale and
        // missing are the deriver's; directed is a FRESH paragraph the writer
        // has ruled on since it was translated — two dates, nothing stored,
        // which is how "Keep mine" on a round report reaches the next Run.
        let work = derived.entries.filter { entry in
            entry.status != .fresh || Directives.isDirected(
                translatedAt: latest[entry.paragraphId]?.at,
                directives: directives[entry.paragraphId] ?? [])
        }
        let workList = work.map { entry in
            TranslatorBriefing.Inputs.WorkItem(
                paragraphId: entry.paragraphId,
                sourceText: MarkdownDisplayFilter.stripTaskAnchorsInline(entry.sourceText),
                status: entry.status,
                // A stale item's last answer is worth reconsidering; a DIRECTED
                // item's current answer is what the directive is a standard
                // for. Missing has nothing to hand over.
                priorTranslation: entry.status == .missing ? nil : entry.translatedText,
                directives: (directives[entry.paragraphId] ?? []).map(\.text))
        }
```

and pass `craftIntentText: intentText, editionBriefText: briefText, glossary: GlossaryTable.gather(editionBrief: briefText)` into the `Inputs` init (keep every other argument as it is; `mode` stays defaulted — the pipeline's fix legs are Plan 3's).

Keep the existing "keep the existing comments" (`read_translation`'s own strip etc.) in place.

- [ ] **Step 4: Run** — `-only-testing:MaughamTests/TranslatorEnvironmentTests`. Expected: green, including `test_theBriefingAsksForWhatIsStaleOrMissingOnly` unchanged (no directives → same delta).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/TranslatorEnvironment+Project.swift MaughamTests/TranslatorEnvironmentTests.swift
git commit -m "feat(compiler): the translator's work-list is stale ∪ missing ∪ directed, with directives and the glossary"
```

---

### Task 9: The cast sheet names three people

**Files:**
- Modify: `Maugham/Views/Publish/DepartmentCastSheet.swift`
- Modify: `Maugham/Views/Publish/DepartmentPaneHost.swift` (`askToRename` ~412, `confirmCast` ~432, `addLanguage` ~488, `nameTranslator` ~547)
- Modify: `MaughamTests/DepartmentRunTests.swift` (every `.translator(language:` → `.edition(language:`; +3 tests), `MaughamTests/DepartmentPaneTests.swift` (+1)

**Interfaces:**
- Consumes: `ProjectStore.readerRole/collatorRole(for:)`, `renameProductionRole`, `EditionStatus.readerName/collatorName(for:in:)`, `ProductionRole.defaultReaderName/defaultCollatorName` (P1).
- Produces:
  ```swift
  DepartmentCastPrompt.RenameSubject.edition(language: String)   // was .translator(language:)
  DepartmentCastPrompt { let ask: Ask; var currentReader: String? = nil; var currentCollator: String? = nil; var takesCast: Bool }
  DepartmentCastAnswer { let language: String?; let name: String; let reader: String?; let collator: String? }
  DepartmentCastCopy.readerPlaceholder / .collatorPlaceholder / .castExplanation
  DepartmentPaneHost.nameCast(language:answer:) async -> Bool   (private)
  ```

- [ ] **Step 1: Write the failing tests**

Mechanical first: `sed -i '' 's/\.translator(language:/.edition(language:/g' MaughamTests/DepartmentRunTests.swift` (and the same in `DepartmentPaneTests.swift` if it references the case). Then add to `DepartmentRunTests` near `test_theRenameSheetStartsFromTheNameItIsAbout`:

```swift
    /// **Rename … on a language row offers all three** (translation pipeline
    /// spec §1): the sheet starts from the translator, the reader and the
    /// collator this edition has — presets included — and sends all three.
    func test_theRenameSheetOffersReaderAndCollatorPrefilled() async throws {
        var answered: [DepartmentCastAnswer] = []
        let window = mountCastSheet(
            ask: .rename(subject: .edition(language: "es"), currentName: "Cortázar"),
            currentReader: "Ocampo", currentCollator: "Borges",
            onConfirm: { answered.append($0) })

        let reader = try XCTUnwrap(
            textField(placeholder: DepartmentCastCopy.readerPlaceholder, in: window),
            "no reader field")
        let collator = try XCTUnwrap(
            textField(placeholder: DepartmentCastCopy.collatorPlaceholder, in: window),
            "no collator field")
        XCTAssertEqual(reader.stringValue, "Ocampo")
        XCTAssertEqual(collator.stringValue, "Borges")

        type("Victoria", into: reader)
        pump(0.1)
        press(try axButtons(labelled: DepartmentCastCopy.renameConfirmTitle, in: window)[0])
        _ = await pumpUntil(deadline: 3) { !answered.isEmpty }
        XCTAssertEqual(answered, [DepartmentCastAnswer(
            language: nil, name: "Cortázar", reader: "Victoria", collator: "Borges")])
    }

    /// A blank reader or collator is "leave them be", not a refusal: only the
    /// translator's name gates Confirm, because only the translator signs the
    /// round the sheet may be standing in front of.
    func test_blankReaderAndCollatorTravelAsNilAndDoNotDisableConfirm() async throws {
        var answered: [DepartmentCastAnswer] = []
        let window = mountCastSheet(ask: .nameForRun(language: "xx", docId: "doc-1"),
                                    onConfirm: { answered.append($0) })
        type("Ana", into: try XCTUnwrap(
            textField(placeholder: DepartmentCastCopy.placeholder, in: window)))
        pump(0.1)
        let confirm = try axButtons(labelled: DepartmentCastCopy.nameAndRunTitle, in: window)
        XCTAssertEqual(axEnabled(confirm[0]), true)
        press(confirm[0])
        _ = await pumpUntil(deadline: 3) { !answered.isEmpty }
        XCTAssertEqual(answered, [DepartmentCastAnswer(
            language: nil, name: "Ana", reader: nil, collator: nil)])
    }

    /// The designer's sheet is one field — there is no reader or collator of a
    /// book's design.
    func test_theDesignerSheetHasNoCastFields() async throws {
        let window = mountCastSheet(
            ask: .rename(subject: .designer, currentName: "Tschichold"))
        XCTAssertNil(textField(placeholder: DepartmentCastCopy.readerPlaceholder, in: window))
        XCTAssertNil(textField(placeholder: DepartmentCastCopy.collatorPlaceholder, in: window))
    }

    /// **On the real desk, all three land in the manifest** — the same one
    /// visible act, three people.
    func test_renamingAnEditionNamesItsReaderAndCollatorToo() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "es")
        let window = mountTranslatorHost(fixture)
        _ = try await scrollersSettling(in: window)

        try await pressRowControl(
            labelled: DepartmentDesk.renameTitle(translator: "Cortázar"), in: window)
        let sheetWindow = try XCTUnwrap(await attachedSheetWindow(of: window))
        type("Victoria", into: try XCTUnwrap(textField(
            placeholder: DepartmentCastCopy.readerPlaceholder, in: sheetWindow)))
        pump(0.1)
        press(try axButtons(labelled: DepartmentCastCopy.renameConfirmTitle,
                            in: sheetWindow)[0])

        _ = await pumpUntil(deadline: 10) {
            fixture.projectStore.manifest.storedReader(for: "es") != nil
                && fixture.projectStore.manifest.storedCollator(for: "es") != nil
        }
        XCTAssertEqual(fixture.projectStore.manifest.storedTranslator(for: "es")?.effectiveName,
                       "Cortázar")
        XCTAssertEqual(fixture.projectStore.manifest.storedReader(for: "es")?.effectiveName,
                       "Victoria")
        XCTAssertEqual(fixture.projectStore.manifest.storedCollator(for: "es")?.effectiveName,
                       "Borges", "an untouched preset field still names them — the sheet "
                       + "is the one composition that mints the cast")

        await fixture.documentStore.close()
    }
```

Extend `mountCastSheet` with `currentReader: String? = nil, currentCollator: String? = nil`, building `DepartmentCastPrompt(ask: ask, currentReader: currentReader, currentCollator: currentCollator)`.

In `DepartmentPaneTests`, a pure test:

```swift
    func test_everyEditionAskTakesTheCastAndTheDesignersDoesNot() {
        XCTAssertTrue(DepartmentCastPrompt(ask: .addLanguage).takesCast)
        XCTAssertTrue(DepartmentCastPrompt(ask: .nameForRun(language: "es", docId: "d")).takesCast)
        XCTAssertTrue(DepartmentCastPrompt(
            ask: .rename(subject: .edition(language: "es"), currentName: "X")).takesCast)
        XCTAssertFalse(DepartmentCastPrompt(
            ask: .rename(subject: .designer, currentName: "X")).takesCast)
    }
```

- [ ] **Step 2: Run to see failures** — compile errors on `.edition`, `currentReader`, `readerPlaceholder`.

- [ ] **Step 3: Implement the sheet**

`DepartmentCastSheet.swift`:

- `RenameSubject`: rename `case translator(language: String)` → `case edition(language: String)`; update the doc ("a language's whole cast — translator, reader, collator — through its language"), `id` (`"rename:\(language)"` unchanged), `nameSubjectTitle`, `renameExplanation` arms (`case .edition(let language)`), and the explanation text to say "signs the … edition's paragraphs and queries; its reader and collator sign the notes they write".
- `DepartmentCastPrompt`: add
  ```swift
      /// What the reader and collator fields start with, for an edition ask —
      /// `EditionStatus.readerName`/`collatorName`'s answer, resolved by the
      /// host the way `currentName` is. nil = nobody yet (the field starts
      /// empty, or with the preset the tag names for `.addLanguage`).
      var currentReader: String? = nil
      var currentCollator: String? = nil

      /// Whether the sheet draws the reader and collator fields: every ask
      /// about an edition. The designer has neither.
      var takesCast: Bool {
          if case .rename(.designer, _) = ask { return false }
          return true
      }
  ```
  and an explicit `init(ask: Ask, currentReader: String? = nil, currentCollator: String? = nil)` so existing `DepartmentCastPrompt(ask:)` call sites compile.
- `DepartmentCastAnswer`: add `let reader: String?`, `let collator: String?` with `init(language:name:reader: String? = nil, collator: String? = nil)`.
- The view: add `@State private var reader = ""`, `@State private var collator = ""`, `@State private var autofilledReader: String?`, `@State private var autofilledCollator: String?`. In `.onAppear`: `reader = prompt.currentReader ?? ""`, `collator = prompt.currentCollator ?? ""`, and for `.nameForRun(language, _)` with nil `currentReader`: `reader = ProductionRole.defaultReaderName(language: language) ?? ""` (same for collator). In the tag `.onChange`, mirror the translator autofill for the two new fields against `autofilledReader`/`autofilledCollator` using `defaultReaderName`/`defaultCollatorName`. Draw, when `prompt.takesCast`, under the name field:
  ```swift
              if prompt.takesCast {
                  Text(DepartmentCastCopy.castExplanation)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  TextField(DepartmentCastCopy.readerPlaceholder, text: $reader)
                      .textFieldStyle(.roundedBorder)
                  TextField(DepartmentCastCopy.collatorPlaceholder, text: $collator)
                      .textFieldStyle(.roundedBorder)
              }
  ```
  Confirm sends `reader: trimmedOrNil(reader), collator: trimmedOrNil(collator)` where `trimmedOrNil` returns nil for a blank. The confirm `disabled` condition is unchanged (translator name + tag only). Bump `.frame(width: 380)` height is automatic; the test mounts at 380×260 — raise `mountCastSheet`'s height to 360 so three fields fit.
- Copy:
  ```swift
      static let readerPlaceholder = "The edition\u{2019}s blind reader (optional)"
      static let collatorPlaceholder = "The edition\u{2019}s collator (optional)"
      /// Why there are two more fields. Short, because the sheet is already
      /// explaining who the translator is.
      static let castExplanation =
          "Who reads the finished edition blind, and who collates it against the "
          + "original. A preset language fills them in; leave one blank to change "
          + "nothing about them."
  ```

- [ ] **Step 4: Implement the host**

`DepartmentPaneHost.swift`:
- `askToRename(language:)`: build the prompt with `currentReader: EditionStatus.readerName(for: language, in: store.manifest)`, `currentCollator: EditionStatus.collatorName(for: language, in: store.manifest)`.
- `confirmCast`: `.nameForRun` → `guard await nameCast(language: language, answer: answer) else { return }` then run; `.addLanguage` → `addLanguage(tag: answer.language ?? "", answer: answer)`; `.rename(.edition(let language), _)` → `Task { await nameCast(language: language, answer: answer) }`; designer arm unchanged.
- `addLanguage(tag:name:)` → `addLanguage(tag:answer:)`, ending in `Task { _ = await nameCast(language: language, answer: answer) }`.
- Replace `nameTranslator(language:name:)` with:
  ```swift
      /// **Mint-then-rename, the one visible act — now for the whole cast.**
      /// `translatorRole(for:)` finds or mints; the very next line names them.
      /// The reader and the collator follow the same shape only when the sheet
      /// sent a name: a blank field is "change nothing", so a rename that
      /// touches only the translator mints no reader on the side. Answers
      /// whether the TRANSLATOR landed — the run the sheet may be standing in
      /// front of needs them and nobody else.
      @discardableResult
      private func nameCast(language: String, answer: DepartmentCastAnswer) async -> Bool {
          do {
              let translator = try await store.translatorRole(for: language)
              try await store.renameProductionRole(id: translator.id, to: answer.name)
          } catch {
              _departmentLog.error(
                  "could not name the \(language, privacy: .public) translator: \(error, privacy: .public)")
              notice = DepartmentCastCopy.mintFailed(language: language)
              return false
          }
          await nameCompanion(language: language, name: answer.reader,
                              mint: store.readerRole(for:), what: "reader")
          await nameCompanion(language: language, name: answer.collator,
                              mint: store.collatorRole(for:), what: "collator")
          return true
      }

      private func nameCompanion(
          language: String, name: String?,
          mint: (String) async throws -> ProductionRole, what: String
      ) async {
          guard let name else { return }
          do {
              let role = try await mint(language)
              try await store.renameProductionRole(id: role.id, to: name)
          } catch {
              _departmentLog.error(
                  "could not name the \(language, privacy: .public) \(what, privacy: .public): \(error, privacy: .public)")
              notice = DepartmentCastCopy.mintFailed(language: language)
          }
      }
  ```
  Update the doc comment above the old `nameTranslator` (it is quoted in `ProjectStore+ProductionRoles`'s comments by name — leave those comments alone; they describe the shape, and `nameCast` keeps it).

- [ ] **Step 5: Run** — `-only-testing:MaughamTests/DepartmentRunTests -only-testing:MaughamTests/DepartmentPaneTests`. Expected: green; every pre-existing cast test still passes with the case rename.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Views/Publish/DepartmentCastSheet.swift Maugham/Views/Publish/DepartmentPaneHost.swift MaughamTests/DepartmentRunTests.swift MaughamTests/DepartmentPaneTests.swift
git commit -m "feat(desk): the cast sheet names the translator, the reader and the collator"
```

---

### Task 10: Translator's note… — the editor verb

**Files:**
- Create: `Maugham/Views/TranslatorsNote.swift`
- Create: `MaughamTests/TranslatorsNoteTests.swift`
- Modify: `Maugham/Models/MaughamNotifications.swift` (~132), `Maugham/MaughamApp.swift` (the `CommandGroup(after: .pasteboard)` holding Find in Project ~326), `Maugham/Resources/KeyboardShortcuts.swift` (Edit category), `docs/guide/reference.md` (the ⌘⌥ table ~24–47), `docs/guide/compiler.md` (the Intent section — grep "Intent pane")
- Modify: `Maugham/Views/ProjectWindow.swift` (`ProjectActiveSheet` ~17, `.sheet(item: $activeSheet)` ~304, a new `.onKeyWindowCommand` beside the `.maughamShowProjectSettings` arm ~410 — **on `ProjectWindow`'s own body, where `activeSheet`, `activeDocId`, `declaredWorld` and `activeDocument(in:documentStore:)` are reachable; NOT inside `SessionAndNavigationModifier`, which hosts the `.maughamFindInProject` arm and has none of them**)
- Modify: `Maugham/Editor/SelectionToolbarView.swift` (`Kind`), `Maugham/Editor/EditorCoordinator+ReviewRender.swift` (`handleToolbarAction` ~337)
- Modify: `Maugham/Editor/AREA.md`

**Interfaces:**
- Consumes: `RulingPerformer.rule`, `Ruling.directiveText`, `Ruling.Provenance.translatorsNote` (P1); `Document.paragraphId(at:)`, `Document.cursorLocation`; `EditionStatus.editionLanguages(files:queries:roles:)`; `TranslationStore.languages(forDocId:in:)`; `StatementLookup`/`manifest.statements`; `DiagnosticsPane.truncatedDriftQuote`; `TranslationReviewIndicator.displayLabel(forLanguageTag:)`.
- Produces:
  ```swift
  @MainActor enum TranslatorsNote {
      struct Target: Hashable { let docId: String; let paragraphId: String; let excerpt: String; let editions: [String] }
      enum Home: Hashable { case everyEdition; case edition(String) }
      static func destination(home: Home, docId: String) -> (kind: Statement.Kind, scope: Statement.Scope)
      static func editions(manifest: ProjectManifest, docId: String, projectURL: URL) -> [String]
      static func target(for document: Document, docId: String, manifest: ProjectManifest, projectURL: URL) -> Target?
      static func commit(_ instruction: String, target: Target, home: Home, store: ProjectStore, world: DeclaredWorldStore?) async -> String?
  }
  struct TranslatorsNoteSheet: View   // (target:onCommit:(String, Home) -> Void, onCancel:)
  enum TranslatorsNoteCopy
  Notification.Name.maughamTranslatorsNote   // scope .keyWindow
  SelectionToolbarView.Kind.translatorsNote
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/TranslatorsNoteTests.swift
import MaughamCore
import XCTest
@testable import Maugham

/// **Translator's note…** — the author's Kundera move (translation pipeline
/// spec §3): a directive minted from the English through the one door,
/// `RulingPerformer.rule`, into the home the writer chose.
@MainActor
final class TranslatorsNoteTests: XCTestCase {

    private struct Harness {
        let projectURL: URL
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let doc: Document
    }

    /// `TranslatorEnvironmentTests.makeHarness`'s project, minus the
    /// environment: a real `Document.load` is what mints the ¶ids every test
    /// here names.
    private func makeHarness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranslatorsNote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let path = "manuscript/c1.md"
        try "The fog came in.\n\nShe closed the door.\n\nNobody spoke."
            .write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "Note", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-1", title: "Chapter 1",
                                      type: .document, path: path)],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: root.appendingPathComponent("project.maugham.json"))

        let projectStore = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        projectStore.documentStore = documentStore
        let doc = try await Document.load(
            url: root.appendingPathComponent(path),
            device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc, for: path)
        return Harness(projectURL: root, projectStore: projectStore,
                       documentStore: documentStore, doc: doc)
    }

    func test_everyEditionLandsInThePiecesOwnIntent() async throws {
        let h = try await makeHarness()
        let id = h.doc.sequence[1]
        let target = TranslatorsNote.Target(
            docId: h.doc.docId, paragraphId: id, excerpt: "She closed the door.", editions: [])

        let refusal = await TranslatorsNote.commit(
            "one sentence, not two — it is a door closing",
            target: target, home: .everyEdition, store: h.projectStore, world: nil)

        XCTAssertNil(refusal)
        let statement = try XCTUnwrap(h.projectStore.statement(
            kind: .intent, scope: .document(h.doc.docId)))
        let rulings = RulingsSection.parse(try h.projectStore.statementText(of: statement)).rulings
        XCTAssertEqual(rulings.count, 1)
        XCTAssertEqual(rulings[0].directive?.paragraphId, id)
        XCTAssertEqual(rulings[0].directive?.text, "one sentence, not two - it is a door closing",
                       "the em-dash became a hyphen and the line still parses as a directive")
        XCTAssertEqual(rulings[0].provenance, Ruling.Provenance.translatorsNote)
        XCTAssertNotNil(rulings[0].ruledOn)
        await h.documentStore.close()
    }

    func test_thisEditionOnlyLandsInThatLanguagesBriefAtProjectScope() async throws {
        let h = try await makeHarness()
        let id = h.doc.sequence[0]
        let target = TranslatorsNote.Target(
            docId: h.doc.docId, paragraphId: id, excerpt: "The fog came in.", editions: ["es"])

        let refusal = await TranslatorsNote.commit(
            "do not elevate this", target: target, home: .edition("es"),
            store: h.projectStore, world: nil)

        XCTAssertNil(refusal)
        let brief = try XCTUnwrap(h.projectStore.statement(kind: .editionBrief("es"), scope: .project))
        let rulings = RulingsSection.parse(try h.projectStore.statementText(of: brief)).rulings
        XCTAssertEqual(rulings.first?.directive?.paragraphId, id)
        XCTAssertNil(h.projectStore.statement(kind: .intent, scope: .document(h.doc.docId)),
                     "nothing was written to the other home")
        await h.documentStore.close()
    }

    func test_anEmptyInstructionIsRefusedInWordsAndWritesNothing() async throws {
        let h = try await makeHarness()
        let target = TranslatorsNote.Target(
            docId: h.doc.docId, paragraphId: h.doc.sequence[0], excerpt: "x", editions: [])
        let refusal = await TranslatorsNote.commit(
            "   ", target: target, home: .everyEdition, store: h.projectStore, world: nil)
        XCTAssertEqual(refusal, TranslatorsNoteCopy.emptyRefusal)
        XCTAssertNil(h.projectStore.statement(kind: .intent, scope: .document(h.doc.docId)))
        await h.documentStore.close()
    }

    func test_destinationIsTheOneSpellingOfWhereANoteGoes() {
        let every = TranslatorsNote.destination(home: .everyEdition, docId: "doc-1")
        XCTAssertEqual(every.kind, .intent)
        XCTAssertEqual(every.scope, .document("doc-1"))
        let one = TranslatorsNote.destination(home: .edition("fr"), docId: "doc-1")
        XCTAssertEqual(one.kind, .editionBrief("fr"))
        XCTAssertEqual(one.scope, .project)
    }

    /// The "This edition only" choices are every edition the book has, by the
    /// desk's own union — translation files, stored roles — plus a brief that
    /// exists with neither.
    func test_editionsAreTheUnionOfFilesRolesAndBriefs() async throws {
        let h = try await makeHarness()
        try await TranslationStore.append(
            TranslationRecord(paragraphId: h.doc.sequence[0], language: "es", text: "…",
                              sourceHash: TranslationHash.hash("x")),
            forDocId: h.doc.docId, deviceSlug: DeviceSlug.make(from: "t"), in: h.projectURL)
        _ = try await h.projectStore.readerRole(for: "de")
        _ = try await h.projectStore.createStatement(kind: .editionBrief("fr"), scope: .project)

        XCTAssertEqual(
            TranslatorsNote.editions(manifest: h.projectStore.manifest, docId: h.doc.docId,
                                     projectURL: h.projectURL),
            ["de", "es", "fr"])
        await h.documentStore.close()
    }

    /// The target is read off the caret: the paragraph under it, an excerpt of
    /// its display text, and the editions the sheet offers. No paragraph (an
    /// empty document) → no target.
    func test_targetIsReadOffTheCaret() async throws {
        let h = try await makeHarness()
        h.doc.cursorLocation = 0
        let target = try XCTUnwrap(TranslatorsNote.target(
            for: h.doc, docId: h.doc.docId, manifest: h.projectStore.manifest,
            projectURL: h.projectURL))
        XCTAssertEqual(target.paragraphId, h.doc.sequence[0])
        XCTAssertEqual(target.excerpt, "The fog came in.")
        XCTAssertEqual(target.docId, h.doc.docId)
        await h.documentStore.close()
    }

    // MARK: - The doors

    /// The window command is in the Edit menu with a ⌘⌥ letter, and that
    /// letter is on the cheatsheet — `DocSyncTests` enforces the second half;
    /// this pins the first.
    func test_theCommandIsBoundInTheAppAndListedOnTheCheatsheet() throws {
        let app = try String(contentsOf: repoFile("Maugham/MaughamApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("MaughamEvent.post(.maughamTranslatorsNote, to: .keyWindow)"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"c\", modifiers: [.command, .option])"))
        let listed = KeyboardShortcuts.all.flatMap(\.items)
            .contains { $0.shortcut == "⌘⌥C" && $0.label.contains("Translator") }
        XCTAssertTrue(listed)
    }

    func test_theSelectionToolbarOffersItAndPostsTheSameCommand() throws {
        XCTAssertTrue(SelectionToolbarView.Kind.allCases.contains(.translatorsNote))
        let coordinator = try String(
            contentsOf: repoFile("Maugham/Editor/EditorCoordinator+ReviewRender.swift"),
            encoding: .utf8)
        XCTAssertTrue(coordinator.contains(
            "case .translatorsNote: MaughamEvent.post(.maughamTranslatorsNote, to: .keyWindow)"))
    }

    private func repoFile(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
```

- [ ] **Step 2: `./gen.sh`, run, see the compile failure**

- [ ] **Step 3: Implement the model and the sheet**

`Maugham/Views/TranslatorsNote.swift`:

```swift
import SwiftUI
import MaughamCore

/// **Translator's note… — the author's Kundera move** (translation pipeline
/// spec §3). In the English, put the caret in a paragraph, ⌘⌥C, type the
/// instruction — "this repetition is deliberate", "one sentence, not two" —
/// and choose its home:
///
/// - **Every edition** (default): the piece's craft intent `## Rulings`,
///   because a directive about the English applies to every language.
/// - **This edition only**: that language's edition brief `## Rulings`.
///
/// On disk it is one plain line (`Ruling.directiveText`), minted through
/// `RulingPerformer.rule` — the one door — with provenance
/// `Ruling.Provenance.translatorsNote`. **No new door**: this type chooses the
/// destination and the words, and holds no markdown of its own
/// (`QueryRuling`'s shape, one verb over).
///
/// `world:` is passed for the intent home only: `RulingPerformer`'s cache
/// holds INTENT readings, and nothing derives a world from an edition brief.
@MainActor
enum TranslatorsNote {

    /// What the sheet is about: the paragraph under the caret, enough of its
    /// text to recognise it by, and the editions "This edition only" can name.
    struct Target: Hashable {
        let docId: String
        let paragraphId: String
        let excerpt: String
        let editions: [String]
    }

    enum Home: Hashable {
        case everyEdition
        case edition(String)
    }

    /// **The one spelling of where a note goes.** `StatementPane.effectiveScope`
    /// is the pane's rule for what it SHOWS; this is the verb's rule for what
    /// it WRITES, and the two agree by construction on the only case they
    /// share (intent on a document is document-scoped).
    static func destination(home: Home, docId: String) -> (kind: Statement.Kind, scope: Statement.Scope) {
        switch home {
        case .everyEdition: return (.intent, .document(docId))
        case .edition(let language): return (.editionBrief(language), .project)
        }
    }

    /// Every edition this book has — the desk's own union
    /// (`EditionStatus.editionLanguages`: translation files and stored roles),
    /// plus any language with a brief and nothing else yet. Sorted, so the
    /// picker is stable.
    static func editions(manifest: ProjectManifest, docId: String, projectURL: URL) -> [String] {
        let files = Set(TranslationStore.languages(forDocId: docId, in: projectURL))
        let roles: [String] = manifest.productionRoles.compactMap { role in
            switch role.role {
            case .translator(let l), .reader(let l), .collator(let l): return l
            case .designer, .unknown: return nil
            }
        }
        let briefs: [String] = manifest.statements.compactMap {
            if case .editionBrief(let l) = $0.kind { return l }
            return nil
        }
        return EditionStatus.editionLanguages(files: files, queries: [], roles: roles + briefs)
    }

    /// The target under the caret, or nil when the document has no paragraph
    /// there (an empty document).
    static func target(for document: Document, docId: String,
                       manifest: ProjectManifest, projectURL: URL) -> Target? {
        guard let paragraphId = document.paragraphId(at: document.cursorLocation) else {
            return nil
        }
        let text = MarkdownDisplayFilter.stripAnchors(document.paragraphs[paragraphId] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Target(
            docId: docId, paragraphId: paragraphId,
            excerpt: DiagnosticsPane.truncatedDriftQuote(text),
            editions: editions(manifest: manifest, docId: docId, projectURL: projectURL))
    }

    /// Write the directive. Returns the refusal's own sentence, or nil.
    static func commit(_ instruction: String, target: Target, home: Home,
                       store: ProjectStore, world: DeclaredWorldStore?) async -> String? {
        let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return TranslatorsNoteCopy.emptyRefusal }
        let (kind, scope) = destination(home: home, docId: target.docId)
        do {
            try await RulingPerformer.rule(
                Ruling.directiveText(paragraphId: target.paragraphId, words),
                provenance: Ruling.Provenance.translatorsNote,
                kind: kind, forScope: scope,
                store: store,
                world: home == .everyEdition ? world : nil)
        } catch {
            return error.localizedDescription
        }
        return nil
    }
}

/// The sheet. `QueryRulingSheet`'s shape: headline, the paragraph it is about,
/// the instruction, where it goes, Cancel and a default action.
@MainActor
struct TranslatorsNoteSheet: View {
    let target: TranslatorsNote.Target
    let onCommit: (String, TranslatorsNote.Home) -> Void
    let onCancel: () -> Void
    @State private var instruction = ""
    @State private var home: TranslatorsNote.Home = .everyEdition

    private var trimmed: String {
        instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TranslatorsNoteCopy.title)
                .font(.headline)
            Text("\u{201C}\(target.excerpt)\u{201D}")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $instruction)
                .frame(minHeight: 70)
                .border(Color.gray.opacity(0.3))
            Picker(TranslatorsNoteCopy.homeLabel, selection: $home) {
                Text(TranslatorsNoteCopy.everyEdition).tag(TranslatorsNote.Home.everyEdition)
                ForEach(target.editions, id: \.self) { language in
                    Text(TranslatorsNoteCopy.thisEditionOnly(language))
                        .tag(TranslatorsNote.Home.edition(language))
                }
            }
            Text(TranslatorsNoteCopy.confirmation(home: home))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(TranslatorsNoteCopy.cancelTitle, action: onCancel)
                Button(TranslatorsNoteCopy.confirmTitle) { onCommit(trimmed, home) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// The sheet's own words — assertable without mounting anything.
enum TranslatorsNoteCopy {
    static let title = "Translator\u{2019}s Note"
    static let homeLabel = "Applies to"
    static let everyEdition = "Every edition"
    static let confirmTitle = "Add Note"
    static let cancelTitle = "Cancel"

    static func thisEditionOnly(_ language: String) -> String {
        "This edition only: "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
    }

    /// Both possible destinations, before the click.
    static func confirmation(home: TranslatorsNote.Home) -> String {
        switch home {
        case .everyEdition:
            return "This becomes a dated ruling on this paragraph in the piece\u{2019}s "
                + "craft intent, briefed to every translator, reader and collator."
        case .edition(let language):
            return "This becomes a dated ruling on this paragraph in the "
                + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
                + " edition brief, briefed to that edition\u{2019}s people only."
        }
    }

    static let emptyRefusal =
        "A translator\u{2019}s note needs an instruction \u{2014} say what the "
        + "translator must keep, or must not do, here."
}
```

- [ ] **Step 4: The doors**

`MaughamNotifications.swift`, beside `maughamFindInProject`:

```swift
    /// Posted by ⌘⌥C / Edit ▸ Translator's Note… (translation pipeline P2):
    /// the window opens the note sheet on the paragraph under the caret.
    /// Scope: .keyWindow — a command, not a data event.
    public static let maughamTranslatorsNote = Notification.Name("maugham.translators.note")
```

`MaughamApp.swift`, in the `CommandGroup(after: .pasteboard)` after "Find in Project…":

```swift
                // **⌘⌥C, for *direCtive*** — every letter of "translator's
                // note" the ⌘⌥ family could use is spoken for (T Tasks, N
                // Intent, R Research, A Annotations, L Translation, O Outline,
                // E References), and C is the first free letter in the word
                // for what the note IS on disk (spec §3).
                Button("Translator\u{2019}s Note\u{2026}") {
                    MaughamEvent.post(.maughamTranslatorsNote, to: .keyWindow)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
```

`KeyboardShortcuts.swift`, Edit category: `Entry(label: "Translator's Note…", shortcut: "⌘⌥C"),`.

`docs/guide/reference.md`, in the ⌘⌥ table: `| `⌘⌥C` | Translator's Note… — a directive on the paragraph under the caret, into the piece's craft intent (every edition) or one edition's brief |`.

`docs/guide/compiler.md`, in the Intent section, one short paragraph:

> **Translator's note…** (⌘⌥C, or the button on the selection toolbar in Review Mode) writes a *directive* — a ruling anchored to the paragraph under the caret — into this piece's craft intent by default, or into one language's edition brief if you choose "This edition only". Every translator, reader and collator is briefed with it. On disk it is one plain line under `## Rulings`, `- ¶k7mq: keep the three "and"s — ruled 28 Aug 2026, translator's note`, and you can edit it there.

`ProjectWindow.swift`:
- `enum ProjectActiveSheet` gains `case translatorsNote(TranslatorsNote.Target)` (the enum's `id: Int { hashValue }` needs `Hashable` — `Target` is).
- `.sheet(item: $activeSheet)` gains:
  ```swift
                    case .translatorsNote(let target):
                        TranslatorsNoteSheet(
                            target: target,
                            onCommit: { instruction, home in
                                activeSheet = nil
                                Task { @MainActor in
                                    if let refusal = await TranslatorsNote.commit(
                                        instruction, target: target, home: home,
                                        store: store, world: declaredWorld) {
                                        restoreOutcome = refusal
                                    }
                                }
                            },
                            onCancel: { activeSheet = nil })
  ```
  (`restoreOutcome` is the window's existing one-line outcome banner — the same slot Restore Last Deletion reports into. If its rendering is labelled in a way that would misread for a refusal here, add a sibling `@State private var noteOutcome: String?` drawn the same way; check `restoreOutcome`'s view site ~828 first.)
- beside `.onKeyWindowCommand(.maughamShowProjectSettings, …)` (~410, on the window's own body):
  ```swift
                // **Translator's note** (⌘⌥C): the sheet opens on the paragraph
                // under the caret of the ACTIVE manuscript document; with no
                // document in the centre column there is nothing to note, and
                // the command is a quiet no-op like every other editor verb
                // with no editor.
                .onKeyWindowCommand(.maughamTranslatorsNote, window: window) { _ in
                    guard let store, let documentStore,
                          let document = activeDocument(in: store, documentStore: documentStore),
                          let target = TranslatorsNote.target(
                              for: document, docId: activeDocId,
                              manifest: store.manifest, projectURL: store.url)
                    else { return }
                    activeSheet = .translatorsNote(target)
                }
  ```

`SelectionToolbarView.Kind` gains `case translatorsNote = "Translator\u{2019}s note"` (last, so the existing buttons keep their tags). `handleToolbarAction` gains `case .translatorsNote: MaughamEvent.post(.maughamTranslatorsNote, to: .keyWindow)` — exactly that spelling, on one line, because `TranslatorsNoteTests` greps for it. Update the toolbar's doc comment (the "Comment / Suggest / Query" sentence) to name the fourth button.

- [ ] **Step 5: Run**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/TranslatorsNoteTests -only-testing:MaughamTests/DocSyncTests -only-testing:MaughamTests/Editor/SelectionToolbarWiringTests -only-testing:MaughamTests/TripwireGrepTests 2>&1 | grep -E "error:|Test Suite '(TranslatorsNoteTests|DocSyncTests|SelectionToolbarWiringTests|TripwireGrepTests)'|passed|failed" | tail -8`
Expected: all green. (`TripwireGrepTests` has a `ContentUnavailableView`/window-construction census that reads every view file — the new sheet must not trip it.)

- [ ] **Step 6: Editor AREA.md**

Add after "Two editors in one window (M1A)":

```markdown
## Translator's note — the editor's one statement-writing verb (translation pipeline P2)

⌘⌥C (Edit ▸ Translator's Note…, and a fourth `SelectionToolbarView.Kind` in
Review Mode) opens `TranslatorsNoteSheet` (`Maugham/Views/TranslatorsNote.swift`)
on the paragraph under the caret — `Document.paragraphId(at: cursorLocation)`,
read by `ProjectWindow`'s key-window handler, never by the coordinator — and
writes a **directive** (`Ruling.directiveText`, provenance `translator's note`)
through `RulingPerformer.rule`: the piece's craft intent at `.document(id)` by
default, or one language's edition brief at `.project`. The editor itself
knows nothing about statements (the toolbar button only posts the window
command), which is what keeps this out of the binding contract above. It is
a sheet, not a popover (tripwire 7). `TranslatorsNoteTests` drives the whole
act at the op log.
```

- [ ] **Step 7: Commit**

```bash
git add Maugham/Views/TranslatorsNote.swift MaughamTests/TranslatorsNoteTests.swift Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift Maugham/Resources/KeyboardShortcuts.swift docs/guide/reference.md docs/guide/compiler.md Maugham/Views/ProjectWindow.swift Maugham/Editor/SelectionToolbarView.swift Maugham/Editor/EditorCoordinator+ReviewRender.swift Maugham/Editor/AREA.md
git commit -m "feat(editor): Translator's note… — a directive on the paragraph under the caret, through the one door"
```

---

## Before merge

1. Whole-branch review (CLAUDE.md workflow rule 9) — one reviewer over the full diff against `main`, opus.
2. `./scripts/test.sh full`; read the kept xcresult (`xcrun xcresulttool get test-results summary --path <the run's .xcresult>`) — the verdict is there, not in the pipe's exit code. Expect the count to rise from 7313 by roughly the number of tests added (≈50); a count that did not rise means a stale project (`./gen.sh`).
3. Release build after the `ProjectWindow.body` change (CLAUDE.md): `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`.
4. Merge locally (`git merge --no-ff translation-pipeline-p2` on `main`); don't push. Update the memory note.

## Carried forward to Plan 3 (not defects — decisions this plan deliberately left)

- **Same-day directives re-direct for the rest of that day** (`Directives.isDirected`): a paragraph directed today is re-sent on every Run today. Plan 3's round record is where a "directive applied in round N" fact could live if this ever costs anything.
- **`ReaderBriefing.Inputs.authorLanguage` / `CollatorBriefing.Inputs.authorLanguage`** are resolved by the caller. Plan 3 decides the source: the publish config's book language, else "English".
- **The reader is passed `nil` for a stale paragraph** by convention (doc on `Paragraph.translation`); Plan 3's gather must honour it.
- **`TranslatorBriefing.FixNote.id`** is the annotation id Plan 3 mints before briefing leg 7 (P1's carried-forward item about `CollatorReport.Departure` carrying no id).
- `ColdCall` has no production caller yet; its four arrive in Plans 3 (reader, collator) and 4 (gloss, Ask the collator). The window wiring and the census are in place so they arrive as calls, not as wiring.
- The StatementPane glossary TABLE and orphaned-directive drawing (spec §3, §3.1) are Plan 4's surfaces; this plan only composes and reads.
- **Plan 3's reader/collator gather must strip inline task anchors** (`MarkdownDisplayFilter.stripTaskAnchorsInline`) from paragraph text before it reaches `ReaderBriefing`/`CollatorBriefing`, exactly as the translator's gather already does — `compose` on both types strips only whole-line `¶id` anchors, not inline ones.
