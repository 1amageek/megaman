import { test, type Page } from "@playwright/test";
import { mkdirSync, rmSync } from "node:fs";
import { resolve } from "node:path";

// Debug-only: snapshot the canvas every 500ms for 3 seconds while a chosen
// scenario plays out. Run with the CAPTURE_SCENARIO env var:
//
//   CAPTURE_SCENARIO=overdrive npx playwright test specs/_capture.spec.ts
//   CAPTURE_SCENARIO=groundCombo BOSS_X=200 BOSS_FACING=right npx playwright test specs/_capture.spec.ts
//   CAPTURE_SCENARIO=playerDash PLAYER_X=80 PLAYER_FACING=right npx playwright test specs/_capture.spec.ts
//
// Frames land in test-results/capture_<scenario>/frame_<idx>_<ms>ms.png — old
// frames for the same scenario are wiped at the start of each run so the
// directory always reflects the latest fix iteration.

const CAPTURE_DIR_ROOT = "test-results";
const FRAMES = 7;            // 0, 500, 1000, ..., 3000 ms
const INTERVAL_MS = 500;
const TOTAL_MS = (FRAMES - 1) * INTERVAL_MS;

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
    // Let the SigmaIntro cutscene finish so the scene is in .fighting.
    await page.waitForTimeout(5_300);
}

const KNOWN_SCENARIOS = [
    "overdrive", "groundCombo", "jumpCombo", "lanceThrow", "airCombo",
    "playerDash", "playerJump", "playerWalkLeft", "playerDeath"
] as const;

type ScenarioName = typeof KNOWN_SCENARIOS[number];

function isKnownScenario(name: string): name is ScenarioName {
    return (KNOWN_SCENARIOS as readonly string[]).includes(name);
}

const scenarioName = process.env.CAPTURE_SCENARIO ?? "";
const bossX = process.env.BOSS_X ? Number(process.env.BOSS_X) : null;
const bossFacing = process.env.BOSS_FACING ?? null;
const playerX = process.env.PLAYER_X ? Number(process.env.PLAYER_X) : null;
const playerFacing = process.env.PLAYER_FACING ?? null;
const bossHp = process.env.BOSS_HP ? Number(process.env.BOSS_HP) : null;

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

test("capture 500ms × 3s window", async ({ page }) => {
    test.skip(!scenarioName, "set CAPTURE_SCENARIO env var (e.g. overdrive, groundCombo, playerDash)");
    test.skip(!isKnownScenario(scenarioName), `unknown scenario "${scenarioName}". Known: ${KNOWN_SCENARIOS.join(", ")}`);

    const outDir = resolve(CAPTURE_DIR_ROOT, `capture_${scenarioName}`);
    rmSync(outDir, { recursive: true, force: true });
    mkdirSync(outDir, { recursive: true });

    page.on("pageerror", (err) => console.error(`[pageerror] ${err.message}`));
    page.on("console", (msg) => {
        if (msg.type() === "error") console.error(`[console.error] ${msg.text()}`);
    });

    await bootAndStart(page);

    // Apply optional scene overrides BEFORE running the scenario, so the
    // capture frames always start from the same setup. Player-only scenarios
    // additionally disable the boss AI to keep Sigma from corrupting the
    // assertion window.
    await page.evaluate(
        ({ name, bx, bf, px, pf, bhp }) => {
            type H = {
                disableBoss: () => void;
                setBossPosition: (x: number, y?: number, facing?: string) => void;
                setBossFacing: (facing: string) => void;
                setBossHealth: (hp: number) => void;
                setPlayerPosition: (x: number, y?: number, facing?: string) => void;
            };
            const h = (window as unknown as { __megaman_test: H }).__megaman_test;
            if (bx !== null) h.setBossPosition(bx, 28, bf ?? "left");
            else if (bf !== null) h.setBossFacing(bf);
            if (px !== null) h.setPlayerPosition(px, 28, pf ?? "right");
            if (bhp !== null) h.setBossHealth(bhp);
            if (name === "playerDash" || name === "playerJump" || name === "playerWalkLeft") {
                h.disableBoss();
            }
        },
        { name: scenarioName, bx: bossX, bf: bossFacing, px: playerX, pf: playerFacing, bhp: bossHp }
    );

    // Frame 0: pre-fire baseline.
    const t0 = Date.now();
    await page.screenshot({ path: `${outDir}/frame_00_0000ms.png`, fullPage: false });

    // Fire the scenario action immediately after frame 0.
    await page.evaluate((name) => {
        type H = {
            forceAttack: (k: string) => void;
            killPlayer: () => void;
            forcePlayerAction: (action: string) => void;
        };
        const h = (window as unknown as { __megaman_test: H }).__megaman_test;
        switch (name) {
            case "overdrive":      h.forceAttack("overdrive"); break;
            case "groundCombo":    h.forceAttack("groundCombo"); break;
            case "jumpCombo":      h.forceAttack("jumpCombo"); break;
            case "lanceThrow":     h.forceAttack("lanceThrow"); break;
            case "airCombo":       h.forceAttack("airCombo"); break;
            case "playerDash":     h.forcePlayerAction("dashRight"); break;
            case "playerJump":     h.forcePlayerAction("jump"); break;
            case "playerWalkLeft": h.forcePlayerAction("walkLeft"); break;
            case "playerDeath":    h.killPlayer(); break;
        }
    }, scenarioName);

    // Frames 1..N at fixed 500ms cadence, anchored to t0 to avoid drift from
    // the screenshot + IPC overhead.
    for (let i = 1; i < FRAMES; i++) {
        const targetElapsed = i * INTERVAL_MS;
        const wait = targetElapsed - (Date.now() - t0);
        if (wait > 0) await page.waitForTimeout(wait);
        const ms = String(targetElapsed).padStart(4, "0");
        const idx = String(i).padStart(2, "0");
        await page.screenshot({ path: `${outDir}/frame_${idx}_${ms}ms.png`, fullPage: false });
    }

    // Snapshot final harness state for post-mortem alongside the frames.
    const finalState = await page.evaluate(() => {
        type H = Record<string, () => unknown>;
        const h = (window as unknown as { __megaman_test: H }).__megaman_test;
        return {
            player:      h.getInfo(),
            boss:        h.getBossInfo(),
            ai:          h.getAIState(),
            attack:      h.getActiveAttackInfo(),
            projectiles: h.getProjectiles(),
            muzzle:      h.getBossMuzzle()
        };
    });
    console.log(`[capture] scenario=${scenarioName} totalMs=${TOTAL_MS} frames=${FRAMES} dir=${outDir}`);
    console.log(`[capture] finalState=${JSON.stringify(finalState, null, 2)}`);
});
