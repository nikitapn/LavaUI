// swift-tools-version: 6.2
// The LavaUI documentation site: pages rendered in-process by an NPRPC page
// handler from the api.json that `scripts/docs-api.sh` produces. The site
// itself is the NPRPC one (nprpc/docs/site) with LavaUI's name on it.
import Foundation
import PackageDescription

// NPRPC's Swift package: the prebuilt copy in the nprpc-dev image, which sets
// NPRPC_SWIFT_ROOT=/opt/nprpc_swift, else the same places the main manifest
// looks — a clone at third-party/nprpc, then a sibling checkout at ../nprpc.
let nprpcSwift: String = {
  if let root = Context.environment["NPRPC_SWIFT_ROOT"] { return root }
  let candidates = ["../../third-party/nprpc/nprpc_swift", "../../../nprpc/nprpc_swift"]
  let here = Context.packageDirectory
  return candidates.first {
    FileManager.default.fileExists(atPath: here + "/" + $0 + "/Package.swift")
  } ?? candidates[1]
}()

let package = Package(
  name: "docs-site",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(path: nprpcSwift),
  ],
  targets: [
    // api.json -> an index of pages, links and search. No NPRPC, no
    // templates, so it is testable on its own.
    .target(name: "DocsModel", path: "Sources/DocsModel"),
    .target(
      name: "DocsWeb",
      dependencies: [
        "DocsModel",
        .product(name: "NPRPC", package: "nprpc_swift"),
        .product(name: "NPRPCWeb", package: "nprpc_swift"),
      ],
      path: "Sources/DocsWeb",
      swiftSettings: [.interoperabilityMode(.Cxx)]),
    .executableTarget(
      name: "docs-server",
      dependencies: ["DocsWeb", .product(name: "NPRPC", package: "nprpc_swift")],
      path: "Sources/docs-server",
      swiftSettings: [.interoperabilityMode(.Cxx)]),
    .testTarget(
      name: "DocsModelTests",
      dependencies: ["DocsModel"],
      path: "Tests/DocsModelTests"),
  ]
)
