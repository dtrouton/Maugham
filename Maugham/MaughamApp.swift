import SwiftUI

@main
struct MaughamApp: App {
    var body: some Scene {
        Window("Maugham", id: "welcome") {
            Text("Maugham")
                .font(.largeTitle)
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
