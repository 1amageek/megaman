// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "megaman",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.120.0"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", from: "0.50.2"),
        .package(path: "/Users/1amageek/Desktop/CoreFoundation/OpenSpriteKit"),
        .package(path: "/Users/1amageek/Desktop/CoreFoundation/OpenCoreGraphics"),
        .package(path: "/Users/1amageek/Desktop/CoreFoundation/OpenCoreAnimation"),
        .package(path: "/Users/1amageek/Desktop/CoreFoundation/OpenCoreImage"),
        .package(path: "/Users/1amageek/Desktop/CoreFoundation/OpenImageIO"),
    ],
    targets: [
        // WASM App - Your Swift code compiled to WebAssembly
        .executableTarget(
            name: "WasmApp",
            dependencies: [
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
                .product(name: "OpenSpriteKit", package: "OpenSpriteKit"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    // JavaScriptKit only binds against WASI-reactor modules
                    // (has `_initialize`, no `_start`). wasmport passes this
                    // at the command line; encode it here so any plain
                    // `swift build --product WasmApp` also produces a
                    // JavaScriptKit-compatible artifact.
                    "-Xclang-linker", "-mexec-model=reactor",
                    "-Xlinker", "--export=setup",
                    "-Xlinker", "--export=getCanvasWidth",
                    "-Xlinker", "--export=getCanvasHeight",
                ])
            ]
        ),
        // Development Server - Builds WASM and serves to browser
        .executableTarget(
            name: "Server",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
    ]
)