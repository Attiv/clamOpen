// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClamOpen",
    platforms: [.macOS(.v12)],
    targets: [
        // 可测试的核心逻辑：显示器控制、状态机、电源管理、本地化
        .target(
            name: "ClamOpenCore",
            path: "Sources/ClamOpenCore"
        ),
        .executableTarget(
            name: "ClamOpen",
            dependencies: ["ClamOpenCore"],
            path: "Sources/ClamOpen"
        ),
        // 独立急救工具：恢复（启用）内置屏，不依赖主程序
        .executableTarget(
            name: "ClamRestore",
            path: "Sources/ClamRestore"
        ),
        .testTarget(
            name: "ClamOpenCoreTests",
            dependencies: ["ClamOpenCore"],
            path: "Tests/ClamOpenCoreTests"
        )
    ]
)
