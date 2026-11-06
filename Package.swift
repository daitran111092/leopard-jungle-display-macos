// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LJDisplay",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LJCore"),
        .target(name: "LJSources", dependencies: ["LJCore"]),
        // libjpeg-turbo from Homebrew (`brew install jpeg-turbo`), linked statically so the app runs without it.
        .systemLibrary(name: "CTurboJPEG", path: "Sources/CTurboJPEG"),
        .target(name: "LJUI", dependencies: ["LJCore", "CTurboJPEG"], resources: [.copy("Resources")],
                linkerSettings: [.unsafeFlags(["/opt/homebrew/opt/jpeg-turbo/lib/libturbojpeg.a"])]),
        // Shared live-dashboard wiring (PanelLink, sources → store → frame loop, sleep/wake) for the app and `ljprobe stream`.
        .target(name: "LJApp", dependencies: ["LJCore", "LJSources", "LJUI"]),
        .executableTarget(name: "LJDisplay", dependencies: ["LJCore", "LJApp", "LJUI"]),
        .executableTarget(name: "ljprobe", dependencies: ["LJCore", "LJSources", "LJUI", "LJApp"]),
        .testTarget(name: "LJCoreTests", dependencies: ["LJCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LJSourcesTests", dependencies: ["LJSources", "LJCore"]),
        .testTarget(name: "LJUITests", dependencies: ["LJUI", "LJCore"]),
        .testTarget(name: "LJAppTests", dependencies: ["LJApp", "LJCore"]),
    ]
)
