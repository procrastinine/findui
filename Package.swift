// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FindUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "FindUI",
            targets: ["FindUICLI"]
        ),
        .executable(name: "FindUIApp", targets: ["FindUI"]),
    ],
    targets: [
        .target(name: "SearchCore"),
        .target(name: "SearchBackend", dependencies: ["SearchCore"]),
        .executableTarget(name: "FindUICLI", dependencies: ["SearchBackend"]),
        .executableTarget(name: "FindUI", dependencies: ["SearchBackend"]),
        .testTarget(name: "SearchCoreTests", dependencies: ["SearchCore"]),
        .testTarget(
            name: "FindUITests",
            dependencies: ["FindUI", "SearchBackend"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
