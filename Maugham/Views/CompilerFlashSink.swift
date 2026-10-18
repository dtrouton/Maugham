import SwiftUI

/// **⌘R's acknowledgment capsule, as a value the window can hand out**:
/// three `@State` bindings and the generation dance, so a caller holding the
/// flash across a suspension (`runRoundWhenPieceOpens`'s expiry closure)
/// holds these rather than a whole `ProjectWindow` and its stores. It stays
/// ONE spelling of the flash: `showCompilerFlash` delegates here.
@MainActor
struct CompilerFlashSink {
    let label: Binding<String>
    let generation: Binding<Int>
    let showing: Binding<Bool>

    /// The generation is what keeps a double-press honest: the first press's
    /// hide is still pending when the second arrives, and without it the
    /// second capsule would be taken off screen by a timer belonging to a
    /// flash the writer has already stopped reading.
    func show(_ acknowledgment: CompilerOrchestrator.Acknowledgment) {
        label.wrappedValue = acknowledgment.flashLabel
        generation.wrappedValue &+= 1
        let mine = generation.wrappedValue
        showing.wrappedValue = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard generation.wrappedValue == mine else { return }
            showing.wrappedValue = false
        }
    }
}
