import Foundation

/// The window's current working mode. Four optional lenses over one project —
/// never gates. Every persona is reachable at any time regardless of project
/// state; nothing is disabled, and nothing is required before writing.
///
/// Decoding is forward-tolerant: an unrecognised raw value becomes `.author`
/// rather than throwing, so a project touched by a newer build still opens.
/// This is deliberately weaker than `ResearchRole`'s lossless `.unknown`
/// sentinel — persona is presentation state, not identity, so there is nothing
/// to preserve on behalf of the newer build.
public enum Persona: String, Codable, Equatable, Sendable, CaseIterable {
    case plan
    case author
    case review
    case publish

    /// The default a fresh project opens in. Authoring is the mode most of a
    /// writer's hours are spent in, and the one whose layout matches today's
    /// window exactly — so an upgrading writer sees no change until they ask.
    public static let `default`: Persona = .author

    public var displayName: String {
        switch self {
        case .plan: return "Plan"
        case .author: return "Author"
        case .review: return "Review"
        case .publish: return "Publish"
        }
    }

    public var systemImageName: String {
        switch self {
        case .plan: return "lightbulb"
        case .author: return "pencil.line"
        case .review: return "text.magnifyingglass"
        case .publish: return "book.closed"
        }
    }

    /// ⌘1–⌘4. Ordering is the stage arc, and `allCases` order must match.
    public var shortcutKey: Character {
        switch self {
        case .plan: return "1"
        case .author: return "2"
        case .review: return "3"
        case .publish: return "4"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Persona(rawValue: raw) ?? .default
    }
}

// MARK: - Pane registry

public extension Persona {
    /// The right-pane segments this persona offers, in picker order. The first
    /// is the persona's default.
    ///
    /// THIS IS THE EXTENSION POINT. A milestone adding a right-pane surface
    /// adds its `DetailSegment` case and one entry here — it does not touch
    /// `DetailPaneToggle`, the shortcut table, or `ProjectWindow`.
    ///
    /// The registry is the design's pane × persona matrix (§6.3 of
    /// `docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md`)
    /// made executable: every `●` and `○` cell for a built segment appears
    /// below, and `PersonaPaneRegistryTests.test_everyPersona_matchesTheDesignMatrix`
    /// checks the whole table rather than a row at a time — the matrix was
    /// swept row-wise twice and lost a cell each time (Review's translation
    /// and palette, then Plan's tasks).
    ///
    /// One deliberate deviation, marked at its case below: Publish carries
    /// `.inspector`, which §6.3 gives it as `—`.
    ///
    /// Reserved for later milestones of this redesign: `.diagnostics` →
    /// author; `.references` → author, review; `.intent` → plan, author,
    /// review, publish; `.visualLanguage` → plan, review, publish;
    /// `.editions` → publish.
    var panes: [DetailSegment] {
        switch self {
        case .plan:
            // Primaries first, then the ○ cells: Tasks is planning-adjacent
            // (what the writer intends to do next), Inspector is metadata.
            return [.research, .outline, .palette, .inbox, .tasks, .inspector]
        case .author:
            return [.inspector, .outline, .research, .tasks, .palette]
        case .review:
            // Order follows the review workflow: adjudicate notes, see what
            // changed, check the translated edition, then the supporting
            // lenses. Translation and Palette are ○ in the design's pane ×
            // persona matrix (§6.3) — reviewing a translated edition IS a
            // review activity, and `ProjectWindow` force-sets
            // `detailSegment = .translation` on entering translation review.
            return [.annotations, .history, .translation, .inspector, .outline, .tasks, .palette]
        case .publish:
            // Thin until M1D gives Publishing its own surfaces (editions,
            // config, visual language). Translation is genuinely its work
            // today. DELIBERATE DEVIATION from §6.3, which marks Inspector
            // `—` for Publish: without it the picker is a single button,
            // which reads as broken chrome rather than a choice. Drop it
            // when Publish gains its own surfaces.
            return [.translation, .inspector]
        }
    }

    var defaultPane: DetailSegment {
        // `panes` is never empty — PersonaPaneRegistryTests enforces ≥2.
        panes.first ?? .inspector
    }

    /// Map a segment onto one this persona actually offers. Used when the
    /// writer switches persona while sitting on a pane the destination does
    /// not have — the same shape as `BinderSegment.documentHome(for:)`, which
    /// exists because re-deriving that check inline shipped a real bug
    /// (2026-07-02 smoke finding).
    func coerce(_ segment: DetailSegment) -> DetailSegment {
        panes.contains(segment) ? segment : defaultPane
    }
}
