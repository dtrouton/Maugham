import Foundation

/// **Finds production source by the TYPE or SYMBOL it declares, never by the
/// file it happens to live in today.**
///
/// A census that reads `Maugham/Views/ProjectWindow.swift` by name goes quietly
/// blind the day that file is split: the code it guarded moves to
/// `ProjectWindow+Routes.swift`, the read still succeeds, and the token the
/// census wanted is simply not there any more — or, worse, a ban passes because
/// the offender now lives somewhere it does not look. Every lookup here THROWS
/// on zero matches (and `declaration(named:under:)` on more than one), so a
/// move turns a census red rather than off.
///
/// Comments and string literals are masked before anything is matched (see
/// `SourceTree.mask`), so a header quoted in a doc comment never counts as the
/// declaration, and a `}` in a string never closes a body early.
///
/// Every lookup has an internal overload taking a `base` URL, which is the
/// seam `SourceTreeTests` plants fixtures through; the public spellings pass
/// `repoRoot`.
enum SourceTree {

    struct LookupError: Error, CustomStringConvertible {
        let description: String
    }

    /// The repo root, from this file's #filePath (MaughamTests/TestSupport/ → two up).
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TestSupport/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
    }

    /// Every production Swift root, repo-relative: "Maugham", "MaughamPhone",
    /// and each "Packages/<pkg>/Sources/<target>" that exists on disk.
    static var productionRoots: [String] {
        let fm = FileManager.default
        var roots = ["Maugham", "MaughamPhone"]
        let packages = repoRoot.appendingPathComponent("Packages", isDirectory: true)
        let pkgNames = ((try? fm.contentsOfDirectory(atPath: packages.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        for pkg in pkgNames {
            let sources = packages.appendingPathComponent(pkg).appendingPathComponent("Sources")
            let targets = ((try? fm.contentsOfDirectory(atPath: sources.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted()
            for target in targets where isDirectory(sources.appendingPathComponent(target)) {
                roots.append("Packages/\(pkg)/Sources/\(target)")
            }
        }
        return roots
    }

    // MARK: - Public lookups (against the real repo)

    /// The file at a repo-relative path. Throws LookupError naming the path if absent.
    static func read(_ repoRelative: String) throws -> String {
        try read(repoRelative, base: repoRoot)
    }

    /// Repo-relative paths of every .swift file under `root` (a repo-relative dir).
    static func swiftFiles(under root: String) throws -> [String] {
        try swiftFiles(under: root, base: repoRoot)
    }

    /// Repo-relative paths of the files under `roots` that DECLARE `typeName`:
    /// a line whose code (after attributes and access/final/@MainActor modifiers)
    /// begins `class|struct|enum|actor|protocol|extension <typeName>` followed by
    /// a non-identifier character. Throws if none.
    static func filesDeclaring(_ typeName: String, under roots: [String]) throws -> [String] {
        try filesDeclaring(typeName, under: roots, base: repoRoot)
    }

    /// The concatenated text of every file declaring `typeName`.
    static func sourceOfType(_ typeName: String, under roots: [String]) throws -> String {
        try sourceOfType(typeName, under: roots, base: repoRoot)
    }

    /// The brace-matched body (header through closing brace) of the ONE declaration
    /// whose line contains `header` (e.g. "private func manuscriptEditor(",
    /// "static func reviewCentreShowsBoard("), searched across every .swift file
    /// under `root`. Throws if zero matches or more than one.
    static func declaration(named header: String, under root: String) throws -> String {
        try declaration(named: header, under: root, base: repoRoot)
    }

    // MARK: - Seam overloads (against any base)

    static func read(_ relative: String, base: URL) throws -> String {
        let url = base.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw LookupError(description:
                "SourceTree: no readable file at '\(relative)' (under \(base.path)).")
        }
        return text
    }

    static func swiftFiles(under root: String, base: URL) throws -> [String] {
        let dir = base.appendingPathComponent(root, isDirectory: true)
        guard isDirectory(dir),
              let walk = FileManager.default.enumerator(atPath: dir.path) else {
            throw LookupError(description:
                "SourceTree: root '\(root)' is not a directory (under \(base.path)).")
        }
        var files: [String] = []
        while let next = walk.nextObject() as? String {
            let name = (next as NSString).lastPathComponent
            if name.hasPrefix(".") {
                walk.skipDescendants()
                continue
            }
            if name.hasSuffix(".swift") { files.append("\(root)/\(next)") }
        }
        return files.sorted()
    }

    static func filesDeclaring(_ typeName: String, under roots: [String], base: URL) throws -> [String] {
        let pattern = #"^\s*(?:@\w+(?:\([^)]*\))?\s*)*"#
            + #"(?:(?:public|private|fileprivate|internal|package|open|final|indirect|nonisolated|distributed)\s+)*"#
            + #"(?:class|struct|enum|actor|protocol|extension)\s+"#
            + NSRegularExpression.escapedPattern(for: typeName)
            + #"(?![A-Za-z0-9_])"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        // The keyword and the name, anywhere: masking only blanks characters, so a
        // file whose RAW text lacks this cannot declare the type. Checking it first
        // spares masking every file that merely mentions the name.
        let loose = try NSRegularExpression(pattern:
            #"(?:class|struct|enum|actor|protocol|extension)\s+"#
            + NSRegularExpression.escapedPattern(for: typeName)
            + #"(?![A-Za-z0-9_])"#)

        var found: [String] = []
        for root in roots {
            for file in try swiftFiles(under: root, base: base) {
                let text = try read(file, base: base)
                guard text.contains(typeName),
                      loose.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                else { continue }
                let masked = String(mask(text))
                let range = NSRange(masked.startIndex..., in: masked)
                if regex.firstMatch(in: masked, range: range) != nil { found.append(file) }
            }
        }
        guard !found.isEmpty else {
            throw LookupError(description:
                "SourceTree: no file declares type '\(typeName)' under roots \(roots).")
        }
        return found
    }

    static func sourceOfType(_ typeName: String, under roots: [String], base: URL) throws -> String {
        try filesDeclaring(typeName, under: roots, base: base)
            .map { try read($0, base: base) }
            .joined(separator: "\n")
    }

    static func declaration(named header: String, under root: String, base: URL) throws -> String {
        struct Match { let file: String; let text: [Character]; let headerAt: Int; let lineStart: Int }

        var matches: [Match] = []
        for file in try swiftFiles(under: root, base: base) {
            let raw = try read(file, base: base)
            guard raw.contains(header) else { continue }   // necessary, and cheap
            let text = Array(raw)
            let masked = String(mask(raw))
            var offset = 0
            for line in masked.split(separator: "\n", omittingEmptySubsequences: false) {
                if let hit = line.range(of: header) {
                    let column = line.distance(from: line.startIndex, to: hit.lowerBound)
                    matches.append(Match(file: file, text: text,
                                         headerAt: offset + column, lineStart: offset))
                }
                offset += line.count + 1
            }
        }

        guard let match = matches.first else {
            throw LookupError(description:
                "SourceTree: no declaration whose line contains '\(header)' under root '\(root)'.")
        }
        guard matches.count == 1 else {
            let sites = matches.map(\.file)
            throw LookupError(description:
                "SourceTree: \(matches.count) declarations contain '\(header)' under root '\(root)' "
                + "— expected exactly one: \(sites).")
        }

        let masked = mask(String(match.text))
        var depth = 0
        var opened = false
        var index = match.headerAt
        while index < masked.count {
            switch masked[index] {
            case "{":
                depth += 1
                opened = true
            case "}" where opened:
                depth -= 1
                if depth == 0 {
                    return String(match.text[match.lineStart...index])
                }
            default:
                break
            }
            index += 1
        }
        throw LookupError(description:
            "SourceTree: the declaration containing '\(header)' in '\(match.file)' "
            + "(root '\(root)') has no brace-matched body.")
    }

    // MARK: - Masking

    /// `text` as an array of the same length, with every character inside a
    /// comment or a string literal's content replaced by a space. Newlines are
    /// kept, so line numbers and offsets line up with the original. The quote
    /// characters themselves stay; the code inside a `\( … )` interpolation stays.
    ///
    /// Handles `//` and nested `/* */` comments, `"…"`, `"""…"""`, raw strings
    /// (`#"…"#`, any number of `#`), escapes, and interpolation (which may
    /// itself hold strings). It does not know regex literals.
    static func mask(_ text: String) -> [Character] {
        enum Context {
            case code(parens: Int)          // parens: depth inside an interpolation
            case string(multiline: Bool, hashes: Int)
        }

        let chars = Array(text)
        var out = chars
        var stack: [Context] = [.code(parens: 0)]
        var i = 0

        func at(_ offset: Int, _ c: Character) -> Bool {
            i + offset < chars.count && chars[i + offset] == c
        }
        func run(of c: Character, from start: Int) -> Int {
            var n = 0
            while start + n < chars.count && chars[start + n] == c { n += 1 }
            return n
        }
        func blank(_ index: Int) {
            if !chars[index].isNewline { out[index] = " " }
        }

        while i < chars.count {
            switch stack[stack.count - 1] {
            case .code(let parens):
                if at(0, "/") && at(1, "/") {
                    while i < chars.count && !chars[i].isNewline { blank(i); i += 1 }
                } else if at(0, "/") && at(1, "*") {
                    var depth = 0
                    repeat {
                        if at(0, "/") && at(1, "*") { depth += 1; blank(i); blank(i + 1); i += 2 }
                        else if at(0, "*") && at(1, "/") { depth -= 1; blank(i); blank(i + 1); i += 2 }
                        else { blank(i); i += 1 }
                    } while depth > 0 && i < chars.count
                } else if chars[i] == "#" || chars[i] == "\"" {
                    let hashes = run(of: "#", from: i)
                    guard i + hashes < chars.count, chars[i + hashes] == "\"" else { i += max(hashes, 1); continue }
                    let multiline = run(of: "\"", from: i + hashes) >= 3
                    i += hashes + (multiline ? 3 : 1)
                    stack.append(.string(multiline: multiline, hashes: hashes))
                } else if parens > 0 || stack.count > 1 {
                    // Inside an interpolation: track parens to find its end.
                    if chars[i] == "(" {
                        stack[stack.count - 1] = .code(parens: parens + 1)
                    } else if chars[i] == ")" {
                        if parens == 0 { stack.removeLast() }
                        else { stack[stack.count - 1] = .code(parens: parens - 1) }
                    }
                    i += 1
                } else {
                    i += 1
                }

            case .string(let multiline, let hashes):
                if chars[i] == "\\" && run(of: "#", from: i + 1) >= hashes {
                    let after = i + 1 + hashes
                    if after < chars.count && chars[after] == "(" {
                        for k in i..<after { blank(k) }
                        i = after + 1
                        stack.append(.code(parens: 0))
                    } else {
                        for k in i...min(after, chars.count - 1) { blank(k) }
                        i = after + 1
                    }
                } else if chars[i] == "\"",
                          run(of: "\"", from: i) >= (multiline ? 3 : 1),
                          run(of: "#", from: i + (multiline ? 3 : 1)) >= hashes {
                    i += (multiline ? 3 : 1) + hashes
                    stack.removeLast()
                } else {
                    blank(i)
                    i += 1
                }
            }
        }
        return out
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
