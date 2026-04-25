import { test, expect, type Page } from "@playwright/test";

// Input plumbing smoke. Uses the Swift-side debug harness exposed on
// `window.__megaman_test` (see Sources/WasmApp/main.swift `installTestHarness`)
// so the assertion is deterministic — we read the actual Player.position.x
// before and after the keypress rather than diffing pixels.

async function waitForRunning(page: Page): Promise<void> {
    await expect(page.locator("#status")).toHaveText("Running...", { timeout: 30_000 });
    await expect(page.locator("#error")).toBeHidden();
}

// Poll for the test harness to appear. `installTestHarness()` runs after the
// scene and renderer finish async initialisation, which may trail the "Running..."
// status by one tick.
async function waitForHarness(page: Page): Promise<void> {
    await page.waitForFunction(
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        () => !!(window as unknown as { __megaman_test?: unknown }).__megaman_test,
        null,
        { timeout: 10_000 }
    );
}

interface PlayerInfo {
    x: number; y: number; vx: number; vy: number;
    state: string; facing: "left" | "right"; onFloor: boolean;
}

async function playerInfo(page: Page): Promise<PlayerInfo | null> {
    return await page.evaluate(() => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const h = (window as unknown as { __megaman_test?: { getInfo: () => PlayerInfo | null } }).__megaman_test;
        return h ? h.getInfo() : null;
    });
}

// Tear the boss AI offline so input-plumbing assertions don't race Sigma's
// attack window. BossAI.deactivate cancels the in-flight attack and stops
// the scheduler; clearBossProjectiles drops any lance/sprite already in air.
// See main.swift → `disableBoss` harness closure.
async function disableBoss(page: Page): Promise<void> {
    await page.evaluate(() => {
        const h = (window as unknown as { __megaman_test?: { disableBoss: () => void } }).__megaman_test;
        h?.disableBoss();
    });
}

test.describe("megaman input pipeline", () => {
    test("ArrowRight translates Player.position.x to the right", async ({ page }) => {
        await page.goto("/");
        await waitForRunning(page);
        await waitForHarness(page);
        // The 9-stage Sigma intro (~4.76 s) keeps player.tick gated off;
        // settle past it before the press so the assertion measures real
        // input propagation, not the cutscene lock.
        await page.waitForTimeout(5_300);
        await disableBoss(page);

        const before = await playerInfo(page);
        expect(before, "player info unavailable — harness not wired?").not.toBeNull();
        expect(before!.onFloor, "player should spawn on the floor").toBe(true);

        // Hold ArrowRight for 600 ms. At the Godot-parity walk speed (~140 px/s)
        // the player translates >80 px, far above any plausible idle jitter.
        await page.keyboard.down("ArrowRight");
        await page.waitForTimeout(600);
        const after = await playerInfo(page);
        await page.keyboard.up("ArrowRight");

        expect(after, "player info unavailable after input").not.toBeNull();
        const dx = after!.x - before!.x;
        expect(
            dx,
            `Player did not move right: before.x=${before!.x.toFixed(1)} after.x=${after!.x.toFixed(1)} state=${after!.state} facing=${after!.facing}`
        ).toBeGreaterThan(20);
        expect(after!.facing, "player should face right after ArrowRight").toBe("right");
    });

    test("Space lifts Player off the floor (jump)", async ({ page }) => {
        await page.goto("/");
        await waitForRunning(page);
        await waitForHarness(page);

        // BossBattleScene now runs the full 9-stage Godot-parity Sigma intro
        // (~4.76 s total). `player.tick` is skipped for the entire cutscene,
        // so settle past it before asserting input wiring.
        await page.waitForTimeout(5_300);
        await disableBoss(page);

        const before = await playerInfo(page);
        expect(before!.onFloor, "player should start grounded").toBe(true);

        // Jump is edge-triggered (`jumpPressed`). Hold Space briefly so the
        // press edge is observed by at least one game tick.
        await page.keyboard.down("Space");
        await page.waitForTimeout(250);
        const midAir = await playerInfo(page);
        await page.keyboard.up("Space");

        expect(
            midAir!.onFloor,
            `player should be airborne after Space: before=${JSON.stringify(before)} mid=${JSON.stringify(midAir)}`
        ).toBe(false);
        // Swift convention: Y-up-positive, so y increases while rising.
        expect(
            midAir!.y - before!.y,
            `player did not rise: before.y=${before!.y.toFixed(1)} mid.y=${midAir!.y.toFixed(1)}`
        ).toBeGreaterThan(5);

        // Let the jump arc complete; confirm the player returns to the floor.
        // 1.5 s is enough for the full up/down arc under all gravity scales.
        await page.waitForTimeout(1_500);
        const landed = await playerInfo(page);
        expect(landed!.onFloor, "player should land back on the floor").toBe(true);
    });

    test("ArrowLeft translates Player.position.x to the left", async ({ page }) => {
        await page.goto("/");
        await waitForRunning(page);
        await waitForHarness(page);
        // Settle past the Sigma intro — see above comment.
        await page.waitForTimeout(5_300);
        await disableBoss(page);

        // Move right first so we have headroom to move left without hitting
        // the stage-edge clamp on spawn.
        await page.keyboard.down("ArrowRight");
        await page.waitForTimeout(400);
        await page.keyboard.up("ArrowRight");
        await page.waitForTimeout(100);

        const before = await playerInfo(page);
        await page.keyboard.down("ArrowLeft");
        await page.waitForTimeout(500);
        const after = await playerInfo(page);
        await page.keyboard.up("ArrowLeft");

        const dx = after!.x - before!.x;
        expect(
            dx,
            `Player did not move left: before.x=${before!.x.toFixed(1)} after.x=${after!.x.toFixed(1)}`
        ).toBeLessThan(-20);
        expect(after!.facing, "player should face left after ArrowLeft").toBe("left");
    });
});
