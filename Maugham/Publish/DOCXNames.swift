import Foundation
import CryptoKit
import MaughamCore

/// **Every Word bookmark name the export writes is spelled here** (R-4-3),
/// and nowhere else (`TripwireGrepTests.test_bookmarkNamesAreSpelledInDOCXNamesOnly`).
///
/// Word's rule for a name: ASCII letters, digits and `_`, starting with a
/// letter, at most 40 characters (a leading `_` hides the bookmark). Neither
/// a `¶id` (whose alphabet lets it start with a digit) nor a label name
/// (`-`, unbounded length) is one, so each is mapped:
/// - a paragraph: `p_` plus the `¶id`;
/// - a label: `l_<kind>_<name>`;
/// - a body other than the first (`bodyTag`) adds its tag after the prefix,
///   `p_sr_k3wq`, so two bodies of one document never share a name;
/// - every character outside the rule becomes `_`;
/// - a name over 40 characters keeps its first 31, then `_` and 8 hex digits
///   of the SHA-256 of the UNMAPPED name, so names that differ only past the
///   31st character, or only in `-` against `_`, stay apart.
///
/// The round trip (milestone 3) reads a returned file's paragraph bookmarks
/// back through `paragraphBookmark`, so the mapping is one function. A name
/// that is still taken — two labels equal after mapping, a paragraph that
/// produced several nodes — gets `disambiguated`'s counter from the emitter.
enum DOCXNames {

    /// Word's limit on a bookmark name's length.
    static let maxLength = 40

    /// The bookmark on a node from paragraph `id`, in the first body.
    static func paragraphBookmark(_ id: String) -> String {
        paragraphBookmark(id, bodyTag: nil)
    }

    static func paragraphBookmark(_ id: String, bodyTag: String?) -> String {
        name(["p"] + (bodyTag.map { [$0] } ?? []) + [id])
    }

    /// The bookmark a cross-reference to `label` names, in the first body.
    static func labelBookmark(_ label: ManuscriptLabel) -> String {
        labelBookmark(label, bodyTag: nil)
    }

    static func labelBookmark(_ label: ManuscriptLabel, bodyTag: String?) -> String {
        name(["l"] + (bodyTag.map { [$0] } ?? []) + [label.kind.rawValue, label.name])
    }

    /// `name` made distinct with a counter, `l_fig_a_b_2`, cut so the whole
    /// still fits Word's 40 characters.
    static func disambiguated(_ name: String, counter: Int) -> String {
        let suffix = "_\(counter)"
        return String(name.prefix(maxLength - suffix.count)) + suffix
    }

    /// True when Word accepts `name` as a visible bookmark name.
    static func isLegal(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isLetter(first),
              name.unicodeScalars.count <= maxLength else { return false }
        return name.unicodeScalars.allSatisfy(isNameScalar)
    }

    // MARK: - the mapping

    private static func name(_ parts: [String]) -> String {
        let raw = parts.joined(separator: "_")
        var mapped = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars { mapped.append(isNameScalar(scalar) ? scalar : "_") }
        let legal = String(mapped)
        guard legal.unicodeScalars.count > maxLength else { return legal }
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return String(legal.prefix(31)) + "_" + hex
    }

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s)
    }

    private static func isNameScalar(_ s: Unicode.Scalar) -> Bool {
        isLetter(s) || ("0"..."9").contains(s) || s == "_"
    }
}
