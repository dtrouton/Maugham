import SwiftUI
import MaughamCore

struct WelcomeSlide: Identifiable, Equatable {
    enum ID: String { case welcome, structure, focus, organize, collaborate, publish, safety, getStarted }
    let id: ID
    let symbol: String        // SF Symbol for the drawn illustration
    let heading: String
    let body: String
    var imageName: String?    // future: bundled screenshot overrides the symbol

    static let all: [WelcomeSlide] = [
        .init(id: .welcome,    symbol: "doc.text",            heading: "A room of one's own",
              body: "Maugham is a focus editor for serious creative writing. Your words live as plain text you own."),
        .init(id: .structure,  symbol: "sidebar.left",        heading: "Shape the whole work",
              body: "Stories, novels, screenplays, collections. The Binder holds your structure — drag to reorder."),
        .init(id: .focus,      symbol: "scope",               heading: "Disappear into the page",
              body: "Focus mode, typewriter scroll, sentence dimming, smart dashes & quotes. ⌘\\ hides everything but the words."),
        .init(id: .organize,   symbol: "rectangle.3.group",   heading: "Keep the threads",
              body: "Synopses, status, tags, word targets, to-do checklists, [[wiki-links]], an Outline corkboard, research beside the draft."),
        .init(id: .collaborate,symbol: "bubble.left.and.text.bubble.right", heading: "A reader who never rewrites you",
              body: "Claude Desktop can read, annotate and research — but never edits your manuscript. That stays yours."),
        .init(id: .publish,    symbol: "books.vertical",      heading: "Publish, beautifully",
              body: "Claude co-authors a bespoke LaTeX template tuned to your taste — a deeply personalised PDF, or a clean standard EPUB."),
        .init(id: .safety,     symbol: "clock.arrow.circlepath", heading: "Nothing is ever lost",
              body: "Autosave, a full edit history you can rewind, iCloud sync, ⌘S checkpoints. Write fearlessly."),
        .init(id: .getStarted, symbol: "sparkles",            heading: "Your turn",
              body: "Try a hands-on sample, or start a project of your own.")
    ]
}

/// First-run tour. Paged slides ending in a three-way fork. The three fork
/// actions + Skip are injected so the host owns navigation and the
/// completion flag.
struct WelcomeCarousel: View {
    let onSampleNovel: () -> Void
    let onSampleScreenplay: () -> Void
    let onNewProject: () -> Void
    let onSkip: () -> Void

    @State private var index = 0
    private var slides: [WelcomeSlide] { WelcomeSlide.all }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip", action: onSkip).buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(12)

            Spacer()
            illustration(slides[index].symbol)
            Text(slides[index].heading)
                .font(.system(size: 28, weight: .light, design: .serif))
                .padding(.top, 16)
            Text(slides[index].body)
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460).padding(.top, 8)
            Spacer()

            if slides[index].id == .getStarted {
                forkButtons
            } else {
                navButtons
            }
            dots.padding(.vertical, 18)
        }
        .frame(width: 640, height: 480)
    }

    private func illustration(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 84, weight: .thin))
            .foregroundStyle(.tint)
            .frame(height: 120)
    }

    private var navButtons: some View {
        HStack {
            Button("Back") { index -= 1 }.disabled(index == 0)
            Spacer()
            Button("Next") { index += 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }.padding(.horizontal, 40)
    }

    private var forkButtons: some View {
        VStack(spacing: 10) {
            Button { onSampleNovel() } label: { Label("Try a sample Novel", systemImage: "book").frame(maxWidth: 320) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button { onSampleScreenplay() } label: { Label("Try a sample Screenplay", systemImage: "film").frame(maxWidth: 320) }
                .controlSize(.large)
            Button { onNewProject() } label: { Label("Start a project of my own", systemImage: "doc.badge.plus").frame(maxWidth: 320) }
                .controlSize(.large)
        }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(slides.indices, id: \.self) { i in
                Circle().fill(i == index ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
