// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BrainMenu",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "BrainMenu", targets: ["BrainMenu"]),
        .executable(name: "BrainDictationObserver", targets: ["BrainDictationObserver"]),
    ],
    targets: [
        .executableTarget(name: "BrainMenu"),
        .target(name: "BrainDictationObserverSupport"),
        .executableTarget(
            name: "BrainDictationObserver",
            dependencies: ["BrainDictationObserverSupport"]
        ),
        .testTarget(
            name: "BrainMenuTests",
            dependencies: ["BrainMenu", "BrainDictationObserverSupport"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
