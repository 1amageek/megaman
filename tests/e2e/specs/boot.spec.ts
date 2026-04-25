import { test, expect, type Page } from "@playwright/test";

// Boot + render-loop smoke. Validates the full
// OpenCoreGraphics → OpenCoreAnimation → OpenSpriteKit → megaman stack inside
// a real browser running the production WASM artifact.
//
// Rendering liveness is measured via `window.__megaman_test.getFrameCount()`
// — a counter the Swift-side rAF loop increments each tick. Reading WebGPU
// pixels from JS is unreliable (GPUCanvasContext swap textures are discarded
// after present, so `drawImage(webgpuCanvas, 0, 0)` returns an empty/cleared
// image in most browsers). The frame counter is a deterministic proxy:
// every increment proves `SKRenderer.update()` + `render()` ran.

async function waitForRunning(page: Page): Promise<void> {
    // runtime.mjs + app.js set #status through a small set of strings. The
    // terminal success string is "Running..." — anything else at 30 s means a
    // stall during WASM instantiation or Swift-side setup().
    await expect(page.locator("#status")).toHaveText("Running...", { timeout: 30_000 });
    await expect(page.locator("#error")).toBeHidden();
}

async function waitForHarness(page: Page): Promise<void> {
    await page.waitForFunction(
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        () => !!(window as unknown as { __megaman_test?: unknown }).__megaman_test,
        null,
        { timeout: 10_000 }
    );
}

async function getFrameCount(page: Page): Promise<number> {
    return await page.evaluate(() => {
        const h = (window as unknown as {
            __megaman_test?: { getFrameCount: () => number }
        }).__megaman_test;
        return h ? h.getFrameCount() : -1;
    });
}

test.describe("megaman WASM boot pipeline", () => {
    test("WASM instantiates and reaches Running state", async ({ page }) => {
        const errors: string[] = [];
        page.on("pageerror", err => errors.push(err.message));
        page.on("console", msg => {
            if (msg.type() === "error") errors.push(msg.text());
        });

        await page.goto("/");
        await waitForRunning(page);

        // No thrown page errors, no console-level errors.
        expect(errors, `unexpected page/console errors:\n${errors.join("\n")}`).toEqual([]);
    });

    test("render loop starts ticking", async ({ page }) => {
        await page.goto("/");
        await waitForRunning(page);
        await waitForHarness(page);

        // After harness installation, frames should start arriving almost
        // immediately. 1 s at 60 fps is ~60 frames; a healthy loop will
        // blow past any reasonable lower bound.
        await page.waitForTimeout(1_000);
        const count = await getFrameCount(page);
        expect(
            count,
            `render loop did not tick within 1 s (frameCount=${count})`
        ).toBeGreaterThan(5);
    });

    test("render loop keeps ticking over time", async ({ page }) => {
        await page.goto("/");
        await waitForRunning(page);
        await waitForHarness(page);

        // Sample twice 500 ms apart. Any forward progress proves the rAF
        // chain is self-sustaining (a one-shot callback would tick once
        // then freeze — this test catches that).
        const c1 = await getFrameCount(page);
        await page.waitForTimeout(500);
        const c2 = await getFrameCount(page);

        expect(c2, `frame counter regressed or stalled: c1=${c1} c2=${c2}`).toBeGreaterThan(c1);
        const delta = c2 - c1;
        // Allow a generous floor — SwiftShader CI can dip below 30 fps.
        expect(
            delta,
            `render loop too slow: only ${delta} frames in 500 ms`
        ).toBeGreaterThanOrEqual(10);
    });
});
