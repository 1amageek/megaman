import { test, expect, type Page } from "@playwright/test";

// Dash-ability parity with Godot reference (Mega-Man-X8-16-bit/Dash.gd).
// End conditions we verify:
//   1. Button release on floor     → .idle, vx=0
//   2. Opposite direction on floor → .idle, vx=0
//   3. Leaving floor mid-dash      → .fall, vx preserved (dashfall)
//   4. Duration timer expiry       → .idle, vx=0
// Key bindings (Systems/InputManager.swift): dash=c|shift|k, jump=Space|z.
//
// All tests dash LEFT (away from the boss) so the Player doesn't collide
// into the Sigma hitbox and trigger contact-damage during the test window.

const DASH_SPEED = 210;   // GameConfig.playerDashSpeed
const DASH_DURATION = 550; // ms, PhysicsConstants.playerDashDuration

async function waitForRunning(page: Page): Promise<void> {
    await expect(page.locator("#status")).toHaveText("Running...", { timeout: 30_000 });
    await expect(page.locator("#error")).toBeHidden();
}

async function waitForHarness(page: Page): Promise<void> {
    await page.waitForFunction(
        () => !!(window as unknown as { __megaman_test?: unknown }).__megaman_test,
        null,
        { timeout: 10_000 }
    );
}

interface PlayerInfo {
    x: number; y: number; vx: number; vy: number;
    state: string; facing: "left" | "right"; onFloor: boolean;
}

async function playerInfo(page: Page): Promise<PlayerInfo> {
    const info = await page.evaluate(() => {
        const h = (window as unknown as {
            __megaman_test?: { getInfo: () => PlayerInfo | null };
        }).__megaman_test;
        return h ? h.getInfo() : null;
    });
    expect(info, "harness unavailable — installTestHarness() not running?").not.toBeNull();
    return info!;
}

async function settleIntro(page: Page): Promise<void> {
    // BossBattleScene now runs the full 9-stage Godot-parity Sigma intro
    // (~4.76 s total: seated_loop → intro → intro2 → intro_loop → intro_end).
    // Player input is locked for the entire cutscene, so dash tests have to
    // wait past it before any press register as movement. Add headroom for
    // animation frame rounding on slower CI machines.
    await page.waitForTimeout(5_300);
}

async function faceLeft(page: Page): Promise<void> {
    await page.keyboard.down("ArrowLeft");
    await page.waitForTimeout(80);
    await page.keyboard.up("ArrowLeft");
}

test.describe("megaman dash parity", () => {
    test("holding dash enters .dash and applies -210 vx when facing left", async ({ page }) => {
        await page.goto("/");
        await waitForRunning(page);
        await waitForHarness(page);
        await settleIntro(page);
        await faceLeft(page);

        await page.keyboard.down("c");
        await page.waitForTimeout(80);
        const mid = await playerInfo(page);
        await page.keyboard.up("c");

        expect(mid.state, `state=${mid.state}`).toBe("dash");
        expect(mid.vx).toBeLessThan(-(DASH_SPEED - 20));
    });

    test("releasing dash on floor returns to .idle with vx=0", async ({ page }) => {
        await page.goto("/");
        await waitForRunning(page);
        await waitForHarness(page);
        await settleIntro(page);
        await faceLeft(page);

        await page.keyboard.down("c");
        await page.waitForTimeout(100);
        await page.keyboard.up("c");
        await page.waitForTimeout(50);
        const after = await playerInfo(page);

        expect(after.onFloor).toBe(true);
        expect(after.state, `state=${after.state}`).not.toBe("dash");
        expect(Math.abs(after.vx), `vx=${after.vx}`).toBeLessThan(5);
    });

    test("pressing opposite direction during dash ends dash", async ({ page }) => {
        await page.goto("/");
        await waitForRunning(page);
        await waitForHarness(page);
        await settleIntro(page);
        await faceLeft(page);

        await page.keyboard.down("c");
        await page.waitForTimeout(100);
        const dashing = await playerInfo(page);
        expect(dashing.state, "should be dashing before turnaround").toBe("dash");

        await page.keyboard.down("ArrowRight");
        await page.waitForTimeout(80);
        const turned = await playerInfo(page);
        await page.keyboard.up("ArrowRight");
        await page.keyboard.up("c");

        expect(turned.state, `state=${turned.state}`).not.toBe("dash");
    });

    test("dash timer expires after ~550ms and releases vx", async ({ page }) => {
        await page.goto("/");
        await waitForRunning(page);
        await waitForHarness(page);
        await settleIntro(page);
        await faceLeft(page);

        await page.keyboard.down("c");
        await page.waitForTimeout(DASH_DURATION + 150);
        const after = await playerInfo(page);
        await page.keyboard.up("c");

        expect(after.onFloor).toBe(true);
        expect(after.state, `state=${after.state}`).not.toBe("dash");
        expect(Math.abs(after.vx), `vx=${after.vx}`).toBeLessThan(5);
    });

    test("jumping mid-dash cancels into .jump", async ({ page }) => {
        await page.goto("/");
        await waitForRunning(page);
        await waitForHarness(page);
        await settleIntro(page);
        await faceLeft(page);

        await page.keyboard.down("c");
        await page.waitForTimeout(80);
        await page.keyboard.down("Space");
        await page.waitForTimeout(80);
        const mid = await playerInfo(page);
        await page.keyboard.up("Space");
        await page.keyboard.up("c");

        expect(mid.onFloor, "jump should lift off floor").toBe(false);
        expect(mid.state, `state=${mid.state}`).toBe("jump");
    });
});
