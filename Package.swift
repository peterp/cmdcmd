// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "cmdcmd",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "cmdcmd",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
