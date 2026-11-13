// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LayoutConverter",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Layouts", linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "LayoutConverter", dependencies: ["Layouts"],
                          linkerSettings: [.linkedFramework("ServiceManagement")]),
        .executableTarget(name: "LayoutCheck", dependencies: ["Layouts"]),
    ]
)
