import SwiftUI
import MaughamCore
import AppKit
import os

/// Reports the width of whatever it is applied to — once at mount, and again
/// whenever that width changes.
///
/// A `Color.clear` in a `.background` measures without proposing anything back,
/// which is the whole difference between reading the CONTAINER's geometry and
/// the feedback loop tripwire 3 is about. Nothing it reports is ever persisted.
///
/// **Internal rather than private because `DetailColumnWidthTests` mounts this
/// exact modifier.** The right column's affordability sum is only as good as the
/// number it is fed, and a harness that measured the window its own way would be
/// testing the harness.
struct ContainerWidthReporter: ViewModifier {
    let onWidth: (Double) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, width in
                        onWidth(Double(width))
                    }
            })
    }
}
