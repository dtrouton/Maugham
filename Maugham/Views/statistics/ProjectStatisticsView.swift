import SwiftUI

struct ProjectStatisticsView: View {
    @Bindable var store: ProjectStore
    let sessionLog: SessionLog
    let onSelectChapter: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Statistics")
                    .font(.title)
                    .padding(.top, 24)
                Text("Sections will appear here in subsequent tasks.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }
}
