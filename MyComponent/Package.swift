// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MyComponent",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MyComponent",
            targets: ["MyComponent"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "MyComponent",
            dependencies: ["Helpers"]
        ),
        .target(
            name: "Helpers",
            path: "Sources/Helpers",            // 指定 OC target 的根目录
            sources: ["src"],                   // 只编译 src/ 下的 .m 文件
            publicHeadersPath: "include"        // 公开头文件目录
        ),
        .testTarget(
            name: "MyComponentTests",
            dependencies: ["MyComponent"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
