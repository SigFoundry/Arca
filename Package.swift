// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Arca",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Arca", targets: ["Arca"])
    ],
    targets: [
        .executableTarget(
            name: "Arca",
            path: "Sources/Arca",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
