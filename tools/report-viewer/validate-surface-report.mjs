import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import {
  complexVectorMagnitude,
  surfaceCharge,
  surfaceCurrent,
} from "./surface-math.js";

const [path, profile = "dipole"] = process.argv.slice(2);
if (!path || !["dipole", "generic"].includes(profile))
  throw new Error("usage: node validate-surface-report.mjs REPORT.html [dipole|generic]");
const html = readFileSync(path, "utf8");
const match = html.match(/<script type="application\/json" id="antenna-turtle-report-data">([\s\S]*?)<\/script>/);
if (!match) throw new Error("report data script not found");
const report = JSON.parse(match[1]);
assert.equal(report.schema, "antenna-turtle-report/m3");

const floats = encoded => {
  const bytes = gunzipSync(Buffer.from(encoded, "base64"));
  return new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4);
};
const transformPoint = (matrix, point) => matrix.map(row =>
  row[0] * point[0] + row[1] * point[1] + row[2] * point[2] + row[3]);
const transformVector = (matrix, vector) => matrix.map(row =>
  row[0] * vector[0] + row[1] * vector[1] + row[2] * vector[2]);
const normalize = vector => {
  const length = Math.hypot(...vector);
  return vector.map(value => value / length);
};
const subtract = (a, b) => a.map((value, index) => value - b[index]);
const cross = (a, b) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
];

const captures = new Map(report.captures.map(capture => {
  const [nx, ny, nz] = capture.shape;
  return [capture.name, {
    capture, nx, ny, nz, sampleCount: nx * ny * nz,
    real: floats(capture.real), imaginary: floats(capture.imaginary),
  }];
}));
const bracket = (coordinates, value) => {
  if (value <= coordinates[0]) return [0, 0, 0];
  if (value >= coordinates.at(-1)) {
    const last = coordinates.length - 1;
    return [last, last, 0];
  }
  let low = 0, high = coordinates.length - 1;
  while (high - low > 1) {
    const middle = Math.floor((low + high) / 2);
    if (coordinates[middle] <= value) low = middle;
    else high = middle;
  }
  return [low, high,
    (value - coordinates[low]) / (coordinates[high] - coordinates[low])];
};
const sample = (loaded, point) => {
  const axes = [loaded.capture.x, loaded.capture.y, loaded.capture.z];
  const brackets = axes.map((axis, index) => bracket(axis, point[index]));
  const real = [0, 0, 0], imaginary = [0, 0, 0];
  for (let bx = 0; bx < 2; ++bx)
    for (let by = 0; by < 2; ++by)
      for (let bz = 0; bz < 2; ++bz) {
        const choices = [bx, by, bz], indices = [0, 0, 0];
        let weight = 1;
        for (let axis = 0; axis < 3; ++axis) {
          const [lower, upper, mix] = brackets[axis];
          indices[axis] = choices[axis] ? upper : lower;
          weight *= choices[axis] ? mix : 1 - mix;
        }
        const index = indices[0] + loaded.nx * (indices[1] + loaded.ny * indices[2]);
        for (let component = 0; component < 3; ++component) {
          const offset = index + loaded.sampleCount * component;
          real[component] += weight * loaded.real[offset];
          imaginary[component] += weight * loaded.imaginary[offset];
        }
      }
  return { real, imaginary };
};

const zero = { real: [0, 0, 0], imaginary: [0, 0, 0] };
const results = [];
for (const hCapture of report.captures.filter(item => item.quantity === "surface-magnetic")) {
  const reconstruction = hCapture.surface_reconstruction;
  const dCapture = report.captures.find(item =>
    item.quantity === "surface-charge-flux"
      && item.surface_reconstruction.geometry_index === reconstruction.geometry_index);
  const geometry = report.geometry.find(item => item.index === reconstruction.geometry_index);
  assert.ok(dCapture && geometry);
  const h = captures.get(hCapture.name), d = captures.get(dCapture.name);
  const positions = floats(geometry.positions);
  for (let offset = 0; offset < positions.length; offset += 9) {
    const a = [...positions.slice(offset, offset + 3)];
    const b = [...positions.slice(offset + 3, offset + 6)];
    const c = [...positions.slice(offset + 6, offset + 9)];
    const center = a.map((value, index) => (value + b[index] + c[index]) / 3);
    let normal = normalize(cross(subtract(b, a), subtract(c, a)));
    const solverCenter = transformPoint(report.user_to_solver_transform, center);
    normal = normalize(transformVector(report.user_to_solver_transform, normal));
    const plus = solverCenter.map((value, index) =>
      value + reconstruction.sample_offset_m * normal[index]);
    const minus = solverCenter.map((value, index) =>
      value - reconstruction.sample_offset_m * normal[index]);
    let hOut = sample(h, plus), hIn = sample(h, minus);
    let dOut = sample(d, plus), dIn = sample(d, minus);
    if (!reconstruction.two_sided
        && complexVectorMagnitude(hIn) + complexVectorMagnitude(dIn)
          > complexVectorMagnitude(hOut) + complexVectorMagnitude(dOut)) {
      [hOut, hIn] = [hIn, hOut];
      [dOut, dIn] = [dIn, dOut];
      normal = normal.map(value => -value);
    }
    const current = surfaceCurrent(normal, hOut,
      reconstruction.two_sided ? hIn : zero);
    const charge = surfaceCharge(normal, dOut,
      reconstruction.two_sided ? dIn : zero);
    results.push({ center, current: complexVectorMagnitude(current),
      charge: Math.hypot(charge.real, charge.imaginary) });
  }
}

assert.ok(results.length > 0);
assert.ok(results.every(item => Number.isFinite(item.current) && Number.isFinite(item.charge)));
const maximumCurrent = Math.max(...results.map(item => item.current));
const maximumCharge = Math.max(...results.map(item => item.charge));
assert.ok(maximumCurrent > 0 && maximumCharge > 0);
const summary = { triangles: results.length, maximumCurrent, maximumCharge };
if (profile === "dipole") {
  const axial = results.map(item => Math.abs(item.center[2]));
  const maximumAxial = Math.max(...axial);
  const average = values => values.reduce((sum, value) => sum + value, 0) / values.length;
  const feed = results.filter(item => Math.abs(item.center[2]) < maximumAxial * 0.2);
  const tips = results.filter(item => Math.abs(item.center[2]) > maximumAxial * 0.8);
  const feedCurrent = average(feed.map(item => item.current));
  const tipCurrent = average(tips.map(item => item.current));
  assert.ok(feedCurrent > tipCurrent,
    `expected dipole current to be larger at feed (${feedCurrent}) than tips (${tipCurrent})`);
  Object.assign(summary, { feedCurrent, tipCurrent,
    feedToTipRatio: feedCurrent / tipCurrent });
}

console.log(JSON.stringify(summary, null, 2));
