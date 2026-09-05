import Foundation

/// Which mode the right pane displays.
public enum DetailSegment: String, Codable, Equatable, Sendable, CaseIterable {
    case inspector
    case annotations
    case history
    case tasks      // milestone-tasks
    case inbox      // iphone-companion: triage captures from MaughamPhone
    case translation // translation-layer: source text + translator queries (⌘⌥L)
    // M1A spine: the writer's intent and the book's visual language are one
    // op-logged artifact (`Statement`) in two kinds. Two cases rather than one
    // because they are different objects that happen to look alike — see
    // `Statement.Kind`.
    case intent          // m1a-spine: what you're going for (⌘⌥N)
    case visualLanguage  // m1a-spine: how the book looks (⌘⌥V)
    // editorial-letter P2: the lessons ledger (⌘⌥G). A third `Statement.Kind`
    // beside intent and visual language, and a third case for the same reason
    // they are two — the ledger is about the WRITER rather than about the book,
    // so it is a different object that happens to render through the same pane.
    case lessons
    // two-loops P2: the project's first reader (⌘⌥Y) — who reads your checks
    // as a reader, and what she knows. Another `Statement.Kind` and another
    // case for the reason the ones above it are separate: she is a person the
    // book is read by, not a thing the book is made of.
    //
    // **⌘⌥Y, because the word's own letters are spoken for.** Of "first
    // reader": F is Find in Project, I Inspector, R Research, T Tasks, E
    // References, A Annotations, D Diagnostics. That leaves S, and S is the one
    // to refuse rather than take — ⌘S is the checkpoint reflex this app goes
    // out of its way to keep (CLAUDE.md's hard invariants), and a pane one ⌥
    // slip away from it would open on a writer trying to save. Y is free across
    // the whole ⌘⌥ keyspace (verified 2026-09-05) and takes nothing.
    case firstReader
    case diagnostics     // m2-compiler-loop: the compiler's notes (⌘⌥D)
    case references      // m2-author-surfaces: what this piece is pinned to (⌘⌥E)
    // publish-department: the desk (⌘⌥K) — Publish's own working pane, where
    // the translator per language and the book designer are run from and their
    // state is read back. Publish's only, and it leads there
    // (`PersonaPaneRegistryTests.test_theDepartmentDeskIsPublishsAndLeadsIt`).
    case department
}

// MARK: - Presentation

/// Icon and tooltip live beside the case, not inside the picker, so a persona
/// can compose its own subset of segments (`Persona.panes`) without every
/// picker re-declaring how a segment looks. Shortcut letters in the help text
/// are owned by the View menu in `MaughamApp.swift` — keep them in step with
/// `docs/guide/reference.md` (guarded by `DocSyncTests`).
public extension DetailSegment {
    var systemImageName: String {
        switch self {
        case .inspector: return "info.circle"
        case .annotations: return "text.bubble"
        case .history: return "clock.arrow.circlepath"
        case .tasks: return "checklist.checked"
        case .inbox: return "tray"
        case .translation: return "character.book.closed"
        case .intent: return "target"
        case .visualLanguage: return "photo.on.rectangle.angled"
        // A closed book, because that is what the ledger is a record of: the
        // pieces already finished and what they taught, rather than the one
        // open on the desk.
        case .lessons: return "book.closed"
        // A person in a circle, because that is what this pane holds: one
        // named reader, not a document about reading.
        case .firstReader: return "person.crop.circle"
        case .diagnostics: return "checkmark.seal"
        // A pin, because that is the word the design uses for what this pane
        // holds — the piece's *pinned* set — and the shelf is a row of things
        // pinned up beside the desk rather than a folder of them.
        case .references: return "pin"
        // Two people, because that is what the pane is: the translator and the
        // designer, named, with what each of them is working on.
        case .department: return "person.2"
        }
    }

    var helpText: String {
        switch self {
        case .inspector: return "Inspector — document metadata, tags, links (⌘⌥I)"
        case .annotations: return "Annotations — review Claude's comments and suggested edits (⌘⌥A)"
        case .history: return "History — read-only timeline of edits, annotations, and checkpoints (⌘⌥H)"
        case .tasks: return "Tasks — todos in this document and across the project (⌘⌥T)"
        case .inbox: return "Inbox — triage captures from MaughamPhone (⌘⌥B)"
        case .translation: return "Translation — source text and translator queries (⌘⌥L)"
        case .intent: return "Intent — what you're going for, here or across the project (⌘⌥N)"
        case .visualLanguage: return "Visual Language — how the book looks (⌘⌥V)"
        case .lessons: return "What I've learned — lessons and choices, across the project (⌘⌥G)"
        case .firstReader:
            return "First reader — who reads your checks as a reader, and what she knows (⌘⌥Y)"
        case .diagnostics: return "Diagnostics — the compiler's notes on what you've written (⌘⌥D)"
        case .references: return "References — what this piece is pinned to (⌘⌥E)"
        case .department: return "Department — the book's design and its language editions (⌘⌥K)"
        }
    }
}
