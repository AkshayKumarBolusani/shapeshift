// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shapeshift",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Shapeshift",
            path: "Sources/Shapeshift",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
