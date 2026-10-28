// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "KongFolio", platforms: [.macOS(.v14)], products: [.executable(name: "KongFolio", targets: ["KongFolio"])], targets: [.executableTarget(name: "KongFolio"), .testTarget(name: "KongFolioTests", dependencies: ["KongFolio"]), .testTarget(name: "KongFolioUITests", dependencies: ["KongFolio"])])
