import SwiftUI

/// **The compiler's depth picker, mounted in both of its homes** (editorial
/// letter P1, Task 8): the Diagnostics pane's header (Author) and the round
/// cockpit's lane row (Review). One view type so the two surfaces cannot draw
/// two menus that quietly disagree about the choices on offer or which one is
/// checked — and one production `ForEach(CompilerModelChoice.allCases` site,
/// which `TripwireGrepTests` counts.
///
/// Moved verbatim from `DiagnosticsPane.gearMenu` (M2 Task 8): the checkmark
/// on the current choice and the `.help` text naming it are unchanged, so a
/// writer who already knows this control in Author finds the identical
/// behaviour in Review.
struct CompilerModelMenu: View {
    let choice: CompilerModelChoice
    let onChange: (CompilerModelChoice) -> Void

    var body: some View {
        Menu {
            ForEach(CompilerModelChoice.allCases, id: \.self) { candidate in
                Button {
                    onChange(candidate)
                } label: {
                    if candidate == choice {
                        Label(candidate.displayName, systemImage: "checkmark")
                    } else {
                        Text(candidate.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model: \(choice.displayName)")
    }
}
