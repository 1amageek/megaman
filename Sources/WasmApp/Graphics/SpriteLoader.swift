import Foundation
import JavaScriptKit
import JavaScriptEventLoop
import OpenSpriteKit

// Async fetch of (PNG + Aseprite JSON) pairs from the dev server.
// Path convention: "/assets/sprites/<group>/<name>.{png,json}".

enum SpriteLoaderError: Error {
    case fetchFailed(String)
    case decodeFailed(String)
    case sliceFailed(String)
}

@MainActor
enum SpriteLoader {
    static func load(group: String, name: String) async throws -> SpriteAtlas {
        let basePath = "/assets/sprites/\(group)/\(name)"
        async let pngData = fetchData(from: "\(basePath).png")
        async let jsonData = fetchData(from: "\(basePath).json")

        let png = try await pngData
        let json = try await jsonData

        let atlas: AsepriteAtlas
        do {
            atlas = try AsepriteAtlas.decode(from: json)
        } catch {
            throw SpriteLoaderError.decodeFailed("\(basePath).json: \(error)")
        }

        guard let sliced = SpriteAtlas.make(pngData: png, atlas: atlas) else {
            throw SpriteLoaderError.sliceFailed(basePath)
        }
        return sliced
    }

    /// Load a PNG with no sibling Aseprite JSON, slicing it as a regular
    /// `cols × rows` grid into a single animation tag. Godot effect textures
    /// (sparks.png, death.png, dash.png, ...) ship as bare PNGs consumed by
    /// `ParticleProcessMaterial` + `TextureAtlas` H/V frame counts; we mirror
    /// that by building a synthetic `SpriteAtlas` at load time.
    static func loadGrid(
        group: String,
        name: String,
        cols: Int,
        rows: Int,
        frameDurationMs: Int = 100,
        tag: String = "all"
    ) async throws -> SpriteAtlas {
        let basePath = "/assets/sprites/\(group)/\(name)"
        let png = try await fetchData(from: "\(basePath).png")
        guard let atlas = SpriteAtlas.makeGrid(
            pngData: png,
            cols: cols,
            rows: rows,
            frameDurationMs: frameDurationMs,
            tag: tag
        ) else {
            throw SpriteLoaderError.sliceFailed(basePath)
        }
        return atlas
    }

    // MARK: - Fetch

    private static func fetchData(from path: String) async throws -> Data {
        let promiseValue = JSObject.global.fetch!(path)
        guard let promiseObj = promiseValue.object,
              let promise = JSPromise(promiseObj) else {
            throw SpriteLoaderError.fetchFailed("\(path) (no fetch result)")
        }
        let response = try await promise.value()
        guard let responseObj = response.object else {
            throw SpriteLoaderError.fetchFailed("\(path) (no response object)")
        }
        let okValue = responseObj.ok.boolean ?? false
        guard okValue else {
            let status = responseObj.status.number ?? 0
            throw SpriteLoaderError.fetchFailed("\(path) (HTTP \(Int(status)))")
        }
        let bufferPromiseValue = responseObj.arrayBuffer!()
        guard let bufferPromiseObj = bufferPromiseValue.object,
              let bufferPromise = JSPromise(bufferPromiseObj) else {
            throw SpriteLoaderError.fetchFailed("\(path) (no arrayBuffer promise)")
        }
        let buffer = try await bufferPromise.value()
        let uint8Ctor = JSObject.global.Uint8Array.function!
        let uint8Object = uint8Ctor.new(buffer)
        let typed = JSTypedArray<UInt8>(unsafelyWrapping: uint8Object)
        let length = typed.length
        var data = Data(count: length)
        data.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                let buffer = UnsafeMutableBufferPointer<UInt8>(start: base.assumingMemoryBound(to: UInt8.self), count: length)
                typed.copyMemory(to: buffer)
            }
        }
        return data
    }
}
