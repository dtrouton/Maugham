import SwiftUI

/// "Maugham Help" — a resizable window with a topic sidebar (from the bundled
/// `guide/index.json`) and a rendered-markdown content pane. Reads the same
/// files as the `get_help` MCP tool via `HelpTopicIndex`.
struct HelpWindow: View {
    @State private var index: HelpTopicIndex?
    @State private var selectedSlug: String?
    @State private var loadError: String?

    var body: some View {
        NavigationSplitView {
            if let index {
                List(index.topics, id: \.slug, selection: $selectedSlug) { topic in
                    Text(topic.title).tag(topic.slug)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            } else {
                Text(loadError ?? "Loading…").foregroundStyle(.secondary)
            }
        } detail: {
            if let index, let slug = selectedSlug,
               let md = try? index.markdown(for: slug) {
                GuideMarkdownView(markdown: md)
            } else {
                ContentUnavailableView("Maugham Help",
                    systemImage: "book",
                    description: Text("Choose a topic from the list."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
            do {
                let idx = try HelpTopicIndex.bundled()
                index = idx
                selectedSlug = idx.topics.first?.slug
            } catch { loadError = "Help content unavailable." }
        }
    }
}
