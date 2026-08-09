import XCTest
import MaughamCore

/// A PROBE, not a test. It asserts nothing; it prints observed behaviour so the
/// characterization assertions in the `*Characterization.swift` files can be
/// written from what the code ACTUALLY does rather than from what I expected it
/// to do. Kept in the repo so the observations are reproducible.
///
/// Run just this:  swift test --package-path register/ExperimentTests --filter ObservationProbe
final class ObservationProbe: XCTestCase {

    private func show(_ label: String, _ value: Any) {
        print("PROBE | \(label) = \(value)")
    }

    // MARK: - M2 TreeWalk

    func test_probe_treeWalk() {
        let empty: [XNode] = []
        show("find/empty", String(describing: TreeWalk.find(id: "a", in: empty)?.id))
        show("contains/empty", TreeWalk.contains(id: "a", in: empty))
        show("collectIds/empty", TreeWalk.collectIds(in: empty))
        show("leaves/empty", TreeWalk.leaves(in: empty).map(\.id))
        show("collect/empty", TreeWalk.collect(in: empty) { _ in true }.map(\.id))
        show("first/empty", String(describing: TreeWalk.first(in: empty) { _ in true }?.id))
        show("mutate/empty", TreeWalk.mutate(id: "a", in: empty) { $0 }.map(\.id))
        show("remove/empty", TreeWalk.remove(id: "a", in: empty).map(\.id))

        // Duplicate ids at different depths.
        let dup = [XNode("d", [XNode("d"), XNode("x")]), XNode("d")]
        show("find/dup -> which node (children count)",
             String(describing: TreeWalk.find(id: "d", in: dup)?.children?.count))
        show("collectIds/dup", TreeWalk.collectIds(in: dup))
        show("mutate/dup -> ids after renaming every match", TreeWalk.mutate(id: "d", in: dup) {
            var n = $0; n.id = "R"; return n
        }.map { "\($0.id)[\($0.children?.map(\.id).joined(separator: ",") ?? "nil")]" })
        show("remove/dup", TreeWalk.remove(id: "d", in: dup).map { "\($0.id)[\($0.children?.map(\.id).joined(separator: ",") ?? "nil")]" })

        // mutate: is the body's node already child-rewritten?
        let nested = [XNode("p", [XNode("p")])]
        var seenChildren: [String]? = nil
        _ = TreeWalk.mutate(id: "p", in: nested) { node in
            if seenChildren == nil { seenChildren = node.children?.map(\.id) }
            var n = node; n.id = "P"; return n
        }
        show("mutate/parent-sees-children-as", String(describing: seenChildren))

        // mutate/remove with an absent id.
        let sample = [XNode("a", [XNode("a1"), XNode("a2", [XNode("a2x")])]), XNode("b")]
        show("mutate/absent-is-identity", TreeWalk.mutate(id: "zz", in: sample) { _ in XNode("BOOM") } == sample)
        show("remove/absent-is-identity", TreeWalk.remove(id: "zz", in: sample) == sample)

        // collect: does a failing parent prune its matching children?
        let pruneProbe = [XNode("parent-no", [XNode("yes-1"), XNode("no-2", [XNode("yes-3")])])]
        show("collect/descends-through-non-match",
             TreeWalk.collect(in: pruneProbe) { $0.id.hasPrefix("yes") }.map(\.id))

        // collect: does a collected node keep its subtree?
        show("collect/keeps-subtree",
             String(describing: TreeWalk.collect(in: sample) { $0.id == "a" }.first?.children?.map(\.id)))

        // leaves: nil vs empty children, chain.
        let chain = [XNode("c1", [XNode("c2", [XNode("c3", [])])])]
        show("leaves/chain-terminating-in-empty-array", TreeWalk.leaves(in: chain).map(\.id))
        show("leaves/all-branches-nonempty", TreeWalk.leaves(in: sample).map(\.id))

        // first: sibling order vs depth.
        let sibs = [XNode("s1", [XNode("m-deep")]), XNode("m-shallow")]
        show("first/depth-first-not-breadth-first",
             String(describing: TreeWalk.first(in: sibs) { $0.id.hasPrefix("m") }?.id))

        // rewritePaths edges.
        func rw(_ tree: [XPathNode], _ old: String, _ new: String) -> [String?] {
            TreeWalk.rewritePaths(in: tree, replacingPrefix: old, with: new,
                                  path: XPathNode.readPath, setPath: XPathNode.writePath)
                .flatMap { [$0.path] + ($0.children?.map(\.path) ?? []) }
        }
        show("rewritePaths/empty-oldPrefix", rw([XPathNode("a", path: "x/y"), XPathNode("b", path: "")], "", "NEW"))
        show("rewritePaths/identity-when-same", rw([XPathNode("a", path: "p/q")], "p", "p"))
        show("rewritePaths/nil-path-untouched", rw([XPathNode("a", path: nil)], "p", "NEW"))
        show("rewritePaths/trailing-slash-oldPrefix", rw([XPathNode("a", path: "p/q")], "p/", "NEW"))
        show("rewritePaths/descends-into-children-of-non-match",
             rw([XPathNode("a", path: "unrelated", children: [XPathNode("b", path: "p/q")])], "p", "NEW"))
        show("rewritePaths/newPrefix-empty", rw([XPathNode("a", path: "p/q")], "p", ""))
        show("rewritePaths/both-node-and-descendant-match",
             rw([XPathNode("a", path: "p", children: [XPathNode("b", path: "p/q")])], "p", "NEW"))

        // idsByPath duplicate paths.
        let dupPaths = [XPathNode("first", path: "same"), XPathNode("second", path: "same")]
        show("idsByPath/duplicate-path-winner",
             TreeWalk.idsByPath(in: dupPaths, path: XPathNode.readPath)["same"] ?? "nil")
        let parentChildSame = [XPathNode("parent", path: "same",
                                         children: [XPathNode("child", path: "same")])]
        show("idsByPath/parent-vs-child-same-path-winner",
             TreeWalk.idsByPath(in: parentChildSame, path: XPathNode.readPath)["same"] ?? "nil")
        show("idsByPath/empty-string-path-is-a-key",
             TreeWalk.idsByPath(in: [XPathNode("e", path: "")], path: XPathNode.readPath))
        show("idsByPath/empty-forest",
             TreeWalk.idsByPath(in: [XPathNode](), path: XPathNode.readPath))
    }

    // MARK: - M1 PaletteCard

    func test_probe_hex() {
        for s in ["#", "#f", "#ff", "#ffff", "#fffff", "#ffffffff", "#FFFFFF ", "# fff",
                  "#+FFFFF", "#-FFFFF", "##fff", "#0x1234", "#ABCDEF", "#abcdef",
                  "#000", "#FFF", "#F0F0F0", "", "#\u{FF23}\u{FF23}\u{FF23}", "#١٢٣"] {
            let r = PaletteCard.color(fromHex: s)
            print("PROBE | hex(\(s.debugDescription)) = \(r.map { "(\($0.r),\($0.g),\($0.b))" } ?? "nil")")
        }
    }

    func test_probe_parse() {
        func p(_ md: String, dir: String = "research/palette") -> PaletteCard {
            PaletteCardParser.parse(markdown: md, itemId: "id", fallbackTitle: "FB", cardDirectory: dir)
        }
        func dump(_ label: String, _ c: PaletteCard) {
            print("PROBE | \(label) title=\(c.title.debugDescription) kind=\(c.kind) "
                  + "sw=\(c.swatches) notes=\(c.notes.map { "\(String(describing: $0.sense)):\($0.text.debugDescription)" }) "
                  + "img=\(c.imagePaths) body=\(c.body.debugDescription)")
        }

        dump("empty-string", p(""))
        dump("whitespace-only", p("   \n\t\n"))
        dump("title-blank", p("# \n"))
        dump("title-whitespace", p("#    \n"))
        dump("second-title-ignored", p("# One\n\n# Two\n"))
        dump("hash-without-space", p("#NoSpace\n"))
        dump("h3-heading", p("### Deep\n\nkind: motif\n"))
        dump("section-without-space", p("kind: motif\n##Swatches\n- #fff\n"))
        dump("section-indented", p("kind: motif\n\nprose\n\n  ## Swatches\n\n  - #fff\n"))
        dump("section-uppercase", p("kind: motif\n\n## SWATCHES\n\n- #fff\n"))
        dump("section-extra-spaces", p("kind: motif\n\n##   Swatches   \n\n- #fff\n"))
        dump("duplicate-sections", p("kind: motif\n\n## Swatches\n\n- #fff\n\n## Swatches\n\n- #000\n"))
        dump("sections-out-of-order", p("kind: motif\n\n## Images\n\n- a.png\n\n## Swatches\n\n- #fff\n"))
        dump("kind-no-space", p("kind:location\n"))
        dump("kind-uppercase-key", p("KIND: location\n"))
        dump("kind-empty-then-later", p("kind: \n\nkind: location\n"))
        dump("kind-after-section", p("## Swatches\n\nkind: location\n"))
        dump("pre-kind-prose-then-blank", p("# T\n\nprose\n\nkind: location\n"))
        dump("pre-kind-whitespace-line", p("# T\n\n   \nkind: location\n"))
        dump("crlf", p("# T\r\n\r\nkind: location\r\n\r\n## Swatches\r\n\r\n- #fff\r\n"))
        dump("swatch-duplicates", p("kind: motif\n\n## Swatches\n\n- #fff\n- #fff\n- #FFF\n"))
        dump("swatch-3digit-kept-verbatim", p("kind: motif\n\n## Swatches\n\n- #abc\n"))
        dump("image-dash-duplicates", p("kind: motif\n\n## Images\n\n- a.png\n- a.png\n"))
        dump("image-dash-then-same-inline", p("kind: motif\n\n## Images\n\n- a.png\n\ntext ![x](a.png)\n"))
        dump("image-absolute", p("kind: motif\n\n## Images\n\n- /abs/x.png\n"))
        dump("image-remote-dash", p("kind: motif\n\n## Images\n\n- https://e.com/x.png\n"))
        dump("image-climb-past-root", p("kind: motif\n\n## Images\n\n- ../../../../x.png\n"))
        dump("image-dot-segments", p("kind: motif\n\n## Images\n\n- ./a/./b/../c.png\n"))
        dump("image-empty-cardDir", p("kind: motif\n\n## Images\n\n- a.png\n", dir: ""))
        dump("note-colon-unknown-prefix", p("kind: motif\n\n## Senses\n\n- foo: bar\n"))
        dump("note-leading-colon", p("kind: motif\n\n## Senses\n\n- : x\n"))
        dump("note-spaced-sense", p("kind: motif\n\n## Senses\n\n-  smell : x\n"))
        dump("note-bare-dash", p("kind: motif\n\n## Senses\n\n-\n- \n"))
        dump("unknown-section-before-structure", p("kind: motif\n\n## Weird\n\nprose here\n"))
        dump("unknown-section-after-structure", p("kind: motif\n\n## Swatches\n\n- #fff\n\n## Weird\n\n- dropped\n"))
        dump("body-with-h3", p("kind: motif\n\n### Deep\n\nmore\n\n## Swatches\n"))
        dump("no-kind-body-starts-immediately", p("# T\n\nbody line\n\n## Swatches\n"))
    }

    func test_probe_render_and_relativize() {
        func r(_ c: PaletteCard, _ dir: String = "research/palette") -> String {
            PaletteCardRenderer.render(c, cardDirectory: dir)
        }
        let bare = PaletteCard(researchItemId: "i", title: "T", kind: .other,
                               swatches: [], notes: [], imagePaths: [], body: "")
        print("PROBE | render/bare = \(r(bare).debugDescription)")

        let junkSwatch = PaletteCard(researchItemId: "i", title: "T", kind: .other,
                                     swatches: ["not-a-hex"], notes: [], imagePaths: [], body: "")
        let junkMd = r(junkSwatch)
        print("PROBE | render/invalid-swatch = \(junkMd.debugDescription)")
        print("PROBE | render/invalid-swatch/reparsed-swatches = "
              + "\(PaletteCardParser.parse(markdown: junkMd, itemId: "i", fallbackTitle: "F", cardDirectory: "research/palette").swatches)")

        let newlineTitle = PaletteCard(researchItemId: "i", title: "A\nB", kind: .other,
                                       swatches: [], notes: [], imagePaths: [], body: "")
        let ntMd = r(newlineTitle)
        print("PROBE | render/newline-title/reparsed-title = "
              + "\(PaletteCardParser.parse(markdown: ntMd, itemId: "i", fallbackTitle: "F", cardDirectory: "research/palette").title.debugDescription)")

        let newlineNote = PaletteCard(researchItemId: "i", title: "T", kind: .other, swatches: [],
                                      notes: [.init(sense: nil, text: "A\nB")], imagePaths: [], body: "")
        let nnMd = r(newlineNote)
        print("PROBE | render/newline-note/reparsed-notes = "
              + "\(PaletteCardParser.parse(markdown: nnMd, itemId: "i", fallbackTitle: "F", cardDirectory: "research/palette").notes.map(\.text))")

        let wsBody = PaletteCard(researchItemId: "i", title: "T", kind: .other, swatches: [],
                                 notes: [], imagePaths: [], body: "   ")
        print("PROBE | render/whitespace-body/reparsed-body = "
              + "\(PaletteCardParser.parse(markdown: r(wsBody), itemId: "i", fallbackTitle: "F", cardDirectory: "research/palette").body.debugDescription)")

        let remoteImg = PaletteCard(researchItemId: "i", title: "T", kind: .other, swatches: [],
                                    notes: [], imagePaths: ["https://e.com/x.png"], body: "")
        let riMd = r(remoteImg)
        print("PROBE | render/remote-image = \(riMd.debugDescription)")
        print("PROBE | render/remote-image/reparsed = "
              + "\(PaletteCardParser.parse(markdown: riMd, itemId: "i", fallbackTitle: "F", cardDirectory: "research/palette").imagePaths)")

        let dupNotes = PaletteCard(researchItemId: "i", title: "T", kind: .other, swatches: [],
                                   notes: [.init(sense: .smell, text: "x"), .init(sense: .smell, text: "x")],
                                   imagePaths: [], body: "")
        print("PROBE | render/duplicate-notes/reparsed-count = "
              + "\(PaletteCardParser.parse(markdown: r(dupNotes), itemId: "i", fallbackTitle: "F", cardDirectory: "research/palette").notes.count)")

        let dupImgs = PaletteCard(researchItemId: "i", title: "T", kind: .other, swatches: [], notes: [],
                                  imagePaths: ["research/palette/a.png", "research/palette/a.png"], body: "")
        print("PROBE | render/duplicate-images/reparsed = "
              + "\(PaletteCardParser.parse(markdown: r(dupImgs), itemId: "i", fallbackTitle: "F", cardDirectory: "research/palette").imagePaths)")

        let bodyImages = PaletteCard(researchItemId: "i", title: "T", kind: .other, swatches: [], notes: [],
                                     imagePaths: [], body: "## Images\n\n- ./sneaky.png")
        let biMd = r(bodyImages)
        let bi1 = PaletteCardParser.parse(markdown: biMd, itemId: "i", fallbackTitle: "F", cardDirectory: "research/palette")
        let bi2 = PaletteCardParser.parse(markdown: r(bi1), itemId: "i", fallbackTitle: "F", cardDirectory: "research/palette")
        print("PROBE | render/body-spelling-a-known-section/pass1 = body=\(bi1.body.debugDescription) img=\(bi1.imagePaths)")
        print("PROBE | render/body-spelling-a-known-section/pass2 = body=\(bi2.body.debugDescription) img=\(bi2.imagePaths)")
        print("PROBE | render/body-spelling-a-known-section/converged = \(bi1 == bi2)")

        for (path, dir) in [("research/palette/a.png", "research/palette"),
                            ("research/palette", "research/palette"),
                            ("a.png", ""),
                            ("", "research/palette"),
                            ("x/y/z.png", "x"),
                            ("x.png", "a/b/c"),
                            ("research/paletteX/a.png", "research/palette"),
                            ("https://e.com/x.png", "research/palette")] {
            print("PROBE | relativize(\(path.debugDescription), from: \(dir.debugDescription)) = "
                  + PaletteCardRenderer.relativize(path, from: dir).debugDescription)
        }

        print("PROBE | template = \(PaletteCardParser.template(title: "T", kind: .motif).debugDescription)")
        print("PROBE | Sense.allCases = \(PaletteCard.Sense.allCases.map(\.rawValue))")
        print("PROBE | Kind.allCases = \(PaletteCard.Kind.allCases.map(\.rawValue))")
    }
}
