import { test, expect, type Page } from "@playwright/test";

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

type PlayerInfo = {
    x: number; y: number; vx: number; vy: number;
    state: string; facing: "left" | "right"; onFloor: boolean;
};

type BossInfo = {
    hp: number; attack: string; projCount: number;
};

type DamageResult = {
    applied: boolean; hp: number;
};

type Harness = {
    disableBoss: () => void;
    forceAttack: (name: string) => void;
    setState: (state: string, facing?: "left" | "right") => void;
    release: () => void;
    setPlayerPosition: (x: number, y: number) => void;
    damageBoss: (amount: number) => DamageResult;
    getInfo: () => PlayerInfo | null;
    getBossInfo: () => BossInfo;
    getAIState: () => { phase: string } | null;
    step: (dtMs?: number, frames?: number) => void;
};

async function bootBattle(page: Page): Promise<void> {
    await page.goto("/");
    await waitForRunning(page);
    await waitForHarness(page);
    await page.waitForFunction(() => {
        const h = (window as unknown as { __megaman_test?: Harness }).__megaman_test;
        return h?.getAIState()?.phase === "fighting";
    }, null, { timeout: 15_000 });
}

test.describe("combat and wall behavior", () => {
    test("boss accepts consecutive normal hits after short boss invulnerability", async ({ page }) => {
        await bootBattle(page);

        const result = await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            h.disableBoss();
            const first = h.damageBoss(2);
            h.step(1000 / 60, 7);
            const second = h.damageBoss(2);
            return { first, second, hp: h.getBossInfo().hp };
        });

        expect(result.first.applied, "first hit should damage the boss").toBe(true);
        expect(result.second.applied, "second hit after 100 ms should not be blocked by player invulnerability timing").toBe(true);
        expect(result.hp, `unexpected boss HP after two 2-damage hits: ${JSON.stringify(result)}`).toBe(256);
    });

    test("boss projectile attacks spawn the intended number of hazards", async ({ page }) => {
        await bootBattle(page);

        const counts = await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            function sampleAttack(name: string, frames: number): number {
                h.disableBoss();
                h.forceAttack(name);
                let maxProjectiles = 0;
                for (let i = 0; i < frames; i += 1) {
                    h.step(1000 / 60, 1);
                    maxProjectiles = Math.max(maxProjectiles, h.getBossInfo().projCount);
                }
                return maxProjectiles;
            }

            return {
                groundCombo: sampleAttack("groundCombo", 150),
                lanceThrow: sampleAttack("lanceThrow", 180),
                airCombo: sampleAttack("airCombo", 210),
            };
        });

        expect(counts.groundCombo, `GroundCombo should emit only slash_3 wave: ${JSON.stringify(counts)}`).toBeLessThanOrEqual(1);
        expect(counts.lanceThrow, `LanceThrow should emit two lances total: ${JSON.stringify(counts)}`).toBeLessThanOrEqual(2);
        expect(counts.airCombo, `AirCombo should emit two aimed balls total: ${JSON.stringify(counts)}`).toBeLessThanOrEqual(2);
    });

    test("player can enter wall slide and wall jump away from the side wall", async ({ page }) => {
        await bootBattle(page);

        await page.keyboard.down("ArrowLeft");
        const result = await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            h.disableBoss();
            h.setState("fall", "left");
            h.setPlayerPosition(11, 92);
            h.release();
            return h.getInfo();
        });
        expect(result?.onFloor, "setup should place player in air").toBe(false);

        await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            h.step(1000 / 60, 2);
        });
        const slide = await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            return h.getInfo();
        });
        expect(slide?.state, `expected wall slide at left wall: ${JSON.stringify(slide)}`).toBe("slide");

        await page.keyboard.down("Space");
        await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            h.step(1000 / 60, 2);
        });
        const jump = await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            return h.getInfo();
        });
        await page.keyboard.up("Space");
        await page.keyboard.up("ArrowLeft");

        expect(jump?.state, `expected wall jump after pressing jump on wall: ${JSON.stringify(jump)}`).toBe("wallJump");
        // Godot Walljump.gd:_Setup faces TOWARD the wall during the kick pose
        // (set_direction(- walljump_direction)). Off the LEFT wall the sprite
        // faces left while velocity launches right.
        expect(jump?.facing).toBe("left");
        expect(jump?.vx ?? 0, `wall jump should push away from left wall: ${JSON.stringify(jump)}`).toBeGreaterThan(50);
        expect(jump?.vy ?? 0, `wall jump should launch upward: ${JSON.stringify(jump)}`).toBeGreaterThan(100);
    });

    test("player can re-enter wall slide after a wall jump arcs back into the wall", async ({ page }) => {
        await bootBattle(page);

        await page.keyboard.down("ArrowLeft");
        await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            h.disableBoss();
            h.setState("fall", "left");
            h.setPlayerPosition(11, 92);
            h.release();
        });

        // Wait for slide entry against the LEFT wall.
        await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            for (let i = 0; i < 30; i += 1) {
                h.step(1000 / 60, 1);
                if (h.getInfo()?.state === "slide") break;
            }
        });
        const slide = await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            return h.getInfo();
        });
        expect(slide?.state, `expected wall slide before kick: ${JSON.stringify(slide)}`).toBe("slide");

        // Tap Space to kick off the wall.
        await page.keyboard.down("Space");
        await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            h.step(1000 / 60, 2);
        });
        await page.keyboard.up("Space");
        const kick = await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            return h.getInfo();
        });
        expect(kick?.state, `expected wall jump after Space: ${JSON.stringify(kick)}`).toBe("wallJump");

        // Continue holding ArrowLeft so the player arcs back into the same wall.
        // Godot WallSlide.conflicting_moves contains "WallJump" — sliding must
        // be able to interrupt the in-flight wall jump on contact.
        const arc = await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            for (let i = 0; i < 240; i += 1) {
                h.step(1000 / 60, 1);
                const s = h.getInfo();
                if (s?.state === "slide" && i > 4) {
                    return { reentered: true, frame: i, info: s };
                }
                if (s?.onFloor && i > 10) {
                    return { reentered: false, frame: i, info: s, reason: "landed before re-slide" };
                }
            }
            return { reentered: false, frame: -1, info: h.getInfo(), reason: "timeout" };
        });
        await page.keyboard.up("ArrowLeft");

        expect(arc.reentered, `expected re-slide after kick → arc back to wall: ${JSON.stringify(arc)}`).toBe(true);
    });
});
