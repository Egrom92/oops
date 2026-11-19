// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Oops",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Layouts", linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "Oops", dependencies: ["Layouts"],
                          linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("Carbon")]),
        .executableTarget(name: "LayoutCheck", dependencies: ["Layouts"]),
    ]
)
