import SwiftUI

struct ProsePieceInspector: View {
    @Bindable var store: ProjectStore
    let pieceId: String

    var body: some View {
        if let piece = store.manifest.structure.first(where: { $0.id == pieceId }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(piece.title).font(.headline)
                    Text("Prose").font(.caption).foregroundStyle(.secondary)
                    synopsisSection(piece: piece)
                    statusSection(piece: piece)
                    wordTargetSection(piece: piece)
                    InspectorPublishSection(
                        projectURL: store.url,
                        selectedPieceID: piece.id)
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("Select a piece", systemImage: "doc.text")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func synopsisSection(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Synopsis").font(.caption).foregroundStyle(.secondary)
            TextField("Optional summary",
                      text: Binding(
                        get: { piece.synopsis ?? "" },
                        set: { newValue in
                            Task { try? await store.updateInspector(id: piece.id, synopsis: newValue) }
                        }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
        }
    }

    @ViewBuilder private func statusSection(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status").font(.caption).foregroundStyle(.secondary)
            Picker("Status", selection: Binding(
                get: { piece.status ?? "draft" },
                set: { newValue in
                    Task { try? await store.updateInspector(id: piece.id, status: newValue) }
                })) {
                Text("Draft").tag("draft")
                Text("Revising").tag("revising")
                Text("Final").tag("final")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder private func wordTargetSection(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Word target").font(.caption).foregroundStyle(.secondary)
            Stepper(value: Binding(
                get: { piece.wordTarget ?? 0 },
                set: { newValue in
                    Task { try? await store.updateInspector(id: piece.id, wordTarget: newValue) }
                }),
                in: 0...100_000, step: 100) {
                Text("\(piece.wordTarget ?? 0)")
            }
        }
    }
}
