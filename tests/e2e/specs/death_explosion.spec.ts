import { test, expect, type Page } from "@playwright/test";

// Verifies that the death-explosion sparkles actually animate. The root-cause
// fix in OpenSpriteKit SKActionRunner was: `SKAction.sequence([.group([...]),
// .removeFromParent()])` never ran its grandchild actions because the outer
// sequence created a RunningAction for the group without recursively
// initializing childStates, turning the group execute-branch into a silent
// no-op. This spec drives Player into .dead (via the harness), steps the
// simulation through the 0.5s pre-burst + 0.6s into the first burst, then
// inspects the scene tree for sparkles whose alpha + xScale diverged from
// the spawn-time values (alpha=0, xScale=0.2). At least one must show
// alpha ≥ 0.2 and xScale ≥ 0.4 — anything else means the compound actions
// still silently no-op.

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

interface NodeSnap {
    name: string;
    x: number;
    y: number;
    z: number;
    alpha: number;
    xScale: number;
    yScale: number;
    hidden: boolean;
    childCount: number;
    children?: NodeSnap[];
}

// Each X-burst container is an SKNode at z=70 with 8 sparkle SKSpriteNode
// children (Godot xdeath_0..xdeath_8 — 8 compass directions). Walk to depth 2
// to collect the SKSpriteNode sparkles themselves, not the container — the
// container sits at α=1 / scale=1 by default and would mask a regression
// where the sparkles' own compound-action group silently no-ops.
function collectSparkles(node: NodeSnap, out: NodeSnap[]): void {
    if (node.name === "SKNode" && node.z === 70 && node.children) {
        for (const c of node.children) {
            if (c.name === "SKSpriteNode") out.push(c);
        }
        return;
    }
    if (node.children) {
        for (const c of node.children) collectSparkles(c, out);
    }
}

test("death explosion sparkles animate alpha + xScale away from spawn values", async ({ page }) => {
    await page.goto("/");
    await waitForRunning(page);
    await waitForHarness(page);

    // Wait out the 9-stage Sigma intro (~4.76 s of Godot-parity cutscene).
    // During `.intro`, the scene update path runs ONLY the cutscene tick —
    // `player.tick` (and therefore `tickDeathSequence`) is skipped. Headroom
    // for animation frame rounding on slower machines.
    await page.waitForTimeout(5_300);

    // Drop the boss so Sigma's attacks / contact damage can't interfere
    // with the forced .dead state during the step window.
    await page.evaluate(() => {
        (window as unknown as {
            __megaman_test: { disableBoss: () => void };
        }).__megaman_test.disableBoss();
    });

    // Apply lethal damage so the natural `die()` transition runs.
    // Draining HP + calling `die()` is what actually primes deathTimer/flags;
    // `setState("dead")` bypasses that priming and — as a bonus — calls
    // `debugForce` which leaves state pinned but does NOT initialize the
    // death sequence bookkeeping, so `tickDeathSequence` never spawns.
    await page.evaluate(() => {
        (window as unknown as {
            __megaman_test: { killPlayer: () => void };
        }).__megaman_test.killPlayer();
    });

    // Pre-kill diagnostics so a 0-sparkle outcome isn't ambiguous between
    // "phase blocked" and "actions silently no-op".
    const before = await page.evaluate(() => {
        const h = (window as unknown as {
            __megaman_test: {
                getAIState: () => { phase: string } | null;
                getInfo: () => { state: string } | null;
            };
        }).__megaman_test;
        return { ai: h.getAIState(), info: h.getInfo() };
    });
    console.log(`before kill: phase=${before.ai?.phase} playerState=${before.info?.state}`);

    // Natural rAF wait — ~1.1 s is past the 0.5 s pre-burst and ~0.6 s into
    // the first sparkle's 1.0 s lifetime. By now each sparkle should be
    // mid-group-action with alpha held at 1.0 and xScale near 1.2.
    await page.waitForTimeout(1_100);

    const after = await page.evaluate(() => {
        const h = (window as unknown as {
            __megaman_test: {
                getAIState: () => { phase: string } | null;
                getInfo: () => { state: string } | null;
            };
        }).__megaman_test;
        return { ai: h.getAIState(), info: h.getInfo() };
    });
    console.log(`after 1.1s: phase=${after.ai?.phase} playerState=${after.info?.state}`);

    // Pull the scene tree (depth 3: Scene → container → sparkle sprite).
    const roots = await page.evaluate(() => {
        const h = (window as unknown as {
            __megaman_test: { getSceneChildren: (depth: number) => NodeSnap[] };
        }).__megaman_test;
        return h.getSceneChildren(3);
    }) as NodeSnap[];

    const sparkles: NodeSnap[] = [];
    for (const root of roots) collectSparkles(root, sparkles);

    // Debug: dump scene's top-level node names + child counts so we can tell
    // whether the death container was added at all.
    console.log(`scene.children at depth 3:`);
    roots.forEach((r, i) => {
        console.log(`  [${i}] ${r.name} z=${r.z.toFixed(0)} childCount=${r.childCount} α=${r.alpha.toFixed(2)} xS=${r.xScale.toFixed(2)}`);
        if (r.children) {
            r.children.slice(0, 12).forEach((c, j) => {
                console.log(`    └[${j}] ${c.name} z=${c.z.toFixed(0)} childCount=${c.childCount} α=${c.alpha.toFixed(2)} xS=${c.xScale.toFixed(2)}`);
            });
        }
    });

    console.log(`found ${sparkles.length} candidate sparkle sprites`);
    sparkles.slice(0, 16).forEach((s, i) => {
        console.log(`  #${i} α=${s.alpha.toFixed(2)} xS=${s.xScale.toFixed(2)} yS=${s.yScale.toFixed(2)} pos=(${s.x.toFixed(1)},${s.y.toFixed(1)})`);
    });

    // A freshly-spawned sparkle has alpha=0 and xScale=0.2. Any sparkle past
    // the first few frames of its group should have alpha ≥ 0.2 and xScale
    // noticeably larger. If ALL sparkles are still at spawn values, the
    // grandchild actions inside the group aren't ticking.
    const animated = sparkles.filter(s => s.alpha >= 0.2 && s.xScale >= 0.4);
    expect(
        animated.length,
        `no sparkle showed animated alpha≥0.2 AND xScale≥0.4 — compound actions silent no-op? total candidates: ${sparkles.length}`
    ).toBeGreaterThan(0);
});
