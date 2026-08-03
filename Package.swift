// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "patchthrough",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Exact pins, not ranges. Two reasons:
        //
        // Correctness: `from: "0.7.0"` had silently resolved to 0.15.5, and
        // pre-1.0 minor bumps are breaking by convention. patchthrough calls
        // FluidAudio's `buildWordTimings` free function directly.
        //
        // Supply chain: with a range, a future `swift package update` can pull
        // code nobody reviewed and compile it into a binary that records your
        // meetings. An upstream Package.swift edit can trigger the same
        // resolution. An exact pin plus the committed Package.resolved keeps
        // the build reproducible. Any change to a dependency then shows up as
        // a reviewable diff instead of a silent fetch. See
        // packaging/verify-deps.sh.
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "patchthrough",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the binary so TCC can attribute the
                // system-audio-capture permission to patchthrough itself when it
                // runs as a LaunchAgent (no .app bundle to carry a plist).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/patchthrough/Info.plist",
                ]),
            ]
        ),
    ]
)
