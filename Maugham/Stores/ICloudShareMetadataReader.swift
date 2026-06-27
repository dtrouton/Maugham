import Foundation
import MaughamCore

/// Mac alias for the shared `FileURLShareMetadataReader` (MaughamCore). The
/// `URLResourceKey` share family it reads is identical on macOS and iOS, so the
/// implementation lives once in MaughamCore and both surfaces consume it — no
/// divergent per-platform reader (cross-surface contract). The historical Mac
/// name is preserved as a typealias so existing call sites stay readable.
typealias ICloudShareMetadataReader = FileURLShareMetadataReader
