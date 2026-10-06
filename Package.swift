// swift-tools-version:5.9
// Builds the Mac menu bar app. The iPhone app is the Xcode project from project.yml.
import PackageDescription

let package = Package(
    name: "Plummy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PlummyMac", targets: ["PlummyMac"]),
    ],
    targets: [
        .target(name: "PlummyShared", path: "Shared", exclude: ["Fonts"]),
        .executableTarget(
            name: "PlummyMac",
            dependencies: ["PlummyShared"],
            path: "Mac/Sources/PlummyMac"
        ),
    ]
)
