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
        // An attribute's arguments may nest one level of parens: `@Wrap(f(1))`.
        // Leading space is `[ \t]*`, not `\s*`: a `\s*` that can cross lines
        // backtracks over every blank line and made this regex ~10× slower.
        let pattern = #"^[ \t]*(?:@\w+(?:\((?:[^()]|\([^()]*\))*\))?[ \t]*)*"#
            + #"(?:(?:public|private|fileprivate|internal|package|open|final|indirect|nonisolated|distributed)\s+)*"#
            + #"(?:class|struct|enum|actor|protocol|extension)\s+"#
            + NSRegularExpression.escapedPattern(for: typeName)
            + #"(?![A-Za-z0-9_])"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])

        var found: [String] = []
        for root in roots {
            for file in try swiftFiles(under: root, base: base) {
                let text = try read(file, base: base)
                // Masking only blanks characters, so a file whose raw text never
                // names the type cannot declare it; skipping it spares the mask.
                guard text.contains(typeName) else { continue }
                let masked = String(decoding: mask(text), as: UTF8.self)
                guard masked.contains(typeName) else { continue }   // named only in comments
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
        struct Match {
            let file: String
            let text: [UInt8]
            let masked: [UInt8]
            let headerAt: Int
            let lineStart: Int
        }

        let needle = Array(header.utf8)
        var matches: [Match] = []
        for file in try swiftFiles(under: root, base: base) {
            let raw = try read(file, base: base)
            guard raw.contains(header) else { continue }   // necessary, and cheap
            let text = Array(raw.utf8)
            let masked = mask(raw)
            var lineStart = 0
            while lineStart <= masked.count {
                let lineEnd = masked[lineStart...].firstIndex(of: newline) ?? masked.count
                if let hit = firstIndex(of: needle, in: masked, from: lineStart, to: lineEnd) {
                    matches.append(Match(file: file, text: text, masked: masked,
                                         headerAt: hit, lineStart: lineStart))
                }
                lineStart = lineEnd + 1
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

        // The body opens on the first `{` OUTSIDE any parens or brackets: a `{`
        // inside the parameter list is a default closure (`now: () -> Date =
        // { Date() }`), and opening there would return a header cut short.
        let masked = match.masked
        var depth = 0
        var nesting = 0          // ( and [ depth; read only until the body opens
        var opened = false
        var index = match.headerAt
        while index < masked.count {
            switch masked[index] {
            case UInt8(ascii: "("), UInt8(ascii: "["):
                nesting += 1
            case UInt8(ascii: ")"), UInt8(ascii: "]"):
                nesting -= 1
            case UInt8(ascii: "{") where !opened && nesting > 0:
                break
            case UInt8(ascii: "{"):
                depth += 1
                opened = true
            case UInt8(ascii: "}") where opened:
                depth -= 1
                if depth == 0 {
                    return String(decoding: match.text[match.lineStart...index], as: UTF8.self)
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

    private static let newline = UInt8(ascii: "\n")

    /// `text`'s UTF-8 bytes, the same length, with every byte inside a comment or
    /// a string literal's content replaced by a space. Newlines are kept, so
    /// lines and byte offsets line up with the original; every delimiter is
    /// ASCII, and a multi-byte character is either blanked whole or untouched,
    /// so the result is still valid UTF-8. The quote characters themselves stay;
    /// the code inside a `\( … )` interpolation stays.
    ///
    /// Handles `//` and nested `/* */` comments, `"…"`, `"""…"""`, raw strings
    /// (`#"…"#`, any number of `#`), escapes, and interpolation (which may
    /// itself hold strings). It does not know regex literals: a `"`, `//` or
    /// `/*` inside `/…/` would be read as opening a string or comment, blanking
    /// code after it (none exist in this repo today).
    static func mask(_ text: String) -> [UInt8] {
        enum Context {
            case code(parens: Int)          // parens: depth inside an interpolation
            case string(multiline: Bool, hashes: Int)
        }
        let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), hash = UInt8(ascii: "#")
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        let open = UInt8(ascii: "("), close = UInt8(ascii: ")"), space = UInt8(ascii: " ")

        let chars = Array(text.utf8)
        var out = chars
        var stack: [Context] = [.code(parens: 0)]
        var i = 0

        func at(_ offset: Int, _ c: UInt8) -> Bool {
            i + offset < chars.count && chars[i + offset] == c
        }
        func run(of c: UInt8, from start: Int) -> Int {
            var n = 0
            while start + n < chars.count && chars[start + n] == c { n += 1 }
            return n
        }
        func blank(_ index: Int) {
            if index < chars.count && chars[index] != newline { out[index] = space }
        }

        while i < chars.count {
            switch stack[stack.count - 1] {
            case .code(let parens):
                if at(0, slash) && at(1, slash) {
                    while i < chars.count && chars[i] != newline { blank(i); i += 1 }
                } else if at(0, slash) && at(1, star) {
                    var depth = 0
                    repeat {
                        if at(0, slash) && at(1, star) { depth += 1; blank(i); blank(i + 1); i += 2 }
                        else if at(0, star) && at(1, slash) { depth -= 1; blank(i); blank(i + 1); i += 2 }
                        else { blank(i); i += 1 }
                    } while depth > 0 && i < chars.count
                } else if chars[i] == hash || chars[i] == quote {
                    let hashes = run(of: hash, from: i)
                    guard i + hashes < chars.count, chars[i + hashes] == quote else { i += max(hashes, 1); continue }
                    let multiline = run(of: quote, from: i + hashes) >= 3
                    i += hashes + (multiline ? 3 : 1)
                    stack.append(.string(multiline: multiline, hashes: hashes))
                } else if parens > 0 || stack.count > 1 {
                    // Inside an interpolation: track parens to find its end.
                    if chars[i] == open {
                        stack[stack.count - 1] = .code(parens: parens + 1)
                    } else if chars[i] == close {
                        if parens == 0 { stack.removeLast() }
                        else { stack[stack.count - 1] = .code(parens: parens - 1) }
                    }
                    i += 1
                } else {
                    i += 1
                }

            case .string(let multiline, let hashes):
                if chars[i] == backslash && run(of: hash, from: i + 1) >= hashes {
                    let after = i + 1 + hashes
                    if after < chars.count && chars[after] == open {
                        for k in i..<after { blank(k) }
                        i = after + 1
                        stack.append(.code(parens: 0))
                    } else {
                        for k in i...after { blank(k) }
                        i = after + 1
                    }
                } else if chars[i] == quote,
                          run(of: quote, from: i) >= (multiline ? 3 : 1),
                          run(of: hash, from: i + (multiline ? 3 : 1)) >= hashes {
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

    /// The first index in `haystack[from..<to]` where `needle` begins.
    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from: Int, to: Int) -> Int? {
        guard !needle.isEmpty, to - from >= needle.count else { return nil }
        var i = from
        while i + needle.count <= to {
            if haystack[i] == needle[0] && haystack[i..<(i + needle.count)].elementsEqual(needle) {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
