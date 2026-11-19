// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PowerLevel",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PowerLevel", targets: ["PowerLevel"])
    ],
    targets: [
        .executableTarget(
            name: "PowerLevel",
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
