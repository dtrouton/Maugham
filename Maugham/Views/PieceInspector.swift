import SwiftUI
import MaughamCore

enum PieceInspectorKind {
    case prose
    case screenplay

    var kindLabel: String {
        switch self {
        case .prose: return "Prose"
        case .screenplay: return "Screenplay"
        }
    }

    var unavailableSymbol: String {
        switch self {
        case .prose: return "doc.text"
        case .screenplay: return "film"
        }
    }

    var targetLabel: String {
        switch self {
        case .prose: return "Word target"
        case .screenplay: return "Page target"
        }
    }

    var targetRange: ClosedRange<Int> {
        switch self {
        case .prose: return 0...100_000
        case .screenplay: return 0...500
        }
    }

    var targetStep: Int {
        switch self {
        case .prose: return 100
        case .screenplay: return 1
        }
    }
}

struct PieceInspector: View {
    @Bindable var store: ProjectStore
    let pieceId: String
    let kind: PieceInspectorKind

    var body: some View {
        if let piece = store.manifest.structure.first(where: { $0.id == pieceId }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(piece.title).font(.headline)
                    Text(kind.kindLabel).font(.caption).foregroundStyle(.secondary)
                    synopsisSection(piece: piece)
                    statusSection(piece: piece)
                    targetSection(piece: piece)
                    intentSection(piece: piece)
                    InspectorPublishSection(
                        projectURL: store.url,
                        selectedPieceID: piece.id)
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("Select a piece", systemImage: kind.unavailableSymbol)
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

    /// The review section: the derived status, then the pass ladder (M3 P1
    /// Task 4). The segmented draft/revising/final picker that stood here is
    /// gone — the writer rules on passes and the status is read off them.
    ///
    /// The write is this file's, not `PassLadder`'s: see that view's doc
    /// comment, and `PersonaPaneRegistryTests`' `setPassState` census, which is
    /// what the Review persona's claim on the Inspector now rests on.
    @ViewBuilder private func statusSection(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review").font(.caption).foregroundStyle(.secondary)
            PassLadder(
                item: piece,
                passes: store.manifest.effectiveReviewPasses,
                onSet: { passId, state in
                    Task { try? await store.setPassState(id: piece.id, passId: passId, state) }
                })
        }
    }

    /// A loose piece is a `type: .document` structure item and `ProjectWindow`
    /// passes the same `selectedItemId` here and to the right column, so the
    /// pane this row opens resolves to *this piece's* intent rather than the
    /// Collection's — which is what makes a button under a piece's heading
    /// honest (`InspectorIntentAffordanceTests`).
    @ViewBuilder private func intentSection(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Intent").font(.caption).foregroundStyle(.secondary)
            IntentAffordanceRow(store: store, selectedItemId: piece.id)
        }
    }

    @ViewBuilder private func targetSection(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.targetLabel).font(.caption).foregroundStyle(.secondary)
            switch kind {
            case .prose:
                Stepper(value: Binding(
                    get: { piece.wordTarget ?? 0 },
                    set: { newValue in
                        Task { try? await store.updateInspector(id: piece.id, wordTarget: newValue) }
                    }),
                    in: kind.targetRange, step: kind.targetStep) {
                    Text("\(piece.wordTarget ?? 0)")
                }
            case .screenplay:
                Stepper(value: Binding(
                    get: { piece.pageTarget ?? 0 },
                    set: { newValue in
                        Task { try? await store.updateInspector(id: piece.id, pageTarget: newValue) }
                    }),
                    in: kind.targetRange, step: kind.targetStep) {
                    Text("\(piece.pageTarget ?? 0) pages")
                }
            }
        }
    }
}
