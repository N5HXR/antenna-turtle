import assert from "node:assert/strict";
import { marchingTetrahedra } from "./isosurface.js";

const coordinates = [[0, 1], [0, 1], [0, 1]];
const values = new Float32Array([
  0, 1, 0, 1,
  0, 1, 0, 1,
]);
const positions = marchingTetrahedra({
  dimensions: [2, 2, 2], coordinates, values, threshold: 0.5,
});
assert.ok(positions.length > 0);
assert.equal(positions.length % 9, 0);
for (let index = 0; index < positions.length; index += 3) {
  assert.ok(Math.abs(positions[index] - 0.5) < 1e-6);
  assert.ok(positions[index + 1] >= 0 && positions[index + 1] <= 1);
  assert.ok(positions[index + 2] >= 0 && positions[index + 2] <= 1);
}

const empty = marchingTetrahedra({
  dimensions: [2, 2, 2], coordinates, values, threshold: 2,
});
assert.equal(empty.length, 0);

const lazy = marchingTetrahedra({
  dimensions: [2, 2, 2], coordinates, threshold: 0.5,
  valueAt: x => x,
});
assert.deepEqual(lazy, positions);

console.log("isosurface tests passed");
