import SwiftUI
import AVKit

struct AudioPreview: View {
    let fileURL: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack {
            Spacer()
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(fileURL.lastPathComponent)
                .font(.headline)
                .padding(.top, 8)
            Spacer()
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 60)
                    .padding(.horizontal, 20)
            }
        }
        .task(id: fileURL) {
            player = AVPlayer(url: fileURL)
        }
    }
}
