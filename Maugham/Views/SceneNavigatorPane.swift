import SwiftUI

struct SceneNavigatorPane: View {
    let script: FountainScript?
    /// Called with the line range location when the user clicks a scene.
    let onSelect: (Int) -> Void

    var body: some View {
        if let scenes = scenes, !scenes.isEmpty {
            List {
                ForEach(Array(scenes.enumerated()), id: \.offset) { _, scene in
                    sceneRow(for: scene)
                }
            }
            .listStyle(.sidebar)
        } else {
            VStack {
                Text("No scenes yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Type INT. or EXT. to add one.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scenes: [FountainLine]? {
        script?.lines.filter { $0.element == .sceneHeading }
    }

    @ViewBuilder
    private func sceneRow(for scene: FountainLine) -> some View {
        Button {
            onSelect(scene.range.location)
        } label: {
            HStack {
                Text(scene.content)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("p.\(pageNumber(for: scene))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pageNumber(for scene: FountainLine) -> Int {
        script?.pageNumber(at: scene) ?? 1
    }
}
