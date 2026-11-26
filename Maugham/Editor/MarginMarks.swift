import AppKit
import MaughamCore

/// **View ▸ Margin** (shell p5 Task 2): what the trailing margin beside the
/// text marks. Remembered per project on this Mac (`UIState.marginSetting`);
/// Off is the default and draws nothing at all.
public enum MarginSetting: String, Codable, CaseIterable, Sendable {
    case off
    case myNotes
    case everythingFlagged

    /// The menu item's title.
    var title: String {
        switch self {
        case .off: return "Off"
        case .myNotes: return "My Notes"
        case .everythingFlagged: return "Everything Flagged"
        }
    }

    static let menuTitle = "Margin"
}

/// **The margin's marks for the open piece** (shell p5 Task 2) — positions,
/// never words. Pure: built once per key by the window
/// (`MarginMirrorModifier`) and handed one way through `EditorControl.margin`;
/// the overlay draws from the coordinator's cache of it (tripwire 4).
///
/// - A **dot** is an open note a person wrote (`NoteOwner.isAPersons`): a
///   dot beside its paragraph and a faint tint on its words.
/// - A **tick** is a paragraph carrying an item from a check or a round
///   (`ResolveFilter.source` `.checks` or `.pass`) among the items To
///   resolve's selection shows: one per paragraph, whatever the items say
///   and however many there are. A person's own note is a dot, never also a
///   tick.
///
/// ADR 0027 §1, as amended 2026-11-22: a wordless position mark is
/// permitted; nothing a model wrote is drawn — no string, count or colour
/// that encodes what an item says (`MarginOverlayCensusTests`).
struct MarginMarks: Equatable {
    struct Dot: Equatable {
        let paragraphId: String
        /// The note's words in its paragraph, in graphemes
        /// (`Annotation.resolvedSpanRange`); nil for a paragraph-level note
        /// (a dot and no tint).
        let span: Range<Int>?
        let annotationId: String
        /// Who wrote it, for VoiceOver ("Note by …"): the person's own name.
        let name: String
        /// **The person's colour** (closing round B; ADR 0027 §1 as
        /// amended): the review render's pencil for that person
        /// (`ReviewPalette`), so a dot and its card agree. A dot is only ever
        /// a person's (`drawnBesideTheText`); a model's note draws none.
        var colour: NSColor = MarginOverlayView.dotColor
    }

    let dots: [Dot]
    /// Paragraph ids. Everything Flagged only.
    let ticks: Set<String>

    static let none = MarginMarks(dots: [], ticks: [])

    var isEmpty: Bool { dots.isEmpty && ticks.isEmpty }

    /// The marks for one piece.
    ///
    /// - Parameters:
    ///   - notes: the piece's open notes (its `Document`'s).
    ///   - owner: whose each note is — `Document.noteOwner`, the one door;
    ///     never the note's stamp.
    ///   - items: what To resolve lists for the piece (its notes and its
    ///     check's live strains).
    ///   - selection: To resolve's selection as last published (empty:
    ///     everything).
    ///   - focusMode: focus mode hides the margin whatever the setting.
    ///   - readingTranslation: the anchors are the source's, so a piece read
    ///     in a language draws nothing.
    ///   - reviewRenderIsOn: the review render (read-through, or a posture
    ///     that refuses the text) already marks the same notes: the dots
    ///     yield to it, the ticks still draw.
    static func of(setting: MarginSetting, notes: [Annotation], owner: (Annotation) -> NoteOwner,
                   items: [ResolveItem], selection: Set<ResolveSource>, localName: String,
                   focusMode: Bool, readingTranslation: Bool, reviewRenderIsOn: Bool) -> MarginMarks {
        guard setting != .off, !focusMode, !readingTranslation else { return .none }
        let persons = drawnBesideTheText(notes.filter { $0.status == .open }, owner: owner)
        let dots: [Dot] = reviewRenderIsOn ? [] : persons.compactMap { note in
            guard let paragraphId = note.paragraphId else { return nil }
            return Dot(paragraphId: paragraphId, span: note.resolvedSpanRange,
                       annotationId: note.id, name: note.author?.displayName ?? "",
                       colour: ReviewPalette().color(for: note.author))
        }
        guard setting == .everythingFlagged else { return MarginMarks(dots: dots, ticks: []) }
        let personIds = Set(persons.map(\.id))
        var ticks = Set<String>()
        for item in ResolveFilter.visible(items, selection: selection, localName: localName) {
            guard let paragraphId = item.paragraphId else { continue }
            if case .note(let note) = item, personIds.contains(note.annotation.id) { continue }
            switch ResolveFilter.source(of: item, localName: localName) {
            case .checks, .pass: ticks.insert(paragraphId)
            case .mine, .questions, .others, .changes, .design, .compile: break
            }
        }
        return MarginMarks(dots: dots, ticks: ticks)
    }

    /// **The notes that may be drawn beside the text**: those a person wrote
    /// (`NoteOwner.isAPersons`, the one predicate). The margin's dots and the
    /// review render's cards both come through here, so Claude's notes stay
    /// in To resolve under read-through too (the owner's answer, 2026-11-22).
    static func drawnBesideTheText(_ notes: [Annotation],
                                   owner: (Annotation) -> NoteOwner) -> [Annotation] {
        notes.filter { owner($0).isAPersons }
    }

    /// What VoiceOver hears for the dots beside one line, and for a tick:
    /// fixed words and, for a single note, its writer's own name — nothing a
    /// note says, and no count.
    static func accessibilityLabel(ofDots names: [String]) -> String {
        guard names.count == 1, let name = names.first else { return "Notes" }
        return name.isEmpty ? "Note" : "Note by \(name)"
    }
    static let tickAccessibilityLabel = "Flagged paragraph"

    /// The menu's check mark: the item matching the key window's setting;
    /// none with no project window.
    static func isChecked(_ item: MarginSetting, current: MarginSetting?) -> Bool {
        item == current
    }
}
