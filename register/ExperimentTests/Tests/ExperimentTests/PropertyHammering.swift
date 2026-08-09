import XCTest
import MaughamCore

/// PHASE 4 — property hammering.
///
/// Fifteen claims spanning every warrant level, each re-expressed as a property
/// over randomised input from a seeded generator. A property that SHATTERS is not
/// a broken test: the counterexample is the finding, and the test asserts the
/// counterexample so the result stays green and re-runnable. Every such case is
/// labelled `// SHATTERED` and carried to the ruling sheet.
///
/// Run:  swift test --package-path register/ExperimentTests --filter PropertyHammering
final class PropertyHammering: XCTestCase {

    // =====================================================================
    // MARK: - M1 PaletteCard
    // =====================================================================

    /// P01 — claim M1-T-032 / M1-A-01 (warrant HIGH).
    /// parse(render(card)) == card for every EDITOR-REACHABLE model.
    func test_P01_roundTripHoldsForEveryEditorReachableCard() {
        let r = Property.check("P01 round-trip / editor-reachable", count: 20_000,
            generate: { rng -> PaletteCard? in
                let c = CardGen.card(&rng)
                return CardGen.isEditorReachable(c) ? c : nil
            },
            shrink: CardGen.shrink,
            body: { card in
                let out = CardGen.roundTrip(card)
                return out == card ? nil : "got \(out)"
            })
        XCTAssertTrue(r.held, r.counterexample ?? "")
        XCTAssertGreaterThanOrEqual(r.casesRun, 20_000)
    }

    /// P02 — claim M1-C-047 / M1-A-02 (warrant LOW).
    /// The card format CONVERGES: whatever you throw at it, one render→parse pass
    /// reaches a fixed point that a second pass preserves. Run over deliberately
    /// pathological models the parser could never itself produce.
    func test_P02_renderParseReachesAFixedPointAfterOnePass() {
        let r = Property.check("P02 convergence / arbitrary models", count: 20_000,
            generate: { rng -> PaletteCard? in CardGen.card(&rng, pathological: true) },
            shrink: CardGen.shrink,
            body: { card in
                let once = CardGen.roundTrip(card)
                let twice = CardGen.roundTrip(once)
                return once == twice ? nil : "pass1 \(once)\n         pass2 \(twice)"
            })
        XCTAssertTrue(r.held, r.counterexample ?? "")
    }

    /// P03 — claim M1-C-003 (warrant LOW), on which intent clause M1-A-11 depends.
    /// color(fromHex:) accepts EXACTLY the language `#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})`.
    /// SHATTERED — see the pinned counterexample.
    func test_P03_hexValidatorLanguage_SHATTERED() {
        func inTheStatedLanguage(_ s: String) -> Bool {
            guard s.hasPrefix("#") else { return false }
            let body = s.dropFirst()
            guard body.count == 3 || body.count == 6 else { return false }
            return body.allSatisfy(\.isHexDigit)
        }
        let r = Property.check("P03 hex validator language", count: 50_000,
            generate: { rng -> String? in Gen.hexCandidate(&rng) },
            shrink: { s in s.isEmpty ? [] : (0..<s.count).map { i in
                var t = s; t.remove(at: t.index(t.startIndex, offsetBy: i)); return t } },
            body: { s in
                let accepted = PaletteCard.color(fromHex: s) != nil
                return accepted == inTheStatedLanguage(s) ? nil
                     : "accepted=\(accepted) stated=\(inTheStatedLanguage(s))"
            })
        // SHATTERED. The validator accepts strings outside its stated language.
        XCTAssertFalse(r.held, "P03 was expected to shatter; if it now holds, the hole was fixed")
        XCTAssertNotNil(PaletteCard.color(fromHex: "#+FFFFF"),
                        "the shattering shape: a leading '+' counts as one of the six characters")
        XCTAssertFalse(inTheStatedLanguage("#+FFFFF"))
    }

    /// P04 — claim M1-T-039 / M1-A-07 (warrant HIGH).
    /// No body content can corrupt `kind`, however `kind:`-shaped it is.
    /// Deliberately NOT filtered to editor-reachable models: kind-safety is claimed
    /// unconditionally, and filtering would have thrown away the `kind:`-shaped
    /// body lines that are the whole point of the property.
    func test_P04_bodyContentCanNeverCorruptKind() {
        let r = Property.check("P04 kind is uncorruptible by body", count: 20_000,
            generate: { rng -> PaletteCard? in CardGen.card(&rng, pathological: true) },
            shrink: CardGen.shrink,
            body: { card in
                let out = CardGen.roundTrip(card)
                return out.kind == card.kind ? nil : "kind became .\(out.kind.rawValue)"
            })
        XCTAssertTrue(r.held, r.counterexample ?? "")
    }

    /// P05 — claims M1-T-022…M1-T-026 / M1-A-04 (warrant HIGH).
    /// Body bytes survive a round trip exactly, for every body an editor can hold.
    func test_P05_bodyBytesSurviveByteForByte() {
        let r = Property.check("P05 body byte preservation", count: 20_000,
            generate: { rng -> PaletteCard? in
                let c = CardGen.card(&rng)
                return CardGen.isEditorReachable(c) ? c : nil
            },
            shrink: CardGen.shrink,
            body: { card in
                let out = CardGen.roundTrip(card)
                return out.body == card.body ? nil
                     : "body \(card.body.debugDescription) -> \(out.body.debugDescription)"
            })
        XCTAssertTrue(r.held, r.counterexample ?? "")
    }

    /// P06 — claim M1-T-004 / M1-A-11 (warrant HIGH).
    /// Parsing a Swatches section retains exactly the valid items, in order.
    func test_P06_swatchRetentionIsExactlyTheValidSubsequence() {
        let r = Property.check("P06 swatch retention", count: 20_000,
            generate: { rng -> [String]? in
                (0..<rng.int(0...8)).map { _ in
                    rng.bool(0.6) ? Gen.swatch(&rng) : Gen.hexCandidate(&rng)
                }
            },
            shrink: { items in items.isEmpty ? [] : items.indices.map { i in
                var t = items; t.remove(at: i); return t } },
            body: { items in
                let md = "kind: motif\n\n## Swatches\n\n" + items.map { "- \($0)\n" }.joined()
                let got = PaletteCardParser.parse(markdown: md, itemId: "i", fallbackTitle: "F",
                                                  cardDirectory: CardGen.dir).swatches
                // The item text as the parser sees it: trimmed after "- ".
                let expected = items
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { PaletteCard.color(fromHex: $0) != nil }
                return got == expected ? nil : "got \(got) expected \(expected)"
            })
        XCTAssertTrue(r.held, r.counterexample ?? "")
    }

    /// P07 — claim M1-A-14 (warrant HIGH).
    /// relativize is the exact inverse of the parser's resolve, for project-relative paths.
    func test_P07_relativizeAndResolveAreInverses() {
        let r = Property.check("P07 path relativize/resolve inverse", count: 20_000,
            generate: { rng -> (String, String)? in
                (Gen.projectRelativePath(&rng),
                 (0..<rng.int(0...3)).map { _ in Gen.pathComponent(&rng) }.joined(separator: "/"))
            },
            body: { (path, dir) in
                let card = PaletteCard(researchItemId: "i", title: "T", kind: .other, swatches: [],
                                       notes: [], imagePaths: [path], body: "")
                let out = CardGen.roundTrip(card, dir: dir)
                return out.imagePaths == [path] ? nil
                     : "dir=\(dir.debugDescription) path=\(path.debugDescription) -> \(out.imagePaths)"
            })
        XCTAssertTrue(r.held, r.counterexample ?? "")
    }

    /// P08 — claims M1-T-041, M1-T-042 / M1-A-09 (warrant HIGH).
    /// The renderer never emits a bare `- ` bullet, for any note list at all.
    func test_P08_renderNeverEmitsABareBullet() {
        let r = Property.check("P08 no bare bullet", count: 20_000,
            generate: { rng -> [PaletteCard.SensoryNote]? in
                (0..<rng.int(0...6)).map { _ in
                    let tagged = rng.bool(0.5)
                    let text = rng.pick(["", " ", "   ", "\t", "real text", "a: b", "smell: x"])
                    return .init(sense: tagged ? PaletteCard.Sense(rawValue: rng.pick(Gen.senseTokens))! : nil,
                                 text: text)
                }
            },
            shrink: { ns in ns.isEmpty ? [] : ns.indices.map { i in
                var t = ns; t.remove(at: i); return t } },
            body: { notes in
                let card = PaletteCard(researchItemId: "i", title: "T", kind: .other, swatches: [],
                                       notes: notes, imagePaths: [], body: "")
                let md = PaletteCardRenderer.render(card, cardDirectory: CardGen.dir)
                for line in md.split(separator: "\n", omittingEmptySubsequences: false) {
                    if line == "- " || line == "-" { return "emitted \(line.debugDescription)" }
                }
                return nil
            })
        XCTAssertTrue(r.held, r.counterexample ?? "")
    }

    /// P09 — claim M1-C-024 (warrant LOW). LINE-ENDING AGNOSTICISM: parsing a
    /// document is unaffected by whether its lines end LF or CRLF.
    ///
    /// NOTE ON A CORRECTED OPERATIONALISATION. My first version of P09 asked
    /// whether a MODEL whose body contains a CR round-trips. It HELD over 20,000
    /// cases — because the renderer always emits LF, so a lone CR is just a body
    /// byte and body bytes are preserved (P05). The claim is about a document
    /// arriving from OUTSIDE with CRLF endings, which is a parse-side property and
    /// the round trip can never reach. The first framing is recorded in
    /// 04-property-results.md as a miss; this is the property that tests the claim.
    /// SHATTERED — Swift's `\r\n` grapheme cluster defeats `split(separator: "\n")`.
    func test_P09_lineEndingAgnosticism_SHATTERED() {
        let r = Property.check("P09 CRLF vs LF parse agreement", count: 20_000,
            generate: { rng -> String? in
                var lines = ["# " + Gen.sentence(&rng), "", "kind: " + rng.pick(["location", "motif"]), ""]
                if rng.bool() { lines += [Gen.sentence(&rng), ""] }
                lines += ["## Swatches", "", "- " + Gen.swatch(&rng), ""]
                lines += ["## Senses", "", "- smell: " + Gen.sentence(&rng), ""]
                lines += ["## Images", "", "- " + Gen.projectRelativePath(&rng)]
                return lines.joined(separator: "\n")
            },
            shrink: { lf in
                let lines = lf.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                return lines.count <= 1 ? [] : lines.indices.map { i in
                    var l = lines; l.remove(at: i); return l.joined(separator: "\n")
                }
            },
            body: { lf in
                let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
                let a = PaletteCardParser.parse(markdown: lf, itemId: "i", fallbackTitle: "F",
                                                cardDirectory: CardGen.dir)
                let b = PaletteCardParser.parse(markdown: crlf, itemId: "i", fallbackTitle: "F",
                                                cardDirectory: CardGen.dir)
                if a == b { return nil }
                if a.title != b.title { return "title: \(a.title.debugDescription) vs \(b.title.debugDescription)" }
                if a.kind != b.kind { return "kind: .\(a.kind.rawValue) vs .\(b.kind.rawValue)" }
                if a.swatches != b.swatches { return "swatches: \(a.swatches) vs \(b.swatches)" }
                if a.notes != b.notes { return "notes: \(a.notes.count) vs \(b.notes.count)" }
                if a.imagePaths != b.imagePaths { return "images: \(a.imagePaths) vs \(b.imagePaths)" }
                return "body: \(a.body.debugDescription) vs \(b.body.debugDescription)"
            })
        XCTAssertFalse(r.held, "P09 was expected to shatter; if it now holds, CRLF was fixed")

        // The minimal shape, pinned: a two-line document is one line under CRLF.
        XCTAssertEqual("a\r\nb".split(separator: "\n", omittingEmptySubsequences: false).count, 1,
                       "the root cause: \\r\\n is ONE Character, so the split does not fire")
        let lf = "# T\nkind: location"
        XCTAssertEqual(PaletteCardParser.parse(markdown: lf, itemId: "i", fallbackTitle: "F",
                                               cardDirectory: CardGen.dir).kind, .location)
        XCTAssertEqual(PaletteCardParser.parse(markdown: "# T\r\nkind: location", itemId: "i",
                                               fallbackTitle: "F", cardDirectory: CardGen.dir).kind,
                       .other, "the same document with CRLF endings loses its kind")
    }

    // =====================================================================
    // MARK: - M2 TreeWalk
    // =====================================================================

    /// P10 — claim M2-C-018 / M2-A-18 (warrant LOW), the property 36 call sites rest on.
    /// collect(where: p) == collect(where: true).filter(p) — a failing parent never
    /// prunes its matching descendants.
    func test_P10_collectNeverPrunesBelowAFailingParent() {
        let r = Property.check("P10 collect does not prune", count: 20_000,
            generate: { rng -> ([XNode], Int)? in (TreeGen.forest(&rng), rng.int(0...9)) },
            body: { (forest, modulus) in
                let p: (XNode) -> Bool = { node in
                    abs(node.id.hashValue % 10) >= modulus
                }
                let filtered = TreeWalk.collect(in: forest, where: p).map(\.id)
                let flatThenFilter = TreeWalk.collect(in: forest) { _ in true }.filter(p).map(\.id)
                return filtered == flatThenFilter ? nil
                     : "\(filtered) != \(flatThenFilter)"
            })
        XCTAssertTrue(r.held, r.counterexample ?? "")
    }

    /// P11 — claims M2-T-005, M2-T-014 / M2-A-03 (warrant HIGH).
    /// collectIds agrees with an INDEPENDENT explicit-stack pre-order oracle, and
    /// with collect(where: true), and leaves agrees with a filter of that flattening.
    func test_P11_preOrderAgreesWithAnIndependentOracle() {
        let r = Property.check("P11 pre-order vs oracle", count: 20_000,
            generate: { rng -> [XNode]? in TreeGen.forest(&rng, allowDuplicateIds: true) },
            body: { forest in
                let oracle = TreeGen.referencePreOrder(forest).map(\.id)
                if TreeWalk.collectIds(in: forest) != oracle { return "collectIds != oracle" }
                if TreeWalk.collect(in: forest, where: { _ in true }).map(\.id) != oracle {
                    return "collect(true) != oracle"
                }
                let expectedLeaves = TreeGen.referencePreOrder(forest)
                    .filter { ($0.children ?? []).isEmpty }.map(\.id)
                if TreeWalk.leaves(in: forest).map(\.id) != expectedLeaves { return "leaves != oracle" }
                return nil
            })
        XCTAssertTrue(r.held, r.counterexample ?? "")
    }

    /// P12 — claim M2-T-018 / M2-A-11 (warrant MEDIUM — asserted only in a test NAME).
    /// mutate and remove leave the input forest untouched.
    func test_P12_mutateAndRemoveNeverDisturbTheInput() {
        let r = Property.check("P12 persistence of the input", count: 20_000,
            generate: { rng -> ([XNode], String)? in
                let f = TreeGen.forest(&rng, allowDuplicateIds: true)
                let ids = TreeWalk.collectIds(in: f)
                return (f, ids.isEmpty ? "absent" : rng.pick(ids))
            },
            body: { (forest, id) in
                let before = forest
                _ = TreeWalk.mutate(id: id, in: forest) { n in XNode("CLOBBERED", n.children) }
                _ = TreeWalk.remove(id: id, in: forest)
                return forest == before ? nil : "input forest changed"
            })
        XCTAssertTrue(r.held, r.counterexample ?? "")
    }

    /// P13 — claim M2-A-06 (warrant HIGH), tested against the SEMANTIC rule rather
    /// than a transcription of the implementation: "a path denoting the prefixed
    /// node itself, or anything beneath it in the path hierarchy, is rewritten."
    /// SHATTERED — a trailing separator on oldPrefix silently rewrites nothing.
    func test_P13_rewritePathsAgainstTheSemanticRule_SHATTERED() {
        /// Normalise a directory-ish path the way a caller would mean it.
        func denotesSelfOrDescendant(_ p: String, _ prefix: String) -> Bool {
            let norm = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            return p == norm || p.hasPrefix(norm + "/")
        }
        let r = Property.check("P13 rewritePaths vs semantic rule", count: 20_000,
            generate: { rng -> ([XPathNode], String, String)? in
                let f = TreeGen.pathForest(&rng)
                var old = Gen.pathComponent(&rng)
                if rng.bool(0.3) { old += "/" + Gen.pathComponent(&rng) }
                if rng.bool(0.25) { old += "/" }        // the shattering shape
                return (f, old, "NEW/" + Gen.pathComponent(&rng))
            },
            shrink: { (forest, old, new) in
                var out: [([XPathNode], String, String)] = []
                // Drop whole root subtrees, then flatten a root to its bare self.
                for i in forest.indices {
                    var f = forest; f.remove(at: i); out.append((f, old, new))
                }
                for i in forest.indices where forest[i].children != nil {
                    var f = forest; f[i].children = nil; out.append((f, old, new))
                }
                if new != "NEW" { out.append((forest, old, "NEW")) }
                return out
            },
            body: { (forest, old, new) in
                let out = TreeWalk.rewritePaths(in: forest, replacingPrefix: old, with: new,
                                                path: XPathNode.readPath, setPath: XPathNode.writePath)
                let before = TreeWalk.collect(in: forest) { _ in true }
                let after = TreeWalk.collect(in: out) { _ in true }
                for (b, a) in zip(before, after) {
                    guard let bp = b.path else { continue }
                    let shouldRewrite = denotesSelfOrDescendant(bp, old)
                    let didRewrite = a.path != bp
                    if shouldRewrite != didRewrite {
                        return "prefix=\(old.debugDescription) path=\(bp.debugDescription) "
                             + "should=\(shouldRewrite) did=\(didRewrite)"
                    }
                }
                return nil
            })
        XCTAssertFalse(r.held, "P13 was expected to shatter; if it now holds, the trailing-separator hole was closed")

        // The minimal shape, pinned.
        let tree = [XPathNode("a", path: "p/q")]
        XCTAssertEqual(TreeWalk.rewritePaths(in: tree, replacingPrefix: "p/", with: "NEW",
                                             path: XPathNode.readPath,
                                             setPath: XPathNode.writePath).first?.path,
                       "p/q", "a trailing separator rewrites nothing, silently")
    }

    /// P14 — clause M2-A-16 ("node ids MUST be unique within a forest"), warrant LOW.
    /// The clause is tested by ASSUMING IT FALSE: over forests that deliberately
    /// contain duplicate ids, do the walkers still satisfy their own contracts?
    /// If they do, the uniqueness clause is not something TreeWalk requires — which
    /// is the interesting result, because the clause was my Arm A inference.
    func test_P14_theWalkersAreAgnosticToIdUniqueness() {
        let r = Property.check("P14 duplicate-id agnosticism", count: 20_000,
            generate: { rng -> ([XNode], String)? in
                let f = TreeGen.forest(&rng, allowDuplicateIds: true)
                let ids = TreeWalk.collectIds(in: f)
                guard !ids.isEmpty else { return nil }
                return (f, rng.pick(ids))
            },
            body: { (forest, id) in
                // (a) remove really removes every occurrence
                let removed = TreeWalk.remove(id: id, in: forest)
                if TreeWalk.contains(id: id, in: removed) { return "remove left an occurrence" }
                // (b) find agrees with contains
                if TreeWalk.contains(id: id, in: forest) != (TreeWalk.find(id: id, in: forest) != nil) {
                    return "find/contains disagree"
                }
                // (c) find returns the FIRST pre-order occurrence
                let firstOccurrence = TreeGen.referencePreOrder(forest).first { $0.id == id }
                if TreeWalk.find(id: id, in: forest) != firstOccurrence { return "find != first pre-order" }
                // (d) mutate rewrites every occurrence
                let renamed = TreeWalk.mutate(id: id, in: forest) { n in XNode("ZZZ", n.children) }
                if TreeWalk.contains(id: id, in: renamed) { return "mutate left an occurrence" }
                return nil
            })
        XCTAssertTrue(r.held, (r.counterexample ?? "")
            + " — every walker contract holds WITHOUT id uniqueness, so clause M2-A-16 is not a "
            + "requirement of TreeWalk")
    }

    /// P15 — claims M2-C-020, M2-T-012 / M2-A-03 (warrant LOW/HIGH).
    /// first(where:) is exactly collect(where:).first — one traversal order, two
    /// functions, no divergence.
    func test_P15_firstAgreesWithCollectFirst() {
        let r = Property.check("P15 first == collect.first", count: 20_000,
            generate: { rng -> ([XNode], Int)? in (TreeGen.forest(&rng, allowDuplicateIds: true), rng.int(0...9)) },
            body: { (forest, modulus) in
                let p: (XNode) -> Bool = { abs($0.id.hashValue % 10) >= modulus }
                let a = TreeWalk.first(in: forest, where: p)
                let b = TreeWalk.collect(in: forest, where: p).first
                return a == b ? nil : "first=\(String(describing: a?.id)) collect.first=\(String(describing: b?.id))"
            })
        XCTAssertTrue(r.held, r.counterexample ?? "")
    }
}
