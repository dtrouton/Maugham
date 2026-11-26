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
              body: "Stories, novels, screenplays, collections, reports. The binder holds the whole work. Click any part of it, and the window turns to it."),
        .init(id: .focus,      symbol: "scope",               heading: "Disappear into the page",
              body: "Typewriter scrolling, sentence focus, smart dashes and quotes. ⌘\\ clears the chrome away from the page."),
        .init(id: .organize,   symbol: "rectangle.3.group",   heading: "Keep the threads",
              body: "Beside the draft sit two places. To resolve holds everything waiting on you. Brief holds what the piece in front of you is for, in your own words."),
        .init(id: .collaborate,symbol: "bubble.left.and.text.bubble.right", heading: "A reader who never rewrites you",
              body: "Claude can read your book, leave notes and do research, but it never edits your manuscript. That stays yours."),
        .init(id: .publish,    symbol: "books.vertical",      heading: "Publish, beautifully",
              body: "Typeset your book as a PDF or an EPUB. With Claude, design a template that looks like the book you have in mind."),
        .init(id: .safety,     symbol: "clock.arrow.circlepath", heading: "Nothing is ever lost",
              body: "Autosave, a full history you can rewind, iCloud sync, ⌘S checkpoints. Write fearlessly."),
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
