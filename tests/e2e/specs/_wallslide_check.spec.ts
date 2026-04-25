import { test, type Page } from "@playwright/test";

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

// Frame-by-frame state sampling — runs in the page so we capture every rAF
// tick and can spot transient state flips that 150ms Playwright sampling
// would miss.
test("wall slide frame-by-frame state trace", async ({ page }) => {
    await page.goto("/");
    await waitForRunning(page);
    await waitForHarness(page);
    await page.waitForTimeout(5_300);

    type H = {
        disableBoss: () => void;
        setPlayerPosition: (x: number, y?: number, facing?: string) => void;
        pressKey: (key: string, down?: boolean) => void;
        getInfo: () => { state: string; vy: number; y: number; x: number };
    };

    await page.evaluate(() => {
        const h = (window as unknown as { __megaman_test: H }).__megaman_test;
        h.disableBoss();
        h.setPlayerPosition(370, 28, "right");
    });

    await page.evaluate(() => {
        const h = (window as unknown as { __megaman_test: H }).__megaman_test;
        h.pressKey(" ", true);
        h.pressKey("ArrowRight", true);
    });

    // Sample every animation frame for 1.2 seconds.
    const result = await page.evaluate(async () => {
        const h = (window as unknown as { __megaman_test: H }).__megaman_test;
        const frames: Array<{ t: number; state: string; vy: number; y: number; x: number }> = [];
        const start = performance.now();
        return await new Promise<typeof frames>((resolve) => {
            function loop() {
                const now = performance.now() - start;
                if (now > 1200) { resolve(frames); return; }
                const i = h.getInfo();
                frames.push({ t: Math.round(now), state: i.state, vy: i.vy, y: i.y, x: i.x });
                requestAnimationFrame(loop);
            }
            requestAnimationFrame(loop);
        });
    });

    const transitions: Array<{ t: number; from: string; to: string; vy: number }> = [];
    for (let i = 1; i < result.length; i++) {
        if (result[i].state !== result[i - 1].state) {
            transitions.push({ t: result[i].t, from: result[i - 1].state, to: result[i].state, vy: result[i].vy });
        }
    }
    console.log(`[wallslide-trace] frames=${result.length} transitions=${transitions.length}`);
    console.log(JSON.stringify(transitions, null, 2));
});
