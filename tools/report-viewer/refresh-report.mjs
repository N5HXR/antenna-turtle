import { readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

const report = process.argv[2];
if (!report) {
  console.error("usage: npm run refresh -- REPORT.html");
  process.exit(2);
}

const destination = resolve(report);
const bundle = resolve("../../antenna-turtle/private/report-assets/viewer.bundle.js");
const [html, viewer] = await Promise.all([
  readFile(destination, "utf8"),
  readFile(bundle, "utf8"),
]);
const marker = "</script><script>";
const start = html.lastIndexOf(marker);
const end = html.lastIndexOf("</script></body></html>");
if (start < 0 || end < start)
  throw new Error(`${destination} is not an Antenna Turtle HTML report`);
const temporary = join(dirname(destination), `.${process.pid}.viewer-refresh.html`);
await writeFile(temporary,
  html.slice(0, start + marker.length) + viewer + html.slice(end));
await rename(temporary, destination);
console.log(`refreshed viewer in ${destination}`);
