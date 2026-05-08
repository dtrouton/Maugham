import SwiftUI

struct ProjectStatisticsView: View {
    @Bindable var store: ProjectStore
    let sessionLog: SessionLog
    let onSelectChapter: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ProjectTotalSection(
                    totalWords: store.projectWordCount,
                    target: store.manifest.targets?.totalWords,
                    deadline: store.manifest.targets?.deadline)
                // Heatmap, Chapters, Sessions sections appended in T16-T18
            }
            .padding(24)
        }
    }
}
