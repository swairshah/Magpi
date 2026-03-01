// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Magpi",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Magpi", targets: ["Magpi"]),
    ],
    dependencies: [],
    targets: [
        // C bridging module for ONNX Runtime
        // Run scripts/setup.sh first to download the ONNX Runtime headers + dylib
        .target(
            name: "COnnxRuntime",
            path: "Sources/COnnxRuntime",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../vendor/onnxruntime/include"),
            ]
        ),
        // Main app
        .executableTarget(
            name: "Magpi",
            dependencies: ["COnnxRuntime"],
            path: "Sources/Magpi",
            resources: [
                .copy("Resources"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "vendor/onnxruntime/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../lib",
                ]),
                .linkedLibrary("onnxruntime"),
                // macOS frameworks
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
