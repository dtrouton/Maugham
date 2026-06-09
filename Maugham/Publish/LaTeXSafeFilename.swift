import Foundation

/// A type-safe wrapper for a LaTeX `\input{}` filename argument.
///
/// The `\input{pieces/<filename>}` call in `LaTeXBodyEmitter` interpolates the
/// style-file name directly into the TeX source. Without validation, a value
/// like `}...\input{/etc/passwd}%` closes the argument, injects arbitrary TeX,
/// and comments out the rest of the line — a classic TeX-argument injection.
///
/// `LaTeXSafeFilename` enforces an allowlist at construction time so that an
/// unsafe string can **never** reach the emitter:
///
///   Allowed: `[A-Za-z0-9]`, `-`, `_`, `.`
///   Rejected: TeX specials (`{}%$#&~^\`), path separators (`/`),
///             `..` as a substring (parent-directory traversal), null bytes,
///             and the empty string.
///
/// Use `LaTeXSafeFilename(string)` — returns `nil` for any rejected input.
/// Use `.rawValue` to recover the underlying string for interpolation.
public struct LaTeXSafeFilename: Equatable, Sendable {
    public let rawValue: String

    /// Failable initialiser. Returns `nil` when `string` contains any
    /// disallowed character or pattern.
    public init?(_ string: String) {
        guard Self.isValid(string) else { return nil }
        self.rawValue = string
    }

    // MARK: - Validation

    /// Returns `true` only when `string` is a safe LaTeX filename argument.
    public static func isValid(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        guard !string.contains("\0") else { return false }
        // Reject parent-directory traversal (substring check is sufficient:
        // even `..` inside `foo..bar` is harmless, but `..` as a component
        // e.g. `../escape` or `dir/..` would traverse — easier to ban the
        // substring outright given filenames never need it).
        guard !string.contains("..") else { return false }
        // Allowlist: alphanumerics, hyphen, underscore, dot.
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_."))
        guard string.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
        return true
    }
}
