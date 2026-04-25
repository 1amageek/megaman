// Minimal static server for E2E tests.
// Mounts two directories under the same URL space to mirror `wasmport run`:
//   /              -> ../../.build/wasmport/wasm/  (index.html, app.js, runtime.mjs, WasmApp.wasm)
//   /assets/*      -> ../../Public/assets/*         (sprite PNGs + Aseprite JSON)
//
// Why not use `wasmport run`: that command opens Xcode and launches a browser
// interactively — unsuitable for headless CI. This server is zero-dep (Node
// built-ins only) so no npm install is required just to serve.

import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = fileURLToPath(new URL(".", import.meta.url));
const PROJECT_ROOT = resolve(__dirname, "..", "..");
const WASM_ROOT = join(PROJECT_ROOT, ".build", "wasmport", "wasm");
const ASSETS_ROOT = join(PROJECT_ROOT, "Public", "assets");

const MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".mjs": "application/javascript; charset=utf-8",
    ".wasm": "application/wasm",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
    ".css": "text/css; charset=utf-8",
    ".ico": "image/x-icon",
    ".map": "application/json; charset=utf-8"
};

// Resolve a URL path to a physical file path, guarding against escape via "..".
function resolvePhysical(urlPath) {
    const clean = normalize(decodeURIComponent(urlPath.split("?")[0]));
    if (clean.startsWith("/assets/")) {
        const rel = clean.slice("/assets/".length);
        const full = join(ASSETS_ROOT, rel);
        if (!full.startsWith(ASSETS_ROOT)) return null;  // Path traversal guard.
        return full;
    }
    const rel = clean === "/" ? "index.html" : clean.replace(/^\/+/, "");
    const full = join(WASM_ROOT, rel);
    if (!full.startsWith(WASM_ROOT)) return null;
    return full;
}

async function serve(req, res) {
    const filePath = resolvePhysical(req.url);
    if (!filePath) {
        res.writeHead(403);
        res.end("Forbidden");
        return;
    }
    try {
        const stats = await stat(filePath);
        if (!stats.isFile()) {
            res.writeHead(404);
            res.end("Not Found");
            return;
        }
        const data = await readFile(filePath);
        const mime = MIME[extname(filePath).toLowerCase()] ?? "application/octet-stream";
        res.writeHead(200, {
            "Content-Type": mime,
            "Content-Length": data.length,
            // COOP/COEP isolation — not strictly required today but matches the
            // security posture most Swift-WASM hosts use for SharedArrayBuffer.
            "Cross-Origin-Opener-Policy": "same-origin",
            "Cross-Origin-Embedder-Policy": "require-corp"
        });
        res.end(data);
    } catch (err) {
        if (err.code === "ENOENT") {
            res.writeHead(404);
            res.end(`Not Found: ${req.url}`);
        } else {
            res.writeHead(500);
            res.end(`Internal Error: ${err.message}`);
        }
    }
}

async function preflight() {
    const wasmFile = join(WASM_ROOT, "WasmApp.wasm");
    try {
        await stat(wasmFile);
    } catch {
        console.error(
            `\n✗ WasmApp.wasm missing at ${wasmFile}\n` +
            `  Build it first:\n` +
            `    swift build --product WasmApp --swift-sdk swift-6.3.1-RELEASE_wasm -c release\n` +
            `    cp .build/wasm32-unknown-wasip1/release/WasmApp.wasm .build/wasmport/wasm/\n`
        );
        process.exit(1);
    }
}

const PORT = Number(process.env.E2E_PORT ?? 8765);

await preflight();
createServer(serve).listen(PORT, "127.0.0.1", () => {
    console.log(`E2E server listening on http://127.0.0.1:${PORT}`);
    console.log(`  /              -> ${WASM_ROOT}`);
    console.log(`  /assets/*      -> ${ASSETS_ROOT}`);
});
