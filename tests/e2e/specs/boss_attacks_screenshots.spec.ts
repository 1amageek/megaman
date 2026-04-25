import { test, type Page } from "@playwright/test";

// Visual-only: takes screenshots of each boss attack mid-execution. Used to
// audit which attacks are missing visuals vs the Godot reference.

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

async function bootAndStart(page: Page): Promise<void> {
    await page.goto("/");
    await waitForRunning(page);
    await waitForHarness(page);
    // Let intro finish + battle start.
    await page.waitForTimeout(5_300);
}

type Harness = {
    forceAttack: (name: string) => void;
    disableBoss: () => void;
    getBossInfo: () => { attack: string; projCount: number; x: number; y: number };
};

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

async function captureAttackSeries(page: Page, label: string, attackName: string, points: { at: number; tag: string }[]): Promise<void> {
    await page.evaluate((name) => {
        (window as unknown as { __megaman_test: Harness }).__megaman_test.forceAttack(name);
    }, attackName);

    let elapsed = 0;
    for (const p of points) {
        const wait = p.at - elapsed;
        if (wait > 0) await page.waitForTimeout(wait);
        elapsed = p.at;
        await page.screenshot({ path: `test-results/attack_${label}_${p.tag}.png`, fullPage: false });
    }
}

test("SHOT — GroundCombo", async ({ page }) => {
    await bootAndStart(page);
    await captureAttackSeries(page, "ground", "groundCombo", [
        { at: 300, tag: "01_slash1" },
        { at: 700, tag: "02_slash1_mid" },
        { at: 1100, tag: "03_slash2" },
        { at: 1700, tag: "04_slash3" },
        { at: 2200, tag: "05_wave" },
    ]);
});

test("SHOT — JumpCombo", async ({ page }) => {
    await bootAndStart(page);
    await captureAttackSeries(page, "jump", "jumpCombo", [
        { at: 300, tag: "01_jump_prepare" },
        { at: 700, tag: "02_jump_up" },
        { at: 1200, tag: "03_apex" },
        { at: 1700, tag: "04_slam" },
        { at: 2200, tag: "05_recover" },
    ]);
});

test("SHOT — LanceThrow", async ({ page }) => {
    await bootAndStart(page);
    await captureAttackSeries(page, "lance", "lanceThrow", [
        { at: 300, tag: "01_aim" },
        { at: 900, tag: "02_throw" },
        { at: 1300, tag: "03_lance_midair" },
        { at: 1800, tag: "04_lance_far" },
    ]);
});

test("SHOT — AirCombo", async ({ page }) => {
    await bootAndStart(page);
    await captureAttackSeries(page, "air", "airCombo", [
        { at: 300, tag: "01_lift" },
        { at: 900, tag: "02_hover" },
        { at: 1500, tag: "03_shoot" },
        { at: 2100, tag: "04_projectiles" },
        { at: 2700, tag: "05_descent" },
    ]);
});

test("SHOT — Overdrive (desperation)", async ({ page }) => {
    await bootAndStart(page);
    await captureAttackSeries(page, "overdrive", "overdrive", [
        { at: 300, tag: "01_prepare" },
        { at: 900, tag: "02_charge_loop" },
        { at: 1500, tag: "03_charge_peak" },
        { at: 2000, tag: "04_fire_start" },
        { at: 2800, tag: "05_beam" },
        { at: 4000, tag: "06_beam_late" },
    ]);
});
