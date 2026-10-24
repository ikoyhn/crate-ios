// swift-tools-version: 6.0
// CrateKit: everything the app does that isn't UI or audio. Models, the Crate API client and a small
// Subsonic client for Navidrome. Foundation only, so it builds and tests on Linux too.
import PackageDescription

let package = Package(
    name: "CrateKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CrateKit", targets: ["CrateKit"])],
    targets: [
        .target(name: "CrateKit"),
        .testTarget(name: "CrateKitTests", dependencies: ["CrateKit"]),
    ],
    swiftLanguageModes: [.v6]
)
