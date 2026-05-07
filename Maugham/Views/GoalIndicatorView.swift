import SwiftUI

struct GoalIndicatorView: View {
    let metrics: EditorMetrics

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .regular, design: .default))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .padding(12)
    }

    private var label: String {
        let words = metrics.wordCount
        let mins = metrics.readingMinutes
        let wordsLabel = words.formatted(.number)
        if mins == 0 {
            return "\(wordsLabel) words"
        }
        return "\(wordsLabel) words · \(mins) min read"
    }
}
