// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "SideAI", platforms: [.macOS(.v14)],
  products: [.executable(name: "SideAI", targets: ["SideAI"])],
  targets: [
    .target(name: "SideAICore"),
    .executableTarget(name: "SideAI", dependencies: ["SideAICore"]),
    .testTarget(name: "SideAICoreTests", dependencies: ["SideAICore"]),
    .testTarget(name: "SideAIIntegrationTests", dependencies: ["SideAI", "SideAICore"]),
  ])
