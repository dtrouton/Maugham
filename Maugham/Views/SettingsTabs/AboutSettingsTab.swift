import SwiftUI

struct AboutSettingsTab: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Maugham")
                .font(.system(size: 36, weight: .light, design: .serif))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer().frame(height: 12)
            Link("github.com/dtrouton/Maugham",
                 destination: URL(string: "https://github.com/dtrouton/Maugham")!)
                .font(.callout)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
