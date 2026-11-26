import { readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const report = process.argv[2];
if (!report) {
  console.error("usage: npm run refresh -- REPORT.html");
  process.exit(2);
}

const destination = resolve(report);
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const bundle = resolve(scriptDirectory,
  "../../antenna-turtle/private/report-assets/viewer.bundle.js");
const [html, viewer] = await Promise.all([
  readFile(destination, "utf8"),
  readFile(bundle, "utf8"),
]);
const marker = '<script type="text/plain" id="antenna-turtle-report-viewer-source">';
const start = html.indexOf(marker);
const contentStart = start + marker.length;
const end = html.indexOf("</script>", contentStart);
if (start < 0 || end < contentStart)
  throw new Error(`${destination} is not an Antenna Turtle HTML report`);
const temporary = join(dirname(destination), `.${process.pid}.viewer-refresh.html`);
await writeFile(temporary,
  html.slice(0, contentStart) + viewer + html.slice(end));
await rename(temporary, destination);
console.log(`refreshed viewer in ${destination}`);
