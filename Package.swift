// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClamOpen",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "ClamCore"),
        .executableTarget(
            name: "ClamOpen",
            dependencies: ["ClamCore"],
            path: "Sources/ClamOpen"
        ),
        // 独立急救工具：恢复（启用）内置屏，不依赖主程序
        .executableTarget(
            name: "ClamRestore",
            dependencies: ["ClamCore"],
            path: "Sources/ClamRestore"
        ),
        .testTarget(name: "ClamCoreTests", dependencies: ["ClamCore"])
    ]
)
