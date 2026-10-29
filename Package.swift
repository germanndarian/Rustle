// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rustle",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Rustle",
            path: "Sources/Rustle",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SpriteKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
