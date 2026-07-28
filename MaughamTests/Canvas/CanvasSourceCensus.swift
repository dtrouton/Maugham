import XCTest

/// Reading this repo's own source from a test — **one copy, shared by every
/// canvas suite that counts call sites.**
///
/// It lives here because it was two copies and a third was already scheduled.
/// `RegionBindingTests` and `LineInspectorTests` carried character-identical
/// `repoRoot`, `productionFiles()` and `commentsStripped(_:)`, down to the
/// `> 100` guard's message, and 1C-c1's Task 7 is chartered to count
/// `CanvasScene.lines(touching:)`'s callers — which is where the third would
/// have landed. (That count came back zero for the third time and the accessor
/// was deleted; the shared reading of the corpus is what was worth keeping.)
///
/// **A census is the one kind of test that fails quietly in BOTH directions**,
/// which is why the duplication mattered more here than it would elsewhere. A
/// bug in `commentsStripped` that under-strips inflates every census (a symbol
/// discussed in a doc comment is counted as a caller, and this area's files
/// discuss each other at length — that is the point of them); one that
/// over-strips empties them, and an empty census is green. Either way the fix
/// had to be found once and then applied twice, by someone who knew there were
/// two.
///
/// **Why these three and not the filter above them.** Each census asks a
/// different question of the same corpus, with a different exclusion list, and
/// collapsing that into one `callers(of:excluding:)` would put the interesting
/// half — *which* file is allowed to define the thing it names — behind a
/// parameter. What is shared is the corpus and the reading of it, and that is
/// what is here.
///
/// **Not an `XCTestCase` extension**, for the same reason `CanvasPage` is not:
/// none of this needs a test instance, and a caseless enum says at every call
/// site which copy is being used.
enum CanvasSourceCensus {

    /// The repository root, resolved from this file's own path.
    ///
    /// Three levels up: `MaughamTests/Canvas/` → `MaughamTests/` → the repo. Any
    /// suite reaching for this must therefore live beside this file; one that
    /// does not needs its own resolution rather than a fourth
    /// `deletingLastPathComponent()` bolted on here.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Canvas
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo
    }

    /// One production file by its path from the repo root, for the scans that
    /// read a single known file rather than walking the tree.
    static func source(at relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every production `.swift` under `Maugham/`. Comments are the caller's
    /// problem — a doc comment naming a call is not a call, and
    /// `commentsStripped` below is what says so.
    ///
    /// The `> 100` guard is not decoration: a caller census over an empty walk
    /// passes for the wrong reason, and a walk that finds nothing is exactly
    /// what a moved directory or a changed `#filePath` depth produces. It
    /// forwards `file`/`line` so that failure is reported against the suite that
    /// asked, not against this file.
    static func productionFiles(file: StaticString = #filePath,
                                line: UInt = #line) throws -> [(name: String, source: String)] {
        let app = repoRoot.appendingPathComponent("Maugham")
        let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 100,
                             "the walk found almost nothing — a caller census over "
                             + "an empty tree passes for the wrong reason",
                             file: file, line: line)
        return out
    }

    /// Line and block comments removed, so a doc comment naming a symbol is not
    /// read as using it. The canvas's files discuss each other's verbs at length
    /// in prose — `RegionInspector` and `LineInspector` both spend a paragraph on
    /// the verb they must *not* call — which is the whole point of them and the
    /// whole reason this exists.
    ///
    /// Deliberately naive about `//` inside a string literal: no file censused
    /// through here has one, and a stricter parser would be more code than the
    /// thing it is guarding. **If that stops being true, this is where it is
    /// fixed — once.**
    static func commentsStripped(_ source: String) -> String {
        var out = ""
        var inBlock = false
        for line in source.components(separatedBy: "\n") {
            var line = Substring(line)
            if inBlock {
                guard let end = line.range(of: "*/") else { continue }
                line = line[end.upperBound...]
                inBlock = false
            }
            while let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                    line = line[..<start.lowerBound] + line[end.upperBound...]
                } else {
                    line = line[..<start.lowerBound]
                    inBlock = true
                }
            }
            if let slashes = line.range(of: "//") { line = line[..<slashes.lowerBound] }
            out += line + "\n"
        }
        return out
    }
}
