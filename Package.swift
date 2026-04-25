// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "yondery",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "yondery",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
