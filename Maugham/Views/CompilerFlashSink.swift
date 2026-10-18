import SwiftUI
import MaughamCore
import AppKit
import os

/// **⌘R's acknowledgment capsule, as a value the window can hand out**
/// (2026-08-18 review, Minor 6).
///
/// Three `@State` bindings and the generation dance that keeps a double-press
/// honest — extracted from `ProjectWindow.showCompilerFlash` so a caller
/// holding the flash across a suspension holds these rather than a whole
/// `ProjectWindow` (and, transitively, its stores). The one production caller
/// that needs it is `runRoundWhenPieceOpens`, whose expiry closure lives for
/// the deferral's 5s bound.
///
/// It stays ONE spelling of the flash: `showCompilerFlash` delegates here
/// rather than the closure re-implementing the generation check, which is the
/// whole reason this is a type and not a capture list at the call site.
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
