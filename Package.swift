// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASCListing",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ASCListingKit", targets: ["ASCListingKit"]),
        .executable(name: "asc-listing", targets: ["asc-listing"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "ASCListingKit"),
        .target(
            name: "ASCListingCommands",
            dependencies: [
                "ASCListingKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "asc-listing",
            dependencies: ["ASCListingCommands"]
        ),
        .testTarget(
            name: "ASCListingKitTests",
            dependencies: ["ASCListingKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ASCListingCommandsTests",
            dependencies: ["ASCListingCommands", "ASCListingKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
