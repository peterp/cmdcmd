// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "cmdcmd",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "cmdcmd",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
