// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "Recorder", platforms: [.macOS(.v14)], products: [.executable(name: "Recorder", targets: ["Recorder"])], dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1")], targets: [.executableTarget(name: "Recorder", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]), .testTarget(name: "RecorderTests", dependencies: ["Recorder"])])
