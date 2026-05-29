import SwiftUI

/// Inspector subsection exposing per-section publish overrides for the
/// currently-selected piece. Writes back via `PublishConfigStore` so MCP
/// callers see the same state.
///
/// `PublishConfigStore` is an `actor`, so `load()` / `save(_:)` are awaited.
///
/// Race note: if the user selects piece B before piece A's load Task has
/// finished, the older Task can clobber state with A's values. We mitigate
/// by capturing the requested `pieceID` and bailing if `selectedPieceID`
/// has moved on by the time the load completes.
@MainActor
struct InspectorPublishSection: View {

    let projectURL: URL
    let selectedPieceID: String?

    @State private var config: PublishConfig? = nil
    @State private var section: PublishConfig.Section = .init()
    @State private var loadedForPieceID: String? = nil

    var body: some View {
        Group {
            if PublishStarter.isInitialized(in: projectURL),
               let pieceID = selectedPieceID {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Publishing").font(.caption).foregroundStyle(.secondary)

                    if loadedForPieceID == pieceID {
                        Toggle("Include in Table of Contents", isOn: Binding(
                            get: { section.includeInToc },
                            set: { newVal in
                                section.includeInToc = newVal
                                persist(pieceID: pieceID)
                            }))

                        Picker("Start on", selection: Binding(
                            get: { section.startOn },
                            set: { newVal in
                                section.startOn = newVal
                                persist(pieceID: pieceID)
                            })) {
                            Text("Any page").tag(PublishConfig.StartOn.any)
                            Text("Right page").tag(PublishConfig.StartOn.recto)
                            Text("Left page").tag(PublishConfig.StartOn.verso)
                        }

                        HStack {
                            Text("Title override")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("(none)", text: Binding(
                                get: { section.titleOverride ?? "" },
                                set: { newVal in
                                    section.titleOverride = newVal.isEmpty ? nil : newVal
                                    persist(pieceID: pieceID)
                                }))
                                .textFieldStyle(.roundedBorder)
                        }
                    } else {
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .onAppear { load(pieceID: pieceID) }
                .onChange(of: selectedPieceID ?? "") { _, newID in
                    if !newID.isEmpty { load(pieceID: newID) }
                }
            }
        }
    }

    private func load(pieceID: String) {
        // Reset loaded marker so the UI shows "Loading…" while we fetch.
        loadedForPieceID = nil
        Task { @MainActor in
            let cfgStore = PublishConfigStore(projectURL: projectURL)
            let cfg = (try? await cfgStore.load()) ?? PublishConfig()
            // Bail if the selection moved on while we were loading.
            guard selectedPieceID == pieceID else { return }
            self.config = cfg
            self.section = cfg.sections[pieceID] ?? .init()
            self.loadedForPieceID = pieceID
        }
    }

    private func persist(pieceID: String) {
        guard var cfg = config else { return }
        cfg.sections[pieceID] = section
        config = cfg
        Task { @MainActor in
            let cfgStore = PublishConfigStore(projectURL: projectURL)
            try? await cfgStore.save(cfg)
        }
    }
}
