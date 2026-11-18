import Foundation

/// Which mode the right pane displays.
public enum DetailSegment: String, Codable, Equatable, Sendable, CaseIterable {
    /// **To resolve** (shell plan 2, Task 7): what has been raised on the
    /// faces' piece — notes, the check's findings, to-dos — and waits on the
    /// writer (⌘1). It replaced the Annotations, Diagnostics and Tasks panes;
    /// ⌘⌥A, ⌘⌥D and ⌘⌥T open it on the Rounds, Checks and Mine filters.
    case resolve
    case inspector
    case history
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
    // References, A Annotations, D Diagnostics (the last three keys now open
    // To resolve on a filter). That leaves S, and S is the one
    // to refuse rather than take — ⌘S is the checkpoint reflex this app goes
    // out of its way to keep (CLAUDE.md's hard invariants), and a pane one ⌥
    // slip away from it would open on a writer trying to save. Y is free across
    // the whole ⌘⌥ keyspace (verified 2026-09-05) and takes nothing.
    case firstReader
    case references      // m2-author-surfaces: what this piece is pinned to (⌘⌥E)
    // publish-department: the desk (⌘⌥K) — where the translator per language
    // and the book designer are run from and their state is read back. The
    // picker offers it only while an edition is open
    // (`DetailPaneToggle.visibleSegments`).
    case department
}

// MARK: - Order

public extension DetailSegment {
    /// **The right column's one order** (shell p1 Task 6). Every picker is this
    /// sequence with some members left out — never a different sequence — so a
    /// pane is always in the same place relative to its neighbours.
    ///
    /// Denver: *"it'll be confusing if I am always hunting for the right option
    /// in different modes, so the order should be one set and things just
    /// disappear or appear in it, and we have some common anchors."*
    ///
    /// To resolve leads (shell plan 2 Task 7) — everything raised on the
    /// piece, the check's findings and the rounds' notes and the to-dos, in
    /// one list — then the Department desk, which only an edition offers.
    /// Then what the writer works WITH: Intent (what this piece is going
    /// for), the lessons ledger (what the writer has learned; a check is
    /// briefed on it), the first reader (who a check is read by), References
    /// (what the piece is pinned to), Visual Language. Then what flows
    /// THROUGH: Translation, History. Inspector closes the row, outermost.
    ///
    /// `DetailSegmentOrderTests` transcribes this order once and plants a
    /// reorder that keeps the first element; a new case must be given a place
    /// here or that suite goes red.
    static let pickerOrder: [DetailSegment] = [
        .resolve, .department, .intent, .lessons,
        .firstReader, .references, .visualLanguage, .translation,
        .history, .inspector
    ]

    /// **Panes that are about one document** and say nothing without one.
    /// `DetailPaneToggle.visibleSegments` leaves them out while the faces name
    /// no document (the Book, research, a figure, a place); a ⌘⌥ key still
    /// reaches each, because a selected segment is always carried.
    ///
    /// To resolve is not here: it reads the faces' piece without loading it
    /// (`ResolveReader`), so it is offered whatever the centre shows, and
    /// says itself what it is about when the faces name nothing it can show.
    static let needsADocument: Set<DetailSegment> = [
        .references, .translation, .history
    ]
}

// MARK: - Presentation

/// Icon and tooltip live beside the case, not inside the picker, so the picker
/// can show any subset of `pickerOrder` without re-declaring how a segment
/// looks. Shortcut letters in the help text
/// are owned by the View menu in `MaughamApp.swift` — keep them in step with
/// `docs/guide/reference.md` (guarded by `DocSyncTests`).
public extension DetailSegment {
    var systemImageName: String {
        switch self {
        // A tray, because that is what the list is: what has come in and is
        // waiting on the writer.
        case .resolve: return "tray"
        case .inspector: return "info.circle"
        case .history: return "clock.arrow.circlepath"
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
        case .resolve: return "To resolve — what has been raised and waits on you (⌘1)"
        case .inspector: return "Inspector — document metadata, tags, links (⌘⌥I)"
        case .history: return "History — read-only timeline of edits, annotations, and checkpoints (⌘⌥H)"
        case .translation: return "Translation — source text and translator queries (⌘⌥L)"
        case .intent: return "Intent — what you're going for, here or across the project (⌘⌥N)"
        case .visualLanguage: return "Visual Language — how the book looks (⌘⌥V)"
        case .lessons: return "What I've learned — lessons and choices, across the project (⌘⌥G)"
        case .firstReader:
            return "First reader — who reads your checks as a reader, and what she knows (⌘⌥Y)"
        case .references: return "References — what this piece is pinned to (⌘⌥E)"
        case .department: return "Department — the book's design and its language editions (⌘⌥K)"
        }
    }
}
