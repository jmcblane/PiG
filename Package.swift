// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PiG",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PiG", targets: ["PiG"])
    ],
    targets: [
        .executableTarget(
            name: "PiG",
            path: "Sources/PiG",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        ),
        .testTarget(
            name: "PiGTests",
            dependencies: ["PiG"],
            path: "Tests/PiGTests"
        )
    ]
)
