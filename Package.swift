// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacTidy",
    platforms: [.macOS(.v14)],
    targets: [
        // Gọi framework riêng MenuBarClientCore của macOS 27 (ẩn icon thanh menu theo danh sách cho phép)
        .target(name: "MBShim", path: "Sources/MBShim", publicHeadersPath: "include"),
        .executableTarget(name: "MacTidy", dependencies: ["MBShim"], path: "Sources/MacTidy")
    ]
)
