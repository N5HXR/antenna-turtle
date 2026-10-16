import assert from "node:assert/strict";
import {
  complexVectorMagnitude,
  instantaneousVector,
  surfaceCharge,
  surfaceCurrent,
} from "./surface-math.js";

const zero = { real: [0, 0, 0], imaginary: [0, 0, 0] };

// A +Z PEC face with tangential H along +Y carries K = n x H = -X.
const magnetic = { real: [0, 3, 0], imaginary: [0, 4, 0] };
assert.deepEqual(surfaceCurrent([0, 0, 1], magnetic, zero), {
  real: [-3, 0, 0], imaginary: [-4, 0, 0],
});
assert.equal(complexVectorMagnitude(surfaceCurrent([0, 0, 1], magnetic, zero)), 5);

// A two-sided sheet uses the field jump, not either side independently.
assert.deepEqual(surfaceCurrent(
  [0, 0, 1],
  { real: [0, 2, 0], imaginary: [0, 1, 0] },
  { real: [0, -2, 0], imaginary: [0, -1, 0] }), {
  real: [-4, 0, 0], imaginary: [-2, 0, 0],
});

// Only the normal electric-flux jump contributes free surface charge.
assert.deepEqual(surfaceCharge(
  [0, 0, 1],
  { real: [7, 8, 2], imaginary: [3, 4, -5] },
  { real: [1, 2, 0.5], imaginary: [1, 1, -1] }),
{ real: 1.5, imaginary: -4 });

assert.deepEqual(instantaneousVector(magnetic, 0), [0, 3, 0]);
assert.ok(Math.abs(instantaneousVector(magnetic, Math.PI / 2)[1] + 4) < 1e-12);

console.log("surface-math tests passed");
