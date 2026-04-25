# megaman E2E tests

Browser-based end-to-end tests for the WASM build. Validates the full
`OpenCoreGraphics → OpenCoreAnimation → OpenSpriteKit → megaman` pipeline
inside a real Chromium instance via Playwright.

## What is covered

| Spec | Signal validated | Stack layer exercised |
|---|---|---|
| `boot.spec.ts` (boot) | `#status` reaches `Running...`, `#error` hidden, no page/console errors | WASM loader, WASI shim, JavaScriptKit bridge, Swift `setup()` |
| `boot.spec.ts` (render loop starts) | `__megaman_test.getFrameCount()` > 5 within 1 s of harness install | WebGPU init, `CAWebGPURenderer.render`, rAF chain |
| `boot.spec.ts` (render loop sustains) | Frame counter advances ≥10 over 500 ms between samples | Self-sustaining rAF loop, `SKScene.update` each tick |
| `input.spec.ts` (right) | ArrowRight → Swift `Player.position.x` increases > 20 px, facing=right | `InputManager`, `Player.tick`, physics integration |
| `input.spec.ts` (left) | ArrowLeft → `Player.position.x` decreases < -20 px, facing=left | Same pipeline, opposite direction + facing flip |

## Prerequisites

1. **WASM artifact must exist and be current:**
   ```bash
   cd ../..    # megaman repo root
   swift build --product WasmApp --swift-sdk swift-6.3.1-RELEASE_wasm -c release
   cp .build/wasm32-unknown-wasip1/release/WasmApp.wasm .build/wasmport/wasm/
   ```
   The static server fails fast if `WasmApp.wasm` is missing.

2. **Install Playwright + Chromium (first run only):**
   ```bash
   npm install
   npx playwright install chromium
   ```

## Running

```bash
# All specs (headless)
npm test

# Watch tests in a real browser window
npm run test:headed

# Playwright UI mode for debugging
npm run test:ui

# Just serve the WASM app on :8765 (no tests)
npm run serve
```

Override the port with `E2E_PORT=9000 npm test`.

## Why not use `wasmport run`?

`wasmport run` opens Xcode and launches a browser interactively — unsuitable
for headless CI. `server.mjs` is a zero-dependency Node static server that
mirrors the path layout `wasmport` uses (`/` → `.build/wasmport/wasm/`,
`/assets/*` → `Public/assets/*`).

## WebGPU in headless Chromium

`playwright.config.ts` passes `--enable-unsafe-webgpu` plus SwiftShader
Vulkan flags. On machines without a GPU (CI runners), SwiftShader provides
a software-rasterised WebGPU backend that is functionally correct for our
purposes, just slow.

## Why assertions go through the Swift-side harness, not canvas pixels

`window.__megaman_test` exposes `getInfo()` (player x/y/vx/vy/state/facing)
and `getFrameCount()` (rAF tick counter). Tests read these instead of
sampling WebGPU canvas pixels because `drawImage(webgpuCanvas, 0, 0)` into a
2D context returns an empty image in most browsers — the `GPUCanvasContext`
swap texture is destroyed after present, so anything read post-frame is
blank. The harness makes assertions deterministic (exact positions, exact
frame counts) without depending on GPU readback semantics.
