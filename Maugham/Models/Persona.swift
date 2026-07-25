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
    /// Reserved for later milestones of this redesign: `.diagnostics` →
    /// author; `.references` → author, review; `.intent` → plan, author,
    /// review, publish; `.visualLanguage` → plan, review, publish;
    /// `.editions` → publish.
    var panes: [DetailSegment] {
        switch self {
        case .plan:
            return [.research, .outline, .palette, .inbox, .inspector]
        case .author:
            return [.inspector, .outline, .research, .tasks, .palette]
        case .review:
            return [.annotations, .history, .inspector, .outline, .tasks]
        case .publish:
            // Thin until M1D gives Publishing its own surfaces (editions,
            // config, visual language). Translation is genuinely its work
            // today; inspector keeps the picker from being a single button.
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
