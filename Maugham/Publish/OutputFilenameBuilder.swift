import Foundation

/// Shared `{title}-v{version}{label_suffix}.{ext}` interpolation for
/// PDFCompiler and EPUBCompiler.
///
/// Title sanitization splits into two passes:
/// 1. **Always** strips characters that produce broken or unsafe macOS
///    filenames: `/` (path separator), `\0` (null), and leading `.`
///    (creates a hidden file the writer can't see in Finder). These are
///    enforced regardless of `sanitize_spaces` because the result of
///    NOT enforcing them is an unusable Exports/ entry, not a stylistic
///    preference.
/// 2. **Optional** spaces → hyphens, governed by `config.outputs.sanitize_spaces`.
///    That's a cosmetic choice the writer owns.
enum OutputFilenameBuilder {

    static func make(
        config: PublishConfig,
        format: PublishConfig.Format,
        label: String?,
        language: String?
    ) -> String {
        var title = sanitizeForFilesystem(config.metadata.title)
        if config.outputs.sanitizeSpaces {
            title = title.replacingOccurrences(of: " ", with: "-")
        }
        let labelSuffix = label.map { "-\(sanitizeForFilesystem($0))" } ?? ""
        let template = config.outputs.filenameTemplate

        // F7 residue: when {language} expands empty (source-language
        // compile), a separator immediately preceding the token would
        // otherwise dangle (e.g. "T-v0.1-.pdf"). Strip EXACTLY ONE `-`/`_`/`.`
        // right before each token occurrence before the generic replacement
        // runs. A token with no preceding separator falls through to the plain
        // empty replacement below, unchanged from today. When language IS
        // present, the separator is meaningful and stays. (M1: single-pass
        // per-occurrence strip — the old sequential replace-all cascaded on a
        // doubled-separator template like "{title}._{language}.{ext}",
        // removing both separators instead of one.)
        var workingTemplate = template
        if language == nil || language?.isEmpty == true {
            workingTemplate = stripOneSeparatorBefore(
                token: "{language}", in: template)
        }

        var name = workingTemplate
            .replacingOccurrences(of: "{title}",        with: title)
            .replacingOccurrences(of: "{version}",      with: config.nextVersion)
            .replacingOccurrences(of: "{label_suffix}", with: labelSuffix)
            .replacingOccurrences(of: "{language}",     with: language ?? "")
            .replacingOccurrences(of: "{ext}",          with: format.rawValue)

        // Collision guard: if a language edition was requested but the template
        // has no {language} token, insert -<lang> before the extension so the
        // translated edition can't silently overwrite the source-language file.
        if let language, !template.contains("{language}") {
            let ext = ".\(format.rawValue)"
            if name.hasSuffix(ext) {
                name = "\(name.dropLast(ext.count))-\(language)\(ext)"
            } else {
                name += "-\(language)"
            }
        }
        return name
    }

    /// Strip a single `-`/`_`/`.` immediately preceding each occurrence of
    /// `token`, leaving any earlier separators intact. Spec: drop exactly ONE
    /// dangling separator per token, never cascade across a doubled separator.
    private static func stripOneSeparatorBefore(
        token: String, in template: String
    ) -> String {
        let separators: Set<Character> = ["-", "_", "."]
        var result = ""
        var remainder = Substring(template)
        while let range = remainder.range(of: token) {
            var prefix = remainder[remainder.startIndex..<range.lowerBound]
            if let last = prefix.last, separators.contains(last) {
                prefix = prefix.dropLast()
            }
            result += prefix
            result += token
            remainder = remainder[range.upperBound...]
        }
        result += remainder
        return result
    }

    /// Always-on sanitization: strip path separators, null bytes, and any
    /// leading dots. Other control chars are also stripped (Unicode
    /// categories `C` — formatting/control).
    static func sanitizeForFilesystem(_ input: String) -> String {
        var s = input
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\0", with: "")
        // Drop any leading dots so the file isn't hidden on macOS.
        while s.hasPrefix(".") { s.removeFirst() }
        // Strip control characters (anything in Unicode general category C).
        s = String(s.unicodeScalars.filter { !$0.properties.generalCategory.isControl })
        return s
    }
}

private extension Unicode.GeneralCategory {
    var isControl: Bool {
        switch self {
        case .control, .format, .privateUse, .surrogate, .unassigned: return true
        default: return false
        }
    }
}
