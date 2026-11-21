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
    private static func targetPage(_ object: CGPDFObjectRef) -> CGPDFDictionaryRef? {
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
