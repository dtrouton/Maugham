import SwiftUI
import MaughamCore
import AppKit

struct InspectorResearchPanel: View {
    @Bindable var store: ProjectStore
    let item: ResearchItem
    /// The window's tree: the Figures section a figure made here is revealed
    /// in, and its cached answer to which items bring a figure back. Nil
    /// offers no verb toward Figures.
    var figureTree: BinderTreeSectionsState? = nil
    /// The window refuses figure writes (`FigureActions.windowRefusesWrites`).
    var figureWritesRefused: Bool = false

    /// What the verb toward Figures last said (a refusal, the cells kept as
    /// text); cleared when the item changes or the verb flips.
    @State private var figureMessage: FigureMessage?

    /// A line the verb toward Figures says: a refusal reads red, as the
    /// figure inspector's does; a notice reads as a note.
    struct FigureMessage: Equatable {
        let text: String
        let isRefusal: Bool
    }

    @State private var draftTitle: String = ""
    @State private var draftCaption: String = ""
    @State private var draftTags: String = ""
    @State private var draftURL: String = ""
    @State private var isLoaded: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.type == .group ? "Group" : kindLabel(item.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Title") {
                    TextField("", text: $draftTitle, onCommit: commitTitle)
                        .textFieldStyle(.plain)
                }
                LabeledContent("Caption") {
                    TextEditor(text: $draftCaption)
                        .font(.body)
                        .frame(minHeight: 60)
                        .onChange(of: draftCaption) { _, _ in commitCaption() }
                }
                LabeledContent("Tags") {
                    TextField("comma-separated", text: $draftTags,
                              onCommit: commitTags)
                        .textFieldStyle(.plain)
                }
                if item.kind == .link {
                    LabeledContent("URL") {
                        TextField("", text: $draftURL, onCommit: commitURL)
                            .textFieldStyle(.plain)
                    }
                }
                if let figureTree, let verb = Self.figureVerb(for: item, store: store, tree: figureTree,
                                                             windowRefusesWrites: figureWritesRefused) {
                    Button(verb.title) {
                        figureMessage = nil
                        Self.useInDocument(item, store: store, tree: figureTree,
                                           windowRefusesWrites: figureWritesRefused) { figureMessage = $0 }
                    }
                    // The verb flipping (a park, a return) retires what it said.
                    .onChange(of: verb) { _, _ in figureMessage = nil }
                    if let figureMessage {
                        Text(figureMessage.text)
                            .font(.caption)
                            .foregroundStyle(figureMessage.isRefusal ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if item.type != .group {
                    Divider()
                    // Keyed on the item: a selection change makes a fresh
                    // section, so no commit of item A's draft can land on B.
                    InspectorCitationSection(store: store, item: item)
                        .id(item.id)
                    Divider()
                }
                if let added = item.addedAt {
                    LabeledContent("Added") {
                        Text(added, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let path = item.path {
                    LabeledContent("Path") {
                        HStack {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .truncationMode(.middle)
                                .lineLimit(1)
                            Spacer()
                            Button("Show in Finder") {
                                guard let fullURL = try? store.resolvedProjectPath(path)
                                else { return }
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [fullURL])
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(16)
        }
        .task(id: item.id) {
            draftTitle = item.title
            draftCaption = item.caption ?? ""
            draftTags = (item.tags ?? []).joined(separator: ", ")
            draftURL = item.url ?? ""
            figureMessage = nil
            isLoaded = true
        }
    }

    // MARK: Toward Figures (report plan 8b Task 4)

    /// The row menu's verb (`FigureSectionVerbs.researchVerb`'s answer), as
    /// this panel asks it: the window's refusal as the right column observes it.
    static func figureVerb(for item: ResearchItem, store: ProjectStore, tree: BinderTreeSectionsState,
                           windowRefusesWrites: Bool) -> FigureActions.ResearchVerb? {
        FigureSectionVerbs(store: store, state: tree)
            .shared(report: { _ in }, windowRefusesWrites: windowRefusesWrites)
            .researchVerb(for: item, returning: tree.figureReturns[item.id])
    }

    /// *Use in Document* / *Bring Back to Figures* from the panel: the tree's
    /// helper, the figure revealed in the tree once drawn, what it says on
    /// this panel's line.
    @discardableResult
    static func useInDocument(_ item: ResearchItem, store: ProjectStore, tree: BinderTreeSectionsState,
                              windowRefusesWrites: Bool,
                              say: @escaping (FigureMessage) -> Void) -> Task<Void, Never> {
        FigureSectionVerbs(store: store, state: tree)
            .shared(report: { say(FigureMessage(text: $0, isRefusal: true)) },
                    notice: { say(FigureMessage(text: $0, isRefusal: false)) },
                    windowRefusesWrites: windowRefusesWrites)
            .useInDocument(item, definedLabels: tree.definedFigureLabels,
                           reveal: { tree.revealFigureWhenDrawn($0) })
    }

    private func kindLabel(_ kind: ResearchItem.AssetKind?) -> String {
        switch kind {
        case .image: return "Image"
        case .pdf:   return "PDF"
        case .document: return "Document"
        case .audio: return "Audio"
        case .link:  return "Link"
        case .table: return "Table"
        case .none:  return "Item"
        }
    }

    private func commitTitle() {
        Task {
            try? await store.updateResearchItem(id: item.id, title: draftTitle)
        }
    }
    private func commitCaption() {
        Task {
            try? await store.updateResearchItem(id: item.id, caption: draftCaption)
        }
    }
    private func commitTags() {
        let tags = draftTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Task {
            try? await store.updateResearchItem(id: item.id, tags: tags)
        }
    }
    private func commitURL() {
        Task {
            try? await store.updateResearchItem(id: item.id, url: draftURL)
        }
    }
}
