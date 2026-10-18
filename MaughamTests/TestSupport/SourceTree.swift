import Foundation
import os

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
        productionRoots(base: repoRoot)
    }

    /// `productionRoots` against any base — the seam a planted tree uses.
    static func productionRoots(base: URL) -> [String] {
        let fm = FileManager.default
        var roots = ["Maugham", "MaughamPhone"]
        let packages = base.appendingPathComponent("Packages", isDirectory: true)
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
    /// whose line contains `header` (e.g. "func manuscriptEditor(",
    /// "static func reviewCentreShowsBoard("), searched across every .swift file
    /// under `root`. Access modifiers are ignored on both sides — `"private func
    /// f("` finds `func f(` and `fileprivate func f(` — because a split that
    /// moves a declaration into an extension file must drop `private`. Throws
    /// if zero matches or more than one. Memoised for the repo's own tree.
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
        let memoKey = memoKey(base: base, "filesDeclaring", roots.joined(separator: "|"), typeName)
        if let memoKey, let known = lookupMemo.withLock({ $0[memoKey] }) { return known }
        let found = try declarationRanges(of: typeName, under: roots, base: base)
            .keys.sorted()
        guard !found.isEmpty else {
            throw LookupError(description:
                "SourceTree: no file declares type '\(typeName)' under roots \(roots).")
        }
        if let memoKey { lookupMemo.withLock { $0[memoKey] = found } }
        return found
    }

    /// The declaration-header pattern for `typeName`: a line whose code (after
    /// attributes and access/final/@MainActor modifiers) begins
    /// `class|struct|enum|actor|protocol|extension <typeName>` followed by a
    /// non-identifier character.
    private static func declarationPattern(for typeName: String) throws -> NSRegularExpression {
        // An attribute's arguments may nest one level of parens: `@Wrap(f(1))`.
        // Leading space is `[ \t]*`, not `\s*`: a `\s*` that can cross lines
        // backtracks over every blank line and made this regex ~10× slower.
        let pattern = #"^[ \t]*(?:@\w+(?:\((?:[^()]|\([^()]*\))*\))?[ \t]*)*"#
            + #"(?:(?:public|private|fileprivate|internal|package|open|final|indirect|nonisolated|distributed)\s+)*"#
            + #"(?:class|struct|enum|actor|protocol|extension)\s+"#
            + NSRegularExpression.escapedPattern(for: typeName)
            + #"(?![A-Za-z0-9_])"#
        return try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    /// **Where each declaration of `typeName` is**, per repo-relative file
    /// under `roots`: the 1-based, inclusive LINE range of every
    /// `class|struct|enum|actor|protocol|extension <typeName>` declaration,
    /// header through its brace-matched close. Files declaring nothing are
    /// left out. A `type:` key claims these ranges and nothing else in the
    /// file — a child view sharing the file is that file's own code.
    static func declarationRanges(of typeName: String, under roots: [String],
                                  base: URL) throws -> [String: [ClosedRange<Int>]] {
        let regex = try declarationPattern(for: typeName)
        var found: [String: [ClosedRange<Int>]] = [:]
        for root in roots {
            for file in try swiftFiles(under: root, base: base) {
                let text = try read(file, base: base)
                // Masking only blanks characters, so a file whose raw text never
                // names the type cannot declare it; skipping it spares the mask.
                guard text.contains(typeName) else { continue }
                let maskedBytes = try checkedMask(text, path: file)
                let masked = String(decoding: maskedBytes, as: UTF8.self)
                guard masked.contains(typeName) else { continue }   // named only in comments
                let ranges = declarationRanges(matching: regex, masked: masked, bytes: maskedBytes)
                if !ranges.isEmpty { found[file] = ranges }
            }
        }
        return found
    }

    /// The line ranges of every `regex` match's declaration in one masked file.
    private static func declarationRanges(matching regex: NSRegularExpression, masked: String,
                                          bytes: [UInt8]) -> [ClosedRange<Int>] {
        // Line number of each byte offset, by counting newlines up to it.
        var lineStarts: [Int] = [0]
        for (offset, byte) in bytes.enumerated() where byte == newline { lineStarts.append(offset + 1) }
        func line(ofByte offset: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo + 1
        }
        let matches = regex.matches(in: masked, range: NSRange(masked.startIndex..., in: masked))
        return matches.compactMap { match in
            guard let range = Range(match.range, in: masked) else { return nil }
            let start = masked.utf8.distance(from: masked.startIndex, to: range.lowerBound)
            let end = masked.utf8.distance(from: masked.startIndex, to: range.upperBound)
            let close = bodyEnd(in: bytes, from: end) ?? end
            return line(ofByte: start)...line(ofByte: close)
        }
    }

    static func sourceOfType(_ typeName: String, under roots: [String], base: URL) throws -> String {
        try sourcesOfType(typeName, under: roots, base: base)
            .map(\.text)
            .joined(separator: "\n")
    }

    /// Every file declaring `typeName`, each with its own text — for a census
    /// that slices a window of lines and must never let one file's slice run
    /// on into the next file's text.
    static func sourcesOfType(_ typeName: String, under roots: [String],
                              base: URL = repoRoot) throws -> [(path: String, text: String)] {
        try filesDeclaring(typeName, under: roots, base: base).map { ($0, try read($0, base: base)) }
    }

    static func declaration(named header: String, under root: String, base: URL) throws -> String {
        let needleText = withoutAccessModifiers(header)
        let memoKey = memoKey(base: base, "declaration", root, needleText)
        if let memoKey, let known = lookupMemo.withLock({ $0[memoKey] }) {
            return known.first ?? ""
        }

        struct Match {
            let file: String
            let text: [UInt8]
            let masked: [UInt8]
            let headerAt: Int
            let lineStart: Int
        }

        // Access modifiers are not part of what a declaration IS: a split that
        // moves `private func f(` into an extension file has to drop the
        // `private` (it does not cross files), and the header must still find
        // it. So the needle carries none, and a line matches whatever access
        // modifiers precede the rest.
        let needle = Array(needleText.utf8)
        var matches: [Match] = []
        for file in try swiftFiles(under: root, base: base) {
            let raw = try read(file, base: base)
            guard raw.contains(needleText) else { continue }   // necessary, and cheap
            let text = Array(raw.utf8)
            let masked = try checkedMask(raw, path: file)
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
                "SourceTree: no declaration whose line contains '\(needleText)' under root '\(root)'.")
        }
        guard matches.count == 1 else {
            let sites = matches.map(\.file)
            throw LookupError(description:
                "SourceTree: \(matches.count) declarations contain '\(needleText)' under root '\(root)' "
                + "— expected exactly one: \(sites).")
        }
        guard let close = bodyEnd(in: match.masked, from: match.headerAt) else {
            throw LookupError(description:
                "SourceTree: the declaration containing '\(needleText)' in '\(match.file)' "
                + "(root '\(root)') has no brace-matched body.")
        }
        let body = String(decoding: match.text[match.lineStart...close], as: UTF8.self)
        if let memoKey { lookupMemo.withLock { $0[memoKey] = [body] } }
        return body
    }

    /// The access modifiers `declaration(named:)` ignores. `static`, `final`,
    /// `override` and the rest stay meaningful: they say WHICH declaration.
    static let accessModifiers: Set<String> = [
        "private", "fileprivate", "internal", "public", "open", "package",
    ]

    /// `header` with every access-modifier WORD removed (`private func f(` →
    /// `func f(`; `static private func g(` → `static func g(`).
    static func withoutAccessModifiers(_ header: String) -> String {
        let leading = header.prefix(while: { $0 == " " || $0 == "\t" })
        let words = header.dropFirst(leading.count)
            .split(separator: " ", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var stripping = true
        for word in words {
            if stripping, accessModifiers.contains(String(word)) { continue }
            if !word.isEmpty, !word.hasPrefix("@"), word != "static", word != "final",
               word != "override", word != "nonisolated" {
                stripping = false
            }
            kept.append(word)
        }
        return String(leading) + kept.joined(separator: " ")
    }

    /// The index of the `}` closing the body that opens after `from` in
    /// `masked`, or nil. The body opens on the first `{` OUTSIDE any parens or
    /// brackets: a `{` inside the parameter list is a default closure (`now: ()
    /// -> Date = { Date() }`), and opening there would return a header cut short.
    static func bodyEnd(in masked: [UInt8], from: Int) -> Int? {
        var depth = 0
        var nesting = 0          // ( and [ depth; read only until the body opens
        var opened = false
        var index = from
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
                if depth == 0 { return index }
            default:
                break
            }
            index += 1
        }
        return nil
    }

    // MARK: - Memo

    /// The memo key for a lookup against `base`, or nil when `base` is not the
    /// repo (or inside it). The production tree does not change under a
    /// running test, so its lookups are memoised for the life of the process;
    /// a planted base (under `TestTemp`, outside the repo) is read fresh every
    /// time, because its controls rename and rewrite files between calls.
    static func memoKey(base: URL, _ parts: String...) -> String? {
        let path = base.standardizedFileURL.path
        let repo = repoRoot.standardizedFileURL.path
        guard path == repo || path.hasPrefix(repo + "/") else { return nil }
        return ([path] + parts).joined(separator: "\u{0}")
    }

    private static let lookupMemo = OSAllocatedUnfairLock<[String: [String]]>(initialState: [:])

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
    /// code after it (none exist in this repo today). Such a mis-scan almost
    /// always leaves the file ENDING inside a string or comment, which
    /// `checkedMask` — the mask every lookup and `sources(under:)` reads
    /// through — reports by throwing.
    static func mask(_ text: String) -> [UInt8] {
        maskScan(text).bytes
    }

    /// `mask`, throwing when `text` ENDS inside a string literal, an
    /// interpolation or a block comment. A Swift file that compiles cannot, so
    /// such an end means the scan lost its place — a regex literal it read as
    /// opening a string, say — and everything after that point was blanked as
    /// non-code. A census reading a file through that mask would pass over
    /// whatever was hidden; this says so instead.
    static func checkedMask(_ text: String, path: String) throws -> [UInt8] {
        let scan = maskScan(text)
        guard !scan.endsInside else {
            throw LookupError(description:
                "SourceTree: '\(path)' ends inside a string or a comment — the masker "
                + "lost its place (a regex literal?), so every line after that point "
                + "would be invisible to a census.")
        }
        return scan.bytes
    }

    private static func maskScan(_ text: String) -> (bytes: [UInt8], endsInside: Bool) {
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
        var unclosedBlock = false

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
                    if depth > 0 { unclosedBlock = true }
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
        return (out, unclosedBlock || stack.count > 1)
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

// MARK: - Type keys (foundations plan 2, Task 3)

/// **An allow-list or counted-list key may name a TYPE instead of a file.**
///
/// `"type:OpLogStore"` means *the declarations of `OpLogStore`* —
/// `class|struct|enum|actor|protocol|extension OpLogStore`, as
/// `SourceTree.declarationRanges` reads them, header through brace-matched
/// close. A census keyed by a file name has to be hand-edited the day that
/// file is split; one keyed by the type follows the code into the extension
/// files, and a line moved into an unrelated file is still caught.
///
/// **A type key claims DECLARATIONS, never whole files.** A file holding
/// `extension ProjectWindow` and a child view `struct ResearchSubjectInspector`
/// gives `type:ProjectWindow` the extension's lines only; a hit in the child
/// view is judged as the file's own (plain-key) hit — allowed only if the file
/// is named itself, and counted under its own name. Otherwise a type key would
/// quietly allow everything that happened to share a file with its type.
/// Plain file keys keep their old meaning.
///
/// The keys are resolved against the roots the census itself walks — so a
/// planted tree resolves against its own declarations, never the repo's —
/// EXCEPT a root named `MaughamPhone`: a type key never claims a phone file.
/// The Mac's censuses that scan the phone allow-list the Mac's and Core's
/// types, and a phone file declaring `extension OpLogStore` must not inherit
/// `type:OpLogStore`'s allowances (most of those censuses have no phone twin).
/// A type key that resolves to no file is an OFFENDER (*type key `type:X`
/// names no file*): a key that matches nothing would otherwise allow nothing
/// and count nothing, and say neither. So is a declaration two type keys both
/// claim (one nested in the other), and a plain key naming a file a type key
/// claims anything in — one rule for every map shape: in a count map the file
/// would be split between two entries, and in an allow-list two entries would
/// silently merge.
///
/// - An allow-list (`[file: spellings]` or a `Set` of files) is asked per line
///   (`TypeKeyAllowance`): inside a claimed declaration the type key's
///   spellings apply, merged with any plain entry of the file's own.
/// - A count map FOLDS per hit: a hit inside a claimed declaration is added to
///   the type key, so the key's expected count is the SUM over its declarations.
extension SourceTree {

    static let typeKeyPrefix = "type:"

    /// The root a type key never resolves into (see above).
    static let phoneRootName = "MaughamPhone"

    /// The type a `type:` key names, or nil for a plain file key.
    static func typeName(ofKey key: String) -> String? {
        key.hasPrefix(typeKeyPrefix) ? String(key.dropFirst(typeKeyPrefix.count)) : nil
    }

    /// One declaration a type key claims: its lines in one file.
    struct Claim: Equatable {
        let key: String
        let lines: ClosedRange<Int>
    }

    /// The type keys among some keys, resolved to the DECLARATIONS of each.
    struct TypeKeyResolution {
        /// Basename → the declarations type keys claim in it.
        var claims: [String: [Claim]] = [:]
        /// Type key → the basenames that declare its type.
        var filesForKey: [String: Set<String>] = [:]
        /// Unresolved keys, declarations two type keys both claim, and plain
        /// keys naming a file a type key claims.
        var offenders: [String] = []

        /// The type key whose declaration holds `line` of `basename`, or nil:
        /// a line outside every claimed declaration — a child view sharing the
        /// file, say — is the file's own.
        func typeKey(for basename: String, line: Int) -> String? {
            claims[basename]?.first { $0.lines.contains(line) }?.key
        }

        /// The key a hit is counted under: the claiming type key, else its file.
        func key(for basename: String, line: Int) -> String {
            typeKey(for: basename, line: line) ?? basename
        }
    }

    /// Resolve every `type:` key in `keys` against the Swift files under
    /// `roots` (absolute directories, as a census walks them), skipping any
    /// root named `MaughamPhone`.
    static func resolveTypeKeys<Keys: Sequence>(
        _ keys: Keys, in roots: [URL]
    ) -> TypeKeyResolution where Keys.Element == String {
        var resolution = TypeKeyResolution()
        let allKeys = Set(keys).sorted()
        let typeRoots = roots.filter { $0.lastPathComponent != phoneRootName }
        for key in allKeys {
            guard let type = typeName(ofKey: key) else { continue }
            var ranges: [String: [ClosedRange<Int>]] = [:]
            for root in typeRoots {
                ranges.merge(declarationRanges(of: type, in: root), uniquingKeysWith: +)
            }
            guard !ranges.isEmpty else {
                resolution.offenders.append("type key `\(key)` names no file")
                continue
            }
            resolution.filesForKey[key] = Set(ranges.keys)
            for (file, lines) in ranges.sorted(by: { $0.key < $1.key }) {
                for range in lines {
                    if let other = resolution.claims[file]?.first(where: {
                        $0.key != key && $0.lines.overlaps(range)
                    }) {
                        resolution.offenders.append(
                            "\(file):\(range.lowerBound) is claimed by two type keys, "
                            + "`\(other.key)` and `\(key)`")
                    }
                    resolution.claims[file, default: []].append(Claim(key: key, lines: range))
                }
            }
        }
        for key in allKeys where typeName(ofKey: key) == nil {
            if let claimer = resolution.claims[key]?.first?.key {
                resolution.offenders.append("\(key) is named by itself and by `\(claimer)`")
            }
        }
        return resolution
    }

    /// **An allow-list with its type keys resolved, asked per LINE.** A plain
    /// key allows its whole file; a type key allows the lines of its type's
    /// declarations, and nothing else in the files holding them.
    struct TypeKeyAllowance {
        let resolution: TypeKeyResolution
        /// Plain file key → its spellings.
        let plain: [String: Set<String>]
        /// Type key → its spellings.
        let byKey: [String: Set<String>]

        /// The spellings allowed at `line` of `basename`.
        func spellings(file basename: String, line: Int) -> Set<String> {
            var allowed = plain[basename] ?? []
            if let key = resolution.typeKey(for: basename, line: line) {
                allowed.formUnion(byKey[key] ?? [])
            }
            return allowed
        }

        /// Whether a whole-file allow-list (a `Set` of keys) lets `line` of
        /// `basename` through.
        func allows(file basename: String, line: Int) -> Bool {
            plain[basename] != nil || resolution.typeKey(for: basename, line: line) != nil
        }
    }

    /// `allowed` (`[key: spellings]`) resolved: each type key allows its
    /// spellings inside its type's declarations only.
    static func expandingTypeKeys(
        _ allowed: [String: Set<String>], in roots: [URL]
    ) -> (allowance: TypeKeyAllowance, offenders: [String]) {
        let resolution = resolveTypeKeys(allowed.keys, in: roots)
        let plain = allowed.filter { typeName(ofKey: $0.key) == nil }
        let byKey = allowed.filter { typeName(ofKey: $0.key) != nil }
        return (TypeKeyAllowance(resolution: resolution, plain: plain, byKey: byKey),
                resolution.offenders)
    }

    /// A whole-file allow-list (a set of keys) resolved: ask `allows(file:line:)`.
    static func expandingTypeKeys(
        _ files: Set<String>, in roots: [URL]
    ) -> (allowance: TypeKeyAllowance, offenders: [String]) {
        expandingTypeKeys(Dictionary(uniqueKeysWithValues: files.map { ($0, Set<String>()) }),
                          in: roots)
    }

    /// One census hit: a file's basename and the 1-based line it is on.
    struct Hit: Hashable {
        let file: String
        let line: Int
        init(file: String, line: Int) { self.file = file; self.line = line }
        /// From a census offender string, `"<basename>:<line>: <text>"`.
        init?(offender: String) {
            let parts = offender.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, let line = Int(parts[1]) else { return nil }
            self.init(file: String(parts[0]), line: line)
        }
    }

    /// `found` (per hit) keyed the way `expectedKeys` is: a hit inside a
    /// declaration a type key claims is folded into that key with `combine`,
    /// and every other hit — including one elsewhere in the same file — under
    /// its own file name.
    static func foldingIntoTypeKeys<Value, Keys: Sequence>(
        _ found: [(hit: Hit, value: Value)], keyedLike expectedKeys: Keys, in roots: [URL],
        combine: (Value, Value) -> Value
    ) -> (folded: [String: Value], offenders: [String]) where Keys.Element == String {
        let resolution = resolveTypeKeys(Set(expectedKeys), in: roots)
        var folded: [String: Value] = [:]
        for (hit, value) in found {
            let key = resolution.key(for: hit.file, line: hit.line)
            folded[key] = folded[key].map { combine($0, value) } ?? value
        }
        return (folded, resolution.offenders)
    }

    /// The declaration line ranges of `type` per basename under `root`; empty
    /// when none (or `root` is not a directory). A root inside the repo is
    /// memoised for the life of the process — the production tree does not
    /// change under a running test, and one resolution walks every file —
    /// while a planted root (under `TestTemp`, outside the repo) is read fresh
    /// each time, because its controls rename and rewrite files between calls.
    private static func declarationRanges(of type: String, in root: URL) -> [String: [ClosedRange<Int>]] {
        let memoise = root.standardizedFileURL.path.hasPrefix(repoRoot.standardizedFileURL.path + "/")
        let memoKey = root.standardizedFileURL.path + "\u{0}" + type
        if memoise, let known = typeKeyMemo.withLock({ $0[memoKey] }) { return known }
        let base = root.deletingLastPathComponent()
        let byPath = (try? declarationRanges(of: type, under: [root.lastPathComponent], base: base)) ?? [:]
        var byName: [String: [ClosedRange<Int>]] = [:]
        for (path, ranges) in byPath {
            byName[(path as NSString).lastPathComponent, default: []] += ranges
        }
        if memoise { typeKeyMemo.withLock { $0[memoKey] = byName } }
        return byName
    }

    private static let typeKeyMemo =
        OSAllocatedUnfairLock<[String: [String: [ClosedRange<Int>]]]>(initialState: [:])
}

// MARK: - Planted trees and per-file reads (foundations plan 2, Task 4)

extension SourceTree {

    /// Writes `files` (base-relative path → text) into a fresh directory under
    /// `TestTemp.root` and returns that directory, for use as a `base:`. The
    /// controls that prove a migrated census still fires plant a `ProjectWindow`
    /// struct and an `extension ProjectWindow` in two files through this.
    static func plantedTree(_ files: [String: String]) throws -> URL {
        let base = TestTemp.root.appendingPathComponent(
            "PlantedTree-\(UUID().uuidString)", isDirectory: true)
        for (relative, text) in files {
            let url = base.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return base
    }

    /// Every .swift file under `root`, each with its own text — never joined,
    /// so an ABSENCE ban scans file by file and one file's unclosed `/*` (see
    /// `SourceScan`) cannot hide an offender in the next. Throws, like
    /// `swiftFiles(under:)`, when `root` is not a directory, and when it holds
    /// no Swift file at all: a ban over nothing passes over anything. And
    /// throws when a file ENDS inside a string or comment (`checkedMask`): the
    /// masker lost its place in it, and a ban reading it would be blind past
    /// that point.
    static func sources(under root: String, base: URL = repoRoot) throws -> [(path: String, text: String)] {
        try maskedSources(under: root, base: base).map { ($0.path, $0.text) }
    }

    /// `sources(under:)`, each file with its `checkedMask` alongside.
    static func maskedSources(under root: String, base: URL = repoRoot)
        throws -> [(path: String, text: String, masked: [UInt8])] {
        let files = try swiftFiles(under: root, base: base)
        guard !files.isEmpty else {
            throw LookupError(description: "SourceTree: root '\(root)' holds no .swift file.")
        }
        return try files.map { file in
            let text = try read(file, base: base)
            return (file, text, try checkedMask(text, path: file))
        }
    }
}

// MARK: - The window and the views, by type and by directory (foundations plan 2, Task 5)

extension SourceTree {

    /// The window's code, joined: every file under `Maugham/` declaring
    /// `ProjectWindow` or one of `windowFamilyTypes`, wherever they live.
    /// Throws when nothing declares `ProjectWindow`, and (against the repo's own
    /// tree) when nothing declares a family member.
    static func windowSource(base: URL = repoRoot) throws -> String {
        try windowSources(base: base).joined(separator: "\n")
    }

    /// The window's free-standing modifiers and decisions, which lived in
    /// `ProjectWindow.swift` until foundations plan 4 gave each its own file.
    /// A census reading "the window's code" reads these too, BY TYPE, so it
    /// does not care which file a modifier lives in. Against the repo's own tree
    /// a member nothing declares THROWS naming the type (a rename must fail
    /// loudly, not shrink the text an absence check reads); only a planted base
    /// tolerates an absent member, since it plants only what it needs.
    /// Absence checks must still widen to a directory (`sources(under:)`),
    /// never lean on this list.
    ///
    /// `CentreColumn` is a member for a different reason from the modifiers:
    /// it is not a decision lifted out but the window's own centre column,
    /// whose builders were `ProjectWindow` members until plan 4 Task 4. Its
    /// wiring — the board's closures, the gate's write-back — is the window's
    /// wiring, so a census reading "what the window passes" must still see it.
    ///
    /// `RightColumn` is a member for the same reason (plan 4 Task 5): it is the
    /// window's own detail column — the resize handle and its drag, the study
    /// arm, `DetailPaneToggle`'s wiring and the services injected into its
    /// environment — whose builders were `ProjectWindow` members until then.
    /// The width censuses, the environment censuses and the pane-wiring
    /// censuses read "the window's code" and must still find them there.
    ///
    /// `PaletteWallState` and `WindowFlashes` (plan 4 Task 6) are the window's
    /// own `@State`, bundled: the wall's folds were `ProjectWindow` statics
    /// until then, and a census naming them reads the window's code.
    static let windowFamilyTypes = [
        "ProjectActiveSheet", "CheckpointFlashDecision", "CheckpointModifier",
        "RewindModifier", "FocusPostureModifier", "CanvasCollapseModifier",
        "ContainerWidthReporter", "PersonaModifier", "ParagraphNavModifier",
        "EditorControlMirror", "EditorControlMirrorModifier",
        "TranslationReviewModifier", "CanvasPromotionModifier",
        "CompilerFlashSink", "NoteOutcomeAlert", "CentreColumn", "RightColumn",
        "PaletteWallState", "WindowFlashes",
    ]

    /// Every file declaring `ProjectWindow` or a window-family type, each its
    /// own text (the window's files first, in path order) — for a census that SLICES (the N characters or lines after a
    /// token), so a slice can never run off the end of one file into the
    /// next file's text the way it could over `windowSource`'s join.
    static func windowSources(base: URL = repoRoot) throws -> [String] {
        let window = try sourcesOfType("ProjectWindow", under: ["Maugham"], base: base)
        var seen = Set(window.map(\.path))
        var all = window.map(\.text)
        for type in windowFamilyTypes {
            let found: [(path: String, text: String)]
            do {
                found = try sourcesOfType(type, under: ["Maugham"], base: base)
            } catch let error as LookupError
                where base != repoRoot && error.description.hasPrefix("SourceTree: no file declares") {
                continue
            }
            for file in found where seen.insert(file.path).inserted { all.append(file.text) }
        }
        return all
    }

    /// The `length` characters after the first `token` in the window's code
    /// (`windowSources`), sliced inside the ONE file that holds it. Nil
    /// when no window file has the token.
    static func windowText(after token: String, length: Int, base: URL = repoRoot) throws -> String? {
        for text in try windowSources(base: base) {
            if let hit = text.range(of: token) { return String(text[hit.upperBound...].prefix(length)) }
        }
        return nil
    }

    /// `windowSource`'s code lines, comments stripped (`SourceScan.codeLines`).
    static func windowCodeLines(base: URL = repoRoot) throws -> [String] {
        SourceScan.codeLines(of: try windowSource(base: base))
    }

    /// `token` as code (comments and strings masked) counted across every file
    /// under `Maugham/Views` — the window, `CentreColumn` and every sibling
    /// view. The one spelling the routing suites share for *how many places
    /// mount this surface*.
    static func viewMounts(of token: String, base: URL = repoRoot) throws -> Int {
        try codeOccurrences(of: token, base: base).values.reduce(0, +)
    }

    /// Every code line containing `token` in any .swift file under `root`, as
    /// `"<path>: <line>"`, read file by file through `mask` — so a comment or a
    /// string literal naming the token is not a hit, and one file's unclosed
    /// `/*` cannot hide an offender in the next. The instrument of an ABSENCE
    /// ban: it throws, like `sources(under:)`, on a missing or Swift-less root.
    static func codeLines(containing token: String, under root: String = "Maugham/Views",
                          base: URL = repoRoot) throws -> [String] {
        try maskedSources(under: root, base: base).flatMap { file -> [String] in
            let masked = String(decoding: file.masked, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
            let raw = file.text.split(separator: "\n", omittingEmptySubsequences: false)
            return masked.indices
                .filter { masked[$0].contains(token) }
                .map { "\(file.path): \(raw[$0].trimmingCharacters(in: .whitespaces))" }
        }
    }

    /// How many times `token` occurs as CODE in each .swift file under `root`
    /// (files with none are left out). Comments and string contents are masked,
    /// and a token that starts with an identifier character is not counted
    /// where one precedes it — `EditorHost(` is not found inside
    /// `StatementEditorHost(`. The instrument
    /// of a COUNT that also means *nowhere else*. Throws on a missing or
    /// Swift-less root.
    static func codeOccurrences(of token: String, under root: String = "Maugham/Views",
                                base: URL = repoRoot) throws -> [String: Int] {
        let needle = Array(token.utf8)
        let checksBoundary = needle.first.map(isIdentifierByte) ?? false
        var counts: [String: Int] = [:]
        for file in try maskedSources(under: root, base: base) where file.text.contains(token) {
            let masked = file.masked
            var count = 0
            var from = 0
            while let hit = firstIndex(of: needle, in: masked, from: from, to: masked.count) {
                if !checksBoundary || hit == 0 || !isIdentifierByte(masked[hit - 1]) { count += 1 }
                from = hit + 1
            }
            if count > 0 { counts[file.path] = count }
        }
        return counts
    }

    /// `hits` with every hit inside a declaration a type key claims replaced
    /// by that key, and every other hit by its own file name — how a file-SET
    /// census keyed `"type:ProjectWindow"` compares what it found. A hit in a
    /// child view sharing a file with `extension ProjectWindow` answers under
    /// the FILE, not the type. Throws on any offender `resolveTypeKeys` reports
    /// (a type key naming no file, above all), so a fold can never pass empty.
    static func keyedByType<Hits: Sequence>(
        _ hits: Hits, typeKeys: Set<String>, in roots: [URL]
    ) throws -> Set<String> where Hits.Element == Hit {
        let resolution = resolveTypeKeys(typeKeys, in: roots)
        guard resolution.offenders.isEmpty else {
            throw LookupError(description:
                "SourceTree: type keys \(typeKeys.sorted()) did not resolve: \(resolution.offenders)")
        }
        return Set(hits.map { resolution.key(for: $0.file, line: $0.line) })
    }

    /// The 1-based numbers of the lines of `text` whose CODE (comments and
    /// string contents masked) satisfies `predicate` — the per-line hits a
    /// type-keyed census needs.
    static func codeLineNumbers(in text: String, where predicate: (String) -> Bool) -> [Int] {
        String(decoding: mask(text), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { predicate(String($0.element)) }
            .map { $0.offset + 1 }
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || byte == UInt8(ascii: "_")
    }
}
