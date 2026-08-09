import XCTest
import MaughamCore

// MARK: - A tiny property harness (seeded, shrinking, reporting)
//
// No SwiftCheck: MaughamCore forbids third-party dependencies and the
// experiment package deliberately mirrors that constraint. This is the minimum
// that gives the three things Phase 4 needs — a seeded generator so a shattered
// property reproduces, shrinking so the counterexample is minimal, and a printed
// `cases_run / held` line so the ledger can be filled from the run log.

struct PropertyResult {
    let name: String
    let casesRun: Int
    let held: Bool
    let counterexample: String?
    let rejected: Int
}

enum Property {

    /// Runs `body` over `count` generated cases. `body` returns nil when the
    /// property held and a description when it failed. `generate` may return nil
    /// to REJECT a case (rejection sampling); rejections do not count as cases.
    @discardableResult
    static func check<T>(
        _ name: String,
        seed: UInt64 = 0xA11CE,
        count: Int,
        generate: (inout SeededRNG) -> T?,
        shrink: (T) -> [T] = { _ in [] },
        body: (T) -> String?
    ) -> PropertyResult {
        var rng = SeededRNG(seed: seed)
        var run = 0, rejected = 0
        var attempts = 0
        let attemptCap = count * 50

        while run < count && attempts < attemptCap {
            attempts += 1
            guard let value = generate(&rng) else { rejected += 1; continue }
            run += 1
            if let failure = body(value) {
                let (minimal, minimalFailure) = minimise(value, shrink: shrink, body: body,
                                                         initialFailure: failure)
                let text = "after \(run) cases | minimal: \(describe(minimal)) | \(minimalFailure)"
                let r = PropertyResult(name: name, casesRun: run, held: false,
                                       counterexample: text, rejected: rejected)
                report(r); return r
            }
        }
        let r = PropertyResult(name: name, casesRun: run, held: true,
                               counterexample: nil, rejected: rejected)
        report(r); return r
    }

    /// Greedy shrink: repeatedly replace the failing value with the first smaller
    /// candidate that still fails, until no candidate does.
    private static func minimise<T>(
        _ value: T, shrink: (T) -> [T], body: (T) -> String?, initialFailure: String
    ) -> (T, String) {
        var best = value
        var bestFailure = initialFailure
        var improved = true
        var guardRail = 0
        while improved && guardRail < 500 {
            improved = false
            for candidate in shrink(best) {
                guardRail += 1
                if let f = body(candidate) {
                    best = candidate; bestFailure = f; improved = true; break
                }
            }
        }
        return (best, bestFailure)
    }

    private static func describe<T>(_ value: T) -> String {
        // Strings are escaped, not printed raw: a multi-line counterexample must
        // stay on one line or the run log is unreadable (this bit me on P09).
        if let s = value as? String { return s.debugDescription }
        if let s = value as? CustomStringConvertible { return s.description }
        return String(reflecting: value)
    }

    private static func report(_ r: PropertyResult) {
        print("PROP | \(r.name) | cases_run=\(r.casesRun) | held=\(r.held)"
              + (r.rejected > 0 ? " | rejected=\(r.rejected)" : "")
              + (r.counterexample.map { " | COUNTEREXAMPLE \($0)" } ?? ""))
    }
}

// MARK: - Shared generators

enum Gen {
    static let senseTokens = PaletteCard.Sense.allCases.map(\.rawValue)
    static let hexDigits = Array("0123456789abcdefABCDEF")
    static let wordish = ["the", "flat", "grey", "rain", "ash", "tram", "quarry", "tile",
                          "light", "cold", "turpentine", "shutters", "walk-up", "green"]

    static func word(_ rng: inout SeededRNG) -> String { rng.pick(wordish) }

    static func sentence(_ rng: inout SeededRNG) -> String {
        (0..<rng.int(1...6)).map { _ in word(&rng) }.joined(separator: " ")
    }

    /// A valid uppercase swatch — the canonical form the renderer emits.
    static func swatch(_ rng: inout SeededRNG) -> String {
        let n = rng.bool() ? 3 : 6
        return "#" + String((0..<n).map { _ in rng.pick(Array("0123456789ABCDEF")) })
    }

    /// A hex-ish candidate string, deliberately including the shapes that probe
    /// the boundary of `color(fromHex:)`.
    static func hexCandidate(_ rng: inout SeededRNG) -> String {
        var s = rng.bool(0.85) ? "#" : ""
        let n = rng.int(0...8)
        for _ in 0..<n {
            s.append(rng.bool(0.85) ? rng.pick(hexDigits) : rng.pick(Array("+-gGzZ .xX#")))
        }
        return s
    }

    /// A single path component that survives resolve/relativize unchanged.
    static func pathComponent(_ rng: inout SeededRNG) -> String {
        rng.pick(["research", "palette", "assets", "a", "bb", "ccc", "img", "x_assets",
                  "paris", "the-flat", "n1", "n2"])
    }

    static func projectRelativePath(_ rng: inout SeededRNG) -> String {
        let parts = (0..<rng.int(1...4)).map { _ in pathComponent(&rng) }
        return parts.joined(separator: "/") + rng.pick([".png", ".jpg", ".jpeg"])
    }
}

// MARK: - TreeNode generators + oracles

enum TreeGen {
    static func forest(_ rng: inout SeededRNG, maxNodes: Int = 24,
                       allowDuplicateIds: Bool = false) -> [XNode] {
        var pool = 0
        func nextId() -> String {
            if allowDuplicateIds && pool > 0 && rng.bool(0.35) { return "n\(rng.int(0...(pool - 1)))" }
            defer { pool += 1 }
            return "n\(pool)"
        }
        func node(_ depth: Int) -> XNode {
            let id = nextId()
            if depth >= 4 || pool >= maxNodes || rng.bool(0.45) {
                return XNode(id, rng.bool(0.15) ? [] : nil)
            }
            let n = rng.int(0...3)
            if n == 0 { return XNode(id, rng.bool(0.5) ? [] : nil) }
            return XNode(id, (0..<n).map { _ in node(depth + 1) })
        }
        return (0..<rng.int(0...4)).map { _ in node(0) }
    }

    static func pathForest(_ rng: inout SeededRNG) -> [XPathNode] {
        var counter = 0
        func node(_ depth: Int, _ parentPath: String?) -> XPathNode {
            counter += 1
            let id = "p\(counter)"
            let path: String?
            if rng.bool(0.15) { path = nil }
            else if let parentPath, rng.bool(0.7) { path = parentPath + "/" + Gen.pathComponent(&rng) }
            else { path = Gen.pathComponent(&rng) }
            if depth >= 3 || rng.bool(0.5) { return XPathNode(id, path: path, children: nil) }
            return XPathNode(id, path: path,
                             children: (0..<rng.int(1...3)).map { _ in node(depth + 1, path) })
        }
        return (0..<rng.int(0...3)).map { _ in node(0, nil) }
    }

    /// Independent reference implementation of pre-order flattening. Deliberately
    /// written as an explicit stack so it shares no code path with TreeWalk.
    static func referencePreOrder(_ nodes: [XNode]) -> [XNode] {
        var out: [XNode] = []
        var stack = Array(nodes.reversed())
        while let n = stack.popLast() {
            out.append(n)
            if let kids = n.children { stack.append(contentsOf: kids.reversed()) }
        }
        return out
    }
}

// MARK: - PaletteCard generators + reachability predicate

enum CardGen {

    /// Known section headings, in the exact form section detection recognises.
    static func spellsAKnownSection(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("## ") else { return false }
        return ["swatches", "senses", "images"]
            .contains(t.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The predicate the module's own header comment gestures at with the phrase
    /// "any editor-reachable model" but never spells out. Writing it was one of
    /// the more revealing parts of this experiment; see 04-property-results.md.
    static func isEditorReachable(_ c: PaletteCard) -> Bool {
        // Title: single line, already trimmed, non-empty.
        guard !c.title.isEmpty,
              c.title == c.title.trimmingCharacters(in: .whitespaces),
              !c.title.contains("\n") else { return false }
        // Swatches: canonical uppercase valid hex.
        for s in c.swatches {
            guard PaletteCard.color(fromHex: s) != nil, s == s.uppercased() else { return false }
        }
        // Notes: single line, trimmed; an untagged note must be non-blank and must
        // not itself look like a tagged one.
        for n in c.notes {
            guard !n.text.contains("\n"),
                  n.text == n.text.trimmingCharacters(in: .whitespaces) else { return false }
            if n.sense == nil {
                guard !n.text.isEmpty else { return false }
                if let colon = n.text.firstIndex(of: ":"),
                   PaletteCard.Sense(rawValue: n.text[..<colon]
                       .trimmingCharacters(in: .whitespaces).lowercased()) != nil { return false }
            }
        }
        // Images: project-relative, no scheme, no leading slash, no dot segments.
        for p in c.imagePaths {
            guard !p.contains("://"), !p.hasPrefix("/"), !p.isEmpty, !p.contains("\n") else { return false }
            let parts = p.split(separator: "/").map(String.init)
            guard !parts.contains("."), !parts.contains(".."), parts.count >= 1 else { return false }
        }
        // Body: no line spelling a known section heading (the documented residual),
        // and no carriage return (see M1-C-024).
        guard !c.body.contains("\r") else { return false }
        for line in c.body.split(separator: "\n", omittingEmptySubsequences: false) {
            if spellsAKnownSection(String(line)) { return false }
        }
        return true
    }

    static func body(_ rng: inout SeededRNG, pathological: Bool) -> String {
        var lines: [String] = []
        for _ in 0..<rng.int(0...5) {
            if rng.bool(0.2) { lines.append("") ; continue }
            if pathological && rng.bool(0.25) {
                lines.append(rng.pick(["## Swatches", "## Senses", "## Images", "## Weird",
                                       "# Another Title", "- a dash line", "kind: sneaky",
                                       "   ", "  ## Images  ", "###  deep", "\r"]))
                continue
            }
            var line = Gen.sentence(&rng)
            if rng.bool(0.15) { line = "    " + line }        // indentation
            if rng.bool(0.15) { line += "   " }               // trailing spaces
            if rng.bool(0.10) { line = "- " + line }          // dash-leading prose
            if rng.bool(0.10) { line = "kind: " + line }      // kind-looking prose
            if rng.bool(0.08) { line = "# " + line }          // heading-looking prose
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func card(_ rng: inout SeededRNG, pathological: Bool = false) -> PaletteCard {
        let notes = (0..<rng.int(0...4)).map { _ -> PaletteCard.SensoryNote in
            let tagged = rng.bool(0.6)
            var text = Gen.sentence(&rng)
            if pathological && rng.bool(0.3) {
                text = rng.pick(["", "   ", "smell: masquerading", "a\nb", "with: colon", ": lead"])
            }
            return .init(sense: tagged ? PaletteCard.Sense(rawValue: rng.pick(Gen.senseTokens))! : nil,
                         text: text)
        }
        var swatches = (0..<rng.int(0...4)).map { _ in Gen.swatch(&rng) }
        if pathological && rng.bool(0.3) { swatches.append(rng.pick(["not-hex", "#ggg", "#12", "#+FFFFF", "#abc"])) }
        var images = (0..<rng.int(0...3)).map { _ in Gen.projectRelativePath(&rng) }
        if pathological && rng.bool(0.3) { images.append(rng.pick(["https://e.com/x.png", "/abs/x.png", "", "../up.png"])) }
        var title = Gen.sentence(&rng)
        if pathological && rng.bool(0.2) { title = rng.pick(["", "  padded  ", "a\nb", "# hashy"]) }
        return PaletteCard(
            researchItemId: "res-1", title: title,
            kind: PaletteCard.Kind(rawValue: rng.pick(PaletteCard.Kind.allCases.map(\.rawValue)))!,
            swatches: swatches, notes: notes, imagePaths: images,
            body: body(&rng, pathological: pathological))
    }

    static let dir = "research/palette"

    static func roundTrip(_ c: PaletteCard, dir: String = dir) -> PaletteCard {
        PaletteCardParser.parse(markdown: PaletteCardRenderer.render(c, cardDirectory: dir),
                                itemId: c.researchItemId, fallbackTitle: "FB", cardDirectory: dir)
    }

    /// Shrink a card by dropping one element / emptying one field at a time.
    static func shrink(_ c: PaletteCard) -> [PaletteCard] {
        var out: [PaletteCard] = []
        func with(swatches: [String]? = nil, notes: [PaletteCard.SensoryNote]? = nil,
                  images: [String]? = nil, body: String? = nil, title: String? = nil) -> PaletteCard {
            PaletteCard(researchItemId: c.researchItemId, title: title ?? c.title, kind: c.kind,
                        swatches: swatches ?? c.swatches, notes: notes ?? c.notes,
                        imagePaths: images ?? c.imagePaths, body: body ?? c.body)
        }
        if !c.swatches.isEmpty {
            out.append(with(swatches: []))
            for i in c.swatches.indices { var s = c.swatches; s.remove(at: i); out.append(with(swatches: s)) }
        }
        if !c.notes.isEmpty {
            out.append(with(notes: []))
            for i in c.notes.indices { var n = c.notes; n.remove(at: i); out.append(with(notes: n)) }
        }
        if !c.imagePaths.isEmpty {
            out.append(with(images: []))
            for i in c.imagePaths.indices { var p = c.imagePaths; p.remove(at: i); out.append(with(images: p)) }
        }
        if !c.body.isEmpty {
            out.append(with(body: ""))
            let lines = c.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for i in lines.indices {
                var l = lines; l.remove(at: i); out.append(with(body: l.joined(separator: "\n")))
            }
        }
        if c.title != "T" { out.append(with(title: "T")) }
        return out
    }
}

extension PaletteCard: @retroactive CustomStringConvertible {
    public var description: String {
        "PaletteCard(title: \(title.debugDescription), kind: .\(kind.rawValue), "
        + "swatches: \(swatches), notes: \(notes.map { "(\($0.sense.map { ".\($0.rawValue)" } ?? "nil"), \($0.text.debugDescription))" }), "
        + "images: \(imagePaths), body: \(body.debugDescription))"
    }
}
