import SwiftUI

struct WordsByChapterSection: View {
    let chapters: [ChapterRow]
    let onSelectChapter: (String) -> Void

    struct ChapterRow: Identifiable, Equatable {
        let id: String
        let title: String
        let wordCount: Int
        let wordTarget: Int?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Words by chapter")
            VStack(spacing: 4) {
                ForEach(chapters) { row in
                    chapterRow(row)
                }
            }
        }
    }

    private func chapterRow(_ row: ChapterRow) -> some View {
        Button {
            onSelectChapter(row.id)
        } label: {
            HStack(spacing: 10) {
                Text(row.title)
                    .frame(width: 160, alignment: .leading)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                bar(for: row)
                    .frame(maxWidth: .infinity)
                    .frame(height: 18)
                Text(countLabel(row))
                    .frame(width: 100, alignment: .trailing)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func bar(for row: ChapterRow) -> some View {
        GeometryReader { geo in
            let denom: Double = {
                if let t = row.wordTarget, t > 0 { return Double(t) }
                let max = chapters.compactMap { c -> Int? in
                    c.wordCount > 0 ? c.wordCount : nil
                }.max() ?? 0
                return Double(max == 0 ? 1 : max)
            }()
            let fillWidth = min(1.0, Double(row.wordCount) / denom) * geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.12))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: fillWidth)
                if let t = row.wordTarget, t > 0 {
                    let pos = min(1.0, Double(t) / denom) * geo.size.width
                    Rectangle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 1)
                        .offset(x: pos)
                }
            }
        }
    }

    private func countLabel(_ row: ChapterRow) -> String {
        let countStr: String = row.wordCount.formatted(.number)
        if let target = row.wordTarget {
            let targetStr: String = target.formatted(.number)
            return countStr + " / " + targetStr
        }
        return countStr
    }
}
