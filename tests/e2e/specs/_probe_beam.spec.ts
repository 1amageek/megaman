import { test, type Page } from "@playwright/test";

async function waitForRunning(page: Page): Promise<void> {
    await page.locator("#status").waitFor();
    await page.waitForFunction(() => document.querySelector("#status")?.textContent === "Running...");
}

type Harness = {
    forceAttack: (name: string) => void;
    disableBoss: () => void;
    getBossInfo: () => { attack: string; projCount: number; x: number; y: number; hp: number };
    getInfo: () => { x: number; y: number; state: string } | null;
    getAIState: () => { phase: string; active: boolean } | null;
    getSceneChildren: (depth?: number) => unknown[];
    killPlayer: () => void;
    pause: () => void;
    resume: () => void;
};

test.use({
    viewport: { width: 1148, height: 1064 },
    launchOptions: {
        headless: false,
        args: ["--enable-unsafe-webgpu", "--enable-webgpu-developer-features", "--use-angle=metal"]
    }
});

test("probe — capture beam mid-fire", async ({ page }) => {
    const consoleLines: string[] = [];
    page.on("console", msg => {
        const t = msg.text();
        if (t.includes("sigma_laser") || t.includes("WARNING")) {
            consoleLines.push(`[${msg.type()}] ${t}`);
        }
    });
    await page.goto("/");
    await waitForRunning(page);
    await page.waitForFunction(() => !!(window as unknown as { __megaman_test?: unknown }).__megaman_test, null, { timeout: 10_000 });
    await page.waitForTimeout(5_300);
    console.log("=== CONSOLE (sigma_laser / WARNING) ===");
    for (const l of consoleLines) console.log(l);
    console.log("=== END CONSOLE ===");

    // Kill player FIRST so they can't die to the beam and occlude it with death sparkles.
    await page.evaluate(() => {
        const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
        // Force overdrive first (so boss AI schedules the attack), then wait
        // for firing to begin before killing the player, so the beam is
        // actually spawned. During firing the beam lives on even if player
        // dies (projectiles survive enterDefeat per the recent fix).
        h.forceAttack("overdrive");
    });

    // Phases: prepare 0-0.4, chargeLoop 0.4-1.6, startFiring 1.6-1.9, firing 1.9-4.3, cooldown 4.3-5.3.
    // After the fix (boss projectiles survive enterDefeat), the beam should
    // remain visible throughout the 2.4 s firing window even if the player
    // dies on contact. Sample across the full firing window.
    const schedule = [
        { at: 1600, tag: "t1600_pre_fire" },
        { at: 1800, tag: "t1800_pre_fire" },
        { at: 1950, tag: "t1950_firing" },
        { at: 2200, tag: "t2200_firing" },
        { at: 2700, tag: "t2700_firing" },
        { at: 3500, tag: "t3500_firing" },
        { at: 4200, tag: "t4200_firing_end" },
    ];

    let elapsed = 0;
    for (const p of schedule) {
        const wait = p.at - elapsed;
        if (wait > 0) await page.waitForTimeout(wait);
        elapsed = p.at;

        const info = await page.evaluate(() => {
            const h = (window as unknown as { __megaman_test: Harness }).__megaman_test;
            const b = h.getBossInfo();
            const pl = h.getInfo();
            const ai = h.getAIState();
            // Deep node snapshot: full position/scale on parent + child sprites.
            type Snap = {
                name: string; x: number; y: number; z: number; xScale: number; yScale: number;
                alpha: number; hidden: boolean; spriteW?: number; spriteH?: number; hasTexture?: boolean;
                children?: Snap[];
            };
            const children = h.getSceneChildren(2) as Snap[];
            type Snap2 = Snap & {
                layerHasContents?: boolean; layerMasksToBounds?: boolean;
                layerBoundsW?: number; layerBoundsH?: number;
                layerOpacity?: number; layerHidden?: boolean;
            };
            const kids = children as unknown as Snap2[];
            const beamCandidates = kids.filter(c =>
                (c.spriteW === 398 && c.spriteH === 32) ||
                (c.children as Snap2[] | undefined ?? []).some(cc => cc.spriteW === 398 && cc.spriteH === 208)
            ).map(c => ({
                name: c.name, x: c.x, y: c.y, z: c.z, xScale: c.xScale, yScale: c.yScale,
                alpha: c.alpha, hidden: c.hidden, w: c.spriteW, h: c.spriteH,
                hasTexture: c.hasTexture,
                layerHasContents: c.layerHasContents, layerMasksToBounds: c.layerMasksToBounds,
                layerBoundsW: c.layerBoundsW, layerBoundsH: c.layerBoundsH,
                layerOpacity: c.layerOpacity, layerHidden: c.layerHidden,
                atlasChild: (c.children as Snap2[] | undefined ?? [])
                    .filter(cc => cc.spriteW === 398 && cc.spriteH === 208)
                    .map(cc => ({
                        name: cc.name, x: cc.x, y: cc.y, z: cc.z,
                        xScale: cc.xScale, yScale: cc.yScale, alpha: cc.alpha, hidden: cc.hidden,
                        w: cc.spriteW, h: cc.spriteH, hasTexture: cc.hasTexture,
                        layerHasContents: cc.layerHasContents, layerMasksToBounds: cc.layerMasksToBounds,
                        layerBoundsW: cc.layerBoundsW, layerBoundsH: cc.layerBoundsH,
                        layerOpacity: cc.layerOpacity, layerHidden: cc.layerHidden,
                    }))[0] ?? null,
            }));
            // Canvas pixel ruler: sample ctx.getImageData for a horizontal line at y≈mid-beam.
            const canvas = document.querySelector("canvas") as HTMLCanvasElement | null;
            // Sample horizontal strip of canvas pixels around the beam's expected y-band.
            // Canvas origin is top-left (image), scene origin is bottom-left. So for
            // scene y=56 with canvasH=224, image y = 224 - 56 = 168. Beam child is
            // 208 px tall so it spans image y=(168-104) .. (168+104) = 64..272 before clip.
            // We sample a thin strip around the beam midline to find where non-black pixels are.
            let leftmostColored = -1;
            let rightmostColored = -1;
            let greenLeftmost = -1;
            let greenRightmost = -1;
            if (canvas) {
                const ctx = canvas.getContext("webgl2") ? null : (canvas.getContext("2d") as CanvasRenderingContext2D | null);
                // For WebGPU canvases getContext("2d") returns null; try to drawImage into an offscreen 2D canvas.
                const off = document.createElement("canvas");
                off.width = canvas.width;
                off.height = canvas.height;
                const octx = off.getContext("2d");
                if (octx) {
                    octx.drawImage(canvas, 0, 0);
                    const yMid = Math.max(0, Math.min(canvas.height - 1, canvas.height - 56));
                    const row = octx.getImageData(0, yMid, canvas.width, 1).data;
                    for (let x = 0; x < canvas.width; x++) {
                        const r = row[x * 4], g = row[x * 4 + 1], bl = row[x * 4 + 2], a = row[x * 4 + 3];
                        const isColored = a > 40 && (r + g + bl) > 30;
                        const isGreen = g > 100 && g > r + 30 && g > bl + 10;
                        if (isColored) {
                            if (leftmostColored < 0) leftmostColored = x;
                            rightmostColored = x;
                        }
                        if (isGreen) {
                            if (greenLeftmost < 0) greenLeftmost = x;
                            greenRightmost = x;
                        }
                    }
                }
            }
            return {
                attack: b.attack, projCount: b.projCount, bossX: b.x, bossY: b.y, playerState: pl?.state, phase: ai?.phase,
                canvasW: canvas?.width ?? 0, canvasH: canvas?.height ?? 0,
                beam: beamCandidates,
                scanYImage: (canvas?.height ?? 0) - 56,
                leftmostColored, rightmostColored, greenLeftmost, greenRightmost,
            };
        });
        console.log(`[${p.tag}] ${JSON.stringify(info)}`);
        await page.screenshot({ path: `test-results/_beam_${p.tag}.png`, fullPage: false });
        // Also dump the canvas at native resolution (398×224). WebGPU contexts
        // don't always yield pixels via toDataURL, so we request preserveDrawingBuffer
        // on the context first. If unavailable, fall back to a CSS-shrunk element
        // screenshot.
        const dataURL = await page.evaluate(() => {
            const c = document.querySelector("canvas") as HTMLCanvasElement | null;
            return c?.toDataURL("image/png") ?? "";
        });
        if (dataURL.startsWith("data:image/png;base64,")) {
            const b64 = dataURL.slice("data:image/png;base64,".length);
            const fs = await import("node:fs/promises");
            await fs.writeFile(`test-results/_beamNATIVE_${p.tag}.png`, Buffer.from(b64, "base64"));
        }
    }
});
