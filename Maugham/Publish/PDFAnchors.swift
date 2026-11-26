import Foundation
import PDFKit
import CoreGraphics

/// **Where a paragraph landed in a compiled book** (shell p4 Task 5): the
/// page a named destination points at, read through `CGPDFDocument`.
///
/// Every paragraph the op log produced carries a `p-<tag>-<¶id>` anchor into
/// the PDF (`EmissionContract.anchorContract`): a `\hypertarget`, which the
/// typesetter writes as a NAMED destination in the catalog's `/Names /Dests`
/// tree (PDF 1.2+), or — in an older writer — in a `/Dests` dictionary. PDFKit
/// exposes no lookup by name, so this walks the catalog itself.
///
/// Pure and synchronous: the caller runs it off the main actor, once per
/// (publication, piece) — a long book's name tree is thousands of entries.
enum PDFAnchors {

    /// **The page of the first name that resolves**, or nil when none does (a
    /// book compiled before anchors existed, or a piece outside the imprint).
    /// Names are tried in order, so the piece's first anchored paragraph wins.
    static func pageIndex(of names: [String], in document: PDFDocument) -> Int? {
        guard !names.isEmpty, let ref = document.documentRef else { return nil }
        return pageIndex(of: names, in: ref)
    }

    /// The same, with only the file in hand — what the centre calls from a
    /// detached task, so no `PDFDocument` crosses an actor.
    static func pageIndex(of names: [String], inFileAt url: URL) -> Int? {
        guard !names.isEmpty, let ref = CGPDFDocument(url as CFURL) else { return nil }
        return pageIndex(of: names, in: ref)
    }

    /// **A piece's anchor names, in reading order**: `p-<bodyTag>-<¶id>` for
    /// each paragraph of its `sequence`. The name carries no document id (the
    /// contract's own shape), so `docId` only says whose sequence this is.
    static func pieceAnchors(docId: String, bodyTag: String, sequence: [String]) -> [String] {
        sequence.map { "p-\(bodyTag)-\($0)" }
    }

    // MARK: - One walk per book (fix round 1)

    /// **Every paragraph anchor in the book and its page** — every name that
    /// starts `p-`, read in one walk of the name tree (and the legacy
    /// dictionary). The centre reads it once per publication and answers
    /// every click from it. Empty: the book carries no paragraph anchors (it
    /// was compiled before anchors existed).
    static func anchorPages(inFileAt url: URL) -> [String: Int] {
        guard let ref = CGPDFDocument(url as CFURL) else { return [:] }
        return anchorPages(in: ref)
    }

    static func anchorPages(in document: CGPDFDocument) -> [String: Int] {
        guard let catalog = document.catalog else { return [:] }
        var found: [String: CGPDFDictionaryRef] = [:]
        let wants: (String) -> Bool = { $0.hasPrefix("p-") }
        var names: CGPDFDictionaryRef?
        var tree: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
           CGPDFDictionaryGetDictionary(names, "Dests", &tree), let tree {
            collect(tree, wants: wants, into: &found, depth: 0)
        }
        var legacy: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Dests", &legacy), let legacy {
            var context = (wants, [String: CGPDFDictionaryRef]())
            withUnsafeMutablePointer(to: &context) { pointer in
                CGPDFDictionaryApplyFunction(legacy, { key, object, info in
                    guard let info else { return }
                    let box = info.assumingMemoryBound(
                        to: (((String) -> Bool), [String: CGPDFDictionaryRef]).self)
                    let name = String(cString: key)
                    guard box.pointee.0(name), box.pointee.1[name] == nil,
                          let page = PDFAnchors.targetPage(object) else { return }
                    box.pointee.1[name] = page
                }, pointer)
            }
            for (name, page) in context.1 where found[name] == nil { found[name] = page }
        }
        guard !found.isEmpty else { return [:] }
        let pages = pageIndices(of: document)
        return found.compactMapValues { pages[$0] }
    }

    /// The tree walk for `anchorPages`: every leaf pair whose name `wants`.
    private static func collect(_ node: CGPDFDictionaryRef, wants: (String) -> Bool,
                                into found: inout [String: CGPDFDictionaryRef], depth: Int) {
        guard depth < 32 else { return }
        var pairs: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &pairs), let pairs {
            let count = CGPDFArrayGetCount(pairs)
            var index = 0
            while index + 1 < count {
                var key: CGPDFStringRef?
                if CGPDFArrayGetString(pairs, index, &key), let key,
                   let name = CGPDFStringCopyTextString(key) as String?,
                   wants(name), found[name] == nil {
                    var value: CGPDFObjectRef?
                    if CGPDFArrayGetObject(pairs, index + 1, &value), let value,
                       let page = targetPage(value) {
                        found[name] = page
                    }
                }
                index += 2
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for index in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, index, &kid), let kid {
                    collect(kid, wants: wants, into: &found, depth: depth + 1)
                }
            }
        }
    }

    // MARK: - Where a piece starts, unambiguously (fix round 1)

    /// **Where a piece starts in a book**, or why it cannot be said.
    enum Location: Equatable {
        case page(Int)
        /// The book holds no paragraph anchors at all.
        case noAnchors
        /// The book holds anchors, none of them this piece's.
        case notInBook
        /// Its anchors resolve, but none can be trusted to be its own.
        case ambiguous
    }

    /// The body tags a book's anchors carry (`p-<tag>-…`).
    static func tags(in pages: [String: Int]) -> Set<String> {
        // `p-` + tag + `-` + a 4-character ¶id: a tag may hold a hyphen.
        Set(pages.keys.compactMap { name -> String? in
            guard name.hasPrefix("p-"), name.count > 7 else { return nil }
            return String(name.dropFirst(2).dropLast(5))
        })
    }

    /// **The piece's start, from an anchor no other piece shares.** Anchor
    /// names carry no document (`p-<tag>-<¶id>`), and ¶ids are unique only
    /// within a document, so two pieces can share a name and the book keeps
    /// one of them. A name whose ¶id appears in another piece of the book
    /// (`sequences`) is never used; of the rest, the first whose page the
    /// next one corroborates (it starts within two pages after) wins — a lone
    /// unshared anchor stands on its own. Anything else is `.ambiguous`:
    /// nothing is better than the wrong chapter.
    static func locate(piece: String, bodyTag: String, sequences: [String: [String]],
                       pages: [String: Int]) -> Location {
        guard !pages.isEmpty else { return .noAnchors }
        let own = sequences[piece] ?? []
        var elsewhere: Set<String> = []
        for (docId, ids) in sequences where docId != piece { elsewhere.formUnion(ids) }
        let resolved = own.compactMap { id -> (page: Int, shared: Bool)? in
            pages["p-\(bodyTag)-\(id)"].map { ($0, elsewhere.contains(id)) }
        }
        guard !resolved.isEmpty else { return .notInBook }
        let unshared = resolved.filter { !$0.shared }.map(\.page)
        if unshared.count == 1 { return .page(unshared[0]) }
        for (index, page) in unshared.enumerated().dropLast() {
            if (0...2).contains(unshared[index + 1] - page) { return .page(page) }
        }
        return .ambiguous
    }

    // MARK: - The walk

    static func pageIndex(of names: [String], in document: CGPDFDocument) -> Int? {
        let wanted = Set(names)
        let found = destinations(in: document, wanted: wanted)
        guard !found.isEmpty else { return nil }
        let pages = pageIndices(of: document)
        for name in names {
            if let page = found[name], let index = pages[page] { return index }
        }
        return nil
    }

    /// Each wanted name's target page dictionary, from the name tree and the
    /// legacy dictionary alike.
    private static func destinations(in document: CGPDFDocument,
                                     wanted: Set<String>) -> [String: CGPDFDictionaryRef] {
        guard let catalog = document.catalog else { return [:] }
        var found: [String: CGPDFDictionaryRef] = [:]
        var names: CGPDFDictionaryRef?
        var tree: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
           CGPDFDictionaryGetDictionary(names, "Dests", &tree), let tree {
            walk(tree, wanted: wanted, into: &found, depth: 0)
        }
        var legacy: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Dests", &legacy), let legacy {
            for name in wanted where found[name] == nil {
                var object: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(legacy, name, &object), let object,
                   let page = targetPage(object) {
                    found[name] = page
                }
            }
        }
        return found
    }

    /// One node of the name tree: a leaf's `/Names` pairs, or its `/Kids`.
    /// Depth-capped: a malformed tree that cycles stops rather than spins.
    private static func walk(_ node: CGPDFDictionaryRef, wanted: Set<String>,
                             into found: inout [String: CGPDFDictionaryRef], depth: Int) {
        guard depth < 32, found.count < wanted.count else { return }
        var pairs: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &pairs), let pairs {
            let count = CGPDFArrayGetCount(pairs)
            var index = 0
            while index + 1 < count {
                var key: CGPDFStringRef?
                if CGPDFArrayGetString(pairs, index, &key), let key,
                   let name = CGPDFStringCopyTextString(key) as String?,
                   wanted.contains(name), found[name] == nil {
                    var value: CGPDFObjectRef?
                    if CGPDFArrayGetObject(pairs, index + 1, &value), let value,
                       let page = targetPage(value) {
                        found[name] = page
                    }
                }
                index += 2
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for index in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, index, &kid), let kid {
                    walk(kid, wanted: wanted, into: &found, depth: depth + 1)
                }
            }
        }
    }

    /// A destination's page: an explicit array `[page /XYZ …]`, or a
    /// dictionary whose `/D` is one.
    fileprivate static func targetPage(_ object: CGPDFObjectRef) -> CGPDFDictionaryRef? {
        var array: CGPDFArrayRef?
        if CGPDFObjectGetValue(object, .array, &array), let array {
            var page: CGPDFDictionaryRef?
            return CGPDFArrayGetDictionary(array, 0, &page) ? page : nil
        }
        var dictionary: CGPDFDictionaryRef?
        if CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary {
            var d: CGPDFArrayRef?
            var page: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(dictionary, "D", &d), let d,
               CGPDFArrayGetDictionary(d, 0, &page) { return page }
        }
        return nil
    }

    /// Each page's dictionary → its zero-based index. The destination's page
    /// reference resolves to the same object the page tree holds.
    private static func pageIndices(of document: CGPDFDocument) -> [CGPDFDictionaryRef: Int] {
        var indices: [CGPDFDictionaryRef: Int] = [:]
        guard document.numberOfPages > 0 else { return indices }
        for number in 1...document.numberOfPages {
            if let dictionary = document.page(at: number)?.dictionary {
                indices[dictionary] = number - 1
            }
        }
        return indices
    }
}
