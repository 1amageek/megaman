// Development Server for megaman
// This file is auto-generated. Usually no edits needed.
//
// When you run with Cmd+R:
// 1. Build WasmApp to WASM
// 2. Start Vapor server
// 3. Open browser

import Vapor
import Foundation

@main
struct DemoServer {
    static func main() async throws {
        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let wasmDir = projectDir.appending(path: ".build/wasmport/wasm")
        let assetsDir = projectDir.appending(path: "Public/assets")

        // Ensure wasm directory exists
        try? FileManager.default.createDirectory(at: wasmDir, withIntermediateDirectories: true)

        // Step 1: Build WasmApp to WASM
        print("")
        print("=========================================")
        print("  Building WasmApp to WASM...")
        print("=========================================")

        do {
            try await buildWasm(projectDir: projectDir, outputDir: wasmDir)
            print("  ✓ WASM build complete")
        } catch let error as ServerError {
            switch error {
            case .wasmSdkNotFound:
                print("  ✗ WASM SDK not found")
                print("  Install with: swift sdk install https://github.com/aspect-build/aspect-swift-wasm-sdk/releases/download/6.2.3-1.0.1-release/swift-6.2.3-RELEASE-wasm.artifactbundle.zip")
            case .buildFailed(let output):
                print("  ✗ WASM build failed:")
                print(output)
            }
            print("")
            print("  Run manually: swift build --product WasmApp --swift-sdk <sdk-name> -c release")
            print("  Then copy: .build/wasm32-unknown-wasip1/release/WasmApp.wasm -> .build/wasmport/wasm/")
        } catch {
            print("  ✗ WASM build failed: \(error)")
        }

        // Step 2: Generate assets
        generateAssets(projectName: "megaman", outputDir: wasmDir)

        // Step 3: Check port availability before starting
        let targetPort = 8080
        if let existingPid = findProcessOnPort(targetPort) {
            print("")
            print("  ⚠️  Port \(targetPort) is already in use by process \(existingPid)")
            print("  Attempting to stop existing server...")

            if killProcess(pid: existingPid) {
                print("  ✓ Stopped existing server")
                // Wait a moment for port to be released
                try? await Task.sleep(nanoseconds: 500_000_000)
            } else {
                print("  ✗ Could not stop existing server")
                print("")
                print("  Run manually: kill -9 \(existingPid)")
                return
            }
        }

        // Start Vapor server
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        defer { Task { try? await app.asyncShutdown() } }

        // Configure server
        app.http.server.configuration.port = targetPort
        app.http.server.configuration.hostname = "0.0.0.0"

        // Routes
        app.get { req in
            req.redirect(to: "/wasm/index.html")
        }

        app.get("health") { _ in "OK" }

        app.get("wasm", "**") { req -> Response in
            let pathComponents = req.parameters.getCatchall()
            let relativePath = pathComponents.isEmpty ? "index.html" : pathComponents.joined(separator: "/")
            let filePath = wasmDir.appending(path: relativePath)

            guard FileManager.default.fileExists(atPath: filePath.path) else {
                throw Abort(.notFound, reason: "File not found: \(relativePath)")
            }

            let data = try Data(contentsOf: filePath)
            var headers = HTTPHeaders()

            let ext = filePath.pathExtension.lowercased()
            headers.add(name: .contentType, value: contentType(for: ext))
            headers.add(name: .accessControlAllowOrigin, value: "*")
            headers.add(name: .cacheControl, value: "no-cache")

            return Response(status: .ok, headers: headers, body: .init(data: data))
        }

        // Static asset route — serves Public/assets/** so the WASM app can fetch
        // sprite PNG and Aseprite JSON via JavaScriptKit fetch().
        app.get("assets", "**") { req -> Response in
            let pathComponents = req.parameters.getCatchall()
            guard !pathComponents.isEmpty else {
                throw Abort(.notFound, reason: "Empty asset path")
            }
            let relativePath = pathComponents.joined(separator: "/")
            // Reject path traversal.
            guard !relativePath.contains("..") else {
                throw Abort(.badRequest, reason: "Invalid asset path")
            }
            let filePath = assetsDir.appending(path: relativePath)

            guard FileManager.default.fileExists(atPath: filePath.path) else {
                throw Abort(.notFound, reason: "Asset not found: \(relativePath)")
            }

            let data = try Data(contentsOf: filePath)
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: contentType(for: filePath.pathExtension.lowercased()))
            headers.add(name: .accessControlAllowOrigin, value: "*")
            headers.add(name: .cacheControl, value: "no-cache")
            return Response(status: .ok, headers: headers, body: .init(data: data))
        }

        print("")
        print("=========================================")
        print("  megaman Development Server")
        print("=========================================")
        print("  URL: http://localhost:\(targetPort)")
        print("  Wasm: \(wasmDir.path)")
        print("=========================================")
        print("")

        let shouldOpenBrowser = CommandLine.arguments.contains("--open-browser")
            && !CommandLine.arguments.contains("--no-browser")

        if shouldOpenBrowser {
            // Open browser after short delay
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                openBrowser(port: targetPort)
            }
        } else {
            print("  Browser auto-open disabled. Open http://localhost:\(targetPort)/wasm/index.html")
        }

        do {
            try await app.execute()
        } catch {
            let errorMessage = "\(error)"
            if errorMessage.contains("Address already in use") || errorMessage.contains("errno: 48") {
                print("")
                print("  ✗ Failed to start server: Port \(targetPort) is still in use")
                print("")
                print("  Try one of the following:")
                print("  1. Wait a moment and try again")
                print("  2. Find and kill the process: lsof -i :\(targetPort) | xargs kill -9")
            } else {
                print("")
                print("  ✗ Server error: \(error)")
            }
        }
    }

    static func contentType(for ext: String) -> String {
        switch ext {
        case "wasm": return "application/wasm"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "html": return "text/html; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    static func openBrowser(port: Int) {
        #if os(macOS)
        let url = "http://localhost:\(port)"

        // Try Google Chrome first — the E2E path and WebGPU flag expectations
        // assume Chromium-family. `open -a` fails with non-zero status if the
        // app is not installed, so we can detect that and fall back.
        let chrome = Process()
        chrome.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        chrome.arguments = ["-a", "Google Chrome", url]
        chrome.standardOutput = Pipe()
        chrome.standardError = Pipe()
        do {
            try chrome.run()
            chrome.waitUntilExit()
            if chrome.terminationStatus == 0 { return }
        } catch {
            // Fall through to default browser.
        }

        // Fallback: default browser.
        let fallback = Process()
        fallback.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        fallback.arguments = [url]
        try? fallback.run()
        #endif
    }

    // Find Swift executable with WASM SDK support.
    //
    // The WASM SDK needs more than just `swift sdk list` reporting the SDK —
    // clang must also support the `wasm32-unknown-wasip1` target, otherwise
    // the build fails with
    //    "unable to create target: 'No available targets are compatible ...'"
    //
    // In practice this means the **open-source Swift toolchain** is required;
    // Xcode's bundled clang does not ship WASI target support. The correct
    // binary for a swiftly-managed install lives at
    //    ~/Library/Developer/Toolchains/swift-<ver>-RELEASE.xctoolchain/usr/bin/swift
    //
    // Candidate ordering:
    //   1. ~/Library/Developer/Toolchains/*.xctoolchain — swiftly-installed
    //      open-source toolchains, newest-version first.
    //   2. Homebrew (/opt/homebrew, /usr/local) — open-source installs.
    //   3. ~/.swiftly/bin/swift — the swiftly proxy. Trips
    //      "Circular swiftly proxy invocation" when spawned as a subprocess
    //      with an already-proxied environment, so keep it last.
    //   4. xcrun-resolved swift (Xcode). Listed last because WASM usually
    //      fails at clang on stock Xcode, but kept as a best-effort fallback.
    static func findSwiftWithWasmSupport() -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []

        candidates.append(contentsOf: swiftlyInstalledToolchains(homeDir: homeDir))

        candidates.append(contentsOf: [
            "/opt/homebrew/bin/swift",
            "/usr/local/bin/swift",
        ])

        candidates.append("\(homeDir)/.swiftly/bin/swift")

        if let xcrunResolved = resolveSwiftViaXcrun() {
            candidates.append(xcrunResolved)
        }

        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: candidate)
            process.arguments = ["sdk", "list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                guard process.terminationStatus == 0 else { continue }
                if output.lowercased().contains("wasm") {
                    return candidate
                }
            } catch {
                continue
            }
        }
        return nil
    }

    // Enumerate swiftly-installed open-source toolchains under
    // ~/Library/Developer/Toolchains, newest first. Returns absolute paths
    // to the `swift` binary inside each xctoolchain.
    private static func swiftlyInstalledToolchains(homeDir: String) -> [String] {
        let root = "\(homeDir)/Library/Developer/Toolchains"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }

        let bundles = entries.filter { $0.hasSuffix(".xctoolchain") && $0 != "swift-latest.xctoolchain" }
        let sorted = bundles.sorted(by: >)  // Lexicographic sort handles "swift-6.3.1" > "swift-6.2.3".

        return sorted.map { "\(root)/\($0)/usr/bin/swift" }
    }

    // Use xcrun to discover the currently active swift toolchain on macOS.
    // Returns the absolute path to `swift`, or nil if xcrun cannot find it.
    private static func resolveSwiftViaXcrun() -> String? {
        let xcrun = "/usr/bin/xcrun"
        guard FileManager.default.isExecutableFile(atPath: xcrun) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrun)
        process.arguments = ["-f", "swift"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns the host Swift version like "6.3.1" by parsing `swift --version` output,
    /// or nil if the version cannot be determined.
    static func hostSwiftVersion(swiftPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftPath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Matches "Swift version 6.3.1" or "Apple Swift version 6.3.1".
        guard let range = output.range(of: #"Swift version (\d+\.\d+\.\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = String(output[range])
        return match.split(separator: " ").last.map(String.init)
    }

    static func buildWasm(projectDir: URL, outputDir: URL) async throws {
        print("  Project: \(projectDir.path)")

        // Find Swift with WASM support
        guard let swiftPath = findSwiftWithWasmSupport() else {
            print("  ✗ Could not find Swift with WASM SDK support")
            print("  Checked: ~/.swiftly/bin/swift, /opt/homebrew/bin/swift, /usr/local/bin/swift")
            print("  Install swiftly and WASM SDK: https://www.swift.org/documentation/articles/wasm-getting-started.html")
            throw ServerError.wasmSdkNotFound
        }
        print("  Using Swift: \(swiftPath)")

        // Find WASM SDK
        let sdkProcess = Process()
        sdkProcess.executableURL = URL(fileURLWithPath: swiftPath)
        sdkProcess.arguments = ["sdk", "list"]
        sdkProcess.currentDirectoryURL = projectDir

        let sdkPipe = Pipe()
        sdkProcess.standardOutput = sdkPipe
        sdkProcess.standardError = Pipe()

        try sdkProcess.run()
        sdkProcess.waitUntilExit()

        let sdkData = sdkPipe.fileHandleForReading.readDataToEndOfFile()
        let sdkOutput = String(data: sdkData, encoding: .utf8) ?? ""
        let sdkLines = sdkOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }

        print("  Available SDKs: \(sdkLines)")

        let nonEmbeddedWasmSdks = sdkLines
            .filter { $0.lowercased().contains("wasm") && !$0.contains("embedded") }
            .sorted(by: >)

        // Prefer SDK matching host Swift version (e.g. "6.3.1"), else newest.
        let hostVersion = hostSwiftVersion(swiftPath: swiftPath)
        let matchingSdk = hostVersion.flatMap { v in
            nonEmbeddedWasmSdks.first(where: { $0.contains("swift-\(v)-RELEASE_wasm") })
        }

        guard let wasmSdk = matchingSdk ?? nonEmbeddedWasmSdks.first else {
            throw ServerError.wasmSdkNotFound
        }

        print("  Using SDK: \(wasmSdk)")

        // Build WASM
        // Note: -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor is required for JavaScriptKit (WASI reactor ABI)
        let buildArgs = ["build", "--product", "WasmApp", "--swift-sdk", wasmSdk, "-c", "release",
                         "-Xswiftc", "-Xclang-linker", "-Xswiftc", "-mexec-model=reactor"]
        print("  Command: swift \(buildArgs.joined(separator: " "))")

        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: swiftPath)
        buildProcess.arguments = buildArgs
        buildProcess.currentDirectoryURL = projectDir

        let buildPipe = Pipe()
        buildProcess.standardOutput = buildPipe
        buildProcess.standardError = buildPipe

        try buildProcess.run()
        buildProcess.waitUntilExit()

        let buildOutput = String(data: buildPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print(buildOutput)

        guard buildProcess.terminationStatus == 0 else {
            throw ServerError.buildFailed(buildOutput)
        }

        // Find and copy .wasm file
        let releaseDir = projectDir.appending(path: ".build/wasm32-unknown-wasip1/release")
        let wasmFile = releaseDir.appending(path: "WasmApp.wasm")

        print("  Looking for: \(wasmFile.path)")

        if FileManager.default.fileExists(atPath: wasmFile.path) {
            let destFile = outputDir.appending(path: "WasmApp.wasm")
            try? FileManager.default.removeItem(at: destFile)
            try FileManager.default.copyItem(at: wasmFile, to: destFile)
            print("  ✓ Copied: WasmApp.wasm")
        } else {
            print("  ✗ WasmApp.wasm not found at expected location")
            throw ServerError.buildFailed("WasmApp.wasm not found at \(wasmFile.path)")
        }
    }

    enum ServerError: Error {
        case wasmSdkNotFound
        case buildFailed(String)
    }

    // MARK: - Port Management

    static func findProcessOnPort(_ port: Int) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", ":\(port)", "-t"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(output.components(separatedBy: "\n").first ?? "") {
                return pid
            }
        } catch {
            // lsof failed, assume port is available
        }
        return nil
    }

    static func killProcess(pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-9", "\(pid)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func generateAssets(projectName: String, outputDir: URL) {
        let indexHtml = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(projectName) - WasmPort</title>
            <style>
                * { box-sizing: border-box; margin: 0; padding: 0; }
                html, body { width: 100%; height: 100%; overflow: hidden; background: #1a1a33; }
                #canvas { display: block; width: 100%; height: 100%; }
                #status {
                    position: fixed;
                    bottom: 20px;
                    left: 20px;
                    color: #69db7c;
                    font-family: monospace;
                    font-size: 14px;
                    background: rgba(0, 0, 0, 0.7);
                    padding: 10px 15px;
                    border-radius: 5px;
                }
                #error {
                    position: fixed;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    color: #ff6b6b;
                    font-family: system-ui;
                    font-size: 18px;
                    text-align: center;
                    display: none;
                }
            </style>
        </head>
        <body>
            <canvas id="canvas"></canvas>
            <div id="status">Initializing...</div>
            <div id="error"></div>
            <script type="module" src="app.js"></script>
        </body>
        </html>
        """

        let appJs = """
        // WasmPort App
        // Uses JavaScriptKit for Swift-JavaScript interop

        import { SwiftRuntime } from "./runtime.mjs";
        import { WASI, File, OpenFile, ConsoleStdout } from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.1/+esm";

        const statusEl = document.getElementById('status');
        const errorEl = document.getElementById('error');

        function setStatus(msg) {
            statusEl.textContent = msg;
            console.log('[WasmPort]', msg);
        }

        function showError(msg) {
            errorEl.textContent = msg;
            errorEl.style.display = 'block';
            statusEl.style.color = '#ff6b6b';
            statusEl.textContent = 'Error';
            console.error('[WasmPort Error]', msg);
        }

        async function main() {
            try {
                setStatus('Loading WASM module...');

                // Load WASM
                const response = await fetch('WasmApp.wasm');
                if (!response.ok) {
                    throw new Error('Failed to load WasmApp.wasm: ' + response.status);
                }
                const wasmBytes = await response.arrayBuffer();
                setStatus('WASM loaded (' + (wasmBytes.byteLength / 1024).toFixed(1) + ' KB)');

                // Setup JavaScriptKit runtime
                const swift = new SwiftRuntime();

                // Setup WASI
                const wasi = new WASI([], [], [
                    new OpenFile(new File([])),  // stdin
                    ConsoleStdout.lineBuffered((line) => console.log('[Swift]', line)),  // stdout
                    ConsoleStdout.lineBuffered((line) => console.error('[Swift]', line)), // stderr
                ]);

                // BridgeJS imports (required for JavaScriptKit 0.37.0+)
                let wasmMemory = null;
                const textDecoder = new TextDecoder('utf-8');
                const textEncoder = new TextEncoder();

                // Temporary storage for return values
                let tmpRetString = undefined;
                let tmpRetBytes = undefined;
                let tmpRetException = undefined;
                let tmpRetOptionalBool = undefined;
                let tmpRetOptionalInt = undefined;
                let tmpRetOptionalFloat = undefined;
                let tmpRetOptionalDouble = undefined;
                let tmpRetOptionalHeapObject = undefined;

                // Unified parameter/return stacks (BridgeJS canonical)
                let stringStack = [];
                let i32Stack = [];
                let i64Stack = [];
                let f32Stack = [];
                let f64Stack = [];
                let pointerStack = [];

                function decodeString(ptr, len) {
                    const bytes = new Uint8Array(wasmMemory.buffer, ptr, len);
                    return textDecoder.decode(bytes);
                }

                const bjs = {
                    swift_js_return_string: (ptr, len) => {
                        tmpRetString = decodeString(ptr, len);
                    },
                    swift_js_init_memory: (sourceId, bytesPtr) => {
                        const source = swift.memory.getObject(sourceId);
                        swift.memory.release(sourceId);
                        const bytes = new Uint8Array(wasmMemory.buffer, bytesPtr);
                        bytes.set(source);
                    },
                    swift_js_make_js_string: (ptr, len) => {
                        return swift.memory.retain(decodeString(ptr, len));
                    },
                    swift_js_init_memory_with_result: (ptr, len) => {
                        const target = new Uint8Array(wasmMemory.buffer, ptr, len);
                        target.set(tmpRetBytes);
                        tmpRetBytes = undefined;
                    },
                    swift_js_throw: (id) => {
                        tmpRetException = swift.memory.retainByRef(id);
                    },
                    swift_js_retain: (id) => {
                        return swift.memory.retainByRef(id);
                    },
                    swift_js_release: (id) => {
                        swift.memory.release(id);
                    },
                    swift_js_push_i32: (v) => { i32Stack.push(v | 0); },
                    swift_js_push_i64: (v) => { i64Stack.push(v); },
                    swift_js_push_f32: (v) => { f32Stack.push(Math.fround(v)); },
                    swift_js_push_f64: (v) => { f64Stack.push(v); },
                    swift_js_push_string: (ptr, len) => {
                        stringStack.push(decodeString(ptr, len));
                    },
                    swift_js_push_pointer: (pointer) => { pointerStack.push(pointer); },
                    swift_js_pop_i32: () => i32Stack.pop(),
                    swift_js_pop_i64: () => i64Stack.pop(),
                    swift_js_pop_f32: () => f32Stack.pop(),
                    swift_js_pop_f64: () => f64Stack.pop(),
                    swift_js_pop_pointer: () => pointerStack.pop(),
                    swift_js_return_optional_bool: (isSome, value) => {
                        tmpRetOptionalBool = isSome === 0 ? null : value !== 0;
                    },
                    swift_js_return_optional_int: (isSome, value) => {
                        tmpRetOptionalInt = isSome === 0 ? null : value | 0;
                    },
                    swift_js_get_optional_int_presence: () => {
                        return tmpRetOptionalInt != null ? 1 : 0;
                    },
                    swift_js_get_optional_int_value: () => {
                        const value = tmpRetOptionalInt;
                        tmpRetOptionalInt = undefined;
                        return value;
                    },
                    swift_js_return_optional_float: (isSome, value) => {
                        tmpRetOptionalFloat = isSome === 0 ? null : Math.fround(value);
                    },
                    swift_js_get_optional_float_presence: () => {
                        return tmpRetOptionalFloat != null ? 1 : 0;
                    },
                    swift_js_get_optional_float_value: () => {
                        const value = tmpRetOptionalFloat;
                        tmpRetOptionalFloat = undefined;
                        return value;
                    },
                    swift_js_return_optional_double: (isSome, value) => {
                        tmpRetOptionalDouble = isSome === 0 ? null : value;
                    },
                    swift_js_get_optional_double_presence: () => {
                        return tmpRetOptionalDouble != null ? 1 : 0;
                    },
                    swift_js_get_optional_double_value: () => {
                        const value = tmpRetOptionalDouble;
                        tmpRetOptionalDouble = undefined;
                        return value;
                    },
                    swift_js_return_optional_string: (isSome, ptr, len) => {
                        tmpRetString = isSome === 0 ? null : decodeString(ptr, len);
                    },
                    swift_js_get_optional_string: () => {
                        const str = tmpRetString;
                        tmpRetString = undefined;
                        if (str == null) return -1;
                        const bytes = textEncoder.encode(str);
                        tmpRetBytes = bytes;
                        return bytes.length;
                    },
                    swift_js_return_optional_object: (isSome, objectId) => {
                        tmpRetString = isSome === 0 ? null : swift.memory.getObject(objectId);
                    },
                    swift_js_return_optional_heap_object: (isSome, pointer) => {
                        tmpRetOptionalHeapObject = isSome === 0 ? null : pointer;
                    },
                    swift_js_get_optional_heap_object_pointer: () => {
                        const pointer = tmpRetOptionalHeapObject;
                        tmpRetOptionalHeapObject = undefined;
                        return pointer || 0;
                    },
                    swift_js_closure_unregister: (funcRef) => {},
                };

                // Combine imports
                const importObject = {
                    wasi_snapshot_preview1: wasi.wasiImport,
                    javascript_kit: swift.wasmImports,
                    bjs: bjs,
                };

                setStatus('Instantiating WASM...');

                // Instantiate
                const { instance } = await WebAssembly.instantiate(wasmBytes, importObject);

                // Store memory reference for bjs functions
                wasmMemory = instance.exports.memory;

                // Connect runtime
                swift.setInstance(instance);
                wasi.initialize(instance);

                setStatus('Starting application...');

                // Set canvas size to fill viewport
                const canvas = document.getElementById('canvas');
                const dpr = window.devicePixelRatio || 1;
                canvas.width = Math.floor(window.innerWidth * dpr);
                canvas.height = Math.floor(window.innerHeight * dpr);

                // Call setup
                if (instance.exports.setup) {
                    instance.exports.setup();
                }

                setTimeout(() => {
                    setStatus('Running...');
                }, 1000);

            } catch (err) {
                showError(err.message || 'Unknown error');
                console.error('WASM Error:', err);
            }
        }

        main();
        """

        try? indexHtml.write(to: outputDir.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try? appJs.write(to: outputDir.appending(path: "app.js"), atomically: true, encoding: .utf8)
        try? embeddedRuntimeMjs.write(to: outputDir.appending(path: "runtime.mjs"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Embedded JavaScriptKit Runtime

let embeddedRuntimeMjs = #"""
class SwiftClosureDeallocator {
    constructor(exports) {
        if (typeof FinalizationRegistry === "undefined") {
            throw new Error("The Swift part of JavaScriptKit was configured to require the availability of JavaScript WeakRefs.");
        }
        this.functionRegistry = new FinalizationRegistry((id) => { exports.swjs_free_host_function(id); });
    }
    track(func, func_ref) { this.functionRegistry.register(func, func_ref); }
}
function assertNever(x, message) { throw new Error(message); }
const decode = (kind, payload1, payload2, objectSpace) => {
    switch (kind) {
        case 0: return payload1 === 1;
        case 2: return payload2;
        case 1: case 3: case 7: case 8: return objectSpace.getObject(payload1);
        case 4: return null;
        case 5: return undefined;
        default: assertNever(kind, `JSValue Type kind "${kind}" is not supported`);
    }
};
const decodeArray = (ptr, length, memory, objectSpace) => {
    if (length === 0) return [];
    let result = [];
    for (let index = 0; index < length; index++) {
        const base = ptr + 16 * index;
        result.push(decode(memory.getUint32(base, true), memory.getUint32(base + 4, true), memory.getFloat64(base + 8, true), objectSpace));
    }
    return result;
};
const write = (value, kind_ptr, payload1_ptr, payload2_ptr, is_exception, memory, objectSpace) => {
    memory.setUint32(kind_ptr, writeAndReturnKindBits(value, payload1_ptr, payload2_ptr, is_exception, memory, objectSpace), true);
};
const writeAndReturnKindBits = (value, payload1_ptr, payload2_ptr, is_exception, memory, objectSpace) => {
    const exceptionBit = (is_exception ? 1 : 0) << 31;
    if (value === null) return exceptionBit | 4;
    const writeRef = (kind) => { memory.setUint32(payload1_ptr, objectSpace.retain(value), true); return exceptionBit | kind; };
    const type = typeof value;
    switch (type) {
        case "boolean": memory.setUint32(payload1_ptr, value ? 1 : 0, true); return exceptionBit | 0;
        case "number": memory.setFloat64(payload2_ptr, value, true); return exceptionBit | 2;
        case "string": return writeRef(1);
        case "undefined": return exceptionBit | 5;
        case "object": case "function": return writeRef(3);
        case "symbol": return writeRef(7);
        case "bigint": return writeRef(8);
        default: assertNever(type, `Type "${type}" is not supported yet`);
    }
    throw new Error("Unreachable");
};
let globalVariable;
if (typeof globalThis !== "undefined") globalVariable = globalThis;
else if (typeof window !== "undefined") globalVariable = window;
else if (typeof global !== "undefined") globalVariable = global;
else if (typeof self !== "undefined") globalVariable = self;
class JSObjectSpace {
    constructor() {
        this._heapValueById = new Map();
        this._heapValueById.set(1, globalVariable);
        this._heapEntryByValue = new Map();
        this._heapEntryByValue.set(globalVariable, { id: 1, rc: 1 });
        this._heapNextKey = 2;
    }
    retain(value) {
        const entry = this._heapEntryByValue.get(value);
        if (entry) { entry.rc++; return entry.id; }
        const id = this._heapNextKey++;
        this._heapValueById.set(id, value);
        this._heapEntryByValue.set(value, { id: id, rc: 1 });
        return id;
    }
    retainByRef(ref) { return this.retain(this.getObject(ref)); }
    release(ref) {
        const value = this._heapValueById.get(ref);
        const entry = this._heapEntryByValue.get(value);
        entry.rc--;
        if (entry.rc != 0) return;
        this._heapEntryByValue.delete(value);
        this._heapValueById.delete(ref);
    }
    getObject(ref) {
        const value = this._heapValueById.get(ref);
        if (value === undefined) throw new ReferenceError("Attempted to read invalid reference " + ref);
        return value;
    }
}
class SwiftRuntime {
    constructor(options) {
        this.version = 708;
        this.textDecoder = new TextDecoder("utf-8");
        this.textEncoder = new TextEncoder();
        this._instance = null;
        this.memory = new JSObjectSpace();
        this._closureDeallocator = null;
        this.options = options || {};
        this.getDataView = () => { throw new Error("Please call setInstance() before using any JavaScriptKit APIs."); };
        this.getUint8Array = () => { throw new Error("Please call setInstance() before using any JavaScriptKit APIs."); };
        this.wasmMemory = null;
    }
    setInstance(instance) {
        this._instance = instance;
        const wasmMemory = instance.exports.memory;
        if (wasmMemory instanceof WebAssembly.Memory) {
            let cachedDataView = new DataView(wasmMemory.buffer);
            let cachedUint8Array = new Uint8Array(wasmMemory.buffer);
            this.getDataView = () => { if (cachedDataView.buffer.byteLength === 0) cachedDataView = new DataView(wasmMemory.buffer); return cachedDataView; };
            this.getUint8Array = () => { if (cachedUint8Array.byteLength === 0) cachedUint8Array = new Uint8Array(wasmMemory.buffer); return cachedUint8Array; };
            this.wasmMemory = wasmMemory;
        } else { throw new Error("instance.exports.memory is not a WebAssembly.Memory!?"); }
        if (typeof this.exports._start === "function") throw new Error("JavaScriptKit supports only WASI reactor ABI.");
        if (this.exports.swjs_library_version() != this.version) throw new Error("The versions of JavaScriptKit are incompatible.");
    }
    get instance() { if (!this._instance) throw new Error("WebAssembly instance is not set yet"); return this._instance; }
    get exports() { return this.instance.exports; }
    get closureDeallocator() {
        if (this._closureDeallocator) return this._closureDeallocator;
        if ((this.exports.swjs_library_features() & 1) != 0) this._closureDeallocator = new SwiftClosureDeallocator(this.exports);
        return this._closureDeallocator;
    }
    callHostFunction(host_func_id, line, file, args) {
        const argc = args.length;
        const argv = this.exports.swjs_prepare_host_function_call(argc);
        const dataView = this.getDataView();
        for (let index = 0; index < args.length; index++) {
            const base = argv + 16 * index;
            write(args[index], base, base + 4, base + 8, false, dataView, this.memory);
        }
        let output;
        const callback_func_ref = this.memory.retain((result) => { output = result; });
        this.exports.swjs_call_host_function(host_func_id, argv, argc, callback_func_ref);
        this.exports.swjs_cleanup_host_function_call(argv);
        return output;
    }
    get wasmImports() {
        return {
            swjs_set_prop: (ref, name, kind, payload1, payload2) => { this.memory.getObject(ref)[this.memory.getObject(name)] = decode(kind, payload1, payload2, this.memory); },
            swjs_get_prop: (ref, name, payload1_ptr, payload2_ptr) => writeAndReturnKindBits(this.memory.getObject(ref)[this.memory.getObject(name)], payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory),
            swjs_set_subscript: (ref, index, kind, payload1, payload2) => { this.memory.getObject(ref)[index] = decode(kind, payload1, payload2, this.memory); },
            swjs_get_subscript: (ref, index, payload1_ptr, payload2_ptr) => writeAndReturnKindBits(this.memory.getObject(ref)[index], payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory),
            swjs_encode_string: (ref, bytes_ptr_result) => { const bytes = this.textEncoder.encode(this.memory.getObject(ref)); this.getDataView().setUint32(bytes_ptr_result, this.memory.retain(bytes), true); return bytes.length; },
            swjs_decode_string: (bytes_ptr, length) => this.memory.retain(this.textDecoder.decode(this.getUint8Array().subarray(bytes_ptr, bytes_ptr + length))),
            swjs_load_string: (ref, buffer) => { this.getUint8Array().set(this.memory.getObject(ref), buffer); },
            swjs_call_function: (ref, argv, argc, payload1_ptr, payload2_ptr) => { try { return writeAndReturnKindBits(this.memory.getObject(ref)(...decodeArray(argv, argc, this.getDataView(), this.memory)), payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory); } catch (e) { return writeAndReturnKindBits(e, payload1_ptr, payload2_ptr, true, this.getDataView(), this.memory); } },
            swjs_call_function_no_catch: (ref, argv, argc, payload1_ptr, payload2_ptr) => writeAndReturnKindBits(this.memory.getObject(ref)(...decodeArray(argv, argc, this.getDataView(), this.memory)), payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory),
            swjs_call_function_with_this: (obj_ref, func_ref, argv, argc, payload1_ptr, payload2_ptr) => { try { return writeAndReturnKindBits(this.memory.getObject(func_ref).apply(this.memory.getObject(obj_ref), decodeArray(argv, argc, this.getDataView(), this.memory)), payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory); } catch (e) { return writeAndReturnKindBits(e, payload1_ptr, payload2_ptr, true, this.getDataView(), this.memory); } },
            swjs_call_function_with_this_no_catch: (obj_ref, func_ref, argv, argc, payload1_ptr, payload2_ptr) => writeAndReturnKindBits(this.memory.getObject(func_ref).apply(this.memory.getObject(obj_ref), decodeArray(argv, argc, this.getDataView(), this.memory)), payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory),
            swjs_call_new: (ref, argv, argc) => this.memory.retain(new (this.memory.getObject(ref))(...decodeArray(argv, argc, this.getDataView(), this.memory))),
            swjs_call_throwing_new: (ref, argv, argc, exception_kind_ptr, exception_payload1_ptr, exception_payload2_ptr) => { try { const result = new (this.memory.getObject(ref))(...decodeArray(argv, argc, this.getDataView(), this.memory)); write(null, exception_kind_ptr, exception_payload1_ptr, exception_payload2_ptr, false, this.getDataView(), this.memory); return this.memory.retain(result); } catch (e) { write(e, exception_kind_ptr, exception_payload1_ptr, exception_payload2_ptr, true, this.getDataView(), this.memory); return -1; } },
            swjs_instanceof: (obj_ref, constructor_ref) => this.memory.getObject(obj_ref) instanceof this.memory.getObject(constructor_ref),
            swjs_value_equals: (lhs_ref, rhs_ref) => this.memory.getObject(lhs_ref) == this.memory.getObject(rhs_ref),
            swjs_create_function: (host_func_id, line, file) => { const fileString = this.memory.getObject(file); const func = (...args) => this.callHostFunction(host_func_id, line, fileString, args); const ref = this.memory.retain(func); this.closureDeallocator?.track(func, host_func_id); return ref; },
            swjs_create_typed_array: (constructor_ref, elementsPtr, length) => { const ArrayType = this.memory.getObject(constructor_ref); if (length == 0) return this.memory.retain(new ArrayType()); return this.memory.retain(new ArrayType(this.wasmMemory.buffer, elementsPtr, length).slice()); },
            swjs_create_object: () => this.memory.retain({}),
            swjs_load_typed_array: (ref, buffer) => { this.getUint8Array().set(new Uint8Array(this.memory.getObject(ref).buffer), buffer); },
            swjs_release: (ref) => { this.memory.release(ref); },
            swjs_i64_to_bigint: (value, signed) => this.memory.retain(signed ? value : BigInt.asUintN(64, value)),
            swjs_bigint_to_i64: (ref, signed) => { const obj = this.memory.getObject(ref); if (typeof obj !== "bigint") throw new Error("Expected BigInt"); return signed ? obj : (obj < 0n ? 0n : BigInt.asIntN(64, obj)); },
            swjs_i64_to_bigint_slow: (lower, upper, signed) => { const value = BigInt.asUintN(32, BigInt(lower)) + (BigInt.asUintN(32, BigInt(upper)) << 32n); return this.memory.retain(signed ? BigInt.asIntN(64, value) : value); },
            swjs_unsafe_event_loop_yield: () => { throw new UnsafeEventLoopYield(); },
            swjs_create_oneshot_function: (host_func_id, line, file) => { const fileString = this.memory.getObject(file); return this.memory.retain((...args) => this.callHostFunction(host_func_id, line, fileString, args)); },
            swjs_release_remote: () => {}, swjs_send_job_to_main_thread: () => {}, swjs_listen_message_from_main_thread: () => {},
            swjs_wake_up_worker_thread: () => {}, swjs_listen_message_from_worker_thread: () => {}, swjs_terminate_worker_thread: () => {},
            swjs_get_worker_thread_id: () => -1, swjs_request_sending_object: () => {}, swjs_request_sending_objects: () => {},
        };
    }
}
class UnsafeEventLoopYield extends Error {}
export { SwiftRuntime };
"""#
