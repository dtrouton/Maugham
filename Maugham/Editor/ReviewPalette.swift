import AppKit
import MaughamCore

/// Colour policy for the crafted review render (Component F). Each annotation
/// author gets a stable, muted "pencil" colour:
///
/// - **Claude** → a single fixed terracotta, reserved (never handed to a human).
/// - **Humans** → assigned from a small capped set of muted editorial tones by
///   hashing the author's `collaboratorId` (or `displayName` when id is nil).
///   Same identity → same colour across calls AND across process runs; once the
///   capped set is exhausted, distinct ids may collide (intentional — we assert
///   determinism, not uniqueness).
///
/// Pure: depends only on `NSColor` (no text view, no drawing). The hash is a
/// hand-rolled FNV-1a so the mapping is stable across launches — Swift's
/// built-in `Hasher` is per-process randomized and would shuffle the palette on
/// every relaunch.
struct ReviewPalette {

    /// The reserved terracotta for Claude. A warm, muted clay tone — distinct
    /// from every human tone below.
    static let claudeTerracotta = NSColor(
        srgbRed: AssistantNoteColour.red, green: AssistantNoteColour.green,
        blue: AssistantNoteColour.blue, alpha: 1.0)

    /// Capped set of muted editorial "pencil" tones for human reviewers.
    /// Desaturated on purpose — these are marginalia, not highlighter. None of
    /// them is the reserved terracotta. **Each adapts to the appearance**
    /// (shell p5a closing round B2): the dark page takes a lighter pencil,
    /// so every tone stands at least 3:1 against the editor's page in both
    /// (`ReviewPaletteTests`). One palette for the margin's dots, the cards
    /// and To resolve's author dots.
    static let humanTones: [NSColor] = zip(lightTones, darkTones).map { light, dark in
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// The tones on a light page: blue-pencil, plum, sage, slate, ochre.
    private static let lightTones: [NSColor] = [
        NSColor(srgbRed: 0.30, green: 0.40, blue: 0.62, alpha: 1.0),  // blue-pencil
        NSColor(srgbRed: 0.52, green: 0.36, blue: 0.55, alpha: 1.0),  // plum
        NSColor(srgbRed: 0.36, green: 0.50, blue: 0.42, alpha: 1.0),  // sage
        NSColor(srgbRed: 0.45, green: 0.45, blue: 0.50, alpha: 1.0),  // slate
        NSColor(srgbRed: 0.58, green: 0.48, blue: 0.30, alpha: 1.0),  // ochre
    ]

    /// The same pencils on the dark page: each 30% toward white.
    private static let darkTones: [NSColor] = [
        NSColor(srgbRed: 0.51, green: 0.58, blue: 0.73, alpha: 1.0),  // blue-pencil
        NSColor(srgbRed: 0.66, green: 0.55, blue: 0.69, alpha: 1.0),  // plum
        NSColor(srgbRed: 0.55, green: 0.65, blue: 0.59, alpha: 1.0),  // sage
        NSColor(srgbRed: 0.62, green: 0.62, blue: 0.65, alpha: 1.0),  // slate
        NSColor(srgbRed: 0.71, green: 0.64, blue: 0.51, alpha: 1.0),  // ochre
    ]

    /// Returns the stable pencil colour for an annotation's author.
    /// Claude → reserved terracotta; everyone else (including a nil author,
    /// treated as an anonymous human) → a deterministic pick from `humanTones`.
    func color(for author: AnnotationAuthor?) -> NSColor {
        if author?.sourceKind == .claude {
            return Self.claudeTerracotta
        }
        let key = Self.person(author)
        let index = Int(Self.stableHash(key) % UInt64(Self.humanTones.count))
        return Self.humanTones[index]
    }

    /// **Who a pencil is for**: the author's collaborator id, else their
    /// name — the key a tone is chosen by, and the one identity the margin
    /// asks whether a mark is one person's or several (closing round B2).
    static func person(_ author: AnnotationAuthor?) -> String {
        author?.collaboratorId ?? author?.displayName ?? ""
    }

    /// FNV-1a over the UTF-8 bytes. Deterministic across runs (unlike Swift's
    /// randomized `Hasher`) so an author keeps the same colour between launches.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}
