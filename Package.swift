// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BetterFind",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "better-find", targets: ["BetterFind"]),
        .executable(name: "better-find-backend", targets: ["BetterFindBackend"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
    ],
    targets: [
        .target(name: "BetterFindIPC"),
        .target(name: "ClingSearchCore"),
        .executableTarget(
            name: "BetterFindBackend",
            dependencies: ["BetterFindIPC", "ClingSearchCore"]
        ),
        .executableTarget(
            name: "BetterFind",
            dependencies: ["Yams", "BetterFindIPC"]
        )
    ]
)
