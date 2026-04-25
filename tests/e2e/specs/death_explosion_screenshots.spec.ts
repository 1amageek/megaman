import { test, type Page } from "@playwright/test";

// Visual-only: takes still screenshots at key moments of the death sequence.
// Unlike the video spec, screenshots bypass the rAF-throttling issues we hit
// with webm capture on this canvas, so they actually contain pixels.

async function waitForRunning(page: Page): Promise<void> {
    await page.locator("#status").waitFor();
    await page.waitForFunction(() => document.querySelector("#status")?.textContent === "Running...");
}

async function waitForHarness(page: Page): Promise<void> {
    await page.waitForFunction(
        () => !!(window as unknown as { __megaman_test?: unknown }).__megaman_test,
        null,
        { timeout: 10_000 }
    );
}

test.use({
    viewport: { width: 1148, height: 1064 },
    launchOptions: {
        headless: false,
        args: [
            "--enable-unsafe-webgpu",
            "--enable-webgpu-developer-features",
            "--use-angle=metal"
        ]
    }
});

test("SHOT — death sequence key frames", async ({ page }) => {
    await page.goto("/");
    await waitForRunning(page);
    await waitForHarness(page);

    await page.waitForTimeout(5_300);

    await page.evaluate(() => {
        (window as unknown as {
            __megaman_test: { disableBoss: () => void };
        }).__megaman_test.disableBoss();
    });
    await page.waitForTimeout(100);

    await page.evaluate(() => {
        (window as unknown as {
            __megaman_test: { killPlayer: () => void };
        }).__megaman_test.killPlayer();
    });

    // t=0.30s: player still visible, pre-burst
    await page.waitForTimeout(300);
    await page.screenshot({ path: "test-results/death_00_pre.png", fullPage: false });

    // t=0.55s: first burst just fired (killPlayer at ~0, burst at 0.5)
    await page.waitForTimeout(250);
    await page.screenshot({ path: "test-results/death_01_burst1_start.png", fullPage: false });

    // t=0.75s: first burst at peak scale
    await page.waitForTimeout(200);
    await page.screenshot({ path: "test-results/death_02_burst1_peak.png", fullPage: false });

    // t=1.05s: second burst just fired (0.95 trigger)
    await page.waitForTimeout(300);
    await page.screenshot({ path: "test-results/death_03_burst2_start.png", fullPage: false });

    // t=1.30s: second burst near peak, first burst fading
    await page.waitForTimeout(250);
    await page.screenshot({ path: "test-results/death_04_burst2_peak.png", fullPage: false });

    // t=1.90s: both bursts fading / mostly gone
    await page.waitForTimeout(600);
    await page.screenshot({ path: "test-results/death_05_fading.png", fullPage: false });
});
