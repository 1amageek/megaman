// Frame-drop probe v4 — stress run with simulated input.
//
// Idle harness sampling shows 100% steady 120Hz. The user reports that drops
// still happen while interacting. This probe drives the player with random
// movement / jump / dash inputs while sampling Swift frameCount per browser
// rAF tick — any window where Swift skips ≥1 frame relative to browser is a
// stall, and we report the perfStats nearby to identify the trigger.

import { test, type Page } from "@playwright/test";

type PerfStats = {
    frameCount: number;
    fps: number;
    phase: string;
    sceneChildren: number;
    totalProjectiles: number;
    liveProjectiles: number;
    deadProjectiles: number;
    totalNodes: number;
    emitters: number;
    particles: number;
    runningActions: number;
    actionNodeBuckets: number;
    orphanedActionNodeBuckets: number;
    textures: number;
    gpuTextures: number;
    jsHeapUsedBytes?: number;
};

type Harness = {
    getPerfStats: () => PerfStats | null;
    getFrameCount: () => number;
    getAIState: () => { phase: string; active?: boolean } | null;
    pressKey?: (key: string, isDown: boolean) => void;
    releaseKeys?: () => void;
    forceAttack?: (name: string) => void;
};

async function bootBattle(page: Page): Promise<void> {
    await page.goto("/");
    await page.waitForFunction(
        () => !!(window as unknown as { __megaman_test?: unknown }).__megaman_test,
        null,
        { timeout: 30_000 }
    );
    await page.waitForFunction(() => {
        const h = (window as unknown as { __megaman_test?: Harness }).__megaman_test;
        return h?.getAIState()?.phase === "fighting";
    }, null, { timeout: 15_000 });
}

test("Swift-render stall under input stress (25s)", async ({ page }) => {
    test.setTimeout(90_000);
    await bootBattle(page);

    const result = await page.evaluate(async () => {
        const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
        type Tick = { t: number; sf: number };
        const ticks: Tick[] = [];
        let raf = 0;
        const start = performance.now();
        const tick = (t: number) => {
            ticks.push({ t, sf: h.getFrameCount() });
            if (t - start < 25_000) raf = requestAnimationFrame(tick);
        };
        raf = requestAnimationFrame(tick);

        // Input pump: cycle through movement / jump / dash patterns while sampling.
        const perfSamples: (PerfStats & { t: number })[] = [];
        const press = (k: string, down: boolean) => h.pressKey?.(k, down);
        const release = () => h.releaseKeys?.();

        // Sequence (15 stages × ~1.5s ≈ 22.5s)
        const stages: (() => void)[] = [
            () => press("ArrowRight", true),
            () => press("Space", true),
            () => { press("ArrowRight", false); press("Space", false); press("Shift", true); press("ArrowLeft", true); },
            () => { press("Shift", false); press("ArrowLeft", false); release(); },
            () => press("ArrowLeft", true),
            () => { press("Space", true); },
            () => { press("ArrowLeft", false); press("Space", false); press("Z", true); },
            () => { press("Z", false); release(); },
            () => press("ArrowRight", true),
            () => { press("Shift", true); },
            () => { press("Shift", false); press("ArrowRight", false); press("Space", true); release(); },
            () => press("ArrowLeft", true),
            () => { press("Z", true); },
            () => { release(); h.forceAttack?.("overdrive"); },
            () => { press("ArrowRight", true); press("Space", true); press("Z", true); },
        ];

        let stageIdx = 0;
        let lastStageT = start;
        while (performance.now() - start < 25_000) {
            await new Promise((r) => setTimeout(r, 100));
            if (performance.now() - lastStageT >= 1500 && stageIdx < stages.length) {
                stages[stageIdx]();
                stageIdx += 1;
                lastStageT = performance.now();
            }
            const s = h.getPerfStats();
            if (s) perfSamples.push({ ...s, t: performance.now() - start });
        }
        release();
        cancelAnimationFrame(raf);
        await new Promise((r) => setTimeout(r, 50));
        return { ticks, perfSamples, t0: start };
    });

    const { ticks, perfSamples, t0 } = result;
    console.log(`browser rAF ticks: ${ticks.length} (${(ticks.length / 25).toFixed(1)} fps avg)`);
    console.log(`perfStats samples: ${perfSamples.length}`);

    if (ticks.length < 10) throw new Error("not enough ticks");

    // Per-tick advance
    const advances: { t: number; dSf: number; dt: number }[] = [];
    for (let i = 1; i < ticks.length; i += 1) {
        advances.push({ t: ticks[i].t - t0, dSf: ticks[i].sf - ticks[i - 1].sf, dt: ticks[i].t - ticks[i - 1].t });
    }

    const bucket: Record<string, number> = {
        "0 (Swift skipped)": 0,
        "1 (synced)": 0,
        "2 (caught up after skip)": 0,
        "3+ (large catch-up)": 0,
    };
    for (const a of advances) {
        if (a.dSf === 0) bucket["0 (Swift skipped)"] += 1;
        else if (a.dSf === 1) bucket["1 (synced)"] += 1;
        else if (a.dSf === 2) bucket["2 (caught up after skip)"] += 1;
        else bucket["3+ (large catch-up)"] += 1;
    }
    console.log("\n=== Swift frameCount advance per browser rAF tick ===");
    for (const [k, v] of Object.entries(bucket)) {
        console.log(`${k.padEnd(28)} ${String(v).padStart(5)}  (${((v / advances.length) * 100).toFixed(1)}%)`);
    }

    // dt distribution
    const dts = advances.map((a) => a.dt).sort((a, b) => a - b);
    console.log(`\nrAF dt: median=${dts[Math.floor(dts.length / 2)].toFixed(2)}ms p95=${dts[Math.floor(dts.length * 0.95)].toFixed(2)}ms p99=${dts[Math.floor(dts.length * 0.99)].toFixed(2)}ms max=${dts[dts.length - 1].toFixed(2)}ms`);

    // Stalls: runs of consecutive zero-advance
    type Stall = { t: number; framesStuck: number; dur: number };
    const stalls: Stall[] = [];
    let runStart = -1;
    let runStartTime = 0;
    for (let i = 0; i < advances.length; i += 1) {
        if (advances[i].dSf === 0) {
            if (runStart < 0) { runStart = i; runStartTime = advances[i].t; }
        } else if (runStart >= 0) {
            const framesStuck = i - runStart;
            const dur = advances[i].t - runStartTime;
            stalls.push({ t: runStartTime, framesStuck, dur });
            runStart = -1;
        }
    }

    // dt-based jank (browser frame interval > 2× normal — even rAF skipped)
    const jank = advances.filter((a) => a.dt > 17).sort((a, b) => b.dt - a.dt);

    stalls.sort((a, b) => b.framesStuck - a.framesStuck);

    console.log(`\nstalls (≥1 missed Swift frame): ${stalls.length}`);
    console.log(`stalls (≥2 — visible jank): ${stalls.filter((s) => s.framesStuck >= 2).length}`);
    console.log(`browser rAF gaps >17ms: ${jank.length}`);

    const findNearestPerf = (t: number) => {
        let best = perfSamples[0]; let bestDelta = Infinity;
        for (const s of perfSamples) {
            const d = Math.abs(s.t - t);
            if (d < bestDelta) { bestDelta = d; best = s; }
        }
        return best;
    };

    const fmtRow = (t: number, label: string) => {
        const ps = findNearestPerf(t);
        const heapMB = ps?.jsHeapUsedBytes ? (ps.jsHeapUsedBytes / 1024 / 1024).toFixed(1) : "?";
        return `${(t / 1000).toFixed(2).padStart(5)}  ${label.padStart(8)}  ${(ps?.phase ?? "?").padEnd(10)} nodes=${String(ps?.totalNodes ?? "?").padStart(4)} parts=${String(ps?.particles ?? "?").padStart(4)} emit=${String(ps?.emitters ?? "?").padStart(3)} acts=${String(ps?.runningActions ?? "?").padStart(3)} bkt=${String(ps?.actionNodeBuckets ?? "?").padStart(3)} liveP=${String(ps?.liveProjectiles ?? "?").padStart(3)} totP=${String(ps?.totalProjectiles ?? "?").padStart(3)} heap=${heapMB.padStart(6)}MB`;
    };

    console.log(`\n=== Top ${Math.min(stalls.length, 25)} worst Swift stalls ===`);
    console.log("t(s)   stuck    phase      diagnostics");
    for (const s of stalls.slice(0, 25)) {
        console.log(fmtRow(s.t, `${s.framesStuck}f/${s.dur.toFixed(0)}ms`));
    }

    console.log(`\n=== Top ${Math.min(jank.length, 15)} browser rAF gaps ===`);
    console.log("t(s)   dt(ms)   phase      diagnostics");
    for (const j of jank.slice(0, 15)) {
        console.log(fmtRow(j.t, `${j.dt.toFixed(1)}ms`));
    }

    console.log("\n=== Phase timeline ===");
    let prevPhase = perfSamples[0]?.phase; let pStart = 0;
    for (const s of perfSamples) {
        if (s.phase !== prevPhase) {
            console.log(`${(pStart / 1000).toFixed(2)}s - ${(s.t / 1000).toFixed(2)}s : ${prevPhase}`);
            prevPhase = s.phase; pStart = s.t;
        }
    }
    if (perfSamples.length > 0) {
        console.log(`${(pStart / 1000).toFixed(2)}s - ${(perfSamples[perfSamples.length - 1].t / 1000).toFixed(2)}s : ${prevPhase}`);
    }

    if (perfSamples[0]?.jsHeapUsedBytes && perfSamples[perfSamples.length - 1]?.jsHeapUsedBytes) {
        const a = perfSamples[0].jsHeapUsedBytes;
        const b = perfSamples[perfSamples.length - 1].jsHeapUsedBytes;
        console.log(`\nJS heap: ${(a / 1024 / 1024).toFixed(1)}MB → ${(b / 1024 / 1024).toFixed(1)}MB (delta ${((b - a) / 1024 / 1024).toFixed(2)}MB over 25s)`);
    }
});
