// Renders design/website/app-window.html to site/app-screenshot.png (2x).
//
//   node design/website/render.mjs [fonts-dir]
//
// fonts-dir is optional: any .woff2/.ttf/.otf files in it are loaded first, so
// a machine without a Hebrew system font (CI, Linux) still renders the sample
// text properly. Needs Playwright (`npm i -g playwright`) and its Chromium.
import { createRequire } from "node:module";
import { readdirSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

// require() honours NODE_PATH, so a global install works:
//   NODE_PATH=$(npm root -g) node design/website/render.mjs
const { chromium } = createRequire(import.meta.url)("playwright");

const here = path.dirname(fileURLToPath(import.meta.url));
const source = path.join(here, "app-window.html");
const out = path.join(here, "..", "..", "site", "app-screenshot.png");
const fontsDir = process.argv[2];

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2 });
await page.goto(pathToFileURL(source).href);
if (fontsDir) {
  const faces = readdirSync(fontsDir)
    .filter((f) => /\.(woff2?|ttf|otf)$/.test(f))
    .map((f) => {
      const weight = (f.match(/-(\d{3})-/) || [, "400"])[1];
      return `@font-face { font-family: "Mila Shot"; font-weight: ${weight}; src: url("${pathToFileURL(path.join(fontsDir, f)).href}"); }`;
    })
    .join("\n");
  await page.addStyleTag({ content: `${faces}\nbody { font-family: "Inter", "Mila Shot", sans-serif !important; }` });
}
await page.evaluate(() => document.fonts.ready);
await page.screenshot({ path: out, omitBackground: true });
await browser.close();
console.log(`wrote ${out}`);
