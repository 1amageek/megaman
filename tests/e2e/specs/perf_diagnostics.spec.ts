import { test, expect, type Page } from "@playwright/test";

async function waitForRunning(page: Page): Promise<void> {
    await expect(page.locator("#status")).toHaveText("Running...", { timeout: 30_000 });
    await expect(page.locator("#error")).toBeHidden();
}

type PerfStats = {
    frameCount: number;
    fps: number;
    phase: string;
    sceneChildren: number;
    totalProjectiles: number;
    liveProjectiles: number;
    deadProjectiles: number;
    playerProjectiles: number;
    bossProjectiles: number;
    totalNodes: number;
    emitters: number;
    particles: number;
    runningActions: number;
    actionNodeBuckets: number;
    orphanedActionNodeBuckets: number;
    textures: number;
    gpuTextures: number;
    jsHeapUsedBytes?: number;
    jsHeapTotalBytes?: number;
};

type Harness = {
    disableBoss: () => void;
    forceAttack: (name: string) => void;
    setPlayerPosition: (x: number, y: number) => void;
    getAIState: () => { phase: string } | null;
    getPerfStats: () => PerfStats | null;
    step: (dtMs?: number, frames?: number) => void;
};

async function bootBattle(page: Page): Promise<void> {
    await page.goto("/");
    await waitForRunning(page);
    await page.waitForFunction(
        () => !!(window as unknown as { __megaman_test?: unknown }).__megaman_test,
        null,
        { timeout: 10_000 }
    );
    await page.waitForFunction(() => {
        const h = (window as unknown as { __megaman_test?: Harness }).__megaman_test;
        return h?.getAIState()?.phase === "fighting";
    }, null, { timeout: 15_000 });
}

test.describe("runtime diagnostics", () => {
    test("transient boss effects do not leave orphaned actions or projectiles", async ({ page }) => {
        await bootBattle(page);

        const samples = await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            const stats: PerfStats[] = [];
            h.disableBoss();

            for (let cycle = 0; cycle < 8; cycle += 1) {
                h.setPlayerPosition(310, 92);
                h.forceAttack("overdrive");
                h.step(1000 / 60, 210);
                h.disableBoss();
                h.step(1000 / 60, 60);
                const sample = h.getPerfStats();
                if (sample) {
                    stats.push(sample);
                }
            }

            return stats;
        });

        expect(samples.length).toBe(8);
        for (const sample of samples) {
            expect(sample.deadProjectiles, `dead projectiles should be removed each tick: ${JSON.stringify(sample)}`).toBe(0);
            expect(sample.orphanedActionNodeBuckets, `removed nodes still have running actions: ${JSON.stringify(sample)}`).toBe(0);
            expect(sample.totalProjectiles, `projectile array should stay bounded: ${JSON.stringify(sample)}`).toBeLessThanOrEqual(2);
            expect(sample.runningActions, `running actions should stay bounded: ${JSON.stringify(sample)}`).toBeLessThanOrEqual(80);
            expect(sample.totalNodes, `scene node count should stay bounded: ${JSON.stringify(sample)}`).toBeLessThanOrEqual(180);
        }
    });
});
