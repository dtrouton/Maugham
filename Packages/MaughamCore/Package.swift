// swift-tools-version: 5.10
import PackageDescription

// MaughamCore — the Foundation-only substrate shared by the macOS app (Maugham)
// and the iOS companion (MaughamPhone). Houses the op-log types, JSONL store,
// annotation derivation, paragraph/Fountain parsing, and the shared model types.
// AppKit/SwiftUI-bound code stays in the app targets; nothing here imports a UI
// framework. See docs/superpowers/specs/2026-05-24-iphone-companion-v1-design.md §3.1.
let package = Package(
    name: "MaughamCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MaughamCore", targets: ["MaughamCore"]),
    ],
    targets: [
        .target(
            name: "MaughamCore",
            // BuildVariant.current keys on this flag. The app target sets it in its
            // Debug config (SWIFT_ACTIVE_COMPILATION_CONDITIONS); mirror it here so
            // the variant stays .dev in Debug/test builds and .stable in Release —
            // otherwise the flag is never set inside the package and current is
            // always .stable. See CLAUDE.md tripwire 13. (BuildVariantTests guards this.)
            swiftSettings: [.define("MAUGHAM_DEV_BUILD", .when(configuration: .debug))]
        ),
        .testTarget(name: "MaughamCoreTests", dependencies: ["MaughamCore"]),
    ]
)
