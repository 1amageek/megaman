import { test, expect, type Page } from "@playwright/test";

// Verifies the Godot-parity death sequence: once HP hits zero the phase
// transitions to .defeat, holds for ~5 s (fade window), then resetBattle
// returns the scene to .intro with a fresh boss. This exercises the full
// `Player.die → tickDeathSequence → Scene.onPlayerDeath → resetBattle` loop.

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

type AIState = {
    active: boolean; timer: number; cooldown: number;
    cursor: number; orderCount: number; phase: string;
};

async function getPhase(page: Page): Promise<string | null> {
    const ai = await page.evaluate<AIState | null>(() => {
        const h = (window as unknown as {
            __megaman_test?: { getAIState: () => AIState | null }
        }).__megaman_test;
        return h!.getAIState();
    });
    return ai?.phase ?? null;
}

test("Player death sequence fades and returns to .intro after ~5 s", async ({ page }) => {
    await page.goto("/");
    await waitForRunning(page);
    await waitForHarness(page);

    // Passive contact damage is 8/frame — parking the Player on top of the
    // boss drains HP quickly. The harness default Player spawn sits to the
    // left of Sigma, so the boss will often walk into us as it approaches.
    // 20 s budget: ~4.76 s Godot-parity Sigma intro + up to ~4 s to first
    // defeat + 5 s defeat window + ~6 s headroom for the second intro cycle
    // (which replays the full cutscene via `resetBattle`).
    const start = Date.now();
    const deadline = start + 20_000;
    const phases: { t: number; phase: string }[] = [];
    let sawDefeat = false;
    let sawIntroAfterDefeat = false;

    while (Date.now() < deadline) {
        const phase = await getPhase(page);
        if (phase) {
            const t = Date.now() - start;
            if (phases.length === 0 || phases[phases.length - 1].phase !== phase) {
                phases.push({ t, phase });
            }
            if (phase === "defeat") sawDefeat = true;
            if (sawDefeat && phase === "intro") sawIntroAfterDefeat = true;
            if (sawIntroAfterDefeat) break;
        }
        await page.waitForTimeout(100);
    }

    console.log("Phase timeline:");
    phases.forEach(p => console.log(`  t=${p.t.toString().padStart(6)}ms  phase=${p.phase}`));

    expect(sawDefeat, "phase never reached .defeat within budget").toBe(true);
    expect(sawIntroAfterDefeat,
        "scene did not restart to .intro after .defeat — reset loop broken"
    ).toBe(true);

    // Sanity: defeat should hold for at least 4.5 s before returning (Godot
    // PlayerDeath timer > 5.0). Any less would mean the fade/reset fires
    // early and the player never sees the full sequence.
    const defeatEntry = phases.find(p => p.phase === "defeat")!;
    const afterDefeat = phases.find(p => p.t > defeatEntry.t && p.phase !== "defeat")!;
    expect(afterDefeat.t - defeatEntry.t,
        "defeat → reset was faster than the 5 s Godot sequence"
    ).toBeGreaterThanOrEqual(4_500);
});
