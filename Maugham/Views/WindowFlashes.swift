import SwiftUI

/// **The window's acknowledgments, as one value** (foundations plan 4 Task 6):
/// ⌘S's capsule, ⌘R's capsule and the MCP note banner. Five `@State`s on
/// `ProjectWindow` until then, held now in ONE `@State` of this type.
///
/// **A value, never an `@Observable`** (tripwire 2). The banner's model is a
/// reference it carries — `MCPBannerModel` was already a class with an
/// auto-dismiss timer of its own, and it is created once with the window's
/// `@State`, exactly as it was when it was a `@State` by itself.
@MainActor
struct WindowFlashes {
    /// ⌘S's capsule.
    var showingSave: Bool = false
    /// The run key's own acknowledgment (M2 §3.1) — the same overlay, its own
    /// flag, because ⌘S and ⌘R can be pressed a second apart and one flash
    /// showing the other's word is worse than two.
    var showingCompiler: Bool = false
    /// What that capsule says — the acknowledgment's own word, not a constant,
    /// because the second ⌘R of a double-press says something different
    /// (`CompilerOrchestrator.Acknowledgment`).
    var compilerLabel: String = CompilerOrchestrator.Acknowledgment.started.flashLabel
    /// Which flash the pending hide belongs to — see `CompilerFlashSink.show`.
    var compilerGeneration: Int = 0
    /// The banner announcing a research note Claude added through MCP.
    let mcpBanner = MCPBannerModel()
}
