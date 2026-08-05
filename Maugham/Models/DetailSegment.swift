import Foundation

/// Which mode the right pane displays.
public enum DetailSegment: String, Codable, Equatable, Sendable, CaseIterable {
    case inspector
    case annotations
    case research
    case outline
    case history
    case tasks      // milestone-tasks
    case inbox      // iphone-companion: triage captures from MaughamPhone
    case palette    // sensory-palette: write against a palette card (⌘⌥P)
    case translation // translation-layer: source text + translator queries (⌘⌥L)
    // M1A spine: the writer's intent and the book's visual language are one
    // op-logged artifact (`Statement`) in two kinds. Two cases rather than one
    // because they are different objects that happen to look alike — see
    // `Statement.Kind`.
    case intent          // m1a-spine: what you're going for (⌘⌥N)
    case visualLanguage  // m1a-spine: how the book looks (⌘⌥V)
    case diagnostics     // m2-compiler-loop: the compiler's notes (⌘⌥D)
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
        case .research: return "doc.text.magnifyingglass"
        case .outline: return "list.bullet.indent"
        case .history: return "clock.arrow.circlepath"
        case .tasks: return "checklist.checked"
        case .inbox: return "tray"
        case .palette: return "paintpalette"
        case .translation: return "character.book.closed"
        case .intent: return "target"
        case .visualLanguage: return "photo.on.rectangle.angled"
        case .diagnostics: return "checkmark.seal"
        }
    }

    var helpText: String {
        switch self {
        case .inspector: return "Inspector — document metadata, tags, links (⌘⌥I)"
        case .annotations: return "Annotations — review Claude's comments and suggested edits (⌘⌥A)"
        case .research: return "Research — this document's own and linked research (⌘⌥R)"
        case .outline: return "Outline — table or corkboard structure view (⌘⌥O)"
        case .history: return "History — read-only timeline of edits, annotations, and checkpoints (⌘⌥H)"
        case .tasks: return "Tasks — todos in this document and across the project (⌘⌥T)"
        case .inbox: return "Inbox — triage captures from MaughamPhone (⌘⌥B)"
        case .palette: return "Palette Card (⌘⌥P)"
        case .translation: return "Translation — source text and translator queries (⌘⌥L)"
        case .intent: return "Intent — what you're going for, here or across the project (⌘⌥N)"
        case .visualLanguage: return "Visual Language — how the book looks (⌘⌥V)"
        case .diagnostics: return "Diagnostics — the compiler's notes on what you've written (⌘⌥D)"
        }
    }
}
