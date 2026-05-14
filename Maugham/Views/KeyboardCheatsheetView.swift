import SwiftUI

struct KeyboardCheatsheetView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(KeyboardShortcuts.all, id: \.category) { category in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.category)
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(category.items, id: \.label) { item in
                                HStack {
                                    Text(item.label)
                                        .font(.body)
                                    Spacer()
                                    Text(item.shortcut)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.secondary.opacity(0.1)))
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}
