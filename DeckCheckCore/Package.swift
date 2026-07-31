// swift-tools-version: 5.9
import PackageDescription

// The shared, platform-independent query-core for deckcheck (spec §7.3 search
// and §7.4 decklist gap-check share this core), plus a SQLite-backed CatalogLookup
// over the tools/build-catalog snapshot and a `gapcheck` CLI that runs the whole pipeline
// against a real catalog from the laptop.
//
// DeckCheckCore + DeckCheckSQLite are pure library targets the SwiftUI app
// adds as a local package dependency; `gapcheck` is a host (macOS) executable.
let package = Package(
    name: "DeckCheckCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "DeckCheckCore", targets: ["DeckCheckCore"]),
        .library(name: "DeckCheckSQLite", targets: ["DeckCheckSQLite"]),
        .executable(name: "gapcheck", targets: ["gapcheck"]),
    ],
    targets: [
        .target(
            name: "DeckCheckCore",
            resources: [.copy("Resources")]
        ),
        .target(name: "DeckCheckSQLite", dependencies: ["DeckCheckCore"]),
        .executableTarget(
            name: "gapcheck",
            dependencies: ["DeckCheckCore", "DeckCheckSQLite"]
        ),
        .testTarget(name: "DeckCheckCoreTests", dependencies: ["DeckCheckCore"]),
        .testTarget(name: "DeckCheckSQLiteTests", dependencies: ["DeckCheckSQLite"]),
    ]
)
