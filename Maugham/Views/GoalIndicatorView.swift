import SwiftUI

struct GoalIndicatorView: View {
    let state: GoalIndicatorState

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
        let words: String = state.docWordCount.formatted(.number)
        let today: String = state.wordsToday.formatted(.number)

        if let target = state.docWordTarget {
            let pct = percent(state.docWordCount, of: target)
            let targetStr: String = target.formatted(.number)
            return words + " / " + targetStr + " words (" + String(pct)
                + "%) · today: " + today
        }

        if let projectTarget = state.projectWordTarget {
            let pct = percent(state.projectWordCount, of: projectTarget)
            return words + " words · today: " + today
                + " · project " + String(pct) + "%"
        }

        if state.readingMinutes == 0 {
            return words + " words · today: " + today
        }
        return words + " words · " + String(state.readingMinutes)
            + " min read · today: " + today
    }

    private func percent(_ value: Int, of total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(value) / Double(total)) * 100)
    }
}
