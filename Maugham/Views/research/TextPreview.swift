import SwiftUI

struct TextPreview: View {
    let fileURL: URL
    @State private var text: String = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .serif))
                .frame(maxWidth: 720, alignment: .leading)
                .padding(20)
        }
        .task(id: fileURL) {
            text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }
}
