import SwiftUI

struct RecentSessionsSection: View {
    let events: [SessionEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recent sessions")
            if events.isEmpty {
                Text("No sessions yet — start writing and they'll appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                tableHeader
                Divider()
                ForEach(events) { e in
                    row(e)
                    Divider().opacity(0.5)
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack {
            colHeader("Date").frame(width: 90, alignment: .leading)
            colHeader("Time").frame(width: 130, alignment: .leading)
            colHeader("Duration").frame(width: 90, alignment: .leading)
            Spacer()
            colHeader("Words").frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 4)
    }

    private func colHeader(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func row(_ e: SessionEvent) -> some View {
        HStack {
            Text(dateLabel(e.startedAt))
                .frame(width: 90, alignment: .leading)
            Text(timeRange(e))
                .frame(width: 130, alignment: .leading)
            Text(durationLabel(e))
                .frame(width: 90, alignment: .leading)
            Spacer()
            Text(wordsLabel(e))
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(e.wordsNet >= 0 ? Color.primary : Color.red)
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func dateLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func timeRange(_ e: SessionEvent) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let start = f.string(from: e.startedAt)
        let end = f.string(from: e.endedAt)
        return start + " – " + end
    }

    private func durationLabel(_ e: SessionEvent) -> String {
        let mins = Int(e.endedAt.timeIntervalSince(e.startedAt) / 60)
        if mins < 60 { return String(mins) + " min" }
        let h = mins / 60
        let m = mins % 60
        return String(h) + "h " + String(m) + "m"
    }

    private func wordsLabel(_ e: SessionEvent) -> String {
        let n = e.wordsNet
        let s: String = n.formatted(.number)
        if n >= 0 { return "+" + s }
        return s
    }
}
