// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LearnKeyboard",
    platforms: [.macOS(.v13), .iOS("26.0")],
    products: [.library(name: "KeyboardCore", targets: ["KeyboardCore"]),
               .library(name: "DesktopCore", targets: ["DesktopCore"])],
    targets: [
         .binaryTarget(name: "RimeStatic", path: "Vendor/librime-static.xcframework"),
        .target(name: "CRimeBridge", dependencies: ["RimeStatic"], linkerSettings: [.linkedLibrary("c++")]),
        .target(name: "KeyboardCore", dependencies: ["CRimeBridge"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "KeyboardCoreTests", dependencies: ["KeyboardCore"]),
        .target(name: "DesktopCore", dependencies: ["KeyboardCore"]),
        .testTarget(name: "DesktopCoreTests", dependencies: ["DesktopCore"])
    ]
)
