// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PiG",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PiG", targets: ["PiG"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "PiG",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
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
