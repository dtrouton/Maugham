import SwiftUI
import MaughamCore

struct ProjectStatisticsView: View {
    @Bindable var store: ProjectStore
    let sessionLog: SessionLog
    /// The writer's process across the book (editorial letter P3, spec §5
    /// surface 1). `nil` while the window is still walking the op logs — a
    /// value the view passes straight through, because "still reading" and
    /// "nothing to show" are two different sentences and `PracticeSection`
    /// owns both.
    let practice: ProjectPractice?
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
                WordsByChapterSection(
                    chapters: chapterRows,
                    onSelectChapter: onSelectChapter)
                RecentSessionsSection(
                    events: sessionLog.eventsRecent(limit: 50))
                PracticeSection(
                    practice: practice,
                    onSelectChapter: onSelectChapter)
            }
            .padding(24)
        }
    }

    private var chapterRows: [WordsByChapterSection.ChapterRow] {
        store.manifest.structure.map { item in
            WordsByChapterSection.ChapterRow(
                id: item.id,
                title: item.title,
                wordCount: aggregateWordCount(for: item),
                wordTarget: item.wordTarget)
        }
    }

    private func aggregateWordCount(for item: StructureItem) -> Int {
        if item.type == .document {
            return store.cachedWordCount(for: item.id) ?? 0
        } else {
            return (item.children ?? [])
                .map { aggregateWordCount(for: $0) }
                .reduce(0, +)
        }
    }

    private var dailyCounts: [Date: Int] {
        let cal = Calendar.current
        let now = Date()
        let lower = cal.date(byAdding: .day, value: -91, to: now) ?? now
        return sessionLog.wordsByDay(in: lower...now)
    }
}
