import XCTest

/// Reading an EPUB back off disk, for tests that assert on what a compile
/// actually shipped rather than on the package value it built.
///
/// `pieceIDs(inEPUBAt:)` was `private` in `RepublisherTests` (P2 Task 4 moved
/// it here verbatim, keeping its `XCTestCase`-extension shape so every existing
/// call site reads unchanged) because the bilingual suite needs the same
/// question asked of a two-language EPUB — where the answer is no longer a set:
/// one piece appears once per body. So the set is now derived from an ordered
/// list of every occurrence, and both are available.
extension XCTestCase {

    /// Every `data-piece-id` an EPUB's section documents carry, in the order
    /// `unzip` hands the section files over.
    func pieceIDOccurrences(inEPUBAt url: URL) throws -> [String] {
        let xhtml = try unzipToString(url, entryGlob: "OEBPS/*.xhtml")
        let pattern = try NSRegularExpression(pattern: #"data-piece-id="([^"]+)""#)
        let range = NSRange(xhtml.startIndex..<xhtml.endIndex, in: xhtml)
        return pattern.matches(in: xhtml, range: range).compactMap {
            Range($0.range(at: 1), in: xhtml).map { String(xhtml[$0]) }
        }
    }

    /// Every DISTINCT `data-piece-id` an EPUB's section documents carry.
    func pieceIDs(inEPUBAt url: URL) throws -> Set<String> {
        Set(try pieceIDOccurrences(inEPUBAt: url))
    }

    /// The archive's entry names, in the order the zip lists them.
    func epubEntryNames(inEPUBAt url: URL) throws -> [String] {
        let listing = try run("/usr/bin/unzip", ["-Z", "-1", url.path])
        return listing.split(separator: "\n").map(String.init)
    }

    /// One entry's text.
    func epubEntryText(_ entry: String, inEPUBAt url: URL) throws -> String {
        try unzipToString(url, entryGlob: entry)
    }

    // MARK: - plumbing

    private func unzipToString(_ url: URL, entryGlob: String) throws -> String {
        try run("/usr/bin/unzip", ["-p", url.path, entryGlob])
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
