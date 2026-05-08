import SwiftUI

struct DailyHeatmapSection: View {
    /// Map of midnight-of-day → word count summed across sessions
    /// starting on that day.
    let dailyCounts: [Date: Int]

    private let weeks = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Daily writing — last 13 weeks")
            heatmapGrid
            HStack {
                Text(monthLabel(forWeeksAgo: weeks))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                legend
                Spacer()
                Text(monthLabel(forWeeksAgo: 0))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var heatmapGrid: some View {
        let columns = (0..<weeks).reversed().map(\.self)
        return HStack(alignment: .top, spacing: 3) {
            ForEach(columns, id: \.self) { weekIdx in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { weekday in
                        cellFor(weeksAgo: weekIdx, weekday: weekday)
                    }
                }
            }
        }
    }

    private func cellFor(weeksAgo: Int, weekday: Int) -> some View {
        let date = dateFor(weeksAgo: weeksAgo, weekday: weekday)
        let count = dailyCounts[date] ?? 0
        // Color.clear with explicit frame + a background shape holds its
        // frame rigidly inside the VStack/HStack. Plain
        // `RoundedRectangle().fill().frame()` can flex despite the explicit
        // width/height — the fill returns an inherently-flexible view, so
        // the cells end up stretched horizontally and squashed vertically.
        return Color.clear
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(colorForCount(count)))
            .help(tooltip(for: date, count: count))
    }

    private func colorForCount(_ count: Int) -> Color {
        let max = (dailyCounts.values.max() ?? 0)
        guard max > 0 else { return Color.accentColor.opacity(0.06) }
        if count <= 0 { return Color.accentColor.opacity(0.06) }
        let q = Double(count) / Double(max)
        if q <= 0.25 { return Color.accentColor.opacity(0.18) }
        if q <= 0.5 { return Color.accentColor.opacity(0.36) }
        if q <= 0.75 { return Color.accentColor.opacity(0.55) }
        return Color.accentColor.opacity(0.85)
    }

    private func dateFor(weeksAgo: Int, weekday: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let now = cal.startOfDay(for: Date())
        let currentWeekday = cal.component(.weekday, from: now) - 1   // 0..6
        let daysBack = (weeksAgo * 7) + (currentWeekday - weekday)
        return cal.date(byAdding: .day, value: -daysBack, to: now) ?? now
    }

    private func tooltip(for date: Date, count: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dateStr = formatter.string(from: date)
        let countStr: String = count.formatted(.number)
        return dateStr + " · " + countStr + " words"
    }

    private func monthLabel(forWeeksAgo weeksAgo: Int) -> String {
        let date = dateFor(weeksAgo: weeksAgo, weekday: 0)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less").font(.caption).foregroundStyle(.tertiary)
            ForEach(0..<5, id: \.self) { i in
                Color.clear
                    .frame(width: 12, height: 12)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(opacities[i])))
            }
            Text("More").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private let opacities: [Double] = [0.06, 0.18, 0.36, 0.55, 0.85]
}
