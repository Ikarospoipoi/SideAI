// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "SideAI", platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.executable(name: "SideAI", targets: ["SideAI"]), .library(name: "SideAIRemote", targets: ["SideAIRemote"])],
  targets: [
    .target(name: "SideAICore"),
    .target(name: "SideAIRemote", path: "shared/SideAIRemote"),
    .executableTarget(name: "SideAI", dependencies: ["SideAICore", "SideAIRemote"]),
    .testTarget(name: "SideAICoreTests", dependencies: ["SideAICore"]),
    .testTarget(name: "SideAIIntegrationTests", dependencies: ["SideAI", "SideAICore", "SideAIRemote"]),
    .testTarget(name: "SideAIRemoteTests", dependencies: ["SideAIRemote"]),
  ])
