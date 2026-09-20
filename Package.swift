// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BetterFind",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "better-find", targets: ["BetterFind"]),
        .executable(name: "better-find-backend", targets: ["BetterFindBackend"]),
        .executable(name: "better-find-benchmark", targets: ["BetterFindBenchmark"])
    ],
    dependencies: [
        .package(path: "Vendor/Yams")
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
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                "BetterFindIPC"
            ]
        ),
        .executableTarget(
            name: "BetterFindBenchmark",
            dependencies: ["ClingSearchCore"]
        )
    ]
)
