import SwiftUI
import AppKit

struct ImagePreview: View {
    let fileURL: URL

    var body: some View {
        if let nsImage = NSImage(contentsOf: fileURL) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView(
                "Image unavailable",
                systemImage: "photo.fill",
                description: Text(fileURL.lastPathComponent))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
