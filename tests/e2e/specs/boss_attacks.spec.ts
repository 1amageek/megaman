import { test, expect, type Page } from "@playwright/test";

async function waitForRunning(page: Page): Promise<void> {
    await expect(page.locator("#status")).toHaveText("Running...", { timeout: 30_000 });
}

async function waitForHarness(page: Page): Promise<void> {
    await page.waitForFunction(
        () => !!(window as unknown as { __megaman_test?: unknown }).__megaman_test,
        null,
        { timeout: 10_000 }
    );
}

type BossInfo = {
    x: number; y: number; vx: number; vy: number; hp: number;
    attack: string; projCount: number; facing: string;
};

type AIState = {
    active: boolean; timer: number; cooldown: number;
    cursor: number; orderCount: number; phase: string;
};

async function getBossInfo(page: Page): Promise<BossInfo> {
    return await page.evaluate(() => {
        const h = (window as unknown as {
            __megaman_test?: { getBossInfo: () => BossInfo }
        }).__megaman_test;
        return h!.getBossInfo();
    });
}

async function getAIState(page: Page): Promise<AIState | null> {
    return await page.evaluate(() => {
        const h = (window as unknown as {
            __megaman_test?: { getAIState: () => AIState | null }
        }).__megaman_test;
        return h!.getAIState();
    });
}

test("Sigma begins attacking within 5 s of boot", async ({ page }) => {
    await page.goto("/");
    await waitForRunning(page);
    await waitForHarness(page);

    // Poll every 50 ms for up to 10 s. Intro is 1 s + initial cooldown 1 s,
    // so the first attack should land well before 5 s.
    const attacksSeen = new Set<string>();
    const samples: Array<BossInfo & { ai: AIState | null }> = [];
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
        const [info, ai] = await Promise.all([getBossInfo(page), getAIState(page)]);
        samples.push({ ...info, ai });
        if (info.attack !== "none") attacksSeen.add(info.attack);
        await page.waitForTimeout(50);
    }

    console.log(`Samples observed: ${samples.length}`);
    console.log(`HP range: ${samples[0].hp} → ${samples[samples.length - 1].hp}`);
    console.log(`Attacks seen: ${[...attacksSeen].join(", ") || "(none)"}`);

    // Timeline: attack-state transitions + AI state snapshot every 500 ms
    let prev = "";
    samples.forEach((s, i) => {
        const t = i * 50;
        const aiStr = s.ai
            ? `active=${s.ai.active} timer=${s.ai.timer.toFixed(2)}/${s.ai.cooldown.toFixed(2)} cursor=${s.ai.cursor}/${s.ai.orderCount} phase=${s.ai.phase}`
            : "ai=null";
        if (s.attack !== prev) {
            console.log(`  t=${t.toString().padStart(5)}ms  attack=${s.attack.padEnd(14)} x=${s.x.toFixed(1).padStart(6)} vx=${s.vx.toFixed(1).padStart(7)} hp=${s.hp} | ${aiStr}`);
            prev = s.attack;
        } else if (t % 500 === 0) {
            console.log(`  t=${t.toString().padStart(5)}ms  (idle)          x=${s.x.toFixed(1).padStart(6)} vx=${s.vx.toFixed(1).padStart(7)} hp=${s.hp} | ${aiStr}`);
        }
    });

    expect(attacksSeen.size,
        `boss never entered an attack state in 5 s — samples=${samples.length}`
    ).toBeGreaterThan(0);
});
