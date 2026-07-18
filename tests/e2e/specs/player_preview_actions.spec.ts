import { test, expect } from "@playwright/test";

// Smoke test for the player-preview ACTIONS feature. Verifies the
// compound-action UI renders, that an action's first step plays, and
// that selecting a tag manually clears any in-flight action so the
// click takes effect.
test("player-preview shows ACTIONS list and plays a chain", async ({ page }) => {
    await page.goto("/assets/player-preview.html");
    const actions = page.locator("#actionList button");
    await expect(actions).toHaveCount(33);

    // Click the spawn action. First step should be the "beam" tag.
    await page.locator('#actionList button[data-action="spawn"]').click();
    await expect(page.locator("#iTag")).toContainText("beam");

    // Wait long enough that the chain reaches the terminal `idle` step.
    // Sequence durations: beam (~100ms) + beam_in (~260ms) + beam_armor
    // (~2160ms) ≈ 2.5s; give it 4s of slack.
    await page.waitForFunction(() => {
        const txt = document.getElementById("iTag")?.textContent ?? "";
        return /idle/.test(txt);
    }, undefined, { timeout: 5_000 });
    await expect(page.locator("#iTag")).toContainText("idle");

    // Manual tag selection should drop the active action.
    await page.locator('#tagList button[data-tag="walk"]').click();
    await expect(page.locator("#actionList button.active")).toHaveCount(0);
    await expect(page.locator("#iTag")).toHaveText("walk");
});

// `fall` is loop=false in Godot's SpriteFrames resource: when the chain
// reaches it (e.g. via the Jump action), the 4-frame cycle plays once
// and freezes on the last frame (87) while the player remains airborne.
// Looping `fall` would be a regression — the airborne pose would flicker
// frame 84↔87 forever instead of holding the descent silhouette.
test("player-preview parks on fall last frame instead of looping", async ({ page }) => {
    await page.goto("/assets/player-preview.html");
    await page.locator('#actionList button[data-action="jump"]').click();
    // Wait for jump (4 frames @ ~80ms each ≈ 320ms) to finish and chain
    // into fall, then for fall (4 frames) to play through once.
    await page.waitForFunction(
        () => document.getElementById("iTag")?.textContent?.startsWith("fall"),
        undefined,
        { timeout: 2_000 },
    );
    // Give the fall cycle time to finish at least once (fall lasts ~320ms).
    await page.waitForTimeout(800);
    // After freezing, sample the frame twice — it must not budge.
    const first = await page.locator("#iAtlasFrame").textContent();
    await page.waitForTimeout(400);
    const second = await page.locator("#iAtlasFrame").textContent();
    expect(first).toBe("87");   // last frame of fall (84–87)
    expect(second).toBe("87");
});

// `idle` is loop=true — the terminal idle of the Spawn action must keep
// cycling through frames 30–32, not freeze.
test("player-preview keeps idle cycling on the terminal step", async ({ page }) => {
    await page.goto("/assets/player-preview.html");
    await page.locator('#actionList button[data-action="spawn"]').click();
    await page.waitForFunction(
        () => /idle/.test(document.getElementById("iTag")?.textContent ?? ""),
        undefined,
        { timeout: 5_000 },
    );
    // Sample three times across ~500ms; we should observe at least two
    // distinct frame values within 30–32 (idle range).
    const samples = new Set<string>();
    for (let i = 0; i < 5; i++) {
        samples.add((await page.locator("#iAtlasFrame").textContent()) ?? "");
        await page.waitForTimeout(120);
    }
    expect(samples.size).toBeGreaterThan(1);
    for (const s of samples) {
        expect(["30", "31", "32"]).toContain(s);
    }
});
