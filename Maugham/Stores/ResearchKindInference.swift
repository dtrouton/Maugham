import Foundation
import MaughamCore

/// Maps a file extension to a ResearchItem.AssetKind. Returns nil for
/// unknown extensions so importers can skip files they can't preview.
public enum ResearchKindInference {

    public static func kind(forFilename name: String) -> ResearchItem.AssetKind? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if Self.imageExts.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if Self.documentExts.contains(ext) { return .document }
        if Self.audioExts.contains(ext) { return .audio }
        return nil
    }

    private static let imageExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp"
    ]
    private static let documentExts: Set<String> = ["txt", "md", "markdown", "rtf"]
    private static let audioExts: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg"
    ]
}
