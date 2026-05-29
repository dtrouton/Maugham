import Foundation

/// RFC 7396 JSON Merge Patch.
///
/// - Object keys in the patch with null values are DELETED from the target.
/// - Object keys with object values are MERGED recursively.
/// - All other values (scalars, arrays) REPLACE the target's value.
public enum JSONMergePatch {

    public enum Error: Swift.Error {
        case invalidJSON
    }

    public static func apply(patch: Data, to target: Data) throws -> Data {
        let patchJSON  = try JSONSerialization.jsonObject(with: patch)
        let targetJSON = try JSONSerialization.jsonObject(with: target)
        let merged = mergeAny(target: targetJSON, patch: patchJSON)
        guard let merged else {
            return try JSONSerialization.data(
                withJSONObject: NSDictionary(),
                options: [.sortedKeys])
        }
        return try JSONSerialization.data(
            withJSONObject: merged, options: [.sortedKeys])
    }

    private static func mergeAny(target: Any, patch: Any) -> Any? {
        // If patch is an object, do the merge dance per RFC.
        if let patchDict = patch as? [String: Any] {
            var result: [String: Any] = (target as? [String: Any]) ?? [:]
            for (key, value) in patchDict {
                if value is NSNull {
                    result.removeValue(forKey: key)
                } else if let existing = result[key],
                          let merged = mergeAny(target: existing, patch: value) {
                    result[key] = merged
                } else {
                    // Either no existing value, or merge returned nil from a
                    // top-level null. We only get nil when patch IS NSNull,
                    // already handled above, so this branch installs `value`.
                    result[key] = value
                }
            }
            return result
        }
        // Patch is null at the top level: signal delete.
        if patch is NSNull {
            return nil
        }
        // Patch is any non-object non-null value: replace.
        return patch
    }
}
