// Renders the report figures (diagrams.html, terminal.html) to PNG at 2x.
import { chromium } from "playwright";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 900 }, deviceScaleFactor: 2 });
await page.goto("file:///e2e/out/figs/diagrams.html");
for (const id of ["arch", "comp", "rec"]) {
  await page.locator("#" + id).screenshot({ path: `/e2e/out/figs/fig_${id}.png` });
  console.log("saved", id);
}
await page.goto("file:///e2e/out/figs/terminal.html");
await page.locator("#term").screenshot({ path: "/e2e/out/figs/fig_compose_ps.png" });
console.log("saved compose_ps");
await browser.close();
