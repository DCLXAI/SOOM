// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SOOM",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ShowTellCore", targets: ["ShowTellCore"]),
        .library(name: "ShowTellShare", targets: ["ShowTellShare"]),
        .executable(name: "SOOM", targets: ["ShowTellApp"])
    ],
    targets: [
        .target(
            name: "ShowTellCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ShowTellShare",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ShowTellApp",
            dependencies: ["ShowTellCore", "ShowTellShare"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "ShowTellCoreTests",
            dependencies: ["ShowTellCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .linkedFramework("Testing"),
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "ShowTellShareTests",
            dependencies: ["ShowTellShare"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .linkedFramework("Testing"),
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ]
        )
    ]
)
