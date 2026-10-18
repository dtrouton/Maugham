# Foundations Plan 3: The Project Session — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One owner for an open project's stores and its `claude` services. Every window that needs a project borrows that owner instead of re-opening the project by hand. As a result, the Statistics window stops opening a second `DocumentStore` that is released immediately, and adding a sixth AI service cannot leave a billing process running.

**Architecture:** Three new types.
- **`AgentRoster`** (Compiler/) owns the five warm-session services plus the translation run log. It holds the one shutdown/detach ORDER and the model fan-out. `ProjectWindow` and `CompilerRunModifier` iterate the roster instead of naming each service.
- **`ProjectSession`** (Stores/, `@MainActor @Observable`) owns `ProjectStore`, `DocumentStore`, `BibleStore`, `DeclaredWorldStore` and the roster. It exposes `open(…)` and `close()`, which are `ProjectWindow.load()`'s wiring and `onDisappear`'s teardown moved out of the view.
- **`ProjectSessionRegistry`** (app-wide, injected through the environment) hands out sessions per URL, reference-counted. A second window on the same project borrows the session that is already open.

`ProjectWindow` keeps its UI state seeding (persona, subject, widths) and its `@State` mirrors of `store`/`documentStore`, set from the session, so the rest of the 5,577-line view is untouched. Splitting that view is plan 4.

**Tech Stack:** Swift 5.10, SwiftUI `@Observable`, XCTest.

**Spec:** `docs/superpowers/notes/2026-10-17-foundations-audit.md` §2 S3, §3 B3 and B4 (the verified Statistics-window symptom), and A2 (half). B6 (`ManifestStore`) and the `Document.load*` identity locator are deliberately NOT in this plan; see Out of scope.

## Global Constraints

- **Behaviour is unchanged for a single project window.** It opens the same stores in the same order and makes the same registry acts at open (`DocumentStore.open` declares this Mac, runs recognition, sweeps seals and starts transcription). The services shut down in the same order: **pipeline first**, then compiler, translator, designer, coldCall. A leg parked on a translator summary must be resolved before that translator is torn down (`ProjectWindow.swift:~490`, `CompilerRunModifier.swift:~91`).
- **`DocumentStore.open` runs once per project URL per app process while any window holds the session.** That call has registry side effects, so the second window must borrow, never re-open.
- **The shutdown contract is load-bearing.** `ClaudeCLISession.deinit` cannot reap its own child (`Maugham/Compiler/AREA.md`), so every window-ending path must call `shutdown()` or `detach()` on every service. A merely released service is a live billing process.
- **The window-liveness guard stays.** `ProjectWindow`'s `onDisappear` blanks its state only when `!MaughamEvent.isLive(window)`. A spurious `onDisappear` on a live window must not close the session (ADR 0021).
- **Tests never touch the real keychain, registry or socket.** Use the existing test seams, e.g. `TestWorkspace` and `TestTemp`. `PersonKeyAccess` already gives a test host an in-memory store.
- **Census edits ship with the code they guard.** `TranslatorEnvironmentTests.test_everyWindowEndingPathShutsEverySessionDown` changes shape in Task 1.
- **Do not edit `CLAUDE.md`, `docs/tripwires.md` or any `AREA.md`.** Plan 1's branch is rewriting them; the controller sweeps the docs at merge.
- **Gates:** `./scripts/test.sh` (fast) after each task; `./scripts/test.sh full` plus a Release build (`xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`, run inside a script that holds the lock, or via `./scripts/test.sh only` + a separate Release build) before the final review. Run a Release build after any `ProjectWindow.body` change. Never raw `xcodebuild test`. Never `git push`.
- **Branch** `claude/foundations-plan3-project-session`, off plan 2's branch head. Plan 3's tests use `SourceTree`.

## Review Focus

1. **A second window on the same project re-runs `DocumentStore.open`.** That would duplicate the presenter and transcription, and register this Mac twice. *Pinned by:* the registry test that two `acquire` calls for one URL return the same session and open once (Task 3).
2. **The last window closes and something keeps the session alive,** such as a strong capture in an environment closure, a leaked borrow, or a still-configured service holding the project graph. *Pinned by:* a weak-reference test that the session deallocates after the last `release` (Task 3), plus the roster's detach-all test (Task 1).
3. **A service added later is not shut down.** *Pinned by:* the roster population census (Task 1).
4. **The Statistics window, opened alone with no project window, still works and still closes cleanly,** and its session-log refresh reaches a live store. *Pinned by:* Task 4's tests.
5. **A spurious `onDisappear` on a live window closes the session.** *Pinned by:* Task 2 keeps the `isLive` guard around `release`, and a test drives `release` only when the window is gone.

---

### Task 1: `AgentRoster` — one owner, one order, one census

**Files:**
- Create: `Maugham/Compiler/AgentRoster.swift`
- Create: `MaughamTests/AgentRosterTests.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`: the five service `@State`s (`:259-289`), `onDisappear` (`:~485-495`) and the model fan-out (`:~3234-3245`)
- Modify: `Maugham/Views/CompilerRunModifier.swift`: init parameters and the two shutdown arms (`:~91-104`)
- Modify: `MaughamTests/TranslatorEnvironmentTests.swift`: `test_everyWindowEndingPathShutsEverySessionDown` (`:798`)

**Contract:**

```swift
@MainActor @Observable
final class AgentRoster {
    let compiler: CompilerOrchestrator
    let translator: TranslatorOrchestrator
    let designer: DesignerOrchestrator
    let coldCall: ColdCall
    let pipeline: TranslationPipeline
    let translationRuns: TranslationRunLog

    init(compiler: CompilerOrchestrator = .init(), translator: TranslatorOrchestrator = .init(),
         designer: DesignerOrchestrator = .init(), coldCall: ColdCall = .init(),
         pipeline: TranslationPipeline = .init(), translationRuns: TranslationRunLog = .init())

    /// Ends every warm session, pipeline first (a parked leg is resolved before its translator goes).
    func shutdownAll()
    /// Detaches every service from its project environment, pipeline first.
    func detachAll()
    /// The depth-menu change: every service that spawns a session gets the new model.
    func updateModel(_ model: CompilerModelChoice)
}
```

Before writing `updateModel`, read the real fan-out at `ProjectWindow.swift:~3234-3245` and use the same calls in the same order. Read each service's `shutdown()`/`detach()` signature before calling it.

- [ ] **Step 1: Tests first** (`AgentRosterTests`):
  - (a) `shutdownAll` calls the pipeline's shutdown before the translator's. Use each service's existing test seam, or observe the order through a spy runner where the orchestrators already accept one; read `TranslatorOrchestratorTests` for the existing pattern.
  - (b) `detachAll` follows the same order.
  - (c) `updateModel` reaches every service the old fan-out reached.

  Run `./scripts/test.sh only AgentRosterTests`. Expected: compile failure. Run `./gen.sh` first.

- [ ] **Step 2: Implement.** Then make `ProjectWindow` hold `@State private var roster = AgentRoster()`. Replace every reference to the five services with `roster.<service>`, using a short `private var compiler: CompilerOrchestrator { roster.compiler }`-style accessor if that keeps the diff small. In `onDisappear`, call `roster.detachAll()`. In the model fan-out, call `roster.updateModel(_:)`.

  `CompilerRunModifier` takes the roster rather than five services, and both arms call `roster.shutdownAll()`.

- [ ] **Step 3: The census becomes a POPULATION census.** Rewrite `test_everyWindowEndingPathShutsEverySessionDown` to check four things:
  - (a) `CompilerRunModifier`'s two window-ending arms each call `roster.shutdownAll()`.
  - (b) `ProjectWindow`'s `onDisappear` calls `roster.detachAll()` (or the session's close, after Task 2).
  - (c) **Every production class that holds a session runner is a roster member.** Use `SourceTree` to find every type in `Maugham/` declaring a stored property of type `CompilerRunner`, `CompilerRunner?`, `ClaudeCLISession` or `ClaudeCLISession?`. Read the real property spellings first. Assert that the set of declaring types equals the set of `AgentRoster`'s stored property types, plus a named exemption list with a reason each. `ClaudeCLISession` itself, for example, is the runner and not a holder.
  - (d) A planted control: a planted sixth orchestrator holding a runner, not in the roster, is reported.

  Keep the old assertion's meaning: every arm shuts every service down.

- [ ] **Step 4: Disable experiment.** Remove `coldCall` from `shutdownAll`; a test must fail. Restore. Then run `./scripts/test.sh` (fast) and a Release build.

- [ ] Commit: `refactor(compiler): AgentRoster owns the warm-session services and their one teardown order; the census counts holders, not names`

---

### Task 2: `ProjectSession` — open and close move out of the view

**Files:**
- Create: `Maugham/Stores/ProjectSession.swift`
- Create: `MaughamTests/ProjectSessionTests.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`: `load()` (`:~4071-4250`) and `onDisappear`

**Contract:**

```swift
@MainActor @Observable
final class ProjectSession {
    let url: URL
    let projectStore: ProjectStore
    let documentStore: DocumentStore
    let bible: BibleStore
    let declaredWorld: DeclaredWorldStore
    let roster: AgentRoster

    /// Everything `ProjectWindow.load()` does that is not UI seeding: load the
    /// manifest, open the DocumentStore, cross-link them, build bible + world,
    /// configure every roster service with its production environment.
    static func open(url: URL, preferences: UserPreferences,
                     liveCanvas: CanvasModel?, onCompilerFlash: @escaping @MainActor (String) -> Void,
                     roster: AgentRoster) async throws -> ProjectSession

    /// The window-ending teardown, in order: roster.detachAll(), then documentStore.close().
    func close() async
}
```

Rules:
- The canvas model and the flash callback are the window's, so they are passed in.
- Everything else in `open` is moved, not rewritten. Keep the same statement order and the same `[weak …]` captures.
- `ProjectWindow.load()` keeps only the UI seeding from `ds.uiState`, which must still happen BEFORE `store`/`documentStore` are published (see the comment at `:~4088`), plus `mcpRegistry.register` and the session log.
- `onDisappear`, inside the existing `!isLive` guard, calls `await session.close()`; the registry takes this over in Task 3.

- [ ] **Step 1: Tests first** (`ProjectSessionTests`), against a real temp project built the way existing store tests build one:
  - (a) `open` returns a session whose `documentStore.projectStore === projectStore`, and vice versa.
  - (b) `close()` detaches every roster service. The orchestrators expose whether they are configured, or assert via a spy runner.
  - (c) After `close()` and dropping the last strong reference, a `weak var` to the session becomes nil.

  Reuse the existing fixture builder. Don't hand-write a project.

- [ ] **Step 2: Implement and adopt in `ProjectWindow`.** Hold `@State private var session: ProjectSession?`. Keep `store` and `documentStore` as `@State` mirrors set from the session, so the rest of the view is untouched. Run `./scripts/test.sh` and a Release build (this is a `ProjectWindow` change).

- [ ] Commit: `refactor(stores): ProjectSession owns an open project's stores and services; ProjectWindow.load seeds UI only`

---

### Task 3: `ProjectSessionRegistry` — one session per project, borrowed

**Files:**
- Create: `Maugham/Stores/ProjectSessionRegistry.swift`
- Create: `MaughamTests/ProjectSessionRegistryTests.swift`
- Modify: `Maugham/MaughamApp.swift` (create one registry and inject it with `.environment`, next to `mcpRegistry`, `:~11`)
- Modify: `Maugham/Views/ProjectWindow.swift` (acquire and release through the registry)

**Contract:**

```swift
@MainActor @Observable
final class ProjectSessionRegistry {
    /// The open session for `url`, opening it if none — concurrent callers for one URL
    /// await the SAME open (one in-flight Task per URL), never two.
    func acquire(_ url: URL, open: @escaping @MainActor () async throws -> ProjectSession) async throws -> ProjectSession
    /// Gives a borrow back; the last release for a URL closes the session.
    func release(_ url: URL) async
    /// Test seam: how many sessions are open.
    var openCount: Int { get }
}
```

Paths are standardised before keying: `url.standardizedFileURL`, plus resolving symlinks.

- [ ] **Step 1: Tests first.**
  - (a) Two `acquire`s for one URL return the identical session, and the `open` closure ran exactly once.
  - (b) Two CONCURRENT `acquire`s (`async let`) still open once.
  - (c) One `release` of two keeps it open; the second closes it, and `close()` ran.
  - (d) After the last release a weak reference to the session is nil.
  - (e) `acquire` for a different URL opens a second session.
  - (f) An `open` that throws leaves nothing registered, and the next `acquire` retries.

- [ ] **Step 2: Implement, and adopt in `ProjectWindow`.** `load()` gets its session with `try await sessions.acquire(url) { try await ProjectSession.open(…) }`. `onDisappear` (still inside `!isLive`) calls `await sessions.release(url)`.

  The roster belongs to the session, not to the window, so a second window on the same project shares the warm services. Note that in the report.

  Run `./scripts/test.sh` and a Release build.

- [ ] Commit: `feat(stores): one session per project, reference-counted; a second window borrows rather than re-opens`

---

### Task 4: The Statistics window borrows the session (the verified bug)

**Files:**
- Modify: `Maugham/Views/ProjectStatisticsWindow.swift` (`load()` `:72-80`, plus a new `onDisappear`)
- Test: `MaughamTests/ProjectStatisticsWindowSessionTests.swift` (create)

**The bug (verified):** `load()` calls `DocumentStore.open(url:)` a second time and keeps it only through `ProjectStore.documentStore`, which is `weak` (`ProjectStore.swift:182`). The store is released at once, so `reloadSessionLog` (`:89`) always returns early. Opening Statistics also repeats the open-time registry acts.

- [ ] **Step 1: Test first.** Pull the window's data source into a small `@MainActor` model, or reuse the registry, so it can be tested without a window. Pin two things:
  - (a) With a session already acquired for the URL, the Statistics load opens nothing new (`openCount` unchanged), and its store's `documentStore` is non-nil.
  - (b) With no session open, Statistics acquires one (`openCount` 1), and its disappearance releases it (`openCount` 0).

  Before the fix, (a) fails, because `documentStore` is nil after load.

- [ ] **Step 2: Fix.** Acquire through `ProjectSessionRegistry` (the environment) and keep the session in `@State`. On `onDisappear`, guarded by window liveness the way `ProjectWindow` guards it, release the session. `reloadSessionLog` reads `session.documentStore`.

- [ ] **Step 3:** Run `./scripts/test.sh`. Commit: `fix(statistics): the Statistics window borrows the project's session instead of opening a DocumentStore it immediately loses`

---

### Task 5: Panes get the services from the environment, not 9 parameters

**Files:**
- Modify: `Maugham/Views/DetailPaneToggle.swift` (`:4-141`, the init)
- Modify: `Maugham/Views/ProjectWindow.swift` (the call at `:~3180-3270`)
- Modify: the panes that read a service through the toggle

**Contract:**
- `ProjectWindow` puts the session's roster, bible and declared world into the environment, using `.environment(roster)` for `@Observable` types.
- `DetailPaneToggle` drops its service parameters: compiler, diagnostics if it comes from the roster, bible, world, translator, translationRuns, designer, pipeline and coldCall. The panes that need one read it with `@Environment(AgentRoster.self)` etc.
- Leave `documentStore` optional in this task. Tests mount the toggle without a store, and making it non-optional is plan 4's job, together with the window split.

- [ ] **Step 1:** Grep `MaughamTests` for every construction of `DetailPaneToggle(` and of each pane you change. Update each test to provide the environment. A test that mounts a pane with no roster in its environment would crash on `@Environment(AgentRoster.self)`; give each such test a roster built from its existing service fakes.

- [ ] **Step 2:** Implement. Run `./scripts/test.sh` and a Release build (this touches `ProjectWindow.body`).

- [ ] Commit: `refactor(views): panes read the project's services from the environment; DetailPaneToggle loses nine parameters`

---

## Finish

1. `./scripts/test.sh full` green, and a Release build green.
2. Whole-branch review on opus, given the audit note, this plan and the ledger. It should:
   - prove the single-window open order and teardown order are unchanged, by diffing old `load()`/`onDisappear` against the new `open`/`close`;
   - hunt for strong-reference cycles that keep a closed session alive;
   - check that the population census would catch a sixth service;
   - check that two windows on one project share one `DocumentStore.open`.
3. Smoke, for Denver: open a project, open Statistics, check its Practice numbers refresh after a writing session, close Statistics, close the project, and quit. Activity Monitor should show no `claude` child left running.
4. Do not merge without Denver.

## Out of scope (ruled)

- **`ManifestStore` (audit B6).** Unifying the manifest write door touches the schema gate's counted assignments (tripwire 50) and `ProjectStore+Structure`'s legacy path. It deserves its own plan once the session exists to own it.
- **The `Document.load*` static identity locator (audit B, Medium).** It has 109 references. The session is the right future owner; moving it is a separate plan.
- **`AgentSessionHolder` (de-duplicating the three orchestrators' runner lifecycles).** The roster closes the leak risk; the holder only removes duplication. Do it with the next new department.
