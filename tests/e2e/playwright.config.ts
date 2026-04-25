import { defineConfig, devices } from "@playwright/test";

const PORT = Number(process.env.E2E_PORT ?? 8765);
const BASE_URL = `http://127.0.0.1:${PORT}`;

export default defineConfig({
    testDir: "./specs",
    fullyParallel: false,       // Single WASM instance per page; no cross-spec isolation to gain.
    workers: 1,
    forbidOnly: !!process.env.CI,
    retries: process.env.CI ? 1 : 0,
    reporter: [["list"], ["html", { open: "never" }]],
    timeout: 60_000,             // WASM cold-boot can be slow on first run.
    expect: { timeout: 15_000 },
    use: {
        baseURL: BASE_URL,
        trace: "retain-on-failure",
        screenshot: "only-on-failure",
        // WebGPU in headless Chromium is gated behind a flag. On macOS the
        // native Metal backend handles it; on Linux a SwiftShader fallback
        // would be needed (add --use-vulkan=swiftshader + Vulkan features
        // in that environment, not here).
        launchOptions: {
            args: [
                "--enable-unsafe-webgpu",
                "--enable-webgpu-developer-features"
            ]
        }
    },
    projects: [
        {
            name: "chromium",
            use: { ...devices["Desktop Chrome"] }
        }
    ],
    webServer: {
        command: "node server.mjs",
        port: PORT,
        reuseExistingServer: !process.env.CI,
        timeout: 30_000,
        stdout: "pipe",
        stderr: "pipe"
    }
});
