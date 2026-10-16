import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { gunzipSync } from "node:zlib";
import { averagePoynting } from "./field-math.js";

const [reportPath, requestedAxis = "x", requestedSign = "+"] = process.argv.slice(2);
if (!reportPath || !"xyz".includes(requestedAxis) || !["+", "-"].includes(requestedSign)) {
  console.error("usage: node validate-power-report.mjs REPORT.html [x|y|z] [+|-]");
  process.exit(2);
}

const html = await readFile(reportPath, "utf8");
const opening = html.indexOf(
  '<script type="application/json" id="antenna-turtle-report-data">');
const closing = html.indexOf("</script><script>", opening);
assert.ok(opening >= 0 && closing > opening, "report data script not found");
const report = JSON.parse(html.slice(html.indexOf(">", opening) + 1, closing));
const capture = quantity => report.captures.find(item =>
  item.quantity === quantity && item.shape.slice(0, 3).every(length => length > 1));
const electric = capture("electric"), magnetic = capture("magnetic");
assert.ok(electric && magnetic, "co-registered E/H volumes are required");
assert.deepEqual(electric.shape, magnetic.shape, "E/H shapes differ");
for (const axis of "xyz") assert.deepEqual(electric[axis], magnetic[axis],
  `E/H ${axis} coordinates differ`);

function floatArray(item, key) {
  const bytes = gunzipSync(Buffer.from(item[key], "base64"));
  return new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4);
}
const er = floatArray(electric, "real"), ei = floatArray(electric, "imaginary");
const hr = floatArray(magnetic, "real"), hi = floatArray(magnetic, "imaginary");
const dimensions = electric.shape.slice(0, 3);
const sampleCount = dimensions.reduce((product, value) => product * value, 1);
const userAxis = "xyz".indexOf(requestedAxis);
const row = report.solver_to_user_transform[userAxis].slice(0, 3);
const normalAxis = row.map(Math.abs).indexOf(Math.max(...row.map(Math.abs)));
const normalSign = Math.sign(row[normalAxis]) || 1;
const coordinates = [electric.x, electric.y, electric.z];
const center = (coordinates[normalAxis][0] + coordinates[normalAxis].at(-1)) / 2;
const plane = coordinates[normalAxis].reduce((best, value, index) =>
  Math.abs(value - center) < Math.abs(coordinates[normalAxis][best] - center)
    ? index : best, 0);
const varying = [0, 1, 2].filter(axis => axis !== normalAxis);
const sampleIndex = indices => indices[0]
  + dimensions[0] * (indices[1] + dimensions[1] * indices[2]);
const phasor = (real, imaginary, indices) => {
  const sample = sampleIndex(indices);
  return {
    real: [real[sample], real[sample + sampleCount], real[sample + 2 * sampleCount]],
    imaginary: [imaginary[sample], imaginary[sample + sampleCount],
      imaginary[sample + 2 * sampleCount]],
  };
};

let watts = 0;
for (let a = 0; a < dimensions[varying[0]] - 1; ++a)
  for (let b = 0; b < dimensions[varying[1]] - 1; ++b) {
    const middles = [
      (coordinates[varying[0]][a] + coordinates[varying[0]][a + 1]) / 2,
      (coordinates[varying[1]][b] + coordinates[varying[1]][b + 1]) / 2,
    ];
    if (report.pml?.enabled && middles.some((value, index) =>
      value < report.pml.inner_min[varying[index]]
        || value > report.pml.inner_max[varying[index]])) continue;
    let normalPower = 0;
    for (const [da, db] of [[0, 0], [1, 0], [1, 1], [0, 1]]) {
      const indices = [0, 0, 0];
      indices[normalAxis] = plane;
      indices[varying[0]] = a + da;
      indices[varying[1]] = b + db;
      normalPower += averagePoynting(
        phasor(er, ei, indices), phasor(hr, hi, indices))[normalAxis] / 4;
    }
    const area = Math.abs(coordinates[varying[0]][a + 1]
        - coordinates[varying[0]][a])
      * Math.abs(coordinates[varying[1]][b + 1]
        - coordinates[varying[1]][b]);
    watts += normalSign * normalPower * area;
  }

assert.ok(Number.isFinite(watts) && Math.abs(watts) > 1e-9,
  "integrated power is absent or non-finite");
assert.equal(Math.sign(watts), requestedSign === "+" ? 1 : -1,
  `power flows the wrong way: ${watts} W`);
console.log(`${requestedAxis.toUpperCase()}=${coordinates[normalAxis][plane]} m: sampled average power ${watts} W`);
