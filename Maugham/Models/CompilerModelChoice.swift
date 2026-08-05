import Foundation

/// The model a compiler run is spawned against, persisted per project
/// (the Diagnostics pane's gear menu, M2 Task 8).
///
/// The CLI's own model names are an implementation detail the writer never
/// chose, so the gear menu speaks the compiler's own vocabulary — Fast /
/// Standard / Deep — and `claudeModel` is the one place that vocabulary maps
/// onto `claude -p`'s `--model` argument. `CompilerOrchestrator.defaultModel`
/// remains the fallback a run uses before this choice has ever been read.
public enum CompilerModelChoice: String, Codable, Equatable, Sendable, CaseIterable {
    case fast
    case standard
    case deep

    /// The literal the CLI's `--model` flag expects.
    public var claudeModel: String {
        switch self {
        case .fast: return "haiku"
        case .standard: return "sonnet"
        case .deep: return "opus"
        }
    }

    public var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .standard: return "Standard"
        case .deep: return "Deep"
        }
    }
}
