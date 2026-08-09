# Implementation brief — user-content move (ARM B: boundary claims)

You are implementing a Swift function from a written specification, as a controlled experiment.

## Your task

Implement `CandidateMover.move(from:to:in:)`, which moves a **user-editable file** (a manuscript
`.md`/`.fountain`, or a research note) from one project-relative path to another inside a Maugham
project folder.

Write the complete file to:
`MaughamTests/Experiment/CandidateMoverB.swift`

with exactly this shape:

```swift
import Foundation
@testable import Maugham

enum CandidateMover {
    /// Move user-editable content from `oldPath` to `newPath` (both
    /// project-relative, e.g. "research/note.md").
    @MainActor
    static func move(from oldPath: String, to newPath: String,
                     in store: DocumentStore) async throws {
        // your implementation
    }
}
```

Write ordinary, idiomatic Swift. Assume the destination's parent directory already exists.

---

## 1. The types you may use

### `DocumentStore`

The project-folder coordinator. One instance per open project. `@MainActor`-isolated.

```swift
@MainActor public final class DocumentStore {

    /// The project folder's URL. Project-relative paths are resolved against it.
    public let projectURL: URL

    /// Coordinated move of a file or folder, through NSFileCoordinator.
    public func coordinatedMove(from sourceURL: URL, to destinationURL: URL) async throws

    /// Coordinated atomic write of `text` to `fileURL`, through NSFileCoordinator.
    public func coordinatedWrite(text: String, to fileURL: URL) async throws

    /// Coordinated copy of a file or folder.
    public func executeCopy(from sourceURL: URL, to destinationURL: URL) async throws

    /// Schedule a coordinated write of `text` to `path` on a 750ms debounce.
    /// Used by research-note editing — anything that isn't a manuscript Document.
    public func scheduleFileSave(for path: String, text: String)

    /// Flush any pending `scheduleFileSave` immediately.
    public func flushPendingSave() async throws

    /// Register an open Document against its project-relative path.
    public func register(document: Document, for path: String)

    /// Remove a path from the open-document registry.
    public func unregister(path: String)

    /// The open Document at a project-relative path, if any.
    public func document(for path: String) -> Document?

    /// Every currently-open Document.
    public func allOpenDocuments() -> [Document]
}
```

### `Document`

One open manuscript. Owns its op log and its own autosave.

```swift
@MainActor public final class Document {

    /// Stable document identity. NOT a path — a Document does not know its own
    /// project-relative path. Only the store's registry maps path -> Document.
    public let docId: String

    /// Close the document: cancels its timers and flushes any pending state.
    public func close() async
}
```

## 2. Claims

Each claim is scoped to the API member it constrains.

| id | scope | kind | claim |
|---|---|---|---|
| S-B-01 | `DocumentStore.coordinatedMove` | POST | moves the item at `sourceURL` to `destinationURL`, coordinated through `NSFileCoordinator` so other coordinated readers/writers see an atomic transition |
| S-B-02 | `DocumentStore.coordinatedMove` | POST | throws if the source does not exist, or if the destination exists and cannot be replaced |
| S-B-03 | `DocumentStore.coordinatedWrite` | POST | atomically writes `text` to `fileURL`, coordinated |
| S-B-04 | `DocumentStore.scheduleFileSave` | POST | schedules a coordinated write of `text` to `path`, to be performed **750ms** after the most recent call; further calls within that window restart the timer and replace the payload |
| S-B-05 | `DocumentStore.scheduleFileSave` | POST | the scheduled write targets the `path` supplied **at schedule time** |
| S-B-06 | `DocumentStore.flushPendingSave` | POST | performs any pending `scheduleFileSave` write immediately and clears the pending state; returns having completed the write |
| S-B-07 | `DocumentStore.flushPendingSave` | POST | is a no-op when nothing is pending |
| S-B-08 | `Document` | INV | an open `Document` autosaves its own text to its own file on a **750ms** debounce, internally, without the store's involvement. It writes to the URL it was loaded from, which it captured at load time |
| S-B-09 | `Document.close` | POST | cancels the document's timers and flushes any pending state before returning |
| S-B-10 | `DocumentStore.register` | POST | the document becomes retrievable via `document(for:)` at that path and appears in `allOpenDocuments()` |
| S-B-11 | `DocumentStore.unregister` | POST | the path stops resolving via `document(for:)`; the `Document` object itself is not closed by this call |
| S-B-12 | `DocumentStore.document(for:)` | POST | returns the open `Document` registered at that project-relative path, or nil |
| S-B-13 | `DocumentStore.projectURL` | INV | project-relative paths are resolved by appending to `projectURL` |

## 3. Intent envelope

| id | clause |
|---|---|
| S-B-14 | **MUST** leave the file's bytes unchanged by the move |
| S-B-15 | **MUST** perform filesystem mutation of user content through `NSFileCoordinator`, never through a bare `FileManager` call, so the app's own file presenter is notified |
| S-B-16 | **MUST NOT** leave the project in a half-moved state if a step throws |
| S-B-17 | **MUST** treat a manuscript and a research note identically — the caller does not tell you which it is |

---

## 4. Output

Write the Swift file, then write your notes to
`MaughamTests/Experiment/NOTES-B.md`, covering:

- **(a)** anything the specification left ambiguous, and what you chose;
- **(b)** any contradiction you found between claims, quoted by id;
- **(c)** anything you had to decide that the specification does not mention at all;
- **(d)** your confidence that this implementation is correct in the real application, and what
  you would need to know to raise it.

Be blunt. A long list of gaps is the desired outcome.
