// swift-tools-version: 5.10
import PackageDescription

// ExperimentTests — a STANDALONE package holding the specification-mining
// experiment's generated tests. Deliberately separate from MaughamCore's own
// test target so nothing in the shipping build depends on it and nothing here
// can perturb the shipping suite. Run with:
//   swift test --package-path register/ExperimentTests
let package = Package(
    name: "ExperimentTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/MaughamCore")],
    targets: [
        .testTarget(name: "ExperimentTests", dependencies: [.product(name: "MaughamCore", package: "MaughamCore")]),
    ]
)
