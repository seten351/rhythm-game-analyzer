// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OurNotesAnalyzer",
    platforms: [.macOS("26.4")],
    products: [.library(name: "ResultCore", targets: ["ResultCore"]), .executable(name: "OurNotesAnalyzer", targets: ["OurNotesApp"])],
    targets: [
        .target(name: "ResultCore"),
        .executableTarget(name: "OurNotesApp", dependencies: ["ResultCore"], resources: [.copy("Resources")]),
        .testTarget(name: "ResultCoreTests", dependencies: ["ResultCore"]),
        .testTarget(name: "OurNotesAppTests", dependencies: ["OurNotesApp", "ResultCore"])
    ]
)
