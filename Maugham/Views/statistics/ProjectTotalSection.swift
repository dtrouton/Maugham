import SwiftUI

struct ProjectTotalSection: View {
    let totalWords: Int
    let target: Int?
    let deadline: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Project total")
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(totalWords, format: .number)
                    .font(.system(size: 36, weight: .semibold))
                if let target {
                    Text("/ \(target.formatted(.number)) words")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            if let target, target > 0 {
                let progress = min(1.0, Double(totalWords) / Double(target))
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                HStack {
                    Text("\(Int(progress * 100))% complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(footerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footerText: String {
        let remaining = max(0, (target ?? 0) - totalWords)
        let remainingStr: String = remaining.formatted(.number)
        if let deadline {
            let dateStr: String = deadline
                .formatted(date: .abbreviated, time: .omitted)
            return remainingStr + " to go · target: " + dateStr
        }
        return remainingStr + " to go"
    }
}

func sectionHeader(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 11, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.6)
        .foregroundStyle(.secondary)
}
