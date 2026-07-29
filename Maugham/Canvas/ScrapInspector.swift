import SwiftUI

/// One card, in the inspector: what it says, what it became, and the way to
/// promote it.
///
/// **A card had no pane at all until 1C-c2, and this exists because of the
/// field that slice added.** A drawn mark can say *that* a card was promoted
/// and can never say *what it became*; CLAUDE.md rule 8 asks every new data
/// type for a surface that can inspect and act on it. The section that says so
/// is `PromotedArtifactSection`, shared with the region arm — for one slice
/// only this one had it, which is the same rule failing for the other half of
/// the field.
///
/// **There is no Delete button, deliberately.** ⌫ remains the only route to
/// deleting a scrap (ADR 0026's standing consequence). Adding one here for
/// symmetry with the region and line arms would be a design change wearing a
/// tidy-up's clothes.
///
/// **Promotion goes through the one command** — the same `.keyWindow` post the
/// File-menu item and ⌘⇧↩ make. A closure of its own would be a second path
/// that can drift from the keystroke.
struct ScrapInspector: View {

    let model: CanvasModel
    let nodeID: CanvasNodeID
    /// Deferred: it walks the manifest, and it is called only when a promoted
    /// card is selected. Same rule as `CanvasView.paletteSwatchHexes`.
    let artifactTitle: (String) -> String?
    let onOpenResearchItem: (String) -> Void

    private var node: CanvasNode? { model.scene.node(nodeID) }

    private var state: PromotedArtifactSection.ArtifactState {
        let mark = node?.promotedItemID
        return PromotedArtifactSection.artifactState(promotedItemID: mark,
                                                     title: mark.flatMap(artifactTitle))
    }

    var body: some View {
        Form {
            Section {
                Text(CanvasRenderer.chipTitle(for: nodeID, in: model.scene,
                                              scraps: model.scraps))
                    .lineLimit(2)
            } header: {
                Text("Card")
            } footer: {
                Text("The words live on the card. Editing them here isn't a thing "
                     + "— click into it on the canvas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PromotedArtifactSection(state: state, subject: .card,
                                    onOpen: onOpenResearchItem)

            Section {
                Button("Promote…") {
                    // The SAME command the menu item and ⌘⇧↩ post — see
                    // `RegionInspector` for why a closure of our own would be
                    // a second path, and why posting is safe from this column.
                    MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
                }
                Text("Promoting takes a copy. The card stays here with its words, "
                     + "and changing it afterwards doesn't change what it made.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
