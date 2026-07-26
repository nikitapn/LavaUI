// swift-tools-version: 5.10

import PackageDescription

var dependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/moreSwift/swift-cross-ui",
        .upToNextMinor(from: "0.7.0")
    ),
]
var targetDependencies: [Target.Dependency] = [
    .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
    .product(name: "DefaultBackend", package: "swift-cross-ui"),
]

// The Swift Bundler runtime (used for hot reloading) requires Swift >=6.0.
#if compiler(>=6.0)
    dependencies.append(
        .package(
            url: "https://github.com/moreSwift/swift-bundler",
            revision: "496c0638dc2c6750c7873832a08c36c74631aed4"
        )
    )
    targetDependencies.append(
        .product(
            name: "SwiftBundlerRuntime",
            package: "swift-bundler",
            condition: .when(platforms: [.macOS, .linux])
        )
    )
#endif

let package = Package(
    name: "HelloWorld",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .macCatalyst(.v13)],
    dependencies: dependencies,
    targets: [
        .executableTarget(
            name: "HelloWorld",
            dependencies: targetDependencies
        ),
    ]
)
