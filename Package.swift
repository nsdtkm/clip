// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Clip", platforms: [.macOS(.v13)], products: [.executable(name: "Clip", targets: ["Clip"])], targets: [
    .systemLibrary(name: "CSQLite"),
    .executableTarget(name: "Clip", dependencies: ["CSQLite"])
])
