import Foundation

/// The helpers every report parser shares: finding the answer object in a
/// turn's text, reading a list all-or-nothing, and reading a string that has
/// something in it. `DiagnosticIngest`, `TranslatorReport` and
/// `DesignerReport` each carried a private copy "owing the others no
/// dependency"; a neutral helper is not a dependency on another contract, and
/// the fourth copy is where the duplication stopped earning its keep.
enum ReportJSON {

    /// A `String` value with something in it, TRIMMED — whitespace around a
    /// model's answer is an artifact of how it wrote its JSON, not of the prose.
    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A closed wire enum's value, or nil for anything not in the enum.
    static func enumValue<E: RawRepresentable>(_ value: Any?, as: E.Type) -> E?
    where E.RawValue == String {
        guard let raw = nonEmptyString(value) else { return nil }
        return E(rawValue: raw)
    }

    /// A key that is absent reads as an empty list; a key present with the
    /// wrong shape, or any one element `parseItem` refuses, fails the list.
    static func parseList<T>(
        _ container: [String: Any], key: String, parseItem: ([String: Any]) -> T?
    ) -> [T]? {
        guard let value = container[key] else { return [] }
        guard let raw = value as? [Any] else { return nil }
        var results: [T] = []
        results.reserveCapacity(raw.count)
        for element in raw {
            guard let item = element as? [String: Any], let parsed = parseItem(item) else {
                return nil
            }
            results.append(parsed)
        }
        return results
    }

    /// The LAST complete top-level JSON object in `raw` carrying any of `keys`
    /// — a model that reasons in prose puts worked examples earlier and the
    /// real answer last (`TranslatorReport`'s reasoning, unchanged).
    static func lastObject(in raw: String, shapedBy keys: [String]) -> [String: Any]? {
        for span in objectSpans(in: raw).reversed() {
            guard let data = span.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  keys.contains(where: { dictionary[$0] != nil })
            else { continue }
            return dictionary
        }
        return nil
    }

    /// Every top-level `{...}` span in `text`, brace-balanced and string-aware.
    static func objectSpans(in text: String) -> [String] {
        var spans: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let opening = start {
                    spans.append(String(text[opening...index]))
                    start = nil
                }
            default:
                break
            }
        }
        return spans
    }
}
