# Phase 2c — Metadata + Metrics Design

**Date:** 2026-05-08
**Status:** Approved during brainstorm; ready for implementation plan.
**Anchor:** Builds on `2026-05-07-maugham-master-design.md` Phase 2 ("Novel Project Depth"). Sub-milestone 2c per `2026-05-08-phase-2-breakdown.md`.

---

## Goal

Three sub-areas shipping as one milestone:

1. **Inspector growth** — tags, per-document word target, and document-to-document links (both id-based picker AND `[[Title]]` wiki syntax in body).
2. **Word goals + session tracking** — activity-bracketed sessions, project-wide net delta, today's word count, target progress in the goal indicator.
3. **Project Statistics window** — a new top-level surface with project total, 13-week daily heatmap, words-by-chapter bar chart, and a recent-sessions table.

The three are interlocked: target progress is computed from session-aware word counts; the Statistics window depends on the session log; the inspector's word target feeds both the goal indicator and the chapter chart. Shipping together keeps the data model coherent.

---

## 1. Model additions

### 1.1 StructureItem extensions

`Maugham/Models/StructureItem.swift` adds two new optional fields:

```swift
public var tags: [String]?      // free-form per-document tags
public var links: [String]?     // ids of other StructureItems this document links to
```

Both are nil by default and Codable-compatible. Existing manifests without these keys decode cleanly (Codable's `decodeIfPresent` semantics preserved by the existing init signatures).

### 1.2 SessionEvent and SessionLog

New file `Maugham/Stores/SessionLog.swift`:

```swift
public struct SessionEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String          // UUID; uniqueness for conflict-merge
    public let startedAt: Date
    public let endedAt: Date
    public let wordsNet: Int       // signed; deletes can produce negatives
    public let deviceId: String?   // captured from a hash of host name; nil OK
}

public struct SessionLog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var events: [SessionEvent]

    public static let empty = SessionLog(schemaVersion: 1, events: [])

    /// Conflict-merge: union by event id, sorted by startedAt.
    /// Append-only logs compose safely under iCloud divergence —
    /// no event is ever modified after write, so picking the
    /// "later" version per id would also be correct, but union
    /// of ids is the simpler invariant.
    public static func merged(_ a: SessionLog, _ b: SessionLog) -> SessionLog
}
```

Storage path: `<project>/.maugham/sessions.json` — synced by iCloud as part of the project.

Schema-versioned for forward compatibility (matching `UIState`'s pattern).

### 1.3 ProjectTargets unchanged

`ProjectTargets { totalWords: Int?, deadline: Date? }` already exists and stays unchanged.

---

## 2. Inspector growth

### 2.1 Manuscript-mode inspector layout

`Maugham/Views/InspectorView.swift` — three new sections appended under the existing `Document` block (manuscript mode only). Order:

```
Document
├── Title           (existing, read-only)
├── Status          (existing, picker: Draft / Revising / Final)
├── Synopsis        (existing, multiline)
├── Tags            (new) — chip row + comma-separated input
├── Word target     (new) — Stepper + text field
├── Words           (existing, computed)
├── Links           (new) — list of linked docs + Add Link… popover
└── Linked from     (new) — backlinks computed from manifest scan

Project
└── Project Settings…  (existing)
```

### 2.2 Tags

UI: chip row (using `Capsule()` background per chip) with a multiline-flow layout. Below the chips: a TextField that accepts comma-separated input. Pressing Return commits the trimmed, deduped, non-empty values to the document's `tags` array. Click ⓧ on a chip to remove that tag.

Autocomplete: while typing, suggest completions drawn from the project's existing tag pool. The pool is computed on-the-fly by walking `manifest.structure` (and optionally `manifest.research`'s tags from 2b) and unioning the `tags` arrays. No separate index — small enough to recompute per-keystroke.

Persistence: `ProjectStore.updateInspector(id:tags:)` extension. Already-existing `updateInspector` gains an optional `tags:` parameter; nil leaves unchanged, non-nil sets the value (empty array clears).

### 2.3 Word target

UI: `LabeledContent("Word target")` with a `Stepper` (range 0–100 000, step 100) and adjacent text-field input (the Stepper-and-TextField pattern). `0` displays as "No target." When non-zero, the field shows the count.

Persistence: `ProjectStore.updateInspector(id:wordTarget:)` — `0` is stored as `nil` to keep the manifest clean.

### 2.4 Links

UI: list of rows under "Links". Each row shows the linked document's title (looked up live from manifest) plus a click-to-navigate gesture (sets `selectedItemId` to the link's target). Click ⓧ to remove that link. Below the list: an "+ Add link…" button that opens a `popover` showing all *other* documents in the project (search field at top + scrolling list). Click an entry to add it as a link.

Below "Links" is "Linked from" — an auto-computed backlink list. For each document in the project whose `links` contains the current doc's id, show a clickable row. Read-only.

Persistence: links flow through the unified `ProjectStore.updateInspector(id:links:)` parameter (§2.5). Backlinks are not stored, only computed by walking `manifest.structure` for each render.

### 2.5 ProjectStore.updateInspector signature

Existing signature must extend cleanly. Plan dictates:

```swift
public func updateInspector(
    id: String,
    synopsis: String? = nil,
    status: String? = nil,
    tags: [String]? = nil,
    wordTarget: Int? = nil,
    links: [String]? = nil
) async throws
```

`nil` leaves a field unchanged; non-nil writes (including empty arrays/strings, which clear).

---

## 3. Wiki-style `[[Title]]` syntax

### 3.1 Tokenizer

`MarkdownTokenizer` adds a new token kind:

```swift
public enum Kind: ... {
    // existing cases
    case wikiLink(title: String)
}
```

Match rule: `\[\[([^\[\]\n]+)\]\]` — anything between `[[` and `]]` that is not another `[`, `]`, or newline. Match is greedy within a single line. The captured `title` is the trimmed inner text.

### 3.2 Rendering

`ProseMode.applyTypography` — when applying styles to tokens, a `wikiLink` token gets:
- Body font + size (same as paragraph text — does not visually shrink)
- Color = current theme's link color
- Underline IF the title resolves to an existing document in the project, else no underline (broken-link style)

Resolution: case-insensitive comparison of trimmed title against each document's `title` in `manifest.structure`. First match wins (document-tree order). The renderer does NOT cache resolutions; resolution runs on each tokenize pass, which already happens on every keystroke.

This requires the tokenizer/styler to have access to the project manifest at render time. The cleanest path: `ProseMode.applyTypography` already takes a `theme` and `typography`; extend it to take an optional `project: WikiLinkProject` protocol with a `resolveDocumentId(forTitle:) -> String?` method. `ProjectStore` conforms.

### 3.3 Click handling

`EditorSurface` — when the user clicks inside the editor, `MaughamTextView` checks whether the character index is inside a `wikiLink` token range. If yes, look up the title via the resolver and post a `Notification` (`.maughamNavigateToDocument`) carrying the resolved id. `ProjectWindow` listens and sets `selectedItemId`.

Click detection: override `mouseDown(with:)` on `MaughamTextView`. Use `characterIndexForInsertion(at: point)` to find the index, then look up the token range covering that index from the most recent tokenizer output (which `EditorCoordinator` already keeps as state for focus highlighting).

### 3.4 Renames don't update bodies

If the user renames a document, bodies that reference the old title via `[[old title]]` keep the old text. The rendered link will appear as a "broken link" (no underline) until the user manually edits the wiki-link text. Out of scope for 2c — listed in §6.

---

## 4. Session tracking

### 4.1 SessionTracker

`Maugham/Stores/SessionTracker.swift` — new `@MainActor @Observable` final class owned by `DocumentStore`.

```swift
@MainActor
@Observable
public final class SessionTracker {
    public private(set) var activeSession: ActiveSession?

    public struct ActiveSession {
        let startedAt: Date
        let startWordCount: Int
        let deviceId: String?
    }

    /// Called by DocumentStore on every text change. Starts a session if
    /// none is active; resets the idle timer otherwise.
    public func recordTextChange(at: Date, projectWordCount: Int)

    /// Called by the idle timer 30 min after the last text change.
    public func endSessionIfIdle(at: Date, projectWordCount: Int) -> SessionEvent?

    /// Called on app quit; flushes any active session as a final event.
    public func endSessionImmediately(at: Date, projectWordCount: Int) -> SessionEvent?
}
```

The class doesn't write to disk itself — its caller (DocumentStore) takes the returned `SessionEvent?` and appends to the SessionLog through coordinated I/O.

Idle timer: `DispatchQueue.main.asyncAfter` with a token reset on every `recordTextChange`. On fire: `endSessionIfIdle` runs, returning a SessionEvent if a session was active.

### 4.2 30-minute threshold

Hard-coded in `SessionTracker`. User-configurable threshold is out of scope for 2c. The constant lives at the top of `SessionTracker.swift` so it's easy to find for a future preferences task.

### 4.3 Project word count

Total project words = sum of cached per-document word counts on `ProjectStore`. `ProjectStore` already caches `metrics` per open document via `EditorHost.onTextChange` updates; the aggregate is recomputed cheaply. Documents not currently loaded use the last-saved word count (cached on disk via the manifest's `wordCount` field if added; alternatively recompute from the file on demand — implementer's call during planning).

For 2c the simplest correct path is: cache `[String: Int]` (document id → word count) on `ProjectStore`, refreshed on document load and on save. The aggregate is `dict.values.reduce(0, +)`.

### 4.4 DocumentStore wiring

`DocumentStore` gains:
- `private var sessionTracker = SessionTracker()`
- `private var sessionLog: SessionLog = .empty` loaded on `open(url:)`
- `private var idleTimerToken: DispatchWorkItem?`
- Method: `func recordTextChange(text: String)` called from existing `scheduleSave`. This: updates the per-doc word-count cache, calls `sessionTracker.recordTextChange(...)`, and reschedules the idle timer.
- Method: `func writeSessionLog(_:) async throws` — coordinated write through `NSFileCoordinator` to `<project>/.maugham/sessions.json`.
- Conflict handling: if `NSFilePresenter` reports an external change to `sessions.json`, the next read merges via `SessionLog.merged(local, external)` and writes back the merged result. (This is much simpler than the document/manifest conflict UI from 1e — sessions are append-only, so union-merge is the correct behavior with no user choice required.)
- App-quit flush: existing `.maughamAppWillTerminate` hook in `MaughamApp` calls `documentStore.flushSessionOnQuit()` which calls `sessionTracker.endSessionImmediately(...)` and writes synchronously.

### 4.5 Today / week / 13-week aggregates

Pure functions on `SessionLog`:
- `wordsToday(timeZone: TimeZone = .current) -> Int`
- `wordsByDay(in range: ClosedRange<Date>) -> [Date: Int]` — keyed by midnight-local of each day.
- `eventsRecent(limit: Int) -> [SessionEvent]` — sorted descending by `startedAt`.

Used by GoalIndicator and Statistics window.

---

## 5. Goal indicator extension

`GoalIndicatorView` gains awareness of the current document's `wordTarget`, the project's `totalWords` target, and the day's running word count.

Display rules:

| State | Label |
|---|---|
| Per-doc target set | `1,234 / 5,000 words (24%) · today: 800` |
| No per-doc, project total set | `1,234 words · today: 800 · project 24%` |
| Neither | `1,234 words · 5 min read · today: 800` |

The "today" segment is always present (even if 0). Reading-minutes shows only when neither target is set, to keep the indicator from getting cluttered.

The view takes a `goalState: GoalIndicatorState` value type:

```swift
public struct GoalIndicatorState: Equatable, Sendable {
    public var docWordCount: Int
    public var docWordTarget: Int?
    public var projectWordCount: Int
    public var projectWordTarget: Int?
    public var wordsToday: Int
    public var readingMinutes: Int
}
```

`ProjectWindow` constructs this state from `metrics` + `store.manifest.targets` + `documentStore.sessionLog.wordsToday(...)`, refreshes it on every `onTextChange`.

---

## 6. Project Statistics window

### 6.1 Window scene

New SwiftUI scene in `MaughamApp`:

```swift
WindowGroup("Project Statistics", id: "project-stats", for: URL.self) { $url in
    if let url {
        ProjectStatisticsWindow(projectURL: url)
    }
}
.commandsRemoved()  // no Edit/View commands
```

Opens via:
- File → Show Project Statistics (no shortcut — the master design doesn't claim ⌘⇧ keys for stats and we want to leave room)
- The active project window's File-menu command posts a notification with the project URL; `MaughamApp` opens the window scene with that URL.

Multiple projects open multiple stats windows.

### 6.2 ProjectStatisticsWindow + ProjectStatisticsView

`ProjectStatisticsWindow` loads its own `ProjectStore` + `SessionLog` for the URL — independent from the project window's stores so closing one doesn't close the other.

`ProjectStatisticsView` is a single `ScrollView` with four sections in vertical order:

#### 6.2.1 Project total

```swift
struct ProjectTotalSection: View {
    let totalWords: Int
    let target: Int?
    let deadline: Date?
}
```

Big number `formatted(.number)` left-aligned, target as small subtext if set. Below: progress bar (8pt tall). Below that: meta line — `<remaining> to go · target: <date>` if both set, else just `<percent> complete`.

#### 6.2.2 Daily heatmap

```swift
struct DailyHeatmapSection: View {
    let dailyCounts: [Date: Int]   // midnight-local keys, last 91 days (13 wks)
}
```

7-row × 13-column grid (today's column on the right, 13 weeks back on the left). Cell intensity bucketed by quartile of the non-zero counts (5 buckets: zero, q1, q2, q3, q4). Hover via `.help(...)` modifier shows `<date> · <count> words`.

Color: theme's primary tint with opacity bands.

#### 6.2.3 Words by chapter

```swift
struct WordsByChapterSection: View {
    let chapters: [ChapterRow]
    let onSelectChapter: (String) -> Void  // id

    struct ChapterRow {
        let id: String
        let title: String
        let wordCount: Int
        let wordTarget: Int?
    }
}
```

One row per top-level manuscript item (`manifest.structure`). Group items show the sum of their descendant document word counts. Bar fill: when target set, fill = `wordCount / wordTarget` clamped to 100%. When no target, fill = `wordCount / max(allChapters.wordCount)` for visual scale. Red 1pt vertical line at target position when `wordTarget` is set.

Click bar → calls `onSelectChapter(id)` → the parent window posts `.maughamNavigateToDocument` notification → the project's main window (if open) brings forward and selects the item. If the project window isn't open, the notification opens it via the existing project-open path.

#### 6.2.4 Recent sessions

```swift
struct RecentSessionsSection: View {
    let events: [SessionEvent]   // last 50, sorted desc by startedAt
}
```

Plain SwiftUI `Table` (or `LazyVStack` with table-like row layout). Columns: Date · Time · Duration · Words. Date column shows `Today`, `Yesterday`, or `MMM d` for older, formatted via a `RelativeDateTimeFormatter`-or-custom helper. Words column right-aligned, `+N` style (positive sessions are the norm; negatives still display with a minus).

### 6.3 Out of scope for the window
- Sortable columns on the sessions table (default order only).
- Filters (date range, document, tags).
- Export to CSV.
- Section collapse-toggle.
- Detail drill-in on heatmap cells (just hover tooltip).

---

## 7. Architecture summary

### 7.1 New files

| File | Purpose |
|---|---|
| `Maugham/Stores/SessionLog.swift` | SessionEvent, SessionLog, conflict-merge |
| `Maugham/Stores/SessionTracker.swift` | Idle-timer + start/end logic |
| `Maugham/Views/InspectorTagsField.swift` | Chip-style tags field |
| `Maugham/Views/InspectorLinksSection.swift` | Links list + Add Link picker |
| `Maugham/Views/ProjectStatisticsWindow.swift` | Window scene wrapper |
| `Maugham/Views/statistics/ProjectStatisticsView.swift` | Top-level scroll container |
| `Maugham/Views/statistics/ProjectTotalSection.swift` | Project total + progress |
| `Maugham/Views/statistics/DailyHeatmapSection.swift` | 13-week heatmap grid |
| `Maugham/Views/statistics/WordsByChapterSection.swift` | Bar chart |
| `Maugham/Views/statistics/RecentSessionsSection.swift` | Sessions table |
| `Maugham/Models/GoalIndicatorState.swift` | Computed state for the indicator |
| Tests: `SessionLogTests`, `SessionTrackerTests`, `WikiLinkTokenizerTests`, `ProjectStoreInspectorTests` (extended) |

### 7.2 Modified files

| File | Change |
|---|---|
| `Maugham/Models/StructureItem.swift` | adds `tags: [String]?`, `links: [String]?` |
| `Maugham/Editor/MarkdownTokenizer.swift` | adds `wikiLink(title:)` token kind |
| `Maugham/Editor/ProseMode.swift` | renders wiki-link tokens with theme link color + conditional underline |
| `Maugham/Editor/EditorSurface.swift` | click handling for wiki-link ranges; posts notification |
| `Maugham/Stores/ProjectStore.swift` | extends `updateInspector` with tags/wordTarget/links; adds wiki-link resolver protocol conformance; adds project word-count cache |
| `Maugham/Stores/DocumentStore.swift` | session tracker + log persistence; idle timer; flush-on-quit |
| `Maugham/Views/InspectorView.swift` | three new sections (tags / target / links); adds "Linked from" |
| `Maugham/Views/GoalIndicatorView.swift` | takes `GoalIndicatorState`; renders with target progress + today |
| `Maugham/Views/ProjectWindow.swift` | wires `GoalIndicatorState` construction from manifest + sessionLog; listens for navigate-to-document notifications |
| `Maugham/MaughamApp.swift` | adds Project Statistics window scene + File-menu command |
| `Maugham/Models/MaughamNotifications.swift` | adds `.maughamShowProjectStatistics`, `.maughamNavigateToDocument` |

### 7.3 Test discipline

- **Pure logic, full TDD:** `SessionLogTests` (~8 tests for merge/today/wordsByDay), `SessionTrackerTests` (~6 tests for idle/start/end), `WikiLinkTokenizerTests` (~6 tests covering match patterns and edge cases).
- **Integration (real `NSFileCoordinator` + temp dirs):** `DocumentStore` extension tests for sessions.json read/write/conflict-merge (~4 tests). `ProjectStoreInspectorTests` extension for tags/wordTarget/links updates (~5 tests).
- **Smoke-build only:** all SwiftUI views (per the established 1d/1e/2a/2b pattern). Manual smoke catches UI seam bugs.

### 7.4 Estimated scope

~16-18 tasks. Sub-ordering: model + pure logic first (T2-T5), persistence next (T6-T7), session tracker plumbing (T8-T9), inspector UI (T10-T12), wiki-link rendering + click (T13), goal indicator (T14), statistics window built section-by-section (T15-T18), end-to-end smoke + tag (T19).

---

## 8. Acceptance criteria (smoke test outline)

Once milestone-2c ships, this 10-step smoke confirms health:

1. Open a Novel project. Inspector shows Tags / Word target / Links sections under Synopsis. Tags is empty; Word target is "No target"; Links is empty.
2. Type `Margaret, Lighthouse` into Tags, press Return. Two chips appear. Reopen project — chips persist.
3. Word target Stepper to 5000. Goal indicator updates to `0 / 5,000 words (0%) · today: 0`.
4. Click + Add link… in the Links section. Popover shows other docs. Pick "Chapter 2". Link row appears with click-to-navigate. Open Chapter 2. Inspector shows "Linked from: Chapter 1" backlink.
5. In Chapter 2 body, type `Margaret returns to [[Chapter 1]] for the first time.` The `[[Chapter 1]]` text renders blue + underlined. Click it; binder selection moves to Chapter 1.
6. Type body text for ~2 minutes, leave Maugham idle for 30 min, return. A SessionEvent has been recorded; goal indicator's "today" reflects the session's net words. (For testing, lower the idle threshold to 30 seconds via a debug constant edit, then reset.)
7. File → Show Project Statistics. Window opens; project total shows correctly with the 5,000 target.
8. Heatmap shows today's cell colored. Hover for tooltip.
9. Words-by-chapter shows Chapter 1, Chapter 2, etc. Bars proportional to counts; red target line at 5000 position. Click a bar — project window comes forward, selects that chapter.
10. Recent sessions shows the just-recorded session row. Date "Today", correct duration.

If all 10 pass, milestone 2c is healthy.

---

## 9. Open considerations

These don't block the plan but are flagged for future milestones:

- **Wiki-link rename propagation.** Renaming a doc breaks wiki-link bodies that referenced it by old title. A future milestone can add a "find references" tool or auto-update.
- **Session goals / streaks.** "Write 1000 words today" reminders, day-streak tracking, "you wrote N days in a row" — popular in writing apps but explicitly out of scope for 2c.
- **Hourly heatmap.** Time-of-day distribution of writing sessions could be a Phase 3 stats addition.
- **Tag rename / merge.** Currently tags are independent strings on each document. Renaming "novel" → "fiction" everywhere requires manual edits. A tag-management surface is a Phase 3 candidate.
- **Tag-based search / filter.** No surface in 2c. Phase 3+.
- **Export statistics to CSV.** Useful for writers tracking annual goals across multiple projects. Phase 3+.
