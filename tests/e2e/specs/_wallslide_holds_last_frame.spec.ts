import { test, expect, type Page } from "@playwright/test";

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

// Slide animation MUST be one-shot (Godot x.res slide.loop = false), holding
// the final frame after ~333ms (5 frames @ 15fps). If repeating: true is
// re-introduced, the sprite will keep cycling visibly different poses.
test("wall slide visual freezes after one play, does not cycle", async ({ page }) => {
    await page.goto("/");
    await waitForRunning(page);
    await waitForHarness(page);
    await page.waitForTimeout(5_300);

    type H = {
        disableBoss: () => void;
        setPlayerPosition: (x: number, y?: number, facing?: string) => void;
        pressKey: (key: string, down?: boolean) => void;
        releaseKeys: () => void;
        getInfo: () => { state: string };
    };

    await page.evaluate(() => {
        const h = (window as unknown as { __megaman_test: H }).__megaman_test;
        h.disableBoss();
        h.setPlayerPosition(370, 28, "right");
        h.pressKey(" ", true);
        h.pressKey("ArrowRight", true);
    });

    // Wait for slide to start.
    await page.waitForFunction(
        () => (window as unknown as { __megaman_test: { getInfo: () => { state: string } } }).__megaman_test.getInfo().state === "slide",
        null,
        { timeout: 3_000 }
    );

    // Snapshot the canvas just AFTER slide animation should have completed
    // (1 play = 5/15 ≈ 333ms; sample at 500ms to be safe), then again at 900ms.
    // If the animation is one-shot, both screenshots are pixel-identical.
    // If it's looping, frame 122 ↔ 123 cycling within the 280ms loop will diff.
    const canvas = page.locator("canvas");
    await page.waitForTimeout(500);
    const a = await canvas.screenshot();
    await page.waitForTimeout(400);
    const b = await canvas.screenshot();

    // PNG byte equality is brittle in general, but with no other animation in
    // the scene (boss disabled, no projectiles, identical static background)
    // the only moving piece is the player sprite.
    expect(a.equals(b)).toBeTruthy();
});
