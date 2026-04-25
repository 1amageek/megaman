import { test, type Page } from "@playwright/test";

// Visual-only capture: records a video of the death sequence so the user
// can review the particle animation outside of the headless harness. Not
// an assertion — always passes; the artifact is the point.

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
    video: { mode: "on", size: { width: 1148, height: 1064 } },
    viewport: { width: 1148, height: 1064 },
});

test("CAPTURE — death sequence animation", async ({ page }) => {
    await page.goto("/");
    await waitForRunning(page);
    await waitForHarness(page);

    // Let intro finish (~5.3s includes safety margin over 4.76s Sigma intro).
    await page.waitForTimeout(5_300);

    await page.evaluate(() => {
        (window as unknown as {
            __megaman_test: { disableBoss: () => void; killPlayer: () => void };
        }).__megaman_test.disableBoss();
    });

    // Trigger death; video continues rolling for the full sequence.
    await page.evaluate(() => {
        (window as unknown as {
            __megaman_test: { killPlayer: () => void };
        }).__megaman_test.killPlayer();
    });

    // Cover: 0.5s pre-burst + 0.45s inter-round + 1.0s particle lifetime +
    // scene fade (~1.5s after death start) + post-defeat dwell (~5.0s).
    await page.waitForTimeout(7_000);
});
