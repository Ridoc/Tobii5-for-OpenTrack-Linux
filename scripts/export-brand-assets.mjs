#!/usr/bin/env node
/**
 * TobiiArgus brand asset exporter.
 *
 * Renders assets/brand/*.svg to:
 *   - assets/icons/hicolor/<size>x<size>/apps/tobiiargus.png   (16..512)
 *   - assets/icons/hicolor/scalable/apps/tobiiargus.svg        (copy of master)
 *   - assets/brand/dist/tobiiargus.ico                          (multi-res)
 *   - assets/brand/dist/banner.png / avatar.png                 (README art)
 *
 * Renderer preference: rsvg-convert -> inkscape -> magick.
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const BRAND = join(ROOT, "assets", "brand");
const HICOLOR = join(ROOT, "assets", "icons", "hicolor");
const DIST = join(BRAND, "dist");

const SIZES = [16, 24, 32, 48, 64, 128, 256, 512];

function pickRenderer() {
  for (const bin of ["rsvg-convert", "inkscape", "magick"]) {
    try {
      execFileSync(bin, ["--version"], { stdio: "ignore" });
      return bin;
    } catch {
      /* try next */
    }
  }
  console.error("No SVG renderer found (need rsvg-convert, inkscape, or magick).");
  process.exit(1);
}

function render(svg, png, width, height = width) {
  const args =
    RENDERER === "rsvg-convert"
      ? ["-w", String(width), "-h", String(height), svg, "-o", png]
      : RENDERER === "inkscape"
        ? [`--export-type=png`, `--export-width=${width}`, `--export-height=${height}`, `--export-filename=${png}`, svg]
        : ["-background", "none", "-density", "300", "-resize", `${width}x${height}`, svg, png];
  execFileSync(RENDERER, args, { stdio: "pipe" });
}

const RENDERER = pickRenderer();
console.log(`renderer: ${RENDERER}`);

mkdirSync(DIST, { recursive: true });

// 1. Hicolor PNG set from the master mark
const mark = join(BRAND, "tobiiargus.svg");
for (const size of SIZES) {
  const dir = join(HICOLOR, `${size}x${size}`, "apps");
  mkdirSync(dir, { recursive: true });
  render(mark, join(dir, "tobiiargus.png"), size);
}
// 2. Scalable copy — plain read/write: NFS rejects copyfile(2) on this mount
const scalable = join(HICOLOR, "scalable", "apps");
mkdirSync(scalable, { recursive: true });
writeFileSync(join(scalable, "tobiiargus.svg"), readFileSync(mark));

// 3. Multi-resolution .ico (needs the 256/48/32/16 PNGs first)
const pngOf = (s) => join(HICOLOR, `${s}x${s}`, "apps", "tobiiargus.png");
execFileSync("magick", [pngOf(256), pngOf(128), pngOf(64), pngOf(48), pngOf(32), pngOf(24), pngOf(16), join(DIST, "tobiiargus.ico")], { stdio: "pipe" });

// 4. README art
render(join(BRAND, "tobiiargus-banner.svg"), join(DIST, "banner.png"), 1024, 256);
render(join(BRAND, "tobiiargus-avatar.svg"), join(DIST, "avatar.png"), 512);

console.log("done:");
for (const p of [
  ...SIZES.map((s) => `assets/icons/hicolor/${s}x${s}/apps/tobiiargus.png`),
  "assets/icons/hicolor/scalable/apps/tobiiargus.svg",
  "assets/brand/dist/tobiiargus.ico",
  "assets/brand/dist/banner.png",
  "assets/brand/dist/avatar.png",
]) {
  if (!existsSync(join(ROOT, p))) {
    console.error(`MISSING: ${p}`);
    process.exitCode = 1;
  }
}
if (!process.exitCode) console.log(`OK — ${SIZES.length + 5} artifacts`);
