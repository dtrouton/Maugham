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
                DailyHeatmapSection(
                    dailyCounts: dailyCounts)
                // Chapters, Sessions sections appended in T17-T18
            }
            .padding(24)
        }
    }

    private var dailyCounts: [Date: Int] {
        let cal = Calendar.current
        let now = Date()
        let lower = cal.date(byAdding: .day, value: -91, to: now) ?? now
        return sessionLog.wordsByDay(in: lower...now)
    }
}
