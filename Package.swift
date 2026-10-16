// swift-tools-version: 6.0
import PackageDescription

// The application is owned by Forky.xcodeproj. Keeping the local package
// library-only avoids ambiguous app-under-test resolution in Xcode.
let package = Package(
    name: "ForkyCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ForkyCore", targets: ["ForkyCore"])],
    targets: [
        .target(name: "ForkyCore"),
        .testTarget(name: "ForkyCoreTests", dependencies: ["ForkyCore"])
    ]
)
